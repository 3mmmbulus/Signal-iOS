//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit
import XCTest

@testable import Signal

@MainActor
final class ReactionFlyInTest: XCTestCase {

    // MARK: - 读屏公告（A-07）

    /// 加回应念「已回应」加表情，收回念「已取消回应」（测试跑英文界面）。
    func testVoiceOverAnnouncementSaysWhatTheReactionDid() {
        XCTAssertEqual(ConversationViewController.tellomiReactionAnnouncement(emoji: "❤️", isRemoving: false), "Reacted with ❤️")
        XCTAssertEqual(ConversationViewController.tellomiReactionAnnouncement(emoji: "👍", isRemoving: true), "Reaction removed")
    }

    // MARK: - 缩放

    /// 回应条上 32 pt 的表情飞到胶囊里 14 pt 的表情：先缩到 14 / 32，再多留 1.25 倍给落定的回弹。
    func testLandingScaleShrinksToThePillAndLeavesRoomForTheBounce() {
        XCTAssertEqual(ReactionFlyIn.landingScale(sourceFontSize: 32, targetFontSize: 14), 14.0 / 32.0 * 1.25, accuracy: 1e-9)
        XCTAssertEqual(ReactionFlyIn.landingScale(sourceFontSize: 0, targetFontSize: 14), 1)
    }

    // MARK: - 纵向初速

    /// 目标在下方且足够远：向上抛（相对速度为负）。
    func testTossesUpwardWhenTheTargetIsBelow() {
        let velocity = ReactionFlyIn.verticalInitialVelocity(verticalDistance: 200)
        XCTAssertEqual(velocity.dx, 0)
        XCTAssertEqual(velocity.dy, -ReactionFlyIn.tossSpeed / 200, accuracy: 1e-9)
    }

    /// 目标在上方或几乎平齐：不抛，免得冲过头或原地上下抖。
    func testDoesNotTossWhenTheTargetIsAboveOrLevel() {
        XCTAssertEqual(ReactionFlyIn.verticalInitialVelocity(verticalDistance: -150), .zero)
        XCTAssertEqual(ReactionFlyIn.verticalInitialVelocity(verticalDistance: 10), .zero)
    }

    // MARK: - 落点

    /// 落点只认「我」的那一格：别人已经用同一个表情回应过时，菜单刚收起那一刻那一格还不是我这次的回应，认了它真表情会先露出来。
    func testOnlyTheLocalUsersPillIsALandingSpot() {
        XCTAssertTrue(CVReactionCountsView.isFlyInTarget(.emoji(emoji: "❤️", count: 2, fromLocalUser: true), emoji: "❤️"))
        XCTAssertFalse(CVReactionCountsView.isFlyInTarget(.emoji(emoji: "❤️", count: 1, fromLocalUser: false), emoji: "❤️"))
        XCTAssertFalse(CVReactionCountsView.isFlyInTarget(.emoji(emoji: "👍", count: 1, fromLocalUser: true), emoji: "❤️"))
        XCTAssertFalse(CVReactionCountsView.isFlyInTarget(nil, emoji: "❤️"))
    }

    // MARK: - 路线形状（用真实的 Token 数值做弹簧积分）

    /// 横向偏开的落点：路线要明显弯（离直线最远处 ≥ 12 pt），最后落在目标上。
    func testPathArcsAndEndsOnTheTarget() {
        let path = simulatePath(dx: 160, dy: 120)
        XCTAssertGreaterThanOrEqual(path.maxDeviationFromStraightLine, 12)
        XCTAssertLessThan(hypot(path.end.x - 160, path.end.y - 120), 0.5)
    }

    /// 正下方的落点：先轻轻抬起一点（2–20 pt），不是原地一跳。
    func testStraightDropLiftsGentlyFirst() {
        let path = simulatePath(dx: 0, dy: 150)
        XCTAssertGreaterThanOrEqual(path.lift, 2)
        XCTAssertLessThanOrEqual(path.lift, 20)
    }

