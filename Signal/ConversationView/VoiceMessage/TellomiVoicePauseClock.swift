//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（Telegram 对照 3.3 / F12）：录音暂停 / 继续的状态和时长。
/// 只算“真正在录”的时间：暂停期间不计。纯值类型，时间由调用方传入，方便单测。
struct TellomiVoicePauseClock: Equatable {
    enum State: Equatable {
        case idle
        case recording(since: TimeInterval)
        case paused
        case stopped
    }

    private(set) var state: State = .idle
    /// 之前各段录音已累计的时长（不含当前正在录的这一段）。
    private(set) var accumulated: TimeInterval = 0

    var isRecording: Bool { if case .recording = state { return true } else { return false } }
    var isPaused: Bool { state == .paused }

    /// 开始录（只能从 idle 开始）。返回是否生效。
    @discardableResult
    mutating func start(at now: TimeInterval) -> Bool {
        guard state == .idle else { return false }
        state = .recording(since: now)
        return true
    }

    /// 暂停（只在录音中生效）。
    @discardableResult
    mutating func pause(at now: TimeInterval) -> Bool {
        guard case .recording(let since) = state else { return false }
        accumulated += max(0, now - since)
        state = .paused
        return true
    }

    /// 继续（只在暂停中生效）。
    @discardableResult
    mutating func resume(at now: TimeInterval) -> Bool {
        guard state == .paused else { return false }
        state = .recording(since: now)
        return true
    }

    /// 结束，返回总时长；idle 或已结束返回 nil。
    @discardableResult
    mutating func stop(at now: TimeInterval) -> TimeInterval? {
        switch state {
        case .idle, .stopped: return nil
        case .recording, .paused:
            let total = elapsed(at: now)
            accumulated = total
            state = .stopped
            return total
        }
    }

    /// 到 now 为止的有效录音时长。
    func elapsed(at now: TimeInterval) -> TimeInterval {
        if case .recording(let since) = state { return accumulated + max(0, now - since) }
        return accumulated
    }
}
