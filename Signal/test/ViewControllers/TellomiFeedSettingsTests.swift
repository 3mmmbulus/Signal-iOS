//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedSettingsTests.swift (new file)
// I-9: blocked keywords (local), settings API wire shapes, FeedRecommendationSettingsStore, FeedStore keyword filter.
// Mirrors Android FeedHideListsTest (keyword part) / FeedRecommendationSettingsViewModelTest.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

private let t0 = Date(timeIntervalSince1970: 1_791_889_200)

final class TellomiFeedBlockedKeywordsTests: XCTestCase {
    func testAddTrimsDedupesCaseInsensitivelyAndPutsTheNewestFirst() {
        let list = InMemoryFeedBlockedKeywords()
        list.add(keyword: "  Spoiler ", expiresAt: nil)
        list.add(keyword: "ads", expiresAt: nil)
        list.add(keyword: "   ", expiresAt: nil)
        XCTAssertEqual(list.active(now: t0).map(\.keyword), ["ads", "Spoiler"])
        list.add(keyword: "SPOILER", expiresAt: t0.addingTimeInterval(60))
        XCTAssertEqual(list.active(now: t0).map(\.keyword), ["SPOILER", "ads"], "同一个词换成新写法和新有效期，放最前")
        XCTAssertEqual(list.active(now: t0)[0].expiresAt, InMemoryFeedBlockedKeywords.millis(t0) + 60_000)
    }

    func testExpiredWordsAreNotActiveAndTheBoundaryIsExclusive() {
        let list = InMemoryFeedBlockedKeywords()
        list.add(keyword: "short", expiresAt: t0.addingTimeInterval(10))
        list.add(keyword: "forever", expiresAt: nil)
        XCTAssertEqual(Set(list.active(now: t0).map(\.keyword)), ["short", "forever"])
        XCTAssertEqual(list.active(now: t0.addingTimeInterval(9.999)).count, 2)
        XCTAssertEqual(list.active(now: t0.addingTimeInterval(10)).map(\.keyword), ["forever"], "到点就算过期（Android: expiresAt > now）")
    }

    func testRemoveIsExactMatchLikeAndroid() {
        let list = InMemoryFeedBlockedKeywords()
        list.add(keyword: "Spoiler", expiresAt: nil)
        list.remove(keyword: "spoiler")
        XCTAssertEqual(list.active(now: t0).count, 1)
        list.remove(keyword: "Spoiler")
        XCTAssertEqual(list.active(now: t0).count, 0)
    }

    func testStoredListSurvivesARestartDropsExpiredOnWriteAndIgnoresGarbage() {
        let storage = InMemoryFeedStorage()

        let first = StoredFeedBlockedKeywords(storage: storage)
        first.add(keyword: "old", expiresAt: Date().addingTimeInterval(-3600))   // 已过期的先存进去
        XCTAssertNil(storage.data(forKey: StoredFeedBlockedKeywords.key), "只有过期的词：不写")
        first.add(keyword: "keep", expiresAt: nil)
        first.add(keyword: "later", expiresAt: Date().addingTimeInterval(3600))

        let second = StoredFeedBlockedKeywords(storage: storage)
        XCTAssertEqual(second.active(now: Date()).map(\.keyword), ["later", "keep"])

        second.remove(keyword: "later")
        second.remove(keyword: "keep")
        XCTAssertNil(storage.data(forKey: StoredFeedBlockedKeywords.key), "空了就删键")

        storage.set(Data("not json".utf8), forKey: StoredFeedBlockedKeywords.key)
        XCTAssertEqual(StoredFeedBlockedKeywords(storage: storage).active(now: Date()), [])
    }

