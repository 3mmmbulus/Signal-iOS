//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 抓取失败的类别。日志只记这个（§6.5：不记完整 URL，更不记 `#` 片段），不带主机名、不带底层错误的描述。
public enum TellomiLinkFetchError: Error, Equatable, Sendable {
    /// 不是 https
    case schemeNotAllowed
    /// URL 形状不合法（带用户名密码、主机名不合法……）
    case shapeNotAllowed
    /// 主机是私网地址或解析到私网地址
    case blockedAddress
    /// 本机可达性记录里有这个 host：没发请求
    case knownUnreachable
    /// 这条链接的预算（总时间、请求数）用完了：没发请求
    case budgetExhausted
    /// 超过 5 跳重定向
    case tooManyRedirects
    /// HTTP 非 2xx（短链步骤：非 3xx）
    case httpStatus(Int)
    /// `Content-Type` 不在这一步的白名单里
    case contentTypeNotAllowed
    /// 解压后超过体积上限
    case tooLarge
    case timeout
    /// 网络层失败（已写进可达性记录）
    case network
    /// 短链步骤：响应里没有可用的 `Location`
    case missingLocation
    /// 还没同意跨境告知，一个请求都不发（tellomi/tellomi#1133）
    case blockedByConsent
    case cancelled
    case other

    /// 给日志用的类别名。
    public var logCategory: String {
        switch self {
        case .schemeNotAllowed: return "scheme"
        case .shapeNotAllowed: return "shape"
        case .blockedAddress: return "blocked-address"
        case .knownUnreachable: return "known-unreachable"
        case .budgetExhausted: return "budget"
        case .tooManyRedirects: return "too-many-redirects"
        case .httpStatus(let status): return "http-\(status)"
        case .contentTypeNotAllowed: return "content-type"
        case .tooLarge: return "too-large"
        case .timeout: return "timeout"
        case .network: return "network"
        case .missingLocation: return "missing-location"
        case .blockedByConsent: return "consent"
        case .cancelled: return "cancelled"
        case .other: return "other"
        }
    }
}

/// 每条链接一份：总时间 10 s、最多 3 个元数据请求（短链展开算 1 个）+ 1 个图片请求（§4.4）。
/// 在发请求**之前**扣；扣不动就不发。一个请求连同它的重定向算一次。
public final class TellomiLinkFetchBudget: @unchecked Sendable {
    public let deadline: Date
    private let maxMetadataRequests: Int
    private let maxImageRequests: Int
    private let lock = NSLock()
    private var metadataRequests = 0
    private var imageRequests = 0

    init(deadline: Date, maxMetadataRequests: Int, maxImageRequests: Int) {
        self.deadline = deadline
        self.maxMetadataRequests = maxMetadataRequests
        self.maxImageRequests = maxImageRequests
    }

    public var metadataRequestsUsed: Int {
        lock.lock()
        defer { lock.unlock() }
        return metadataRequests
    }

    public var imageRequestsUsed: Int {
        lock.lock()
        defer { lock.unlock() }
        return imageRequests
    }

    func consume(_ step: TellomiLinkFetchStep, now: Date) throws(TellomiLinkFetchError) {
        lock.lock()
        defer { lock.unlock() }
        guard now < deadline else {
            throw .budgetExhausted
        }
        if step.isImageRequest {
            guard imageRequests < maxImageRequests else { throw .budgetExhausted }
            imageRequests += 1
        } else {
            guard metadataRequests < maxMetadataRequests else { throw .budgetExhausted }
            metadataRequests += 1
        }
    }
}

/// 发送端的安全抓取器（§4.4 契约；§4.10：`rust/links` 不联网，决定抓什么以后由各端的这个抓取器去抓）。
///
/// 与上游 `LinkPreviewFetcherImpl` 原来经 `OWSURLSession` 的做法相比：
/// - 请求头只有 `User-Agent`（`WhatsApp/2`）、`Accept`、`Accept-Encoding`，外加一个盖掉 CFNetwork 自动语言列表的中性
///   `Accept-Language`（见 `TellomiLinkFetchContract.neutralAcceptLanguage`）；上游会经 `addDefaultHeaders()` 带上用户的语言列表；
/// - 完全不存、不发 cookie；
/// - 重定向自己跟：最多 5 跳，每跳重做 https / 形状 / 私网校验和可达性记录检查；
/// - 连接 5 s、单个请求 10 s、每条链接 10 s 且最多 3 + 1 个请求；
/// - 按步骤的 `Content-Type` 白名单；按解压后字节数计的体积上限，边读边计：JSON / 图片超了就断，HTML 超了只留开头 2 MiB 照常解析（§4.4）；
/// - 短链只读 `Location`，不读正文、不跟随；
/// - 网络层**明确**失败（DNS、连接被拒 / 被重置、TLS）写本机可达性记录，同一 host 之后不再发请求；超时不写。
public final class TellomiLinkFetcher: @unchecked Sendable {