    // MARK: - 收尾（叠在窗口上的那一层一定要收走）

    /// 调用方起飞后就放掉引用、落定的回弹又拖过了 2 s 等待上限——那一层仍然要收走，落点的字要放回来，对象也要释放。
    /// （走查模拟器上抓到过：回弹收尾时对象已经没了，那一层一直悬在窗口上。）
    func testOverlayIsRemovedAfterLandingEvenIfTheCallerLetsGo() {
        let (window, target) = makeWindowWithTarget()
        let baseline = window.subviews.count
        var flyIn: ReactionFlyIn? = makeFlyIn(window: window)
        weak let weakFlyIn = flyIn
        XCTAssertEqual(window.subviews.count, baseline + 1)

        // 像真实流程一样过一会儿才找到落点：菜单收起、聊天列表落地要大约半秒到一秒。
        let found = expectation(description: "found target")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            flyIn?.claim(target)
            XCTAssertEqual(target.alpha, 0)
            flyIn?.land(on: target, targetFontSize: 14)
            flyIn = nil
            found.fulfill()
        }
        wait(for: [found], timeout: 3)

        waitUntil(timeout: 6) { window.subviews.count == baseline && weakFlyIn == nil }
        XCTAssertEqual(window.subviews.count, baseline)
        XCTAssertEqual(target.alpha, 1)
        XCTAssertNil(weakFlyIn)
    }

    /// 等不到落点：已经藏起来的落点放回来，那一层收走，对象释放。
    func testCancelRestoresTheClaimedTargetAndRemovesTheOverlay() {
        let (window, target) = makeWindowWithTarget()
        let baseline = window.subviews.count
        var flyIn: ReactionFlyIn? = makeFlyIn(window: window)
        weak let weakFlyIn = flyIn
        // UIKit 登记动画收尾闭包时会把对象放进当前的 autorelease pool；测试方法自己的 pool 要到方法结束才清，
        // 所以在这里单独包一层（App 里主线程每轮 runloop 都会清）。
        autoreleasepool {
            flyIn?.claim(target)
            flyIn?.cancel()
            flyIn = nil
        }

        waitUntil(timeout: 3) { window.subviews.count == baseline && weakFlyIn == nil }
        XCTAssertEqual(window.subviews.count, baseline)
        XCTAssertEqual(target.alpha, 1)
        XCTAssertNil(weakFlyIn)
    }

    // MARK: -

    private func makeWindowWithTarget() -> (UIWindow, UILabel) {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let target = UILabel(frame: CGRect(x: 200, y: 400, width: 20, height: 18))
        target.font = .boldSystemFont(ofSize: 14)
        target.text = "👍"
        window.addSubview(target)
        addTeardownBlock { window.isHidden = true }
        return (window, target)
    }

    private func makeFlyIn(window: UIWindow) -> ReactionFlyIn {
        ReactionFlyIn(
            messageUniqueId: "message",
            emoji: "👍",
            source: ReactionFlyIn.Source(frameInWindow: CGRect(x: 100, y: 300, width: 44, height: 44), fontSize: 32),
            window: window,
        )
    }

    /// 让主线程跑着（动画要靠它推进），直到条件成立或超时。
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    private struct Path {
        var maxDeviationFromStraightLine: CGFloat = 0
        var lift: CGFloat = 0
        var end: CGPoint = .zero
    }

    /// 起点在原点、目标在 (dx, dy)（y 向下）。弹簧和初速都取 [ReactionFlyIn] 里 land 用的那一份。
    private func simulatePath(dx: CGFloat, dy: CGFloat) -> Path {
        let horizontalSpring = ReactionFlyIn.horizontalSpring
        let verticalSpring = ReactionFlyIn.verticalSpring
        // UIKit 的相对初速 × 距离 = 点 / 秒。
        let verticalSpeed = ReactionFlyIn.verticalInitialVelocity(verticalDistance: dy).dy * dy

        var x = Axis(position: 0, velocity: 0, target: dx, spring: horizontalSpring)
        var y = Axis(position: 0, velocity: verticalSpeed, target: dy, spring: verticalSpring)
        var path = Path()
        let length = hypot(dx, dy)
        let step = 1.0 / 2000
        for _ in 0..<(2000 * 2) {
            x.advance(by: step)
            y.advance(by: step)
            if length > 0 {
                let deviation = abs(x.position * dy - y.position * dx) / length
                path.maxDeviationFromStraightLine = max(path.maxDeviationFromStraightLine, deviation)
            }
            path.lift = max(path.lift, -y.position)
        }
        path.end = CGPoint(x: x.position, y: y.position)
        return path
    }

    /// 质量 1 的阻尼弹簧，半隐式欧拉积分。
    private struct Axis {
        var position: CGFloat
        var velocity: CGFloat
        let target: CGFloat
        let spring: TellomiMotion.Spring

        mutating func advance(by dt: CGFloat) {
            let acceleration = -spring.stiffness * (position - target) - spring.damping * velocity
            velocity += acceleration * dt
            position += velocity * dt
        }
    }
}

