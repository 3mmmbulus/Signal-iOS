//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 「动态设置」页的逻辑层（第五轮）：展示逻辑（`FeedSettingsPresentation`）、store 的失败分类 / 保存顺序 / 回滚只回这一个 / 重置之后读不到、
/// 样例源的引擎规则。界面（UIKit）不在这里测；store 原有的行为在 `TellomiFeedSettingsTests.swift`。

private struct SBoom: Error {}

private actor SGate {
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

private final class SSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = [String]()
    var calls: [String] { lock.withLock { _calls } }
    func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
    private func log(_ call: String) { lock.withLock { _calls.append(call) } }

    var preferencesValue = FeedPreferences()
    var interestsValue = FeedInterests(topics: [FeedInterest(key: "tech"), FeedInterest(key: "food"), FeedInterest(key: "travel")], authors: [FeedInterest(key: "n:1", label: "Ann")])
    var serverKeywords = [FeedServerKeyword(keyword: "a"), FeedServerKeyword(keyword: "b"), FeedServerKeyword(keyword: "c")]
    var loadError: Error?
    var interestsErrorAfterReset: Error?
    var saveError: Error?
    var resetError: Error?
    var deleteInterestErrors = [String: Error]()
    var deleteKeywordErrors = [String: Error]()
    var putKeywordError: Error?
    private var resetDone = false
    private var gates = [String: SGate]()
    func hold(_ key: String, _ gate: SGate) { lock.withLock { gates[key] = gate } }
    private func gate(_ key: String) -> SGate? { lock.withLock { gates[key] } }

    func config() async throws -> FeedConfig {
        log("config")
        if let gate = gate("config") { await gate.wait() }
        if let loadError { throw loadError }
        var c = FeedConfig()
        c.region = "us"
        c.personalizationToggleVisible = true
        return c
    }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage(cards: []) }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw SBoom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func preferences() async throws -> FeedPreferences { preferencesValue }
    func savePreferences(_ update: FeedPreferencesUpdate) async throws -> FeedPreferences {
        let name = update.personalized.map { "personalized \($0)" } ?? update.style.map { "style \($0)" } ?? update.sensitive.map { "sensitive \($0)" } ?? "other"
        log("save \(name)")
        if let gate = gate("save \(name)") { await gate.wait() }
        if let saveError { throw saveError }
        var p = lock.withLock { preferencesValue }
        if let v = update.personalized { p.personalized = v }
        if let v = update.style { p.style = v }
        if let v = update.sensitive { p.sensitive = v }
        if let v = update.categories { p.categories = v }
        lock.withLock { preferencesValue = p }
        return p
    }
    func interests() async throws -> FeedInterests {
        log("interests")
        if lock.withLock({ resetDone }), let interestsErrorAfterReset { throw interestsErrorAfterReset }
        return lock.withLock { resetDone } ? FeedInterests() : interestsValue
    }
    func deleteInterest(dimension: String, key: String) async throws {
        log("deleteInterest \(dimension)/\(key)")
        if let gate = gate("deleteInterest \(key)") { await gate.wait() }
        if let error = deleteInterestErrors[key] { throw error }
    }
    func resetInterests() async throws {
        log("reset")
        if let resetError { throw resetError }
        lock.withLock { resetDone = true }
    }
    func keywords() async throws -> [FeedServerKeyword] { serverKeywords }
    func putKeyword(_ keyword: String, days: Int) async throws {
        log("put \(keyword) \(days)")
        if let putKeywordError { throw putKeywordError }
    }
    func deleteKeyword(_ keyword: String) async throws {
        log("delete \(keyword)")
        if let gate = gate("delete \(keyword)") { await gate.wait() }
        if let error = deleteKeywordErrors[keyword] { throw error }
    }
}

private let t0 = FeedDates.parse("2026-10-18T12:00:00Z")!

private func throttled(_ seconds: Int? = 20) -> FeedAPIError { FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds) }
private let hidden = FeedAPIError(status: 404, code: "feed_hidden")

private func waitForArrival(_ gate: SGate) async {
    for _ in 0..<300 where await gate.arrivals == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
}

private func millis(_ date: Date) -> Int64 { InMemoryFeedBlockedKeywords.millis(date) }

// MARK: - 展示逻辑

final class TellomiFeedSettingsPresentationTests: XCTestCase {
    private typealias P = FeedSettingsPresentation

