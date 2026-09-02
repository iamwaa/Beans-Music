import Foundation
import JavaScriptCore

/// LX Music 脚本音源执行引擎。
///
/// 脚本通过 `globalThis.lx` 与宿主交互：
/// - `lx.EVENT_NAMES` 事件名常量（request / inited）
/// - `lx.request(url, options, callback)` 发起 HTTP 请求
/// - `lx.on(EVENT_NAMES.request, handler)` 注册请求处理回调
/// - `lx.send(EVENT_NAMES.inited, { sources })` 通知初始化完成
///
/// 引擎在 JSContext 中注入 `globalThis.lx` 运行环境，加载脚本后，
/// 调用脚本注册的 `musicUrl` action 获取播放地址。
///
/// 用法：
/// ```swift
/// let engine = try await LXScriptEngine.load(script: jsString)
/// let url = try await engine.getMusicURL(source: "wy", musicInfo: info, type: "320k")
/// ```
final class LXScriptEngine {

    // MARK: - 类型

    /// 脚本声明的音源配置（对应 `send(EVENT_NAMES.inited, { sources })` 的内容）
    struct SourceConfig: Sendable {
        let id: String
        let name: String
        let qualitys: [String]
    }

    /// 单次解析结果
    struct ResolvedURL: Sendable {
        let url: String
        let sourceName: String
    }

