//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// I-14：顶栏和底栏在同一次回调里收起 / 出现（Android `FeedChromeState` + `FeedListPane` / `MainActivity`），
/// 收起 220 ms、出现 180 ms；栏动引起的 inset 跳变不算滚动。
final class TellomiFeedChromeCoordinatorTests: XCTestCase {
    private struct Call: Equatable {
        var bar: String
        var hidden: Bool
        var duration: TimeInterval
    }

    private var calls = [Call]()

    private func coordinator() -> FeedChromeCoordinator {
        calls = []
        return FeedChromeCoordinator(
            setTopBarHidden: { [unowned self] in self.calls.append(Call(bar: "top", hidden: $0, duration: $1)) },
            setBottomBarHidden: { [unowned self] in self.calls.append(Call(bar: "bottom", hidden: $0, duration: $1)) },
        )
    }

    func testDurationsAreTheSpec() {
        XCTAssertEqual(FeedChromeCoordinator.duration(visible: false), 0.22, accuracy: 0.0001)
        XCTAssertEqual(FeedChromeCoordinator.duration(visible: true), 0.18, accuracy: 0.0001)
    }

    func testBothBarsHideTogetherThenShowTogether() {
        let chrome = coordinator()
        chrome.onListScrolled(offsetFromTop: 0)
        chrome.onListScrolled(offsetFromTop: 100)
        XCTAssertTrue(calls.isEmpty)
        chrome.onListScrolled(offsetFromTop: 150)    // 累计 50 ≥ 48
        XCTAssertEqual(calls, [
            Call(bar: "top", hidden: true, duration: 0.22),
            Call(bar: "bottom", hidden: true, duration: 0.22),
        ])
        XCTAssertTrue(chrome.barsHidden)

        calls = []
        chrome.onListScrolled(offsetFromTop: 150)    // 栏动之后的第一次位置：只记
        chrome.onListScrolled(offsetFromTop: 137)    // 往回 13 ≥ 12
        XCTAssertEqual(calls, [
            Call(bar: "top", hidden: false, duration: 0.18),
            Call(bar: "bottom", hidden: false, duration: 0.18),
        ])
        XCTAssertFalse(chrome.barsHidden)
    }

    func testTheInsetJumpAfterHidingIsNotAScroll() {
        let chrome = coordinator()
        chrome.onListScrolled(offsetFromTop: 100)
        chrome.onListScrolled(offsetFromTop: 160)    // 收起
        calls = []
        // 导航栏收起后 adjustedContentInset.top 少了 44：offsetFromTop 跳到 116，不能当成往回滚 44 又把栏放出来
        chrome.onListScrolled(offsetFromTop: 116)
        chrome.onListScrolled(offsetFromTop: 120)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(chrome.barsHidden)
    }

    func testResetShowsBothBarsWithoutAnimation() {
        let chrome = coordinator()
        chrome.onListScrolled(offsetFromTop: 100)
        chrome.onListScrolled(offsetFromTop: 200)
        calls = []
        chrome.reset()
        XCTAssertEqual(calls, [
            Call(bar: "top", hidden: false, duration: 0),
            Call(bar: "bottom", hidden: false, duration: 0),
        ])
        calls = []
        chrome.reset()    // 已经显示着：不再下发
        XCTAssertTrue(calls.isEmpty)
    }

    func testNearTheTopTheBarsComeBack() {
        let chrome = coordinator()
        chrome.onListScrolled(offsetFromTop: 100)
        chrome.onListScrolled(offsetFromTop: 300)
        XCTAssertTrue(chrome.barsHidden)
        chrome.onListScrolled(offsetFromTop: 300)
        chrome.onListScrolled(offsetFromTop: 20)
        XCTAssertFalse(chrome.barsHidden)
    }
}
