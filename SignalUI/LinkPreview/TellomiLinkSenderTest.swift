//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit
import XCTest
@testable import SignalServiceKit
@testable import SignalUI

/// ADR-0063 §4.2 / §4.4 / §5.2（tellomi/tellomi#1423）：发送端——rust/links 决定抓什么，客户端做请求、把结果喂回去，最后拼预览
/// （快照 + `Preview.rich`）。这里用**脚本化的作业**（请求和最终结果是预设的）+ 真的抓取器指向本地测试服务，核客户端这一半：
/// 请求怎么做、结果怎么喂回去、tell.cc 对象用客户端自己的查询、预览怎么拼出草稿。
/// rust/links 那一半（请求是什么、预览长什么样）由 `TellomiLinkBridgeGoldenTest` 用共享黄金数据管。
final class TellomiLinkSenderTest: XCTestCase {

    private var servers = [TellomiLocalHTTPTestServer]()

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers.removeAll()
        super.tearDown()
    }

    private func startServer(_ handler: @escaping TellomiLocalHTTPTestServer.Handler) async throws -> TellomiLocalHTTPTestServer {
        let server = try TellomiLocalHTTPTestServer(handler: handler)
        try await server.start()
        servers.append(server)
        return server
    }

    private struct NoDNS: TellomiLinkHostResolving {
        func resolve(host: String) async -> TellomiLinkResolution { .failed }
    }

    private func makeLinkFetcher(allowing server: TellomiLocalHTTPTestServer?) -> TellomiLinkFetcher {
        let port = server.map { Int($0.port) }
        let isTestOrigin: @Sendable (URL) -> Bool = { $0.scheme == "http" && $0.host == "127.0.0.1" && $0.port == port }
        let production = TellomiLinkURLGuard(resolver: NoDNS())
        let urlGuard = TellomiLinkURLGuard(
            checkShape: { isTestOrigin($0) ? .allowed : production.checkShape($0) },
            checkAddress: { url in isTestOrigin(url) ? .allowed : await production.checkAddress(url) },
        )
        return TellomiLinkFetcher(urlGuard: urlGuard, reachability: TellomiLinkReachability())
    }

    // MARK: - 假作业、假查询

    /// 按脚本吐请求，记下客户端喂回来的一切，最后给一份预设的结果。
    private final class ScriptedJob: TellomiSendJob {
        var requests: [String]
        let outcome: String
        var responses = [(id: UInt32, status: UInt32, finalUrl: String, contentType: String, location: String?, body: Data)]()
        var networkErrors = [UInt32]()
        var failures = [UInt32]()
        var firstParty = [(id: UInt32, result: String)]()
        var images = [(id: UInt32, ok: Bool)]()

        init(requests: [String], outcome: String) {
            self.requests = requests
            self.outcome = outcome
        }

        func nextRequest() throws -> String? { requests.isEmpty ? nil : requests.removeFirst() }

        func onResponse(id: UInt32, status: UInt32, finalUrl: String, contentType: String, location: String?, body: Data) throws {
            responses.append((id, status, finalUrl, contentType, location, body))
        }

        func onNetworkError(id: UInt32) throws { networkErrors.append(id) }
        func onFailure(id: UInt32) throws { failures.append(id) }
        func onFirstParty(id: UInt32, result: String) throws { firstParty.append((id, result)) }
        func onImage(id: UInt32, ok: Bool) throws { images.append((id, ok)) }
        func finish() throws -> String { outcome }
    }

    private final class FakeLookups: TellomiSendLookups {
        var firstPartyResult: TellomiLinkSender.FirstParty = .notFound
        var askedKinds = [String]()
        var thumbnailResult: TellomiLinkSender.Thumbnail? = TellomiLinkSender.Thumbnail(imageData: Data([1, 2, 3]), mimeType: "image/png")
        var thumbnailInputs = [Data]()

        func firstParty(kind: String, url: URL) async -> TellomiLinkSender.FirstParty {
            askedKinds.append(kind)
            return firstPartyResult
        }

        func thumbnail(from data: Data) async -> TellomiLinkSender.Thumbnail? {
            thumbnailInputs.append(data)
            return thumbnailResult
        }
    }

    private func makeSender(fetcher: TellomiLinkFetcher, lookups: FakeLookups) -> TellomiLinkSender {
        TellomiLinkSender(fetcher: fetcher, expandShortLinks: { true }, locale: { Locale(identifier: "zh_Hans_CN") }, lookups: lookups)
    }

    private func outcomeJson(preview: String?, groupLinkInvalid: Bool = false, provider: String = "app-store") -> String {
        let previewPart = preview ?? "null"
        return #"{"level":"structured","provider":"\#(provider)","route":"app","kind":"app","preview":\#(previewPart),"group_link_invalid":\#(groupLinkInvalid),"lookalike":null,"newly_unreachable_hosts":[],"failures":[]}"#
    }

    private func fetchRequest(_ url: URL, id: Int = 1, contentTypes: String = #"["text/html","application/xhtml+xml"]"#) -> String {
        #"{"id":\#(id),"type":"fetch","url":"\#(url.absoluteString)","accept":"text/html","content_types":\#(contentTypes),"max_bytes":2097152,"max_redirects":5,"connect_timeout_ms":5000,"timeout_ms":10000}"#
    }

    private func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData()!
    }

    // MARK: - 结果怎么喂回去

    func testThePageIsFetchedAndTheResponseIsFedBack() async throws {
        let server = try await startServer { request in
            request.path == "/page" ? .html("<html><head><title>T</title></head></html>") : .html("missing", status: 404)
        }
        let url = server.url("/page")
        let job = ScriptedJob(
            requests: [fetchRequest(url)],
            outcome: outcomeJson(preview: #"{"url":"\#(url.absoluteString)","title":"标题","description":"描述","image_url":null,"date":1700000000000,"rich_hex":"0a03616263"}"#),
        )
        let sender = makeSender(fetcher: makeLinkFetcher(allowing: server), lookups: FakeLookups())

        let result = try await sender.preview(job: job, url: url)

        XCTAssertEqual(job.responses.count, 1)
        XCTAssertEqual(job.responses.first?.status, 200)
        XCTAssertEqual(job.responses.first?.contentType, "text/html")
        XCTAssertEqual(String(decoding: job.responses.first?.body ?? Data(), as: UTF8.self), "<html><head><title>T</title></head></html>")
        guard case .found(let draft) = result else {
            return XCTFail("\(result)")
        }
        XCTAssertEqual(draft.url, url)
        XCTAssertEqual(draft.title, "标题")
        XCTAssertEqual(draft.previewDescription, "描述")
        XCTAssertEqual(draft.date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(draft.rich, Data([0x0a, 0x03, 0x61, 0x62, 0x63]), "rich_hex 原样变成 Preview.rich 的字节")
    }

    func testAPageThatIsNotFoundIsReportedWithItsStatusNotAsAFailure() async throws {
        let server = try await startServer { _ in .html("nope", status: 404) }
        let job = ScriptedJob(requests: [fetchRequest(server.url("/gone"))], outcome: outcomeJson(preview: nil))
        let sender = makeSender(fetcher: makeLinkFetcher(allowing: server), lookups: FakeLookups())

        _ = try await sender.preview(job: job, url: server.url("/gone"))

        XCTAssertEqual(job.responses.first?.status, 404, "rust/links 自己看状态码")
        XCTAssertTrue(job.failures.isEmpty)
        XCTAssertTrue(job.networkErrors.isEmpty)
    }

    func testTheWrongContentTypeIsAFailureAndAServerThatHangsUpIsANetworkError() async throws {
        let server = try await startServer { request in
            request.path == "/json" ? .response(status: 200, headers: [("Content-Type", "application/json")], body: Data("{}".utf8)) : .drop
        }
        // 要 HTML，服务给 JSON → 失败（不是网络错误）
        let job1 = ScriptedJob(requests: [fetchRequest(server.url("/json"))], outcome: outcomeJson(preview: nil))
        _ = try await makeSender(fetcher: makeLinkFetcher(allowing: server), lookups: FakeLookups()).preview(job: job1, url: server.url("/json"))
        XCTAssertEqual(job1.failures, [1])
        XCTAssertTrue(job1.responses.isEmpty)

        // 收下请求就断开 → 网络层失败
        let job2 = ScriptedJob(requests: [fetchRequest(server.url("/drop"))], outcome: outcomeJson(preview: nil))
        _ = try await makeSender(fetcher: makeLinkFetcher(allowing: server), lookups: FakeLookups()).preview(job: job2, url: server.url("/drop"))
        XCTAssertEqual(job2.networkErrors, [1])
    }

    func testTheContentTypesRustLinksAsksForPickTheHTMLOrTheJSONStep() async throws {
        let server = try await startServer { request in
            request.path == "/json" ? .response(status: 200, headers: [("Content-Type", "text/javascript; charset=utf-8")], body: Data(#"{"a":1}"#.utf8)) : .html("<html/>")
        }
        // rust/links 要 JSON（iTunes 的接口回 text/javascript）
        let job = ScriptedJob(
            requests: [fetchRequest(server.url("/json"), contentTypes: #"["application/json","text/javascript"]"#)],
            outcome: outcomeJson(preview: nil),
        )
        _ = try await makeSender(fetcher: makeLinkFetcher(allowing: server), lookups: FakeLookups()).preview(job: job, url: server.url("/json"))
        XCTAssertEqual(job.responses.first?.status, 200)
        XCTAssertEqual(job.responses.first?.contentType, "text/javascript")
    }

    func testTheErrorsMapTheWayRustLinksExpectsThem() {
        typealias E = TellomiLinkFetchError
        func map(_ error: E) -> TellomiSendExchange { TellomiLinkSender.exchange(for: error, requestUrl: "https://a.example/x") }
        XCTAssertEqual(map(.network), .networkError)
        XCTAssertEqual(map(.httpStatus(503)), .response(status: 503, finalUrl: "https://a.example/x", contentType: "", location: nil, body: Data()))
        XCTAssertEqual(map(.missingLocation), .response(status: 200, finalUrl: "https://a.example/x", contentType: "", location: nil, body: Data()))
        for error in [E.timeout, .tooLarge, .contentTypeNotAllowed, .tooManyRedirects, .blockedAddress, .knownUnreachable, .budgetExhausted, .cancelled, .other] {
            XCTAssertEqual(map(error), .failure, "\(error)")
        }
    }

    // MARK: - 预览图

    func testTheImageIsFetchedValidatedAndAttachedToTheDraft() async throws {
        let png = pngData()
        let server = try await startServer { request in
            request.path == "/img.png" ? .response(status: 200, headers: [("Content-Type", "image/png")], body: png) : .html("<html/>")
        }
        let imageUrl = server.url("/img.png")
        let job = ScriptedJob(
            requests: [#"{"id":2,"type":"image","url":"\#(imageUrl.absoluteString)","max_redirects":5,"connect_timeout_ms":5000,"timeout_ms":10000}"#],
            outcome: outcomeJson(preview: #"{"url":"https://a.example/x","title":"T","description":null,"image_url":"\#(imageUrl.absoluteString)","date":null,"rich_hex":null}"#),
        )
        let lookups = FakeLookups()
        let sender = makeSender(fetcher: makeLinkFetcher(allowing: server), lookups: lookups)

        let result = try await sender.preview(job: job, url: URL(string: "https://a.example/x")!)

        XCTAssertEqual(job.images.map(\.ok), [true])
        XCTAssertEqual(lookups.thumbnailInputs, [png], "下载到的图交给 Signal 的校验 / 重新编码")
        guard case .found(let draft) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(draft.imageData, Data([1, 2, 3]))
        XCTAssertEqual(draft.imageMimeType, "image/png")
    }

    func testAnImageSignalWouldRejectIsReportedAsNotOK() async throws {
        let server = try await startServer { _ in .response(status: 200, headers: [("Content-Type", "image/png")], body: Data([9, 9, 9])) }
        let lookups = FakeLookups()
        lookups.thumbnailResult = nil
        let job = ScriptedJob(
            requests: [#"{"id":2,"type":"image","url":"\#(server.url("/i").absoluteString)","max_redirects":5,"connect_timeout_ms":5000,"timeout_ms":10000}"#],
            outcome: outcomeJson(preview: #"{"url":"https://a.example/x","title":"T","description":null,"image_url":"https://a.example/i","date":null,"rich_hex":null}"#),
        )
        let result = try await makeSender(fetcher: makeLinkFetcher(allowing: server), lookups: lookups).preview(job: job, url: URL(string: "https://a.example/x")!)

        XCTAssertEqual(job.images.map(\.ok), [false])
        guard case .found(let draft) = result else { return XCTFail("\(result)") }
        XCTAssertNil(draft.imageData, "图不能用，草稿里就没有图（标题照常）")
    }

    // MARK: - tell.cc 的对象

    private func firstPartyDraft(title: String?, image: Bool) -> OWSLinkPreviewDraft {
        OWSLinkPreviewDraft(
            url: URL(string: "https://tell.cc/g#x")!,
            title: title,
            imageData: image ? Data([7, 7]) : nil,
            imageMimeType: image ? "image/jpeg" : nil,
            isForwarded: false,
        )
    }

    func testAGroupIsLookedUpWithSignalsOwnLookupAndItsCountAndImageGoIntoThePreview() async throws {
        let lookups = FakeLookups()
        lookups.firstPartyResult = .found(firstPartyDraft(title: "周末爬山群", image: true), count: 12)
        let job = ScriptedJob(
            requests: [#"{"id":1,"type":"first_party","kind":"tellomi.group"}"#],
            outcome: outcomeJson(preview: #"{"url":"https://tell.cc/g#x","title":"周末爬山群","description":null,"image_url":null,"date":null,"rich_hex":"0a"}"#, provider: "tellomi"),
        )
        let sender = makeSender(fetcher: makeLinkFetcher(allowing: nil), lookups: lookups)

        let result = try await sender.preview(job: job, url: URL(string: "https://tell.cc/g#x")!)

        XCTAssertEqual(lookups.askedKinds, ["tellomi.group"])
        let fed = try XCTUnwrap(job.firstParty.first?.result)
        let decoded = try JSONDecoder().decode(TellomiSendFirstPartyResult.self, from: Data(fed.utf8))
        XCTAssertEqual(decoded, TellomiSendFirstPartyResult(ok: true, title: "周末爬山群", memberCount: 12))
        guard case .found(let draft) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(draft.imageData, Data([7, 7]), "群头像来自客户端自己的查询")
        XCTAssertEqual(draft.imageMimeType, "image/jpeg")
    }

    func testAStickerPackCountsStickersNotMembers() async throws {
        let lookups = FakeLookups()
        lookups.firstPartyResult = .found(firstPartyDraft(title: "Bandit", image: true), count: 24)
        let job = ScriptedJob(
            requests: [#"{"id":1,"type":"first_party","kind":"tellomi.sticker"}"#],
            outcome: outcomeJson(preview: nil, provider: "tellomi"),
        )
        _ = try await makeSender(fetcher: makeLinkFetcher(allowing: nil), lookups: lookups).preview(job: job, url: URL(string: "https://tell.cc/s#x")!)
        let decoded = try JSONDecoder().decode(TellomiSendFirstPartyResult.self, from: Data(try XCTUnwrap(job.firstParty.first?.result).utf8))
        XCTAssertEqual(decoded.stickerCount, 24)
        XCTAssertNil(decoded.memberCount)
    }

    func testACountOfZeroIsNotSentAndAnInactiveGroupIsSaidToBeInvalid() async throws {
        let lookups = FakeLookups()
        lookups.firstPartyResult = .found(firstPartyDraft(title: "G", image: false), count: 0)
        let job1 = ScriptedJob(requests: [#"{"id":1,"type":"first_party","kind":"tellomi.group"}"#], outcome: outcomeJson(preview: nil, provider: "tellomi"))
        _ = try await makeSender(fetcher: makeLinkFetcher(allowing: nil), lookups: lookups).preview(job: job1, url: URL(string: "https://tell.cc/g#x")!)
        XCTAssertNil(try JSONDecoder().decode(TellomiSendFirstPartyResult.self, from: Data(try XCTUnwrap(job1.firstParty.first?.result).utf8)).memberCount)

        lookups.firstPartyResult = .inactive
        let job2 = ScriptedJob(
            requests: [#"{"id":1,"type":"first_party","kind":"tellomi.group"}"#],
            outcome: outcomeJson(preview: nil, groupLinkInvalid: true, provider: "tellomi"),
        )
        let result = try await makeSender(fetcher: makeLinkFetcher(allowing: nil), lookups: lookups).preview(job: job2, url: URL(string: "https://tell.cc/g#x")!)
        let decoded = try JSONDecoder().decode(TellomiSendFirstPartyResult.self, from: Data(try XCTUnwrap(job2.firstParty.first?.result).utf8))
        XCTAssertEqual(decoded, TellomiSendFirstPartyResult(ok: false, invalid: true))
        guard case .groupLinkInactive = result else { return XCTFail("\(result)") }
    }

    func testAnInactiveGroupLinkIsTheOnlyNoPreviewThatTheComposerCanTellApart() {
        XCTAssertEqual(LinkPreviewFetcherImpl.previewError(for: .groupLinkInactive), .groupLinkInactive)
        XCTAssertEqual(LinkPreviewFetcherImpl.previewError(for: .notAvailable), .noPreview)
    }

    // MARK: - 没有预览

    func testNoPreviewInTheOutcomeMeansNoPreview() async throws {
        let job = ScriptedJob(requests: [], outcome: outcomeJson(preview: nil))
        let result = try await makeSender(fetcher: makeLinkFetcher(allowing: nil), lookups: FakeLookups()).preview(job: job, url: URL(string: "https://a.example/")!)
        guard case .notAvailable = result else { return XCTFail("\(result)") }
    }

    func testARequestThisBuildDoesNotUnderstandMeansNoPreviewNotAGuess() async throws {
        let job = ScriptedJob(requests: [#"{"id":1,"type":"hologram","url":"https://a.example/"}"#], outcome: outcomeJson(preview: #"{"url":"https://a.example/","title":"guess","description":null,"image_url":null,"date":null,"rich_hex":null}"#))
        let result = try await makeSender(fetcher: makeLinkFetcher(allowing: nil), lookups: FakeLookups()).preview(job: job, url: URL(string: "https://a.example/")!)
        guard case .notAvailable = result else { return XCTFail("\(result)") }
    }

    func testNoRegistryMeansTheSenderIsNotAvailable() async throws {
        let sender = TellomiLinkSender(
            fetcher: makeLinkFetcher(allowing: nil),
            classifier: TellomiLinkClassifier(registry: nil),
            expandShortLinks: { true },
            lookups: FakeLookups(),
        )
        XCTAssertFalse(sender.isAvailable)
        let result = try await sender.preview(for: URL(string: "https://a.example/")!)
        XCTAssertNil(result, "没有注册表：调用方照 Signal 原样")
    }

    // MARK: - 实网烟测（默认跳过）

    /// 用生产同一套接线（`LinkPreviewFetcherImpl(usesTellomiSendJob: true)`）对几条真实公开链接跑一遍，看真网络上整条流程走得通。
    /// 只在 `TELLOMI_LIVE_LINKS=1` 时跑（`TEST_RUNNER_TELLOMI_LIVE_LINKS=1`）；结果写到 `TELLOMI_SHOTS_DIR/live-links.txt`。
    func testLiveLinks() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_LIVE_LINKS"] == "1", "只在 TELLOMI_LIVE_LINKS=1 时联网跑")
        let fetcher = LinkPreviewFetcherImpl(
            authCredentialManager: MockAuthCrededentialManager(),
            db: InMemoryDB(),
            groupsV2: MockGroupsV2(),
            linkPreviewSettingStore: LinkPreviewSettingStore.mock(),
            tsAccountManager: MockTSAccountManager(),
            usesTellomiSendJob: true,
        )
        var report = ""
        for raw in [
            "https://www.wikipedia.org/",
            "https://github.com/tellomi/Signal-iOS",
            "https://apps.apple.com/cn/app/wechat/id414478124",
            "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            "https://item.taobao.com/item.htm?id=674169489573",
            "https://tell.cc/hk881qb",
        ] {
            let url = URL(string: raw)!
            do {
                let draft = try await fetcher.fetchLinkPreview(for: url)
                report += "OK   \(raw)\n     title=\(draft.title ?? "-") | description=\(draft.previewDescription?.prefix(60) ?? "-") | image=\(draft.imageData.map { "\($0.count) bytes \(draft.imageMimeType ?? "")" } ?? "-") | date=\(draft.date.map { "\($0)" } ?? "-") | rich=\(draft.rich.map { "\($0.count) bytes" } ?? "-")\n"
            } catch {
                report += "FAIL \(raw)  → \(error)\n"
            }
        }
        print(report)
        if let dir = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try report.write(toFile: dir + "/live-links.txt", atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 整个 LinkPreviewFetcherImpl

    func testTheFetcherUsesTheSendJobOnlyWhenTurnedOn() async throws {
        let server = try await startServer { _ in .html("<html><head><meta property=\"og:title\" content=\"legacy\"></head></html>") }
        func makeFetcher(usesSendJob: Bool) -> LinkPreviewFetcherImpl {
            LinkPreviewFetcherImpl(
                authCredentialManager: MockAuthCrededentialManager(),
                db: InMemoryDB(),
                groupsV2: MockGroupsV2(),
                linkPreviewSettingStore: LinkPreviewSettingStore.mock(),
                tsAccountManager: MockTSAccountManager(),
                linkFetcher: makeLinkFetcher(allowing: server),
                usesTellomiSendJob: usesSendJob,
                serverFetchEnabled: { false },
            )
        }
        // 关着：照 Signal 原样抓（本地 http 测试服务能抓到）
        let legacy = try await makeFetcher(usesSendJob: false).fetchLinkPreview(for: server.url("/a"))
        XCTAssertEqual(legacy.title, "legacy")

        // 开着：由 rust/links 判——它只认 https，本地 http 的地址没有预览
        do {
            _ = try await makeFetcher(usesSendJob: true).fetchLinkPreview(for: server.url("/a"))
            XCTFail("rust/links 不给 http 的链接出预览")
        } catch {
            XCTAssertEqual(error as? LinkPreviewError, .noPreview)
        }
    }

    // MARK: - 服务端代抓（ADR-0063 §6.5）

    private final class FakeServerClient: TellomiServerLinkPreviewClient, @unchecked Sendable {
        let answer: TellomiServerLinkPreview.Answer
        private let lock = NSLock()
        private var _asked = [URL]()
        var asked: [URL] { lock.withLock { _asked } }

        init(_ answer: TellomiServerLinkPreview.Answer) { self.answer = answer }

        func fetch(url: URL) async -> TellomiServerLinkPreview.Answer {
            lock.withLock { _asked.append(url) }
            return answer
        }
    }

    private func brandOutcome(url: URL, provider: String = "weixin-mp") -> String {
        #"{"level":"brand","provider":"\#(provider)","route":"article","kind":"article","preview":{"url":"\#(url.absoluteString)","title":null,"description":null,"image_url":null,"date":null,"rich_hex":"0a02"},"group_link_invalid":false,"lookalike":null,"newly_unreachable_hosts":[],"failures":[]}"#
    }

    private func makeServerSender(
        client: FakeServerClient,
        enabled: Bool,
        lookups: FakeLookups = FakeLookups(),
        gate: TellomiServerLinkPreviewGate = TellomiServerLinkPreviewGate(),
    ) -> TellomiLinkSender {
        TellomiLinkSender(
            fetcher: makeLinkFetcher(allowing: nil),
            expandShortLinks: { true },
            locale: { Locale(identifier: "zh_Hans_CN") },
            lookups: lookups,
            serverClient: client,
            serverFetchEnabled: { enabled },
            serverGate: gate,
        )
    }

    private let weixinUrl = URL(string: "https://mp.weixin.qq.com/s/AbCdEf")!

    func testAWhitelistedLinkAsksTheServerOnlyWhenTheFlagIsOn() {
        let client = FakeServerClient(.noCard)
        XCTAssertFalse(makeServerSender(client: client, enabled: false).usesServerFetch(for: weixinUrl), "开关默认关：不问服务端")
        XCTAssertTrue(makeServerSender(client: client, enabled: true).usesServerFetch(for: weixinUrl))
        XCTAssertFalse(makeServerSender(client: client, enabled: true).usesServerFetch(for: URL(string: "https://example.com/a")!), "白名单外不问")
        XCTAssertFalse(makeServerSender(client: client, enabled: true).usesServerFetch(for: URL(string: "http://mp.weixin.qq.com/s/x")!), "只认 https")
        let noClient = TellomiLinkSender(fetcher: makeLinkFetcher(allowing: nil), expandShortLinks: { true }, lookups: FakeLookups(), serverFetchEnabled: { true })
        XCTAssertFalse(noClient.usesServerFetch(for: weixinUrl), "没有客户端（默认）就不问")
    }

    func testTheServerCardReplacesTheBrandShellButKeepsTheRichBytes() async throws {
        let client = FakeServerClient(.card(.init(title: "文章标题", provider: "weixin-mp", imageData: pngData(), imageMimeType: "image/jpeg")))
        let lookups = FakeLookups()
        let job = ScriptedJob(requests: [], outcome: brandOutcome(url: weixinUrl))
        let result = try await makeServerSender(client: client, enabled: true, lookups: lookups).preview(job: job, url: weixinUrl, viaServer: true)
        guard case .found(let draft) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(draft.title, "文章标题")
        XCTAssertEqual(draft.imageData, Data([1, 2, 3]), "服务端的图也过 Signal 的缩略图关")
        XCTAssertEqual(draft.imageMimeType, "image/png")
        XCTAssertEqual(lookups.thumbnailInputs.count, 1)
        XCTAssertEqual(draft.rich, Data([0x0a, 0x02]), "品牌壳的 rich 原样带上，旧接收端照旧显示品牌壳")
        XCTAssertEqual(client.asked, [weixinUrl])
    }

    func testEveryServerFailureFallsBackToTheBrandShell() async throws {
        let answers: [TellomiServerLinkPreview.Answer] = [.noCard, .notDeployed, .throttled(retryAfter: 5), .failed]
        for answer in answers {
            let client = FakeServerClient(answer)
            let job = ScriptedJob(requests: [], outcome: brandOutcome(url: weixinUrl))
            let result = try await makeServerSender(client: client, enabled: true).preview(job: job, url: weixinUrl, viaServer: true)
            guard case .found(let draft) = result else { return XCTFail("\(answer): \(result)") }
            XCTAssertNil(draft.title, "\(answer)：照现在的品牌壳")
            XCTAssertEqual(draft.rich, Data([0x0a, 0x02]))
        }
    }

    func testAServerCardWithoutAnImageStillHasATitle() async throws {
        let client = FakeServerClient(.card(.init(title: "只有标题", provider: "weibo")))
        let lookups = FakeLookups()
        let url = URL(string: "https://weibo.com/1234/AbCd")!
        let job = ScriptedJob(requests: [], outcome: brandOutcome(url: url, provider: "weibo"))
        let result = try await makeServerSender(client: client, enabled: true, lookups: lookups).preview(job: job, url: url, viaServer: true)
        guard case .found(let draft) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(draft.title, "只有标题")
        XCTAssertNil(draft.imageData)
        XCTAssertTrue(lookups.thumbnailInputs.isEmpty)
    }

    func testAStructuredCardIsNeverReplacedByTheServer() async throws {
        let client = FakeServerClient(.card(.init(title: "服务端", provider: "zhihu")))
        let url = URL(string: "https://www.zhihu.com/question/1")!
        let job = ScriptedJob(requests: [], outcome: outcomeJson(preview: #"{"url":"\#(url.absoluteString)","title":"本机结构化","description":null,"image_url":null,"date":null,"rich_hex":null}"#, provider: "zhihu"))
        let result = try await makeServerSender(client: client, enabled: true).preview(job: job, url: url, viaServer: true)
        guard case .found(let draft) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(draft.title, "本机结构化")
        XCTAssertTrue(client.asked.isEmpty, "结构化卡本来就更好，不问服务端")
    }

    func testWithoutViaServerTheServerIsNeverAsked() async throws {
        let client = FakeServerClient(.card(.init(title: "x", provider: "weixin-mp")))
        let job = ScriptedJob(requests: [], outcome: brandOutcome(url: weixinUrl))
        _ = try await makeServerSender(client: client, enabled: false).preview(job: job, url: weixinUrl)
        XCTAssertTrue(client.asked.isEmpty)
    }

    func testNotDeployedClosesTheGateSoTheNextLinkDoesNotAsk() async throws {
        let gate = TellomiServerLinkPreviewGate()
        let client = FakeServerClient(.notDeployed)
        let sender = makeServerSender(client: client, enabled: true, gate: gate)
        let job = ScriptedJob(requests: [], outcome: brandOutcome(url: weixinUrl))
        _ = try await sender.preview(job: job, url: weixinUrl, viaServer: true)
        XCTAssertFalse(sender.usesServerFetch(for: weixinUrl), "没部署：10 分钟内不再问")
    }
}
