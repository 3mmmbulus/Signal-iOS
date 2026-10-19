//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 上一次拉到的 `config.minor_mode`（I-15）。开 App 时配置还没回来（或这次没拉到），就按上一次的算，
/// 免得未成年人断网 / 等配置的那几秒里能绕过时间限制。从来没拉到过 = nil，按「不是未成年人模式」算。
protocol FeedMinorModeMemory: AnyObject {
    var lastKnown: Bool? { get set }
}

final class InMemoryFeedMinorModeMemory: FeedMinorModeMemory {
    var lastKnown: Bool?

    init(lastKnown: Bool? = nil) {
        self.lastKnown = lastKnown
    }
}

/// 存在本机 `UserDefaults`。和 `StoredFeedMinorUsage` 一样会进 iCloud / iTunes 备份：换手机恢复后先按未成年人模式锁着，
/// 等配置回来再说（宁可多锁几秒，不能换手机就绕过去）。
final class StoredFeedMinorModeMemory: FeedMinorModeMemory {
    static let key = "tellomiFeedMinorModeLastKnown"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastKnown: Bool? {
        get { defaults.object(forKey: Self.key) as? Bool }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

/// 动态标签的未成年人时限（I-15，`dynamic-feed.md` 第三节第 31 条）：把 `FeedMinorTimeKeeper` 接到页面的生命周期上。
///
/// - 动态标签（连同从它推进去的详情、作者页…）在前台时 `resume()`，每 `FeedMinorTime.tickMillis` 调一次 `tick()`；
///   切到别的标签或退到后台时 `pause()`（先把最后这一小段记上再停）。
/// - 配置回来 `configLoaded(minorMode:)`：记住这次的值；变了就换一个 keeper（正在计时就先把旧的这段记上）。
/// - `lock` 变了调 `onChange`；页面据此盖上 / 拿掉提示页。只管动态，聊天不受影响。
@MainActor
final class FeedMinorGate {
    private let memory: FeedMinorModeMemory
    private let usage: FeedMinorUsage
    private let clock: () -> Date
    private let monotonicMillis: () -> Int64
    private let calendar: Calendar

    private var keeper: FeedMinorTimeKeeper
    private(set) var minorMode: Bool
    private(set) var lock: FeedMinorTime.Lock?
    private(set) var isRunning = false
    var onChange: ((FeedMinorTime.Lock?) -> Void)?

    init(
        memory: FeedMinorModeMemory,
        usage: FeedMinorUsage,
        clock: @escaping () -> Date = Date.init,
        monotonicMillis: @escaping () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1000) },
        calendar: Calendar = .current,
    ) {
        self.memory = memory
        self.usage = usage
        self.clock = clock
        self.monotonicMillis = monotonicMillis
        self.calendar = calendar
        let minorMode = memory.lastKnown ?? false
        self.minorMode = minorMode
        keeper = FeedMinorTimeKeeper(minorMode: minorMode, usage: usage, clock: clock, monotonicMillis: monotonicMillis, calendar: calendar)
        lock = keeper.lock
    }

    /// 配置拉到了。没拉到就别调（继续用上一次的）。
    func configLoaded(minorMode: Bool) {
        memory.lastKnown = minorMode
        guard minorMode != self.minorMode else { return }
        if isRunning { keeper.tick() }
        self.minorMode = minorMode
        keeper = FeedMinorTimeKeeper(minorMode: minorMode, usage: usage, clock: clock, monotonicMillis: monotonicMillis, calendar: calendar)
        publish(isRunning ? keeper.resume() : keeper.lock)
    }

    /// 动态标签到了前台。已经在计时就不重来（不然会丢掉上一次 tick 之后的那一段）。
    func resume() {
        guard !isRunning else { return }
        isRunning = true
        publish(keeper.resume())
    }

    /// 计时器每 15 秒一次。没在计时（后台 / 别的标签）不算。
    func tick() {
        guard isRunning else { return }
        publish(keeper.tick())
    }

    /// 离开动态标签或退到后台：把上一次 tick 到现在这段记上，然后停。
    func pause() {
        guard isRunning else { return }
        publish(keeper.tick())
        isRunning = false
    }

    private func publish(_ lock: FeedMinorTime.Lock?) {
        guard lock != self.lock else { return }
        self.lock = lock
        onChange?(lock)
    }
}

/// 提示页的文案 key（夜间 / 当日用满）。文案里的「22:00–6:00」「40 分钟」写死在文案里，和 `FeedMinorTime` 的常量一致（测试里对过）。
enum FeedMinorLockPresentation {
    static func titleKey(_ lock: FeedMinorTime.Lock) -> String {
        switch lock {
        case .night: return "TELLOMI_FEED_MINOR_LOCK_NIGHT_TITLE"
        case .daily: return "TELLOMI_FEED_MINOR_LOCK_DAILY_TITLE"
        }
    }

    static func bodyKey(_ lock: FeedMinorTime.Lock) -> String {
        switch lock {
        case .night: return "TELLOMI_FEED_MINOR_LOCK_NIGHT_BODY"
        case .daily: return "TELLOMI_FEED_MINOR_LOCK_DAILY_BODY"
        }
    }

    static func symbolName(_ lock: FeedMinorTime.Lock) -> String {
        switch lock {
        case .night: return "moon.zzz"
        case .daily: return "hourglass"
        }
    }
}