    public struct Configuration: Sendable {
        public var connectTimeout: TimeInterval
        public var requestTimeout: TimeInterval
        public var perLinkBudget: TimeInterval
        public var maxRedirects: Int
        public var maxMetadataRequests: Int
        public var maxImageRequests: Int
        public var maxHtmlBytes: Int
        public var maxJsonBytes: Int
        public var maxImageBytes: Int

        public static let contract = Configuration(
            connectTimeout: TellomiLinkFetchContract.connectTimeout,
            requestTimeout: TellomiLinkFetchContract.requestTimeout,
            perLinkBudget: TellomiLinkFetchContract.perLinkBudget,
            maxRedirects: TellomiLinkFetchContract.maxRedirectsPerRequest,
            maxMetadataRequests: TellomiLinkFetchContract.maxMetadataRequestsPerLink,
            maxImageRequests: TellomiLinkFetchContract.maxImageRequestsPerLink,
            maxHtmlBytes: TellomiLinkFetchContract.maxHtmlBytes,
            maxJsonBytes: TellomiLinkFetchContract.maxJsonBytes,
            maxImageBytes: TellomiLinkFetchContract.maxImageBytes,
        )

        func maxBytes(for kind: TellomiLinkFetchBodyKind) -> Int {
            switch kind {
            case .html: return maxHtmlBytes
            case .json: return maxJsonBytes
            case .image: return maxImageBytes
            }
        }
    }

    public struct Response: Sendable {
        /// 跟完重定向以后的地址（结构化步骤要拿它核「还在不在同一个 provider」，§4.4）。
        public let finalUrl: URL
        public let mimeType: String
        public let kind: TellomiLinkFetchBodyKind
        /// 解压后的正文。
        public let body: Data
        public let redirectCount: Int
        /// HTML 超过上限、只读了开头 `maxHtmlBytes` 字节（§4.4：OG 标签都在 `<head>` 里，靠前）。
        public let isTruncated: Bool
        let stringEncoding: String.Encoding

        public var bodyString: String? {
            return String(data: body, encoding: stringEncoding)
        }
    }

    public static let shared = TellomiLinkFetcher()

    public let configuration: Configuration
    private let urlGuard: TellomiLinkURLGuard
    public let reachability: TellomiLinkReachability
    private let now: @Sendable () -> Date

    public init(
        configuration: Configuration = .contract,
        urlGuard: TellomiLinkURLGuard = .production,
        reachability: TellomiLinkReachability = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.configuration = configuration
        self.urlGuard = urlGuard
        self.reachability = reachability
        self.now = now
    }

    public func makeBudget() -> TellomiLinkFetchBudget {
        return TellomiLinkFetchBudget(
            deadline: now().addingTimeInterval(configuration.perLinkBudget),
            maxMetadataRequests: configuration.maxMetadataRequests,
            maxImageRequests: configuration.maxImageRequests,
        )
    }

    // MARK: - 抓取

    /// 抓一个资源（页面 / JSON / 图片），跟重定向。短链用 `expandShortLink`。
    public func fetch(
        _ url: URL,
        step: TellomiLinkFetchStep,
        budget: TellomiLinkFetchBudget,
    ) async throws(TellomiLinkFetchError) -> Response {
        guard step != .shortLink else {
            throw .other
        }
        try preflight()
        // 先做不联网的检查（scheme、形状、可达性记录），扣得动预算再去解析，扣不动就连 DNS 都不查
        try validateWithoutNetwork(url)
        try budget.consume(step, now: now())
        try await validateAddress(url)

        let deadline = min(now().addingTimeInterval(configuration.requestTimeout), budget.deadline)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        var currentUrl = url
        var redirectCount = 0
        while true {
            switch try await performHop(session: session, url: currentUrl, step: step, deadline: deadline) {
            case .body(let mimeType, let kind, let body, let isTruncated, let encoding):
                return Response(
                    finalUrl: currentUrl,
                    mimeType: mimeType,
                    kind: kind,
                    body: body,
                    redirectCount: redirectCount,
                    isTruncated: isTruncated,
                    stringEncoding: encoding,
                )
            case .redirect(let location):
                guard let nextUrl = Self.resolveLocation(location, relativeTo: currentUrl) else {
                    throw .missingLocation
                }
                redirectCount += 1
                guard redirectCount <= configuration.maxRedirects else {
                    throw .tooManyRedirects
                }
                try validateWithoutNetwork(nextUrl)
                try await validateAddress(nextUrl)
                currentUrl = nextUrl
            }
        }
    }

