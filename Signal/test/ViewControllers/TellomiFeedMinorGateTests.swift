//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 未成年人时限（I-15）接到页面生命周期的那一层：`FeedMinorGate`（记住 `minor_mode`、前台计时、暂停、配置变了换 keeper）。
/// 时间判定本身在 `TellomiFeedMinorTimeTests`。
@MainActor
final class TellomiFeedMinorGateTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private final class Clock {
        var now: Date
        var millis: Int64 = 1_000_000
        init(_ now: Date) { self.now = now }
        func advance(minutes: Double) {
            now = now.addingTimeInterval(minutes * 60)
            millis += Int64(minutes * 60_000)
        }
    }

    private func gate(_ clock: Clock, memory: FeedMinorModeMemory, usage: FeedMinorUsage = InMemoryFeedMinorUsage()) -> FeedMinorGate {
        return FeedMinorGate(memory: memory, usage: usage, clock: { clock.now }, monotonicMillis: { clock.millis }, calendar: calendar)
    }

    func testNeverHavingSeenAConfigMeansNoLimit() async {
        let clock = Clock(date(13, 23))
        let g = gate(clock, memory: InMemoryFeedMinorModeMemory())
        XCTAssertFalse(g.minorMode)
        g.resume()
        XCTAssertNil(g.lock, "夜里也不锁：从没拉到过配置")
    }

    func testTheLastKnownMinorModeAppliesBeforeTheConfigArrives() async {
        let clock = Clock(date(13, 23))
        let g = gate(clock, memory: InMemoryFeedMinorModeMemory(lastKnown: true))
        XCTAssertTrue(g.minorMode)
        XCTAssertEqual(g.lock, .night, "还没 resume，开页面那一刻就该锁着")
    }

    func testConfigIsRememberedAndChangesTheLock() async {
        let clock = Clock(date(13, 23))
        let memory = InMemoryFeedMinorModeMemory()
        let g = gate(clock, memory: memory)
        var changes = [FeedMinorTime.Lock?]()
        g.onChange = { changes.append($0) }
        g.resume()
        g.configLoaded(minorMode: true)
        XCTAssertEqual(memory.lastKnown, true)
        XCTAssertEqual(g.lock, .night)
        g.configLoaded(minorMode: true)
        g.configLoaded(minorMode: false)
        XCTAssertEqual(memory.lastKnown, false)
        XCTAssertNil(g.lock)
        XCTAssertEqual(changes, [.night, nil], "同样的值不重复通知")
    }

    func testConfigWhileNotRunningStillUpdatesTheLock() async {
        let clock = Clock(date(13, 23))
        let g = gate(clock, memory: InMemoryFeedMinorModeMemory())
        g.configLoaded(minorMode: true)
        XCTAssertFalse(g.isRunning)
        XCTAssertEqual(g.lock, .night)
    }

    func testFortyMinutesInTheForegroundLockForTheDay() async {
        let clock = Clock(date(13, 10))
        let usage = InMemoryFeedMinorUsage()
        let g = gate(clock, memory: InMemoryFeedMinorModeMemory(lastKnown: true), usage: usage)
        g.resume()
        XCTAssertNil(g.lock)
        clock.advance(minutes: 39.5)
        g.tick()
        XCTAssertNil(g.lock)
        clock.advance(minutes: 0.5)
        g.tick()
        XCTAssertEqual(g.lock, .daily)
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 40 * 60_000)
    }

    func testTimeInTheBackgroundOrOnAnotherTabIsNotCounted() async {
        let clock = Clock(date(13, 10))
        let usage = InMemoryFeedMinorUsage()
        let g = gate(clock, memory: InMemoryFeedMinorModeMemory(lastKnown: true), usage: usage)
        g.resume()
        clock.advance(minutes: 5)
        g.pause()
        XCTAssertFalse(g.isRunning)
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 5 * 60_000, "暂停时把最后这段记上")
        clock.advance(minutes: 60)
        g.tick()
        g.pause()
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 5 * 60_000, "暂停着 tick / 再暂停都不算")
        g.resume()
        clock.advance(minutes: 1)
        g.tick()
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 6 * 60_000, "回来从回来那一刻算")
    }

    func testResumingTwiceDoesNotDropTheTimeSinceTheLastTick() async {
        let clock = Clock(date(13, 10))
        let usage = InMemoryFeedMinorUsage()
        let g = gate(clock, memory: InMemoryFeedMinorModeMemory(lastKnown: true), usage: usage)
        g.resume()
        clock.advance(minutes: 2)
        g.resume()
        g.tick()
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 2 * 60_000)
    }

    func testSwitchingOffMinorModeWhileRunningRecordsTheOldStretchAndStopsCounting() async {
        let clock = Clock(date(13, 10))
        let usage = InMemoryFeedMinorUsage()
        let g = gate(clock, memory: InMemoryFeedMinorModeMemory(lastKnown: true), usage: usage)
        g.resume()
        clock.advance(minutes: 3)
        g.configLoaded(minorMode: false)
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 3 * 60_000)
        clock.advance(minutes: 50)
        g.tick()
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 3 * 60_000)
        XCTAssertNil(g.lock)
    }

    func testSwitchingOnWhileRunningStartsCountingFromNow() async {
        let clock = Clock(date(13, 10))
        let usage = InMemoryFeedMinorUsage()
        let g = gate(clock, memory: InMemoryFeedMinorModeMemory(lastKnown: false), usage: usage)
        g.resume()
        clock.advance(minutes: 30)
        g.configLoaded(minorMode: true)
        XCTAssertTrue(g.isRunning)
        clock.advance(minutes: 1)
        g.tick()
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 60_000, "不是未成年人模式的那 30 分钟不算")
    }

    func testTheNightLockLiftsAtSixAndAppliesAtTen() async {
        let clock = Clock(date(13, 5, 59))
        let g = gate(clock, memory: InMemoryFeedMinorModeMemory(lastKnown: true))
        var changes = [FeedMinorTime.Lock?]()
        g.onChange = { changes.append($0) }
        g.resume()
        XCTAssertEqual(g.lock, .night)
        clock.advance(minutes: 1)
        g.tick()
        XCTAssertNil(g.lock)
        clock.now = date(13, 22)
        g.tick()
        XCTAssertEqual(g.lock, .night)
        XCTAssertEqual(changes, [nil, .night])
    }

    func testStoredMemorySurvivesARestart() async {
        let suite = "tellomi.minor.gate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(StoredFeedMinorModeMemory(defaults: defaults).lastKnown)
        StoredFeedMinorModeMemory(defaults: defaults).lastKnown = true
        XCTAssertEqual(StoredFeedMinorModeMemory(defaults: defaults).lastKnown, true)
        StoredFeedMinorModeMemory(defaults: defaults).lastKnown = false
        XCTAssertEqual(StoredFeedMinorModeMemory(defaults: defaults).lastKnown, false, "false 也要存下来（不是没存）")
        StoredFeedMinorModeMemory(defaults: defaults).lastKnown = nil
        XCTAssertNil(StoredFeedMinorModeMemory(defaults: defaults).lastKnown)
        defaults.set("yes", forKey: StoredFeedMinorModeMemory.key)
        XCTAssertNil(StoredFeedMinorModeMemory(defaults: defaults).lastKnown, "不是 Bool 就当没存过")
    }

    func testTheLockPageKeysAndSymbols() async {
        XCTAssertEqual(FeedMinorLockPresentation.titleKey(.night), "TELLOMI_FEED_MINOR_LOCK_NIGHT_TITLE")
        XCTAssertEqual(FeedMinorLockPresentation.bodyKey(.night), "TELLOMI_FEED_MINOR_LOCK_NIGHT_BODY")
        XCTAssertEqual(FeedMinorLockPresentation.titleKey(.daily), "TELLOMI_FEED_MINOR_LOCK_DAILY_TITLE")
        XCTAssertEqual(FeedMinorLockPresentation.bodyKey(.daily), "TELLOMI_FEED_MINOR_LOCK_DAILY_BODY")
        XCTAssertNotEqual(FeedMinorLockPresentation.symbolName(.night), FeedMinorLockPresentation.symbolName(.daily))
        // 文案里写死了「22:00–6:00」「40 分钟」：常量改了要一起改文案
        XCTAssertEqual(FeedMinorTime.dailyLimitMillis, 40 * 60_000)
        XCTAssertEqual(FeedMinorTime.nightStartHour, 22)
        XCTAssertEqual(FeedMinorTime.nightEndHour, 6)
    }

    func testTheStoreReportsALoadedConfigButNotAFailedOne() async {
        let ok = MinorConfigSource(result: .success({ var c = FeedConfig(); c.minorMode = true; return c }()))
        let store = FeedStore(source: ok)
        var seen = [Bool]()
        store.onConfigLoaded = { seen.append($0.minorMode) }
        await store.loadConfig()
        XCTAssertEqual(seen, [true])
        let failing = FeedStore(source: MinorConfigSource(result: .failure(URLError(.notConnectedToInternet))))
        failing.onConfigLoaded = { seen.append($0.minorMode) }
        await failing.loadConfig()
        XCTAssertEqual(seen, [true])
    }
}

/// 只给配置的假数据源。
private final class MinorConfigSource: FeedSource {
    let result: Result<FeedConfig, Error>
    init(result: Result<FeedConfig, Error>) {
        self.result = result
    }

    func config() async throws -> FeedConfig { try result.get() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        throw NSError(domain: "minor", code: 1)
    }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
}
