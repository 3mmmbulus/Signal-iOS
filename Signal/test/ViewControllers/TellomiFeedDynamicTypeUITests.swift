//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 最大字号支持的界面检查（UIKit）：分段控件的字体和最小高度、顶栏在放不下时缩字。数字本身在 `TellomiFeedDynamicTypeTests`。
final class TellomiFeedDynamicTypeUITests: XCTestCase {

    @MainActor
    func testSegmentedControlGetsAMinHeightOnceAndTheBodyFont() {
        let control = UISegmentedControl(items: ["A", "B", "C"])
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        host.addSubview(control)
        control.autoPinEdge(toSuperviewEdge: .leading)
        control.autoPinEdge(toSuperviewEdge: .trailing)
        control.autoPinEdge(toSuperviewEdge: .top)
        control.installFeedDynamicType()
        control.installFeedDynamicType()
        let heights = control.constraints.filter { $0.identifier == "feed.segmented.minHeight" }
        XCTAssertEqual(heights.count, 1, "装两次也只有一条")
        XCTAssertEqual(heights[0].constant, FeedDynamicTypeLayout.segmentedMinHeight(lineHeight: UIFont.dynamicTypeBody.lineHeight))
        let attributes = control.titleTextAttributes(for: .normal)
        XCTAssertEqual((attributes?[.font] as? UIFont)?.pointSize, UIFont.dynamicTypeBody.pointSize, "短标题放得下：和正文一样大，不夹紧")
        host.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(control.frame.size.height, heights[0].constant - 0.5)
    }

    @MainActor
    func testTopBarShrinksItsTitlesWhenTheNavigationBarGivesLessRoomAndNeverGrowsBack() {
        let bar = FeedTopBarView(tabs: [.recommend, .following])
        let natural = bar.intrinsicContentSize.width
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 44))
        host.addSubview(bar)
        bar.frame = CGRect(x: 0, y: 0, width: natural, height: 44)
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.intrinsicContentSize.width, natural, accuracy: 0.5, "放得下：不缩")

        bar.frame = CGRect(x: 0, y: 0, width: natural * 0.6, height: 44)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        let shrunk = bar.intrinsicContentSize.width
        XCTAssertLessThan(shrunk, natural, "放不下：字缩小，自然宽度跟着变小")
        XCTAssertGreaterThanOrEqual(shrunk, natural * FeedDynamicTypeLayout.topBarMinimumScale - 40)

        bar.frame = CGRect(x: 0, y: 0, width: natural, height: 44)
        bar.setNeedsLayout()
        bar.layoutIfNeeded()
        XCTAssertEqual(bar.intrinsicContentSize.width, shrunk, accuracy: 0.5, "给回宽的也不放大回去（避免来回抖）")
    }
}
