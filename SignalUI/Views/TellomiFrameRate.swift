//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import QuartzCore

/// Tellomi（交互审计 A-04「iOS 没开高刷新率的键」）：`Signal-Info.plist` 加了 `CADisableMinimumFrameDurationOnPhone`，
/// ProMotion 的 iPhone 上 CADisplayLink 才能跑过 60 Hz（不加这个键，帧率提示最高 60）。
/// 不全局拉满：每个逐帧驱动的动效按它的性质要帧率，低电量、过热时系统还会再降。
/// Telegram iOS 同样开着这个键（`Telegram/BUILD` 的 Info.plist）。
public enum TellomiFrameRate {

    /// 跟手、滚动这类一眼看得出顿挫的：跳到某条消息的滚动、拖选 / 拖动排序时靠边自动滚。
    public static let interactive = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    /// 慢慢变的指示：录音音量、快拍进度条。60 Hz 够了，系统可以再降。
    public static let ambient = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
}
