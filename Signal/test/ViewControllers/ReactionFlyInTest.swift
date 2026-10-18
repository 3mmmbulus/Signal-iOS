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

    /// 回应条上 32 pt 的表情飞到胶囊里 14 pt 的表情：缩到 14 / 32，不留回弹（Telegram 落地不回弹）。
    func testLandingScaleShrinksToThePill() {
        XCTAssertEqual(ReactionFlyIn.landingScale(sourceFontSize: 32, targetFontSize: 14), 14.0 / 32.0, accuracy: 1e-9)
        XCTAssertEqual(ReactionFlyIn.landingScale(sourceFontSize: 0, targetFontSize: 14), 1)
    }

    // MARK: - 时间（Telegram iOS `ReactionContextNode.animateOutToReaction` 的数）

    /// 飞 0.2 s、往上拱 30 pt；0.15 s 起爆开；落地后 0.1 s 给触感。
    func testFlightUsesTelegramsTimings() {
        XCTAssertEqual(ReactionFlyIn.flightDuration, 0.2)
        XCTAssertEqual(ReactionFlyIn.flightElevation, 30)
        XCTAssertEqual(ReactionFlyIn.burstDelay, 0.15)
        XCTAssertEqual(ReactionFlyIn.landingHapticDelay, 0.1)
    }

    // MARK: - 落点

    /// 落点只认「我」的那一格：别人已经用同一个表情回应过时，菜单刚收起那一刻那一格还不是我这次的回应，认了它真表情会先露出来。
    func testOnlyTheLocalUsersPillIsALandingSpot() {
        XCTAssertTrue(CVReactionCountsView.isFlyInTarget(.emoji(emoji: "❤️", count: 2, fromLocalUser: true), emoji: "❤️"))
        XCTAssertFalse(CVReactionCountsView.isFlyInTarget(.emoji(emoji: "❤️", count: 1, fromLocalUser: false), emoji: "❤️"))
        XCTAssertFalse(CVReactionCountsView.isFlyInTarget(.emoji(emoji: "👍", count: 1, fromLocalUser: true), emoji: "❤️"))
        XCTAssertFalse(CVReactionCountsView.isFlyInTarget(nil, emoji: "❤️"))
    }

    // MARK: - 路线形状（Telegram 的抛物线）

    /// 过起点、（横向中点，起点往上 30）、落点；横向匀速；最后正好落在目标上。
    func testPathIsTelegramsParabola() {
        let source = CGPoint(x: 100, y: 300)
        let target = CGPoint(x: 260, y: 420)
        XCTAssertEqual(ReactionFlyIn.flightPosition(from: source, to: target, progress: 0), source)
        XCTAssertEqual(ReactionFlyIn.flightPosition(from: source, to: target, progress: 1), target)
        XCTAssertEqual(ReactionFlyIn.flightPosition(from: source, to: target, progress: 0.5), CGPoint(x: 180, y: 270))
        XCTAssertEqual(ReactionFlyIn.flightPosition(from: source, to: target, progress: 0.25).x, 140, accuracy: 1e-9)
        // 同一条抛物线（按横坐标）上的另一点：y = a x² + b x + c 过那三点。
        let quarter = ReactionFlyIn.flightPosition(from: source, to: target, progress: 0.25)
        XCTAssertEqual(quarter.y, parabolaY(atX: quarter.x, through: [source, CGPoint(x: 180, y: 270), target]), accuracy: 1e-6)
    }

    /// 落点在正下方：照样先往上拱再落下（Telegram 的公式这时除以零，这里按时间插值有定义）。
    func testStraightDropStillRisesFirst() {
        let source = CGPoint(x: 100, y: 300)
        let target = CGPoint(x: 100, y: 450)
        let highest = stride(from: 0.0, through: 1.0, by: 0.01)
            .map { ReactionFlyIn.flightPosition(from: source, to: target, progress: CGFloat($0)).y }
            .min() ?? source.y
        XCTAssertLessThan(highest, source.y - 30)
        XCTAssertEqual(ReactionFlyIn.flightPosition(from: source, to: target, progress: 1), target)
    }

    /// 起点和落点挨得很近：走直线，不拱（Telegram 同一个 5 pt 门槛）。
    func testNearbyTargetFliesStraight() {
        let source = CGPoint(x: 100, y: 300)
        let target = CGPoint(x: 103, y: 304)
        let middle = ReactionFlyIn.flightPosition(from: source, to: target, progress: 0.5)
        XCTAssertEqual(middle.x, 101.5, accuracy: 1e-9)
        XCTAssertEqual(middle.y, 302, accuracy: 1e-9)
    }

    // MARK: - 收尾（叠在窗口上的那一层一定要收走）

    /// 调用方起飞后就放掉引用、飞行又拖过了 2 s 等待上限——那一层仍然要收走，落点的字要放回来，对象也要释放。
    /// （走查模拟器上抓到过：收尾时对象已经没了，那一层一直悬在窗口上。）
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

    /// 过三点的抛物线在 [x] 处的值（拉格朗日插值）。
    private func parabolaY(atX x: CGFloat, through points: [CGPoint]) -> CGFloat {
        let (p0, p1, p2) = (points[0], points[1], points[2])
        let l0 = (x - p1.x) * (x - p2.x) / ((p0.x - p1.x) * (p0.x - p2.x))
        let l1 = (x - p0.x) * (x - p2.x) / ((p1.x - p0.x) * (p1.x - p2.x))
        let l2 = (x - p0.x) * (x - p1.x) / ((p2.x - p0.x) * (p2.x - p1.x))
        return p0.y * l0 + p1.y * l1 + p2.y * l2
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
        XCTAssertEqual(ReactionFlyIn.burstDelay, ReactionFlyIn.flightDuration * 0.75, accuracy: 1e-9)
        XCTAssertLessThan(ReactionFlyIn.burstDelay, ReactionFlyIn.flightDuration)
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
