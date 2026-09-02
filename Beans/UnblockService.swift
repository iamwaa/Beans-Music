import Foundation

/// 音源解析失败原因：用于给出准确提示，区分"没配音源"、"音源不可用"和"校验拒绝"
enum UnblockFailure: Equatable, Sendable {
    /// 用户没有配置任何音源
    case noSourceConfigured
    /// 配置了音源但全部被关闭或配置无效
    case noUsableSource
    /// 当前歌曲缺少该平台所需的 id
    case missingIdentifier
    /// 所有音源都请求失败（网络错误 / HTTP 错误 / 接口报错）
    case allSourcesFailed(detail: String)
    /// 音源工作正常，但都没有这首歌的资源（返回空地址）
    case noResourceForSong
    /// 音源有返回，但严格模式校验判定不是原唱
    case strictRejected(detail: String)
    /// 音源有返回，但缺少可校验的曲目信息，严格模式下不敢播
    case strictUnverifiable(sourceName: String)

    /// 面向用户的提示文案
    var userMessage: String {
        switch self {
        case .noSourceConfigured:
            return "未配置第三方音源，请在设置中添加"
        case .noUsableSource:
            return "没有已启用的可用音源，请在设置中检查"
        case .missingIdentifier:
            return "缺少该平台的歌曲标识，无法请求音源"
        case .allSourcesFailed(let detail):
            return detail.isEmpty ? "音源不可用" : "音源不可用（\(detail)）"
        case .noResourceForSong:
            return "已配置的音源里都没有这首歌"
        case .strictRejected(let detail):
            return "音源返回的不是原唱版本，已拒绝播放（\(detail)）"
        case .strictUnverifiable(let sourceName):
            return "音源「\(sourceName)」未提供曲目信息，无法确认原唱"
        }
    }
}

enum UnblockOutcome: Sendable {
    case success(UnblockService.Resolved)
    case failure(UnblockFailure)

    var resolved: UnblockService.Resolved? {
        if case .success(let value) = self { return value }
        return nil
    }

    var failure: UnblockFailure? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
}

/// 灰色歌曲 / VIP 试听解锁：使用用户自行配置的第三方音源。
/// 由 PlayerManager 在网易云 / QQ / 酷狗无完整 URL 时自动调用。
enum UnblockService {
    struct Resolved: Sendable {
        let url: URL
        let source: String
        /// 严格模式下是否通过了原唱校验
        var strictVerified: Bool = false

        var sourceTitle: String { source }
    }

    /// 单个音源的请求结果
    private enum SourceAttempt: Sendable {
        case success(Resolved)
        case rejected(UnblockFailure)
        case failed(String)
    }

    /// LX 脚本音源的请求结果（异步，需在 TaskGroup 中等待）
    private enum LXScriptAttempt: Sendable {
        case success(Resolved)
        case failed(String)
    }

    /// 音源响应里附带的曲目信息，用于严格模式校验
    private struct TrackMetadata {
        var name: String?
        var artists: String?
        var durationMS: Int?

