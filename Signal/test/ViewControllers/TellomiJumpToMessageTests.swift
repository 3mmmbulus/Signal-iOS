//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalUI

/// 交互审计 A-08（iOS 半边）：跳到某条消息怎么滚、跳完的高亮、滚到底按钮记住的来处。
@MainActor
final class TellomiJumpToMessageTests: XCTestCase {

    // MARK: - 怎么滚

    func testNearJumpsSlideAndFarJumpsStopOneScreenAway() {
        XCTAssertNil(TellomiJumpScroll.prepositionY(currentY: 2000, targetY: 1400, viewportHeight: 700), "一屏以内：直接滑过去")
        XCTAssertNil(TellomiJumpScroll.prepositionY(currentY: 2000, targetY: 1300, viewportHeight: 700), "正好一屏也不瞬移")
        XCTAssertEqual(TellomiJumpScroll.prepositionY(currentY: 5000, targetY: 1000, viewportHeight: 700), 1700, "往上跳：先停在目标下面一屏")
        XCTAssertEqual(TellomiJumpScroll.prepositionY(currentY: 0, targetY: 3000, viewportHeight: 700), 2300, "往下跳：先停在目标上面一屏")
        XCTAssertNil(TellomiJumpScroll.prepositionY(currentY: 0, targetY: 3000, viewportHeight: 0))
    }

    func testTheSlideIsTheScrollSpringWithoutOvershoot() {
        XCTAssertEqual(TellomiJumpScroll.progress(elapsed: 0), 0)
        var previous: CGFloat = 0
        for step in 1...60 {
            let progress = TellomiJumpScroll.progress(elapsed: Double(step) / 60)
            XCTAssertGreaterThanOrEqual(progress, previous, "一路往前，不回头")
            XCTAssertLessThanOrEqual(progress, 1, "不冲过头（滚动位置不回弹）")
            previous = progress
        }
        // 感知时长 0.45 s 时走完约 98.6%
        XCTAssertEqual(TellomiJumpScroll.progress(elapsed: TellomiMotion.scroll.duration), 0.986, accuracy: 0.001)
        // 一整屏（800 pt）在保险时长之内就落到终点
        let settleTime = (1...200).map { Double($0) / 100 }.first { (1 - TellomiJumpScroll.progress(elapsed: $0)) * 800 < TellomiJumpScroll.settleDistance }
        XCTAssertLessThan(settleTime ?? .infinity, TellomiJumpScroll.maxDuration)
    }

    func testAnimatorLandsOnTheTarget() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        scrollView.contentSize = CGSize(width: 390, height: 5000)
        scrollView.contentOffset.y = 2000
        let animator = TellomiJumpScrollAnimator()
        let done = expectation(description: "落到终点")

        animator.animate(scrollView, toY: 1300) { finished in
            XCTAssertTrue(finished)
            done.fulfill()
        }
        XCTAssertTrue(animator.isAnimating)

