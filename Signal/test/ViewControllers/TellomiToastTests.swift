//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 交互审计 A-30（iOS 半边）：提示条拖着跟手、按投射落点滑走或弹回；可撤销的左边倒计时。
final class TellomiToastTests: SignalBaseTest {

    // MARK: - 跟手

    func testDragFollowsTheFingerAndResistsLeavingItsEdge() {
        let sideways = TellomiToastDrag.displayedOffset(translation: CGPoint(x: -80, y: 0), towardEdgeSign: 1)
        XCTAssertEqual(sideways, CGPoint(x: -80, y: 0), "横着 1:1")

        let down = TellomiToastDrag.displayedOffset(translation: CGPoint(x: 0, y: 30), towardEdgeSign: 1)
        XCTAssertEqual(down.y, 30, "贴底边：往下 1:1")

        let up = TellomiToastDrag.displayedOffset(translation: CGPoint(x: 0, y: -200), towardEdgeSign: 1)
        XCTAssertLessThan(up.y, 0)
        XCTAssertGreaterThan(up.y, -TellomiToastDrag.rubberBandLimit, "往上拖不动，最多 24 pt")

        let topEdgeUp = TellomiToastDrag.displayedOffset(translation: CGPoint(x: 0, y: -30), towardEdgeSign: -1)
        XCTAssertEqual(topEdgeUp.y, -30, "贴顶边：往上才是走的方向")
    }

    func testReleaseUsesTheProjectedLandingPoint() {
        let size = CGSize(width: 300, height: 52)

        XCTAssertEqual(TellomiToastDrag.outcome(translation: CGPoint(x: 40, y: 0), velocity: .zero, size: size, towardEdgeSign: 1), .stay, "拖一点、慢慢放：弹回")
        XCTAssertEqual(
            TellomiToastDrag.outcome(translation: CGPoint(x: 40, y: 0), velocity: CGPoint(x: 1200, y: 0), size: size, towardEdgeSign: 1),
            .dismissHorizontally(sign: 1),
            "拖得不远但甩得快：40 + 1200 × 0.1 = 160 > 300 × 0.35，滑走",
        )
        XCTAssertEqual(TellomiToastDrag.outcome(translation: CGPoint(x: -120, y: 0), velocity: .zero, size: size, towardEdgeSign: 1), .dismissHorizontally(sign: -1), "拖过 35% 慢慢放：也滑走")
        XCTAssertEqual(TellomiToastDrag.outcome(translation: CGPoint(x: 0, y: 10), velocity: CGPoint(x: 0, y: 400), size: size, towardEdgeSign: 1), .dismissTowardEdge, "往底边甩：滑下去")
        XCTAssertEqual(TellomiToastDrag.outcome(translation: CGPoint(x: 0, y: -20), velocity: CGPoint(x: 0, y: -800), size: size, towardEdgeSign: 1), .stay, "往上甩不算")
    }

    // MARK: - 倒计时

    func testCountdownShowsWholeSecondsLeft() {
        XCTAssertEqual(TellomiToastCountdownView.displayedSeconds(remaining: 5), 5)
        XCTAssertEqual(TellomiToastCountdownView.displayedSeconds(remaining: 4.2), 5)
        XCTAssertEqual(TellomiToastCountdownView.displayedSeconds(remaining: 4), 4)
        XCTAssertEqual(TellomiToastCountdownView.displayedSeconds(remaining: 0.4), 1, "最后一秒显示 1")
        XCTAssertEqual(TellomiToastCountdownView.displayedSeconds(remaining: 0), 0)
        XCTAssertEqual(DispatchTimeInterval.milliseconds(2500).tellomiSeconds, 2.5)
    }

    @MainActor
    func testUndoToastCountsDownAndPlainToastDoesNot() throws {
        let host = try makeHost()
        defer { host.window.isHidden = true }

        let undo = ToastController(text: "Chat archived")
        undo.tellomiAction = (title: "Undo", handler: {})
        undo.presentToastView(from: .bottom, of: host.root.view, inset: 8, dismissAfter: .seconds(5))
        let undoView = try XCTUnwrap(host.root.view.subviews.compactMap { $0 as? ToastView }.last)
        let countdown = try XCTUnwrap(undoView.tellomiCountdownView, "可撤销的左边有倒计时")
        XCTAssertEqual(countdown.labelTextForTesting, "5")
        XCTAssertEqual(countdown.ringAnimationForTesting?.duration ?? 0, 5, accuracy: 0.001, "环和提示条停的时长一样")
        undo.dismissToastView()

        let plain = ToastController(text: "Copied")
        plain.presentToastView(from: .bottom, of: host.root.view, inset: 8)
        let plainView = try XCTUnwrap(host.root.view.subviews.compactMap { $0 as? ToastView }.last)
        XCTAssertNil(plainView.tellomiCountdownView, "普通提示没有倒计时")
    }