        var isEmpty: Bool {
            name == nil && artists == nil && durationMS == nil
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// 入口：并发尝试可用于当前平台的音源，返回第一个通过校验的地址。
    /// strict 为 true 时要求音源返回的曲目信息与原曲匹配，匹配不上或无信息可校验都拒绝播放。
    static func resolve(
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource = .netease,
        qqMid: String? = nil,
        kugouID: String? = nil,
        durationMS: Int? = nil,
        strict: Bool = false
    ) async -> UnblockOutcome {
        let hasSongIdentity = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !artists.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSongIdentity else { return .failure(.missingIdentifier) }

        let store = UnblockSourceStore.shared
        guard !store.sources.isEmpty else { return .failure(.noSourceConfigured) }

        let usable = store.activeSources
            .filter { canUse(source: $0, songSource: songSource, neteaseID: neteaseID, qqMid: qqMid, kugouID: kugouID) }
        guard !usable.isEmpty else { return .failure(.noUsableSource) }

        // 模板与取值路径完全一致的音源最终访问同一个接口，去重避免同一首歌重复请求。
        var seen = Set<String>()
        let uniqueSources = usable.filter { seen.insert(requestFingerprint(for: $0)).inserted }

        // 区分 JSON 模板音源与 LX 脚本音源，分别走不同解析路径
        let templateSources = uniqueSources.filter { !$0.isLXScript }
        let scriptSources = uniqueSources.filter { $0.isLXScript }

        // 慢源/失效源不要拖住播放：全部候选一起请求，最快通过校验的地址直接返回。
        return await withTaskGroup(of: SourceAttempt.self) { group in
            // JSON 模板音源：并发请求
            for source in templateSources {
                group.addTask {
                    await self.presetSourceRequest(
                        source: source,
                        name: name,
                        artists: artists,
                        neteaseID: neteaseID,
                        songSource: songSource,
                        qqMid: qqMid,
                        kugouID: kugouID,
                        durationMS: durationMS,
                        strict: strict
                    )
                }
            }
            // LX 脚本音源：并发请求
            for source in scriptSources {
                group.addTask {
                    let result = await self.lxScriptSourceRequest(
                        source: source,
                        name: name,
                        artists: artists,
                        neteaseID: neteaseID,
                        songSource: songSource,
                        qqMid: qqMid,
                        kugouID: kugouID
                    )
                    switch result {
                    case .success(let resolved):
                        return .success(resolved)
                    case .failed(let detail):
                        return .failed(detail)
                    }
                }
            }
            var rejection: UnblockFailure?
            var failureDetails: [String] = []
            var missingCount = 0
            for await attempt in group {
                switch attempt {
                case .success(let resolved):
                    group.cancelAll()
                    return .success(resolved)
                case .rejected(let reason):
                    // 校验拒绝比网络失败更能说明问题，优先保留
                    if rejection == nil { rejection = reason }
                case .failed(let detail):
                    if detail == "音源无此歌资源" {
                        missingCount += 1
                    } else {
                        failureDetails.append(detail)
                    }
                }
            }
            if let rejection {
                return .failure(rejection)
            }
            // 所有音源都正常应答但都没有资源：是这首歌拿不到，不是音源挂了
            if failureDetails.isEmpty && missingCount > 0 {
                return .failure(.noResourceForSong)
            }
            return .failure(.allSourcesFailed(detail: failureDetails.first ?? ""))
        }
    }

    /// 连接检测：只验证音源能否正常响应，不关心具体歌曲。
    static func probe(source: ThirdPartySource) async -> UnblockSourceHealth {
        guard source.isValid else {
            return .failed(reason: source.isLXScript ? "脚本为空" : "模板无效")
        }
        // LX 脚本音源：验证脚本能正常加载并初始化
        if source.isLXScript {
            return await probeLXScript(source: source)
        }
        // 用一首公开的免费歌曲做探测，避免受版权状态干扰；
        // 优先拉网易云，不支持网易云时退到该音源声明支持的首个平台
        let probeCode = source.supportsProvider("wy") ? "wy" : (source.providerMap.keys.sorted().first ?? "wy")
        let probeID = probeCode == "tx" ? "003aAYrm3GE0Ac" : "347230"
        guard let request = buildRequest(
            source: source,
            songID: probeID,
            provider: source.providerParameter(for: probeCode),
            name: "海阔天空",
            artists: "Beyond"
        ) else {
            return .failed(reason: "请求地址无法构造")
        }
        // 探测只关心“这个音源能不能正常应答”，所以不把空 url 当失败（见下方注释）
        let started = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return .failed(reason: "响应异常")
            }
            guard http.statusCode == 200 else {
                return .failed(reason: httpFailureReason(status: http.statusCode, data: data))
            }
            guard let obj = try? JSONSerialization.jsonObject(with: data) else {
                return .failed(reason: "响应不是 JSON")
            }
            if let dict = obj as? [String: Any], let code = responseCode(from: dict), code != 200, code != 0 {
                let message = dict["message"] as? String ?? dict["msg"] as? String ?? "code=\(code)"
                return .failed(reason: message)
            }
            return .healthy(latencyMS: latency)
        } catch {
            return .failed(reason: (error as NSError).code == NSURLErrorTimedOut ? "连接超时" : error.localizedDescription)
        }
    }

