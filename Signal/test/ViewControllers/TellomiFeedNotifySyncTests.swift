//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 通知页的逻辑层（第三轮）：未读数放在 `FeedStore` 里（动态页红点和通知页同一份）、点开帖子走 `FeedCardMirror`（屏蔽 / 删除同步、详情页接手借着的卡片）、
/// 错误分类（5xx / Retry-After / `feed_hidden`）、翻页失败和首页失败分开、页面要画什么（`FeedNotificationsPresentation`）、样例数据、设置页的错误分类。界面（UIKit）不在这里测。

private struct NBoom: Error {}

private actor NGate {
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

private final class NClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var date: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

private final class NSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = [String]()
    var calls: [String] { lock.withLock { _calls } }
    func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
    private func log(_ call: String) { lock.withLock { _calls.append(call) } }

    var pages = [String: FeedNotificationsResponse]()
    var listError: Error?
    var listErrorOnlyForBefore = false
    var actionError: Error?
    var cards = [String: FeedCard]()
    var cardError: Error?
    var profiles = [String: FeedProfilePage]()
    var settings = FeedNotificationSettings()
    var settingsLoadError: Error?
    var settingsSaveError: Error?
    private var gates = [String: NGate]()
    func hold(_ key: String, _ gate: NGate) { lock.withLock { gates[key] = gate } }
    private func gate(_ key: String) -> NGate? { lock.withLock { gates[key] } }

    static func key(_ tab: String, _ before: String?) -> String { "\(tab)|\(before ?? "-")" }

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage(cards: []) }
    func setLiked(contentId: String, liked: Bool) async throws { log("like \(contentId) \(liked)") }
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw NBoom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}

    func notifications(tab: String, before: String?) async throws -> FeedNotificationsResponse {
        let key = Self.key(tab, before)
        log("list \(key)")
        if let gate = gate(key) { await gate.wait() }
        if let listError, !listErrorOnlyForBefore || before != nil { throw listError }
        return pages[key] ?? FeedNotificationsResponse()
    }

    func markNotificationsRead(tab: String) async throws {
        log("read \(tab)")
        if let actionError { throw actionError }
    }

    func deleteNotification(id: String) async throws {
        log("delete \(id)")
        if let actionError { throw actionError }
    }

    func muteNotifications(contentId: String, likesOnly: Bool) async throws {
        log("mute \(contentId) \(likesOnly)")
        if let actionError { throw actionError }
    }

    func card(contentId: String) async throws -> FeedCard? {
        log("card \(contentId)")
        if let cardError { throw cardError }
        return cards[contentId]
    }

    func profile(profileId: String) async throws -> FeedProfilePage? {
        log("profile \(profileId)")
        return profiles[profileId]
    }

    func notificationSettings() async throws -> FeedNotificationSettings {
        if let settingsLoadError { throw settingsLoadError }
        return settings
    }

    func saveNotificationSettings(_ settings: FeedNotificationSettings) async throws -> FeedNotificationSettings {
        log("save \(settings.fromWhom)")
        if let settingsSaveError { throw settingsSaveError }
        return settings
    }
}

private let t0 = FeedDates.parse("2026-10-18T12:00:00Z")!
private func iso(_ minutesAgo: Double) -> String { FeedDates.format(t0.addingTimeInterval(-minutesAgo * 60)) }

private func note(_ id: String, _ kind: String = "like", actor: String? = "a1", content: String? = "p1", ago: Double = 5, read: Bool = true, detail: FeedNotificationDetail? = nil) -> FeedNotification {
    FeedNotification(id: id, kind: kind, createdAt: iso(ago), actorId: actor, contentId: content, detail: detail, read: read)
}

private func page(_ items: [FeedNotification], unread: FeedUnreadCounts = FeedUnreadCounts()) -> FeedNotificationsResponse {
    var response = FeedNotificationsResponse()
    response.notifications = items
    response.unread = unread
    return response
}

private func manyNotes(_ count: Int, from start: Int = 0) -> [FeedNotification] {
    (0..<count).map { note("m\(start + $0)", "comment", actor: "a\($0)", content: "p\($0)", ago: Double(start + $0)) }
}

private func postCard(_ id: String, author: String = "p1", likes: Int = 0) -> FeedCard {
    var c = FeedCard(id: id, kind: FeedCard.kindPost, author: FeedAuthor(profileId: author, displayName: author), text: "t \(id)")
    c.stats.likes = likes
    return c
}

private func throttled(_ seconds: Int? = 20) -> FeedAPIError { FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds) }
private let feedHiddenError = FeedAPIError(status: 404, code: "feed_hidden")
private let notFoundError = FeedAPIError(status: 404, code: "not_found")
private let serverError = FeedAPIError(status: 503, code: "unavailable")

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

// MARK: - FeedStore 里的未读数

@MainActor
final class TellomiFeedNotifyUnreadTests: XCTestCase {
    private func make(_ source: NSource, clock: NClock = NClock(t0)) -> FeedStore {
        FeedStore(source: source, now: { clock.date }, jitter: { 0 })
    }

