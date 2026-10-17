//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Tellomi 交互与动效标准（tellomi/tellomi `docs/product/INTERACTION_MOTION.md` 第三节）在 iOS 上的数值。
///
/// 页面代码不写时长和曲线，只从这里取。弹簧用 Apple 的「感知时长 + 回弹」两个参数描述（与 SwiftUI
/// `.spring(duration:bounce:)`、iOS 17 `UISpringTimingParameters(duration:bounce:)` 同一套），
/// 内部换成质量 1 的物理参数，所以 iOS 15 / 16 上的曲线与 17+ 完全一样。
/// owner 2026-09-26 定的弹簧性格是「活泼」；按下、滚动位置、页面转场三处永远不回弹。
public enum TellomiMotion {

    public struct Spring: Equatable, Sendable {
        /// 感知时长（秒）= 无阻尼周期。
        public let duration: TimeInterval
        /// 回弹：0 = 临界阻尼（不回弹）；越大越弹。
        public let bounce: CGFloat

        public init(duration: TimeInterval, bounce: CGFloat) {
            self.duration = duration
            self.bounce = bounce
        }

        /// 阻尼比 = 1 − bounce（bounce ≥ 0 时）。
        public var dampingRatio: CGFloat { 1 - max(0, bounce) }

        /// 质量 1 的刚度：(2π / duration)²。Android `SpringForce` 用同一个数。
        public var stiffness: CGFloat { pow(2 * .pi / CGFloat(duration), 2) }

        /// 质量 1 的阻尼系数：2ζ√k = 4πζ / duration。
        public var damping: CGFloat { 4 * .pi * dampingRatio / CGFloat(duration) }

        /// 同样的时长，去掉回弹（减弱动态效果时用）。
        public var withoutBounce: Spring { Spring(duration: duration, bounce: 0) }
    }

    /// 按下缩放 / 高亮。按下永远不回弹。
    public static let press = Spring(duration: 0.15, bounce: 0)
    /// 松开弹回。
    public static let release = Spring(duration: 0.3, bounce: 0.3)
    /// 小元素出现 / 消失、胶囊、角标。
    public static let snap = Spring(duration: 0.3, bounce: 0.3)
    /// 菜单、Sheet 落档、共享元素、列表补位。回弹约 5%，看得出来（owner 2026-09-26 定「明显回弹，两端一致」，与 Android `Move` 同一个回弹）。
    public static let move = Spring(duration: 0.4, bounce: 0.3)
    /// 整屏级：查看器开合。回弹约 1.5%，与 Android `Large` 同一个回弹。
    public static let large = Spring(duration: 0.45, bounce: 0.2)
    /// 回应落定、一次性成功。
    public static let emphasis = Spring(duration: 0.45, bounce: 0.4)
    /// 滚动位置（跳转、回到底部）。滚动位置永远不回弹。
    public static let scroll = Spring(duration: 0.45, bounce: 0)

    /// 固定时长弹簧：一段「质量 5、刚度 900、阻尼 `damping`」的弹簧，从起点到稳定整段压进 `duration` 秒。
    /// Telegram 两端聊天交互（回应条、长按菜单）的弹簧都是这个形状；owner 2026-10-14 定聊天交互照 Telegram，
    /// 所以回应条（交互审计 A-06 / A-07）用它，不用上面的「感知时长 + 回弹」Token。
    /// 内部换成质量 1 的等价参数（时间压缩 s 倍 = 刚度 × s²、阻尼 × s），UIKit 动画器和 Core Animation 都能直接用。
    public struct FixedDurationSpring: Equatable, Sendable {
        public static let baseMass: CGFloat = 5
        public static let baseStiffness: CGFloat = 900

        /// 质量 5 那段弹簧的阻尼系数。
        public let baseDamping: CGFloat
        /// 整段（到稳定为止）播完要多少秒。
        public let duration: TimeInterval
        /// 时间压缩倍数 = 原弹簧的稳定时长 / `duration`。
        public let timeScale: CGFloat

        public init(damping: CGFloat = 88, duration: TimeInterval) {
            self.baseDamping = damping
            self.duration = duration
            let base = CASpringAnimation()
            base.mass = Self.baseMass
            base.stiffness = Self.baseStiffness
            base.damping = damping
            self.timeScale = CGFloat(base.settlingDuration / duration)
        }