    func testTheTopicTableIsTheEnginesThirtySixCategoriesInTheirOrder() {
        let engine = "ai tech dev games anime film music books photo design food baking explore travel camping fitness running ballsports fashion beauty portrait pets home parenting work frugal cars science health mood funny diy plants city campus news".split(separator: " ").map(String.init)
        XCTAssertEqual(FeedTopicSlug.allCases.map(\.rawValue), engine)
        XCTAssertEqual(FeedTopicSlug.allCases.count, 36)
        XCTAssertEqual(FeedSettingsLabel.fromSlug("baking"), .topic(.baking))
        XCTAssertEqual(FeedSettingsLabel.fromSlug("new-topic"), .text("#new-topic"), "不认识的显示成 #slug")
        XCTAssertEqual(FeedSettingsLabel.fromSlug("AI"), .text("#AI"), "slug 区分大小写，和引擎一样")
    }

    func testPhaseNeedsBothPreferencesAndInterestsAndKeywordsDoNotMatter() {
        var state = FeedRecommendationSettingsState()
        XCTAssertEqual(P.phase(state), .loading)
        state.loading = true
        XCTAssertEqual(P.phase(state), .loading)
        state.preferences = FeedPreferences()
        XCTAssertEqual(P.phase(state), .loading, "兴趣标签还没到")
        state.interests = FeedInterests()
        XCTAssertEqual(P.phase(state), .content)
        state.keywords = []
        XCTAssertEqual(P.phase(state), .content)

        var failed = FeedRecommendationSettingsState()
        failed.loadFailed = true
        XCTAssertEqual(P.phase(failed), .failed(retryAfterSeconds: nil))
        failed.retryAfterSeconds = 12
        XCTAssertEqual(P.phase(failed), .failed(retryAfterSeconds: 12))
        failed.preferences = FeedPreferences()
        failed.interests = FeedInterests()
        XCTAssertEqual(P.phase(failed), .content, "已经有内容就不再是整页失败")
    }

    func testPersonalizationRowIsAToggleOnlyWhenTheEngineScoresByInterest() {
        var state = FeedRecommendationSettingsState()
        XCTAssertNil(P.personalization(state), "还没读到")
        var preferences = FeedPreferences()
        preferences.personalized = false
        state.preferences = preferences
        XCTAssertEqual(P.personalization(state), .editorialNote)
        state.personalizationToggleVisible = true
        XCTAssertEqual(P.personalization(state), .toggle(on: false))
        state.preferences?.personalized = true
        XCTAssertEqual(P.personalization(state), .toggle(on: true))
    }

    func testRecentTopicsAreClampedAndRoundedAndKeepTheEnginesOrder() {
        var preferences = FeedPreferences()
        preferences.recentTopics = [
            FeedRecentTopic(key: "tech", share: 0.4),
            FeedRecentTopic(key: "food", share: 0.126),
            FeedRecentTopic(key: "mystery", share: 1.3),
            FeedRecentTopic(key: "film", share: -0.2),
            FeedRecentTopic(key: "music", share: .nan),
        ]
        let rows = P.recentTopics(preferences)
        XCTAssertEqual(rows.map(\.label), [.topic(.tech), .topic(.food), .text("#mystery"), .topic(.film), .topic(.music)])
        XCTAssertEqual(rows.map(\.percent), [40, 13, 100, 0, 0])
        XCTAssertEqual(rows.map(\.share), [0.4, 0.126, 1, 0, 0])
        XCTAssertEqual(P.recentTopics(FeedPreferences()), [])
    }

    func testInterestSectionsSkipEmptyGroupsAndNameThemTheRightWay() {
        let interests = FeedInterests(
            topics: [FeedInterest(key: "tech", score: 1), FeedInterest(key: "zzz", score: 0.1)],
            authors: [FeedInterest(key: "n:1", label: "Ann"), FeedInterest(key: "x:9", label: "  "), FeedInterest(key: "x:8")],
            sources: []
        )
        let sections = P.interestSections(interests)
        XCTAssertEqual(sections.map(\.kind), [.topics, .authors])
        XCTAssertEqual(sections.map(\.dimension), ["topic", "author"])
        XCTAssertEqual(sections[0].rows.map(\.label), [.topic(.tech), .text("#zzz")])
        XCTAssertEqual(sections[1].rows.map(\.label), [.text("Ann"), .text("x:9"), .text("x:8")], "没有名字（空白 / 没给）的显示 key")
        XCTAssertEqual(sections[1].rows.map(\.dimension), ["author", "author", "author"])
        XCTAssertEqual(sections[0].rows[0].interest, FeedInterest(key: "tech", score: 1))
        XCTAssertEqual(P.interestSections(FeedInterests()), [], "全空时界面说「还没有兴趣标签」")

        let onlySources = P.interestSections(FeedInterests(sources: [FeedInterest(key: "s1", label: "Daily")]))
        XCTAssertEqual(onlySources.map(\.kind), [.sources])
        XCTAssertEqual(onlySources[0].rows.map(\.label), [.text("Daily")])
        XCTAssertEqual(onlySources[0].dimension, FeedInterests.dimSource)
    }

