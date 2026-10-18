//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit
import XCTest

@testable import Signal

/// Tellomi（交互审计 A-07 起飞时机）：选了回应以后，菜单收起期间聊天列表就落了这条回应，真消息可能挪了位置、换了格子。
/// 菜单的预览要飞向它此刻的气泡，回应区快照跟着气泡走；收起照常在约 0.25 s 收尾——不提前、只收一次，路线上不跳。
@MainActor
final class TellomiContextMenuRetargetTests: SignalBaseTest {

    private var window: UIWindow!
    private var message: UIView!
    private var reactions: UIView?
    private var interaction: ContextMenuInteraction!
    private var delegate: RetargetMenuDelegate!

    override func tearDown() {
        interaction?.dismissMenu(animated: false) {}
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    /// 收起途中真消息换到了上面 44 pt 的新格子：预览落到新格子的气泡上，收起照常收一次，路线上不跳。
    func testDismissalFollowsTheMessageToItsNewCell() throws {
        let controller = try presentMenu()
        let preview = try XCTUnwrap(controller.previewView)
        let movedCell = makeMovedCell(dy: -44)

        var completions = 0
        var completedAfter: CFTimeInterval = 0
        let start = CACurrentMediaTime()
        interaction.dismissMenu(animated: true) {
            completions += 1
            completedAfter = CACurrentMediaTime() - start
        }
        spin(0.06)
        controller.tellomiRetargetDismissal(previewTo: movedCell)

        var samples: [CGFloat] = []
        let deadline = Date().addingTimeInterval(1)
        while completions == 0, Date() < deadline {
            samples.append((preview.layer.presentation() ?? preview.layer).frame.minY)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
        }
        spin(0.3)

        XCTAssertEqual(completions, 1, "收起只收一次")
        XCTAssertGreaterThan(completedAfter, 0.2, "叠上去的那段不能让收起提前收尾")
        XCTAssertLessThan(completedAfter, 0.5)
        let target = controller.view.convert(movedCell.frame, from: movedCell.superview)
        XCTAssertEqual(preview.frame.minY, target.minY, accuracy: 0.5, "落在新格子上")
        XCTAssertGreaterThan(samples.count, 5)
        let biggestStep = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertLessThan(biggestStep, 30, "一路过去，不跳")
    }

    /// 菜单还没开始收（回应条还在淡出）就落了 load：收起一开始就飞向新格子；还没收时预览不动。
    func testRetargetBeforeTheDismissalIsUsedWhenItStarts() throws {
        let controller = try presentMenu()
        let preview = try XCTUnwrap(controller.previewView)
        let before = preview.frame
        let movedCell = makeMovedCell(dy: 30)

        controller.tellomiRetargetDismissal(previewTo: movedCell)
        XCTAssertEqual(preview.frame, before, "还没收：预览不动")

        var completions = 0
        interaction.dismissMenu(animated: true) { completions += 1 }
        waitUntil(1) { completions > 0 }

        XCTAssertEqual(completions, 1)
        let target = controller.view.convert(movedCell.frame, from: movedCell.superview)
        XCTAssertEqual(preview.frame.minY, target.minY, accuracy: 0.5)
    }

    /// 回应区快照跟着气泡走：和气泡的相对位置照长按那一刻，大小不变。
    func testReactionsSnapshotKeepsItsPlaceUnderTheBubble() throws {
        let controller = try presentMenu(withReactions: true)
        let auxiliary = try XCTUnwrap(controller.auxiliaryPreviewView)
        let reactions = try XCTUnwrap(reactions)
        let offset = CGPoint(x: reactions.frame.minX - message.frame.minX, y: reactions.frame.minY - message.frame.minY)
        let movedCell = makeMovedCell(dy: -44)

        var completions = 0
        interaction.dismissMenu(animated: true) { completions += 1 }
        spin(0.06)
        controller.tellomiRetargetDismissal(previewTo: movedCell)
        waitUntil(1) { completions > 0 }

        let target = controller.view.convert(movedCell.frame, from: movedCell.superview)
        XCTAssertEqual(auxiliary.frame.minX, target.minX + offset.x, accuracy: 0.5)
        XCTAssertEqual(auxiliary.frame.minY, target.minY + offset.y, accuracy: 0.5)
        XCTAssertEqual(auxiliary.frame.size, reactions.frame.size)
    }

    /// 很长的消息在菜单里缩小过：落到新格子时放回原大，不留着缩小后的大小。会话页是先定落点、再收菜单（胶囊画出来那一刻
    /// 两件事一起做），所以这里也先定落点。
    func testShrunkPreviewLandsAtFullSize() throws {
        let controller = try presentMenu(messageFrame: CGRect(x: 230, y: 12, width: 140, height: 820))
        let preview = try XCTUnwrap(controller.previewView)
        try XCTSkipUnless(preview.frame.size.height < message.frame.size.height - 1, "这个窗口里菜单没有缩小预览")
        let movedCell = makeMovedCell(dy: 0)

        controller.tellomiRetargetDismissal(previewTo: movedCell)
        var completions = 0
        interaction.dismissMenu(animated: true) { completions += 1 }
        waitUntil(1) { completions > 0 }

        XCTAssertEqual(preview.frame.size.width, message.frame.size.width, accuracy: 0.5)
        XCTAssertEqual(preview.frame.size.height, message.frame.size.height, accuracy: 0.5)
    }

    /// 新格子不在视图树里（已经被回收）：不改，照原来的位置收。
    func testATargetThatLeftTheScreenIsIgnored() throws {
        let controller = try presentMenu()
        let preview = try XCTUnwrap(controller.previewView)
        let gone = UIView(frame: message.frame.offsetBy(dx: 0, dy: 100))

        var completions = 0
        interaction.dismissMenu(animated: true) { completions += 1 }
        spin(0.06)
        controller.tellomiRetargetDismissal(previewTo: gone)
        waitUntil(1) { completions > 0 }

        XCTAssertEqual(completions, 1)
        let source = controller.view.convert(message.frame, from: message.superview)
        XCTAssertEqual(preview.frame.minY, source.minY, accuracy: 0.5)
    }

    // MARK: -

    /// 窗口里一条消息（可选：下面挂着回应区），长按弹出菜单。
    private func presentMenu(
        messageFrame: CGRect = CGRect(x: 230, y: 420, width: 140, height: 40),
        withReactions: Bool = false,
    ) throws -> ContextMenuController {
        window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.isHidden = false
        message = UIView(frame: messageFrame)
        message.backgroundColor = .systemBlue
        root.view.addSubview(message)
        if withReactions {
            let reactions = UIView(frame: CGRect(x: messageFrame.minX + 6, y: messageFrame.maxY - 6, width: 60, height: 28))
            reactions.backgroundColor = .systemGray
            root.view.addSubview(reactions)
            self.reactions = reactions
        }
        window.layoutIfNeeded()
        spin(0.2)

        delegate = RetargetMenuDelegate(reactions: reactions)
        interaction = ContextMenuInteraction(delegate: delegate)
        message.addInteraction(interaction)
        interaction.initiateContextMenuGesture(locationInView: CGPoint(x: 20, y: 20), presentImmediately: true)
        spin(1)
        return try XCTUnwrap(interaction.contextMenuController)
    }

    /// 聊天列表给这条消息的新格子：气泡和原来一样大，藏着（会话页在菜单收完前藏着它）。
    private func makeMovedCell(dy: CGFloat) -> UIView {
        let moved = UIView(frame: message.frame.offsetBy(dx: 0, dy: dy))
        moved.isHidden = true
        message.superview?.addSubview(moved)
        return moved
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

private final class RetargetMenuDelegate: ContextMenuInteractionDelegate {
    private weak var reactions: UIView?

    init(reactions: UIView?) {
        self.reactions = reactions
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> ContextMenuConfiguration? {
        ContextMenuConfiguration(identifier: nil, forceDarkTheme: false) { _ in
            ContextMenu([ContextMenuAction(title: "Reply", handler: { _ in })])
        }
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: ContextMenuConfiguration) -> ContextMenuTargetedPreview? {
        guard let view = interaction.view else { return nil }
        let preview = ContextMenuTargetedPreview(view: view, alignment: .right, accessoryViews: nil)
        preview?.auxiliaryView = reactions
        return preview
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, willDisplayMenuForConfiguration: ContextMenuConfiguration) {}
    func contextMenuInteraction(_ interaction: ContextMenuInteraction, willEndForConfiguration: ContextMenuConfiguration) {}
    func contextMenuInteraction(_ interaction: ContextMenuInteraction, didEndForConfiguration: ContextMenuConfiguration) {}
}