    /// 短链展开：发一个请求，**不跟随**，只读 `Location`、不读正文（§4.4）。
    /// 返回的地址只用来识别（交给 Matcher），不在这里请求它；`http` 的 `Location` 也照样返回、绝不跟随（§6.3）。
    public func expandShortLink(
        _ url: URL,
        budget: TellomiLinkFetchBudget,
    ) async throws(TellomiLinkFetchError) -> URL {
        try preflight()
        try validateWithoutNetwork(url)
        try budget.consume(.shortLink, now: now())
        try await validateAddress(url)

        let deadline = min(now().addingTimeInterval(configuration.requestTimeout), budget.deadline)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        switch try await performHop(session: session, url: url, step: .shortLink, deadline: deadline) {
        case .redirect(let location):
            guard let target = Self.resolveLocation(location, relativeTo: url) else {
                throw .missingLocation
            }
            return target
        case .body:
            throw .missingLocation
        }
    }

    // MARK: - 校验

    private func preflight() throws(TellomiLinkFetchError) {
        // 与 OWSURLSession 同一道闸：同意跨境告知之前，URLSession 这一路一个请求都不发。
        guard !TellomiCrossBorderConsent.blocksNetwork else {
            throw .blockedByConsent
        }
    }

    /// 首跳和每一跳重定向：scheme / 形状、可达性记录（不联网）。
    private func validateWithoutNetwork(_ url: URL) throws(TellomiLinkFetchError) {
        switch urlGuard.checkShape(url) {
        case .allowed:
            break
        case .schemeNotAllowed:
            throw .schemeNotAllowed
        case .blockedAddress:
            throw .blockedAddress
        case .shapeNotAllowed, .unresolvable:
            throw .shapeNotAllowed
        }
        if reachability.isKnownUnreachable(host: url.host) {
            throw .knownUnreachable
        }
    }

    /// 首跳和每一跳重定向：解析以后的私网校验（§6.2）。
    private func validateAddress(_ url: URL) async throws(TellomiLinkFetchError) {
        switch await urlGuard.checkAddress(url) {
        case .allowed:
            break
        case .schemeNotAllowed:
            throw .schemeNotAllowed
        case .shapeNotAllowed:
            throw .shapeNotAllowed
        case .blockedAddress:
            throw .blockedAddress
        case .unresolvable:
            // DNS 失败是网络层失败
            reachability.recordNetworkFailure(host: url.host)
            throw .network
        }
    }

    static func resolveLocation(_ location: String?, relativeTo base: URL) -> URL? {
        guard let location = location?.trimmingCharacters(in: .whitespaces).nilIfEmpty else {
            return nil
        }
        return URL(string: location, relativeTo: base)?.absoluteURL
    }