    func testCategoryRowsListAllThirtySixAndUnknownValuesCountAsDefault() {
        var preferences = FeedPreferences()
        preferences.categories = ["baking": "reduce", "travel": "increase", "food": "default", "news": "weird", "not-a-slug": "reduce"]
        let rows = P.categoryRows(preferences)
        XCTAssertEqual(rows.count, 36)
        XCTAssertEqual(rows.map(\.slug), FeedTopicSlug.allCases)
        XCTAssertEqual(rows.first { $0.slug == .baking }?.choice, .reduce)
        XCTAssertEqual(rows.first { $0.slug == .travel }?.choice, .increase)
        XCTAssertEqual(rows.first { $0.slug == .food }?.choice, .default)
        XCTAssertEqual(rows.first { $0.slug == .news }?.choice, .default, "不认得的值当默认")
        XCTAssertEqual(rows.first { $0.slug == .ai }?.choice, .default)
        // 调整过 = 减少 / 增加的（不认得的 slug 也算：服务端确实存了）；default 和不认得的值不算
        XCTAssertEqual(P.adjustedCategoryCount(preferences), 3)
        XCTAssertEqual(P.adjustedCategoryCount(FeedPreferences()), 0)
    }

    func testCategoryAndSensitiveChoicesRoundTripTheApiValues() {
        for choice in FeedCategoryChoice.allCases { XCTAssertEqual(FeedCategoryChoice(value: choice.apiValue), choice) }
        XCTAssertEqual(FeedCategoryChoice.allCases.map(\.apiValue), FeedPreferences.categoryValues)
        XCTAssertEqual(FeedCategoryChoice(value: nil), .default)
        for value in FeedPreferences.sensitiveValues { XCTAssertEqual(FeedSensitiveChoice(value: value).apiValue, value) }
        XCTAssertEqual(FeedSensitiveChoice(value: "banana"), .standard)
    }

    func testKeywordRowsConvertMillisToDatesAndDropTheExpired() {
        let keywords = [
            FeedKeyword(keyword: "blocked", mode: .block, expiresAt: nil),
            FeedKeyword(keyword: "soon", mode: .downrank, expiresAt: millis(t0.addingTimeInterval(60))),
            FeedKeyword(keyword: "gone", mode: .downrank, expiresAt: millis(t0.addingTimeInterval(-1))),
            FeedKeyword(keyword: "edge", mode: .block, expiresAt: millis(t0)),
        ]
        let rows = P.keywordRows(keywords, now: t0)
        XCTAssertEqual(rows.map(\.keyword), ["blocked", "soon"], "过期的（含正好到点的）不画，顺序不变")
        XCTAssertEqual(rows.map(\.mode), [.block, .downrank])
        XCTAssertNil(rows[0].expiresAt)
        XCTAssertEqual(rows[1].expiresAt, t0.addingTimeInterval(60))
        XCTAssertEqual(rows[1].source, keywords[1], "删除时把原样的词交回 store")
    }

    func testPauseRowIgnoresAPausedUntilThatAlreadyPassed() {
        var preferences = FeedPreferences()
        XCTAssertEqual(P.pause(preferences, now: t0), .notPaused)
        preferences.pausedUntil = FeedDates.format(t0.addingTimeInterval(3600))
        XCTAssertEqual(P.pause(preferences, now: t0), .paused(until: t0.addingTimeInterval(3600)))
        preferences.pausedUntil = FeedDates.format(t0)
        XCTAssertEqual(P.pause(preferences, now: t0), .notPaused, "正好到点就算恢复")
        preferences.pausedUntil = FeedDates.format(t0.addingTimeInterval(-86_400))
        XCTAssertEqual(P.pause(preferences, now: t0), .notPaused)
        preferences.pausedUntil = "not a date"
        XCTAssertEqual(P.pause(preferences, now: t0), .notPaused)
        preferences.pausedUntil = "2026-11-15T00:00:00.500Z"
        XCTAssertEqual(P.pause(preferences, now: t0), .paused(until: FeedDates.parse("2026-11-15T00:00:00.500Z")!), "带小数秒也认")
    }