    func testSettingUnreadNotifiesOnlyWhenItChanges() {
        let feed = make(NSource())
        var changes = [FeedChange]()
        let sub = feed.subscribe { changes.append($0) }
        feed.setNotificationUnread(FeedUnreadCounts(interactions: 2))
        feed.setNotificationUnread(FeedUnreadCounts(interactions: 2))
        XCTAssertEqual(changes, [.unread])
        XCTAssertEqual(feed.notificationUnread.interactions, 2)
        feed.setNotificationUnread(FeedUnreadCounts())
        XCTAssertEqual(changes, [.unread, .unread])
        sub.cancel()
    }

    func testRefreshAsksTheInteractionsTabAndTakesTheCounts() async {
        let source = NSource()
        source.pages[NSource.key("interactions", nil)] = page([], unread: FeedUnreadCounts(interactions: 1, follows: 2, system: 3))
        let feed = make(source)
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        XCTAssertEqual(feed.notificationUnread, FeedUnreadCounts(interactions: 1, follows: 2, system: 3))
        XCTAssertEqual(source.calls, ["list interactions|-"])
    }

    func testRefreshIsThrottledToOncePerIntervalAndForceSkipsIt() async {
        let source = NSource()
        let clock = NClock(t0)
        let feed = make(source, clock: clock)
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        clock.advance(FeedStore.unreadRefreshInterval - 1)
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 1, "间隔内不再问")
        feed.refreshNotificationUnread(force: true)
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 2, "force 跳过间隔")
        clock.advance(FeedStore.unreadRefreshInterval)
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 3, "过了间隔又问")
    }

    func testRefreshWhileOneIsInFlightIsIgnored() async {
        let source = NSource()
        let gate = NGate()
        source.hold(NSource.key("interactions", nil), gate)
        let feed = make(source)
        feed.refreshNotificationUnread()
        feed.refreshNotificationUnread(force: true)
        for _ in 0..<100 where await gate.arrivals == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        await gate.open()
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 1)
    }

    func testThrottleWaitsForRetryAfterEvenWithForceThenAsksAgain() async {
        let source = NSource()
        source.listError = throttled(40)
        let clock = NClock(t0)
        let feed = make(source, clock: clock)
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 1)
        source.listError = nil
        source.pages[NSource.key("interactions", nil)] = page([], unread: FeedUnreadCounts(interactions: 5))
        clock.advance(35)
        feed.refreshNotificationUnread(force: true)
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 1, "Retry-After 40 秒没到，force 也不发")
        clock.advance(10)
        feed.refreshNotificationUnread(force: true)
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 2)
        XCTAssertEqual(feed.notificationUnread.interactions, 5)
    }

    func testA503WithRetryAfterBlocksButAPlain503DoesNot() async {
        let source = NSource()
        source.listError = FeedAPIError(status: 503, code: "unavailable", retryAfterSeconds: 30)
        let clock = NClock(t0)
        let feed = make(source, clock: clock)
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        clock.advance(5)
        feed.refreshNotificationUnread(force: true)
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 1, "带 Retry-After 的 503 = 限速")

        let other = NSource()
        other.listError = serverError
        let clock2 = NClock(t0)
        let feed2 = make(other, clock: clock2)
        feed2.refreshNotificationUnread()
        await feed2.waitForNotificationUnread()
        clock2.advance(5)
        feed2.refreshNotificationUnread(force: true)
        await feed2.waitForNotificationUnread()
        XCTAssertEqual(other.count("list"), 2, "不带 Retry-After 的 5xx 不是限速，force 可以再问")
    }

    func testBackoffWithoutRetryAfterGrowsAndASuccessStartsItOver() async {
        let source = NSource()
        source.listError = throttled(nil)
        let clock = NClock(t0)
        let feed = make(source, clock: clock)
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        clock.advance(10)
        feed.refreshNotificationUnread(force: true)
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 1, "第一次退避 15 秒（抖动取 0）")
        clock.advance(6)
        source.listError = nil
        feed.refreshNotificationUnread(force: true)
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 2, "15 秒过了可以问；这次成功，退避从头算")
        source.listError = throttled(nil)
        feed.refreshNotificationUnread(force: true)
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 3)
        clock.advance(16)
        source.listError = nil
        feed.refreshNotificationUnread(force: true)
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 4, "成功之后再被限速又是 15 秒，不是 30 秒")
    }

    func testAFailureKeepsTheOldCountsAndIsSilent() async {
        let source = NSource()
        let feed = make(source)
        feed.setNotificationUnread(FeedUnreadCounts(interactions: 4))
        var changes = [FeedChange]()
        let sub = feed.subscribe { changes.append($0) }
        source.listError = NBoom()
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        XCTAssertEqual(feed.notificationUnread.interactions, 4)
        XCTAssertTrue(changes.isEmpty)
        sub.cancel()
    }

    func testFeedHiddenOnTheUnreadCheckIsSilentToo() async {
        let source = NSource()
        source.listError = feedHiddenError
        let feed = make(source)
        feed.setNotificationUnread(FeedUnreadCounts(system: 1))
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        XCTAssertEqual(feed.notificationUnread.system, 1)
    }

    func testAFailedCheckAlsoWaitsOutTheIntervalBeforeAskingAgain() async {
        let source = NSource()
        source.listError = NBoom()
        let clock = NClock(t0)
        let feed = make(source, clock: clock)
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        clock.advance(5)
        feed.refreshNotificationUnread()
        await feed.waitForNotificationUnread()
        XCTAssertEqual(source.count("list"), 1)
    }
}

