//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreGraphics

/// Tellomi（交互审计 A-12「录音：取消和锁定没有进度反馈」，iOS 半边）：按住录音往取消那边走了多少，
/// 红色录音圆和「滑动取消」提示就跟着淡、圆跟着变小（Telegram 两端都按左滑进度缩小录音圆：iOS
/// `TGModernConversationInputMicButton` `1 − 位移 / 300`，Android `ChatActivityEnterView` `0.7 + 0.3 × 进度`）。
/// 数和 Android `TellomiRecordingGesture` 同一组（Signal-Android#301）。
///
/// 上滑锁定的进度不在这里：上游的锁图标本来就随上滑把箭头收拢到锁上（同 Telegram iOS 的锁面板收拢）。
enum TellomiRecordingGesture {

    /// 取消进度到 1 时：录音圆淡到这个透明度、缩到这个比例；提示淡到 [hintMinAlpha]。
    static let buttonMinAlpha: CGFloat = 0.5
    static let buttonMinScale: CGFloat = 0.8
    static let hintMinAlpha: CGFloat = 0.3

    static func buttonAlpha(cancelProgress: CGFloat) -> CGFloat {
        lerp(1, buttonMinAlpha, cancelProgress)
    }

    static func buttonScale(cancelProgress: CGFloat) -> CGFloat {
        lerp(1, buttonMinScale, cancelProgress)
    }

    static func hintAlpha(cancelProgress: CGFloat) -> CGFloat {
        lerp(1, hintMinAlpha, cancelProgress)
    }

    private static func lerp(_ from: CGFloat, _ to: CGFloat, _ progress: CGFloat) -> CGFloat {
        let progress = min(max(progress, 0), 1)
        return from + (to - from) * progress
    }
}