    func testKeywordFormCountsCodePointsTrimsAndPicksTheMode() {
        var form = FeedKeywordForm()
        XCTAssertFalse(form.valid)
        XCTAssertEqual(form.mode, .downrank)
        XCTAssertEqual(form.days, 0)
        form.text = "   \n "
        XCTAssertFalse(form.valid, "只有空白")
        form.text = "  剧透 "
        XCTAssertTrue(form.valid)
        XCTAssertEqual(form.trimmed, "剧透")
        form.text = String(repeating: "字", count: 20)
        XCTAssertTrue(form.valid)
        form.text = String(repeating: "字", count: 21)
        XCTAssertFalse(form.valid)
        // 一个家庭 emoji 是 1 个 Character、5 个码点（3 个人 + 2 个连接符）：按码点算，5 个 = 25 > 20，4 个 = 20 正好
        form.text = String(repeating: "👨‍👩‍👧", count: 5)
        XCTAssertEqual(form.text.count, 5)
        XCTAssertFalse(form.valid)
        form.text = String(repeating: "👨‍👩‍👧", count: 4)
        XCTAssertEqual(form.text.unicodeScalars.count, 20)
        XCTAssertTrue(form.valid)
        form.block = true
        XCTAssertEqual(form.mode, .block)
        XCTAssertEqual(FeedKeywordForm.dayChoices, [0, 30, 7])
    }

    func testToastsMapTheNoticesAndCarryTheWaitForThrottling() {
        var state = FeedRecommendationSettingsState()
        XCTAssertNil(P.toast(state))
        let table: [(FeedRecommendationSettingsState.Notice, P.Toast)] = [
            (.reset, .reset), (.invalidKeyword, .invalidKeyword), (.tooManyKeywords, .tooManyKeywords), (.failed, .actionFailed),
        ]
        for (notice, toast) in table {
            state.notice = notice
            XCTAssertEqual(P.toast(state), toast)
        }
        state.notice = .throttled
        XCTAssertEqual(P.toast(state), .throttled(retryAfterSeconds: nil))
        state.retryAfterSeconds = 30
        XCTAssertEqual(P.toast(state), .throttled(retryAfterSeconds: 30))
    }
}

// MARK: - store

@MainActor
final class TellomiFeedSettingsStoreSyncTests: XCTestCase {
    private func make(_ source: SSource, local: InMemoryFeedBlockedKeywords = InMemoryFeedBlockedKeywords()) -> FeedRecommendationSettingsStore {
        FeedRecommendationSettingsStore(source: source, blockedKeywords: local, now: { t0 })
    }

    private func loaded(_ source: SSource) async -> FeedRecommendationSettingsStore {
        let store = make(source)
        store.load()
        await store.waitForTasks()
        return store
    }

    // MARK: 读

    func testLoadDoesNotFetchTwiceWhileInFlightOrOnceItHasContent() async {
        let source = SSource()
        let gate = SGate()
        source.hold("config", gate)
        let store = make(source)
        store.load()
        store.load()
        await waitForArrival(gate)
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(source.count("config"), 1)
        store.load()
        await store.waitForTasks()
        XCTAssertEqual(source.count("config"), 1, "已经读到了不再读")
        XCTAssertNotNil(store.state.preferences)
    }

    func testLoadFailureIsClassifiedAndRetryWorksAfterIt() async {
        let source = SSource()
        source.loadError = throttled(17)
        let store = make(source)
        store.load()
        await store.waitForTasks()
        XCTAssertTrue(store.state.loadFailed)
        XCTAssertEqual(store.state.retryAfterSeconds, 17)
        XCTAssertFalse(store.state.loading)
        XCTAssertFalse(store.state.feedHidden)

        source.loadError = nil
        store.load()
        XCTAssertFalse(store.state.loadFailed, "重试一开始就清掉失败")
        XCTAssertNil(store.state.retryAfterSeconds)
        await store.waitForTasks()
        XCTAssertNotNil(store.state.preferences)
        XCTAssertFalse(store.state.loadFailed)
        XCTAssertEqual(source.count("config"), 2)
    }

    func testLoadFeedHiddenClosesThePageInsteadOfSayingFailed() async {
        let source = SSource()
        source.loadError = hidden
        let store = await loaded(source)
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertFalse(store.state.loadFailed)

        let plain = SSource()
        plain.loadError = FeedAPIError(status: 503, code: "unavailable")
        let second = await loaded(plain)
        XCTAssertTrue(second.state.loadFailed)
        XCTAssertNil(second.state.retryAfterSeconds, "不带 Retry-After 的 5xx 是普通失败")
        XCTAssertFalse(second.state.feedHidden)
    }

    // MARK: 存偏好