// MARK: - 通知页 store 和信息流同步

@MainActor
final class TellomiFeedNotifyStoreSyncTests: XCTestCase {
    private func started(_ source: NSource, tab: String = "interactions") async -> (FeedStore, FeedNotificationsStore) {
        let feed = FeedStore(source: source, now: { t0 }, jitter: { 0 })
        let store = FeedNotificationsStore(initialTab: tab, source: source, feed: feed)
        store.start()
        await store.waitForTasks()
        return (feed, store)
    }

    func testTheFeedsUnreadAndThePagesUnreadAreOneCopy() async {
        let source = NSource()
        source.pages[NSource.key("interactions", nil)] = page([note("1", read: false)], unread: FeedUnreadCounts(interactions: 1, follows: 3))
        let (feed, store) = await started(source)
        XCTAssertEqual(store.state.unread, FeedUnreadCounts(follows: 3), "第一次打开这栏就整栏标已读，红点先清掉这一栏")
        XCTAssertEqual(feed.notificationUnread, FeedUnreadCounts(follows: 3), "信息流的红点同一份")
        XCTAssertEqual(source.count("read interactions"), 1)
        feed.setNotificationUnread(FeedUnreadCounts(follows: 9))
        XCTAssertEqual(store.state.unread.follows, 9, "信息流那边变了，这一页跟着变")
    }

    func testAPageStartsFromTheFeedsCountsBeforeAnythingLoads() {
        let source = NSource()
        let feed = FeedStore(source: source, now: { t0 }, jitter: { 0 })
        feed.setNotificationUnread(FeedUnreadCounts(interactions: 2))
        let store = FeedNotificationsStore(source: source, feed: feed)
        XCTAssertEqual(store.state.unread.interactions, 2)
    }

    func testDetachStopsBothSubscriptionsAndReleasesLeases() async {
        let source = NSource()
        source.cards["p1"] = postCard("p1")
        let (feed, store) = await started(source)
        XCTAssertTrue(store.isObservingFeed)
        store.openPost("p1")
        await store.waitForTasks()
        XCTAssertEqual(store.leaseCount, 1)
        store.detach()
        XCTAssertFalse(store.isObservingFeed)
        XCTAssertEqual(store.leaseCount, 0)
        feed.setNotificationUnread(FeedUnreadCounts(system: 4))
        XCTAssertEqual(store.state.unread.system, 0, "detach 之后不再跟")
        store.detach()
    }

    func testOpeningAPostHandsOverTheFeedsCopyAndTheDetailTakesTheLease() async {
        let source = NSource()
        source.cards["p1"] = postCard("p1", likes: 7)
        let (feed, store) = await started(source)
        store.openPost("p1")
        await store.waitForTasks()
        XCTAssertEqual(store.state.openCard?.id, "p1")
        XCTAssertEqual(feed.card(id: "p1")?.stats.likes, 7, "取到的最新卡片换进了信息流里")
        feed.toggleLike(id: "p1")
        XCTAssertEqual(store.state.openCard?.stats.likes, 8, "详情页打开之前别处点的赞，这边也是最新的")
        await feed.waitForActions()
        store.onCardOpened()
        XCTAssertNil(store.state.openCard)
        XCTAssertEqual(store.leaseCount, 0)
    }

    func testABlockedAuthorsPostCannotBeOpened() async {
        let source = NSource()
        source.cards["p1"] = postCard("p1", author: "bad")
        let (feed, store) = await started(source)
        feed.removeCards(byAuthor: "bad")
        store.openPost("p1")
        await store.waitForTasks()
        XCTAssertNil(store.state.openCard)
        XCTAssertEqual(store.state.notice, .postGone)
        XCTAssertEqual(store.leaseCount, 0)
    }

    func testADeletedPostCannotBeOpenedEither() async {
        let source = NSource()
        source.cards["p1"] = postCard("p1")
        let (feed, store) = await started(source)
        feed.removeCard(id: "p1")
        store.openPost("p1")
        await store.waitForTasks()
        XCTAssertNil(store.state.openCard)
        XCTAssertEqual(store.state.notice, .postGone)
    }

    func testAPostTheEngineNoLongerHasIsGoneAndErrorsAreClassified() async {
        let source = NSource()
        let (_, store) = await started(source)
        store.openPost("nope")
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .postGone)
        store.onNoticeShown()
        source.cardError = throttled(30)
        store.openPost("p1")
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 30)
        store.onNoticeShown()
        XCTAssertNil(store.state.retryAfterSeconds)
        source.cardError = notFoundError
        store.openPost("p1")
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .postGone)
        source.cardError = NBoom()
        store.openPost("p1")
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .failed)
        source.cardError = feedHiddenError
        store.openPost("p1")
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
    }

    func testWithoutAFeedItStillWorksAlone() async {
        let source = NSource()
        source.cards["p1"] = postCard("p1")
        source.pages[NSource.key("interactions", nil)] = page([note("1", read: false)], unread: FeedUnreadCounts(interactions: 1))
        let store = FeedNotificationsStore(source: source)
        store.start()
        await store.waitForTasks()
        XCTAssertFalse(store.isObservingFeed)
        store.openPost("p1")
        await store.waitForTasks()
        XCTAssertEqual(store.state.openCard?.id, "p1")
        XCTAssertEqual(store.state.unread, FeedUnreadCounts())
    }
}