    func testStoredFormatIsAnArrayOfKeywordAndExpiresAt() throws {
        let storage = InMemoryFeedStorage()
        storage.set(Data(#"[{"keyword":"a","expiresAt":4102444800000},{"keyword":"b"}]"#.utf8), forKey: StoredFeedBlockedKeywords.key)
        let list = StoredFeedBlockedKeywords(storage: storage)
        XCTAssertEqual(list.active(now: t0), [FeedLocalKeyword(keyword: "a", expiresAt: 4_102_444_800_000), FeedLocalKeyword(keyword: "b", expiresAt: nil)])
    }

    func testMatchingIsCaseInsensitiveOnTitleAndTextOnly() {
        let words = [FeedLocalKeyword(keyword: "Spoiler", expiresAt: nil)]
        XCTAssertTrue(FeedCard(id: "1", kind: "post", title: "no SPOILERS here", text: nil).matchesAny(words))
        XCTAssertTrue(FeedCard(id: "2", kind: "post", title: nil, text: "a spoiler!").matchesAny(words))
        var summaryOnly = FeedCard(id: "3", kind: "post")
        summaryOnly.summary = "spoiler"
        XCTAssertFalse(summaryOnly.matchesAny(words), "摘要不算（和 Android 一样只看标题和正文）")
        XCTAssertFalse(FeedCard(id: "4", kind: "post", text: "clean").matchesAny(words))
        XCTAssertFalse(FeedCard(id: "5", kind: "post", text: "spoiler").matchesAny([]))
    }
}

// MARK: - wire

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

final class TellomiFeedSettingsApiTests: XCTestCase {
    private func api(_ transport: ScriptedTransport) -> FeedAPI {
        FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
    }

    private func body(_ request: URLRequest) -> String {
        String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    }

    func testKeywordCallsHitTheRightRoutesAndZeroDaysIsSent() async throws {
        let transport = ScriptedTransport()
        let api = api(transport)
        try await api.putKeyword("剧透", days: 0)
        try await api.putKeyword("ads", days: 30)
        try await api.deleteKeyword("a/b c")
        transport.reply(200, #"{"keywords":[{"keyword":"x","expires_at":"2026-11-01T00:00:00Z"},{"keyword":"y"}]}"#)
        let keywords = try await api.keywords()
        XCTAssertEqual(keywords, [FeedServerKeyword(keyword: "x", expiresAt: "2026-11-01T00:00:00Z"), FeedServerKeyword(keyword: "y")])

        let r = transport.requests
        XCTAssertEqual(r.map { $0.httpMethod }, ["PUT", "PUT", "DELETE", "GET"])
        XCTAssertEqual(r.map { $0.url?.path }, ["/v1/feed/me/keywords", "/v1/feed/me/keywords", "/v1/feed/me/keywords/a%2Fb c", "/v1/feed/me/keywords"].map { $0.removingPercentEncoding ?? $0 })
        XCTAssertEqual(r[2].url?.absoluteString, "https://feed.example.test/v1/feed/me/keywords/a%2Fb%20c", "词里的 / 和空格各段单独转义")
        XCTAssertEqual(body(r[0]), #"{"days":0,"keyword":"剧透"}"#)
        XCTAssertEqual(body(r[1]), #"{"days":30,"keyword":"ads"}"#)
    }

    func testPreferencesUpdateSendsOnlyWhatChangedButPauseZero() async throws {
        let transport = ScriptedTransport()
        let api = api(transport)
        transport.reply(200, #"{"personalized":false,"style":"explore","sensitive":"reduce","categories":{"sports":"reduce"},"paused_until":"2026-11-15T00:00:00Z"}"#)
        for _ in 0..<3 { transport.reply(200, "{}") }
        let saved = try await api.putPreferences(FeedPreferencesUpdate(personalized: false))
        _ = try await api.putPreferences(FeedPreferencesUpdate(pauseDays: 0))
        _ = try await api.putPreferences(FeedPreferencesUpdate(categories: [:]))
        _ = try await api.putPreferences(FeedPreferencesUpdate(style: "keep", sensitive: "standard", pauseDays: 30))
        XCTAssertEqual(saved.pausedUntil, "2026-11-15T00:00:00Z")
        XCTAssertEqual(saved.categories, ["sports": "reduce"])
        XCTAssertEqual(saved.recentTopics, [])
        let bodies = transport.requests.map { body($0) }
        XCTAssertEqual(bodies[0], #"{"personalized":false}"#)
        XCTAssertEqual(bodies[1], #"{"pause_days":0}"#)
        XCTAssertEqual(bodies[2], #"{"categories":{}}"#, "清空整张表也要发")
        XCTAssertEqual(bodies[3], #"{"pause_days":30,"sensitive":"standard","style":"keep"}"#)
    }

    func testDefaultsWhenFieldsAreMissing() async throws {
        let transport = ScriptedTransport()
        let api = api(transport)
        transport.reply(200, "{}")
        let p = try await api.preferences()
        XCTAssertEqual(p, FeedPreferences())
        XCTAssertTrue(p.personalized)
        XCTAssertEqual(p.style, "keep")
        XCTAssertEqual(p.sensitive, "standard")
        transport.reply(200, #"{"recent_topics":[{"key":"tech","share":0.4},{"key":"food"}]}"#)
        let q = try await api.preferences()
        XCTAssertEqual(q.recentTopics, [FeedRecentTopic(key: "tech", share: 0.4), FeedRecentTopic(key: "food", share: 0)])
        transport.reply(200, "{}")
        let empty = try await api.interests()
        XCTAssertTrue(empty.isEmpty)
        transport.reply(200, "{}")
        let n = try await api.notificationSettings()
        XCTAssertEqual(n, FeedNotificationSettings())
    }

    func testInterestsAndNotificationSettingsRoutes() async throws {
        let transport = ScriptedTransport()
        let api = api(transport)
        transport.reply(200, #"{"topics":[{"key":"tech","score":1.0}],"authors":[{"key":"p1","label":"Ann","score":0.5}],"sources":[]}"#)
        let interests = try await api.interests()
        XCTAssertEqual(interests.topics, [FeedInterest(key: "tech", label: nil, score: 1)])
        XCTAssertEqual(interests.authors, [FeedInterest(key: "p1", label: "Ann", score: 0.5)])
        try await api.deleteInterest(dimension: "author", key: "p/1")
        try await api.resetInterests()
        transport.reply(200, #"{"from_whom":"friends","likes":false,"comments":true,"follows":true}"#)
        let saved = try await api.putNotificationSettings(FeedNotificationSettings(fromWhom: "friends", likes: false, comments: true, follows: true))
        XCTAssertEqual(saved.fromWhom, "friends")
        XCTAssertFalse(saved.likes)

        let r = transport.requests
        XCTAssertEqual(r.map { $0.httpMethod }, ["GET", "DELETE", "POST", "PUT"])
        XCTAssertEqual(r[1].url?.absoluteString, "https://feed.example.test/v1/feed/me/interests/author/p%2F1")
        XCTAssertEqual(r[2].url?.path, "/v1/feed/me/interests/reset")
        XCTAssertEqual(r[3].url?.path, "/v1/feed/me/notification-settings")
        XCTAssertEqual(body(r[3]), #"{"comments":true,"follows":true,"from_whom":"friends","likes":false}"#, "四个字段都发")
    }

    func testInterestsWithoutDropsOnlyThatKeyInThatDimension() {
        let i = FeedInterests(topics: [FeedInterest(key: "a"), FeedInterest(key: "b")], authors: [FeedInterest(key: "a")], sources: [])
        XCTAssertEqual(i.without(dimension: "topic", key: "a").topics.map(\.key), ["b"])
        XCTAssertEqual(i.without(dimension: "topic", key: "a").authors.map(\.key), ["a"])
        XCTAssertEqual(i.without(dimension: "nope", key: "a"), i)
    }
}

// MARK: - store

private struct Boom: Error {}

private final class SettingsSource: FeedSource {
    private let lock = NSLock()
    private var _calls = [String]()
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    private func log(_ s: String) { lock.lock(); _calls.append(s); lock.unlock() }

    var region: String? = "cn"
    var toggleVisible = true
    var preferencesValue = FeedPreferences()
    var interestsValue = FeedInterests(topics: [FeedInterest(key: "tech", score: 1), FeedInterest(key: "food", score: 0.4)], authors: [FeedInterest(key: "p1", label: "Ann", score: 0.2)])
    var interestsAfterReset = FeedInterests()
    var serverKeywords = [FeedServerKeyword]()
    var keywordsFail = false
    var failAll = false
    var putKeywordError: Error?
    var saveError: Error?
    var savedUpdates = [FeedPreferencesUpdate]()
    var resetDone = false
    var pages = [FeedTab: FeedTimelinePage]()

    func config() async throws -> FeedConfig {
        var c = FeedConfig()
        c.region = region
        c.personalizationToggleVisible = toggleVisible
        return c
    }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { pages[tab] ?? FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func preferences() async throws -> FeedPreferences {
        if failAll { throw Boom() }
        var p = preferencesValue
        p.recentTopics = [FeedRecentTopic(key: "tech", share: 0.5)]
        return p
    }
    func savePreferences(_ update: FeedPreferencesUpdate) async throws -> FeedPreferences {
        log("save")
        lock.locked { savedUpdates.append(update) }
        if let saveError { throw saveError }
        var p = preferencesValue   // 服务端回整份，不含 recent_topics
        if let v = update.personalized { p.personalized = v }
        if let v = update.style { p.style = v }
        if let v = update.sensitive { p.sensitive = v }
        if let v = update.categories { p.categories = v }
        if let v = update.pauseDays { p.pausedUntil = v == 0 ? nil : "2026-11-15T00:00:00Z" }
        return p
    }
    func interests() async throws -> FeedInterests { resetDone ? interestsAfterReset : interestsValue }
    func deleteInterest(dimension: String, key: String) async throws {
        log("deleteInterest \(dimension)/\(key)")
        if failAll { throw Boom() }
    }
    func resetInterests() async throws {
        log("reset")
        if failAll { throw Boom() }
        resetDone = true
    }
    func keywords() async throws -> [FeedServerKeyword] {
        if keywordsFail { throw Boom() }
        return serverKeywords
    }
    func putKeyword(_ keyword: String, days: Int) async throws {
        log("put \(keyword) \(days)")
        if let putKeywordError { throw putKeywordError }
    }
    func deleteKeyword(_ keyword: String) async throws {
        log("delete \(keyword)")
        if failAll { throw Boom() }
    }
}

@MainActor
final class TellomiFeedRecommendationSettingsTests: XCTestCase {
    private var clock = t0

    private func make(_ source: SettingsSource, local: InMemoryFeedBlockedKeywords = InMemoryFeedBlockedKeywords()) -> FeedRecommendationSettingsStore {
        FeedRecommendationSettingsStore(source: source, blockedKeywords: local, now: { [unowned self] in self.clock })
    }

    private func loaded(_ source: SettingsSource, local: InMemoryFeedBlockedKeywords = InMemoryFeedBlockedKeywords()) async -> FeedRecommendationSettingsStore {
        let store = make(source, local: local)
        store.load()
        await store.waitForTasks()
        return store
    }

    func testLoadMergesLocalAndServerKeywordsAndDropsExpired() async {
        let local = InMemoryFeedBlockedKeywords()
        local.add(keyword: "blocked", expiresAt: nil)
        let source = SettingsSource()
        source.serverKeywords = [
            FeedServerKeyword(keyword: "soft", expiresAt: "2026-12-01T00:00:00Z"),
            FeedServerKeyword(keyword: "stale", expiresAt: "2026-01-01T00:00:00Z"),
            FeedServerKeyword(keyword: "forever"),
        ]
        let store = await loaded(source, local: local)
        XCTAssertFalse(store.state.loading)
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["blocked", "soft", "forever"], "本机的在前；过期的不显示")
        XCTAssertEqual(store.state.keywords.map(\.mode), [.block, .downrank, .downrank])
        XCTAssertEqual(store.state.region, "cn")
        XCTAssertTrue(store.state.personalizationToggleVisible)
        XCTAssertEqual(store.state.preferences?.recentTopics.count, 1)
        XCTAssertEqual(store.state.interests?.topics.count, 2)
    }

    func testKeywordsFailingDoesNotBlockThePage() async {
        let local = InMemoryFeedBlockedKeywords()
        local.add(keyword: "blocked", expiresAt: nil)
        let source = SettingsSource()
        source.keywordsFail = true
        let store = await loaded(source, local: local)
        XCTAssertFalse(store.state.loadFailed)
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["blocked"])
        XCTAssertNotNil(store.state.preferences)

        let broken = SettingsSource()
        broken.failAll = true
        let second = await loaded(broken)
        XCTAssertTrue(second.state.loadFailed)
        XCTAssertFalse(second.state.loading)
    }

    func testTogglesAreOptimisticKeepRecentTopicsAndRollBackOnFailure() async {
        let source = SettingsSource()
        let store = await loaded(source)
        store.setPersonalized(false)
        XCTAssertEqual(store.state.preferences?.personalized, false, "先改界面")
        await store.waitForTasks()
        XCTAssertEqual(store.state.preferences?.personalized, false)
        XCTAssertEqual(store.state.preferences?.recentTopics.map(\.key), ["tech"], "PUT 回的没有 recent_topics，留着原来的")
        XCTAssertEqual(source.savedUpdates, [FeedPreferencesUpdate(personalized: false)])

        store.setPersonalized(false)   // 没变化：不发
        await store.waitForTasks()
        XCTAssertEqual(source.savedUpdates.count, 1)

        source.saveError = Boom()
        store.setStyle("explore")
        XCTAssertEqual(store.state.preferences?.style, "explore")
        await store.waitForTasks()
        XCTAssertEqual(store.state.preferences?.style, "keep", "存不上改回去")
        XCTAssertEqual(store.state.notice, .failed)
        store.onNoticeShown()
        XCTAssertNil(store.state.notice)

        store.setStyle("bogus")
        await store.waitForTasks()
        XCTAssertEqual(source.savedUpdates.count, 2, "不认识的值不发")
    }

    func testSensitiveMoreOnlyOutsideMainlandAndUnknownRegionCountsAsMainland() async {
        let source = SettingsSource()
        let store = await loaded(source)
        XCTAssertEqual(store.state.sensitiveChoices, ["reduce", "standard"])
        store.setSensitive("more")
        await store.waitForTasks()
        XCTAssertEqual(source.savedUpdates, [], "大陆不发 more")

        let overseas = SettingsSource()
        overseas.region = "us"
        let second = await loaded(overseas)
        XCTAssertEqual(second.state.sensitiveChoices, ["reduce", "standard", "more"])
        second.setSensitive("more")
        await second.waitForTasks()
        XCTAssertEqual(second.state.preferences?.sensitive, "more")

        let unknown = SettingsSource()
        unknown.region = nil
        let third = await loaded(unknown)
        XCTAssertEqual(third.state.sensitiveChoices, ["reduce", "standard"])
    }

    func testCategoriesSendTheWholeTableAndDefaultRemovesTheSlug() async {
        let source = SettingsSource()
        source.preferencesValue.categories = ["sports": "reduce"]
        let store = await loaded(source)
        store.setCategory(slug: "music", value: "increase")
        await store.waitForTasks()
        XCTAssertEqual(source.savedUpdates.last?.categories, ["sports": "reduce", "music": "increase"])
        store.setCategory(slug: "sports", value: "default")
        await store.waitForTasks()
        XCTAssertEqual(source.savedUpdates.last?.categories, ["music": "increase"])
        store.setCategory(slug: "x", value: "nonsense")
        await store.waitForTasks()
        XCTAssertEqual(source.savedUpdates.count, 2)
    }

    func testPauseWaitsForTheServerAndResumeClearsAtOnce() async {
        let source = SettingsSource()
        let store = await loaded(source)
        store.pause()
        XCTAssertNil(store.state.preferences?.pausedUntil, "暂停等服务端回来再改")
        await store.waitForTasks()
        XCTAssertEqual(store.state.preferences?.pausedUntil, "2026-11-15T00:00:00Z")
        XCTAssertEqual(source.savedUpdates.last, FeedPreferencesUpdate(pauseDays: 30))
        store.resume()
        XCTAssertNil(store.state.preferences?.pausedUntil)
        await store.waitForTasks()
        XCTAssertEqual(source.savedUpdates.last, FeedPreferencesUpdate(pauseDays: 0))

        source.saveError = Boom()
        store.pause()
        await store.waitForTasks()
        XCTAssertNil(store.state.preferences?.pausedUntil, "暂停失败：没改界面")
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testDeleteInterestRollsBackAndResetReloads() async {
        let source = SettingsSource()
        let store = await loaded(source)
        store.deleteInterest(dimension: "topic", interest: FeedInterest(key: "tech"))
        XCTAssertEqual(store.state.interests?.topics.map(\.key), ["food"])
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["deleteInterest topic/tech"])

        store.reset()
        XCTAssertTrue(store.state.resetting)
        store.reset()   // 在途时不重复
        await store.waitForTasks()
        XCTAssertEqual(source.calls.filter { $0 == "reset" }.count, 1)
        XCTAssertFalse(store.state.resetting)
        XCTAssertEqual(store.state.interests, FeedInterests())
        XCTAssertEqual(store.state.notice, .reset)

        let failing = SettingsSource()
        let second = await loaded(failing)
        failing.failAll = true
        second.deleteInterest(dimension: "author", interest: FeedInterest(key: "p1"))
        await second.waitForTasks()
        XCTAssertEqual(second.state.interests?.authors.map(\.key), ["p1"])
        XCTAssertEqual(second.state.notice, .failed)
        second.onNoticeShown()
        second.reset()
        await second.waitForTasks()
        XCTAssertFalse(second.state.resetting)
        XCTAssertEqual(second.state.notice, .failed)
    }

    func testAddKeywordValidatesByCodePointsAndAllowedDays() async {
        let source = SettingsSource()
        let store = await loaded(source)
        for (word, days) in [("   ", 0), (String(repeating: "a", count: 21), 0), ("ok", 5)] {
            store.addKeyword(word, mode: .block, days: days)
            XCTAssertEqual(store.state.notice, .invalidKeyword, "\(word.count) \(days)")
            store.onNoticeShown()
        }
        store.addKeyword(String(repeating: "字", count: 20), mode: .block, days: 0)
        XCTAssertNil(store.state.notice)
        XCTAssertEqual(store.state.keywords.count, 1)
        // 20 个 emoji 是 20 个码点（有的 emoji 是多个码点，所以按码点和 Android 一致，而不是按 Character）
        store.addKeyword(String(repeating: "😀", count: 21), mode: .block, days: 0)
        XCTAssertEqual(store.state.notice, .invalidKeyword)
    }

    func testBlockKeywordStaysOnThePhoneAndDownrankGoesToTheServer() async {
        let local = InMemoryFeedBlockedKeywords()
        let source = SettingsSource()
        let store = await loaded(source, local: local)
        store.addKeyword("hide", mode: .block, days: 7)
        store.addKeyword("less", mode: .downrank, days: 30)
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["put less 30"], "完全屏蔽的词不发服务器")
        XCTAssertEqual(local.active(now: t0).map(\.keyword), ["hide"])
        XCTAssertEqual(local.active(now: t0)[0].expiresAt, InMemoryFeedBlockedKeywords.millis(t0) + 7 * 86_400_000)
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["hide", "less"])
        XCTAssertEqual(store.state.keywords[1].expiresAt, InMemoryFeedBlockedKeywords.millis(t0) + 30 * 86_400_000)

        store.addKeyword("less", mode: .downrank, days: 0)   // 已有的词改有效期，不重复
        await store.waitForTasks()
        XCTAssertEqual(store.state.keywords.filter { $0.keyword == "less" }.count, 1)
        XCTAssertNil(store.state.keywords.first { $0.keyword == "less" }?.expiresAt)

        store.removeKeyword(FeedKeyword(keyword: "hide", mode: .block, expiresAt: nil))
        store.removeKeyword(store.state.keywords.first { $0.keyword == "less" }!)
        await store.waitForTasks()
        XCTAssertEqual(source.calls.last, "delete less")
        XCTAssertEqual(local.active(now: t0), [])
        XCTAssertEqual(store.state.keywords, [])
    }

    func testDownrankErrorsAreToldApartAndTheCapIs100() async {
        let source = SettingsSource()
        source.serverKeywords = (0..<100).map { FeedServerKeyword(keyword: "w\($0)") }
        let store = await loaded(source)
        store.addKeyword("one-more", mode: .downrank, days: 0)
        XCTAssertEqual(store.state.notice, .tooManyKeywords, "满 100 个本地就拦")
        XCTAssertEqual(source.calls, [])
        store.onNoticeShown()
        store.addKeyword("w5", mode: .downrank, days: 7)   // 已有的可以改有效期
        await store.waitForTasks()
        XCTAssertEqual(source.calls, ["put w5 7"])
        XCTAssertNil(store.state.notice)

        for (code, notice) in [("too_many_keywords", FeedRecommendationSettingsState.Notice.tooManyKeywords), ("invalid_keyword", .invalidKeyword), ("whatever", .failed)] {
            let s = SettingsSource()
            s.putKeywordError = FeedAPIError(status: 409, code: code, retryAfterSeconds: nil)
            let st = await loaded(s)
            st.addKeyword("kw", mode: .downrank, days: 0)
            await st.waitForTasks()
            XCTAssertEqual(st.state.notice, notice, code)
            XCTAssertEqual(st.state.keywords, [])
        }
    }

    func testRemovingADownrankKeywordRollsBackOnFailure() async {
        let source = SettingsSource()
        source.serverKeywords = [FeedServerKeyword(keyword: "less")]
        let store = await loaded(source)
        source.failAll = true
        store.removeKeyword(store.state.keywords[0])
        XCTAssertEqual(store.state.keywords, [])
        await store.waitForTasks()
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["less"])
        XCTAssertEqual(store.state.notice, .failed)
    }
}

@MainActor
final class TellomiFeedKeywordFilterTests: XCTestCase {
    private func card(_ id: String, _ text: String) -> FeedCard {
        FeedCard(id: id, kind: FeedCard.kindPost, author: FeedAuthor(profileId: "p-\(id)", displayName: "作者"), text: text)
    }

    func testBlockedWordsAreFilteredFromBothTabsEachPageAndFreshEdits() async {
        let source = SettingsSource()
        source.pages[.following] = FeedTimelinePage(cards: [card("a", "hello"), card("b", "a Spoiler inside")], nextCursor: nil)
        source.pages[.recommend] = FeedTimelinePage(cards: [card("c", "SPOILER"), card("d", "fine")], nextCursor: nil)
        let list = InMemoryFeedBlockedKeywords()
        list.add(keyword: "spoiler", expiresAt: nil)
        let store = FeedStore(source: source, blockedKeywords: list)

        store.onTabShown(.following)
        await store.waitForLoad(.following)
        store.onTabShown(.recommend)
        await store.waitForLoad(.recommend)
        XCTAssertEqual(store.tab(.following).cards.map(\.id), ["a"])
        XCTAssertEqual(store.tab(.recommend).cards.map(\.id), ["d"])

        // 设置页刚删掉词，下一次刷新就放行
        list.remove(keyword: "spoiler")
        store.refresh(.following)
        await store.waitForLoad(.following)
        XCTAssertEqual(store.tab(.following).cards.map(\.id), ["a", "b"])
    }

    func testNoListMeansNoFiltering() async {
        let source = SettingsSource()
        source.pages[.following] = FeedTimelinePage(cards: [card("a", "spoiler")], nextCursor: nil)
        let store = FeedStore(source: source)
        store.onTabShown(.following)
        await store.waitForLoad(.following)
        XCTAssertEqual(store.tab(.following).cards.map(\.id), ["a"])
    }

    func testExpiredWordsDoNotFilterUsingTheStoreClock() async {
        let source = SettingsSource()
        source.pages[.following] = FeedTimelinePage(cards: [card("a", "spoiler")], nextCursor: nil)
        let list = InMemoryFeedBlockedKeywords()
        list.add(keyword: "spoiler", expiresAt: t0.addingTimeInterval(100))
        let early = FeedStore(source: source, blockedKeywords: list, now: { t0 })
        early.onTabShown(.following)
        await early.waitForLoad(.following)
        XCTAssertEqual(early.tab(.following).cards, [])

        let late = FeedStore(source: source, blockedKeywords: list, now: { t0.addingTimeInterval(100) })
        late.onTabShown(.following)
        await late.waitForLoad(.following)
        XCTAssertEqual(late.tab(.following).cards.map(\.id), ["a"])
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
