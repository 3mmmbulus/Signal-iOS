//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Lottie
import SignalUI
import UIKit

/// 长按回应条上会动的表情（交互审计 A-06，owner 2026-10-17「和 Telegram 还不一样」）。
///
/// Telegram 两端一样：条出现时每个表情按自己的出场延迟播一遍「出场」动画，播完停在静止帧，不循环
/// （iOS `ReactionNode.appear` 播 `animateInAnimationNode`，播完换成 `staticAnimationNode`；
/// 安卓 `ReactionHolderView.play(delay)` 播 `enterImageView`，最后一帧换成 `loopImageView` 的第 0 帧）。
/// 手指滑到某个表情上时，Telegram iOS 只放大不播、安卓没有这一步，所以这里也只在出场时播。
///
/// 素材是 Google 的 Noto Emoji Animation（CC BY 4.0，不是 Telegram 的；`Signal/Lottie/tellomi_reactions_LICENSE.md`）。
/// 每个文件是一整圈、首尾同姿态，带一个 `rest` 标记（Noto 设计的静止姿态）：从 rest 帧播一整圈回到 rest 帧，停住不跳。
enum TellomiReactionAnimations {

    /// 表情（去掉 U+FE0F）→ 包里的文件。默认条上会出现的 10 个：Signal 默认 6 个和补第 7 个用的 🙏🔥🎉👏。
    /// 带肤色的、别的表情照旧是静态字形。
    private static let fileNames: [String: String] = [
        "👍": "tellomi_reaction_1f44d",
        "❤": "tellomi_reaction_2764_fe0f",
        "👎": "tellomi_reaction_1f44e",
        "😂": "tellomi_reaction_1f602",
        "😮": "tellomi_reaction_1f62e",
        "😢": "tellomi_reaction_1f622",
        "🙏": "tellomi_reaction_1f64f",
        "🔥": "tellomi_reaction_1f525",
        "🎉": "tellomi_reaction_1f389",
        "👏": "tellomi_reaction_1f44f",
    ]

    static var animatedEmoji: [String] { fileNames.keys.sorted() }

    static func fileName(for emoji: String) -> String? {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: emoji.unicodeScalars.filter { $0.value != 0xFE0F })
        return fileNames[String(scalars)]
    }

    /// 减弱动态效果、低电量模式下不用动画（条上是静态字形）。
    @MainActor
    static var isPlaybackAllowed: Bool {
        !TellomiMotion.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    static func animation(for emoji: String, bundle: Bundle = .main) -> LottieAnimation? {
        guard let name = fileName(for: emoji) else { return nil }
        return LottieAnimation.named(name, bundle: bundle)
    }

    static let restMarker = "rest"

    static func restFrame(of animation: LottieAnimation) -> AnimationFrameTime {
        animation.frameTime(forMarker: restMarker) ?? animation.startFrame
    }

    /// 从 rest 帧播一整圈回到 rest 帧要播的段。`lastFrame` 是最后一帧有画面的帧（`endFrame - 1`：图层在 endFrame 那一帧已经出场）。
    /// rest 在开头：一段；否则两段，rest → 尾，头 → rest。
    static func appearSegments(
        restFrame: AnimationFrameTime,
        startFrame: AnimationFrameTime,
        lastFrame: AnimationFrameTime,
    ) -> [ClosedRange<AnimationFrameTime>] {
        guard restFrame > startFrame, restFrame < lastFrame else {
            return [startFrame...lastFrame]
        }
        return [restFrame...lastFrame, startFrame...restFrame]
    }

    static func appearSegments(of animation: LottieAnimation) -> [ClosedRange<AnimationFrameTime>] {
        appearSegments(restFrame: restFrame(of: animation), startFrame: animation.startFrame, lastFrame: animation.endFrame - 1)
    }
}
