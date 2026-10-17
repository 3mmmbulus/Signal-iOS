//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit
import XCTest

@testable import Signal

/// Tellomi（M9 发送动画）：飞的几何（照 Telegram 两端）、数（和 Android 同一组）、等不到就不飞并收干净。
@MainActor
final class TellomiSendFlightTests: XCTestCase {

    private let fromBox = CGRect(x: 60, y: 760, width: 300, height: 40)
    private let fromText = CGPoint(x: 72, y: 769)
    private let toBody = CGRect(x: 250, y: 600, width: 130, height: 38)
    private let toText = CGPoint(x: 262, y: 609)

    private func frame(_ t: Double, textScaleFrom: CGFloat = 1) -> TellomiSendFlight.Frame {
        TellomiSendFlight.frame(at: t, fromBox: fromBox, fromText: fromText, textScaleFrom: textScaleFrom, toBody: toBody, toText: toText)
    }

    // MARK: - 数

    /// 时长是 owner 选的 280 ms；曲线、淡入照 Telegram 两端；和 Android `TellomiMotion.SendFlight` 同一组。
    func testTheNumbersMatchAndroid() {
        XCTAssertEqual(TellomiMotion.SendFlight.duration, 0.28)
        XCTAssertEqual(TellomiMotion.SendFlight.bubbleFadeIn, 0.12)
        XCTAssertEqual(TellomiMotion.SendFlight.horizontalCurve, TellomiMotion.CubicBezier(0.23, 1, 0.32, 1))
        XCTAssertEqual(TellomiMotion.SendFlight.verticalCurve, TellomiMotion.CubicBezier(0.19919, 0.01064, 0.27921, 0.91025))
        XCTAssertEqual(TellomiMotion.SendFlight.waitForRow, 0.6)
        XCTAssertEqual(TellomiMotion.SendFlight.cancelFade, 0.15)
    }

