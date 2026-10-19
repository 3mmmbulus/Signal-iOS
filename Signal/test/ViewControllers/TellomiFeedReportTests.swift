//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedReportTests.swift (new file)
// I-10: report request wire shape, reason table, and FeedReportStore. Mirrors Android FeedReportReasonsTest / FeedReportViewModelTest.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class TellomiFeedReportReasonsTests: XCTestCase {
    func testWithoutAnEngineTableTheBuiltInFourGroupsAreUsedInOrder() {
        let groups = FeedReportReasons.groups(fromConfig: [:])
        XCTAssertEqual(groups.map(\.code), ["harm_others", "illegal", "false_or_impersonation", "my_rights"])
        XCTAssertEqual(groups[0].reasons.map(\.code), ["harassment", "hate", "violence_threat", "self_harm", "minor_safety"])
        XCTAssertEqual(groups[3].reasons.map(\.code), ["copyright", "portrait", "privacy", "defamation"])
        XCTAssertEqual(groups.flatMap(\.reasons).count, 17)
        XCTAssertTrue(groups.flatMap(\.reasons).allSatisfy { FeedReportReasons.known.contains($0.code) })
    }

    func testTheEngineTableDecidesWhichReasonsShowAndInWhatOrderInsideAGroup() {
        let groups = FeedReportReasons.groups(fromConfig: [
            "illegal": ["drugs", "fraud", "brand_new_reason"],
            "harm_others": ["hate", "harassment"],
            "my_rights": ["brand_new_reason"],
            "unknown_group": ["spam"],
        ])
        XCTAssertEqual(groups.map(\.code), ["harm_others", "illegal"], "组的顺序固定；没有认识的原因的组不显示；认不得的组不显示")
        XCTAssertEqual(groups[0].reasons.map(\.code), ["hate", "harassment"])
        XCTAssertEqual(groups[1].reasons.map(\.code), ["drugs", "fraud"], "引擎新加的、客户端没文案的先不显示")
    }

    func testFlagsFollowTheEngine() {
        let all = FeedReportReasons.groups(fromConfig: [:]).flatMap(\.reasons)
        func reason(_ code: String) -> FeedReportReason { all.first { $0.code == code }! }
        XCTAssertTrue(reason("fraud").needsEvidence)
        XCTAssertFalse(reason("fraud").needsRelationship)
        for code in ["copyright", "portrait", "privacy", "defamation"] {
            XCTAssertTrue(reason(code).needsEvidence, code)
            XCTAssertTrue(reason(code).needsRelationship, code)
        }
        XCTAssertFalse(reason("spam").needsEvidence)
        XCTAssertEqual(Set(all.filter(\.isEmergency).map(\.code)), ["violence_threat", "self_harm", "minor_safety"])
        XCTAssertEqual(reason("hate").labelKey, "TELLOMI_FEED_REPORT_HATE")
        XCTAssertEqual(reason("hate").descriptionKey, "TELLOMI_FEED_REPORT_HATE_DESC")
    }
}

private struct Boom: Error {}

private final class CallLog<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [T]()
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class ReportSource: FeedSource {
    var configError: Error?
    var reportError: Error?
    var region: String? = "cn"
    var table = [String: [String]]()
    let requests = CallLog<FeedReportRequest>()
    let uploads = CallLog<String>()
    var uploadFailsAt: Int?

    func config() async throws -> FeedConfig {
        if let configError { throw configError }
        var config = FeedConfig()
        config.region = region
        config.reportReasons = table
        return config
    }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func uploadImage(_ image: UIImage) async throws -> String {
        let n = uploads.all.count + 1
        uploads.append("k\(n)")
        if uploadFailsAt == n { throw Boom() }
        return "m/k\(n)"
    }
    func report(_ request: FeedReportRequest) async throws {
        requests.append(request)
        if let reportError { throw reportError }
    }
}

@MainActor
final class TellomiFeedReportStoreTests: XCTestCase {
    private func reason(_ code: String) -> FeedReportReason {
        return FeedReportReasons.groups(fromConfig: [:]).flatMap(\.reasons).first { $0.code == code }!
    }

    private func image() -> FeedDraftImage { FeedDraftImage(image: UIImage()) }

    func testConfigGivesTheReasonTableAndTheRegion() async {
        let source = ReportSource()
        source.table = ["harm_others": ["spam_only_in_other_group", "hate"]]
        let store = FeedReportStore(target: .content("p"), source: source)
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(store.state.groups.map(\.code), ["harm_others"])
        XCTAssertEqual(store.state.groups[0].reasons.map(\.code), ["hate"])
        XCTAssertTrue(store.state.showMainlandHotline)

        let failing = ReportSource()
        failing.configError = Boom()
        let second = FeedReportStore(target: .content("p"), source: failing)
        second.start()
        await second.waitForTasks()
        XCTAssertEqual(second.state.groups.count, 4, "取不到就用内置的")
        XCTAssertFalse(second.state.showMainlandHotline)
    }

