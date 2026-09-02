import Foundation

/// 用户配置的第三方解锁音源。
/// template：请求 URL 模板，支持 {id}、{source}、{quality}、{name}、{artist}、{keyword} 占位符。
/// urlPath：响应中播放地址的取值路径，多个候选用 | 分隔，如 data.url|url。
/// headers：请求头与元数据（apiKey / quality / br / source 为元数据，不直接作为请求头发送）。
/// providerMap：平台代码到接口实际参数名的映射，如 ["wy": "netease"]；
///   因为各家接口对平台的叫法不同（wy / netease / 163 都有），不能直接把 wy 填进 URL。
struct ThirdPartySource: Identifiable, Codable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    /// 音源类型："custom" = JSON 模板音源，"lxscript" = LX Music JS 脚本音源
    var kind: String = "custom"
    var template: String
    var urlPath: String = "url"
    var headers: [String: String] = [:]
    var providerMap: [String: String] = [:]
    var enabled: Bool = true
    /// LX Music JS 脚本内容（kind == "lxscript" 时使用）
    var scriptBody: String = ""

    /// 元数据键：不作为 HTTP 请求头发送
    static let metadataKeys: Set<String> = ["source", "quality", "br", "apiKey"]

    enum CodingKeys: String, CodingKey {
        case id, name, kind, template, urlPath, headers, providerMap, enabled, scriptBody
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: String = "custom",
        template: String,
        urlPath: String = "url",
        headers: [String: String] = [:],
        providerMap: [String: String] = [:],
        enabled: Bool = true,
        scriptBody: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.template = template
        self.urlPath = urlPath
        self.headers = headers
        self.providerMap = providerMap
        self.enabled = enabled
        self.scriptBody = scriptBody
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未命名音源"
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "custom"
        template = try container.decodeIfPresent(String.self, forKey: .template) ?? ""
        urlPath = try container.decodeIfPresent(String.self, forKey: .urlPath) ?? "url"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        providerMap = try container.decodeIfPresent([String: String].self, forKey: .providerMap) ?? [:]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        scriptBody = try container.decodeIfPresent(String.self, forKey: .scriptBody) ?? ""
    }

    /// 把平台代码（wy / tx / kg）换成该音源接口认的参数名；没配置时原样使用
    func providerParameter(for code: String) -> String {
        providerMap[code] ?? code
    }

    /// 该音源能否侍候某平台：配了 providerMap 就以它为准，否则不限
    func supportsProvider(_ code: String) -> Bool {
        providerMap.isEmpty || providerMap[code] != nil
    }

    /// 配置是否有效：lxscript 检查脚本内容，custom 检查模板占位符
    var isLXScript: Bool { kind == "lxscript" }

    /// 模板缺失或无法构造请求时视为无效配置；lxscript 则检查脚本内容是否为空
    var isValid: Bool {
        if isLXScript {
            return !scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return template.contains("{id}") || template.contains("{keyword}") || template.contains("{name}")
    }

    var apiKey: String? {
        let key = headers["apiKey"] ?? ""
        return key.isEmpty ? nil : key
    }

}

/// 音源连接状态
enum UnblockSourceHealth: Equatable, Sendable {
    case unknown
    case checking
    case healthy(latencyMS: Int)
    case failed(reason: String)

    var label: String {
        switch self {
        case .unknown: return "未检测"
        case .checking: return "检测中"
        case .healthy(let ms): return "可用 · \(ms)ms"
        case .failed(let reason): return reason
        }
    }

    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// 音源导入结果
struct UnblockImportResult: Sendable {
    var added: Int
    var updated: Int
    var skipped: Int

    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("新增 \(added) 个") }
        if updated > 0 { parts.append("更新 \(updated) 个") }
        if skipped > 0 { parts.append("跳过 \(skipped) 个") }
        return parts.isEmpty ? "没有可导入的音源" : parts.joined(separator: "，")
    }
}

enum UnblockImportError: LocalizedError {
    case invalidURL
    case network(String)
    case badFormat
    case empty
    case badScript

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "导入地址无效"
        case .network(let message): return "下载失败：\(message)"
        case .badFormat: return "内容不是有效的音源 JSON"
        case .empty: return "内容里没有有效的音源配置"
        case .badScript: return "脚本格式不正确，需包含 LX Music 音源脚本"
        }
    }
}

