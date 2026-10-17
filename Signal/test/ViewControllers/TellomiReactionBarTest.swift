//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalUI
import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（交互审计 A-06 / A-07，owner 2026-10-17）：长按消息的回应条照 Telegram 两端的样子和数。
@MainActor
final class TellomiReactionBarTest: SignalBaseTest {

    private let signalDefaults = ["❤️", "👍", "👎", "😂", "😮", "😢"]

    // MARK: - 第 7 个表情

    /// 用户的 6 个原样在前（会同步，不能改），第 7 个是显示时补的。
    func testSavedSetStaysFirstAndUntouched() {
        let custom = ["🔥", "👍", "👎", "😂", "😮", "🙏"]
        let slots = TellomiReactionBarSlots.make(saved: custom, selected: nil, signalDefaults: signalDefaults, recents: [])
        XCTAssertEqual(slots.count, 7)
        XCTAssertEqual(Array(slots.prefix(6)), custom)
    }

    /// 我已经回应、但不在那 6 个里的表情排第 7（不显示就没法点它撤回）。
    func testSelectedEmojiOutsideTheSetTakesTheSeventhSlot() {
        let slots = TellomiReactionBarSlots.make(saved: signalDefaults, selected: "🤔", signalDefaults: signalDefaults, recents: ["😍"])
        XCTAssertEqual(slots.last, "🤔")
    }

    /// 已经在那 6 个里的回应不重复占位。
    func testSelectedEmojiInsideTheSetIsNotRepeated() {
        let slots = TellomiReactionBarSlots.make(saved: signalDefaults, selected: "😂", signalDefaults: signalDefaults, recents: ["😍"])
        XCTAssertEqual(slots, signalDefaults + ["😍"])
    }

    /// 用户换掉了一个 Signal 默认表情：第 7 个先用回那个默认的。
    func testReplacedSignalDefaultComesBackSeventh() {
        let custom = ["❤️", "👍", "👎", "😂", "😮", "🔥"]
        let slots = TellomiReactionBarSlots.make(saved: custom, selected: nil, signalDefaults: signalDefaults, recents: ["😍"])
        XCTAssertEqual(slots.last, "😢")
    }

    /// 默认的 6 个都在：用最近用过的；也没有就用固定候补的第一个。
    func testRecentThenFallback() {
        XCTAssertEqual(
            TellomiReactionBarSlots.make(saved: signalDefaults, selected: nil, signalDefaults: signalDefaults, recents: ["❤️", "😍"]).last,
            "😍",
        )
        XCTAssertEqual(
            TellomiReactionBarSlots.make(saved: signalDefaults, selected: nil, signalDefaults: signalDefaults, recents: []).last,
            "🔥",
        )
    }

    // MARK: - 尺寸

    /// 6.1 寸屏：8 格（7 表情 + 展开键）× 36、间距 8、两头 6 = 356。
    func testFullSizeBarOnA390PointScreen() {
        let layout = TellomiReactionBarLayout(availableWidth: 390)
        XCTAssertEqual(layout.itemSize, 36)
        XCTAssertEqual(layout.slotCount, 8)
        XCTAssertEqual(layout.width, 356)
    }

    /// 屏幕放不下 36 的 8 格时缩小条目，8 格都留着。
    func testNarrowScreensShrinkItemsAndKeepEightSlots() {
        let mini = TellomiReactionBarLayout(availableWidth: 375)
        XCTAssertEqual(mini.itemSize, 35)
        XCTAssertEqual(mini.slotCount, 8)
        XCTAssertEqual(mini.width, 348)

        let se = TellomiReactionBarLayout(availableWidth: 320)
        XCTAssertEqual(se.itemSize, 28)
        XCTAssertEqual(se.slotCount, 8)
        XCTAssertEqual(se.width, 292)
    }

    /// 宽屏（iPad、横屏）也最多 8 格，不拉长。
    func testWideScreensStayAtEightSlots() {
        let layout = TellomiReactionBarLayout(availableWidth: 1024)
        XCTAssertEqual(layout.itemSize, 36)
        XCTAssertEqual(layout.width, 356)
    }