// MARK: - 错误分类和翻页

@MainActor
final class TellomiFeedNotifyErrorTests: XCTestCase {
    func testAFirstPageFailureIsFailedAndAPagingFailureIsNot() async {
        let source = NSource()
        source.pages[NSource.key("interactions", nil)] = page(manyNotes(30))
        let store = FeedNotificationsStore(source: source)
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.count, 30)
        XCTAssertTrue(store.state.tab("interactions").hasMore)
        source.listError = NBoom()
        source.listErrorOnlyForBefore = true
        store.loadMore()
        await store.waitForTasks()
        let tab = store.state.tab("interactions")
        XCTAssertTrue(tab.loadMoreFailed)
        XCTAssertFalse(tab.failed, "翻页失败不算首页失败")
        XCTAssertEqual(tab.items.count, 30, "已有的留着")
        let presentation = FeedNotificationsPresentation(state: store.state, now: t0, calendar: utc)
        XCTAssertEqual(presentation.rows.last, .status(.loadMoreFailed(retryAfterSeconds: nil)))
        XCTAssertFalse(presentation.canLoadMore, "失败了不自动再翻，要点重试")
        source.listError = nil
        store.loadMore()
        await store.waitForTasks()
        XCTAssertFalse(store.state.tab("interactions").loadMoreFailed)
    }

    func testThrottledListGivesRetryAfterSecondsOnFirstPageAndOnPaging() async {
        let source = NSource()
        source.listError = throttled(25)
        let store = FeedNotificationsStore(source: source)
        store.start()
        await store.waitForTasks()
        XCTAssertTrue(store.state.tab("interactions").failed)
        XCTAssertEqual(store.state.tab("interactions").retryAfterSeconds, 25)
        XCTAssertEqual(FeedNotificationsPresentation(state: store.state, now: t0, calendar: utc).rows, [.status(.failed(retryAfterSeconds: 25))])
        source.listError = nil
        source.pages[NSource.key("interactions", nil)] = page(manyNotes(30))
        store.refresh()
        await store.waitForTasks()
        XCTAssertNil(store.state.tab("interactions").retryAfterSeconds, "成功后清掉")
        source.listError = throttled(11)
        source.listErrorOnlyForBefore = true
        store.loadMore()
        await store.waitForTasks()
        XCTAssertEqual(FeedNotificationsPresentation(state: store.state, now: t0, calendar: utc).rows.last, .status(.loadMoreFailed(retryAfterSeconds: 11)))
    }

    func testAPlain5xxIsAFailureWithoutSecondsAndA503WithRetryAfterIsThrottle() async {
        let source = NSource()
        source.listError = serverError
        let store = FeedNotificationsStore(source: source)
        store.start()
        await store.waitForTasks()
        XCTAssertTrue(store.state.tab("interactions").failed)
        XCTAssertNil(store.state.tab("interactions").retryAfterSeconds)
        source.listError = FeedAPIError(status: 503, code: "unavailable", retryAfterSeconds: 9)
        store.refresh()
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").retryAfterSeconds, 9)
    }

    func testFeedHiddenOnListCollapsesThePageInsteadOfFailing() async {
        let source = NSource()
        source.listError = feedHiddenError
        let store = FeedNotificationsStore(source: source)
        store.start()
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertFalse(store.state.tab("interactions").failed)
        let presentation = FeedNotificationsPresentation(state: store.state, now: t0, calendar: utc)
        XCTAssertTrue(presentation.feedHidden)
        XCTAssertEqual(presentation.rows, [])
    }

    func testAFailedRefreshKeepsWhatIsThereAndPutsAFailedRowOnTop() async {
        let source = NSource()
        source.pages[NSource.key("interactions", nil)] = page([note("1")])
        let store = FeedNotificationsStore(source: source)
        store.start()
        await store.waitForTasks()
        source.listError = NBoom()
        store.refresh()
        await store.waitForTasks()
        let rows = FeedNotificationsPresentation(state: store.state, now: t0, calendar: utc).rows
        XCTAssertEqual(rows.first, .status(.failed(retryAfterSeconds: nil)))
        XCTAssertEqual(rows.count, 3, "失败行 + 分组头 + 那一条")
    }

    func testDeleteGoneCountsAsDeletedAndOtherFailuresRollBack() async {
        let source = NSource()
        source.pages[NSource.key("interactions", nil)] = page([note("1", "comment", content: "p1"), note("2", "comment", content: "p2")])
        let store = FeedNotificationsStore(source: source)
        store.start()
        await store.waitForTasks()
        let row = FeedNotificationGrouping.group(store.state.tab("interactions").items, now: t0, calendar: utc)[0].rows[0]

        source.actionError = notFoundError
        store.delete(row)
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["2"], "404 当删成了，不放回来")
        XCTAssertEqual(store.state.notice, .deleted)
        store.onNoticeShown()

        let second = FeedNotificationGrouping.group(store.state.tab("interactions").items, now: t0, calendar: utc)[0].rows[0]
        source.actionError = NBoom()
        store.delete(second)
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["2"], "别的错放回来")
        XCTAssertEqual(store.state.notice, .failed)
        store.onNoticeShown()

        source.actionError = throttled(15)
        store.delete(second)
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["2"])
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 15)
        store.onNoticeShown()

        source.actionError = feedHiddenError
        store.delete(second)
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
    }

    func testMuteGoneSaysThePostIsGoneAndKeepsTheRowsRemovedWhileOtherFailuresRollBack() async {
        let source = NSource()
        source.pages[NSource.key("interactions", nil)] = page([note("1", "like", content: "p1"), note("2", "comment", content: "p1", ago: 6), note("3", "like", content: "p2", ago: 7)])
        let store = FeedNotificationsStore(source: source)
        store.start()
        await store.waitForTasks()
        let rows = FeedNotificationGrouping.group(store.state.tab("interactions").items, now: t0, calendar: utc)[0].rows

        source.actionError = notFoundError
        store.mute(rows[0], likesOnly: true)
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["2", "3"], "只关赞：评论留着")
        XCTAssertEqual(store.state.notice, .postGone)
        store.onNoticeShown()

        source.actionError = NBoom()
        store.mute(rows[1], likesOnly: false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["2", "3"], "失败放回来")
        XCTAssertEqual(store.state.notice, .failed)
        store.onNoticeShown()

        source.actionError = nil
        store.mute(rows[1], likesOnly: false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.map(\.id), ["3"])
        XCTAssertEqual(store.state.notice, .muted)
    }

    func testAnActorTheEngineOnlyGivesAnIdForIsLookedUpOnceAndFeedsTheName() async {
        let source = NSource()
        source.profiles["a1"] = FeedProfilePage(id: "a1", displayName: "小满")
        source.pages[NSource.key("interactions", nil)] = page([note("1", "reply", actor: "a1", content: "p1"), note("2", "comment", actor: "a1", content: "p2", ago: 6)])
        let store = FeedNotificationsStore(source: source)
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(store.state.people["a1"]?.displayName, "小满")
        XCTAssertEqual(source.count("profile"), 1)
        let presentation = FeedNotificationsPresentation(state: store.state, now: t0, calendar: utc)
        guard case .notification(let row) = presentation.rows[1] else { return XCTFail("应该是通知行") }
        XCTAssertEqual(presentation.summary(for: row), .replied(name: "小满"))
    }
}

