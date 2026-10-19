//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0063 §4.4 / §6.2 抓取器契约的平台层安全用例（§8.1 第 5、10 行；tellomi/tellomi#1423）。
/// 全部打本进程的 `TellomiLocalHTTPTestServer`（127.0.0.1），不出本机。
final class TellomiLinkFetcherTest: XCTestCase {

    private var servers = [TellomiLocalHTTPTestServer]()

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers.removeAll()
        super.tearDown()
    }

    // MARK: - 工具

    private func startServer(_ handler: @escaping TellomiLocalHTTPTestServer.Handler) async throws -> TellomiLocalHTTPTestServer {
        let server = try TellomiLocalHTTPTestServer(handler: handler)
        try await server.start()
        servers.append(server)
        return server
    }

    /// 测试用的解析：不碰真实 DNS。
    private struct FakeResolver: TellomiLinkHostResolving {
        var table: [String: [TellomiLinkIPAddress]] = [
            "public.tellomi-test.cn": [TellomiLinkIPAddress(literal: "93.184.216.34")!],
            "intranet.tellomi-test.cn": [TellomiLinkIPAddress(literal: "10.0.0.5")!],
            "fakeip.tellomi-test.cn": [TellomiLinkIPAddress(literal: "198.18.0.7")!],
            "dual.tellomi-test.cn": [TellomiLinkIPAddress(literal: "93.184.216.34")!, TellomiLinkIPAddress(literal: "fd00::1")!],
        ]

        func resolve(host: String) async -> TellomiLinkResolution {
            guard let addresses = table[host.lowercased()] else { return .failed }
            return .addresses(addresses)
        }
    }

    private final class CountingResolver: TellomiLinkHostResolving, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }

        private func recordCall() {
            lock.lock()
            _calls += 1
            lock.unlock()
        }

        func resolve(host: String) async -> TellomiLinkResolution {
            recordCall()
            return .failed
        }
    }

    /// 生产的校验，只把**这一个**测试服务的来源（`http://127.0.0.1:<port>`）当成「https + 公网」。其余一切照生产规则判。
    private func testingGuard(allowing server: TellomiLocalHTTPTestServer, resolver: any TellomiLinkHostResolving = FakeResolver()) -> TellomiLinkURLGuard {
        let port = Int(server.port)
        let isTestOrigin: @Sendable (URL) -> Bool = { url in
            url.scheme == "http" && url.host == "127.0.0.1" && url.port == port
        }
        let production = TellomiLinkURLGuard(resolver: resolver)
        return TellomiLinkURLGuard(
            checkShape: { url in isTestOrigin(url) ? .allowed : production.checkShape(url) },
            checkAddress: { url in isTestOrigin(url) ? .allowed : await production.checkAddress(url) },
        )
    }

    private func makeFetcher(
        server: TellomiLocalHTTPTestServer,
        configuration: TellomiLinkFetcher.Configuration = .contract,
        resolver: any TellomiLinkHostResolving = FakeResolver(),
        reachability: TellomiLinkReachability = TellomiLinkReachability(),
    ) -> TellomiLinkFetcher {
        return TellomiLinkFetcher(
            configuration: configuration,
            urlGuard: testingGuard(allowing: server, resolver: resolver),
            reachability: reachability,
        )
    }

    private func fastConfiguration(
        connectTimeout: TimeInterval = 0.5,
        requestTimeout: TimeInterval = 1.0,
        perLinkBudget: TimeInterval = 5,
    ) -> TellomiLinkFetcher.Configuration {
        var configuration = TellomiLinkFetcher.Configuration.contract
        configuration.connectTimeout = connectTimeout
        configuration.requestTimeout = requestTimeout
        configuration.perLinkBudget = perLinkBudget
        return configuration
    }

    private func expectFailure(
        _ expected: TellomiLinkFetchError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: () async throws -> Void,
    ) async {
        do {
            try await block()
            XCTFail("expected \(expected), got success", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TellomiLinkFetchError, expected, file: file, line: line)
        }
    }

    private static let page = "<html><head><title>ok</title><meta property=\"og:title\" content=\"Tellomi test\"></head><body>ok</body></html>"

    // MARK: - 契约数字

    /// rust/links 的 JSON 请求（`content_types`）列的四种：application/json、text/json、text/javascript、application/javascript（另加 `+json`）。
    /// iTunes 的查询接口回的就是 `text/javascript; charset=utf-8`——这里不收，App Store 链接在 iOS 上整条失败。
    func testTheJsonStepAcceptsTheContentTypesRustLinksAsksFor() {
        for mimeType in ["application/json", "text/json", "text/javascript", "application/javascript", "text/javascript; charset=utf-8", "APPLICATION/JSON", "application/ld+json"] {
            XCTAssertEqual(TellomiLinkFetchStep.json.bodyKind(forMimeType: mimeType.components(separatedBy: ";")[0]), .json, mimeType)
        }
        for mimeType in ["text/html", "text/plain", "application/xml", "image/png", "application/octet-stream"] {
            XCTAssertNil(TellomiLinkFetchStep.json.bodyKind(forMimeType: mimeType), mimeType)
        }
        // 页面步骤不因此多收 JS
        XCTAssertNil(TellomiLinkFetchStep.html.bodyKind(forMimeType: "text/javascript"))
        XCTAssertNil(TellomiLinkFetchStep.page.bodyKind(forMimeType: "application/json"))
    }

    func testContractNumbersMatchADR0063() {
        XCTAssertEqual(TellomiLinkFetchContract.userAgent, "WhatsApp/2")
        XCTAssertEqual(TellomiLinkFetchContract.maxRedirectsPerRequest, 5)
        XCTAssertEqual(TellomiLinkFetchContract.connectTimeout, 5)
        XCTAssertEqual(TellomiLinkFetchContract.requestTimeout, 10)
        XCTAssertEqual(TellomiLinkFetchContract.perLinkBudget, 10)
        XCTAssertEqual(TellomiLinkFetchContract.maxMetadataRequestsPerLink, 3)
        XCTAssertEqual(TellomiLinkFetchContract.maxImageRequestsPerLink, 1)
        XCTAssertEqual(TellomiLinkFetchContract.maxHtmlBytes, 2 * 1024 * 1024)
        XCTAssertEqual(TellomiLinkFetchContract.maxJsonBytes, 256 * 1024)
        XCTAssertEqual(TellomiLinkReachability.memoLifetime, 2 * 60)
        XCTAssertEqual(TellomiLinkRegionPrior.current, .global)
    }

    // MARK: - 请求头 / cookie

    func testWireHeadersAreOnlyTheContractOnes() async throws {
        let server = try await startServer { _ in .html(Self.page) }
        let fetcher = makeFetcher(server: server)

        let response = try await fetcher.fetch(server.url("/headers"), step: .page, budget: fetcher.makeBudget())
        XCTAssertEqual(response.kind, .html)

        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.header("User-Agent"), "WhatsApp/2")
        XCTAssertEqual(request.header("Accept"), TellomiLinkFetchStep.page.acceptHeader)
        XCTAssertEqual(request.header("Accept-Encoding"), "gzip, deflate, br")
        XCTAssertFalse(request.hasHeader("Cookie"))
        XCTAssertFalse(request.hasHeader("Referer"))
        // CFNetwork 会自己补系统语言列表；线上只能出现不含任何信息的 `*`
        XCTAssertEqual(request.header("Accept-Language"), "*")
        // 应用层的头只有契约里的几个；Host / Connection 是 HTTP/1.1 传输本身的
        let applicationHeaders = Set(request.headers.map { $0.name.lowercased() }).subtracting(["host", "connection"])
        XCTAssertEqual(applicationHeaders, ["user-agent", "accept", "accept-encoding", "accept-language"])
    }

    func testSetCookieOnRedirectIsNeitherStoredNorSent() async throws {
        let server = try await startServer { request in
            switch request.path {
            case "/cookie/start":
                return .redirect(to: "/cookie/landing", extraHeaders: [("Set-Cookie", "tracker=tellomi-cookie-canary; Path=/; Max-Age=3600")])
            case "/cookie/landing":
                return .html(Self.page, extraHeaders: [("Set-Cookie", "second=tellomi-cookie-canary-2; Path=/")])
            default:
                return .html(Self.page)
            }
        }
        let fetcher = makeFetcher(server: server)

        _ = try await fetcher.fetch(server.url("/cookie/start"), step: .page, budget: fetcher.makeBudget())
        _ = try await fetcher.fetch(server.url("/cookie/again"), step: .page, budget: fetcher.makeBudget())

        XCTAssertEqual(server.requests.map(\.path), ["/cookie/start", "/cookie/landing", "/cookie/again"])
        for request in server.requests {
            XCTAssertNil(request.header("Cookie"), request.path)
        }
        XCTAssertEqual(HTTPCookieStorage.shared.cookies(for: server.url("/"))?.count ?? 0, 0)
    }

    // MARK: - 重定向

    func testFollowsUpToFiveRedirects() async throws {
        let server = try await startServer { request in
            if request.path.hasPrefix("/hop/"), let n = Int(request.path.dropFirst("/hop/".count)) {
                return n < 5 ? .redirect(to: "/hop/\(n + 1)") : .redirect(to: "/final", status: 301)
            }
            return .html(Self.page)
        }
        let fetcher = makeFetcher(server: server)

        let response = try await fetcher.fetch(server.url("/hop/1"), step: .page, budget: fetcher.makeBudget())
        XCTAssertEqual(response.redirectCount, 5)
        XCTAssertEqual(response.finalUrl.path, "/final")
        XCTAssertEqual(server.requests.count, 6)
        // 每一跳都是新建的请求，头照样只有契约里的
        for request in server.requests {
            XCTAssertEqual(request.header("User-Agent"), "WhatsApp/2")
            XCTAssertNil(request.header("Cookie"))
        }
    }

    func testSixthRedirectIsRefused() async throws {
        let server = try await startServer { request in
            if request.path.hasPrefix("/hop/"), let n = Int(request.path.dropFirst("/hop/".count)) {
                return .redirect(to: "/hop/\(n + 1)")
            }
            return .html(Self.page)
        }
        let fetcher = makeFetcher(server: server)

        await expectFailure(.tooManyRedirects) {
            _ = try await fetcher.fetch(server.url("/hop/1"), step: .page, budget: fetcher.makeBudget())
        }
        // 首跳 + 跟了 5 跳；第 6 个 Location 不再请求
        XCTAssertEqual(server.requests.map(\.path), (1...6).map { "/hop/\($0)" })
    }

    func testRedirectToPrivateAddressIsRefusedBeforeConnecting() async throws {
        // 另起一个「内网服务」：被拦的话它一个连接都收不到
        let intranet = try await startServer { _ in .html("<html>internal</html>") }
        let targets = [
            "https://127.0.0.1:\(intranet.port)/admin",
            "https://10.0.0.1/",
            "https://100.64.0.1/",
            "https://169.254.169.254/latest/meta-data/",
            "https://172.16.0.1/",
            "https://192.168.1.1/",
            "https://0.0.0.0/",
            "https://intranet.tellomi-test.cn/", // 域名解析到 10.0.0.5
            "https://dual.tellomi-test.cn/", // 解析结果里有一个 ULA 地址
        ]
        let server = try await startServer { request in
            if request.path.hasPrefix("/to/"), let index = Int(request.path.dropFirst("/to/".count)) {
                return .redirect(to: targets[index])
            }
            return .html(Self.page)
        }
        let fetcher = makeFetcher(server: server)

        for index in targets.indices {
            await expectFailure(.blockedAddress) {
                _ = try await fetcher.fetch(server.url("/to/\(index)"), step: .page, budget: fetcher.makeBudget())
            }
        }
        XCTAssertEqual(intranet.connectionCount, 0)
        XCTAssertEqual(server.requests.count, targets.count)
    }

    func testRedirectToPlainHttpIsRefused() async throws {
        let server = try await startServer { request in
            request.path == "/downgrade" ? .redirect(to: "http://public.tellomi-test.cn/page") : .html(Self.page)
        }
        let fetcher = makeFetcher(server: server)

        await expectFailure(.schemeNotAllowed) {
            _ = try await fetcher.fetch(server.url("/downgrade"), step: .page, budget: fetcher.makeBudget())
        }
        XCTAssertEqual(server.requests.count, 1)
    }

    func testNonHttpsIsRefusedWithoutTouchingTheNetwork() async throws {
        let resolver = CountingResolver()
        let fetcher = TellomiLinkFetcher(urlGuard: TellomiLinkURLGuard(resolver: resolver), reachability: TellomiLinkReachability())
        let budget = fetcher.makeBudget()
        for rawUrl in ["http://www.tellomi-test.cn/", "ftp://www.tellomi-test.cn/file", "javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "tellomi://tell.cc/u"] {
            let url = try XCTUnwrap(URL(string: rawUrl))
            await expectFailure(.schemeNotAllowed) {
                _ = try await fetcher.fetch(url, step: .page, budget: budget)
            }
            await expectFailure(.schemeNotAllowed) {
                _ = try await fetcher.expandShortLink(url, budget: budget)
            }
        }
        XCTAssertEqual(resolver.calls, 0)
        XCTAssertEqual(budget.metadataRequestsUsed, 0)
    }

    // MARK: - 体积与类型

    /// 产品经理 2026-10-19 定（ADR-0063 §4.4）：HTML 超过 2 MiB 不放弃，只留开头 2 MiB 照常解析标题和图。
    func testOversizedHtmlIsTruncatedNotRefused() async throws {
        let head = "<html><head><meta property=\"og:title\" content=\"大页面\"></head><body>"
        var oversized = Data(head.utf8)
        oversized.append(Data(repeating: UInt8(ascii: "a"), count: TellomiLinkFetchContract.maxHtmlBytes + 1))
        let oversizedBody = oversized
        let server = try await startServer { request in
            let headers = [("Content-Type", "text/html")]
            switch request.path {
            case "/declared": return .response(status: 200, headers: headers, body: oversizedBody)
            case "/streamed": return .closeDelimited(status: 200, headers: headers, body: oversizedBody)
            default: return .html(Self.page)
            }
        }
        let fetcher = makeFetcher(server: server)

        for path in ["/declared", "/streamed"] {
            for step in [TellomiLinkFetchStep.page, .html] {
                let response = try await fetcher.fetch(server.url(path), step: step, budget: fetcher.makeBudget())
                XCTAssertEqual(response.kind, .html, path)
                XCTAssertTrue(response.isTruncated, path)
                XCTAssertEqual(response.body.count, TellomiLinkFetchContract.maxHtmlBytes, path)
                XCTAssertEqual(response.body.prefix(head.utf8.count), Data(head.utf8), path)
            }
        }
        // 没超的页面不标截断
        let small = try await fetcher.fetch(server.url("/small"), step: .page, budget: fetcher.makeBudget())
        XCTAssertFalse(small.isTruncated)
        XCTAssertEqual(small.bodyString, Self.page)
    }

    func testHtmlExactlyAtTheLimitIsNotTruncated() async throws {
        let exact = Data(repeating: UInt8(ascii: "a"), count: TellomiLinkFetchContract.maxHtmlBytes)
        let server = try await startServer { _ in .response(status: 200, headers: [("Content-Type", "text/html")], body: exact) }
        let fetcher = makeFetcher(server: server)

        let response = try await fetcher.fetch(server.url("/exact"), step: .html, budget: fetcher.makeBudget())
        XCTAssertFalse(response.isTruncated)
        XCTAssertEqual(response.body.count, TellomiLinkFetchContract.maxHtmlBytes)
    }

    func testOversizedImageIsStillRefused() async throws {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(count: TellomiLinkFetchContract.maxImageBytes))
        let pngBody = png
        let server = try await startServer { request in
            let headers = [("Content-Type", "image/png")]
            return request.path == "/declared"
                ? .response(status: 200, headers: headers, body: pngBody)
                : .closeDelimited(status: 200, headers: headers, body: pngBody)
        }
        let fetcher = makeFetcher(server: server)

        // 图片截了就是坏图：照旧超了就放弃（卡片没有图）
        await expectFailure(.tooLarge) {
            _ = try await fetcher.fetch(server.url("/declared"), step: .image, budget: fetcher.makeBudget())
        }
        await expectFailure(.tooLarge) {
            _ = try await fetcher.fetch(server.url("/streamed"), step: .image, budget: fetcher.makeBudget())
        }
    }

    func testGzipBombIsCutAtTheDecompressedLimit() async throws {
        // 16 MiB 的 0 压成十几 KB：按线上（压缩后）字节数算的上限拦不住它
        let bomb = try TellomiTestGzip.gzip(Data(count: 16 * 1024 * 1024))
        XCTAssertLessThan(bomb.count, TellomiLinkFetchContract.maxHtmlBytes / 16)
        let smallPage = try TellomiTestGzip.gzip(Data(Self.page.utf8))
        let server = try await startServer { request in
            let body = request.path == "/bomb" ? bomb : smallPage
            return .response(status: 200, headers: [("Content-Type", "text/html"), ("Content-Encoding", "gzip")], body: body)
        }
        let fetcher = makeFetcher(server: server)

        // 解压到 2 MiB 就停，只留开头（不会把 16 MiB 全解出来）
        let truncated = try await fetcher.fetch(server.url("/bomb"), step: .page, budget: fetcher.makeBudget())
        XCTAssertTrue(truncated.isTruncated)
        XCTAssertEqual(truncated.body.count, TellomiLinkFetchContract.maxHtmlBytes)
        // 正常的压缩页面照常解开（说明上限计的是解压后的字节）
        let response = try await fetcher.fetch(server.url("/small"), step: .page, budget: fetcher.makeBudget())
        XCTAssertEqual(response.bodyString, Self.page)
    }

    func testJsonLimitIs256KiB() async throws {
        @Sendable
        func json(bytes: Int) -> Data {
            // `{"filler":"` 11 个字节 + 填充 + `"}` 2 个字节 = 正好 `bytes`
            let filler = String(repeating: "x", count: bytes - 13)
            return Data("{\"filler\":\"\(filler)\"}".utf8)
        }
        let server = try await startServer { request in
            let body = request.path == "/big.json" ? json(bytes: 256 * 1024 + 1) : json(bytes: 256 * 1024)
            return .response(status: 200, headers: [("Content-Type", "application/json")], body: body)
        }
        let fetcher = makeFetcher(server: server)

        let ok = try await fetcher.fetch(server.url("/ok.json"), step: .json, budget: fetcher.makeBudget())
        XCTAssertEqual(ok.kind, .json)
        XCTAssertEqual(ok.body.count, 256 * 1024)
        await expectFailure(.tooLarge) {
            _ = try await fetcher.fetch(server.url("/big.json"), step: .json, budget: fetcher.makeBudget())
        }
    }

    func testContentTypeWhitelistIsPerStep() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let server = try await startServer { request in
            switch request.path {
            case "/plain": return .response(status: 200, headers: [("Content-Type", "text/plain")], body: Data("hi".utf8))
            case "/none": return .response(status: 200, headers: [], body: Data("hi".utf8))
            case "/png": return .response(status: 200, headers: [("Content-Type", "image/png")], body: png)
            case "/json": return .response(status: 200, headers: [("Content-Type", "application/json")], body: Data("{}".utf8))
            default: return .html(Self.page)
            }
        }
        let fetcher = makeFetcher(server: server)
        func fetch(_ path: String, _ step: TellomiLinkFetchStep) async throws -> TellomiLinkFetcher.Response {
            return try await fetcher.fetch(server.url(path), step: step, budget: fetcher.makeBudget())
        }

        await expectFailure(.contentTypeNotAllowed) { _ = try await fetch("/plain", .page) }
        await expectFailure(.contentTypeNotAllowed) { _ = try await fetch("/none", .page) }
        await expectFailure(.contentTypeNotAllowed) { _ = try await fetch("/json", .page) }
        await expectFailure(.contentTypeNotAllowed) { _ = try await fetch("/html", .json) }
        await expectFailure(.contentTypeNotAllowed) { _ = try await fetch("/png", .html) }
        await expectFailure(.contentTypeNotAllowed) { _ = try await fetch("/html", .image) }
        let html = try await fetch("/html", .html)
        XCTAssertEqual(html.kind, .html)
        let image = try await fetch("/png", .page)
        XCTAssertEqual(image.kind, .image)
        let json = try await fetch("/json", .json)
        XCTAssertEqual(json.kind, .json)
    }

    // MARK: - 超时与预算

    func testStalledServerTimesOut() async throws {
        let server = try await startServer { _ in .stall }
        let reachability = TellomiLinkReachability()
        let fetcher = makeFetcher(server: server, configuration: fastConfiguration(), reachability: reachability)

        let start = Date()
        await expectFailure(.timeout) {
            _ = try await fetcher.fetch(server.url("/stall"), step: .page, budget: fetcher.makeBudget())
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        // 连上了、只是不回：不算「这个 host 不可达」
        XCTAssertFalse(reachability.isKnownUnreachable(host: "127.0.0.1"))
    }

    func testPerLinkRequestCountBudget() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let server = try await startServer { request in
            switch request.path {
            case "/short": return .redirect(to: "/landing", status: 301)
            case "/img": return .response(status: 200, headers: [("Content-Type", "image/png")], body: png)
            default: return .html(Self.page)
            }
        }
        let fetcher = makeFetcher(server: server)
        let budget = fetcher.makeBudget()

        _ = try await fetcher.expandShortLink(server.url("/short"), budget: budget) // 短链展开算 1 个
        _ = try await fetcher.fetch(server.url("/a"), step: .page, budget: budget)
        _ = try await fetcher.fetch(server.url("/b"), step: .html, budget: budget)
        await expectFailure(.budgetExhausted) {
            _ = try await fetcher.fetch(server.url("/c"), step: .page, budget: budget)
        }
        _ = try await fetcher.fetch(server.url("/img"), step: .image, budget: budget)
        await expectFailure(.budgetExhausted) {
            _ = try await fetcher.fetch(server.url("/img"), step: .image, budget: budget)
        }
        XCTAssertEqual(server.requests.map(\.path), ["/short", "/a", "/b", "/img"])
    }

    func testPerLinkTimeBudget() async throws {
        let server = try await startServer { _ in .delayed(1.0, .html(Self.page)) }
        let fetcher = makeFetcher(
            server: server,
            configuration: fastConfiguration(connectTimeout: 5, requestTimeout: 10, perLinkBudget: 1.5),
        )
        let budget = fetcher.makeBudget()
        let start = Date()

        _ = try await fetcher.fetch(server.url("/1"), step: .page, budget: budget)
        // 第二个请求只剩 0.5 s
        await expectFailure(.timeout) {
            _ = try await fetcher.fetch(server.url("/2"), step: .page, budget: budget)
        }
        // 预算用完：第三个不发
        await expectFailure(.budgetExhausted) {
            _ = try await fetcher.fetch(server.url("/3"), step: .page, budget: budget)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(server.requests.map(\.path), ["/1", "/2"])
    }

    // MARK: - 可达性记录

    func testNetworkLevelFailureIsNotRetriedForTheSameHost() async throws {
        let server = try await startServer { request in request.path == "/drop" ? .drop : .html(Self.page) }
        let reachability = TellomiLinkReachability()
        let fetcher = makeFetcher(server: server, reachability: reachability)

        await expectFailure(.network) {
            _ = try await fetcher.fetch(server.url("/drop"), step: .page, budget: fetcher.makeBudget())
        }
        XCTAssertTrue(reachability.isKnownUnreachable(host: "127.0.0.1"))
        let connectionsAfterFailure = server.connectionCount

        // 同一个 host 的下一次（换路径、换一条链接的预算）：不再发请求
        await expectFailure(.knownUnreachable) {
            _ = try await fetcher.fetch(server.url("/other"), step: .page, budget: fetcher.makeBudget())
        }
        await expectFailure(.knownUnreachable) {
            _ = try await fetcher.expandShortLink(server.url("/short"), budget: fetcher.makeBudget())
        }
        XCTAssertEqual(server.connectionCount, connectionsAfterFailure)
        XCTAssertEqual(Set(server.requests.map(\.path)), ["/drop"])

        // 网络变化以后清空，可以再试
        reachability.clear()
        _ = try await fetcher.fetch(server.url("/other"), step: .page, budget: fetcher.makeBudget())
    }

    func testDnsFailureIsRecordedAndNotRetried() async throws {
        let server = try await startServer { request in
            request.path == "/to-unknown" ? .redirect(to: "https://unresolvable.tellomi-test.cn/") : .html(Self.page)
        }
        let reachability = TellomiLinkReachability()
        let fetcher = makeFetcher(server: server, reachability: reachability)

        await expectFailure(.network) {
            _ = try await fetcher.fetch(server.url("/to-unknown"), step: .page, budget: fetcher.makeBudget())
        }
        XCTAssertTrue(reachability.isKnownUnreachable(host: "unresolvable.tellomi-test.cn"))
        await expectFailure(.knownUnreachable) {
            _ = try await fetcher.fetch(server.url("/to-unknown"), step: .page, budget: fetcher.makeBudget())
        }
    }

    func testHttpErrorDoesNotMarkTheHost() async throws {
        let server = try await startServer { request in
            request.path == "/500" ? .html("oops", status: 500) : .html(Self.page)
        }
        let reachability = TellomiLinkReachability()
        let fetcher = makeFetcher(server: server, reachability: reachability)

        await expectFailure(.httpStatus(500)) {
            _ = try await fetcher.fetch(server.url("/500"), step: .page, budget: fetcher.makeBudget())
        }
        XCTAssertFalse(reachability.isKnownUnreachable(host: "127.0.0.1"))
        _ = try await fetcher.fetch(server.url("/ok"), step: .page, budget: fetcher.makeBudget())
    }

    /// 产品经理 2026-10-19 定（ADR-0063 §4.4）：只有明确失败才记；超时（连接超时、请求超时）不记。
    func testOnlyDefiniteNetworkFailuresAreRecorded() {
        for code: URLError.Code in [
            .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .networkConnectionLost,
            .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
        ] {
            XCTAssertTrue(TellomiLinkFetcher.isDefiniteNetworkFailure(code), "\(code.rawValue)")
        }
        for code: URLError.Code in [.timedOut, .notConnectedToInternet, .cancelled, .badServerResponse, .unknown] {
            XCTAssertFalse(TellomiLinkFetcher.isDefiniteNetworkFailure(code), "\(code.rawValue)")
        }
    }

    func testRequestTimeoutBeforeAnyResponseDoesNotMarkTheHost() async throws {
        // 连上了但一个字节都不回、自己的计时器到点：原来没收到响应也算「连接超时」写进记录，现在不写
        let server = try await startServer { _ in .stall }
        let reachability = TellomiLinkReachability()
        let fetcher = makeFetcher(
            server: server,
            configuration: fastConfiguration(connectTimeout: 0.5, requestTimeout: 0.8, perLinkBudget: 2),
            reachability: reachability,
        )

        await expectFailure(.timeout) {
            _ = try await fetcher.fetch(server.url("/stall"), step: .html, budget: fetcher.makeBudget())
        }
        XCTAssertFalse(reachability.isKnownUnreachable(host: "127.0.0.1"))
        XCTAssertEqual(reachability.unreachableHosts(), [])
    }

    func testReachabilityMemoLifetimeAndNetworkChange() {
        final class Clock: @unchecked Sendable {
            var now = Date(timeIntervalSince1970: 1_800_000_000)
        }
        let clock = Clock()
        let notificationCenter = NotificationCenter()
        let reachability = TellomiLinkReachability(
            now: { clock.now },
            clearsOnNetworkChange: true,
            notificationCenter: notificationCenter,
        )

        reachability.recordNetworkFailure(host: "Blocked.Example.CN")
        XCTAssertTrue(reachability.isKnownUnreachable(host: "blocked.example.cn"))
        clock.now += 119
        XCTAssertTrue(reachability.isKnownUnreachable(host: "blocked.example.cn"))
        clock.now += 1
        XCTAssertFalse(reachability.isKnownUnreachable(host: "blocked.example.cn"))

        reachability.recordNetworkFailure(host: "blocked.example.cn")
        XCTAssertTrue(reachability.isKnownUnreachable(host: "blocked.example.cn"))
        notificationCenter.post(name: SSKReachability.owsReachabilityDidChange, object: nil)
        XCTAssertFalse(reachability.isKnownUnreachable(host: "blocked.example.cn"))
    }

    // MARK: - 短链

    func testShortLinkReadsOnlyLocationAndNeverFollows() async throws {
        let bigBody = Data(repeating: UInt8(ascii: "z"), count: 1024 * 1024)
        let server = try await startServer { request in
            switch request.path {
            case "/b23": return .response(status: 302, headers: [("Location", "https://www.bilibili.com/video/BV1GJ411x7h7"), ("Content-Type", "text/html")], body: bigBody)
            case "/relative": return .redirect(to: "/landing?from=short", status: 301)
            case "/http": return .redirect(to: "http://www.tellomi-test.cn/page")
            case "/no-location": return .response(status: 302, headers: [], body: Data())
            default: return .html(Self.page)
            }
        }
        let fetcher = makeFetcher(server: server)

        let target = try await fetcher.expandShortLink(server.url("/b23"), budget: fetcher.makeBudget())
        XCTAssertEqual(target.absoluteString, "https://www.bilibili.com/video/BV1GJ411x7h7")
        let relative = try await fetcher.expandShortLink(server.url("/relative"), budget: fetcher.makeBudget())
        XCTAssertEqual(relative, server.url("/landing?from=short"))
        // http 的 Location 只用来识别，不请求（§6.3）
        let insecure = try await fetcher.expandShortLink(server.url("/http"), budget: fetcher.makeBudget())
        XCTAssertEqual(insecure.scheme, "http")
        await expectFailure(.missingLocation) {
            _ = try await fetcher.expandShortLink(server.url("/no-location"), budget: fetcher.makeBudget())
        }
        await expectFailure(.missingLocation) {
            _ = try await fetcher.expandShortLink(server.url("/page"), budget: fetcher.makeBudget())
        }
        // 只有这五个请求：Location 指向的地址一个都没请求
        XCTAssertEqual(server.requests.map(\.path), ["/b23", "/relative", "/http", "/no-location", "/page"])
    }

    // MARK: - 纯函数

    func testBlockedAddressRanges() {
        let blocked = [
            "0.0.0.0",
            "0.1.2.3",
            "10.0.0.1",
            "10.255.255.255",
            "100.64.0.1",
            "100.127.255.254",
            "127.0.0.1",
            "127.8.8.8",
            "169.254.169.254",
            "172.16.0.1",
            "172.31.255.255",
            "192.168.0.1",
            "::1",
            "::",
            "fc00::1",
            "fd12:3456::1",
            "fe80::1",
            "febf::1",
            "::ffff:10.0.0.1",
            "::ffff:127.0.0.1",
            "::ffff:169.254.1.1",
            "64:ff9b::a00:1",
            "[::1]",
        ]
        let allowed = [
            "1.1.1.1",
            "8.8.8.8",
            "100.63.255.255",
            "100.128.0.1",
            "172.15.255.255",
            "172.32.0.1",
            "192.167.1.1",
            "192.169.1.1",
            "169.253.1.1",
            "198.18.0.1",
            "198.19.255.254",
            "11.0.0.1",
            "2001:4860:4860::8888",
            "fec0::1",
            "::ffff:8.8.8.8",
            "64:ff9b::808:808",
        ]
        for literal in blocked {
            let address = TellomiLinkIPAddress(literal: literal)
            XCTAssertNotNil(address, literal)
            XCTAssertTrue(address.map(TellomiLinkAddressPolicy.isBlocked) ?? false, literal)
        }
        for literal in allowed {
            let address = TellomiLinkIPAddress(literal: literal)
            XCTAssertNotNil(address, literal)
            XCTAssertFalse(address.map(TellomiLinkAddressPolicy.isBlocked) ?? true, literal)
        }
        XCTAssertNil(TellomiLinkIPAddress(literal: "tell.cc"))
    }

    func testFakeIpProxyRangeResolvesThrough() async {
        let verdict = await TellomiLinkURLGuard.productionAddressCheck(URL(string: "https://fakeip.tellomi-test.cn/")!, resolver: FakeResolver())
        XCTAssertEqual(verdict, .allowed)
    }

    func testRegionPriorIsFixedToGlobalInP1() {
        XCTAssertEqual(TellomiLinkRegionPrior.current, .global)
        XCTAssertFalse(TellomiLinkRegionPrior.skipsNetwork(unreachableIn: [.cn]))
        XCTAssertTrue(TellomiLinkRegionPrior.skipsNetwork(unreachableIn: [.global]))
        XCTAssertFalse(TellomiLinkRegionPrior.skipsNetwork(unreachableIn: []))
    }
}