    /// 哪些错误算「这个 host 在当前网络明确不可达」、要写可达性记录（ADR-0063 §4.4，产品经理 2026-10-19 定）：
    /// DNS 解析失败、连接被拒绝 / 被重置、TLS 握手失败（含证书不对，大陆网络对被封站点常见的 RST / 证书劫持）。
    /// **超时（连接超时、请求超时）一律不算**；没网（`notConnectedToInternet`）这类是设备的事，也不记在某个 host 头上。
    static func isDefiniteNetworkFailure(_ code: URLError.Code) -> Bool {
        switch code {
        case .cannotFindHost,
             .dnsLookupFailed,
             .cannotConnectToHost,
             .networkConnectionLost,
             .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }

    // MARK: - 一跳

    private enum HopResult {
        case body(mimeType: String, kind: TellomiLinkFetchBodyKind, body: Data, isTruncated: Bool, encoding: String.Encoding)
        case redirect(location: String?)
    }

    private func makeSession() -> URLSession {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        // 完全不存 cookie（§3.4.11 / §4.4）
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.httpAdditionalHeaders = nil
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.timeoutIntervalForRequest = configuration.connectTimeout
        sessionConfiguration.timeoutIntervalForResource = configuration.requestTimeout
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        return URLSession(configuration: sessionConfiguration, delegate: HopDelegate(), delegateQueue: delegateQueue)
    }

    private func buildRequest(url: URL, step: TellomiLinkFetchStep) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.connectTimeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(TellomiLinkFetchContract.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(step.acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(TellomiLinkFetchContract.acceptEncoding, forHTTPHeaderField: "Accept-Encoding")
        request.setValue(TellomiLinkFetchContract.neutralAcceptLanguage, forHTTPHeaderField: "Accept-Language")
        return request
    }

    private func performHop(
        session: URLSession,
        url: URL,
        step: TellomiLinkFetchStep,
        deadline: Date,
    ) async throws(TellomiLinkFetchError) -> HopResult {
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else {
            throw .timeout
        }
        guard let delegate = session.delegate as? HopDelegate else {
            throw .other
        }
        let request = buildRequest(url: url, step: step)
        let outcome = await delegate.run(
            request: request,
            in: session,
            step: step,
            configuration: configuration,
            timeout: remaining,
        )
        switch outcome {
        case .success(let result):
            return result
        case .failure(let failure):
            if failure.isNetworkLevel {
                reachability.recordNetworkFailure(host: url.host)
            }
            throw failure.error
        }
    }

    // MARK: - URLSession 代理（每个 session 一个，一次只跑一个任务）

    private struct HopFailure: Error {
        let error: TellomiLinkFetchError
        /// DNS / TCP / TLS 这一层失败、还没收到任何 HTTP 响应：写可达性记录
        let isNetworkLevel: Bool
    }

    private final class HopDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private final class TaskState {
            let step: TellomiLinkFetchStep
            let configuration: Configuration
            var continuation: CheckedContinuation<Result<HopResult, HopFailure>, Never>?
            var response: HTTPURLResponse?
            var kind: TellomiLinkFetchBodyKind?
            var body = Data()
            var failure: TellomiLinkFetchError?
            var isRedirect = false
            /// HTML 读满上限后主动断开：断开后的 cancel / 计时器都不算失败
            var isTruncated = false
            var isFinished = false

            init(step: TellomiLinkFetchStep, configuration: Configuration) {
                self.step = step
                self.configuration = configuration
            }
        }

        private let lock = NSLock()
        private var states = [Int: TaskState]()

        private func state(for task: URLSessionTask) -> TaskState? {
            lock.lock()
            defer { lock.unlock() }
            return states[task.taskIdentifier]
        }

        func run(
            request: URLRequest,
            in session: URLSession,
            step: TellomiLinkFetchStep,
            configuration: Configuration,
            timeout: TimeInterval,
        ) async -> Result<HopResult, HopFailure> {
            let task = session.dataTask(with: request)
            let state = TaskState(step: step, configuration: configuration)
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    state.continuation = continuation
                    states[task.taskIdentifier] = state
                    lock.unlock()
                    // 单个请求 10 s（与每条链接剩下的预算取小）：到点就断。
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                        self?.fail(task: task, with: .timeout)
                    }
                    task.resume()
                }
            } onCancel: {
                self.fail(task: task, with: .cancelled)
            }
        }

        private func fail(task: URLSessionTask, with error: TellomiLinkFetchError) {
            lock.lock()
            if let state = states[task.taskIdentifier], !state.isFinished, !state.isTruncated, state.failure == nil {
                state.failure = error
            }
            lock.unlock()
            task.cancel()
        }

        // 重定向不交给 URLSession 自动跟：3xx 当作响应交回来，由调用方校验下一跳后再发（每跳重建请求头）。
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void,
        ) {
            completionHandler(nil)
        }

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void,
        ) {
            guard let state = state(for: dataTask), let httpResponse = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return
            }
            // 在锁外调 completionHandler：取消可能同步走到 didCompleteWithError
            lock.lock()
            let disposition = Self.disposition(for: httpResponse, state: state)
            lock.unlock()
            completionHandler(disposition)
        }

        private static func disposition(for httpResponse: HTTPURLResponse, state: TaskState) -> URLSession.ResponseDisposition {
            state.response = httpResponse
            let status = httpResponse.statusCode

            if (300...399).contains(status) {
                // 不读 3xx 的正文，也不看它的 Set-Cookie
                state.isRedirect = true
                return .cancel
            }
            if state.step == .shortLink {
                state.failure = (200...299).contains(status) ? .missingLocation : .httpStatus(status)
                return .cancel
            }
            guard (200...299).contains(status) else {
                state.failure = .httpStatus(status)
                return .cancel
            }
            guard let kind = state.step.bodyKind(forMimeType: httpResponse.mimeType) else {
                state.failure = .contentTypeNotAllowed
                return .cancel
            }
            state.kind = kind
            // HTML 不因为大而放弃：只读开头（见 `didReceive`），所以不按 Content-Length 提前断
            if kind == .html {
                return .allow
            }
            // 没压缩时 Content-Length 就是解压后的长度，超了直接断；压缩的只能边读边计
            let contentEncoding = httpResponse.value(forHTTPHeaderField: "Content-Encoding")?.lowercased().trimmingCharacters(in: .whitespaces)
            let isIdentity = contentEncoding == nil || contentEncoding == "" || contentEncoding == "identity"
            if isIdentity, httpResponse.expectedContentLength > Int64(state.configuration.maxBytes(for: kind)) {
                state.failure = .tooLarge
                return .cancel
            }
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard let state = state(for: dataTask) else { return }
            lock.lock()
            guard state.failure == nil, !state.isTruncated, let kind = state.kind else {
                lock.unlock()
                return
            }
            // URLSession 交上来的是已经解压的字节：按解压后的数计
            let maxBytes = state.configuration.maxBytes(for: kind)
            if state.body.count + data.count > maxBytes, kind == .html {
                // HTML：留下开头正好 maxBytes 字节，断开连接，按成功交回（产品经理 2026-10-19 定，ADR-0063 §4.4）
                state.body.append(data.prefix(maxBytes - state.body.count))
                state.isTruncated = true
                lock.unlock()
                dataTask.cancel()
                return
            }
            if state.body.count + data.count > maxBytes {
                state.failure = .tooLarge
                lock.unlock()
                dataTask.cancel()
                return
            }
            state.body.append(data)
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            guard let state = states.removeValue(forKey: task.taskIdentifier), !state.isFinished else {
                lock.unlock()
                return
            }
            state.isFinished = true
            let continuation = state.continuation
            state.continuation = nil
            let result = Self.outcome(state: state, error: error)
            lock.unlock()
            continuation?.resume(returning: result)
        }

        private static func outcome(state: TaskState, error: Error?) -> Result<HopResult, HopFailure> {
            let gotResponse = state.response != nil
            if let failure = state.failure {
                // 自己的计时器到点（超时）不写可达性记录：超时不算「明确不可达」（ADR-0063 §4.4）
                return .failure(HopFailure(error: failure, isNetworkLevel: false))
            }
            if state.isRedirect, let response = state.response {
                return .success(.redirect(location: response.value(forHTTPHeaderField: "Location")))
            }
            // HTML 读满上限后是我们自己断的：带着开头这一段按成功交回
            if let error, !state.isTruncated {
                return .failure(classify(error, gotResponse: gotResponse))
            }
            guard let response = state.response, let kind = state.kind else {
                return .failure(HopFailure(error: .other, isNetworkLevel: false))
            }
            let encoding = response.textEncodingName.flatMap { name -> String.Encoding? in
                let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
                guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            } ?? .utf8
            return .success(.body(
                mimeType: response.mimeType?.lowercased() ?? "",
                kind: kind,
                body: state.body,
                isTruncated: state.isTruncated,
                encoding: encoding,
            ))
        }

        private static func classify(_ error: Error, gotResponse: Bool) -> HopFailure {
            guard let urlError = error as? URLError else {
                return HopFailure(error: .other, isNetworkLevel: false)
            }
            switch urlError.code {
            case .timedOut:
                return HopFailure(error: .timeout, isNetworkLevel: false)
            case .cancelled:
                return HopFailure(error: .cancelled, isNetworkLevel: false)
            default:
                // 已经收到响应再断的不算「这个 host 不可达」
                let isDefinite = TellomiLinkFetcher.isDefiniteNetworkFailure(urlError.code)
                return HopFailure(error: .network, isNetworkLevel: isDefinite && !gotResponse)
            }
        }
    }
}