    func testSavesGoOutOneAfterAnotherInTheOrderTheyWereTapped() async {
        let source = SSource()
        let store = await loaded(source)
        let gate = SGate()
        source.hold("save personalized false", gate)
        store.setPersonalized(false)
        store.setStyle(FeedPreferences.styleExplore)
        await waitForArrival(gate)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("save") }, ["save personalized false"], "第一个还没回来，第二个不发")
        XCTAssertEqual(store.state.preferences?.style, FeedPreferences.styleExplore, "界面上先改过去")
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("save") }, ["save personalized false", "save style explore"])
        XCTAssertEqual(store.state.preferences?.personalized, false)
        XCTAssertEqual(store.state.preferences?.style, FeedPreferences.styleExplore)
        XCTAssertEqual(store.state.preferences?.recentTopics, [], "SSource 的偏好没有 recent_topics，这里只看没被覆盖出别的")
    }

    func testAFailedSaveRollsBackAndSaysThrottledWithTheSecondsOrFailed() async {
        let source = SSource()
        let store = await loaded(source)
        source.saveError = throttled(9)
        store.setPersonalized(false)
        XCTAssertEqual(store.state.preferences?.personalized, false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.preferences?.personalized, true, "存不上改回来")
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 9)
        store.onNoticeShown()
        XCTAssertNil(store.state.notice)
        XCTAssertNil(store.state.retryAfterSeconds, "提示说完就清掉秒数")

        source.saveError = FeedAPIError(status: 400, code: "not_available_in_region")
        store.setStyle(FeedPreferences.styleExplore)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .failed)
        XCTAssertNil(store.state.retryAfterSeconds)
        XCTAssertEqual(store.state.preferences?.style, FeedPreferences.styleKeep)

        source.saveError = hidden
        store.onNoticeShown()
        store.setPersonalized(false)
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertNil(store.state.notice, "收页不弹提示")
    }

    // MARK: 兴趣标签

    func testAFailedInterestDeleteBringsBackOnlyThatTagAtItsOldPlace() async {
        let source = SSource()
        let store = await loaded(source)
        let gate = SGate()
        source.hold("deleteInterest food", gate)
        source.deleteInterestErrors["tech"] = SBoom()
        store.deleteInterest(dimension: "topic", interest: FeedInterest(key: "food"))
        store.deleteInterest(dimension: "topic", interest: FeedInterest(key: "tech"))
        XCTAssertEqual(store.state.interests?.topics.map(\.key), ["travel"])
        await waitForArrival(gate)
        for _ in 0..<300 where store.state.notice == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.state.interests?.topics.map(\.key), ["tech", "travel"], "tech 放回原来的位置；food 还在删，不放回来")
        XCTAssertEqual(store.state.notice, .failed)
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(store.state.interests?.topics.map(\.key), ["tech", "travel"])
        XCTAssertEqual(store.state.interests?.authors.map(\.key), ["n:1"], "别的维度不动")
    }

    func testAnEarlierFailingInterestDeleteDoesNotBringBackALaterOneThatWorked() async {
        let source = SSource()
        let store = await loaded(source)
        let gate = SGate()
        source.hold("deleteInterest food", gate)
        source.deleteInterestErrors["food"] = SBoom()
        store.deleteInterest(dimension: "topic", interest: FeedInterest(key: "food"))
        await waitForArrival(gate)
        store.deleteInterest(dimension: "topic", interest: FeedInterest(key: "tech"))
        await Task.yield()
        XCTAssertEqual(store.state.interests?.topics.map(\.key), ["travel"])
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(store.state.interests?.topics.map(\.key), ["food", "travel"], "food 失败放回；tech 已经删成功，不能被 food 失败时的旧快照带回来")
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testAnEarlierFailingKeywordDeleteDoesNotBringBackALaterOneThatWorked() async {
        let source = SSource()
        let store = await loaded(source)
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["a", "b", "c"])
        let gate = SGate()
        source.hold("delete a", gate)
        source.deleteKeywordErrors["a"] = SBoom()
        store.removeKeyword(FeedKeyword(keyword: "a", mode: .downrank, expiresAt: nil))
        await waitForArrival(gate)
        store.removeKeyword(FeedKeyword(keyword: "b", mode: .downrank, expiresAt: nil))
        await Task.yield()
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["c"])
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["a", "c"], "a 失败放回；b 已经删成功，不能被带回来")
        XCTAssertEqual(store.state.notice, .failed)
    }

    func testInterestDeleteThrottledAndHiddenAreClassified() async {
        let source = SSource()
        source.deleteInterestErrors["tech"] = throttled(5)
        source.deleteInterestErrors["food"] = hidden
        let store = await loaded(source)
        store.deleteInterest(dimension: "topic", interest: FeedInterest(key: "tech"))
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 5)
        XCTAssertEqual(store.state.interests?.topics.map(\.key), ["tech", "food", "travel"])
        store.onNoticeShown()
        store.deleteInterest(dimension: "topic", interest: FeedInterest(key: "food"))
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertNil(store.state.notice)
    }

    func testResetThatWorkedButCannotReloadStillShowsAsReset() async {
        let source = SSource()
        source.interestsErrorAfterReset = SBoom()
        let store = await loaded(source)
        store.reset()
        await store.waitForTasks()
        XCTAssertFalse(store.state.resetting)
        XCTAssertEqual(store.state.interests, FeedInterests(), "重置成功了，读不到就先当全清")
        XCTAssertEqual(store.state.notice, .reset)
    }

    func testResetFailureIsClassified() async {
        let source = SSource()
        source.resetError = throttled(30)
        let store = await loaded(source)
        store.reset()
        await store.waitForTasks()
        XCTAssertFalse(store.state.resetting)
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 30)
        XCTAssertEqual(store.state.interests?.topics.count, 3, "没重置成，标签还在")
        XCTAssertEqual(source.count("interests"), 1, "重置没成功就不重读")
    }

    // MARK: 关键词

    func testAFailedKeywordDeleteBringsBackOnlyThatWord() async {
        let source = SSource()
        let store = await loaded(source)
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["a", "b", "c"])
        let gate = SGate()
        source.hold("delete b", gate)
        source.deleteKeywordErrors["a"] = SBoom()
        store.removeKeyword(FeedKeyword(keyword: "b", mode: .downrank, expiresAt: nil))
        store.removeKeyword(FeedKeyword(keyword: "a", mode: .downrank, expiresAt: nil))
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["c"])
        await waitForArrival(gate)
        for _ in 0..<300 where store.state.notice == nil { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["a", "c"], "a 放回原位，b 还在删")
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["a", "c"])
    }

    func testKeywordWriteErrorsAreToldApart() async {
        let source = SSource()
        let store = await loaded(source)
        let table: [(Error, FeedRecommendationSettingsState.Notice?, Int?)] = [
            (FeedAPIError(status: 409, code: "too_many_keywords"), .tooManyKeywords, nil),
            (FeedAPIError(status: 400, code: "invalid_keyword"), .invalidKeyword, nil),
            (throttled(11), .throttled, 11),
            (FeedAPIError(status: 503, code: "unavailable", retryAfterSeconds: 4), .throttled, 4),
            (FeedAPIError(status: 500, code: "internal"), .failed, nil),
            (hidden, nil, nil),
        ]
        for (error, notice, seconds) in table {
            source.putKeywordError = error
            store.onNoticeShown()
            store.addKeyword("new", mode: .downrank, days: 7)
            await store.waitForTasks()
            XCTAssertEqual(store.state.notice, notice, "\(error)")
            XCTAssertEqual(store.state.retryAfterSeconds, seconds, "\(error)")
        }
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["a", "b", "c"], "加失败的词不进列表")
    }

    func testRemovingADownrankWordThrottledRollsBackWithSeconds() async {
        let source = SSource()
        source.deleteKeywordErrors["a"] = throttled(8)
        let store = await loaded(source)
        store.removeKeyword(FeedKeyword(keyword: "a", mode: .downrank, expiresAt: nil))
        await store.waitForTasks()
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["a", "b", "c"])
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 8)
    }

    func testFeedHiddenCanAlsoComeFromOutsideThePage() async {
        let store = await loaded(SSource())
        XCTAssertFalse(store.state.feedHidden)
        store.onFeedHidden()
        XCTAssertTrue(store.state.feedHidden)
    }
}