    // MARK: - 松手

    @MainActor
    func testReleasingShortSpringsBackAndFlingingRemovesIt() throws {
        let host = try makeHost()
        defer { host.window.isHidden = true }

        let controller = ToastController(text: "Copied")
        controller.presentToastView(from: .bottom, of: host.root.view, inset: 8)
        let toast = try XCTUnwrap(host.root.view.subviews.compactMap { $0 as? ToastView }.last)
        host.root.view.layoutIfNeeded()

        toast.tellomiDragChanged(translation: CGPoint(x: 50, y: 0))
        XCTAssertEqual(toast.transform.tx, 50, "跟着手指")
        toast.tellomiDragEnded(translation: CGPoint(x: 50, y: 0), velocity: .zero, reduceMotion: false)
        XCTAssertEqual(toast.transform, .identity, "弹回原位（动画的终值已经写上）")
        XCTAssertNotNil(toast.superview)

        toast.tellomiDragChanged(translation: CGPoint(x: 60, y: 0))
        toast.tellomiDragEnded(translation: CGPoint(x: 60, y: 0), velocity: CGPoint(x: 1500, y: 0), reduceMotion: false)
        XCTAssertGreaterThan(toast.transform.tx, host.root.view.bounds.size.width * 0.5, "接着往右飞出去")
        let gone = expectation(description: "飞完拿掉")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            XCTAssertNil(toast.superview)
            gone.fulfill()
        }
        wait(for: [gone], timeout: 3)
    }

    @MainActor
    func testTimeRunningOutWhileDraggingWaitsForTheFinger() throws {
        let host = try makeHost()
        defer { host.window.isHidden = true }

        let controller = ToastController(text: "Copied")
        controller.presentToastView(from: .bottom, of: host.root.view, inset: 8)
        let toast = try XCTUnwrap(host.root.view.subviews.compactMap { $0 as? ToastView }.last)

        toast.tellomiIsDragging = true
        controller.dismissToastView()
        XCTAssertNotNil(toast.superview, "手指还拖着：先不收")
        XCTAssertTrue(toast.tellomiDismissWhenReleased)
        XCTAssertTrue(toast.gestureRecognizers?.allSatisfy(\.isEnabled) ?? false, "还能接着拖")
    }

    // MARK: - 截图（只在 TELLOMI_SHOTS=1 时截）

    /// 可撤销的提示条：左边倒计时环、右边「撤销」；拖到一半的样子。
    @MainActor
    func testUndoToastScreenshots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        let host = try makeHost()
        defer { host.window.isHidden = true }
        let controller = ToastController(text: "Chat archived")
        controller.tellomiAction = (title: "Undo", handler: {})
        controller.presentToastView(from: .bottom, of: host.root.view, inset: host.root.view.safeAreaInsets.bottom + 8, dismissAfter: .seconds(5))
        let toast = try XCTUnwrap(host.root.view.subviews.compactMap { $0 as? ToastView }.last)

        try await Task.sleep(nanoseconds: 1_300_000_000)
        try save(host.window, "toast-undo-countdown.png")

        toast.tellomiIsDragging = true
        toast.tellomiDragChanged(translation: CGPoint(x: 110, y: 14))
        try save(host.window, "toast-undo-dragged.png")
        toast.tellomiIsDragging = false
    }

    // MARK: -

    private struct Host {
        let window: UIWindow
        let root: UIViewController
    }

    @MainActor
    private func makeHost() throws -> Host {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let root = UIViewController()
        root.view.backgroundColor = .systemBackground
        window.rootViewController = root
        window.isHidden = false
        root.view.layoutIfNeeded()
        return Host(window: window, root: root)
    }

    @MainActor
    private func save(_ window: UIWindow, _ name: String) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("402")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }
}