/// Tellomi（交互审计 A-07，owner 2026-10-17）：回应落到胶囊上的「爆开」。
@MainActor
final class TellomiReactionBurstTest: XCTestCase {

    /// 十颗粒子：方向两两不同（黄金角错开），远近在表情字号 × 2.2 的 0.8–1.2 倍，大小 0.35–0.5，最多晚 0.04 s。
    func testParticlesSpreadDeterministically() {
        let particles = TellomiReactionBurst.particles(emojiSize: 14)
        XCTAssertEqual(particles.count, 10)
        XCTAssertEqual(particles, TellomiReactionBurst.particles(emojiSize: 14), "每次一样，录屏可复现")
        let reach = 14 * TellomiReactionBurst.reachFactor
        for particle in particles {
            XCTAssertGreaterThanOrEqual(particle.distance, reach * 0.8 - 1e-9)
            XCTAssertLessThanOrEqual(particle.distance, reach * 1.2 + 1e-9)
            XCTAssertGreaterThanOrEqual(particle.scale, 0.35)
            XCTAssertLessThanOrEqual(particle.scale, 0.5)
            XCTAssertLessThanOrEqual(particle.delay, 0.04 + 1e-9)
        }
        let directions = Set(particles.map { Int((atan2(sin($0.angle), cos($0.angle)) * 100).rounded()) })
        XCTAssertEqual(directions.count, particles.count)
    }

    /// 爆开在飞行的 75% 开始（Telegram iOS 0.15 / 0.2 s、Android 70%），整段 0.7 s 以内。
    func testBurstStartsBeforeTheEmojiLands() {
        XCTAssertEqual(ReactionFlyIn.burstDelay, ReactionFlyIn.verticalSpring.duration * 0.75, accuracy: 1e-9)
        XCTAssertLessThan(ReactionFlyIn.burstDelay, ReactionFlyIn.verticalSpring.duration)
        XCTAssertLessThanOrEqual(TellomiReactionBurst.duration, 0.7)
    }

    /// 播的时候窗口上多一层不挡触摸、不进读屏的视图，播完自己摘掉。
    func testBurstIsAPassiveOverlayThatRemovesItself() throws {
        try XCTSkipUnless(TellomiReactionBurst.shouldPlay, "减弱动态效果或低电量模式下不播")
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let before = window.subviews.count
        TellomiReactionBurst.play(emoji: "❤️", at: CGPoint(x: 200, y: 400), in: window, emojiSize: 14)
        XCTAssertEqual(window.subviews.count, before + 1)
        let overlay = try XCTUnwrap(window.subviews.last)
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        XCTAssertTrue(overlay.accessibilityElementsHidden)
        XCTAssertEqual(overlay.layer.sublayers?.count, 1 + TellomiReactionBurst.particleCount, "一个环 + 十颗粒子")

        let done = expectation(description: "burst finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + TellomiReactionBurst.duration + 0.2) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(window.subviews.count, before)
        window.isHidden = true
    }
}
