//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（交互审计 A-06 iOS 余项）：长按菜单的选项在收起开始时就执行；收起途中再要一次不带动画的收起（选项推了新页面，
/// 聊天页 `viewWillDisappear`）时就地收尾，`didEnd` 只报一次。
@MainActor
final class TellomiContextMenuActionTimingTest: SignalBaseTest {

    private var window: UIWindow!
    private var sourceView: UIView!
    private var baselineWindowSubviewCount = 0

    override func setUp() {
        super.setUp()
        window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.isHidden = false
        sourceView = UIView(frame: CGRect(x: 40, y: 300, width: 220, height: 60))
        sourceView.backgroundColor = .systemBlue
        root.view.addSubview(sourceView)
        window.layoutIfNeeded()
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        sourceView = nil
        super.tearDown()
    }

    private func presentMenu(delegate: FakeContextMenuDelegate) -> (ContextMenuInteraction, ContextMenuActionsAccessory) {
        // 菜单用 snapshotView(afterScreenUpdates: false) 截预览：源视图得先真的画过一帧，否则截不到。
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let interaction = ContextMenuInteraction(delegate: delegate)
        sourceView.addInteraction(interaction)
        baselineWindowSubviewCount = window.subviews.count
        interaction.initiateContextMenuGesture(locationInView: CGPoint(x: 20, y: 20), presentImmediately: true)
        XCTAssertEqual(window.subviews.count, baselineWindowSubviewCount + 1, "菜单挂到窗口上了")
        let configuration = delegate.configuration
        let preview = ContextMenuTargetedPreview(view: sourceView, alignment: .center, accessoryViews: nil)!
        let accessory = interaction.menuAccessory(configuration: configuration, targetedPreview: preview)
        return (interaction, accessory)
    }