// MARK: - 页面要画什么

final class TellomiFeedNotifyPresentationTests: XCTestCase {
    private func row(_ item: FeedNotification, more: [FeedNotification] = []) -> FeedNotificationRow {
        FeedNotificationGrouping.group([item] + more, now: t0, calendar: utc)[0].rows[0]
    }

    func testRowsHeadersAndStatuses() {
        var state = FeedNotificationsState()
        XCTAssertEqual(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).rows, [], "还没开始：什么也没有")
        state.tabs["interactions"] = FeedNotificationsTab(loading: true)
        XCTAssertEqual(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).rows, [.status(.loading)])
        state.tabs["interactions"] = FeedNotificationsTab(loadedOnce: true)
        XCTAssertEqual(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).rows, [.status(.empty(tab: "interactions"))])
        state.selectedTab = "system"
        state.tabs["system"] = FeedNotificationsTab(loadedOnce: true)
        XCTAssertEqual(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).rows, [.status(.empty(tab: "system"))])

        state.selectedTab = "interactions"
        state.tabs["interactions"] = FeedNotificationsTab(items: [note("1", ago: 5), note("2", "comment", ago: 60 * 24 * 3), note("3", "comment", ago: 60 * 24 * 20)], loadedOnce: true, hasMore: true)
        let rows = FeedNotificationsPresentation(state: state, now: t0, calendar: utc).rows
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows[0], .header(.today))
        XCTAssertEqual(rows[2], .header(.thisWeek))
        XCTAssertEqual(rows[4], .header(.earlier))

        state.tabs["interactions"]?.loadingMore = true
        XCTAssertEqual(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).rows.last, .status(.loadingMore))
    }

    func testCanLoadMoreOnlyWhenThereIsAPageAndNothingIsRunningOrFailed() {
        var state = FeedNotificationsState()
        state.tabs["interactions"] = FeedNotificationsTab(items: [note("1")], loadedOnce: true, hasMore: true)
        XCTAssertTrue(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).canLoadMore)
        state.tabs["interactions"]?.hasMore = false
        XCTAssertFalse(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).canLoadMore)
        state.tabs["interactions"]?.hasMore = true
        state.tabs["interactions"]?.loading = true
        XCTAssertFalse(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).canLoadMore)
        state.tabs["interactions"]?.loading = false
        state.tabs["interactions"]?.loadingMore = true
        XCTAssertFalse(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).canLoadMore)
        state.tabs["interactions"]?.loadingMore = false
        state.tabs["interactions"]?.loadMoreFailed = true
        XCTAssertFalse(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).canLoadMore)
        state.tabs["interactions"]?.loadMoreFailed = false
        state.tabs["interactions"]?.failed = true
        XCTAssertFalse(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).canLoadMore)
    }

    func testBadgesPerTab() {
        var state = FeedNotificationsState()
        state.unread = FeedUnreadCounts(interactions: 1, follows: 2, system: 3)
        let presentation = FeedNotificationsPresentation(state: state, now: t0, calendar: utc)
        XCTAssertEqual([FeedAPI.notificationsInteractions, FeedAPI.notificationsFollows, FeedAPI.notificationsSystem].map { presentation.badge(for: $0) }, [1, 2, 3])
    }

    func testSummaries() {
        let people = [
            "a": FeedPersonSummary(id: "a", handle: nil, displayName: "甲", avatarKey: nil),
            "b": FeedPersonSummary(id: "b", handle: nil, displayName: "乙", avatarKey: nil),
            "c": FeedPersonSummary(id: "c", handle: nil, displayName: "丙", avatarKey: nil),
            "e": FeedPersonSummary(id: "e", handle: nil, displayName: "", avatarKey: nil),
        ]
        func summary(_ item: FeedNotification, more: [FeedNotification] = []) -> FeedNotificationSummary {
            FeedNotificationsPresentation.summary(for: row(item, more: more), people: people)
        }
        XCTAssertEqual(summary(note("1", "like", actor: "a"), more: [note("2", "like", actor: "b", ago: 6), note("3", "like", actor: "c", ago: 7), note("4", "like", actor: "zz", ago: 8)]),
                       .liked(names: ["甲", "乙"], total: 4), "最多说两个名字，人数是全部（含没查到名字的）")
        XCTAssertEqual(summary(note("1", "like", actor: "zz")), .liked(names: [], total: 1))
        XCTAssertEqual(summary(note("1", "like", actor: nil)), .liked(names: [], total: 1), "没有 actor 也至少算一个人")
        XCTAssertEqual(summary(note("1", "comment", actor: "a")), .commented(name: "甲"))
        XCTAssertEqual(summary(note("1", "comment", actor: "zz")), .commented(name: nil))
        XCTAssertEqual(summary(note("1", "comment", actor: "e")), .commented(name: nil), "名字是空的当没查到")
        XCTAssertEqual(summary(note("1", "reply", actor: "b")), .replied(name: "乙"))
        XCTAssertEqual(summary(note("1", "comment", actor: "a", detail: FeedNotificationDetail(held: true))), .commentHeld(name: "甲"))
        XCTAssertEqual(summary(note("1", "reply", actor: "a", detail: FeedNotificationDetail(held: true))), .replyHeld(name: "甲"))
        XCTAssertEqual(summary(note("1", "follow", actor: "c", content: nil)), .followed(name: "丙"))
        XCTAssertEqual(summary(note("1", "follow_request", actor: "c", content: nil)), .followRequested(name: "丙"))
        XCTAssertEqual(summary(note("1", "system", actor: nil, detail: FeedNotificationDetail(type: "rejected"))), .system(.rejected))
        XCTAssertEqual(summary(note("1", "system", actor: nil, detail: FeedNotificationDetail(type: "edit_rejected"))), .system(.editRejected))
        XCTAssertEqual(summary(note("1", "system", actor: nil, detail: FeedNotificationDetail(type: "taken_down"))), .system(.takenDown))
        XCTAssertEqual(summary(note("1", "system", actor: nil, detail: FeedNotificationDetail(type: "appeal_upheld"))), .system(.appealUpheld))
        XCTAssertEqual(summary(note("1", "system", actor: nil, detail: FeedNotificationDetail(type: "appeal_overturned"))), .system(.appealOverturned))
        XCTAssertEqual(summary(note("1", "system", actor: nil, detail: FeedNotificationDetail(type: "something_new"))), .system(.other))
        XCTAssertEqual(summary(note("1", "system", actor: nil, detail: nil)), .system(.other))
        XCTAssertEqual(summary(note("1", "system", actor: nil, content: nil, detail: FeedNotificationDetail(type: "close_person_request", profileId: "b"))), .closePersonRequest(name: "乙"))
        XCTAssertEqual(summary(note("1", "system", actor: nil, content: nil, detail: FeedNotificationDetail(type: "close_person_request", profileId: "zz"))), .closePersonRequest(name: nil))
        XCTAssertEqual(summary(note("1", "brand_new_kind")), .other)
    }

    func testTargetsAndMuteAvailability() {
        XCTAssertEqual(FeedNotificationsPresentation.target(for: row(note("1", "like", content: "p9"))), .post(contentId: "p9"))
        XCTAssertEqual(FeedNotificationsPresentation.target(for: row(note("1", "comment", content: "p9"))), .post(contentId: "p9"))
        XCTAssertEqual(FeedNotificationsPresentation.target(for: row(note("1", "reply", content: "p9"))), .post(contentId: "p9"))
        XCTAssertNil(FeedNotificationsPresentation.target(for: row(note("1", "comment", content: nil))))
        XCTAssertNil(FeedNotificationsPresentation.target(for: row(note("1", "comment", content: ""))))
        XCTAssertEqual(FeedNotificationsPresentation.target(for: row(note("1", "follow", actor: "x", content: nil))), .profile(id: "x"))
        XCTAssertEqual(FeedNotificationsPresentation.target(for: row(note("1", "follow_request", actor: "x", content: nil))), .profile(id: "x"))
        XCTAssertNil(FeedNotificationsPresentation.target(for: row(note("1", "follow", actor: nil, content: nil))))
        XCTAssertEqual(FeedNotificationsPresentation.target(for: row(note("1", "system", actor: nil, content: nil, detail: FeedNotificationDetail(type: "close_person_request", profileId: "o")))), .profile(id: "o"))
        XCTAssertNil(FeedNotificationsPresentation.target(for: row(note("1", "system", actor: nil, detail: FeedNotificationDetail(type: "taken_down")))), "被下架的通知不能点")
        XCTAssertNil(FeedNotificationsPresentation.target(for: row(note("1", "system", actor: nil, content: nil, detail: FeedNotificationDetail(type: "rejected", profileId: "o")))), "只有亲密好友请求能点，别的系统通知哪怕带了 profile_id 也不能")
        XCTAssertNil(FeedNotificationsPresentation.target(for: row(note("1", "weird"))))

        XCTAssertTrue(FeedNotificationsPresentation.canMute(row(note("1", "like"))))
        XCTAssertTrue(FeedNotificationsPresentation.canMute(row(note("1", "comment"))))
        XCTAssertFalse(FeedNotificationsPresentation.canMute(row(note("1", "follow", actor: "x", content: nil))))
        XCTAssertFalse(FeedNotificationsPresentation.canMute(row(note("1", "system", actor: nil))))
    }

    func testFeedHiddenEmptiesTheRows() {
        var state = FeedNotificationsState()
        state.tabs["interactions"] = FeedNotificationsTab(items: [note("1")], loadedOnce: true)
        state.feedHidden = true
        XCTAssertEqual(FeedNotificationsPresentation(state: state, now: t0, calendar: utc).rows, [])
    }
}