    private static func canUse(source: ThirdPartySource, songSource: SongSource, neteaseID: Int, qqMid: String?, kugouID: String?) -> Bool {
        let expectedProvider = providerCode(for: songSource)
        guard source.supportsProvider(expectedProvider) else { return false }
        if songSource == .qq {
            return qqMid?.isEmpty == false
        }
        if songSource == .kugou {
            return kugouID?.isEmpty == false
        }
        return neteaseID > 0
    }

    // MARK: - LX 脚本音源请求

    /// 通过 LXScriptEngine 执行 LX Music JS 脚本音源，获取播放 URL
    private static func lxScriptSourceRequest(
        source: ThirdPartySource,
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource,
        qqMid: String?,
        kugouID: String?
    ) async -> LXScriptAttempt {
        guard source.isValid else { return .failed("脚本为空") }
        let expectedProvider = providerCode(for: songSource)
        guard source.supportsProvider(expectedProvider) else {
            return .failed("该脚本不支持此平台")
        }

        // 构造歌曲信息，传给脚本的 musicUrl action
        var musicInfo: [String: Any] = [:]
        musicInfo["name"] = name
        musicInfo["singer"] = artists
        switch songSource {
        case .netease where neteaseID > 0:
            musicInfo["id"] = String(neteaseID)
            musicInfo["songmid"] = String(neteaseID)
        case .qq:
            guard let qqMid, !qqMid.isEmpty else { return .failed("缺少 QQ 歌曲标识") }
            musicInfo["songmid"] = qqMid
            musicInfo["mid"] = qqMid
            musicInfo["strMediaMid"] = qqMid
        case .kugou:
            guard let kugouID, !kugouID.isEmpty else { return .failed("缺少酷狗歌曲标识") }
            musicInfo["hash"] = kugouID
            musicInfo["id"] = kugouID
        default:
            return .failed("缺少歌曲标识")
        }

        // 获取脚本引擎并调用
        do {
            let engine = try await LXScriptEngine.cachedEngine(for: source.scriptBody)
            // 音质映射：BeansAudioQuality → LX 脚本音质代码
            let quality = currentQualityForLXScript()
            let url = try await engine.getMusicURL(source: expectedProvider, musicInfo: musicInfo, type: quality)
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failed("脚本返回空地址")
            }
            guard let playURL = URL(string: trimmed), playURL.scheme?.hasPrefix("http") == true else {
                return .failed("脚本返回的地址无效")
            }
            BeansLogger.shared.log("LX脚本命中：\(source.name) 平台=\(expectedProvider) URL=\(playURL.host ?? trimmed) 音质=\(quality)", level: .info)
            return .success(Resolved(url: playURL, source: source.name, strictVerified: false))
        } catch let error as LXScriptEngine.EngineError {
            BeansLogger.shared.log("LX脚本失败：\(source.name) \(error.errorDescription ?? "")", level: .debug)
            return .failed(error.errorDescription ?? "脚本执行失败")
        } catch {
            BeansLogger.shared.log("LX脚本失败：\(source.name) \(error.localizedDescription)", level: .debug)
            return .failed(error.localizedDescription)
        }
    }

    /// 当前音质映射为 LX 脚本音质代码（128k / 320k / flac / 24bit）
    private static func currentQualityForLXScript() -> String {
        switch BeansAudioQuality.current {
        case .standard: return "128k"
        case .higher: return "192k"
        case .exhigh: return "320k"
        case .lossless: return "flac"
        case .hires: return "24bit"
        }
    }

    /// LX 脚本音源连接检测：验证脚本能正常加载并初始化
    private static func probeLXScript(source: ThirdPartySource) async -> UnblockSourceHealth {
        let started = Date()
        do {
            _ = try await LXScriptEngine.cachedEngine(for: source.scriptBody)
            let latency = Int(Date().timeIntervalSince(started) * 1000)
            return .healthy(latencyMS: latency)
        } catch let error as LXScriptEngine.EngineError {
            return .failed(reason: error.errorDescription ?? "脚本加载失败")
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    private static func presetSourceRequest(
        source: ThirdPartySource,
        name: String,
        artists: String,
        neteaseID: Int,
        songSource: SongSource,
        qqMid: String?,
        kugouID: String?,
        durationMS: Int?,
        strict: Bool
    ) async -> SourceAttempt {
        guard source.isValid else { return .failed("配置无效") }
        let expectedProvider = providerCode(for: songSource)
        guard source.supportsProvider(expectedProvider) else {
            return .failed("该音源不支持此平台")
        }
        let songID: String
        switch songSource {
        case .netease where neteaseID > 0:
            songID = String(neteaseID)
        case .qq:
            guard let qqMid, !qqMid.isEmpty else { return .failed("缺少 QQ 歌曲标识") }
            songID = qqMid
        case .kugou:
            guard let kugouID, !kugouID.isEmpty else { return .failed("缺少酷狗歌曲标识") }
            songID = kugouID
        default:
            return .failed("缺少歌曲标识")
        }
        guard let request = buildRequest(
            source: source,
            songID: songID,
            provider: source.providerParameter(for: expectedProvider),
            name: name,
            artists: artists
        ) else {
            return .failed("请求地址无法构造")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let reason = (error as NSError).code == NSURLErrorTimedOut ? "连接超时" : error.localizedDescription
            BeansLogger.shared.log("音源请求失败：\(source.name) \(reason)", level: .debug)
            return .failed(reason)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let reason = httpFailureReason(status: status, data: data)
            BeansLogger.shared.log("音源 HTTP 失败：\(source.name) 状态=\(status) \(reason)", level: .debug)
            return .failed(reason)
        }
        // 有的音源（如 Meting）直接返回顶层数组，所以不能只接受字典
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            BeansLogger.shared.log("音源响应格式错误：\(source.name)", level: .debug)
            return .failed("响应不是 JSON")
        }
        if let dict = obj as? [String: Any], let code = responseCode(from: dict), code != 200, code != 0 {
            let message = dict["message"] as? String ?? dict["msg"] as? String ?? "code=\(code)"
            BeansLogger.shared.log("音源返回失败：\(source.name) \(message)", level: .debug)
            return .failed(message)
        }
        // 注意：常见音源（如 GDStudio）对 VIP / 不存在的歌曲仍然返回 HTTP 200 + code 正常，
        // 只是 url 为空串。这种情况属于“这首歌拿不到”，不能当成音源本身挂了。
        let rawValue = valueAtAnyPath(obj, source.urlPath)
        let rawURLString = (rawValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawURLString.isEmpty else {
            BeansLogger.shared.log("音源无此歌资源：\(source.name) 返回空地址", level: .debug)
            return .failed("音源无此歌资源")
        }
        guard let playURL = URL(string: rawURLString), playURL.scheme?.hasPrefix("http") == true else {
            BeansLogger.shared.log("音源返回的地址无法解析：\(source.name)", level: .debug)
            return .failed("返回的播放地址无效")
        }

        guard strict else {
            BeansLogger.shared.log("音源命中：\(source.name) 平台=\(expectedProvider)", level: .info)
            return .success(Resolved(url: playURL, source: source.name, strictVerified: false))
        }

        // 严格模式：必须能从响应里读到曲目信息，且与原曲匹配，否则拒绝，避免播放翻唱
        let metadata = trackMetadata(from: obj)
        if metadata.isEmpty {
            BeansLogger.shared.log("音源严格校验：\(source.name) 响应无曲目信息，拒绝播放", level: .info)
            return .rejected(.strictUnverifiable(sourceName: source.name))
        }
        if let mismatch = strictMismatchReason(
            metadata: metadata,
            expectedName: name,
            expectedArtists: artists,
            expectedDurationMS: durationMS
        ) {
            BeansLogger.shared.log("音源严格校验不通过：\(source.name) \(mismatch)", level: .info)
            return .rejected(.strictRejected(detail: mismatch))
        }
        BeansLogger.shared.log("音源命中并通过严格校验：\(source.name) 平台=\(expectedProvider)", level: .info)
        return .success(Resolved(url: playURL, source: source.name, strictVerified: true))
    }

    private static func buildRequest(
        source: ThirdPartySource,
        songID: String,
        provider: String,
        name: String,
        artists: String
    ) -> URLRequest? {
        var urlString = source.template
        urlString = urlString.replacingOccurrences(of: "{id}", with: songID)
        urlString = urlString.replacingOccurrences(of: "{source}", with: provider)
        urlString = urlString.replacingOccurrences(of: "{quality}", with: source.headers["quality"] ?? "320k")
        urlString = urlString.replacingOccurrences(of: "{br}", with: source.headers["br"] ?? "320")
        urlString = urlString.replacingOccurrences(of: "{name}", with: urlEncoded(name))
        let keyword = ([name, artists].filter { !$0.isEmpty }).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        urlString = urlString.replacingOccurrences(of: "{keyword}", with: urlEncoded(keyword))
        urlString = urlString.replacingOccurrences(of: "{artist}", with: urlEncoded(artists))
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 7
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BeansMusic/1.0", forHTTPHeaderField: "User-Agent")
        if let apiKey = source.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        for (key, value) in source.headers where !ThirdPartySource.metadataKeys.contains(key) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    // MARK: - 严格校验

    /// 从响应中尽力提取曲目信息，兼容常见字段命名
    /// obj 可能是字典也可能是顶层数组，所以路径里一并覆盖 0.xxx / data.0.xxx 形式
    private static func trackMetadata(from obj: Any) -> TrackMetadata {
        var metadata = TrackMetadata()
        let namePaths = ["name", "songName", "title", "songname",
                         "data.name", "data.songName", "data.title", "data.song",
                         "0.name", "0.title", "0.songname", "data.0.name", "data.0.title"]
        let artistPaths = ["artist", "artists", "singer", "author",
                           "data.artist", "data.artists", "data.singer", "data.author",
                           "0.artist", "0.artists", "0.singer", "data.0.artist", "data.0.artists"]
        let durationPaths = ["duration", "interval", "time",
                             "data.duration", "data.interval", "data.time",
                             "0.duration", "0.interval", "data.0.duration"]

        for path in namePaths {
            if let value = valueAtPath(obj, path) as? String, !value.isEmpty {
                metadata.name = value
                break
            }
        }
        for path in artistPaths {
            if let value = valueAtPath(obj, path) {
                if let text = value as? String, !text.isEmpty {
                    metadata.artists = text
                    break
                }
                if let list = value as? [String], !list.isEmpty {
                    metadata.artists = list.joined(separator: " ")
                    break
                }
                if let dicts = value as? [[String: Any]] {
                    let names = dicts.compactMap { $0["name"] as? String }
                    if !names.isEmpty {
                        metadata.artists = names.joined(separator: " ")
                        break
                    }
                }
            }
        }
        for path in durationPaths {
            guard let value = valueAtPath(obj, path) else { continue }
            if let ms = durationInMilliseconds(from: value) {
                metadata.durationMS = ms
                break
            }
        }
        return metadata
    }

    /// 秒 / 毫秒混用很常见：小于 10000 一律按秒处理
    private static func durationInMilliseconds(from value: Any) -> Int? {
        var raw: Double?
        if let number = value as? NSNumber {
            raw = number.doubleValue
        } else if let text = value as? String {
            raw = Double(text)
        }
        guard let raw, raw > 0 else { return nil }
        return raw < 10_000 ? Int(raw * 1000) : Int(raw)
    }

    /// 返回不匹配的原因；nil 表示校验通过
    private static func strictMismatchReason(
        metadata: TrackMetadata,
        expectedName: String,
        expectedArtists: String,
        expectedDurationMS: Int?
    ) -> String? {
        if let actualName = metadata.name {
            let expected = normalized(expectedName)
            let actual = normalized(actualName)
            if !expected.isEmpty, !actual.isEmpty,
               !actual.contains(expected), !expected.contains(actual) {
                return "歌名不符：\(actualName)"
            }
        }
        if let actualArtists = metadata.artists {
            let expectedTokens = artistTokens(expectedArtists)
            let actualTokens = artistTokens(actualArtists)
            if !expectedTokens.isEmpty, !actualTokens.isEmpty,
               expectedTokens.isDisjoint(with: actualTokens) {
                return "歌手不符：\(actualArtists)"
            }
        }
        if let expectedDurationMS, expectedDurationMS > 0, let actualDuration = metadata.durationMS {
            // 不同版本的母带长度会有细微差异，允许 5 秒偏差
            if abs(actualDuration - expectedDurationMS) > 5000 {
                return "时长不符：\(actualDuration / 1000)s vs \(expectedDurationMS / 1000)s"
            }
        }
        return nil
    }

    /// 去掉空格、括号内容与大小写差异，便于宽松比较
    private static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        var result = ""
        var depth = 0
        for character in lowered {
            if "（(【[".contains(character) {
                depth += 1
                continue
            }
            if "）)】]".contains(character) {
                depth = max(0, depth - 1)
                continue
            }
            guard depth == 0 else { continue }
            if character.isLetter || character.isNumber {
                result.append(character)
            }
        }
        return result
    }

    /// 歌手串可能用 / & , 、等分隔，拆成集合后按交集判断
    private static func artistTokens(_ text: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: "/&,，、;；|+ ")
        return Set(
            text.components(separatedBy: separators)
                .map { normalized($0) }
                .filter { !$0.isEmpty }
        )
    }

    // MARK: - 工具

    private static func httpFailureReason(status: Int, data: Data) -> String {
        // detail / error 是常见的错误字段名（如 GDStudio 用 detail）
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = obj["message"] as? String ?? obj["msg"] as? String
               ?? obj["detail"] as? String ?? obj["error"] as? String,
           !message.isEmpty {
            return message
        }
        switch status {
        case 400: return "请求参数不被接受，检查模板占位符"
        case 401: return "密钥无效或已被禁用"
        case 403: return "服务拒绝访问"
        case 404: return "接口地址不存在"
        case 429: return "请求过于频繁"
        case 500...599: return "音源服务异常"
        default: return "HTTP \(status)"
        }
    }

    private static func requestFingerprint(for source: ThirdPartySource) -> String {
        // LX 脚本音源以脚本内容前 64 字符做指纹，避免大脚本全量哈希
        if source.isLXScript {
            let prefix = String(source.scriptBody.prefix(64))
            return "lxscript|\(source.name)|\(prefix)"
        }
        let headers = source.headers
            .filter { $0.key != "source" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return "\(source.template)|\(source.urlPath)|\(headers)"
    }

    private static func responseCode(from object: [String: Any]) -> Int? {
        if let code = object["code"] as? Int {
            return code
        }
        if let code = object["code"] as? NSNumber {
            return code.intValue
        }
        if let code = object["code"] as? String {
            return Int(code)
        }
        return nil
    }

    private static func providerCode(for source: SongSource) -> String {
        switch source {
        case .netease: return "wy"
        case .qq: return "tx"
        case .kugou: return "kg"
        }
    }

    /// 多个点分路径取值：data.music|data.url|url。
    private static func valueAtAnyPath(_ obj: Any, _ paths: String) -> Any? {
        for path in paths.split(separator: "|") {
            if let value = valueAtPath(obj, String(path)) {
                return value
            }
        }
        return nil
    }

    /// 点分路径取值：url / data.url / data.audioUrl
    /// 数字段作为数组下标，因此支持 0.url（顶层是数组的响应）、data.0.url 这类路径。
    private static func valueAtPath(_ obj: Any, _ path: String) -> Any? {
        var current: Any = obj
        for key in path.split(separator: ".") {
            let segment = String(key)
            if let array = current as? [Any] {
                guard let index = Int(segment), array.indices.contains(index) else { return nil }
                current = array[index]
                continue
            }
            guard let dict = current as? [String: Any], let next = dict[segment] else { return nil }
            current = next
        }
        return current
    }

    private static func urlEncoded(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? string
    }
}