/// 第三方音源管理：完全由用户自行添加或导入，不再内置任何音源。
final class UnblockSourceStore: ObservableObject {
    static let shared = UnblockSourceStore()

    @Published var sources: [ThirdPartySource] {
        didSet { save() }
    }

    /// 各音源最近一次连接检测结果，key 为音源 id
    @Published private(set) var health: [String: UnblockSourceHealth] = [:]

    private let defaults = UserDefaults.standard
    private let sourcesKey = "beans.unblock.sources.v1"
    private let legacyPresetsKey = "beans.unblock.presets"
    private let legacyCustomKey = "beans.unblock.custom"
    private let legacyLXKey = "beans.unblock.lxScripts"

    /// 已失效的内置预设 id 前缀：迁移时一并清除，避免继续发无效请求
    private static let retiredPresetPrefix = "beans.preset."

    private init() {
        if let data = defaults.data(forKey: sourcesKey),
           let list = try? JSONDecoder().decode([ThirdPartySource].self, from: data) {
            sources = list
        } else if let data = defaults.data(forKey: legacyPresetsKey),
                  let list = try? JSONDecoder().decode([ThirdPartySource].self, from: data) {
            // 旧版内置预设的服务端密钥已被禁用，迁移时全部丢弃，只保留用户自定义条目
            sources = list.filter { !$0.id.hasPrefix(Self.retiredPresetPrefix) }
        } else {
            sources = []
        }
        defaults.removeObject(forKey: legacyPresetsKey)
        defaults.removeObject(forKey: legacyCustomKey)
        defaults.removeObject(forKey: legacyLXKey)
        save()
    }

    /// 参与播放解析的音源：已启用且配置有效
    var activeSources: [ThirdPartySource] {
        sources.filter { $0.enabled && $0.isValid }
    }

    // MARK: - 增删改

    func add(_ source: ThirdPartySource) {
        sources.append(source)
        health[source.id] = .unknown
    }

    func update(_ source: ThirdPartySource) {
        guard let index = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[index] = source
        health[source.id] = .unknown
    }

    func remove(id: String) {
        sources.removeAll { $0.id == id }
        health.removeValue(forKey: id)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[index].enabled = enabled
    }

    // MARK: - 统一文件导入

    /// 从本地文件导入音源，自动识别 JSON 配置或 LX Music JS 脚本。
    /// 先尝试 JSON 解析，失败则按 JS 脚本导入。
    func importFromFile(data: Data) throws -> UnblockImportResult {
        // 先尝试 JSON 配置导入
        do {
            return try importSources(from: data)
        } catch UnblockImportError.badFormat {
            // 不是 JSON，尝试按脚本导入
        } catch UnblockImportError.empty {
            // JSON 解析成功但没有有效条目，尝试按脚本导入
        }
        // 按 LX Music JS 脚本导入
        return try importScript(from: data)
    }

    // MARK: - 导入

    /// 从 JSON 数据导入，支持单个对象或数组；同名同模板视为同一音源并覆盖更新
    func importSources(from data: Data) throws -> UnblockImportResult {
        let decoder = JSONDecoder()
        var incoming: [ThirdPartySource] = []
        if let list = try? decoder.decode([ThirdPartySource].self, from: data) {
            incoming = list
        } else if let single = try? decoder.decode(ThirdPartySource.self, from: data) {
            incoming = [single]
        } else if let wrapper = try? decoder.decode([String: [ThirdPartySource]].self, from: data),
                  let list = wrapper["sources"] {
            incoming = list
        } else {
            throw UnblockImportError.badFormat
        }

        let valid = incoming.filter { $0.isValid }
        guard !valid.isEmpty else { throw UnblockImportError.empty }

        var result = UnblockImportResult(added: 0, updated: 0, skipped: incoming.count - valid.count)
        for var source in valid {
            if let index = sources.firstIndex(where: { $0.name == source.name && $0.template == source.template }) {
                source.id = sources[index].id
                source.enabled = sources[index].enabled
                sources[index] = source
                health[source.id] = .unknown
                result.updated += 1
            } else {
                if sources.contains(where: { $0.id == source.id }) {
                    source.id = UUID().uuidString
                }
                sources.append(source)
                health[source.id] = .unknown
                result.added += 1
            }
        }
        return result
    }