// MARK: - 样例数据

@MainActor
final class TellomiFeedNotifySampleTests: XCTestCase {
    private func make() -> SampleFeedSource { SampleFeedSource(now: { t0 }) }

    func testInteractionsHaveMergedLikesAPagedTailAndUnreadCounts() async throws {
        let source = make()
        let first = try await source.notifications(tab: "interactions", before: nil)
        XCTAssertEqual(first.notifications.count, 30)
        XCTAssertEqual(first.unread, FeedUnreadCounts(interactions: 6, follows: 2, system: 2))
        let ids = first.notifications.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let dates = first.notifications.compactMap { FeedDates.parse($0.createdAt) }
        XCTAssertEqual(dates, dates.sorted(by: >), "新的在前")
        let second = try await source.notifications(tab: "interactions", before: first.notifications.last?.createdAt)
        XCTAssertEqual(second.notifications.count, 6)
        XCTAssertTrue(Set(second.notifications.map(\.id)).isDisjoint(with: ids))
        let sections = FeedNotificationGrouping.group(first.notifications, now: t0, calendar: utc)
        XCTAssertEqual(sections.first?.rows.first?.actorIds.count, 3, "sample-0 上三个人的赞合成一行")
        XCTAssertTrue(first.notifications.contains { $0.kind == "reply" && $0.actor == nil }, "有一条回复只带 actor_id")
        XCTAssertTrue(first.notifications.contains { $0.detail?.held == true })
    }

