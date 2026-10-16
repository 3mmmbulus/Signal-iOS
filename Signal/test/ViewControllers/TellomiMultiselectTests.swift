//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalUI

/// 交互审计 A-15（iOS 半边）：双指拖选的「起点到手指下这一段」规则、靠边自动滚的速度、勾弹一下、进出多选时换栏。
@MainActor
final class TellomiMultiselectTests: XCTestCase {

    private let ids = ["m1", "m2", "m3", "m4", "m5", "m6"]

    /// 拿一张「现在每条选了什么」的表跑一次拖选：每一步都把返回的改动写回表里（会话页里就是写回 `CVSelectionState`）。
    private func drag(
        from anchor: String,
        through path: [String],
        initial: [String: CVSelectionType] = [:],
    ) -> (state: [String: CVSelectionType], changesPerStep: [[TellomiDragSelection.Change]]) {
        var state = initial
        var selection = TellomiDragSelection(anchorId: anchor, anchorType: state[anchor] ?? [])
        var changesPerStep = [[TellomiDragSelection.Change]]()
        for id in [anchor] + path {
            let changes = selection.update(orderedIds: ids, currentId: id, currentType: { state[$0] ?? [] })
            for change in changes {
                state[change.interactionId] = change.selectionType
            }
            changesPerStep.append(changes)
        }
        return (state, changesPerStep)
    }

    private func selected(_ state: [String: CVSelectionType]) -> [String] {
        ids.filter { state[$0] == .allContent }
    }

    func testDraggingFromAnUnselectedMessageSelectsTheWholeStretch() {
        let result = drag(from: "m2", through: ["m3", "m5"])

        XCTAssertEqual(selected(result.state), ["m2", "m3", "m4", "m5"], "手指跳过的 m4 也选上（起点到手指下这一段）")
        XCTAssertEqual(result.changesPerStep.first, [.init(interactionId: "m2", selectionType: .allContent)], "一开始起点就选上")
    }

    func testDraggingBackRestoresWhatWasThereBefore() {
        let result = drag(from: "m2", through: ["m5", "m3"], initial: ["m5": .allContent])

        XCTAssertEqual(selected(result.state), ["m2", "m3", "m5"], "拖回来：m4 恢复没选，m5 本来就选了、还是选着")
        XCTAssertNil(result.state["m4"].flatMap { $0.isEmpty ? nil : $0 })
    }

    func testDraggingPastTheAnchorFlipsDirection() {
        let result = drag(from: "m3", through: ["m5", "m1"])

        XCTAssertEqual(selected(result.state), ["m1", "m2", "m3"], "从下面拖到起点上面：下面那段恢复，上面那段选上")
    }

    func testDraggingFromASelectedMessageDeselects() {
        let initial: [String: CVSelectionType] = ["m2": .allContent, "m3": .allContent, "m4": .primaryContent]
        let result = drag(from: "m2", through: ["m4"], initial: initial)

        XCTAssertEqual(selected(result.state), [], "起点原来选了：一路取消，只选了附件的 m4 也取消")
        XCTAssertEqual(result.state["m4"], CVSelectionType.none)

        // 拖回起点：m3、m4 恢复成拖之前的样子（m4 只选附件）
        let back = drag(from: "m2", through: ["m4", "m2"], initial: initial)
        XCTAssertEqual(back.state["m3"], .allContent)
        XCTAssertEqual(back.state["m4"], .primaryContent)
        XCTAssertEqual(back.state["m2"], CVSelectionType.none, "起点本身一直是这次的状态")
    }

    func testAPartlySelectedAnchorCompletesTheSelection() {
        let selection = TellomiDragSelection(anchorId: "m1", anchorType: .secondaryContent)
        XCTAssertTrue(selection.selecting, "只选了文字的那条拖一下是补全，不是取消")
    }

    func testMessagesOutsideTheLoadedWindowAreLeftAlone() {
        var selection = TellomiDragSelection(anchorId: "m2", anchorType: .none)
        let changes = selection.update(orderedIds: ids, currentId: "gone", currentType: { _ in [] })
        XCTAssertEqual(changes, [])
    }

    // MARK: - 靠边自动滚

    func testAutoScrollOnlyNearTheEdges() {
        let top: CGFloat = 100
        let bottom: CGFloat = 700
        XCTAssertNil(TellomiDragSelectAutoScroll.step(y: 400, visibleTop: top, visibleBottom: bottom), "中间不滚")
        XCTAssertNil(TellomiDragSelectAutoScroll.step(y: top + 51, visibleTop: top, visibleBottom: bottom))

        let nearTop = TellomiDragSelectAutoScroll.step(y: top + 10, visibleTop: top, visibleBottom: bottom)
        let atTop = TellomiDragSelectAutoScroll.step(y: top - 40, visibleTop: top, visibleBottom: bottom)
        let nearBottom = TellomiDragSelectAutoScroll.step(y: bottom - 10, visibleTop: top, visibleBottom: bottom)
        XCTAssertLessThan(nearTop ?? 0, 0, "上边往上滚（更早的消息）")
        XCTAssertGreaterThan(nearBottom ?? 0, 0, "下边往下滚")
        XCTAssertEqual(nearTop ?? 0, -(nearBottom ?? 0), accuracy: 0.001, "上下对称")
        XCTAssertLessThan(atTop ?? 0, nearTop ?? 0, "越靠边越快")
        // 在顶栏上按离边 5 pt 算：15 × min(1, 0.15 + 0.9²) = 14.4
        XCTAssertEqual(atTop ?? 0, -14.4, accuracy: 0.001)
        // 刚进边缘区：最慢 15 × 0.15
        XCTAssertEqual(TellomiDragSelectAutoScroll.step(y: top + 49.999, visibleTop: top, visibleBottom: bottom) ?? 0, -2.25, accuracy: 0.01)
    }

