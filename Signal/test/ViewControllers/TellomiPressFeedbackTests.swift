//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalUI

/// 交互审计 A-09（iOS 半边）：可点的一块按下即缩、以手指为支点；松开 / 挪远 / 长按拿起时还原；减弱动态效果时只压暗。
@MainActor
final class TellomiPressFeedbackTests: XCTestCase {

    func testScalingKeepsTheFingerWhereItIs() {
        let bounds = CGRect(x: 0, y: 0, width: 240, height: 60)
        let pivot = CGPoint(x: 30, y: 50)
        let transform = TellomiPressFeedback.transform(scale: 0.97, pivot: pivot, bounds: bounds)

        // 视图的 transform 绕中心作用：手指相对中心的那一点缩完还在原处
        let offset = CGPoint(x: pivot.x - bounds.midX, y: pivot.y - bounds.midY)
        let moved = offset.applying(transform)
        XCTAssertEqual(moved.x, offset.x, accuracy: 0.001)
        XCTAssertEqual(moved.y, offset.y, accuracy: 0.001)
        // 别的点往手指那边收
        let corner = CGPoint(x: bounds.maxX - bounds.midX, y: bounds.maxY - bounds.midY).applying(transform)
        XCTAssertLessThan(corner.x, bounds.maxX - bounds.midX)
        XCTAssertEqual(transform.a, 0.97, accuracy: 0.0001)
    }

    func testPressScalesAndReleaseRestores() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let feedback = TellomiPressFeedback()

        feedback.press(.init(view: view, scale: TellomiPressFeedback.contentScale), at: CGPoint(x: 100, y: 30), pointInWindow: .zero, reduceMotion: false)
        XCTAssertTrue(feedback.isPressed)
        XCTAssertEqual(view.transform.a, TellomiPressFeedback.contentScale, accuracy: 0.0001, "按下即缩（动画的终值已经写上）")

        feedback.release(reduceMotion: false)
        XCTAssertFalse(feedback.isPressed)
        XCTAssertEqual(view.transform, .identity, "松开弹回")
    }

    func testMovingAwayReleasesButSmallJitterDoesNot() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let feedback = TellomiPressFeedback()
        feedback.press(.init(view: view, scale: TellomiPressFeedback.reactionScale), at: CGPoint(x: 20, y: 20), pointInWindow: CGPoint(x: 100, y: 100), reduceMotion: false)

        feedback.moved(toWindowPoint: CGPoint(x: 105, y: 104))
        XCTAssertTrue(feedback.isPressed, "手指抖一下不算拖")

        feedback.moved(toWindowPoint: CGPoint(x: 100, y: 120))
        XCTAssertFalse(feedback.isPressed, "挪出 10 pt 是在滚动 / 滑动回复：弹回")
        XCTAssertEqual(view.transform, .identity)
    }

    func testLongPressRestoresImmediately() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let feedback = TellomiPressFeedback()
        feedback.press(.init(view: view, scale: TellomiPressFeedback.contentScale), at: CGPoint(x: 10, y: 10), pointInWindow: .zero, reduceMotion: false)

        feedback.cancel(animated: false)
        XCTAssertFalse(feedback.isPressed)
        XCTAssertEqual(view.transform, .identity)
        XCTAssertNil(view.layer.animationKeys(), "不留动画：长按菜单的快照是原样")
    }

    func testReduceMotionDimsInsteadOfScaling() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 60))
        let feedback = TellomiPressFeedback()

        feedback.press(.init(view: view, scale: TellomiPressFeedback.contentScale), at: CGPoint(x: 10, y: 10), pointInWindow: .zero, reduceMotion: true)
        XCTAssertEqual(view.transform, .identity, "减弱动态效果：不缩")
        XCTAssertEqual(view.alpha, TellomiPressFeedback.reducedMotionAlpha, accuracy: 0.001)

        feedback.release(reduceMotion: true)
        XCTAssertEqual(view.alpha, 1, accuracy: 0.001)
    }

    func testPressingAnotherViewRestoresTheFirst() {
        let first = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        let second = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        let feedback = TellomiPressFeedback()
        feedback.press(.init(view: first, scale: TellomiPressFeedback.contentScale), at: .zero, pointInWindow: .zero, reduceMotion: false)

        feedback.press(.init(view: second, scale: TellomiPressFeedback.contentScale), at: .zero, pointInWindow: .zero, reduceMotion: false)

        XCTAssertEqual(first.transform, .identity)
        XCTAssertTrue(feedback.pressedView === second)
    }
}