    /// 条高 46，条目上下各留 5；展开键 30、离末端 9，和第 8 格同一个中心。
    func testItemAndExpandButtonFrames() {
        let layout = TellomiReactionBarLayout(availableWidth: 390)
        XCTAssertEqual(layout.itemFrame(at: 0, isRTL: false), CGRect(x: 6, y: 5, width: 36, height: 36))
        XCTAssertEqual(layout.itemFrame(at: 6, isRTL: false), CGRect(x: 270, y: 5, width: 36, height: 36))
        let expand = layout.expandButtonFrame(isRTL: false)
        XCTAssertEqual(expand, CGRect(x: 317, y: 8, width: 30, height: 30))
        XCTAssertEqual(expand.midX, layout.itemFrame(at: 7, isRTL: false).midX)
    }

    /// 从右往左的语言：第一个表情在最右，展开键在最左。
    func testRightToLeftMirrorsTheOrder() {
        let layout = TellomiReactionBarLayout(availableWidth: 390)
        XCTAssertEqual(layout.itemFrame(at: 0, isRTL: true), CGRect(x: 314, y: 5, width: 36, height: 36))
        XCTAssertEqual(layout.expandButtonFrame(isRTL: true).minX, 9)
    }

    // MARK: - 尾巴

    /// 消息在左半边：大圆（16）圆心骑在条下沿、横向在消息右上角往里 4 pt；小圆（8）在它右下 2 pt。
    func testTailHangsOffTheOuterCornerOfALeftMessage() {
        let bar = CGRect(x: 17, y: 100, width: 356, height: 46)
        let message = CGRect(x: 16, y: 153, width: 120, height: 40)
        let tail = TellomiReactionBarLayout.tailFrames(barFrame: bar, messageFrame: message, containerWidth: 390)
        XCTAssertEqual(tail.large, CGRect(x: 124, y: 138, width: 16, height: 16))
        XCTAssertEqual(tail.small, CGRect(x: 137, y: 156, width: 8, height: 8))
    }

    /// 消息在右半边：大圆横向在消息左边缘，小圆在它左下。
    func testTailHangsOffTheOuterCornerOfARightMessage() {
        let bar = CGRect(x: 17, y: 100, width: 356, height: 46)
        let message = CGRect(x: 250, y: 153, width: 124, height: 40)
        let tail = TellomiReactionBarLayout.tailFrames(barFrame: bar, messageFrame: message, containerWidth: 390)
        XCTAssertEqual(tail.large, CGRect(x: 242, y: 138, width: 16, height: 16))
        XCTAssertEqual(tail.small, CGRect(x: 237, y: 156, width: 8, height: 8))
    }

    /// 消息比条还靠外（长消息贴着屏幕边）：尾巴不出条的两头。
    func testTailStaysInsideTheBarEnds() {
        let bar = CGRect(x: 17, y: 100, width: 356, height: 46)
        let message = CGRect(x: 8, y: 153, width: 380, height: 40)
        let tail = TellomiReactionBarLayout.tailFrames(barFrame: bar, messageFrame: message, containerWidth: 400)
        XCTAssertEqual(tail.large.midX, bar.maxX - 23)
    }

    // MARK: - 出现

    /// 底板从消息那一头 46 宽的圆长出来，夹在条里。
    func testGrowthOriginSitsAtTheMessageEnd() {
        let bar = CGRect(x: 17, y: 100, width: 356, height: 46)
        let leftMessage = CGRect(x: 16, y: 153, width: 120, height: 40)
        XCTAssertEqual(
            TellomiReactionBarLayout.growthOriginFrame(barFrame: bar, messageFrame: leftMessage, containerWidth: 390),
            CGRect(x: 95, y: 0, width: 46, height: 46),
        )
        let rightMessage = CGRect(x: 30, y: 153, width: 344, height: 40)
        XCTAssertEqual(
            TellomiReactionBarLayout.growthOriginFrame(barFrame: bar, messageFrame: rightMessage, containerWidth: 390),
            CGRect(x: 0, y: 0, width: 46, height: 46),
        )
    }

    /// 错峰：0.01 + 距离 / 条宽 × 0.3。
    func testAppearDelayGrowsWithDistanceFromTheOrigin() {
        XCTAssertEqual(TellomiReactionBarLayout.appearDelay(itemMidX: 24, originMinX: 24, barWidth: 356), 0.01, accuracy: 1e-9)
        XCTAssertEqual(TellomiReactionBarLayout.appearDelay(itemMidX: 356, originMinX: 0, barWidth: 356), 0.31, accuracy: 1e-9)
        XCTAssertEqual(TellomiReactionBarLayout.appearDelay(itemMidX: 0, originMinX: 178, barWidth: 356), 0.16, accuracy: 1e-9)
    }