    /// 从远程地址导入音源配置或 LX Music JS 脚本。
    /// 自动识别响应内容类型：JSON 配置走 `importSources`，JS 脚本走 `importScript`。
    /// URL 以 .js 结尾或响应体包含 LX 脚本特征时按脚本导入。
    @MainActor
    func importFromRemote(urlString: String) async throws -> UnblockImportResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw UnblockImportError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw UnblockImportError.network("HTTP \(http.statusCode)")
            }
            // 优先用 URL 后缀判断：.js 结尾按脚本导入
            let pathLower = url.path.lowercased()
            if pathLower.hasSuffix(".js") || pathLower.hasSuffix(".js") {
                return try importScript(from: data)
            }
            // 其次检查内容：是否是 LX Music JS 脚本
            if let body = String(data: data, encoding: .utf8), looksLikeLXScript(body) {
                return try importScript(from: data)
            }
            // 否则按 JSON 配置导入
            return try importSources(from: data)
        } catch let error as UnblockImportError {
            throw error
        } catch {
            throw UnblockImportError.network(error.localizedDescription)
        }
    }

    /// 判断文本是否是 LX Music JS 脚本（而非 JSON 配置）
    private func looksLikeLXScript(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON 配置以 { 或 [ 开头
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return false }
        // LX 脚本特征：包含 globalThis.lx / EVENT_NAMES / lx. 且非 JSON
        return trimmed.contains("globalThis.lx") || trimmed.contains("EVENT_NAMES") || trimmed.contains("@name")
    }

    // MARK: - LX 脚本导入

    /// 从 JS 脚本文件导入 LX Music 音源。
    /// 解析脚本头部的 @name / @description / @version 注释提取名称，无则用文件名。
    func importScript(from data: Data) throws -> UnblockImportResult {
        guard let script = String(data: data, encoding: .utf8), !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UnblockImportError.badScript
        }
        // 校验是否为 LX Music 脚本：必须包含 globalThis.lx 或 EVENT_NAMES 或 lx.
        guard script.contains("globalThis.lx") || script.contains("EVENT_NAMES") || script.contains("lx.") || script.contains("@name") else {
            throw UnblockImportError.badScript
        }

        // 从注释中提取元数据（@name / @version / @author 等）
        let meta = LXScriptEngine.parseScriptMeta(script)
        let name = meta.name.isEmpty ? "LX 脚本音源" : meta.name

        var source = ThirdPartySource(
            name: name,
            kind: "lxscript",
            template: "",
            enabled: true
        )
        source.scriptBody = script

        // 同名脚本视为同一音源并覆盖更新
        if let index = sources.firstIndex(where: { $0.name == source.name && $0.isLXScript }) {
            source.id = sources[index].id
            source.enabled = sources[index].enabled
            sources[index] = source
            health[source.id] = .unknown
            // 脚本内容变更时清除引擎缓存
            LXScriptEngine.clearCache()
            return UnblockImportResult(added: 0, updated: 1, skipped: 0)
        } else {
            if sources.contains(where: { $0.id == source.id }) {
                source.id = UUID().uuidString
            }
            sources.append(source)
            health[source.id] = .unknown
            return UnblockImportResult(added: 1, updated: 0, skipped: 0)
        }
    }

    /// 导出当前音源配置，便于备份或分享
    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sources)
    }

    // MARK: - 健康检测

    func healthState(for id: String) -> UnblockSourceHealth {
        health[id] ?? .unknown
    }

    /// 检测单个音源连通性
    @MainActor
    func checkHealth(for source: ThirdPartySource) async {
        health[source.id] = .checking
        let result = await UnblockService.probe(source: source)
        health[source.id] = result
    }

    /// 检测全部已启用音源
    @MainActor
    func checkHealthForActiveSources() async {
        let targets = activeSources
        guard !targets.isEmpty else { return }
        for target in targets {
            health[target.id] = .checking
        }
        await withTaskGroup(of: (String, UnblockSourceHealth).self) { group in
            for target in targets {
                group.addTask {
                    (target.id, await UnblockService.probe(source: target))
                }
            }
            for await (id, result) in group {
                health[id] = result
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: sourcesKey)
        }
    }
}