    private func wait(seconds: TimeInterval) {
        let done = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 2)
    }

    func testTheActionRunsWhenTheMenuStartsToCollapse() {
        let delegate = FakeContextMenuDelegate()
        let (_, accessory) = presentMenu(delegate: delegate)
        XCTAssertEqual(delegate.willDisplayCount, 1)

        accessory.contextMenuActionViewDidSelectAction(contextMenuAction: delegate.action)

        XCTAssertEqual(delegate.actionRunCount, 1, "选了就执行，不等收起动画")
        XCTAssertEqual(delegate.willEndCount, 1)
        XCTAssertEqual(delegate.didEndCount, 0, "收起还在播")

        wait(seconds: 0.8)
        XCTAssertEqual(delegate.actionRunCount, 1)
        XCTAssertEqual(delegate.didEndCount, 1, "收完报一次")
    }

    func testAnImmediateDismissalDuringTheCollapseFinishesItOnce() {
        let delegate = FakeContextMenuDelegate()
        let (interaction, accessory) = presentMenu(delegate: delegate)

        accessory.contextMenuActionViewDidSelectAction(contextMenuAction: delegate.action)
        var immediateCompletionCount = 0
        interaction.dismissMenu(animated: false) { immediateCompletionCount += 1 }

        XCTAssertEqual(delegate.didEndCount, 1, "就地收尾")
        XCTAssertEqual(immediateCompletionCount, 1)
        XCTAssertEqual(window.subviews.count, baselineWindowSubviewCount, "菜单的视图已经拿掉")

        wait(seconds: 0.8)
        XCTAssertEqual(delegate.didEndCount, 1, "动画播完不再报第二次")
        XCTAssertEqual(delegate.willEndCount, 1)
        XCTAssertFalse(sourceView.isHidden)
    }

    func testASecondAnimatedDismissalWaitsForTheFirst() {
        let delegate = FakeContextMenuDelegate()
        let (interaction, accessory) = presentMenu(delegate: delegate)

        accessory.contextMenuActionViewDidSelectAction(contextMenuAction: delegate.action)
        var secondCompletionCount = 0
        interaction.dismissMenu(animated: true) { secondCompletionCount += 1 }
        XCTAssertEqual(delegate.willEndCount, 1, "不重新开始收起")
        XCTAssertEqual(secondCompletionCount, 0)

        wait(seconds: 0.8)
        XCTAssertEqual(delegate.didEndCount, 1)
        XCTAssertEqual(secondCompletionCount, 1, "跟着第一次一起收尾")
    }

    // MARK: - 按压（交互审计 A-06，照 Telegram）

    /// 按住时缩到「宽度 − 15 pt」，最小 0.7。
    func testPressedScaleTakesFifteenPointsOffTheWidth() {
        XCTAssertEqual(ContextMenuInteraction.pressedScale(forWidth: 300), 0.95, accuracy: 1e-9)
        XCTAssertEqual(ContextMenuInteraction.pressedScale(forWidth: 150), 0.9, accuracy: 1e-9)
        XCTAssertEqual(ContextMenuInteraction.pressedScale(forWidth: 40), 0.7, accuracy: 1e-9)
        XCTAssertEqual(ContextMenuInteraction.pressedScale(forWidth: 0), 1)
    }

    /// 长按识别（0.2 s）之后 0.12 s 缩完就弹菜单：按下后 0.32 s，和 Telegram 的激活时刻一样（原来 0.4 s）。
    func testMenuOpensWhenTheShrinkEnds() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "减弱动态效果时不缩、直接弹")
        XCTAssertEqual(0.2 + ContextMenuInteraction.pressShrinkDuration, 0.32, accuracy: 1e-9)

        let delegate = FakeContextMenuDelegate()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let interaction = ContextMenuInteraction(delegate: delegate)
        sourceView.addInteraction(interaction)
        let before = window.subviews.count
        interaction.initiateContextMenuGesture(locationInView: CGPoint(x: 20, y: 20), presentImmediately: false)
        XCTAssertEqual(sourceView.transform.a, ContextMenuInteraction.pressedScale(forWidth: 220), accuracy: 1e-6, "缩到的目标比例")
        XCTAssertEqual(window.subviews.count, before, "还在缩")
        wait(seconds: ContextMenuInteraction.pressShrinkDuration + 0.15)
        XCTAssertEqual(window.subviews.count, before + 1, "缩完弹出")
        interaction.dismissMenu(animated: false) {}
    }

    // MARK: - 键盘不动（交互审计 A-06，Q-05 = A）

    func testKeyboardOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        XCTAssertEqual(ContextMenuController.keyboardOverlap(keyboardFrame: CGRect(x: 0, y: 508, width: 390, height: 336), in: bounds), 336)
        XCTAssertEqual(ContextMenuController.keyboardOverlap(keyboardFrame: CGRect(x: 0, y: 844, width: 390, height: 336), in: bounds), 0, "落到屏幕外")
        XCTAssertEqual(ContextMenuController.keyboardOverlap(keyboardFrame: .zero, in: bounds), 0)
    }

    /// 键盘开着长按底部的消息：键盘不收，消息预览和菜单都挪到键盘上面 8 pt 以内。
    func testMenuFitsAboveAKeyboardThatStaysUp() {
        sourceView.frame = CGRect(x: 40, y: 700, width: 220, height: 60)
        let keyboardFrame = CGRect(x: 0, y: 508, width: 390, height: 336)
        let delegate = FakeContextMenuDelegate()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let interaction = KeyboardContextMenuInteraction(delegate: delegate, keyboardFrame: keyboardFrame)
        sourceView.addInteraction(interaction)
        interaction.initiateContextMenuGesture(locationInView: CGPoint(x: 20, y: 20), presentImmediately: true)
        wait(seconds: 0.8)

        let host = window.subviews.last!
        let content = host.subviews.filter { !$0.isHidden && $0.alpha > 0 && $0.frame.size.width < host.bounds.size.width }
        XCTAssertFalse(content.isEmpty)
        for view in content {
            XCTAssertLessThanOrEqual(view.frame.maxY, keyboardFrame.minY - 8 + 0.5, "\(type(of: view)) 在键盘上面")
        }
        interaction.dismissMenu(animated: false) {}
    }
}

/// 弹出时报告一块键盘。
private final class KeyboardContextMenuInteraction: ContextMenuInteraction {
    private let keyboardFrame: CGRect

    init(delegate: ContextMenuInteractionDelegate, keyboardFrame: CGRect) {
        self.keyboardFrame = keyboardFrame
        super.init(delegate: delegate)
    }

    override func keyboardFrameInWindowAtPresentation() -> CGRect? {
        keyboardFrame
    }
}

// MARK: -

private final class FakeContextMenuDelegate: ContextMenuInteractionDelegate {
    var actionRunCount = 0
    var willDisplayCount = 0
    var willEndCount = 0
    var didEndCount = 0

    lazy var action = ContextMenuAction(title: "Copy") { [weak self] _ in
        self?.actionRunCount += 1
    }

    lazy var configuration = ContextMenuConfiguration(identifier: nil) { [weak self] _ in
        guard let self else { return nil }
        return ContextMenu([self.action])
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> ContextMenuConfiguration? {
        configuration
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: ContextMenuConfiguration) -> ContextMenuTargetedPreview? {
        nil
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, willDisplayMenuForConfiguration: ContextMenuConfiguration) {
        willDisplayCount += 1
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, willEndForConfiguration: ContextMenuConfiguration) {
        willEndCount += 1
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, didEndForConfiguration: ContextMenuConfiguration) {
        didEndCount += 1
    }
}