    func testReadingATabClearsItsUnreadAndDeleteAndMuteTakeEffect() async throws {
        let source = make()
        try await source.markNotificationsRead(tab: "interactions")
        var response = try await source.notifications(tab: "interactions", before: nil)
        XCTAssertEqual(response.unread, FeedUnreadCounts(interactions: 0, follows: 2, system: 2))
        XCTAssertTrue(response.notifications.allSatisfy(\.read))
        try await source.deleteNotification(id: "n-i-4")
        try await source.muteNotifications(contentId: "sample-0", likesOnly: true)
        response = try await source.notifications(tab: "interactions", before: nil)
        XCTAssertFalse(response.notifications.contains { $0.id == "n-i-4" })
        XCTAssertFalse(response.notifications.contains { $0.contentId == "sample-0" && $0.kind == "like" })
        XCTAssertTrue(response.notifications.contains { $0.id == "n-i-12" && $0.contentId == "sample-0" }, "只关赞：sample-0 上的评论还在")
        try await source.muteNotifications(contentId: "sample-1", likesOnly: false)
        response = try await source.notifications(tab: "interactions", before: nil)
        XCTAssertFalse(response.notifications.contains { $0.contentId == "sample-1" })
    }

    func testFollowsAndSystemTabs() async throws {
        let source = make()
        let follows = try await source.notifications(tab: "follows", before: nil)
        XCTAssertEqual(Set(follows.notifications.map(\.kind)), ["follow", "follow_request"])
        let system = try await source.notifications(tab: "system", before: nil)
        XCTAssertEqual(system.notifications.compactMap { $0.detail?.type }.first, "rejected")
        XCTAssertTrue(system.notifications.contains { $0.detail?.type == "close_person_request" && $0.detail?.profileId == "s-1" })
    }