    func testAPlainReasonSendsWithoutEvidence() async {
        let source = ReportSource()
        let store = FeedReportStore(target: .content("post-1"), source: source)
        XCTAssertFalse(store.state.canSubmit, "还没选原因")
        store.pick(reason("spam"))
        XCTAssertTrue(store.state.canSubmit)
        store.onDetailChanged("  looks like an ad \n")
        store.submit()
        XCTAssertTrue(store.state.sending)
        XCTAssertFalse(store.state.canSubmit, "在途时不能再交")
        store.submit()
        await store.waitForTasks()
        XCTAssertEqual(source.requests.all, [
            FeedReportRequest(targetType: "content", targetId: "post-1", group: "false_or_impersonation", reason: "spam", detail: "looks like an ad", evidenceKeys: nil, relationship: nil),
        ])
        XCTAssertTrue(store.state.sent)
        XCTAssertFalse(store.state.sending)
        XCTAssertEqual(source.uploads.all, [])
    }

    func testFraudNeedsAScreenshotAndMyRightsNeedsTheRelationshipToo() async {
        let source = ReportSource()
        let store = FeedReportStore(target: .author("u1"), source: source)
        store.pick(reason("fraud"))
        XCTAssertFalse(store.state.canSubmit)
        let a = image(), b = image()
        store.addEvidence([a, b, a])
        XCTAssertEqual(store.state.evidence.count, 2, "同一张不重复加")
        XCTAssertTrue(store.state.canSubmit)
        store.removeEvidence(b)
        XCTAssertEqual(store.state.evidence.count, 1)

        store.pick(reason("portrait"))
        XCTAssertFalse(store.state.canSubmit, "我的权益还要写关系")
        store.onRelationshipChanged("   ")
        XCTAssertFalse(store.state.canSubmit)
        store.onRelationshipChanged(" myself ")
        XCTAssertTrue(store.state.canSubmit)
        store.submit()
        await store.waitForTasks()
        XCTAssertEqual(source.requests.all.count, 1)
        let request = source.requests.all[0]
        XCTAssertEqual(request.targetType, "author")
        XCTAssertEqual(request.group, "my_rights")
        XCTAssertEqual(request.reason, "portrait")
        XCTAssertEqual(request.evidenceKeys, ["m/k1"], "截图在提交时才传")
        XCTAssertEqual(request.relationship, "myself")
        XCTAssertNil(request.detail)
    }

    func testEvidenceIsCappedAtNineAndNotSentForReasonsThatDoNotNeedIt() async {
        let source = ReportSource()
        let store = FeedReportStore(target: .content("p"), source: source)
        store.addEvidence((0..<12).map { _ in image() })
        XCTAssertEqual(store.state.evidence.count, 9)
        store.addEvidence([image()])
        XCTAssertEqual(store.state.evidence.count, 9)

        store.pick(reason("hate"))
        store.submit()
        await store.waitForTasks()
        XCTAssertEqual(source.uploads.all, [], "不需要截图的原因不上传")
        XCTAssertNil(source.requests.all[0].evidenceKeys)
    }

    func testFieldsAreCappedByCodePointsLikeTheEngine() {
        let store = FeedReportStore(target: .content("p"), source: ReportSource())
        store.onDetailChanged(String(repeating: "字", count: 600))
        XCTAssertEqual(store.state.detail.unicodeScalars.count, 500)
        // 😀 是 1 个码点：501 个里留 500 个，不劈开
        store.onDetailChanged(String(repeating: "😀", count: 501))
        XCTAssertEqual(store.state.detail.count, 500)
        XCTAssertEqual(store.state.detail.unicodeScalars.count, 500)
        store.onRelationshipChanged(String(repeating: "a", count: 50))
        XCTAssertEqual(store.state.relationship.unicodeScalars.count, 40)
    }