    /// 按住滑到的那一格放大 2 倍，下沿比原位置低 4 pt。
    func testFocusedItemDoublesAndDropsItsBottomEdgeBy4() {
        let layout = TellomiReactionBarLayout(availableWidth: 390)
        let transform = layout.focusedTransform()
        XCTAssertEqual(transform.a, 2)
        XCTAssertEqual(transform.d, 2)
        let item = layout.itemFrame(at: 0, isRTL: false)
        let focusedBottom = item.midY + transform.ty + item.size.height * 2 / 2
        XCTAssertEqual(focusedBottom, item.maxY + 4, accuracy: 1e-9)
    }

    // MARK: - 真的摆在长按菜单里

    /// 回应条附件：7 个表情 + 展开键，46 高，摆在消息上方 7 pt；横向放不下时夹在离屏幕边 17 pt 以内。
    func testAccessoryPlacesTheBarAboveTheMessage() throws {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.isHidden = false
        // 右边一条短消息：条按 Telegram 从消息左边缘往外 26 pt 摆，会伸出屏幕，要夹回来，而不是把消息预览缩小去让它。
        let message = UIView(frame: CGRect(x: 290, y: 400, width: 84, height: 36))
        message.backgroundColor = .systemBlue
        root.view.addSubview(message)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let thread = TSContactThread(contactAddress: SignalServiceAddress(Aci.randomForTesting()))
        let accessory = ContextMenuReactionBarAccessory(thread: thread, itemViewModel: nil)
        let bar = try XCTUnwrap(accessory.accessoryView as? TellomiReactionBar)
        XCTAssertEqual(bar.currentEmojiSet().count, 7)
        XCTAssertEqual(Array(bar.currentEmojiSet().prefix(6)), ReactionManager.defaultEmojiSet)

        let delegate = BarMenuDelegate(accessory: accessory)
        let interaction = ContextMenuInteraction(delegate: delegate)
        message.addInteraction(interaction)
        interaction.initiateContextMenuGesture(locationInView: CGPoint(x: 20, y: 20), presentImmediately: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))

        let host = try XCTUnwrap(bar.superview)
        XCTAssertTrue(
            host.subviews.contains { $0 !== bar && $0.frame == message.frame },
            "消息预览原大原位，没有为回应条缩小",
        )
        XCTAssertEqual(bar.frame.size.height, 46)
        XCTAssertEqual(bar.frame.size.width, 356)
        XCTAssertEqual(bar.frame.maxY, message.frame.minY - 7, accuracy: 0.5)
        // 消息左边缘 − 26 会让条伸出屏幕，夹回离右边 17 pt。
        XCTAssertEqual(bar.frame.minX, 390 - 17 - 356, accuracy: 0.5)
        XCTAssertFalse(bar.isHidden)

        interaction.dismissMenu(animated: false) {}
        window.isHidden = true
    }
}

// MARK: - 原地展开（交互审计 A-06）

@MainActor
final class TellomiReactionBarExpansionTest: SignalBaseTest {

    private var window: UIWindow!
    private var message: UIView!
    private var accessory: ContextMenuReactionBarAccessory!
    private var interaction: ContextMenuInteraction!
    private var delegate: BarMenuDelegate!

