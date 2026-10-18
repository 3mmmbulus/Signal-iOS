//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedRetryAfter.swift (new file)
// `Retry-After` parsing, the 429 / 503 back-off rule and its gate (I-21). Foundation only, no clock of its own: every function takes `now`
// (and the jitter value), so tests run without sleeping.
//
// Rule (decision by tellomi测试, 2026-10-16), for the feed engine and for Signal-Server's tellomi routes (friend-assertions, audience-lists, feed/auth):
// - `Retry-After` is delta-seconds or an HTTP-date; the wait is clamped to [1, 3600] seconds.
// - 429, and 503 **with** `Retry-After`: stop, and do not send again before the wait is over. 429 without a usable header: the wait is
//   an exponential back-off with jitter (`FeedBackoff`). 503 without the header is an ordinary failure (as before).
// - Nothing that was queued is dropped because of this.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

enum FeedRetryAfter {
    static let minSeconds = 1
    static let maxSeconds = 3600

    /// 响应头 `Retry-After` 的值 → 要等几秒（已夹到 1…3600）。头没有、空的、读不懂 ⇒ nil（调用方用指数退避）。
    /// - 整数秒（只认 ASCII 数字，`0` ⇒ 1，位数再多也不溢出 ⇒ 3600）；`-5`、`1.5`、`+5`、`5s`、`1e3` 都是读不懂。
    /// - HTTP 日期（RFC 9110 的三种写法：`Sun, 06 Nov 1994 08:49:37 GMT`、`Sunday, 06-Nov-94 08:49:37 GMT`、`Sun Nov  6 08:49:37 1994`）：
    ///   离 `now` 的秒数向上取整；已经过去 ⇒ 1。
    static func parse(_ header: String?, now: Date) -> Int? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return nil }
        if value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
            // 太长的数字不用转，直接是「很大」
            if value.utf8.count > 9 { return maxSeconds }
            return clamp(Int(value) ?? maxSeconds)
        }
        guard let date = httpDate(value) else { return nil }
        let seconds = date.timeIntervalSince(now).rounded(.up)
        if seconds >= Double(maxSeconds) { return maxSeconds }
        if seconds <= Double(minSeconds) { return minSeconds }
        return Int(seconds)
    }

    static func clamp(_ seconds: Int) -> Int {
        return min(max(seconds, minSeconds), maxSeconds)
    }

    private static let dateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
        "EEEE, dd-MMM-yy HH:mm:ss 'GMT'",
        "EEE MMM d HH:mm:ss yyyy",
    ]

    private static func httpDate(_ value: String) -> Date? {
        // asctime 的日期是「空格补齐」的（`Nov  6`），折成一个空格再认
        let collapsed = value.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        for format in dateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: collapsed) { return date }
        }
        return nil
    }
}

/// 没有 `Retry-After` 的 429 用：指数退避 + 抖动（第 1 次约 30 秒，每次翻倍，封顶 3600 秒，和 Android `FeedCooldown` 同一套数；实际等待在 [一半, 全部] 里取，免得大家一起撞回来）。
enum FeedBackoff {
    static let base: TimeInterval = 30
    static let cap: TimeInterval = 3600

    /// `attempt` 从 1 数；`random` 是 0…1 的随机数（测试里传定值）。结果夹到 [1, 3600]。
    static func delay(attempt: Int, random: Double) -> Int {
        let exponent = max(attempt, 1) - 1
        let ceiling = min(cap, base * pow(2, Double(min(exponent, 30))))
        let jittered = ceiling / 2 + ceiling / 2 * min(max(random, 0), 1)
        return FeedRetryAfter.clamp(Int(jittered.rounded(.up)))
    }
}

extension FeedAPIError {
    static let tooManyUploadsCode = "too_many_uploads"

    /// 要退避的回答：429，或者带了 `Retry-After` 的 503（`retryAfterSeconds` 是解析 + 夹过的）。
    var isThrottle: Bool {
        // `too_many_uploads` 是引擎的并发上限（不是请求太频繁），和 Android 一样不算限速：照旧直接抛给调用方
        if code == FeedAPIError.tooManyUploadsCode { return false }
        return status == 429 || (status == 503 && retryAfterSeconds != nil)
    }
}

/// 一类请求的「在这之前别再发」：连续被限速的次数和解封时间。值类型，放在持有者里。
struct FeedRetryGate: Equatable {
    private(set) var blockedUntil: Date?
    /// 记下这次等待是从什么时候开始的：时钟被往回拨（现在早于它）就当等待已结束，和 Android `FeedCooldown` 一样。
    private(set) var blockedFrom: Date?
    private(set) var consecutiveThrottles = 0

    init() {}

    /// 还要等几秒；没在限速 ⇒ 0。时钟被调回去（现在早于开始等的时刻）⇒ 0（当作已结束），不会被一个坏时钟卡住。
    func remaining(now: Date) -> TimeInterval {
        guard let blockedUntil, let blockedFrom, now >= blockedFrom else { return 0 }
        return min(max(blockedUntil.timeIntervalSince(now), 0), TimeInterval(FeedRetryAfter.maxSeconds))
    }

    func isBlocked(now: Date) -> Bool { return remaining(now: now) > 0 }

    /// 记一次回答。被限速（`isThrottle`）⇒ 解封时间 = `now` + 头里的秒数，没有就按连续第几次指数退避；返回 true。
    /// 别的错误不动这个门（不是限速）；成功用 `reset()`。
    @discardableResult
    mutating func record(_ error: FeedAPIError, now: Date, random: Double) -> Bool {
        guard error.isThrottle else { return false }
        consecutiveThrottles += 1
        let seconds = error.retryAfterSeconds.map(FeedRetryAfter.clamp) ?? FeedBackoff.delay(attempt: consecutiveThrottles, random: random)
        let until = now.addingTimeInterval(TimeInterval(seconds))
        // 已经有更晚的解封时间就不提前
        if let blockedUntil, blockedUntil > until { return true }
        blockedUntil = until
        blockedFrom = now
        return true
    }

    mutating func reset() {
        blockedUntil = nil
        blockedFrom = nil
        consecutiveThrottles = 0
    }
}
