//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 详情事件和分享（I-13）的界面接线检查（UIKit）：详情页出现时报一次 `open`、离开 / 退到后台收尾一次，分享做完才报 `share`。
/// 判定在 `TellomiFeedDetailEventsTests`，store 那一段在 `TellomiFeedEventsWiringTests`。这里只看页面有没有在对的时候调 store。
final class TellomiFeedEventsWiringUITests: XCTestCase {

    @MainActor
    private func makeDetail(eventsEnabled: Bool = true, shareEnabled: Bool = true, surface: FeedEventSurface? = .recommend, shareable: Bool = true) async throws -> (FeedPostDetailViewController, FeedStore, UIWindow) {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let store = FeedStore(source: source)
        let fetched = try await source.card(contentId: "sample-1")
        var card = try XCTUnwrap(fetched)
        card.shareable = shareable
        let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: false, feed: store, eventSurface: surface, eventsEnabled: eventsEnabled, shareEnabled: shareEnabled)
        let navigation = OWSNavigationController(rootViewController: detail)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        detail.loadViewIfNeeded()
        await detail.detailStore.waitForTasks()
        // 打开页面时详情 store 会从 Card API 重新取这张卡片（样例里的 sample-1 不带 shareable），再按测试要的值改回来
        store.updateCard(card.id) { $0.shareable = shareable }
        window.layoutIfNeeded()
        // 在窗口里时 viewDidAppear 会自己报 open；这里先报掉，下面的计数都从这一条开始算（只报一次）
        detail.openDetailEvent()
        return (detail, store, window)
    }

    @MainActor
    func testBothSwitchesAreOffByDefault() {
        XCTAssertFalse(TellomiFeed.isDetailEventsEnabled)
        XCTAssertFalse(TellomiFeed.isShareEnabled)
    }

    @MainActor
    func testOpeningReportsOnceAndLeavingClosesOnce() async throws {
        let (detail, store, window) = try await makeDetail()
        defer { window.isHidden = true }
        detail.openDetailEvent()
        detail.openDetailEvent()
        XCTAssertEqual(store.pendingEventCount, 1, "只报一次 open")
        detail.closeDetailEvent()
        XCTAssertEqual(store.pendingEventCount, 2, "离开：快速退出（几乎没停留）")
        detail.closeDetailEvent()
        detail.openDetailEvent()
        XCTAssertEqual(store.pendingEventCount, 2, "收尾之后不重报也不重新计时")
    }

    @MainActor
    func testNothingIsReportedWithTheSwitchOffOrWithoutASurface() async throws {
        let (off, offStore, offWindow) = try await makeDetail(eventsEnabled: false)
        defer { offWindow.isHidden = true }
        off.openDetailEvent()
        off.closeDetailEvent()
        XCTAssertEqual(offStore.pendingEventCount, 0)

        let (none, noneStore, noneWindow) = try await makeDetail(surface: nil)
        defer { noneWindow.isHidden = true }
        none.openDetailEvent()
        none.closeDetailEvent()
        XCTAssertEqual(noneStore.pendingEventCount, 0, "通知 / 我的动态点进来的没有对应的 surface")
    }

    @MainActor
    func testBackgroundClosesTheVisit() async throws {
        let (detail, store, window) = try await makeDetail()
        defer { window.isHidden = true }
        detail.openDetailEvent()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(store.pendingEventCount, 0, "退到后台：收尾（open + 快速退出）并马上发出去，缓冲清空")
        await store.waitForEventFlushes()
        detail.closeDetailEvent()
        XCTAssertEqual(store.pendingEventCount, 0, "已经收尾了，不再补")
    }

    @MainActor
    func testACompletedShareReportsAndACancelledOneDoesNot() async throws {
        let (detail, store, window) = try await makeDetail()
        defer { window.isHidden = true }
        var shared = [String]()
        detail.presentShareSheet = { link, finished in
            shared.append(link)
            finished(shared.count == 1)
        }
        detail.share()
        detail.share()
        XCTAssertEqual(shared, [FeedShare.postLink(contentId: "sample-1"), FeedShare.postLink(contentId: "sample-1")])
        XCTAssertEqual(store.pendingEventCount, 2, "open + 第一次分享完成报 share，第二次取消不报")
    }

    @MainActor
    func testCopyingTheLinkCountsAsShared() async throws {
        let (detail, store, window) = try await makeDetail()
        defer { window.isHidden = true }
        var copied: String?
        detail.copyToPasteboard = { copied = $0 }
        detail.copyLink()
        XCTAssertEqual(copied, FeedShare.postLink(contentId: "sample-1"))
        XCTAssertEqual(store.pendingEventCount, 2, "open + share")
    }

    @MainActor
    func testAPostThatCannotBeSharedHasNoShareItemsAndDoesNothing() async throws {
        let (detail, store, window) = try await makeDetail(shareable: false)
        defer { window.isHidden = true }
        XCTAssertFalse(detail.shownPostMenu.contains(.share))
        var presented = false
        detail.presentShareSheet = { _, _ in presented = true }
        detail.share()
        detail.copyLink()
        XCTAssertFalse(presented)
        XCTAssertEqual(store.pendingEventCount, 1, "只有 open，没有 share")
    }

    @MainActor
    func testTheMenuShowsShareAndCopyLinkOnlyWithTheSwitchOn() async throws {
        let (on, _, onWindow) = try await makeDetail()
        defer { onWindow.isHidden = true }
        XCTAssertTrue(on.shownPostMenu.contains(.share))
        XCTAssertTrue(on.shownPostMenu.contains(.copyLink))
        let (off, _, offWindow) = try await makeDetail(shareEnabled: false)
        defer { offWindow.isHidden = true }
        XCTAssertFalse(off.shownPostMenu.contains(.share))
        XCTAssertFalse(off.shownPostMenu.contains(.copyLink))
    }
}