    override func setUp() {
        super.setUp()
        window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let root = UIViewController()
        root.view.backgroundColor = .white
        window.rootViewController = root
        window.isHidden = false
        message = UIView(frame: CGRect(x: 290, y: 500, width: 84, height: 36))
        message.backgroundColor = .systemBlue
        root.view.addSubview(message)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        let thread = TSContactThread(contactAddress: SignalServiceAddress(Aci.randomForTesting()))
        accessory = ContextMenuReactionBarAccessory(thread: thread, itemViewModel: nil)
        delegate = BarMenuDelegate(accessory: accessory)
        interaction = ContextMenuInteraction(delegate: delegate)
        message.addInteraction(interaction)
        interaction.initiateContextMenuGesture(locationInView: CGPoint(x: 20, y: 20), presentImmediately: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))
    }

    override func tearDown() {
        interaction.dismissMenu(animated: false) {}
        window.isHidden = true
        window = nil
        super.tearDown()
    }

    private var bar: TellomiReactionBar { accessory.accessoryView as! TellomiReactionBar }
    private var host: UIView { bar.superview! }
    private var preview: UIView? {
        host.subviews.first { $0 !== bar && $0.frame.size == message.frame.size }
    }

    /// 手指往下 1 pt，内容往下 0.35 pt；往上不算；手指拉过约 86 pt 才到 30。
    func testPullUsesTelegramsResistance() {
        XCTAssertEqual(ContextMenuController.pulledDistance(fingerTranslation: 100), 35, accuracy: 1e-9)
        XCTAssertEqual(ContextMenuController.pulledDistance(fingerTranslation: -50), 0)
        XCTAssertLessThan(ContextMenuController.pulledDistance(fingerTranslation: 85), ContextMenuController.pullToExpandThreshold)
        XCTAssertGreaterThan(ContextMenuController.pulledDistance(fingerTranslation: 86), ContextMenuController.pullToExpandThreshold)
    }

    /// 往下拉：消息预览和菜单跟着往下，回应条不动（它自己往下长）。
    func testPullMovesTheMessageButNotTheBar() throws {
        let controller = try XCTUnwrap(interaction.contextMenuController)
        let barFrame = bar.frame
        let previewFrame = try XCTUnwrap(preview).frame
        controller.setPullDistance(20, animated: false)
        XCTAssertEqual(bar.frame, barFrame)
        XCTAssertEqual(try XCTUnwrap(preview).frame.minY, previewFrame.minY + 20, accuracy: 0.5)
        controller.setPullDistance(0, animated: false)
        XCTAssertEqual(try XCTUnwrap(preview).frame.minY, previewFrame.minY, accuracy: 0.5)
    }

    /// 点 ⌄：条就地长成 300 高的面板、上沿往上提 96，消息原大接在面板下面 7 pt，菜单藏起来、点不到。
    func testExpandButtonGrowsTheBarIntoThePanel() throws {
        let collapsedTop = bar.frame.minY
        let menu = try XCTUnwrap(interaction.contextMenuController?.menuAccessory?.accessoryView)
        accessory.didSelectShowFullEmojiPicker()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))

        XCTAssertTrue(bar.isExpanded)
        XCTAssertTrue(accessory.isExpandedInPlace)
        XCTAssertEqual(bar.frame.size.height, 300)
        XCTAssertEqual(bar.frame.minY, collapsedTop - 96, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(preview).frame.minY, bar.frame.maxY + 7, accuracy: 0.5)
        XCTAssertEqual(menu.alpha, 0)
        XCTAssertFalse(menu.isUserInteractionEnabled)
        XCTAssertNotNil(bar.subviews.first { $0 is TellomiReactionPanel })
    }

    /// 面板里搜索、键盘起来：面板让到键盘上面（离键盘 8 pt），放不下就变矮。
    func testExpandedPanelMovesAboveTheKeyboard() throws {
        accessory.didSelectShowFullEmojiPicker()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1))

        let keyboardHeight: CGFloat = 336
        let keyboardFrame = CGRect(x: 0, y: window.bounds.size.height - keyboardHeight, width: window.bounds.size.width, height: keyboardHeight)
        NotificationCenter.default.post(
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: window.convert(keyboardFrame, to: window.screen.coordinateSpace)),
                UIResponder.keyboardAnimationDurationUserInfoKey: NSNumber(value: 0.25),
            ],
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        XCTAssertLessThanOrEqual(bar.frame.maxY, keyboardFrame.minY - 8 + 0.5)
        XCTAssertGreaterThanOrEqual(bar.frame.minY, host.safeAreaInsets.top - 0.5)
    }
}

private final class BarMenuDelegate: ContextMenuInteractionDelegate {
    let accessory: ContextMenuTargetedPreviewAccessory

    init(accessory: ContextMenuTargetedPreviewAccessory) {
        self.accessory = accessory
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> ContextMenuConfiguration? {
        ContextMenuConfiguration(identifier: nil, forceDarkTheme: false) { _ in
            ContextMenu([ContextMenuAction(title: "Reply", handler: { _ in })])
        }
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, previewForHighlightingMenuWithConfiguration configuration: ContextMenuConfiguration) -> ContextMenuTargetedPreview? {
        guard let view = interaction.view else { return nil }
        return ContextMenuTargetedPreview(view: view, alignment: .right, accessoryViews: [accessory])
    }

    func contextMenuInteraction(_ interaction: ContextMenuInteraction, willDisplayMenuForConfiguration: ContextMenuConfiguration) {}
    func contextMenuInteraction(_ interaction: ContextMenuInteraction, willEndForConfiguration: ContextMenuConfiguration) {}
    func contextMenuInteraction(_ interaction: ContextMenuInteraction, didEndForConfiguration: ContextMenuConfiguration) {}
}
