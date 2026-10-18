//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedFriendsTests.swift (new file)
// I-11: friend sync, signing models, `POST /v1/feed/friends`, publishing with an audience, audience problems.
// Mirrors Android FeedFriendSyncTest and the audience part of FeedDraftTest / RemoteFeedSource publish.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

private struct Boom: Error {}

private final class CallLog<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items = [T]()
    func append(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class ScriptedTransport: FeedHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests = [URLRequest]()
    private var replies = [(Int, String)]()
    func reply(_ status: Int, _ body: String) { lock.lock(); replies.append((status, body)); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.locked {
            _requests.append(request)
            return replies.isEmpty ? (204, "") : replies.removeFirst()
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }
}

private struct FixedTokens: FeedTokenSource {
    func token(forceRefresh: Bool) async throws -> String { "t" }
}

private func body(_ request: URLRequest) -> String {
    String(decoding: request.httpBody ?? Data(), as: UTF8.self)
}

// MARK: - wire / publishing

final class TellomiFeedFriendsWireTests: XCTestCase {
    private func make() -> (FeedAPI, ScriptedTransport) {
        let transport = ScriptedTransport()
        return (FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens()), transport)
    }

    func testSigningModelsUseTheServerKeys() throws {
        let add = try JSONEncoder().encode(FeedFriendAssertionRequest(peerAci: "aci-1"))
        XCTAssertEqual(String(decoding: add, as: UTF8.self), #"{"peer_aci":"aci-1"}"#)
        let list = try JSONEncoder().encode(FeedAudienceListRequest(kind: "include", peerAcis: ["a", "b"]))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: list) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "include")
        XCTAssertEqual(object["peer_acis"] as? [String], ["a", "b"])
        XCTAssertEqual(try JSONDecoder().decode(FeedFriendAssertionResponse.self, from: Data(#"{"assertion":"jwt"}"#.utf8)).assertion, "jwt")
        XCTAssertEqual(try JSONDecoder().decode(FeedAudienceListResponse.self, from: Data(#"{"audience_token":"tok"}"#.utf8)).audienceToken, "tok")
        XCTAssertEqual(FeedSignerPaths.friendAssertions, "v1/tellomi/feed/friend-assertions")
        XCTAssertEqual(FeedSignerPaths.audienceLists, "v1/tellomi/feed/audience-lists")
    }

    func testReportFriendPostsTheAssertionVerbatimAndReadsConfirmed() async throws {
        let (api, transport) = make()
        transport.reply(200, #"{"confirmed":true}"#)
        transport.reply(200, "{}")
        let confirmed = try await api.reportFriend(assertion: "a.b.c")
        let half = try await api.reportFriend(assertion: "x")
        XCTAssertTrue(confirmed)
        XCTAssertFalse(half, "只报了自己这一半")
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertEqual(transport.requests[0].url?.path, "/v1/feed/friends")
        XCTAssertEqual(body(transport.requests[0]), #"{"assertion":"a.b.c"}"#)
        let source = RemoteFeedSource(api: api)
        transport.reply(200, #"{"confirmed":true}"#)
        let viaSource = try await source.reportFriend(assertion: "z")
        XCTAssertTrue(viaSource)
    }

    private final class Signer: FeedFriendSigning, @unchecked Sendable {
        let audiences = CallLog<String>()
        var tokenError: Error?
        func friendAssertion(peerAci: String, add: Bool) async throws -> String? { nil }
        func audienceToken(kind: String, peerAcis: [String]) async throws -> String {
            audiences.append("\(kind) \(peerAcis.joined(separator: ","))")
            if let tokenError { throw tokenError }
            return "tok-1"
        }
    }

    private func draft(_ visibility: FeedVisibility, _ acis: [String]) -> FeedDraft {
        var d = FeedDraft()
        d.text = "hello"
        d.visibility = visibility
        d.audience = acis.enumerated().map { FeedAudienceMember(recipientId: Int64($0.offset + 1), aci: $0.element) }
        return d
    }

    func testPublishingToAnAudienceSignsTheDedupedListAndSendsTheToken() async throws {
        let (api, transport) = make()
        transport.reply(200, #"{"id":"p1","state":"pending","version":1}"#)
        let signer = Signer()
        let source = RemoteFeedSource(api: api, audienceSigner: signer)
        let response = try await source.publish(draft: draft(.include, ["b", "a", "b", "c", "a"]), clientNonce: "n1")
        XCTAssertEqual(response.id, "p1")
        XCTAssertEqual(signer.audiences.all, ["include b,a,c"], "同一个人只交一次，顺序不变")
        let sent = body(transport.requests[0])
        XCTAssertTrue(sent.contains(#""audience":{"audience_token":"tok-1"}"#), sent)
        XCTAssertTrue(sent.contains(#""visibility":"include""#), sent)
        XCTAssertFalse(sent.contains("peer"), "客户端不把别人的 ACI 发给引擎")
    }

    func testOtherVisibilitiesNeverTouchTheSignerAndAMissingSignerStopsBeforeAnyRequest() async throws {
        let (api, transport) = make()
        transport.reply(200, #"{"id":"p1","state":"published"}"#)
        let signer = Signer()
        let source = RemoteFeedSource(api: api, audienceSigner: signer)
        _ = try await source.publish(draft: draft(.friends, ["a"]), clientNonce: "n")
        XCTAssertEqual(signer.audiences.all, [], "别的档位不发名单（切回来还在草稿里）")
        XCTAssertFalse(body(transport.requests[0]).contains("audience"))

        let bare = RemoteFeedSource(api: api)
        do {
            _ = try await bare.publish(draft: draft(.exclude, ["a"]), clientNonce: "n")
            XCTFail("没有签名来源时不能发这两档")
        } catch FeedPublishError.feedNotAvailable {}
        XCTAssertEqual(transport.requests.count, 1, "没有多发请求")

        signer.tokenError = FeedAPIError(status: 400, code: "invalid_audience", retryAfterSeconds: nil)
        do {
            _ = try await source.publish(draft: draft(.exclude, ["a"]), clientNonce: "n")
            XCTFail("签名失败要抛出")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.code, "invalid_audience")
        }
        XCTAssertEqual(transport.requests.count, 1, "名单签不出来，帖子不发")
    }

    func testAudienceProblems() {
        let limits = FeedLimits()
        var d = FeedDraft()
        d.text = "x"
        d.visibility = .include
        XCTAssertEqual(d.problem(limits: limits, minorMode: false), .missingAudience)
        d.audience = (0..<500).map { FeedAudienceMember(recipientId: Int64($0), aci: "a\($0)") }
        XCTAssertNil(d.problem(limits: limits, minorMode: false))
        d.audience.append(FeedAudienceMember(recipientId: 999, aci: "extra"))
        XCTAssertEqual(d.problem(limits: limits, minorMode: false), .audienceTooLarge)
        d.visibility = .public
        XCTAssertNil(d.problem(limits: limits, minorMode: false), "公开不看名单")
        d.visibility = .exclude
        d.audience = []
        XCTAssertEqual(d.problem(limits: limits, minorMode: false), .missingAudience)
    }

    func testDefaultSourceDoesNotPretendToReportFriends() async {
        final class Bare: FeedSource {
            func config() async throws -> FeedConfig { FeedConfig() }
            func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
            func setLiked(contentId: String, liked: Bool) async throws {}
            func notInterested(contentId: String) async throws {}
            func undoNotInterested(contentId: String) async throws {}
            func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
            func reportEvents(_ events: [FeedEventPayload]) async throws {}
        }
        do {
            _ = try await Bare().reportFriend(assertion: "x")
            XCTFail("没有引擎时不能装作报成功")
        } catch {}
    }
}

// MARK: - sync

private final class FakeSigner: FeedFriendSigning, @unchecked Sendable {
    private let lock = NSLock()
    private var _noAccount = Set<String>()
    private var _failOn: String?
    let calls = CallLog<String>()
    var noAccount: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _noAccount }
        set { lock.lock(); _noAccount = newValue; lock.unlock() }
    }
    var failOn: String? {
        get { lock.lock(); defer { lock.unlock() }; return _failOn }
        set { lock.lock(); _failOn = newValue; lock.unlock() }
    }
    func friendAssertion(peerAci: String, add: Bool) async throws -> String? {
        calls.append("\(add ? "add" : "remove") \(peerAci)")
        if peerAci == failOn { throw Boom() }
        if add && noAccount.contains(peerAci) { return nil }
        return "assert-\(add ? "add" : "remove")-\(peerAci)"
    }
    func audienceToken(kind: String, peerAcis: [String]) async throws -> String { "" }
}

private final class Env: @unchecked Sendable {
    private let lock = NSLock()
    private var _friends = Set<String>()
    private var _now = FeedDates.parse("2026-10-13T12:00:00Z")!
    private var _enabled = true
    private var _engineKey = "cn https://feed.example.test"
    let engineCalls = CallLog<String>()
    var friends: Set<String> { get { lock.lock(); defer { lock.unlock() }; return _friends } set { lock.lock(); _friends = newValue; lock.unlock() } }
    var now: Date { get { lock.lock(); defer { lock.unlock() }; return _now } set { lock.lock(); _now = newValue; lock.unlock() } }
    var enabled: Bool { get { lock.lock(); defer { lock.unlock() }; return _enabled } set { lock.lock(); _enabled = newValue; lock.unlock() } }
    var engineKey: String { get { lock.lock(); defer { lock.unlock() }; return _engineKey } set { lock.lock(); _engineKey = newValue; lock.unlock() } }
    let friendReads = CallLog<Int>()
}

final class TellomiFeedFriendSyncTests: XCTestCase {
    private func make(_ env: Env, signer: FakeSigner = FakeSigner(), state: FeedFriendSyncState = InMemoryFeedFriendSyncState()) -> (FeedFriendSync, FakeSigner, FeedFriendSyncState) {
        let sync = FeedFriendSync(
            enabled: { env.enabled },
            engineKey: { env.engineKey },
            friends: { env.friendReads.append(1); return env.friends },
            signer: signer,
            engine: { env.engineCalls.append($0) },
            state: state,
            features: StaticFeedFeatureGate([FeedFeature.friendAssertions]),
            clock: { env.now }
        )
        return (sync, signer, state)
    }

    func testDisabledDoesNothing() async {
        let env = Env()
        env.enabled = false
        env.friends = ["a"]
        let (sync, signer, state) = make(env)
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(signer.calls.all, [])
        XCTAssertNil(state.checkedAt)
        XCTAssertEqual(env.friendReads.all.count, 0)
    }

    func testFirstRunReportsEveryFriendSortedAndRemembersThem() async {
        let env = Env()
        env.friends = ["c", "a", "b"]
        let (sync, signer, state) = make(env)
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(signer.calls.all, ["add a", "add b", "add c"])
        XCTAssertEqual(env.engineCalls.all, ["assert-add-a", "assert-add-b", "assert-add-c"], "签名原样交给引擎")
        XCTAssertEqual(state.reported(engineKey: env.engineKey), ["a", "b", "c"])
        XCTAssertEqual(state.checkedAt, env.now)
    }

    func testRunsOnlyEveryFifteenMinutesAndOnlyTalksWhenSomethingChanged() async {
        let env = Env()
        env.friends = ["a"]
        let (sync, signer, _) = make(env)
        _ = await sync.syncIfStale()
        env.now = env.now.addingTimeInterval(14 * 60 + 59)
        env.friends = ["a", "b"]
        let early = await sync.syncIfStale()
        XCTAssertEqual(early, .skipped)
        XCTAssertEqual(signer.calls.all, ["add a"])
        env.now = env.now.addingTimeInterval(2)
        env.friends = ["a"]   // 没变
        let same = await sync.syncIfStale()
        XCTAssertEqual(same, .unchanged)
        XCTAssertEqual(signer.calls.all, ["add a"], "名单没变不走网络")
    }

    func testRemovalsGoBeforeAdditions() async {
        let env = Env()
        env.friends = ["a", "b"]
        let (sync, signer, state) = make(env)
        _ = await sync.syncIfStale()
        env.now = env.now.addingTimeInterval(16 * 60)
        env.friends = ["b", "c", "d"]
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(Array(signer.calls.all.dropFirst(2)), ["remove a", "add c", "add d"])
        XCTAssertEqual(env.engineCalls.all.suffix(3), ["assert-remove-a", "assert-add-c", "assert-add-d"])
        XCTAssertEqual(state.reported(engineKey: env.engineKey), ["b", "c", "d"])
    }

    func testAFriendWithoutAnAccountIsNotReportedButIsRemembered() async {
        let env = Env()
        env.friends = ["a", "ghost"]
        let signer = FakeSigner()
        signer.noAccount = ["ghost"]
        let (sync, _, state) = make(env, signer: signer)
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(env.engineCalls.all, ["assert-add-a"], "没账号的不交给引擎")
        XCTAssertEqual(state.reported(engineKey: env.engineKey), ["a", "ghost"], "记下来，下次不再问")
    }

    func testAFailureStopsThereKeepsProgressAndResumesNextTime() async {
        let env = Env()
        env.friends = ["a", "b", "c"]
        let signer = FakeSigner()
        signer.failOn = "b"
        let (sync, _, state) = make(env, signer: signer)
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(state.reported(engineKey: env.engineKey), ["a"], "做完的部分已经记下")
        XCTAssertEqual(env.engineCalls.all, ["assert-add-a"])
        let tooSoon = await sync.syncIfStale()
        XCTAssertEqual(tooSoon, .skipped, "失败也算检查过，等满 15 分钟再试")
        signer.failOn = nil
        env.now = env.now.addingTimeInterval(15 * 60)
        let retry = await sync.syncIfStale()
        XCTAssertEqual(retry, .done)
        XCTAssertEqual(state.reported(engineKey: env.engineKey), ["a", "b", "c"])
        XCTAssertEqual(env.engineCalls.all, ["assert-add-a", "assert-add-b", "assert-add-c"])
    }

    func testAnEngineFailureAlsoStopsWithoutRecordingThatFriend() async {
        let env = Env()
        env.friends = ["a", "b", "c"]
        let state = InMemoryFeedFriendSyncState()
        let sync = FeedFriendSync(
            enabled: { true }, engineKey: { "k" }, friends: { env.friends }, signer: FakeSigner(),
            engine: { assertion in
                env.engineCalls.append(assertion)
                if assertion.hasSuffix("-b") { throw Boom() }
            },
            state: state, features: StaticFeedFeatureGate([FeedFeature.friendAssertions]), clock: { env.now }
        )
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(state.reported(engineKey: "k"), ["a"], "引擎没收的那个不记，下次还会报")
        XCTAssertEqual(env.engineCalls.all, ["assert-add-a", "assert-add-b"], "停在失败那里")
    }

    func testMoreThanFiftyChangesAreSpreadOverRunsWithoutWaiting() async {
        let env = Env()
        env.friends = Set((0..<120).map { String(format: "f%03d", $0) })
        let (sync, signer, state) = make(env)
        let first = await sync.syncIfStale()
        XCTAssertEqual(first, .moreLeft)
        XCTAssertEqual(signer.calls.all.count, 50)
        XCTAssertNil(state.checkedAt, "下次回到前台就接着做，不等 15 分钟")
        let second = await sync.syncIfStale()
        XCTAssertEqual(second, .moreLeft)
        XCTAssertEqual(signer.calls.all.count, 100)
        let third = await sync.syncIfStale()
        XCTAssertEqual(third, .done)
        XCTAssertEqual(state.reported(engineKey: env.engineKey).count, 120)
        XCTAssertEqual(Set(signer.calls.all).count, 120, "没有重复报")
    }

    func testSwitchingEngineReportsEveryoneAgain() async {
        let env = Env()
        env.friends = ["a"]
        let (sync, signer, state) = make(env)
        _ = await sync.syncIfStale()
        env.engineKey = "global https://feed2.example.test"
        env.now = env.now.addingTimeInterval(20 * 60)
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(signer.calls.all, ["add a", "add a"], "换了引擎（切区）重新报一遍")
        XCTAssertEqual(state.reported(engineKey: "global https://feed2.example.test"), ["a"])
        XCTAssertEqual(state.reported(engineKey: "cn https://feed.example.test"), [], "旧引擎那份不再认")
    }

    func testAClockThatWentBackwardsDoesNotCountAsJustChecked() async {
        let env = Env()
        env.friends = ["a"]
        let (sync, signer, _) = make(env)
        _ = await sync.syncIfStale()
        env.now = env.now.addingTimeInterval(-3600)
        env.friends = ["a", "b"]
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(signer.calls.all, ["add a", "add b"])
    }

    func testStoredStateSurvivesARestartAndToleratesBadData() throws {
        let storage = InMemoryFeedStorage()
        let first = StoredFeedFriendSyncState(storage: storage)
        XCTAssertNil(first.checkedAt)
        XCTAssertEqual(first.reported(engineKey: "k"), [])
        let when = Date(timeIntervalSince1970: 1_791_000_000)
        first.checkedAt = when
        first.save(engineKey: "k", acis: ["b", "a"])
        let second = StoredFeedFriendSyncState(storage: storage)
        XCTAssertEqual(second.checkedAt, when)
        XCTAssertEqual(second.reported(engineKey: "k"), ["a", "b"])
        XCTAssertEqual(second.reported(engineKey: "other"), [], "引擎不同当作没报过")
        second.checkedAt = nil
        XCTAssertNil(StoredFeedFriendSyncState(storage: storage).checkedAt)
        storage.set(Data("junk".utf8), forKey: StoredFeedFriendSyncState.reportedKey)
        XCTAssertEqual(StoredFeedFriendSyncState(storage: storage).reported(engineKey: "k"), [])
    }
}

// MARK: - compose store

private final class NullSource: FeedSource {
    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
}

@MainActor
final class TellomiFeedAudiencePickTests: XCTestCase {
    private func store(minor: Bool = false) async -> FeedComposeStore {
        let store = FeedComposeStore(source: NullSource(), articleDrafts: InMemoryFeedArticleDrafts(), clientNonce: "n")
        if minor {
            // 手动模拟 minor 配置：通过 config 读
            final class Minor: FeedSource {
                func config() async throws -> FeedConfig { var c = FeedConfig(); c.minorMode = true; return c }
                func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
                func setLiked(contentId: String, liked: Bool) async throws {}
                func notInterested(contentId: String) async throws {}
                func undoNotInterested(contentId: String) async throws {}
                func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
                func reportEvents(_ events: [FeedEventPayload]) async throws {}
            }
            let minorStore = FeedComposeStore(source: Minor(), articleDrafts: InMemoryFeedArticleDrafts(), clientNonce: "n")
            minorStore.start()
            minorStore.refreshFeatures(StaticFeedFeatureGate([FeedFeature.audienceTokens]))
            await minorStore.waitForTasks()
            return minorStore
        }
        store.refreshFeatures(StaticFeedFeatureGate([FeedFeature.audienceTokens]))
        await store.waitForTasks()
        return store
    }

    func testPickingPeopleSwitchesTheTier() async {
        let store = await store()
        let members = [FeedAudienceMember(recipientId: 1, aci: "a"), FeedAudienceMember(recipientId: 2, aci: "b")]
        store.onAudiencePicked(.include, [])
        XCTAssertEqual(store.state.draft.visibility, .public, "一个没选就保持原来的档位")
        store.onAudiencePicked(.friends, members)
        XCTAssertEqual(store.state.draft.visibility, .public, "不需要选人的档位不走这里")
        store.onAudiencePicked(.include, members)
        XCTAssertEqual(store.state.draft.visibility, .include)
        XCTAssertEqual(store.state.draft.audience, members)
        store.onVisibilityChanged(.friends)
        XCTAssertEqual(store.state.draft.audience, members, "切到别的档，名单留着")
        store.onTextChanged("hi")
        XCTAssertEqual(store.state.problem, nil)
        store.onAudiencePicked(.exclude, [members[0]])
        XCTAssertEqual(store.state.draft.visibility, .exclude)
        XCTAssertEqual(store.state.draft.audience, [members[0]])
        store.pickingAudienceFor = .include
        XCTAssertEqual(store.pickingAudienceFor, .include)
    }

    func testMinorsCannotPickAnAudienceTier() async {
        let store = await store(minor: true)
        XCTAssertEqual(store.state.draft.visibility, .friends)
        store.onAudiencePicked(.include, [FeedAudienceMember(recipientId: 1, aci: "a")])
        XCTAssertEqual(store.state.draft.visibility, .friends)
        XCTAssertEqual(store.state.draft.audience, [])
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
