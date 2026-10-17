//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（交互审计 A-07，owner 2026-10-17）：消息下面的回应胶囊——全部显示、放不下换行；同一条消息的回应变了才动。
@MainActor
final class TellomiReactionPillsTest: SignalBaseTest {

    private typealias Pill = CVReactionCountsView.PillState

    // MARK: - 换行

    /// 按顺序排，放不下的那一格起换到下一行；行高 24、行距 2。
    func testPillsWrapIntoRows() {
        let sizes = [CGSize(width: 40, height: 24), CGSize(width: 40, height: 24), CGSize(width: 40, height: 24)]
        let layout = CVReactionCountsView.flowLayout(pillSizes: sizes, maxWidth: 100, alignRight: false)
        XCTAssertEqual(layout.frames, [
            CGRect(x: 0, y: 0, width: 40, height: 24),
            CGRect(x: 40, y: 0, width: 40, height: 24),
            CGRect(x: 0, y: 26, width: 40, height: 24),
        ])
        XCTAssertEqual(layout.size, CGSize(width: 80, height: 50))
    }

    /// 靠右排：每一行的右边缘对齐（对方的消息，胶囊挂在气泡朝屏幕中间的那一侧）。
    func testRowsAlignRight() {
        let sizes = [CGSize(width: 40, height: 24), CGSize(width: 40, height: 24), CGSize(width: 30, height: 24)]
        let layout = CVReactionCountsView.flowLayout(pillSizes: sizes, maxWidth: 100, alignRight: true)
        XCTAssertEqual(layout.frames[2], CGRect(x: 50, y: 26, width: 30, height: 24))
    }

    /// 一格比整行还宽：自己占一行，不丢。
    func testAnOversizedPillTakesItsOwnRow() {
        let sizes = [CGSize(width: 30, height: 24), CGSize(width: 120, height: 24)]
        let layout = CVReactionCountsView.flowLayout(pillSizes: sizes, maxWidth: 100, alignRight: false)
        XCTAssertEqual(layout.frames[1].minY, 26)
        XCTAssertEqual(layout.size.width, 120)
    }

    /// 七个回应都有自己的一格（原来最多 3 格、第 3 格是「+N」）；一行 300 放不下就是两行。
    func testEveryReactionGetsAPill() {
        let pills = ["❤️", "👍", "👎", "😂", "😮", "😢", "🔥"].enumerated().map { index, emoji in
            Pill.emoji(emoji: emoji, count: 10 - index, fromLocalUser: index == 0)
        }
        let state = CVReactionCountsView.State(pills: pills)
        let builder = CVCellMeasurement.Builder()
        let size = CVReactionCountsView.measure(state: state, maxWidth: 300, measurementBuilder: builder)
        XCTAssertEqual(state.pills.count, 7)
        XCTAssertLessThanOrEqual(size.width, 300)
        XCTAssertEqual(size.height, 50, "两行")
        XCTAssertEqual(CVReactionCountsView.measuredHeight(state: state, maxWidth: 300), 50)
        XCTAssertEqual(CVReactionCountsView.measuredHeight(state: CVReactionCountsView.State(pills: Array(pills.prefix(2))), maxWidth: 300), 24, "一行")
    }

    // MARK: - 变化（和 Android `TellomiReactionPillAnimator.changeFor` 一样）

    func testChangeClassification() {
        let before = Pill.emoji(emoji: "❤️", count: 2, fromLocalUser: false)
        XCTAssertEqual(CVReactionCountsView.change(from: nil, to: before), .added)
        XCTAssertEqual(CVReactionCountsView.change(from: before, to: .emoji(emoji: "❤️", count: 3, fromLocalUser: true)), .countUp)
        XCTAssertEqual(CVReactionCountsView.change(from: before, to: .emoji(emoji: "❤️", count: 1, fromLocalUser: false)), .countDown)
        XCTAssertEqual(CVReactionCountsView.change(from: before, to: .emoji(emoji: "❤️", count: 2, fromLocalUser: true)), .restyled)
        XCTAssertEqual(CVReactionCountsView.change(from: before, to: before), .none)
    }

    /// 同一条消息：新胶囊弹出、计数变的那格轻弹；换成别的消息（行复用）：一格都不动。
    func testOnlyTheSameMessageAnimates() throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "减弱动态效果时只淡变")
        let view = CVReactionCountsView()
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 24)

        let first = CVReactionCountsView.State(pills: [.emoji(emoji: "❤️", count: 1, fromLocalUser: false)])
        configure(view, state: first, messageId: "a")
        let heart = try XCTUnwrap(view.subviews.first)
        XCTAssertTrue(heart.layer.animationKeys()?.isEmpty ?? true, "第一次画不动")

        let second = CVReactionCountsView.State(pills: [
            .emoji(emoji: "❤️", count: 2, fromLocalUser: true),
            .emoji(emoji: "👍", count: 1, fromLocalUser: false),
        ])
        configure(view, state: second, messageId: "a")
        let pills = view.subviews
        XCTAssertEqual(pills.count, 2)
        XCTAssertFalse(pills[0].layer.animationKeys()?.isEmpty ?? true, "❤️ 人数变了，轻弹")
        XCTAssertFalse(pills[1].layer.animationKeys()?.isEmpty ?? true, "👍 新出现，弹出来")

        let reused = CVReactionCountsView.State(pills: [.emoji(emoji: "😂", count: 1, fromLocalUser: false)])
        view.layer.removeAllAnimations()
        for pill in view.subviews { pill.layer.removeAllAnimations() }
        configure(view, state: reused, messageId: "b")
        XCTAssertTrue(view.subviews.first?.layer.animationKeys()?.isEmpty ?? true, "复用给别的消息不动")
    }

    private func configure(_ view: CVReactionCountsView, state: CVReactionCountsView.State, messageId: String) {
        let builder = CVCellMeasurement.Builder()
        _ = CVReactionCountsView.measure(state: state, maxWidth: 300, measurementBuilder: builder)
        view.reset()
        view.configure(state: state, cellMeasurement: builder.build(), messageId: messageId, alignRowsRight: false)
        view.layoutIfNeeded()
    }
}