    /// 引擎数码点：🇨🇳 是 2 个码点（1 个 Character）、👨‍👩‍👧‍👦 是 7 个。按 Character 截会放过引擎的 400 `invalid_detail`。
    func testMultiCodePointCharactersCountAsManyCodePointsAsTheEngineCounts() {
        let flag = "\u{1F1E8}\u{1F1F3}"
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        XCTAssertEqual(flag.count, 1)
        XCTAssertEqual(flag.unicodeScalars.count, 2)
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(family.unicodeScalars.count, 7)

        let store = FeedReportStore(target: .content("p"), source: ReportSource())
        store.onDetailChanged(String(repeating: flag, count: 400))
        XCTAssertEqual(store.state.detail.count, 250, "250 个国旗 = 500 个码点")
        XCTAssertEqual(store.state.detail.unicodeScalars.count, 500)

        store.onRelationshipChanged(String(repeating: family, count: 10))
        XCTAssertEqual(store.state.relationship.count, 5, "5 个家庭 emoji = 35 个码点；第 6 个会到 42 > 40")
        XCTAssertEqual(store.state.relationship.unicodeScalars.count, 35)

        // 39 个 a + 一面国旗（2 个码点）= 41 个码点 > 40：国旗整个去掉，不留半个
        store.onRelationshipChanged(String(repeating: "a", count: 39) + flag)
        XCTAssertEqual(store.state.relationship, String(repeating: "a", count: 39), "旗放不下就整个去掉，不留半个")
    }

    func testCapKeepsTextThatFitsAndNeverSplitsACharacter() {
        XCTAssertEqual(FeedReportReason.cap("", codePoints: 5), "")
        XCTAssertEqual(FeedReportReason.cap("abc", codePoints: 5), "abc")
        XCTAssertEqual(FeedReportReason.cap("e\u{301}e\u{301}", codePoints: 3), "e\u{301}", "é = e + 组合符，2 个码点；第二个 é 放不下")
        XCTAssertEqual(FeedReportReason.cap("abc", codePoints: 0), "")
    }

    func testBackToReasonsKeepsWhatWasTyped() {
        let store = FeedReportStore(target: .content("p"), source: ReportSource())
        store.pick(reason("hate"))
        store.onDetailChanged("details")
        store.backToReasons()
        XCTAssertNil(store.state.reason)
        XCTAssertEqual(store.state.detail, "details")
    }

    func testAGoneContentAndOtherFailuresAreToldApart() async {
        let gone = ReportSource()
        gone.reportError = FeedAPIError(status: 404, code: "not_found", retryAfterSeconds: nil)
        let first = FeedReportStore(target: .content("p"), source: gone)
        first.pick(reason("hate"))
        first.submit()
        await first.waitForTasks()
        XCTAssertEqual(first.state.error, .gone)
        XCTAssertFalse(first.state.sent)
        XCTAssertFalse(first.state.sending)
        first.onErrorShown()
        XCTAssertNil(first.state.error)

        let broken = ReportSource()
        broken.reportError = FeedAPIError(status: 500, code: nil, retryAfterSeconds: nil)
        let second = FeedReportStore(target: .content("p"), source: broken)
        second.pick(reason("hate"))
        second.submit()
        await second.waitForTasks()
        XCTAssertEqual(second.state.error, .failed)
        second.submit()   // 失败后可以重试
        await second.waitForTasks()
        XCTAssertEqual(broken.requests.all.count, 2)

        let upload = ReportSource()
        upload.uploadFailsAt = 2
        let third = FeedReportStore(target: .content("p"), source: upload)
        third.pick(reason("fraud"))
        third.addEvidence([image(), image()])
        third.submit()
        await third.waitForTasks()
        XCTAssertEqual(third.state.error, .failed)
        XCTAssertEqual(upload.requests.all.count, 0, "截图没传完就不交举报")
    }
}

// MARK: - wire

private final class ScriptedTransport: FeedHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests = [URLRequest]()
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.locked { _requests.append(request) }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: [:])!)
    }
}

private struct FixedTokens: FeedTokenSource {
    func token(forceRefresh: Bool) async throws -> String { "t" }
}

final class TellomiFeedReportApiTests: XCTestCase {
    func testReportBodyHasOnlyTheContractFieldsAndSkipsNils() async throws {
        let transport = ScriptedTransport()
        let api = FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
        try await api.report(FeedReportRequest(targetType: "content", targetId: "p1", group: "illegal", reason: "fraud", detail: nil, evidenceKeys: ["m/a", "m/b"], relationship: nil))
        try await api.report(FeedReportRequest(targetType: "author", targetId: "u1", group: "harm_others", reason: "hate", detail: "x", evidenceKeys: nil, relationship: nil))
        let requests = transport.requests
        XCTAssertEqual(requests.map { $0.httpMethod }, ["POST", "POST"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/v1/feed/reports", "/v1/feed/reports"])
        let first = String(data: requests[0].httpBody!, encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/")
        XCTAssertEqual(first, #"{"evidence_keys":["m/a","m/b"],"group":"illegal","reason":"fraud","target_id":"p1","target_type":"content"}"#)
        XCTAssertEqual(String(data: requests[1].httpBody!, encoding: .utf8), #"{"detail":"x","group":"harm_others","reason":"hate","target_id":"u1","target_type":"author"}"#)
    }
}

/// `NSLock.lock()` 在 async 函数里不让直接调（Swift 6）；临界区都不跨 `await`，放进同步闭包里。
private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