    /// 引擎错误
    enum EngineError: Error, LocalizedError {
        case scriptLoadFailed(String)
        case noHandler
        case handlerThrew(String)
        case invalidResult
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .scriptLoadFailed(let msg): return "脚本加载失败：\(msg)"
            case .noHandler: return "脚本未注册 musicUrl 处理器"
            case .handlerThrew(let msg): return "脚本执行出错：\(msg)"
            case .invalidResult: return "脚本返回的结果无效"
            case .requestFailed(let msg): return "脚本内 HTTP 请求失败：\(msg)"
            }
        }
    }

    // MARK: - 属性

    private let context: JSContext
    private let session: URLSession
    /// JSContext 专用串行队列：JSContext 非线程安全，所有 JS 调用必须在同一线程
    private let jsQueue = DispatchQueue(label: "lx.engine.jscontext")
    /// 脚本通过 `send(EVENT_NAMES.inited, { sources })` 声明的音源列表
    private(set) var sourceConfigs: [SourceConfig] = []
    /// 脚本注册的 request 事件处理器（由 `on(EVENT_NAMES.request, handler)` 设置）
    private var requestHandler: JSValue?
    /// 脚本是否已完成初始化（收到 inited 事件）
    /// 使用 DispatchSemaphore 保证线程安全：脚本同步执行 send(inited) 时可立即触发
    private let initSemaphore = DispatchSemaphore(value: 0)
    private var didInit = false
    /// setTimeout 定时器管理
    private var timers: [Int: DispatchSourceTimer] = [:]
    private var nextTimerID = 1

    // MARK: - 初始化

    private init(script: String) throws {
        guard let context = JSContext() else {
            throw EngineError.scriptLoadFailed("无法创建 JSContext")
        }
        self.context = context
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)

        setupGlobalEnvironment()
        setupExceptionHandler()

        // 设置 currentScriptInfo.rawScript 及元数据（部分脚本从中解析 @wy_token 等）
        if let lx = context.objectForKeyedSubscript("lx"),
           let scriptInfo = lx.objectForKeyedSubscript("currentScriptInfo") {
            scriptInfo.setObject(script, forKeyedSubscript: "rawScript" as NSCopying & NSObjectProtocol)
            // 从注释中解析 @name/@version/@author/@description/@homepage
            let meta = LXScriptEngine.parseScriptMeta(script)
            scriptInfo.setObject(meta.name, forKeyedSubscript: "name" as NSCopying & NSObjectProtocol)
            scriptInfo.setObject(meta.description, forKeyedSubscript: "description" as NSCopying & NSObjectProtocol)
            scriptInfo.setObject(meta.version, forKeyedSubscript: "version" as NSCopying & NSObjectProtocol)
            scriptInfo.setObject(meta.author, forKeyedSubscript: "author" as NSCopying & NSObjectProtocol)
            scriptInfo.setObject(meta.homepage, forKeyedSubscript: "homepage" as NSCopying & NSObjectProtocol)
        }

        // 执行脚本
        // 注意：不能仅凭 context.exception 判定脚本加载失败——
        // 某些脚本的 IIFE 内部会触发非致命 JS 异常（如 typeof process、
        // atob 调用等），但这些异常不影响脚本注册 on(request) 和 send(inited)。
        // 只有当脚本执行后既未完成初始化、又没有任何 request handler 时才认为失败。
        _ = context.evaluateScript(script)
        if let exception = context.exception {
            // 记录异常详情但不再阻止脚本运行
            let stack = exception.objectForKeyedSubscript("stack")?.toString() ?? ""
            let line = exception.objectForKeyedSubscript("line")?.toString() ?? ""
            BeansLogger.shared.log("LX脚本执行异常：\(exception.toString() ?? "未知") 行=\(line) 堆栈=\(stack)", level: .debug)
        }

        // 脚本可能同步调用 send(inited)（semaphore 已 signal）
        // 也可能异步调用（需在 load 中等待）
        if didInit {
            return
        }
    }

    /// 加载并初始化一个 LX Music 脚本
    static func load(script: String) async throws -> LXScriptEngine {
        let engine = try LXScriptEngine(script: script)

        // 脚本在 evaluateScript 期间可能已同步调用 send(inited)
        if engine.didInit {
            return engine
        }

        // 异步初始化：等待脚本调用 send(inited)，最多等 10 秒
        // 某些脚本初始化时需要先发起网络请求（如获取服务端配置），3 秒不够
        let result = engine.initSemaphore.wait(timeout: .now() + 10)
        guard result == .success, engine.didInit else {
            // 区分超时和未注册 handler 两种情况
            if engine.requestHandler == nil {
                throw EngineError.scriptLoadFailed("脚本未注册 musicUrl 处理器，可能不兼容 LX Music 规范")
            }
            throw EngineError.scriptLoadFailed("脚本未在规定时间内完成初始化（10 秒超时）")
        }
        return engine
    }

    // MARK: - 全局环境注入

    /// 在 JSContext 中构建 `globalThis.lx` 对象，提供 LX Music 脚本运行所需的 API
    private func setupGlobalEnvironment() {
        let lx = JSValue(newObjectIn: context)!

        // EVENT_NAMES：脚本通过 lx.EVENT_NAMES.request / lx.EVENT_NAMES.inited 访问事件名
        let eventNames = JSValue(newObjectIn: context)!
        eventNames.setObject("request", forKeyedSubscript: "request" as NSCopying & NSObjectProtocol)
        eventNames.setObject("inited", forKeyedSubscript: "inited" as NSCopying & NSObjectProtocol)
        lx.setObject(eventNames, forKeyedSubscript: "EVENT_NAMES" as NSCopying & NSObjectProtocol)

        // request(url, options, callback)：脚本发起 HTTP 请求的 API
        // callback(err, res)，res = { statusCode, headers, body }
        // options = { method, headers, body, timeout, follow_max }
        let requestBlock: @convention(block) (String, JSValue, JSValue) -> Void = { [weak self] urlString, options, callback in
            self?.handleRequest(urlString: urlString, options: options, callback: callback)
        }
        lx.setObject(requestBlock, forKeyedSubscript: "request" as NSCopying & NSObjectProtocol)

        // on(eventName, handler)：注册事件处理回调
        let onBlock: @convention(block) (JSValue, JSValue) -> Void = { [weak self] eventName, handler in
            guard let self else { return }
            let name = eventName.toString()
            if name == "request" {
                self.requestHandler = handler
            }
        }
        lx.setObject(onBlock, forKeyedSubscript: "on" as NSCopying & NSObjectProtocol)

        // send(eventName, data)：脚本通知宿主事件
        let sendBlock: @convention(block) (JSValue, JSValue) -> Void = { [weak self] eventName, data in
            guard let self else { return }
            let name = eventName.toString()
            if name == "inited" {
                self.handleInited(data: data)
            }
        }
        lx.setObject(sendBlock, forKeyedSubscript: "send" as NSCopying & NSObjectProtocol)

        // version / env：部分脚本会读取这些属性做兼容性判断
        lx.setObject("2.0.0", forKeyedSubscript: "version" as NSCopying & NSObjectProtocol)
        lx.setObject("mobile", forKeyedSubscript: "ENV" as NSCopying & NSObjectProtocol)
        lx.setObject("mobile", forKeyedSubscript: "env" as NSCopying & NSObjectProtocol)

        // utils：crypto / buffer / zlib，供官方源脚本（如 wy.js 的 eapi 加密）使用
        let utils = JSValue(newObjectIn: context)!
        // crypto
        let crypto = JSValue(newObjectIn: context)!
        crypto.setObject(md5Block, forKeyedSubscript: "md5" as NSCopying & NSObjectProtocol)
        crypto.setObject(randomBytesBlock, forKeyedSubscript: "randomBytes" as NSCopying & NSObjectProtocol)
        crypto.setObject(aesEncryptBlock, forKeyedSubscript: "aesEncrypt" as NSCopying & NSObjectProtocol)
        crypto.setObject(rsaEncryptBlock, forKeyedSubscript: "rsaEncrypt" as NSCopying & NSObjectProtocol)
        utils.setObject(crypto, forKeyedSubscript: "crypto" as NSCopying & NSObjectProtocol)
        // buffer
        let buffer = JSValue(newObjectIn: context)!
        buffer.setObject(bufferFromBlock, forKeyedSubscript: "from" as NSCopying & NSObjectProtocol)
        buffer.setObject(bufToStringBlock, forKeyedSubscript: "bufToString" as NSCopying & NSObjectProtocol)
        utils.setObject(buffer, forKeyedSubscript: "buffer" as NSCopying & NSObjectProtocol)
        // zlib：best-effort，多数脚本不用
        let zlib = JSValue(newObjectIn: context)!
        utils.setObject(zlib, forKeyedSubscript: "zlib" as NSCopying & NSObjectProtocol)
        lx.setObject(utils, forKeyedSubscript: "utils" as NSCopying & NSObjectProtocol)

        // currentScriptInfo：部分脚本从 rawScript 里解析 @wy_token 等
        let scriptInfo = JSValue(newObjectIn: context)!
        scriptInfo.setObject("", forKeyedSubscript: "name" as NSCopying & NSObjectProtocol)
        scriptInfo.setObject("", forKeyedSubscript: "description" as NSCopying & NSObjectProtocol)
        scriptInfo.setObject("", forKeyedSubscript: "version" as NSCopying & NSObjectProtocol)
        scriptInfo.setObject("", forKeyedSubscript: "author" as NSCopying & NSObjectProtocol)
        scriptInfo.setObject("", forKeyedSubscript: "homepage" as NSCopying & NSObjectProtocol)
        // rawScript 稍后在 evaluateScript 后设置（此时还没 script 属性）
        lx.setObject(scriptInfo, forKeyedSubscript: "currentScriptInfo" as NSCopying & NSObjectProtocol)

        // 注入到 globalThis
        context.setObject(lx, forKeyedSubscript: "lx" as NSCopying & NSObjectProtocol)

        // 注入常用全局 API（JavaScriptCore 默认缺失这些）
        setupGlobalHelpers()
    }

    /// 注入 setTimeout / atob / btoa / console 等脚本常用全局 API
    private func setupGlobalHelpers() {
        // setTimeout / setInterval：脚本常用于异步操作（如延迟初始化）
        let setTimeoutBlock: @convention(block) (JSValue, JSValue) -> Int = { [weak self] callback, delay in
            guard let self else { return 0 }
            let ms = delay.isNumber ? Int(delay.toDouble()) : 0
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + .milliseconds(ms))
            let token = self.nextTimerID
            self.nextTimerID += 1
            self.timers[token] = timer
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.jsQueue.async {
                    guard self.timers[token] != nil else { return }
                    callback.call(withArguments: [])
                }
            }
            timer.resume()
            return token
        }
        context.setObject(setTimeoutBlock, forKeyedSubscript: "setTimeout" as NSCopying & NSObjectProtocol)

        let clearTimeoutBlock: @convention(block) (Int) -> Void = { [weak self] token in
            self?.timers[token]?.cancel()
            self?.timers.removeValue(forKey: token)
        }
        context.setObject(clearTimeoutBlock, forKeyedSubscript: "clearTimeout" as NSCopying & NSObjectProtocol)

        // atob / btoa：Base64 编解码
        let atobBlock: @convention(block) (String) -> String = { encoded in
            let data = Data(base64Encoded: encoded) ?? Data()
            return String(data: data, encoding: .ascii) ?? ""
        }
        context.setObject(atobBlock, forKeyedSubscript: "atob" as NSCopying & NSObjectProtocol)

        let btoaBlock: @convention(block) (String) -> String = { str in
            return Data(str.utf8).base64EncodedString()
        }
        context.setObject(btoaBlock, forKeyedSubscript: "btoa" as NSCopying & NSObjectProtocol)

        // console：best-effort 日志，避免脚本访问 console.log 时报错
        let console = JSValue(newObjectIn: context)!
        let logBlock: @convention(block) (JSValue) -> Void = { msg in
            BeansLogger.shared.log("LX脚本 console：\(msg.toString() ?? "")", level: .debug)
        }
        console.setObject(logBlock, forKeyedSubscript: "log" as NSCopying & NSObjectProtocol)
        console.setObject(logBlock, forKeyedSubscript: "info" as NSCopying & NSObjectProtocol)
        console.setObject(logBlock, forKeyedSubscript: "warn" as NSCopying & NSObjectProtocol)
        console.setObject(logBlock, forKeyedSubscript: "error" as NSCopying & NSObjectProtocol)
        context.setObject(console, forKeyedSubscript: "console" as NSCopying & NSObjectProtocol)
    }

    /// 捕获 JS 执行异常，输出到日志（不阻止脚本继续运行）
    private func setupExceptionHandler() {
        context.exceptionHandler = { _, exception in
            let message = exception?.toString() ?? "未知 JS 异常"
            BeansLogger.shared.log("LX脚本异常：\(message)", level: .debug)
        }
    }

    // MARK: - utils block 实现

    /// MD5 hex 摘要：桥接到 CommonCrypto
    private lazy var md5Block: @convention(block) (String) -> String = { input in
        return LXScriptEngine.md5Hex(input)
    }

    /// 随机字节：返回 [UInt8]
    private lazy var randomBytesBlock: @convention(block) (Int) -> [UInt8] = { size in
        var bytes = [UInt8](repeating: 0, count: max(0, size))
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return bytes
    }

    /// AES 加密：best-effort，支持 ECB / CBC
    private lazy var aesEncryptBlock: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> [UInt8] = { data, mode, key, iv in
        let inputBytes = LXScriptEngine.jsValueToBytes(data)
        let keyBytes = LXScriptEngine.jsValueToBytes(key)
        let ivBytes = iv.isUndefined ? [] : LXScriptEngine.jsValueToBytes(iv)
        let modeStr = mode.isUndefined ? "aes-128-cbc" : (mode.toString() ?? "aes-128-cbc")
        if modeStr.contains("ecb") || ivBytes.isEmpty {
            return LXScriptEngine.aesECBEncrypt(input: inputBytes, key: keyBytes)
        }
        return LXScriptEngine.aesCBCEncrypt(input: inputBytes, key: keyBytes, iv: ivBytes)
    }

    /// RSA 加密：best-effort，返回空数组
    private lazy var rsaEncryptBlock: @convention(block) (JSValue, String) -> [UInt8] = { _, _ in
        return []
    }

    /// Buffer.from
    private lazy var bufferFromBlock: @convention(block) (JSValue, JSValue) -> [UInt8] = { input, encoding in
        if input.isArray {
            return input.toArray() as? [UInt8] ?? []
        }
        let str = input.toString() ?? ""
        if encoding.isString {
            let enc = encoding.toString() ?? ""
            if enc == "hex" {
                var bytes: [UInt8] = []
                var idx = str.startIndex
                while idx < str.endIndex {
                    let next = str.index(idx, offsetBy: 2, limitedBy: str.endIndex) ?? str.endIndex
                    if let b = UInt8(str[idx..<next], radix: 16) { bytes.append(b) }
                    idx = next
                }
                return bytes
            }
            if enc == "base64" {
                if let data = Data(base64Encoded: str) { return [UInt8](data) }
            }
        }
        return [UInt8](str.utf8)
    }

    /// Buffer → string
    private lazy var bufToStringBlock: @convention(block) ([UInt8], JSValue) -> String = { bytes, format in
        let data = Data(bytes)
        let fmt = format.isString ? (format.toString() ?? "") : ""
        if fmt == "hex" {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        if fmt == "base64" {
            return data.base64EncodedString()
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 事件处理

    /// 脚本调用 `send(EVENT_NAMES.inited, { sources })` 时解析音源声明
    private func handleInited(data: JSValue) {
        guard data.isObject else {
            didInit = true
            initSemaphore.signal()
            return
        }
        // sources 是 { "wy": { name, type, actions, qualitys }, ... } 的字典
        let sourcesValue = data.objectForKeyedSubscript("sources")
        if let sources = sourcesValue?.toObject() as? [String: Any] {
            var configs: [SourceConfig] = []
            for (id, raw) in sources {
                guard let dict = raw as? [String: Any] else { continue }
                let name = dict["name"] as? String ?? id
                let qualitys = (dict["qualitys"] as? [String]) ?? []
                configs.append(SourceConfig(id: id, name: name, qualitys: qualitys))
            }
            sourceConfigs = configs
        }
        didInit = true
        initSemaphore.signal()
    }

    /// 脚本调用 `request(url, options, callback)` 时，在 Swift 侧发起真实 HTTP 请求
    private func handleRequest(urlString: String, options: JSValue, callback: JSValue) {
        guard let url = URL(string: urlString) else {
            jsQueue.async { callback.call(withArguments: ["无效的 URL", NSNull()]) }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = options.objectForKeyedSubscript("timeout")?.toDouble() ?? 10

        // method
        let method = options.objectForKeyedSubscript("method")?.toString() ?? "GET"
        request.httpMethod = method

        // headers
        if let headers = options.objectForKeyedSubscript("headers")?.toObject() as? [String: String] {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // body：POST 时可能是字符串或对象
        if method.uppercased() != "GET" {
            if let body = options.objectForKeyedSubscript("body")?.toObject() {
                if let str = body as? String {
                    request.httpBody = str.data(using: .utf8)
                } else {
                    // 对象序列化为 JSON
                    if let data = try? JSONSerialization.data(withJSONObject: body) {
                        request.httpBody = data
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                }
            }
        }

        // follow_max：重定向跟随次数（默认跟随）
        // URLSession 默认跟随重定向，这里不额外处理

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error = error {
                self.jsQueue.async {
                    callback.call(withArguments: [error.localizedDescription, NSNull()])
                }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                self.jsQueue.async {
                    callback.call(withArguments: ["响应异常", NSNull()])
                }
                return
            }
            // 构造响应对象 { statusCode, headers, body }
            var resDict: [String: Any] = [:]
            resDict["statusCode"] = http.statusCode
            // headers 转为小写键的字典（LX 脚本习惯用小写 header 名）
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let s = value as? String {
                    headers[(key as? String ?? "").lowercased()] = s
                }
            }
            resDict["headers"] = headers
            // body：优先当字符串传回，脚本侧常做 JSON.parse
            if let data = data {
                let bodyString = String(data: data, encoding: .utf8) ?? ""
                resDict["body"] = bodyString
            } else {
                resDict["body"] = ""
            }
            self.jsQueue.async {
                callback.call(withArguments: [NSNull(), resDict])
            }
        }
        task.resume()
    }

    // MARK: - 公开 API

    /// 获取播放 URL：调用脚本注册的 musicUrl action
    /// - Parameters:
    ///   - source: 平台代码（wy / tx / kw / kg / mg）
    ///   - musicInfo: 歌曲信息（id / songmid / hash / name / singer 等）
    ///   - type: 音质（128k / 320k / flac / 24bit）
    /// - Returns: 播放 URL 字符串
    func getMusicURL(source: String, musicInfo: [String: Any], type: String) async throws -> String {
        guard let handler = requestHandler else {
            throw EngineError.noHandler
        }

        // 构造调用参数：{ action, source, info }
        let params: [String: Any] = [
            "action": "musicUrl",
            "source": source,
            "info": [
                "musicInfo": musicInfo,
                "type": type
            ]
        ]

        // LX Music 脚本的 request 事件处理器返回 Promise
        let result = try await callHandlerAsync(handler, arguments: [params])

        // 结果应该是 URL 字符串，但兼容多种返回格式
        // 1. 直接字符串
        if let url = result as? String, !url.isEmpty {
            return url
        }
        // 2. JSValue 转字符串
        if let jsValue = result as? JSValue, let url = jsValue.toString(), !url.isEmpty, url != "[object Object]" {
            return url
        }
        // 3. 字典中取 url / data / data.url 等常见字段
        if let dict = result as? [String: Any] {
            for key in ["url", "data", "musicUrl", "playUrl", "link"] {
                if let url = dict[key] as? String, !url.isEmpty {
                    return url
                }
                if let inner = dict[key] as? [String: Any], let url = inner["url"] as? String, !url.isEmpty {
                    return url
                }
            }
        }
        if let jsValue = result as? JSValue, let dict = jsValue.toObject() as? [String: Any] {
            for key in ["url", "data", "musicUrl", "playUrl", "link"] {
                if let url = dict[key] as? String, !url.isEmpty {
                    return url
                }
                if let inner = dict[key] as? [String: Any], let url = inner["url"] as? String, !url.isEmpty {
                    return url
                }
            }
        }
        throw EngineError.invalidResult
    }

    /// 获取歌词：调用脚本注册的 lyric action
    func getLyric(source: String, musicInfo: [String: Any]) async throws -> String {
        guard let handler = requestHandler else {
            throw EngineError.noHandler
        }
        let params: [String: Any] = [
            "action": "lyric",
            "source": source,
            "info": ["musicInfo": musicInfo]
        ]
        let result = try await callHandlerAsync(handler, arguments: [params])
        if let dict = result as? [String: Any], let lyric = dict["lyric"] as? String {
            return lyric
        }
        if let jsValue = result as? JSValue,
           let dict = jsValue.toObject() as? [String: Any],
           let lyric = dict["lyric"] as? String {
            return lyric
        }
        return ""
    }

    /// 脚本是否支持指定的 action 和平台
    func supports(action: String, source: String) -> Bool {
        // 通过脚本声明的 sources 配置判断
        // 如果脚本声明了 sources 且包含该 source，则认为支持
        if sourceConfigs.isEmpty { return true } // 未声明则不限
        return sourceConfigs.contains { $0.id == source }
    }

    // MARK: - JSValue → Swift Promise 桥接

    /// 调用返回 Promise 的 JS 函数，将结果转为 Swift 值
    private func callHandlerAsync(_ handler: JSValue, arguments: [Any]) async throws -> Any {
        return try await withCheckedThrowingContinuation { continuation in
            self.jsQueue.async {
                // 创建 JS Promise 的 then/catch 回调
                let resolveBlock: @convention(block) (JSValue) -> Void = { value in
                    continuation.resume(returning: value)
                }
                let rejectBlock: @convention(block) (JSValue) -> Void = { error in
                    let message = error.toString() ?? "未知错误"
                    continuation.resume(throwing: EngineError.handlerThrew(message))
                }

                // 调用 handler(params)，期望返回 Promise
                guard let result = handler.call(withArguments: arguments) else {
                    continuation.resume(throwing: EngineError.handlerThrew("处理器返回空值"))
                    return
                }

                // 如果直接返回字符串（非 Promise），直接返回
                if result.isString {
                    continuation.resume(returning: result.toString() ?? "")
                    return
                }

                // 如果返回对象，检查是否是 Promise（有 .then 方法）
                if result.hasProperty("then") {
                    result.invokeMethod("then", withArguments: [
                        JSValue(object: resolveBlock, in: self.context)!,
                        JSValue(object: rejectBlock, in: self.context)!
                    ])
                } else {
                    // 非 Promise，直接作为结果返回
                    continuation.resume(returning: result.toObject() ?? "")
                }
            }
        }
    }

    // MARK: - 脚本缓存

    /// 脚本引擎缓存：同一脚本内容复用同一引擎实例，避免重复初始化
    private static var engineCache: [String: LXScriptEngine] = [:]
    private static let cacheQueue = DispatchQueue(label: "lx.engine.cache")

    /// 获取或创建脚本引擎（带缓存）
    static func cachedEngine(for script: String) async throws -> LXScriptEngine {
        let cacheKey = script.stableHashKey
        // 先查缓存
        if let cached = cacheQueue.sync(execute: { engineCache[cacheKey] }) {
            return cached
        }
        // 创建新引擎
        let engine = try await load(script: script)
        cacheQueue.sync { engineCache[cacheKey] = engine }
        return engine
    }

    /// 清除所有缓存的引擎
    static func clearCache() {
        cacheQueue.sync { engineCache.removeAll() }
    }
}

// MARK: - String 扩展

private extension String {
    /// 稳定的哈希键，用于引擎缓存
    var stableHashKey: String {
        String(self.hashValue)
    }
}

// MARK: - LXScriptEngine 静态辅助

extension LXScriptEngine {

    /// 脚本元数据
    struct ScriptMeta {
        var name: String = ""
        var description: String = ""
        var version: String = ""
        var author: String = ""
        var homepage: String = ""
    }

    /// 从脚本注释头解析 @name/@version/@author/@description/@homepage
    static func parseScriptMeta(_ script: String) -> ScriptMeta {
        var meta = ScriptMeta()
        // 匹配首个块注释
        guard let commentRange = script.range(of: "^/\\*(?:.|\\n)+?\\*/", options: [.regularExpression]) else {
            return meta
        }
        let comment = String(script[commentRange])
        let fields: [(WritableKeyPath<ScriptMeta, String>, String)] = [
            (\.name, "name"), (\.description, "description"),
            (\.version, "version"), (\.author, "author"), (\.homepage, "homepage"),
        ]
        for (keyPath, field) in fields {
            let pattern = "@\(field)[:\\s]+([^\\*\\n]+)"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: comment, range: NSRange(comment.startIndex..., in: comment)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: comment) {
                let value = String(comment[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    meta[keyPath: keyPath] = value
                }
            }
        }
        return meta
    }

    /// MD5 hex 摘要（CommonCrypto）
    static func md5Hex(_ string: String) -> String {
        let data = Array(string.utf8)
        var digest = [UInt8](repeating: 0, count: 16)
        data.withUnsafeBufferPointer { ptr in
            _ = CC_MD5(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// JSValue 转为 [UInt8]
    static func jsValueToBytes(_ value: JSValue) -> [UInt8] {
        if value.isString {
            return [UInt8]((value.toString() ?? "").utf8)
        }
        if value.isArray {
            return (value.toArray() as? [UInt8]) ?? []
        }
        return []
    }

    /// AES-ECB 加密（CommonCrypto，PKCS7 Padding）
    static func aesECBEncrypt(input: [UInt8], key: [UInt8]) -> [UInt8] {
        guard !key.isEmpty else { return [] }
        let keyLen = kKeyLenForAES(key: key)
        // PKCS7 padding
        let blockSize = kCCBlockSizeAES128
        let padded = pkcs7Pad(input: input, blockSize: blockSize)
        var output = [UInt8](repeating: 0, count: padded.count + blockSize)
        var outLen = 0
        let status = key.withUnsafeBufferPointer { keyPtr in
            padded.withUnsafeBufferPointer { dataPtr in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    keyPtr.baseAddress, keyLen,
                    nil,
                    dataPtr.baseAddress, padded.count,
                    &output, output.count, &outLen
                )
            }
        }
        guard status == kCCSuccess else { return [] }
        return Array(output.prefix(outLen))
    }

    /// AES-CBC 加密（CommonCrypto，PKCS7 Padding）
    static func aesCBCEncrypt(input: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        guard !key.isEmpty, !iv.isEmpty else { return [] }
        let keyLen = kKeyLenForAES(key: key)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = key.withUnsafeBufferPointer { keyPtr in
            iv.withUnsafeBufferPointer { ivPtr in
                input.withUnsafeBufferPointer { dataPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, keyLen,
                        ivPtr.baseAddress,
                        dataPtr.baseAddress, input.count,
                        &output, output.count, &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else { return [] }
        return Array(output.prefix(outLen))
    }

    /// 根据 key 长度选择 AES 密钥位宽（16/24/32 → 128/192/256）
    private static func kKeyLenForAES(key: [UInt8]) -> Int {
        switch key.count {
        case 16: return kCCKeySizeAES128
        case 24: return kCCKeySizeAES192
        case 32: return kCCKeySizeAES256
        default: return kCCKeySizeAES128
        }
    }

    /// PKCS7 填充
    private static func pkcs7Pad(input: [UInt8], blockSize: Int) -> [UInt8] {
        let padLen = blockSize - (input.count % blockSize)
        return input + [UInt8](repeating: UInt8(padLen), count: padLen)
    }
}