        /// 阻尼比：压缩时间不改变它。阻尼 88 ≈ 0.66（回弹约 7%），104 ≈ 0.78（约 2%）。
        public var dampingRatio: CGFloat { baseDamping / (2 * (Self.baseStiffness * Self.baseMass).squareRoot()) }
        /// 质量 1 的刚度。
        public var stiffness: CGFloat { Self.baseStiffness / Self.baseMass * timeScale * timeScale }
        /// 质量 1 的阻尼系数。
        public var damping: CGFloat { baseDamping / Self.baseMass * timeScale }

        /// 给 `UIViewPropertyAnimator`：用质量 / 刚度 / 阻尼描述时，动画器按弹簧自己的稳定时长播，也就是 `duration`。
        public func timingParameters() -> UISpringTimingParameters {
            UISpringTimingParameters(mass: 1, stiffness: stiffness, damping: damping, initialVelocity: .zero)
        }

        /// 给 Core Animation：时长就是这段弹簧的稳定时长（= `duration`）。
        public func animation(keyPath: String) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1
            animation.stiffness = stiffness
            animation.damping = damping
            animation.duration = animation.settlingDuration
            return animation
        }
    }

    /// 回应条条目、尾巴小圆、展开键出现：从 0.01 弹到原大，0.4 s（Telegram iOS `ReactionSelectionNode.appear`）。
    public static let reactionItemAppear = FixedDurationSpring(duration: 0.4)
    /// 回应条底板出现：0.3 s（Telegram iOS `ReactionContextBackgroundNode.animateIn`）。
    public static let reactionBarScaleIn = FixedDurationSpring(duration: 0.3)
    /// 回应条底板从锚点那一小块拉到全宽：阻尼 104、0.5 s（Telegram iOS `animateInFromAnchorRect`）。
    public static let reactionBarWiden = FixedDurationSpring(damping: 104, duration: 0.5)

    /// 纯透明度变化：淡入 ease-out、淡出 ease-in。
    public static let fadeInDuration: TimeInterval = 0.2
    public static let fadeOutDuration: TimeInterval = 0.15
    /// 减弱动态效果时，缩放 / 位移 / 共享元素改成这段时长的交叉淡入。
    public static let reducedMotionCrossfadeDuration: TimeInterval = 0.2

    @MainActor
    public static var isReduceMotionEnabled: Bool { UIAccessibility.isReduceMotionEnabled }

    /// 按系统设置取实际要用的弹簧：减弱动态效果时去掉回弹（HIG：收紧弹簧、减少回弹）。
    public static func resolved(_ spring: Spring, reduceMotion: Bool) -> Spring {
        reduceMotion ? spring.withoutBounce : spring
    }

    /// 与 Token 等价的 `UISpringTimingParameters`。[initialVelocity] 是「每秒走完剩余路程的比例」，见 [relativeVelocity]。
    public static func timingParameters(_ spring: Spring, initialVelocity: CGVector = .zero) -> UISpringTimingParameters {
        UISpringTimingParameters(mass: 1, stiffness: spring.stiffness, damping: spring.damping, initialVelocity: initialVelocity)
    }

    /// 可打断的弹簧动画器：动画中可以被触摸接管；减弱动态效果时自动去回弹。
    @MainActor
    public static func animator(
        _ spring: Spring,
        initialVelocity: CGVector = .zero,
        reduceMotion: Bool? = nil,
        animations: (() -> Void)? = nil,
    ) -> UIViewPropertyAnimator {
        let resolvedSpring = resolved(spring, reduceMotion: reduceMotion ?? isReduceMotionEnabled)
        let animator = UIViewPropertyAnimator(
            duration: resolvedSpring.duration,
            timingParameters: timingParameters(resolvedSpring, initialVelocity: initialVelocity),
        )
        animator.isUserInteractionEnabled = true
        if let animations {
            animator.addAnimations(animations)
        }
        return animator
    }

    /// 手势速度（点 / 秒）换算成弹簧要的初速：松手时从手指的速度出发，而不是从零开始（标准第四节）。
    /// 剩余路程几乎为零的轴返回 0，避免除出巨大的数。
    public static func relativeVelocity(_ velocity: CGPoint, remaining: CGVector) -> CGVector {
        func ratio(_ speed: CGFloat, _ distance: CGFloat) -> CGFloat {
            abs(distance) < 0.5 ? 0 : speed / distance
        }
        return CGVector(dx: ratio(velocity.x, remaining.dx), dy: ratio(velocity.y, remaining.dy))
    }
}
