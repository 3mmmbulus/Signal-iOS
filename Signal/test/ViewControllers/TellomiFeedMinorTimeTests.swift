//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedMinorTimeTests.swift (new file)
// Mirror of Android `FeedMinorTimeTest` (logic) + the keeper's tick loop + persistence.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class TellomiFeedMinorTimeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testNightHoursLockDaytimeDoesNotUntilFortyMinutesAreUsed() {
        func lock(_ hour: Int, _ minute: Int, _ used: Int64) -> FeedMinorTime.Lock? {
            return FeedMinorTime.lock(now: date(13, hour, minute), usedMillisToday: used, calendar: calendar)
        }
        XCTAssertNil(lock(21, 59, 0))
        XCTAssertEqual(lock(22, 0, 0), .night)
        XCTAssertEqual(lock(5, 59, 0), .night)
        XCTAssertNil(lock(6, 0, 0))
        XCTAssertNil(lock(12, 0, 40 * 60_000 - 1))
        XCTAssertEqual(lock(12, 0, 40 * 60_000), .daily)
        XCTAssertEqual(lock(23, 0, 40 * 60_000), .night, "夜里先说夜间")
    }

    func testUsageAddsUpWithinADayAndStartsOverTheNext() {
        let usage = InMemoryFeedMinorUsage()
        usage.add(day: "2026-10-13", millis: 10_000)
        usage.add(day: "2026-10-13", millis: 5_000)
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 15_000)
        XCTAssertEqual(usage.usedMillis(day: "2026-10-14"), 0)
        usage.add(day: "2026-10-14", millis: 1_000)
        XCTAssertEqual(usage.usedMillis(day: "2026-10-14"), 1_000)
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 0)
        usage.add(day: "2026-10-14", millis: 0)
        usage.add(day: "2026-10-14", millis: -5)
        XCTAssertEqual(usage.usedMillis(day: "2026-10-14"), 1_000, "不记零和负数")
    }

    func testDayKeyIsLocalAndIsoShaped() {
        XCTAssertEqual(FeedMinorTime.dayKey(date(3, 23, 59), calendar: calendar), "2026-10-03")
        XCTAssertEqual(FeedMinorTime.dayKey(date(3, 0, 0), calendar: calendar), "2026-10-03")
        XCTAssertTrue(StoredFeedMinorUsage.isDayKey("2026-10-03"))
        for bad in ["", "2026-1-3", "20261003", "2026-13-01", "2026-00-10", "abcd-ef-gh", "2026-10-03T00"] {
            XCTAssertFalse(StoredFeedMinorUsage.isDayKey(bad), bad)
        }
    }

    func testStoredUsageSurvivesARestartAndIgnoresGarbage() {
        let suite = "tellomi.minor.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = StoredFeedMinorUsage(defaults: defaults)
        first.add(day: "2026-10-13", millis: 90_000)
        let second = StoredFeedMinorUsage(defaults: defaults)
        XCTAssertEqual(second.usedMillis(day: "2026-10-13"), 90_000)
        XCTAssertEqual(second.usedMillis(day: "2026-10-14"), 0)

        defaults.set("not-a-day", forKey: StoredFeedMinorUsage.dayKey)
        defaults.set(-5, forKey: StoredFeedMinorUsage.usedKey)
        let third = StoredFeedMinorUsage(defaults: defaults)
        XCTAssertEqual(third.usedMillis(day: "2026-10-13"), 0)
        XCTAssertEqual(third.usedMillis(day: "not-a-day"), 0)
    }

    func testKeeperLocksOnceTheDaysTimeIsUsed() {
        let usage = InMemoryFeedMinorUsage()
        usage.add(day: "2026-10-13", millis: FeedMinorTime.dailyLimitMillis)
        let keeper = FeedMinorTimeKeeper(minorMode: true, usage: usage, clock: { self.date(13, 12) }, calendar: calendar)
        XCTAssertEqual(keeper.lock, .daily)
        XCTAssertEqual(keeper.resume(), .daily)
    }

    func testNotMinorModeNeverLocksAndNeverCounts() {
        let usage = InMemoryFeedMinorUsage()
        let keeper = FeedMinorTimeKeeper(minorMode: false, usage: usage, clock: { self.date(13, 0) }, calendar: calendar)
        XCTAssertNil(keeper.lock)
        XCTAssertNil(keeper.resume())
        XCTAssertNil(keeper.tick())
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 0)
    }

    func testTicksAddTheElapsedTimeAndLockAtFortyMinutes() {
        let usage = InMemoryFeedMinorUsage()
        var now = date(13, 12)
        var uptime: Int64 = 1_000_000
        let keeper = FeedMinorTimeKeeper(minorMode: true, usage: usage, clock: { now }, monotonicMillis: { uptime }, calendar: calendar)
        XCTAssertNil(keeper.resume())

        // 每 15 秒一次，记到第 40 分钟（160 次）正好锁
        var ticks = 0
        while keeper.lock == nil {
            now = now.addingTimeInterval(15)
            uptime += 15_000
            keeper.tick()
            ticks += 1
            XCTAssertLessThan(ticks, 1000)
        }
        XCTAssertEqual(ticks, 160)
        XCTAssertEqual(keeper.lock, .daily)
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), FeedMinorTime.dailyLimitMillis)

        // 锁着的时候不算用了
        now = now.addingTimeInterval(15)
        uptime += 15_000
        XCTAssertEqual(keeper.tick(), .daily)
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), FeedMinorTime.dailyLimitMillis)

        // 过了零点（早上 6 点前仍然是夜间），到 6 点解锁、新的一天从零算
        now = date(14, 5, 59)
        uptime += 1_000
        XCTAssertEqual(keeper.tick(), .night)
        now = date(14, 6, 0)
        uptime += 60_000
        XCTAssertNil(keeper.tick())
        XCTAssertEqual(usage.usedMillis(day: "2026-10-14"), 0, "这一次 tick 上一刻是锁着的，不计")
        now = date(14, 6, 1)
        uptime += 15_000
        keeper.tick()
        XCTAssertEqual(usage.usedMillis(day: "2026-10-14"), 15_000)
    }

    func testResumeRestartsTheClockSoBackgroundTimeIsNotCounted() {
        let usage = InMemoryFeedMinorUsage()
        var now = date(13, 12)
        var uptime: Int64 = 0
        let keeper = FeedMinorTimeKeeper(minorMode: true, usage: usage, clock: { now }, monotonicMillis: { uptime }, calendar: calendar)
        keeper.resume()
        uptime += 15_000
        keeper.tick()
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 15_000)

        // 退到后台 1 小时再回来：不计后台的时间
        uptime += 3_600_000
        now = now.addingTimeInterval(3600)
        keeper.resume()
        uptime += 15_000
        keeper.tick()
        XCTAssertEqual(usage.usedMillis(day: "2026-10-13"), 30_000)
    }
}
