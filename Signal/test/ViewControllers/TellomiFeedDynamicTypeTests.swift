//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 最大字号下的版面数字（`FeedDynamicTypeLayout`）。
final class TellomiFeedDynamicTypeTests: XCTestCase {

    func testSegmentedControlGrowsWithTheLineHeightButNeverShrinksBelowTheSystemHeight() {
        XCTAssertEqual(FeedDynamicTypeLayout.segmentedMinHeight(lineHeight: 10), 32)
        XCTAssertEqual(FeedDynamicTypeLayout.segmentedMinHeight(lineHeight: 16), 32, "16 + 16 = 32，刚好")
        XCTAssertEqual(FeedDynamicTypeLayout.segmentedMinHeight(lineHeight: 16.2), 33, "行高向上取整再加上下各 8")
        XCTAssertEqual(FeedDynamicTypeLayout.segmentedMinHeight(lineHeight: 40), 56)
    }

    func testTopBarKeepsItsSizeWhenItFitsOrHasNoRoomYet() {
        XCTAssertEqual(FeedDynamicTypeLayout.topBarFontScale(available: 200, natural: 180, current: 1), 1)
        XCTAssertEqual(FeedDynamicTypeLayout.topBarFontScale(available: 200, natural: 200.4, current: 1), 1, "差不到半个点不算放不下")
        XCTAssertEqual(FeedDynamicTypeLayout.topBarFontScale(available: 0, natural: 300, current: 1), 1, "还没布局（宽度 0）不缩")
        XCTAssertEqual(FeedDynamicTypeLayout.topBarFontScale(available: 100, natural: 0, current: 1), 1)
    }

    func testTopBarShrinksProportionallyRoundedDownAndNeverBelowTheFloor() {
        XCTAssertEqual(FeedDynamicTypeLayout.topBarFontScale(available: 150, natural: 200, current: 1), 0.75)
        XCTAssertEqual(FeedDynamicTypeLayout.topBarFontScale(available: 100, natural: 300, current: 1), 0.7, "最多缩到 0.7")
        XCTAssertEqual(FeedDynamicTypeLayout.topBarFontScale(available: 100, natural: 300, current: 0.7), 0.7)
        XCTAssertEqual(FeedDynamicTypeLayout.topBarFontScale(available: 150, natural: 160, current: 0.9), 0.84, "0.9 × 150/160 = 0.84375，向下取到 0.84")
    }

    func testTopBarScaleOnlyGoesDownSoItCannotFlipFlop() {
        // 缩小之后导航栏可能给更宽（自然宽度变小了）：已经缩过的不会再放大回去
        var scale: CGFloat = 1
        scale = FeedDynamicTypeLayout.topBarFontScale(available: 150, natural: 200, current: scale)
        XCTAssertEqual(scale, 0.75)
        XCTAssertEqual(FeedDynamicTypeLayout.topBarFontScale(available: 400, natural: 150, current: scale), 0.75)
        XCTAssertEqual(FeedDynamicTypeLayout.topBarFontScale(available: 300, natural: 150, current: 0.7), 0.7)
        for _ in 0..<20 {
            scale = FeedDynamicTypeLayout.topBarFontScale(available: 120, natural: 200 * scale, current: scale)
        }
        XCTAssertLessThanOrEqual(scale, 0.75)
        XCTAssertGreaterThanOrEqual(scale, FeedDynamicTypeLayout.topBarMinimumScale)
    }

    func testPostMetaStacksOnlyAtAccessibilitySizes() {
        XCTAssertTrue(FeedDynamicTypeLayout.stacksPostMetaVertically(isAccessibilityCategory: true))
        XCTAssertFalse(FeedDynamicTypeLayout.stacksPostMetaVertically(isAccessibilityCategory: false))
    }
}