    func testSimulationKnobsFailThrottleAndHide() async {
        let source = make()
        source.simulation.failsNotifications = true
        do { _ = try await source.notifications(tab: "interactions", before: nil); XCTFail("应该失败") } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .failed)
        }
        source.simulation.failsNotifications = false
        source.simulation.failsNotificationsMore = true
        let ok = try? await source.notifications(tab: "interactions", before: nil)
        XCTAssertEqual(ok?.notifications.count, 30, "只让翻页失败")
        do { _ = try await source.notifications(tab: "interactions", before: iso(1000)); XCTFail("翻页应该失败") } catch {}
        source.simulation.failsNotificationsMore = false
        source.simulation.notificationsThrottledRetryAfterSeconds = 12
        do { _ = try await source.notifications(tab: "interactions", before: nil); XCTFail("应该限速") } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .throttled(retryAfterSeconds: 12))
        }
        source.simulation.notificationsThrottledRetryAfterSeconds = nil
        source.simulation.feedHidden = true
        do { _ = try await source.notifications(tab: "interactions", before: nil); XCTFail("应该 feed_hidden") } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .feedHidden)
        }
        source.simulation.feedHidden = false
        source.simulation.failsNotificationActions = true
        do { try await source.deleteNotification(id: "n-i-1"); XCTFail("应该失败") } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .failed)
        }
        source.simulation.failsNotificationActions = false
        source.simulation.notificationActionsGone = true
        do { try await source.muteNotifications(contentId: "sample-0", likesOnly: false); XCTFail("应该 404") } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .gone)
        }
    }

    func testSampleSettingsRoundTripAndKnobs() async throws {
        let source = make()
        var settings = try await source.notificationSettings()
        settings.likes = false
        _ = try await source.saveNotificationSettings(settings)
        let again = try await source.notificationSettings()
        XCTAssertEqual(again.likes, false)
        source.simulation.notificationSettingsNeedProfile = true
        do { _ = try await source.saveNotificationSettings(settings); XCTFail("应该 409") } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .profileRequired)
        }
        source.simulation.notificationSettingsNeedProfile = false
        source.simulation.notificationSettingsThrottledRetryAfterSeconds = 7
        do { _ = try await source.saveNotificationSettings(settings); XCTFail("应该限速") } catch {
            XCTAssertEqual(FeedActionFailure.classify(error), .throttled(retryAfterSeconds: 7))
        }
        source.simulation.failsNotificationSettingsLoad = true
        do { _ = try await source.notificationSettings(); XCTFail("应该失败") } catch {}
    }

    func testTheStoreRunsOnTheSampleSourceEndToEnd() async {
        let source = make()
        let feed = FeedStore(source: source, now: { t0 }, jitter: { 0 })
        let store = FeedNotificationsStore(source: source, feed: feed)
        store.start()
        await store.waitForTasks()
        XCTAssertEqual(store.state.tab("interactions").items.count, 30)
        XCTAssertEqual(feed.notificationUnread, FeedUnreadCounts(follows: 2, system: 2), "打开互动栏后互动清零")
        XCTAssertEqual(store.state.people["s-5"]?.displayName, "夜跑的猫", "只带 actor_id 的回复靠查主页拿到名字")
        store.selectTab("follows")
        await store.waitForTasks()
        XCTAssertEqual(feed.notificationUnread, FeedUnreadCounts(system: 2))
        store.openPost("sample-1")
        await store.waitForTasks()
        XCTAssertEqual(store.state.openCard?.id, "sample-1")
        store.detach()
    }
}

// MARK: - 设置页的错误分类

@MainActor
final class TellomiFeedNotifySettingsTests: XCTestCase {
    private func loaded(_ source: NSource) async -> FeedNotificationSettingsStore {
        let store = FeedNotificationSettingsStore(source: source)
        store.load()
        await store.waitForTasks()
        return store
    }

    func testLoadFailuresAreClassified() async {
        let source = NSource()
        source.settingsLoadError = throttled(33)
        var store = await loaded(source)
        XCTAssertTrue(store.state.loadFailed)
        XCTAssertEqual(store.state.retryAfterSeconds, 33)
        source.settingsLoadError = feedHiddenError
        store = await loaded(source)
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertFalse(store.state.loadFailed)
        source.settingsLoadError = serverError
        store = await loaded(source)
        XCTAssertTrue(store.state.loadFailed)
        XCTAssertNil(store.state.retryAfterSeconds)
    }

    func testSaveFailuresAreClassifiedAndRolledBack() async {
        let source = NSource()
        let store = await loaded(source)
        let original = store.state.settings

        source.settingsSaveError = throttled(8)
        store.setLikes(false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.settings, original)
        XCTAssertEqual(store.state.notice, .throttled)
        XCTAssertEqual(store.state.retryAfterSeconds, 8)
        store.onNoticeShown()
        XCTAssertNil(store.state.retryAfterSeconds)

        source.settingsSaveError = FeedAPIError(status: 409, code: "profile_required")
        store.setComments(false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.settings, original)
        XCTAssertEqual(store.state.notice, .profileRequired)

        source.settingsSaveError = serverError
        store.setFollows(false)
        await store.waitForTasks()
        XCTAssertEqual(store.state.notice, .saveFailed)

        source.settingsSaveError = feedHiddenError
        store.setLikes(false)
        await store.waitForTasks()
        XCTAssertTrue(store.state.feedHidden)
        XCTAssertEqual(store.state.settings, original)
    }

    func testSavesGoOutInTheOrderOfTheTaps() async {
        let source = NSource()
        let store = await loaded(source)
        store.setFromWhom(FeedNotificationSettings.fromFollowing)
        store.setFromWhom(FeedNotificationSettings.fromNone)
        await store.waitForTasks()
        XCTAssertEqual(source.calls.filter { $0.hasPrefix("save") }, ["save following", "save none"])
        XCTAssertFalse(store.state.categoriesEnabled)
    }
}