        wait(for: [done], timeout: 3)
        XCTAssertEqual(scrollView.contentOffset.y, 1300, accuracy: 0.001)
        XCTAssertFalse(animator.isAnimating)
    }

    func testANewJumpReplacesTheOldOneWithoutCallingItBack() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        scrollView.contentSize = CGSize(width: 390, height: 5000)
        let animator = TellomiJumpScrollAnimator()
        let oldOne = expectation(description: "旧的不回调")
        oldOne.isInverted = true
        let newOne = expectation(description: "新的落到终点")

        animator.animate(scrollView, toY: 600) { _ in oldOne.fulfill() }
        animator.animate(scrollView, toY: 300) { _ in newOne.fulfill() }

        wait(for: [newOne, oldOne], timeout: 3)
        XCTAssertEqual(scrollView.contentOffset.y, 300, accuracy: 0.001)
    }

    func testTargetsPastTheEndAreClamped() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        scrollView.contentSize = CGSize(width: 390, height: 1000)
        let animator = TellomiJumpScrollAnimator()
        let done = expectation(description: "落到能滚到的最下面")

        animator.animate(scrollView, toY: 900) { _ in done.fulfill() }

        wait(for: [done], timeout: 3)
        XCTAssertEqual(scrollView.contentOffset.y, 200, accuracy: 0.001)
    }

    // MARK: - 高亮

    func testHighlightFadesInHoldsAndEasesOut() {
        let animation = TellomiJumpHighlight.dimmerAnimation()
        XCTAssertEqual(animation.keyPath, "opacity")
        XCTAssertEqual(animation.values as? [Float], [0, 1, 1, 0])
        XCTAssertEqual(animation.duration, 1.2, accuracy: 0.0001, "淡入 0.2 + 停 0.7 + 淡出 0.3")
        let keyTimes = animation.keyTimes?.map(\.doubleValue) ?? []
        XCTAssertEqual(keyTimes.count, 4)
        XCTAssertEqual(keyTimes[1], 0.2 / 1.2, accuracy: 0.0001)
        XCTAssertEqual(keyTimes[2], 0.9 / 1.2, accuracy: 0.0001)
        XCTAssertEqual(animation.timingFunctions?.last, CAMediaTimingFunction(name: .easeOut), "ease-out 淡出")

        let content = TellomiJumpHighlight.contentDimAnimation()
        XCTAssertEqual(content.values as? [Float], [1, TellomiJumpHighlight.contentDimmedOpacity, TellomiJumpHighlight.contentDimmedOpacity, 1], "没气泡的整条压暗再恢复")
    }

    func testBubbleHighlightAddsATemporaryDimmer() {
        let bubble = CVColorOrGradientView()
        bubble.frame = CGRect(x: 0, y: 0, width: 200, height: 60)
        bubble.dimmerColor = .ows_blackAlpha25
        let before = bubble.layer.sublayers?.count ?? 0

        bubble.tellomiPerformJumpHighlight()

        let sublayers = bubble.layer.sublayers ?? []
        XCTAssertEqual(sublayers.count, before + 1)
        let dimmer = try? XCTUnwrap(sublayers.first { $0.animation(forKey: TellomiJumpHighlight.animationKey) != nil })
        XCTAssertNotNil(dimmer)
        XCTAssertEqual(dimmer?.opacity, 0, "动画播完是透明的（之后拿掉）")
        XCTAssertEqual(dimmer?.frame, bubble.layer.bounds)
    }

    // MARK: - 滚到底按钮记住来处

    func testBackStackIsLastInFirstOut() {
        var stack = TellomiJumpBackStack()
        stack.push(.init(interactionId: "a", sortId: 10))
        stack.push(.init(interactionId: "b", sortId: 30))
        stack.push(.init(interactionId: "a", sortId: 10))

        XCTAssertEqual(stack.entries.map(\.interactionId), ["b", "a"], "同一条只记一次，放到最上面")
        XCTAssertEqual(stack.popLast()?.interactionId, "a")
        XCTAssertEqual(stack.popLast()?.interactionId, "b")
        XCTAssertNil(stack.popLast())
        XCTAssertTrue(stack.isEmpty)
    }

    func testScrollingPastASourceForgetsIt() {
        var stack = TellomiJumpBackStack()
        stack.push(.init(interactionId: "older", sortId: 10))
        stack.push(.init(interactionId: "newer", sortId: 30))

        stack.removeEntries(upTo: 20)
        XCTAssertEqual(stack.entries.map(\.interactionId), ["newer"], "滚过了 10 那条：不记了，30 那条还在下面")

        stack.removeEntries(upTo: 30)
        XCTAssertTrue(stack.isEmpty, "滚到那条本身也算到了")
    }

    func testAPendingSourceExpires() {
        let start = Date()
        let pending = TellomiPendingJumpSource(entry: .init(interactionId: "a", sortId: 1), date: start)
        XCTAssertTrue(pending.isValid(now: start.addingTimeInterval(1)))
        XCTAssertFalse(pending.isValid(now: start.addingTimeInterval(TellomiPendingJumpSource.lifetime)), "点了引用但没跳（找不到原消息）：过一会就不算了")
    }
}
