//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedChromeStateTests.swift (new file)
// Mirror of Android `FeedChromeStateTest` + the UIScrollView offset adapter.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class TellomiFeedChromeStateTests: XCTestCase {
    private func chrome() -> FeedChromeState {
        let chrome = FeedChromeState(hideAfter: 48, showAfter: 12)
        chrome.onNearTopChanged(false)
        return chrome
    }

    func testHidesAfter48TowardOlderShowsAfter12Back() {
        let chrome = chrome()
        chrome.onScroll(towardOlder: 30)
        XCTAssertTrue(chrome.visible)
        chrome.onScroll(towardOlder: 18)
        XCTAssertFalse(chrome.visible)

        chrome.onScroll(towardOlder: -8)
        XCTAssertFalse(chrome.visible)
        chrome.onScroll(towardOlder: -4)
        XCTAssertTrue(chrome.visible)
    }

    func testChangingDirectionStartsTheCountOver() {
        let chrome = chrome()
        chrome.onScroll(towardOlder: 40)
        chrome.onScroll(towardOlder: -1)
        chrome.onScroll(towardOlder: 40)
        XCTAssertTrue(chrome.visible)
    }

    func testNearTheTopItAlwaysShows() {
        let chrome = chrome()
        chrome.onScroll(towardOlder: 100)
        XCTAssertFalse(chrome.visible)
        chrome.onNearTopChanged(true)
        XCTAssertTrue(chrome.visible)
        chrome.onScroll(towardOlder: 100)
        XCTAssertTrue(chrome.visible)
    }

    func testResetBringsItBack() {
        let chrome = chrome()
        chrome.onScroll(towardOlder: 100)
        chrome.reset()
        XCTAssertTrue(chrome.visible)
    }

    func testConstantsAreTheSpec() {
        XCTAssertEqual(FeedChromeState.hideAfter, 48)
        XCTAssertEqual(FeedChromeState.showAfter, 12)
        XCTAssertEqual(FeedChromeState.alwaysShowWithin, 64)
        XCTAssertEqual(FeedChromeState.hideMillis, 220)
        XCTAssertEqual(FeedChromeState.showMillis, 180)
    }

    func testVisibilityCallbackFiresOnlyOnChange() {
        let chrome = chrome()
        var seen = [Bool]()
        chrome.onVisibilityChange = { seen.append($0) }
        chrome.onScroll(towardOlder: 10)
        chrome.onScroll(towardOlder: 100)    // 收起
        chrome.onScroll(towardOlder: 100)    // 已经收起：不重复
        chrome.onScroll(towardOlder: -20)    // 出现
        chrome.onScroll(towardOlder: -20)
        XCTAssertEqual(seen, [false, true])
    }

    func testContentOffsetAdapterTurnsOffsetsIntoScrolls() {
        let chrome = FeedChromeState(hideAfter: 48, showAfter: 12)
        var seen = [Bool]()
        chrome.onVisibilityChange = { seen.append($0) }

        chrome.onContentOffsetChanged(offsetFromTop: 0)      // 第一次：只记位置
        chrome.onContentOffsetChanged(offsetFromTop: 60)     // 还在离顶 64 以内：不收
        chrome.onContentOffsetChanged(offsetFromTop: 100)    // 出了 64：之后才累计
        XCTAssertTrue(chrome.visible)
        chrome.onContentOffsetChanged(offsetFromTop: 140)    // +40
        XCTAssertTrue(chrome.visible)
        chrome.onContentOffsetChanged(offsetFromTop: 150)    // +10 → 累计 50 ≥ 48
        XCTAssertFalse(chrome.visible)
        chrome.onContentOffsetChanged(offsetFromTop: 140)    // 往回 10
        XCTAssertFalse(chrome.visible)
        chrome.onContentOffsetChanged(offsetFromTop: 137)    // 往回累计 13 ≥ 12
        XCTAssertTrue(chrome.visible)
        chrome.onContentOffsetChanged(offsetFromTop: 500)    // 一大步往下：直接收
        XCTAssertFalse(chrome.visible)
        chrome.onContentOffsetChanged(offsetFromTop: 30)     // 回到顶部附近：马上出现
        XCTAssertTrue(chrome.visible)
        XCTAssertEqual(seen, [false, true, false, true])
    }

    func testReplacingTheContentDoesNotCountTheJumpAsAScroll() {
        let chrome = FeedChromeState(hideAfter: 48, showAfter: 12)
        chrome.onContentOffsetChanged(offsetFromTop: 1000)
        chrome.onContentOffsetChanged(offsetFromTop: 1010)
        XCTAssertTrue(chrome.visible)
        chrome.onContentReplaced()
        chrome.onContentOffsetChanged(offsetFromTop: 2000)   // 换了内容后位置跳到 2000：不是滚动
        XCTAssertTrue(chrome.visible)
        chrome.onContentOffsetChanged(offsetFromTop: 2060)
        XCTAssertFalse(chrome.visible)
    }
}
