//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedMinorTime.swift (new file)
// Minor-mode time limits (I-15): 40 minutes a day, locked 22:00–06:00. Mirror of Android `FeedMinorTime.kt` (logic part).
// The lock page and the "which screens are wrapped" plumbing are UI and are not drafted.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 未成年人模式的时间限制（`dynamic-feed.md` 第三节第 31 条）：动态每天最多 40 分钟，22:00–6:00 不能用。
/// 是不是未成年人模式由引擎 `config.minor_mode` 说了算；时间按手机本地时间算，只管动态标签，聊天不受影响。
enum FeedMinorTime {
    static let dailyLimitMillis: Int64 = 40 * 60_000
    static let nightStartHour = 22
    static let nightEndHour = 6
    /// 多久记一次用了多少（也是到点后多快锁上）。
    static let tickMillis: Int64 = 15_000

    enum Lock: Equatable {
        case night
        case daily
    }

    /// 夜里先于每日用时：22:00 起到次日 06:00 前锁（夜间）；白天用满 40 分钟锁（当日）。
    static func lock(hour: Int, usedMillisToday: Int64) -> Lock? {
        if hour >= nightStartHour || hour < nightEndHour { return .night }
        if usedMillisToday >= dailyLimitMillis { return .daily }
        return nil
    }

    static func lock(now: Date, usedMillisToday: Int64, calendar: Calendar = .current) -> Lock? {
        return lock(hour: calendar.component(.hour, from: now), usedMillisToday: usedMillisToday)
    }

    /// 一天的标识 `yyyy-MM-dd`（本地日历；和 Android `LocalDate.toString()` 同形，存盘用）。
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// 今天在动态上用了多久。换了一天从零算。
protocol FeedMinorUsage: AnyObject {
    func usedMillis(day: String) -> Int64
    func add(day: String, millis: Int64)
}

class InMemoryFeedMinorUsage: FeedMinorUsage {
    fileprivate(set) var day: String?
    fileprivate(set) var used: Int64 = 0

    func usedMillis(day: String) -> Int64 {
        return day == self.day ? used : 0
    }

    func add(day: String, millis: Int64) {
        guard millis > 0 else { return }
        used = usedMillis(day: day) + millis
        self.day = day
        onChanged()
    }

    fileprivate func onChanged() {}
}

/// 存在本机，关掉 App 再开不清零。
///
/// 注意：iOS 的 `UserDefaults` 会进 iCloud / iTunes 备份，换新手机恢复后，当天已用的时间会跟着回来；
/// 这对「当日限额」是想要的（换手机不能重置）。Android 的 `SignalStore` 不进备份，所以两端这里不一样。
final class StoredFeedMinorUsage: InMemoryFeedMinorUsage {
    static let dayKey = "tellomiFeedMinorUsageDay"
    static let usedKey = "tellomiFeedMinorUsedMillis"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        let day = defaults.string(forKey: Self.dayKey)
        // 存的不是 `yyyy-MM-dd` 就当没存过（Android `runCatching { LocalDate.parse }`）
        self.day = day.flatMap { Self.isDayKey($0) ? $0 : nil }
        self.used = max(0, Int64(defaults.integer(forKey: Self.usedKey)))
    }

    override fileprivate func onChanged() {
        defaults.set(day, forKey: Self.dayKey)
        defaults.set(Int(used), forKey: Self.usedKey)
    }

    static func isDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        return year > 0 && (1...12).contains(month) && (1...31).contains(day)
    }
}

/// 动态标签开着（前台）时每 `FeedMinorTime.tickMillis` 记一次时，给出现在该不该锁。
/// 不是未成年人模式时一直是 nil、不计时。界面层在进前台 / 每 15 秒调一下（Android `rememberFeedMinorLock` 的循环）：
///
///     keeper.resume()            // 进前台：记起点，算一次
///     … 每 15 秒 …
///     keeper.tick()              // 先把这段时间记上（锁着的时候不算），再重算
final class FeedMinorTimeKeeper {
    private let minorMode: Bool
    private let usage: FeedMinorUsage
    private let clock: () -> Date
    private let monotonicMillis: () -> Int64
    private let calendar: Calendar

    private var last: Int64 = 0
    private(set) var lock: FeedMinorTime.Lock?

    init(
        minorMode: Bool,
        usage: FeedMinorUsage,
        clock: @escaping () -> Date = Date.init,
        monotonicMillis: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
        calendar: Calendar = .current,
    ) {
        self.minorMode = minorMode
        self.usage = usage
        self.clock = clock
        self.monotonicMillis = monotonicMillis
        self.calendar = calendar
        self.lock = minorMode ? Self.current(usage: usage, now: clock(), calendar: calendar) : nil
    }

    private static func current(usage: FeedMinorUsage, now: Date, calendar: Calendar) -> FeedMinorTime.Lock? {
        return FeedMinorTime.lock(now: now, usedMillisToday: usage.usedMillis(day: FeedMinorTime.dayKey(now, calendar: calendar)), calendar: calendar)
    }

    /// 进前台（或页面出现）：记起点并算一次。
    @discardableResult
    func resume() -> FeedMinorTime.Lock? {
        guard minorMode else { return nil }
        last = monotonicMillis()
        lock = Self.current(usage: usage, now: clock(), calendar: calendar)
        return lock
    }

    /// 每 15 秒一次：上一次算出来没锁，就把这段时间记到「当天」（以现在的日期为准）；然后重算。
    @discardableResult
    func tick() -> FeedMinorTime.Lock? {
        guard minorMode else { return nil }
        let now = monotonicMillis()
        let today = clock()
        if lock == nil {
            usage.add(day: FeedMinorTime.dayKey(today, calendar: calendar), millis: now - last)
        }
        last = now
        lock = Self.current(usage: usage, now: today, calendar: calendar)
        return lock
    }
}