    func testFingerOverTheBarsCountsAsTheEdgeMessage() {
        XCTAssertEqual(TellomiDragSelectAutoScroll.clampedY(20, visibleTop: 100, visibleBottom: 700), 105)
        XCTAssertEqual(TellomiDragSelectAutoScroll.clampedY(780, visibleTop: 100, visibleBottom: 700), 695)
        XCTAssertEqual(TellomiDragSelectAutoScroll.clampedY(300, visibleTop: 100, visibleBottom: 700), 300)
    }

    // MARK: - 勾弹一下

    func testCheckPopMatchesTelegram() {
        let select = TellomiCheckPop.animation(selected: true)
        XCTAssertEqual(select.keyPath, "transform.scale")
        XCTAssertEqual(select.values as? [CGFloat], [1, 0.9, 1.1, 1])
        XCTAssertEqual(select.duration, 0.31, accuracy: 0.0001)
        XCTAssertEqual(select.keyTimes?.map(\.doubleValue) ?? [], [0, 0.08 / 0.31, 0.21 / 0.31, 1], accuracy: 0.0001)

        let deselect = TellomiCheckPop.animation(selected: false)
        XCTAssertEqual(deselect.values as? [CGFloat], [1, 0.9, 1])
        XCTAssertEqual(deselect.duration, 0.21, accuracy: 0.0001)
    }

    func testSelectionViewPopsOnlyWhenTheStateChanges() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "减弱动态效果时不弹")
        let selectionView = MessageSelectionView()
        let indicator = try XCTUnwrap(selectionView.subviews.first)

        selectionView.tellomiSetSelected(true, animated: true)
        XCTAssertTrue(selectionView.isSelected)
        XCTAssertNotNil(indicator.layer.animation(forKey: TellomiCheckPop.animationKey), "点一下 / 拖选：弹一下")

        indicator.layer.removeAllAnimations()
        selectionView.tellomiSetSelected(true, animated: true)
        XCTAssertNil(indicator.layer.animation(forKey: TellomiCheckPop.animationKey), "状态没变不弹")

        selectionView.isSelected = false
        XCTAssertNil(indicator.layer.animation(forKey: TellomiCheckPop.animationKey), "重画时照旧赋值，不弹")
    }

    // MARK: - 读屏公告

    func testSelectionCountIsReadOut() {
        let text = TellomiSelectionAnnouncement.text(selectedCount: 3)
        XCTAssertTrue(text.contains("3"), text)
        XCTAssertNotEqual(text, "IMAGE_PICKER_TELLOMI_SELECTED_FORMAT", "要有译文，不能念出键名")
    }

    // MARK: - 进出多选换栏

    func testOnlyNormalSelectionTogglesAnimateTheBars() {
        XCTAssertTrue(TellomiSelectionBars.isSelectionToggle(from: .normal, to: .selection))
        XCTAssertTrue(TellomiSelectionBars.isSelectionToggle(from: .selection, to: .normal))
        XCTAssertFalse(TellomiSelectionBars.isSelectionToggle(from: .normal, to: .search), "搜索有自己的过渡")
        XCTAssertFalse(TellomiSelectionBars.isSelectionToggle(from: .search, to: .normal))
        XCTAssertFalse(TellomiSelectionBars.isSelectionToggle(from: .normal, to: .normal))
    }

    func testBottomBarSwapSlidesTheNewBarInAndCanBeCutShort() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let snapshot = UIView(frame: CGRect(x: 0, y: 760, width: 390, height: 84))
        let incoming = UIView(frame: CGRect(x: 0, y: 770, width: 390, height: 74))
        container.addSubview(incoming)
        container.addSubview(snapshot)
        let swap = TellomiBottomBarSwap()

        swap.run(snapshot: snapshot, incoming: incoming, reduceMotion: false)
        XCTAssertEqual(incoming.transform, .identity, "新栏滑到原位（动画的终值已经写上）")
        XCTAssertEqual(snapshot.alpha, 0, accuracy: 0.001)
        XCTAssertEqual(snapshot.transform.ty, 84, accuracy: 0.001, "旧栏滑下去它自己那么高")
        XCTAssertNotNil(snapshot.superview, "动画播完才拿掉快照")

        swap.finishImmediately()
        XCTAssertNil(snapshot.superview, "又切了一次：立刻落到终点")
        XCTAssertEqual(incoming.transform, .identity)
    }

    func testBottomBarSwapWithReducedMotionOnlyFades() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let snapshot = UIView(frame: CGRect(x: 0, y: 760, width: 390, height: 84))
        let incoming = UIView(frame: CGRect(x: 0, y: 770, width: 390, height: 74))
        container.addSubview(incoming)
        container.addSubview(snapshot)

        TellomiBottomBarSwap().run(snapshot: snapshot, incoming: incoming, reduceMotion: true)

        XCTAssertEqual(snapshot.transform, .identity, "减弱动态效果：不滑")
        XCTAssertEqual(incoming.transform, .identity)
        XCTAssertEqual(snapshot.alpha, 0, accuracy: 0.001)
    }
}

private func XCTAssertEqual(_ lhs: [Double], _ rhs: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (left, right) in zip(lhs, rhs) {
        XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
    }
}