    func testCubicBezierHitsItsEndsAndKnownPoints() {
        let ease = TellomiMotion.CubicBezier(0.25, 0.1, 0.25, 1)
        XCTAssertEqual(ease.value(at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(ease.value(at: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(ease.value(at: 0.5), 0.8024, accuracy: 0.001, "CSS `ease` at half time")
        let linear = TellomiMotion.CubicBezier(0, 0, 1, 1)
        XCTAssertEqual(linear.value(at: 0.3), 0.3, accuracy: 1e-4)
        var previous = -1.0
        for step in 0...20 {
            let value = TellomiMotion.SendFlight.verticalCurve.value(at: Double(step) / 20)
            XCTAssertGreaterThanOrEqual(value, previous, "never goes back")
            previous = value
        }
    }

    // MARK: - 几何

    func testTheFirstFrameIsTheInputFieldAndTheLastOneIsTheBubble() {
        let first = frame(0, textScaleFrom: 0.8)
        XCTAssertEqual(first.body, fromBox)
        XCTAssertEqual(first.textOrigin, fromText)
        XCTAssertEqual(first.scale, 0.8)
        XCTAssertEqual(first.bubbleAlpha, 0)

        let last = frame(1, textScaleFrom: 0.8)
        XCTAssertEqual(last.body.minX, toBody.minX, accuracy: 1e-6)
        XCTAssertEqual(last.body.maxY, toBody.maxY, accuracy: 1e-6)
        XCTAssertEqual(last.body.size.width, toBody.size.width, accuracy: 1e-6)
        XCTAssertEqual(last.textOrigin.x, toText.x, accuracy: 1e-6)
        XCTAssertEqual(last.textOrigin.y, toText.y, accuracy: 1e-6)
        XCTAssertEqual(last.scale, 1, accuracy: 1e-6)
        XCTAssertEqual(last.bubbleAlpha, 1)
    }

    func testTheFillAndTailAreOpaqueAfter120Of280ms() {
        XCTAssertEqual(frame(0.06 / 0.28).bubbleAlpha, 0.5, accuracy: 0.001)
        XCTAssertEqual(frame(0.12 / 0.28).bubbleAlpha, 1)
        XCTAssertEqual(frame(0.8).bubbleAlpha, 1)
    }

    /// 横向前快、纵向跟列表：同一时刻横向走得比纵向远，所以是一道弧线（Telegram 两端都是这样）。
    func testSidewaysRunsAheadOfUpwardsSoThePathIsAnArc() {
        for t in [0.1, 0.2, 0.3, 0.5, 0.7] {
            let origin = frame(t).textOrigin
            let sideways = (origin.x - fromText.x) / (toText.x - fromText.x)
            let upwards = (origin.y - fromText.y) / (toText.y - fromText.y)
            XCTAssertGreaterThan(sideways, upwards, "t=\(t)")
        }
    }

    /// 气泡框的左右边跟横向进度、上下边跟纵向进度：输入框的框一路变成气泡。
    func testTheBoxTurnsIntoTheBubbleEdgeByEdge() {
        let middle = frame(0.3)
        let sideways = (middle.body.minX - fromBox.minX) / (toBody.minX - fromBox.minX)
        let upwards = (middle.body.minY - fromBox.minY) / (toBody.minY - fromBox.minY)
        XCTAssertEqual((middle.body.maxX - fromBox.maxX) / (toBody.maxX - fromBox.maxX), sideways, accuracy: 1e-6)
        XCTAssertEqual((middle.body.maxY - fromBox.maxY) / (toBody.maxY - fromBox.maxY), upwards, accuracy: 1e-6)
        XCTAssertGreaterThan(sideways, upwards)
    }

    // MARK: - 等不到就不飞

    /// 新的一条一直没进列表：输入框的快照原地淡掉，窗口上那一层收掉，输入框回到不透明，只收尾一次。
    func testNothingToFlyTo_theSnapshotFadesWhereItWasAndEverythingIsPutBack() {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        defer { window.isHidden = true }
        let windowSubviewsBefore = window.subviews.count

        let snapshot = UILabel()
        snapshot.text = "hello"
        let source = TellomiSendFlight.Source(
            textSnapshot: snapshot,
            textSnapshotFrame: CGRect(x: 72, y: 769, width: 200, height: 22),
            textOrigin: CGPoint(x: 72, y: 769),
            fontSize: 17,
            box: fromBox,
        )
        var fieldAlphas = [CGFloat]()
        var finished = 0
        var revealed = 0
        let finishedExpectation = expectation(description: "finished")
        let flight = TellomiSendFlight(
            messageTimestamp: 1234,
            source: source,
            window: window,
            findTarget: { _ in nil },
            makeContent: { _ in nil },
            onChange: { fieldAlphas.append($0.fieldAlpha) },
            onReveal: { _, _ in revealed += 1 },
            onFinish: { _ in
                finished += 1
                finishedExpectation.fulfill()
            },
        )
        XCTAssertEqual(flight.phase, .waiting)
        XCTAssertEqual(flight.fieldAlpha, 0, "the field is clear while waiting")
        XCTAssertEqual(window.subviews.count, windowSubviewsBefore + 1, "one overlay on the window")
        XCTAssertTrue(flight.isHoldingRow(interactionUniqueId: "x") == false, "nothing claimed yet")
        flight.claim(interactionUniqueId: "x")
        XCTAssertTrue(flight.isHoldingRow(interactionUniqueId: "x"))

        wait(for: [finishedExpectation], timeout: TellomiMotion.SendFlight.waitForRow + TellomiMotion.SendFlight.cancelFade + 1)

        XCTAssertEqual(finished, 1)
        XCTAssertEqual(revealed, 2, "put back when it gave up waiting, and again (harmless) when it finished")
        XCTAssertEqual(flight.phase, .done)
        XCTAssertEqual(fieldAlphas.last, 1)
        XCTAssertEqual(window.subviews.count, windowSubviewsBefore, "the overlay is gone")
        XCTAssertFalse(flight.isHoldingRow(interactionUniqueId: "x"))
    }

    /// 页面要走：不淡，马上收掉。
    func testCancellingImmediatelyRemovesTheOverlayAtOnce() {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        defer { window.isHidden = true }
        let windowSubviewsBefore = window.subviews.count
        var finished = 0
        let flight = TellomiSendFlight(
            messageTimestamp: 1,
            source: TellomiSendFlight.Source(textSnapshot: UIView(), textSnapshotFrame: .zero, textOrigin: .zero, fontSize: 17, box: fromBox),
            window: window,
            findTarget: { _ in nil },
            makeContent: { _ in nil },
            onChange: { _ in },
            onReveal: { _, _ in },
            onFinish: { _ in finished += 1 },
        )
        flight.cancelImmediately()
        XCTAssertEqual(flight.phase, .done)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(flight.fieldAlpha, 1)
        XCTAssertEqual(window.subviews.count, windowSubviewsBefore)
        flight.cancel()
        XCTAssertEqual(finished, 1, "only once")
    }
}
