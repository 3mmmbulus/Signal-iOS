//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit
import XCTest

final class TellomiMotionTest: XCTestCase {

    /// 数值必须等于标准第三节（owner 2026-09-26 选「活泼」）；改了就是和标准脱节。
    func testTokensMatchTheStandard() {
        XCTAssertEqual(TellomiMotion.press, .init(duration: 0.15, bounce: 0))
        XCTAssertEqual(TellomiMotion.release, .init(duration: 0.3, bounce: 0.3))
        XCTAssertEqual(TellomiMotion.snap, .init(duration: 0.3, bounce: 0.3))
        XCTAssertEqual(TellomiMotion.move, .init(duration: 0.4, bounce: 0.3))
        XCTAssertEqual(TellomiMotion.large, .init(duration: 0.45, bounce: 0.2))
        XCTAssertEqual(TellomiMotion.emphasis, .init(duration: 0.45, bounce: 0.4))
        XCTAssertEqual(TellomiMotion.scroll, .init(duration: 0.45, bounce: 0))
    }

    /// 按下与滚动位置永远不回弹。
    func testPressAndScrollAreCriticallyDamped() {
        XCTAssertEqual(TellomiMotion.press.dampingRatio, 1)
        XCTAssertEqual(TellomiMotion.scroll.dampingRatio, 1)
    }

    /// 「活泼」要看得出来（owner 2026-09-26）：菜单 / Sheet / 共享元素回弹约 5%，查看器约 1.5%，小元素与回应落定更弹。
    /// 与 Android 的 `TellomiMotionTest` 用同一个过冲公式、同一组区间。
    func testLivelyTokensVisiblyOvershoot() {
        XCTAssertEqual(overshoot(TellomiMotion.move), 0.046, accuracy: 0.005)
        XCTAssertEqual(overshoot(TellomiMotion.large), 0.015, accuracy: 0.002)
        XCTAssertGreaterThan(overshoot(TellomiMotion.snap), 0.04)
        XCTAssertGreaterThan(overshoot(TellomiMotion.release), 0.04)
        XCTAssertGreaterThan(overshoot(TellomiMotion.emphasis), 0.09)
    }

    /// 欠阻尼弹簧从 0 到 1 的最大过冲比例：exp(−πζ / √(1 − ζ²))；ζ ≥ 1 时为 0。
    private func overshoot(_ spring: TellomiMotion.Spring) -> Double {
        let z = Double(spring.dampingRatio)
        return z >= 1 ? 0 : exp(-Double.pi * z / (1 - z * z).squareRoot())
    }

    /// Apple `Spring` 文档的例子：(0.5 s, bounce 0.3) → stiffness ≈ 157.9、damping ≈ 17.6（质量 1）。
    func testPhysicalParametersFollowApplesConversion() {
        let spring = TellomiMotion.Spring(duration: 0.5, bounce: 0.3)
        XCTAssertEqual(spring.stiffness, 157.91, accuracy: 0.01)
        XCTAssertEqual(spring.damping, 17.59, accuracy: 0.01)
        XCTAssertEqual(spring.dampingRatio, 0.7, accuracy: 1e-9)
    }

    func testTimingParametersCarryTheSameSpring() {
        let parameters = TellomiMotion.timingParameters(TellomiMotion.move, initialVelocity: CGVector(dx: 0, dy: 2))
        XCTAssertEqual(parameters.initialVelocity.dy, 2)
    }

    /// 减弱动态效果：保留时长，去掉回弹。
    func testReduceMotionRemovesBounceButKeepsDuration() {
        let reduced = TellomiMotion.resolved(TellomiMotion.emphasis, reduceMotion: true)
        XCTAssertEqual(reduced.bounce, 0)
        XCTAssertEqual(reduced.duration, TellomiMotion.emphasis.duration)
        XCTAssertEqual(TellomiMotion.resolved(TellomiMotion.emphasis, reduceMotion: false), TellomiMotion.emphasis)
    }

    /// 动画器必须能在动画中被触摸接管（可打断）。
    @MainActor
    func testAnimatorIsInterruptibleAndTakesTouches() {
        let animator = TellomiMotion.animator(TellomiMotion.move, reduceMotion: false)
        XCTAssertTrue(animator.isInterruptible)
        XCTAssertTrue(animator.isUserInteractionEnabled)
    }

    /// 松手速度换算成「每秒走完剩余路程的比例」；剩余路程几乎为零的轴取 0。
    func testRelativeVelocity() {
        let velocity = TellomiMotion.relativeVelocity(CGPoint(x: 100, y: -300), remaining: CGVector(dx: 50, dy: 0.2))
        XCTAssertEqual(velocity.dx, 2)
        XCTAssertEqual(velocity.dy, 0)
    }

    // MARK: - 固定时长弹簧（回应条照 Telegram，交互审计 A-06）

    /// 换成质量 1 之后，整段弹簧正好在指定时长里稳定下来。
    func testFixedDurationSpringSettlesInItsDuration() {
        for spring in [TellomiMotion.reactionItemAppear, TellomiMotion.reactionBarScaleIn, TellomiMotion.reactionBarWiden] {
            XCTAssertEqual(spring.animation(keyPath: "transform.scale").duration, spring.duration, accuracy: 0.005)
        }
        XCTAssertEqual(TellomiMotion.reactionItemAppear.duration, 0.4)
        XCTAssertEqual(TellomiMotion.reactionBarScaleIn.duration, 0.3)
        XCTAssertEqual(TellomiMotion.reactionBarWiden.duration, 0.5)
    }

    /// 压缩时间不改变弹簧的性格：阻尼 88 ≈ 0.66（回弹约 7%），104 ≈ 0.78（约 2%）。
    func testFixedDurationSpringKeepsTheDampingRatio() {
        XCTAssertEqual(TellomiMotion.reactionItemAppear.dampingRatio, 0.656, accuracy: 0.001)
        XCTAssertEqual(TellomiMotion.reactionBarWiden.dampingRatio, 0.775, accuracy: 0.001)
        let spring = TellomiMotion.reactionItemAppear
        XCTAssertEqual(spring.damping / (2 * spring.stiffness.squareRoot()), spring.dampingRatio, accuracy: 1e-9)
    }
}
