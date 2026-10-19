//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedCapabilitiesTests.swift (new file)
// I-19: `GET /v1/capabilities` client (parse, fetch, cache) and the friend/audience gates built on it.
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

private actor Gate {
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let all = waiters
        waiters = []
        all.forEach { $0.resume() }
    }
}

private enum Reply {
    case body(Int, String)
    case fail(Error)
    /// 一直不回（直到被取消）
    case hang
}

private final class ScriptedTransport: FeedHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests = [URLRequest]()
    private var replies = [Reply]()
    func reply(_ reply: Reply) { lock.lock(); replies.append(reply); lock.unlock() }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next = lock.locked {
            _requests.append(request)
            return replies.isEmpty ? Reply.fail(Boom()) : (replies.count == 1 ? replies[0] : replies.removeFirst())
        }
        switch next {
        case let .body(status, body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        case let .fail(error):
            throw error
        case .hang:
            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            throw Boom()
        }
    }
}

private let realBody = #"{"version":1,"features":["feed","events","posting","audience_tokens","comments","reactions","polls","friend_assertions","follow","blocks","profiles","search","topics","notifications","reports","voice_comments","media_upload","media_url"]}"#

final class TellomiFeedCapabilitiesParseTests: XCTestCase {
    func testParsesTheRealShapeAndKeepsUnknownNames() throws {
        let parsed = try FeedCapabilities.parse(Data(realBody.utf8))
        XCTAssertEqual(parsed.version, 1)
        XCTAssertEqual(parsed.features.count, 18)
        XCTAssertTrue(parsed.features.contains(FeedFeature.friendAssertions))
        XCTAssertTrue(parsed.features.contains(FeedFeature.audienceTokens))
        let noisy = try FeedCapabilities.parse(Data(#"{"version":1,"features":["feed","hologram",7,null,"feed",{"a":1}],"extra":true}"#.utf8))
        XCTAssertEqual(noisy.features, ["feed", "hologram"], "不是字符串的丢掉，不认识的名字留着，重复合并")
        XCTAssertEqual(try FeedCapabilities.parse(Data(#"{"version":1,"features":[]}"#.utf8)), FeedCapabilities(version: 1, features: []))
    }

    /// tellomi测试 2026-10-16：`version` 必须是整数 1，否则当作没有能力检查（和 Android 一致）；`features` 不读。
    func testOnlyVersionOneIsAccepted() {
        let features = #""features":["feed","friend_assertions","audience_tokens"]"#
        for version in ["0", "2", "3", "-1", "100", "1.5", "1.0", "1e0", "true", "false", "null", #""1""#, #""""#, #"{"v":1}"#, "[1]"] {
            XCTAssertThrowsError(try FeedCapabilities.parse(Data(#"{"version":\#(version),\#(features)}"#.utf8)), "version \(version) 不认") { error in
                XCTAssertEqual(error as? FeedCapabilitiesError, .malformed)
            }
        }
        XCTAssertThrowsError(try FeedCapabilities.parse(Data(#"{\#(features)}"#.utf8)), "缺 version") { error in
            XCTAssertEqual(error as? FeedCapabilitiesError, .malformed)
        }
        XCTAssertEqual(try FeedCapabilities.parse(Data(#"{"version":1,\#(features)}"#.utf8)).features, ["feed", "friend_assertions", "audience_tokens"])
        // version 放在 features 后面也一样（键的顺序无关）
        XCTAssertEqual(try FeedCapabilities.parse(Data(#"{\#(features),"version":1}"#.utf8)).version, 1)
        XCTAssertThrowsError(try FeedCapabilities.parse(Data(#"{\#(features),"version":2}"#.utf8)))
    }

    func testMalformedBodiesAreRejected() {
        for body in ["", "not json", "[]", #"["feed"]"#, "{}", #"{"version":1}"#, #"{"version":1,"features":"feed"}"#,
                     #"{"version":1,"features":{"feed":true}}"#, "<html>captive portal</html>", #"{"features":null}"#] {
            XCTAssertThrowsError(try FeedCapabilities.parse(Data(body.utf8)), "应该解析失败: \(body)") { error in
                XCTAssertEqual(error as? FeedCapabilitiesError, .malformed)
            }
        }
    }

    func testFeatureNamesMatchTheEngineContract() {
        XCTAssertEqual(
            [FeedFeature.feed, FeedFeature.events, FeedFeature.posting, FeedFeature.audienceTokens, FeedFeature.comments,
             FeedFeature.voiceComments, FeedFeature.reactions, FeedFeature.polls, FeedFeature.mediaUpload, FeedFeature.mediaUrl,
             FeedFeature.friendAssertions, FeedFeature.follow, FeedFeature.blocks, FeedFeature.profiles, FeedFeature.search,
             FeedFeature.topics, FeedFeature.notifications, FeedFeature.reports],
            ["feed", "events", "posting", "audience_tokens", "comments", "voice_comments", "reactions", "polls", "media_upload",
             "media_url", "friend_assertions", "follow", "blocks", "profiles", "search", "topics", "notifications", "reports"]
        )
        XCTAssertFalse(Set(try! FeedCapabilities.parse(Data(realBody.utf8)).features).contains("friend_sync"), "引擎没有 friend_sync / friend_report")
    }
}

final class TellomiFeedCapabilitiesFetchTests: XCTestCase {
    private func fetcher(_ transport: ScriptedTransport, base: String = "https://feed.example.test", timeout: TimeInterval = 5) -> FeedCapabilitiesFetcher {
        FeedCapabilitiesFetcher(baseURL: URL(string: base)!, transport: transport, timeout: timeout)
    }

    func testRequestIsAnUnauthenticatedGetWithATimeout() async throws {
        let transport = ScriptedTransport()
        transport.reply(.body(200, realBody))
        for base in ["https://feed.example.test", "https://feed.example.test/", "https://host.test/engine/"] {
            _ = try await fetcher(transport, base: base).fetch()
        }
        let urls = transport.requests.map { $0.url!.absoluteString }
        XCTAssertEqual(urls, ["https://feed.example.test/v1/capabilities", "https://feed.example.test/v1/capabilities", "https://host.test/engine/v1/capabilities"])
        for request in transport.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "不带凭证")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.timeoutInterval, 5)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        }
    }

    func testStatusAndBodyErrors() async {
        let cases: [(Reply, FeedCapabilitiesError)] = [
            (.body(404, #"{"error":"not_found"}"#), .notFound),
            (.body(500, ""), .http(500)), (.body(503, "busy"), .http(503)), (.body(429, ""), .throttled(retryAfterSeconds: nil)),
            (.body(405, ""), .http(405)), (.body(401, ""), .http(401)),
            (.body(200, "not json"), .malformed), (.body(200, "{}"), .malformed),
            (.body(200, #"{"version":1,"features":["a"],"pad":""#.appending(String(repeating: "x", count: 70_000)) + #""}"#), .malformed),
            (.fail(URLError(.timedOut)), .timeout), (.fail(URLError(.notConnectedToInternet)), .transport), (.fail(Boom()), .transport),
        ]
        for (reply, expected) in cases {
            let transport = ScriptedTransport()
            transport.reply(reply)
            do {
                _ = try await fetcher(transport).fetch()
                XCTFail("should fail: \(expected)")
            } catch {
                XCTAssertEqual(error as? FeedCapabilitiesError, expected)
            }
        }
    }

    /// 版本不对 = 和 404 / 失败一样什么功能都没有：`features` 里写了 friend_assertions 也不开（好友同步、受众档都关着）。
    func testAnUnsupportedVersionTurnsEveryGatedFeatureOffEvenWhenFeaturesAreListed() async {
        let features = #""features":["feed","friend_assertions","audience_tokens"]"#
        for body in [#"{"version":0,\#(features)}"#, #"{"version":2,\#(features)}"#, "{\(features)}", #"{"version":"1",\#(features)}"#, #"{"version":1.0,\#(features)}"#] {
            let transport = ScriptedTransport()
            transport.reply(.body(200, body))
            let cache = FeedCapabilitiesCache(fetcher: fetcher(transport))
            let snapshot = await cache.current()
            XCTAssertEqual(snapshot, .unavailable(.malformed), body)
            let friendEntry = await FeedFriendEntry.syncAvailable(cache)
            XCTAssertFalse(friendEntry, body)
            let audienceTiers = await FeedFriendEntry.audienceAvailable(cache)
            XCTAssertFalse(audienceTiers, body)
            let feed = await cache.isAvailable(FeedFeature.feed)
            XCTAssertFalse(feed, body)
        }
        // 对照：同样的 features，version 是 1 就开
        let ok = ScriptedTransport()
        ok.reply(.body(200, #"{"version":1,\#(features)}"#))
        let cache = FeedCapabilitiesCache(fetcher: fetcher(ok))
        let entry = await FeedFriendEntry.syncAvailable(cache)
        XCTAssertTrue(entry)
    }

    func testAHungConnectionIsGivenUpOnAfterTheTimeout() async {
        let transport = ScriptedTransport()
        transport.reply(.hang)
        let started = Date()
        do {
            _ = try await fetcher(transport, timeout: 0.1).fetch()
            XCTFail("should time out")
        } catch {
            XCTAssertEqual(error as? FeedCapabilitiesError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

private final class ScriptedFetcher: FeedCapabilitiesFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var script = [Result<FeedCapabilities, Error>]()
    private var _calls = 0
    var gate: Gate?
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func push(_ result: Result<FeedCapabilities, Error>) { lock.lock(); script.append(result); lock.unlock() }
    func fetch() async throws -> FeedCapabilities {
        let (result, gate) = lock.locked {
            _calls += 1
            let result = script.count > 1 ? script.removeFirst() : (script.first ?? .failure(Boom()))
            return (result, self.gate)
        }
        if let gate { await gate.wait() }
        return try result.get()
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_791_000_000)
    var now: Date { get { lock.lock(); defer { lock.unlock() }; return _now } set { lock.lock(); _now = newValue; lock.unlock() } }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private func caps(_ names: String...) -> FeedCapabilities { FeedCapabilities(features: Set(names)) }

final class TellomiFeedCapabilitiesCacheTests: XCTestCase {
    private func make(_ fetcher: ScriptedFetcher, _ clock: Clock) -> FeedCapabilitiesCache {
        FeedCapabilitiesCache(fetcher: fetcher, clock: { clock.now })
    }

    func testSuccessIsCachedForSixtySecondsThenRefetched() async {
        let fetcher = ScriptedFetcher(), clock = Clock()
        fetcher.push(.success(caps("feed", "friend_assertions")))
        fetcher.push(.success(caps("feed")))
        let cache = make(fetcher, clock)
        let first = await cache.isAvailable(FeedFeature.friendAssertions)
        XCTAssertTrue(first)
        clock.advance(59.9)
        let still = await cache.isAvailable(FeedFeature.friendAssertions)
        XCTAssertTrue(still)
        XCTAssertEqual(fetcher.calls, 1)
        clock.advance(0.1)
        let later = await cache.isAvailable(FeedFeature.friendAssertions)
        XCTAssertFalse(later, "到 60 秒就重新问；新答案没有了就是没有了")
        XCTAssertEqual(fetcher.calls, 2)
    }

    func testAMissingFeatureIsUnavailableAndOthersStillWork() async {
        let fetcher = ScriptedFetcher()
        fetcher.push(.success(caps("feed", "events")))
        let cache = make(fetcher, Clock())
        let friends = await cache.isAvailable(FeedFeature.friendAssertions)
        let audience = await cache.isAvailable(FeedFeature.audienceTokens)
        let feed = await cache.isAvailable(FeedFeature.feed)
        XCTAssertFalse(friends)
        XCTAssertFalse(audience)
        XCTAssertTrue(feed)
        XCTAssertEqual(fetcher.calls, 1)
    }

    func testFailureMeansDisabledIsRememberedForThirtySecondsAndRecovers() async {
        let fetcher = ScriptedFetcher(), clock = Clock()
        fetcher.push(.failure(FeedCapabilitiesError.timeout))
        fetcher.push(.success(caps("friend_assertions")))
        let cache = make(fetcher, clock)
        let snapshot = await cache.current()
        XCTAssertEqual(snapshot, .unavailable(.timeout))
        clock.advance(29.9)
        let still = await cache.isAvailable(FeedFeature.friendAssertions)
        XCTAssertFalse(still)
        XCTAssertEqual(fetcher.calls, 1, "30 秒内不重试")
        clock.advance(0.1)
        let recovered = await cache.isAvailable(FeedFeature.friendAssertions)
        XCTAssertTrue(recovered)
        XCTAssertEqual(fetcher.calls, 2)
    }

    func testAFailureAfterASuccessDoesNotKeepServingTheOldAnswer() async {
        let fetcher = ScriptedFetcher(), clock = Clock()
        fetcher.push(.success(caps("friend_assertions")))
        fetcher.push(.failure(FeedCapabilitiesError.http(503)))
        let cache = make(fetcher, clock)
        let before = await cache.isAvailable(FeedFeature.friendAssertions)
        XCTAssertTrue(before)
        clock.advance(61)
        let after = await cache.isAvailable(FeedFeature.friendAssertions)
        XCTAssertFalse(after, "失败按「没有」算，不拿旧的顶")
    }

    func testNotFoundMeansServerTooOldAndIsRememberedForTenMinutes() async {
        let fetcher = ScriptedFetcher(), clock = Clock()
        fetcher.push(.failure(FeedCapabilitiesError.notFound))
        fetcher.push(.success(caps("friend_assertions")))
        let cache = make(fetcher, clock)
        let snapshot = await cache.current()
        XCTAssertEqual(snapshot, .unavailable(.notFound))
        clock.advance(599)
        let still = await cache.isAvailable(FeedFeature.friendAssertions)
        XCTAssertFalse(still)
        XCTAssertEqual(fetcher.calls, 1)
        clock.advance(1)
        let upgraded = await cache.isAvailable(FeedFeature.friendAssertions)
        XCTAssertTrue(upgraded, "10 分钟后重新问：引擎部署了新版就好了")
    }

    func testConcurrentAskersShareOneRequest() async {
        let fetcher = ScriptedFetcher()
        fetcher.push(.success(caps("friend_assertions")))
        let gate = Gate()
        fetcher.gate = gate
        let cache = make(fetcher, Clock())
        async let a = cache.isAvailable(FeedFeature.friendAssertions)
        async let b = cache.isAvailable(FeedFeature.friendAssertions)
        async let c = cache.isAvailable(FeedFeature.audienceTokens)
        for _ in 0..<2000 where await gate.arrivals == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await gate.open()
        let results = await [a, b, c]
        XCTAssertEqual(results, [true, true, false])
        XCTAssertEqual(fetcher.calls, 1)
    }

    func testClockGoingBackwardsAndInvalidateBothForceARefetch() async {
        let fetcher = ScriptedFetcher(), clock = Clock()
        fetcher.push(.success(caps("a")))
        let cache = make(fetcher, clock)
        _ = await cache.current()
        clock.advance(-5)
        _ = await cache.current()
        XCTAssertEqual(fetcher.calls, 2, "时钟被调回去不算「刚问过」")
        clock.advance(5)
        _ = await cache.current()
        XCTAssertEqual(fetcher.calls, 2)
        await cache.invalidate()
        _ = await cache.current()
        XCTAssertEqual(fetcher.calls, 3)
    }

    func testAnAnswerThatArrivesAfterInvalidateIsNotCached() async {
        let fetcher = ScriptedFetcher()
        fetcher.push(.success(caps("old")))
        let gate = Gate()
        fetcher.gate = gate
        let cache = make(fetcher, Clock())
        async let stale = cache.current()
        for _ in 0..<2000 where await gate.arrivals == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
        await cache.invalidate()
        fetcher.push(.success(caps("new")))
        await gate.open()
        let first = await stale
        XCTAssertEqual(first, .available(caps("old")), "等着的人拿到自己问的那次")
        // 注意：脚本只剩一条时会重复用最后一条
        let next = await cache.current()
        XCTAssertGreaterThanOrEqual(fetcher.calls, 2, "invalidate 之后的结果没进缓存，要重新问")
        _ = next
    }
}

private final class GateSigner: FeedFriendSigning, @unchecked Sendable {
    let calls = CallLog<String>()
    func friendAssertion(peerAci: String, add: Bool) async throws -> String? {
        calls.append("sign \(peerAci)")
        return "assert-\(peerAci)"
    }
    func audienceToken(kind: String, peerAcis: [String]) async throws -> String { "" }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// 名单里的功能可以变（测试里模拟引擎升级）。
private final class MutableGate: FeedFeatureGate, @unchecked Sendable {
    private let lock = NSLock()
    private var _features = Set<String>()
    var features: Set<String> { get { lock.lock(); defer { lock.unlock() }; return _features } set { lock.lock(); _features = newValue; lock.unlock() } }
    func isAvailable(_ feature: String) async -> Bool { features.contains(feature) }
}

final class TellomiFeedFriendGateTests: XCTestCase {
    private func sync(_ gate: FeedFeatureGate, signer: GateSigner, engine: CallLog<String>, reads: Counter, state: FeedFriendSyncState) -> FeedFriendSync {
        FeedFriendSync(
            enabled: { true }, engineKey: { "k" }, friends: { reads.bump(); return ["a", "b"] }, signer: signer,
            engine: { engine.append($0) }, state: state, features: gate,
            clock: { Date(timeIntervalSince1970: 1_791_000_000) }
        )
    }

    func testWithoutFriendAssertionsNothingIsReadSignedOrRecorded() async {
        for gateFeatures: Set<String> in [[], ["feed", "audience_tokens", "friend_sync", "friend_report"]] {
            let signer = GateSigner(), engine = CallLog<String>(), reads = Counter(), state = InMemoryFeedFriendSyncState()
            let sync = sync(StaticFeedFeatureGate(gateFeatures), signer: signer, engine: engine, reads: reads, state: state)
            let outcome = await sync.syncIfStale()
            XCTAssertEqual(outcome, .notSupported)
            XCTAssertEqual(signer.calls.all, [])
            XCTAssertEqual(engine.all, [])
            XCTAssertEqual(reads.value, 0, "不读好友名单")
            XCTAssertNil(state.checkedAt, "没记「检查过」，功能一出现下次就做")
            XCTAssertEqual(state.reported(engineKey: "k"), [])
        }
    }

    func testItSyncsAsSoonAsTheEngineAnnouncesTheFeature() async {
        let gate = MutableGate()
        let signer = GateSigner(), engine = CallLog<String>(), reads = Counter(), state = InMemoryFeedFriendSyncState()
        let sync = sync(gate, signer: signer, engine: engine, reads: reads, state: state)
        let first = await sync.syncIfStale()
        XCTAssertEqual(first, .notSupported)
        gate.features = [FeedFeature.friendAssertions]
        let second = await sync.syncIfStale()
        XCTAssertEqual(second, .done)
        XCTAssertEqual(engine.all, ["assert-a", "assert-b"])
        XCTAssertEqual(state.reported(engineKey: "k"), ["a", "b"])
    }

    func testTheRealCacheGatesIt() async {
        let fetcher = ScriptedFetcher()
        fetcher.push(.failure(FeedCapabilitiesError.notFound))
        let cache = FeedCapabilitiesCache(fetcher: fetcher)
        let signer = GateSigner(), engine = CallLog<String>(), reads = Counter()
        let sync = sync(cache, signer: signer, engine: engine, reads: reads, state: InMemoryFeedFriendSyncState())
        let outcome = await sync.syncIfStale()
        XCTAssertEqual(outcome, .notSupported, "404：引擎太旧，不报")
        let entry = await FeedFriendEntry.syncAvailable(cache)
        XCTAssertFalse(entry)
        XCTAssertEqual(fetcher.calls, 1, "第二次问走缓存")
    }

    func testEntryHelpersLookAtTheRightNames() async {
        let both = StaticFeedFeatureGate(["friend_assertions", "audience_tokens"])
        let onlyFriends = StaticFeedFeatureGate(["friend_assertions"])
        let sync1 = await FeedFriendEntry.syncAvailable(both), aud1 = await FeedFriendEntry.audienceAvailable(both)
        let sync2 = await FeedFriendEntry.syncAvailable(onlyFriends), aud2 = await FeedFriendEntry.audienceAvailable(onlyFriends)
        XCTAssertEqual([sync1, aud1, sync2, aud2], [true, true, true, false])
    }
}

private final class NullSource: FeedSource, @unchecked Sendable {
    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
}

@MainActor
final class TellomiFeedAudienceGateTests: XCTestCase {
    private let members = [FeedAudienceMember(recipientId: 1, aci: "a")]

    private func store() -> FeedComposeStore {
        FeedComposeStore(source: NullSource(), articleDrafts: InMemoryFeedArticleDrafts(), clientNonce: "n")
    }

    func testAudienceIsOffUntilTheEngineSaysSo() async {
        let store = store()
        XCTAssertFalse(store.state.audienceAvailable, "没问到之前不开")
        store.onAudiencePicked(.include, members)
        XCTAssertEqual(store.state.draft.visibility, .public)
        XCTAssertEqual(store.state.draft.audience, [])

        store.refreshFeatures(StaticFeedFeatureGate([FeedFeature.friendAssertions]))
        await store.waitForTasks()
        XCTAssertFalse(store.state.audienceAvailable, "只有 friend_assertions 不够，要 audience_tokens")

        store.refreshFeatures(StaticFeedFeatureGate([FeedFeature.audienceTokens]))
        await store.waitForTasks()
        XCTAssertTrue(store.state.audienceAvailable)
        store.onAudiencePicked(.include, members)
        XCTAssertEqual(store.state.draft.visibility, .include)
        XCTAssertEqual(store.state.draft.audience, members)
    }

    func testLosingTheFeatureResetsAnAudienceDraft() async {
        let store = store()
        store.refreshFeatures(StaticFeedFeatureGate([FeedFeature.audienceTokens]))
        await store.waitForTasks()
        store.onAudiencePicked(.exclude, members)
        XCTAssertEqual(store.state.draft.visibility, .exclude)

        let gate = MutableGate()
        store.refreshFeatures(gate)   // 引擎换了个旧版：没有 audience_tokens
        await store.waitForTasks()
        XCTAssertFalse(store.state.audienceAvailable)
        XCTAssertEqual(store.state.draft.visibility, FeedVisibility.defaultValue(minorMode: false))
        XCTAssertEqual(store.state.draft.audience, [])
    }

    func testAFailedCapabilityCheckClosesIt() async {
        let fetcher = ScriptedFetcher()
        fetcher.push(.failure(FeedCapabilitiesError.timeout))
        let store = store()
        store.refreshFeatures(FeedCapabilitiesCache(fetcher: fetcher))
        await store.waitForTasks()
        XCTAssertFalse(store.state.audienceAvailable)
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
