//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 未成年人时限（I-15）App 级的那一份：所有动态页面共用一个检查（`FeedMinorSession`），发布页锁着不能发（`FeedComposeStore`）。
@MainActor
final class TellomiFeedMinorSessionTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private final class Clock {
        var now: Date
        var millis: Int64 = 5_000_000
        init(_ now: Date) { self.now = now }
        func advance(minutes: Double) {
            now = now.addingTimeInterval(minutes * 60)
            millis += Int64(minutes * 60_000)
        }
    }

    private final class Screen {}

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: hour, minute: minute))!
    }

    private func session(_ clock: Clock, minor: Bool? = true, usage: FeedMinorUsage = InMemoryFeedMinorUsage()) -> FeedMinorSession {
        let gate = FeedMinorGate(memory: InMemoryFeedMinorModeMemory(lastKnown: minor), usage: usage, clock: { clock.now }, monotonicMillis: { clock.millis }, calendar: calendar)
        return FeedMinorSession(gate: gate)
    }

    func testTicksOnlyWhileSomeFeedScreenIsShownInTheForeground() async {
        let clock = Clock(date(10))
        let s = session(clock)
        var ticking = [Bool]()
        s.onTickingChanged = { ticking.append($0) }
        let feed = Screen()
        XCTAssertFalse(s.isTicking)
        s.screenWillAppear(feed)
        XCTAssertTrue(s.isTicking)
        XCTAssertTrue(s.gate.isRunning)
        s.didEnterBackground()
        XCTAssertFalse(s.isTicking)
        XCTAssertFalse(s.gate.isRunning)
        s.willEnterForeground()
        XCTAssertTrue(s.isTicking)
        s.screenDidDisappear(feed)
        XCTAssertFalse(s.isTicking)
        XCTAssertFalse(s.gate.isRunning)
        XCTAssertEqual(ticking, [true, false, true, false])
    }

    func testForegroundWithoutAFeedScreenDoesNotTick() async {
        let s = session(Clock(date(10)))
        s.didEnterBackground()
        s.willEnterForeground()
        XCTAssertFalse(s.isTicking)
        XCTAssertFalse(s.gate.isRunning)
    }

    func testPushingTheNextFeedPageKeepsCountingWithoutAGap() async {
        let clock = Clock(date(10))
        let usage = InMemoryFeedMinorUsage()
        let s = session(clock, usage: usage)
        var ticking = [Bool]()
        s.onTickingChanged = { ticking.append($0) }
        let feed = Screen()
        let detail = Screen()
        s.screenWillAppear(feed)
        clock.advance(minutes: 2)
        s.screenWillAppear(detail)
        s.screenDidDisappear(feed)
        XCTAssertEqual(s.visibleScreenCount, 1)
        XCTAssertTrue(s.isTicking)
        clock.advance(minutes: 3)
        s.timerFired()
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 5 * 60_000, "列表 2 分钟 + 详情 3 分钟，中间没断")
        XCTAssertEqual(ticking, [true])
    }

    func testTheSameScreenAppearingTwiceCountsOnce() async {
        let s = session(Clock(date(10)))
        let feed = Screen()
        s.screenWillAppear(feed)
        s.screenWillAppear(feed)
        s.screenDidDisappear(feed)
        XCTAssertFalse(s.isTicking)
        XCTAssertEqual(s.visibleScreenCount, 0)
    }

    func testEveryObserverHearsTheLockAndCancelledOnesDoNot() async {
        let clock = Clock(date(21, 59))
        let s = session(clock)
        var a = [FeedMinorTime.Lock?]()
        var b = [FeedMinorTime.Lock?]()
        var c = [FeedMinorTime.Lock?]()
        let ra = s.observe { a.append($0) }
        let rb = s.observe { b.append($0) }
        var rc: FeedMinorObservation? = s.observe { c.append($0) }
        XCTAssertEqual(s.observerCount, 3)
        rb.cancel()
        rc = nil
        XCTAssertNil(rc)
        s.screenWillAppear(Screen())
        XCTAssertNil(s.lock)
        clock.advance(minutes: 1)
        s.timerFired()
        XCTAssertEqual(s.lock, .night)
        XCTAssertTrue(s.isLocked)
        XCTAssertEqual(a, [.night])
        XCTAssertEqual(b, [])
        XCTAssertEqual(c, [])
        XCTAssertEqual(s.observerCount, 1)
        withExtendedLifetime(ra) {}
    }

    func testAScreenOpenedFromOutsideTheFeedTabSeesTheSameLock() async {
        let clock = Clock(date(12))
        let usage = InMemoryFeedMinorUsage()
        usage.add(day: "2026-10-13", millis: FeedMinorTime.dailyLimitMillis)
        let s = session(clock, usage: usage)
        XCTAssertEqual(s.lock, .daily, "通知推送 / 链接打开的详情：还没出现就已经锁着")
    }

    func testConfigGoesThroughTheSession() async {
        let s = session(Clock(date(23)), minor: false)
        XCTAssertNil(s.lock)
        var heard = [FeedMinorTime.Lock?]()
        let r = s.observe { heard.append($0) }
        s.configLoaded(minorMode: true)
        XCTAssertEqual(s.lock, .night)
        XCTAssertEqual(heard, [.night])
        withExtendedLifetime(r) {}
    }

    func testALockedComposePageCannotPublishButKeepsTheDraft() async {
        let source = ComposeLockSource()
        let store = FeedComposeStore(source: source, articleDrafts: InMemoryFeedArticleDrafts(), clientNonce: "n")
        store.onTextChanged("你好")
        XCTAssertTrue(store.state.canPublish)
        store.setMinorLocked(true)
        XCTAssertTrue(store.state.minorLocked)
        XCTAssertFalse(store.state.canPublish)
        store.publish()
        await store.waitForTasks()
        XCTAssertEqual(source.publishCount, 0)
        XCTAssertEqual(store.state.draft.text, "你好", "草稿留着")
        store.setMinorLocked(false)
        XCTAssertTrue(store.state.canPublish)
        store.publish()
        await store.waitForTasks()
        XCTAssertEqual(source.publishCount, 1, "解锁后接着发")
    }

    func testCanPublishStillNeedsAValidDraftAndNoPublishInFlight() async {
        let store = FeedComposeStore(source: ComposeLockSource(), articleDrafts: InMemoryFeedArticleDrafts(), clientNonce: "n")
        XCTAssertFalse(store.state.canPublish, "空草稿不能发")
        var state = FeedComposeState()
        state.draft.text = "x"
        XCTAssertTrue(state.canPublish)
        state.publishing = true
        XCTAssertFalse(state.canPublish)
    }

    func testALockedArticleIsStillSavedOnThePhone() async {
        let drafts = InMemoryFeedArticleDrafts()
        let store = FeedComposeStore(source: ComposeLockSource(), articleDrafts: drafts, clientNonce: "n")
        store.setMinorLocked(true)
        store.onKindChanged(.article)
        store.onTitleChanged("标题")
        store.onTextChanged("正文")
        XCTAssertEqual(drafts.load()?.text, "正文")
    }
}

private final class ComposeLockSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _publishCount = 0
    var publishCount: Int { lock.lock(); defer { lock.unlock() }; return _publishCount }

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        lock.withLock { _publishCount += 1 }
        return FeedCreatePostResponse(id: "p1", state: "published")
    }
}