// MARK: - 样例源

@MainActor
final class TellomiFeedSettingsSampleSourceTests: XCTestCase {
    private func sample() -> SampleFeedSource { SampleFeedSource(now: { t0 }, commentsLatencyNanos: 0) }

    func testConfigFollowsTheSimulation() async throws {
        let source = sample()
        var config = try await source.config()
        XCTAssertEqual(config.region, "cn")
        XCTAssertFalse(config.personalizationToggleVisible)
        XCTAssertEqual(config.recommendMode, FeedConfig.recommendModeEditorial)
        source.simulation.settingsRegion = "us"
        source.simulation.settingsPersonalizationToggleVisible = true
        config = try await source.config()
        XCTAssertEqual(config.region, "us")
        XCTAssertTrue(config.personalizationToggleVisible)
        XCTAssertEqual(config.recommendMode, FeedConfig.recommendModeScored)
    }

    func testSensitiveMoreIsRefusedInTheMainlandLikeTheEngine() async throws {
        let source = sample()
        do {
            _ = try await source.savePreferences(FeedPreferencesUpdate(sensitive: FeedPreferences.sensitiveMore))
            XCTFail("大陆不能选更多")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 400)
            XCTAssertEqual(error.code, "not_available_in_region")
        }
        let reduced = try await source.savePreferences(FeedPreferencesUpdate(sensitive: FeedPreferences.sensitiveReduce))
        XCTAssertEqual(reduced.sensitive, FeedPreferences.sensitiveReduce)
        source.simulation.settingsRegion = "us"
        let more = try await source.savePreferences(FeedPreferencesUpdate(sensitive: FeedPreferences.sensitiveMore))
        XCTAssertEqual(more.sensitive, FeedPreferences.sensitiveMore)
    }

    func testSavedPreferencesCarryNoRecentTopicsButTheGetDoes() async throws {
        let source = sample()
        let before = try await source.preferences()
        XCTAssertFalse(before.recentTopics.isEmpty)
        let saved = try await source.savePreferences(FeedPreferencesUpdate(personalized: false, categories: ["food": "reduce"]))
        XCTAssertEqual(saved.recentTopics, [], "和真引擎一样，PUT 回的不带 recent_topics")
        XCTAssertFalse(saved.personalized)
        XCTAssertEqual(saved.categories, ["food": "reduce"], "categories 是整张替换")
        let after = try await source.preferences()
        XCTAssertFalse(after.recentTopics.isEmpty)
        XCTAssertEqual(after.categories, ["food": "reduce"])
    }

    func testPauseSetsAThirtyDayDateAndZeroClearsIt() async throws {
        let source = sample()
        let paused = try await source.savePreferences(FeedPreferencesUpdate(pauseDays: 30))
        XCTAssertEqual(paused.pausedUntil.flatMap(FeedDates.parse), t0.addingTimeInterval(30 * 86_400))
        let resumed = try await source.savePreferences(FeedPreferencesUpdate(pauseDays: 0))
        XCTAssertNil(resumed.pausedUntil)
    }

    func testDeletedInterestsStayGoneAndResetClearsTheLearnedOnes() async throws {
        let source = sample()
        let first = try await source.interests()
        XCTAssertTrue(first.topics.contains { $0.key == "tech" })
        XCTAssertFalse(first.authors.isEmpty)
        try await source.deleteInterest(dimension: "topic", key: "tech")
        try await source.deleteInterest(dimension: "author", key: "n:s-1")
        let second = try await source.interests()
        XCTAssertFalse(second.topics.contains { $0.key == "tech" })
        XCTAssertFalse(second.authors.contains { $0.key == "n:s-1" })
        XCTAssertTrue(second.topics.contains { $0.key == "food" })
        try await source.resetInterests()
        let third = try await source.interests()
        XCTAssertTrue(third.isEmpty)
    }

    func testKeywordRulesMatchTheEngine() async throws {
        let source = sample()
        let initial = try await source.keywords()
        XCTAssertEqual(initial.map(\.keyword), ["spoiler", "ads"])
        XCTAssertNil(initial[0].expiresAt)
        XCTAssertNotNil(initial[1].expiresAt)

        try await source.putKeyword("spoiler", days: 7)   // 已有的改有效期，不重复
        var list = try await source.keywords()
        XCTAssertEqual(list.map(\.keyword), ["spoiler", "ads"])
        XCTAssertEqual(list[0].expiresAt.flatMap(FeedDates.parse), t0.addingTimeInterval(7 * 86_400))
        try await source.putKeyword("spoiler", days: 0)
        list = try await source.keywords()
        XCTAssertNil(list[0].expiresAt)

        for (word, days) in [("", 0), ("x", 5), (String(repeating: "a", count: 21), 0)] {
            do {
                try await source.putKeyword(word, days: days)
                XCTFail("\(word) \(days)")
            } catch let error as FeedAPIError {
                XCTAssertEqual(error.code, "invalid_keyword")
                XCTAssertEqual(error.status, 400)
            }
        }
        for i in 0..<98 { try await source.putKeyword("w\(i)", days: 30) }
        list = try await source.keywords()
        XCTAssertEqual(list.count, 100)
        do {
            try await source.putKeyword("one-too-many", days: 0)
            XCTFail("第 101 个")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 409)
            XCTAssertEqual(error.code, "too_many_keywords")
        }
        try await source.putKeyword("w0", days: 7)   // 满了以后改已有的仍然可以
        try await source.deleteKeyword("w0")
        list = try await source.keywords()
        XCTAssertEqual(list.count, 99)
        try await source.deleteKeyword("never-there")   // 引擎对不存在的也回 204
    }

    func testSimulationSwitchesFailLoadWritesKeywordsAndThrottle() async throws {
        let source = sample()
        source.simulation.failsSettingsLoad = true
        do { _ = try await source.preferences(); XCTFail() } catch {}
        do { _ = try await source.interests(); XCTFail() } catch {}
        source.simulation.failsSettingsLoad = false
        source.simulation.failsSettingsKeywordsLoad = true
        _ = try await source.preferences()
        do { _ = try await source.keywords(); XCTFail() } catch {}
        source.simulation.failsSettingsKeywordsLoad = false
        source.simulation.failsSettingsWrites = true
        for write in [
            { _ = try await source.savePreferences(FeedPreferencesUpdate(personalized: false)) },
            { try await source.deleteInterest(dimension: "topic", key: "tech") },
            { try await source.resetInterests() },
            { try await source.putKeyword("x", days: 0) },
            { try await source.deleteKeyword("spoiler") },
        ] as [() async throws -> Void] {
            do { try await write(); XCTFail() } catch {}
        }
        _ = try await source.keywords()   // 读不受 failsSettingsWrites 影响
        source.simulation.failsSettingsWrites = false
        source.simulation.settingsThrottledRetryAfterSeconds = 25
        do {
            _ = try await source.preferences()
            XCTFail()
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 429)
            XCTAssertEqual(error.retryAfterSeconds, 25)
        }
        source.simulation.settingsThrottledRetryAfterSeconds = nil
        source.simulation.feedHidden = true
        do {
            _ = try await source.interests()
            XCTFail()
        } catch let error as FeedAPIError {
            XCTAssertTrue(error.isFeedHidden)
        }
    }

    func testTheStoreWorksEndToEndAgainstTheSampleSource() async {
        let source = sample()
        source.simulation.settingsRegion = "us"
        source.simulation.settingsPersonalizationToggleVisible = true
        let local = InMemoryFeedBlockedKeywords()
        local.add(keyword: "phone-only", expiresAt: nil)
        let store = FeedRecommendationSettingsStore(source: source, blockedKeywords: local, now: { t0 })
        store.load()
        await store.waitForTasks()
        XCTAssertEqual(FeedSettingsPresentation.phase(store.state), .content)
        XCTAssertEqual(FeedSettingsPresentation.personalization(store.state), .toggle(on: true))
        XCTAssertEqual(store.state.sensitiveChoices, FeedPreferences.sensitiveValues, "海外有「更多」")
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["phone-only", "spoiler", "ads"])
        XCTAssertEqual(FeedSettingsPresentation.adjustedCategoryCount(store.state.preferences ?? FeedPreferences()), 2)

        store.setSensitive(FeedPreferences.sensitiveMore)
        store.setCategory(slug: "food", value: FeedPreferences.categoryIncrease)
        store.pause()
        await store.waitForTasks()
        XCTAssertEqual(store.state.preferences?.sensitive, FeedPreferences.sensitiveMore)
        XCTAssertEqual(FeedSettingsPresentation.adjustedCategoryCount(store.state.preferences ?? FeedPreferences()), 3)
        XCTAssertEqual(FeedSettingsPresentation.pause(store.state.preferences ?? FeedPreferences(), now: t0), .paused(until: t0.addingTimeInterval(30 * 86_400)))
        XCTAssertEqual(store.state.preferences?.recentTopics.count, 4, "PUT 回来的没有 recent_topics，store 留着原来的")

        store.addKeyword("剧透", mode: .downrank, days: 30)
        await store.waitForTasks()
        XCTAssertEqual(store.state.keywords.map(\.keyword), ["phone-only", "剧透", "spoiler", "ads"])
        XCTAssertNil(store.state.notice)
    }

    func testTheStoreInTheMainlandNeverAsksForMoreSensitiveContent() async {
        let source = sample()
        let store = FeedRecommendationSettingsStore(source: source, blockedKeywords: InMemoryFeedBlockedKeywords(), now: { t0 })
        store.load()
        await store.waitForTasks()
        XCTAssertFalse(store.state.sensitiveChoices.contains(FeedPreferences.sensitiveMore))
        store.setSensitive(FeedPreferences.sensitiveMore)
        await store.waitForTasks()
        XCTAssertEqual(store.state.preferences?.sensitive, FeedPreferences.sensitiveStandard)
        XCTAssertNil(store.state.notice, "客户端自己就不发，不会换来 400")
    }
}
