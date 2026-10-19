//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 详情事件（I-13）接进 `FeedStore` 和详情页「···」菜单之后的检查：打开报 `open`，离开按停留报 `quick_exit` / `dwell`，
/// 分享完成才报 `share`。事件本身的判定在 `TellomiFeedDetailEventsTests`，这里测的是 store 把它们攒进缓冲、发出去的那一段。
@MainActor
final class TellomiFeedEventsWiringTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(_ source: WiringSource, clock: @escaping () -> Date) -> FeedStore {
        return FeedStore(source: source, now: clock)
    }

    func testOpenThenQuickExitAreSentTogetherWhenFlushed() async throws {
        var clock = t0
        let source = WiringSource()
        let store = make(source) { clock }
        store.onDetailOpened(contentId: "a", surface: .search)
        XCTAssertEqual(store.pendingEventCount, 1)
        clock = t0.addingTimeInterval(1.5)
        store.onDetailClosed(flush: true)
        await store.waitForEventFlushes()
        XCTAssertEqual(source.batches.count, 1)
        XCTAssertEqual(source.batches[0].map(\.type), ["open", "quick_exit"])
        XCTAssertTrue(source.batches[0].allSatisfy { $0.surface == "search" && $0.contentId == "a" })
        XCTAssertEqual(source.batches[0][1].value, 1.5)
        XCTAssertNil(source.batches[0][0].value)
    }

    func testClosingWithoutFlushKeepsTheEventsBufferedUntilTheNextFlush() async throws {
        var clock = t0
        let source = WiringSource()
        let store = make(source) { clock }
        store.onDetailOpened(contentId: "a", surface: .hot)
        clock = t0.addingTimeInterval(2)
        store.onDetailClosed()
        await store.waitForEventFlushes()
        XCTAssertEqual(store.pendingEventCount, 2, "回到动态页还要继续，别急着发；缓冲满了、30 秒到了或退到后台再发")
        XCTAssertTrue(source.batches.isEmpty)
        store.onDetailOpened(contentId: "b", surface: .hot)
        store.onDetailClosed(flush: true)
        await store.waitForEventFlushes()
        XCTAssertEqual(source.batches.map { $0.map(\.type) }, [["open", "quick_exit", "open", "quick_exit"]])
        XCTAssertEqual(store.pendingEventCount, 0)
    }

    func testALongVisitReportsDwellWithTheSeconds() async throws {
        var clock = t0
        let source = WiringSource()
        let store = make(source) { clock }
        store.onDetailOpened(contentId: "a", surface: .recommend)
        clock = t0.addingTimeInterval(45)
        store.onDetailClosed(flush: true)
        await store.waitForEventFlushes()
        XCTAssertEqual(source.batches[0].map(\.type), ["open", "dwell"])
        XCTAssertEqual(source.batches[0][1].value, 45)
    }

    func testAMiddleVisitOnlyHasTheOpen() async throws {
        var clock = t0
        let source = WiringSource()
        let store = make(source) { clock }
        store.onDetailOpened(contentId: "a", surface: .following)
        clock = t0.addingTimeInterval(10)
        store.onDetailClosed(flush: true)
        await store.waitForEventFlushes()
        XCTAssertEqual(source.batches[0].map(\.type), ["open"])
    }

    func testTheThresholdsAre3And30SecondsInclusive() async throws {
        for (seconds, expected) in [(3.0, ["open", "quick_exit"]), (3.01, ["open"]), (29.99, ["open"]), (30.0, ["open", "dwell"])] {
            var clock = t0
            let source = WiringSource()
            let store = make(source) { clock }
            store.onDetailOpened(contentId: "a", surface: .recommend)
            clock = t0.addingTimeInterval(seconds)
            store.onDetailClosed(flush: true)
            await store.waitForEventFlushes()
            XCTAssertEqual(source.batches[0].map(\.type), expected, "\(seconds)")
        }
    }

    func testOpeningAnotherClosesThePreviousOne() async throws {
        var clock = t0
        let source = WiringSource()
        let store = make(source) { clock }
        store.onDetailOpened(contentId: "a", surface: .recommend)
        clock = t0.addingTimeInterval(40)
        store.onDetailOpened(contentId: "b", surface: .profile)
        store.onDetailClosed(flush: true)
        await store.waitForEventFlushes()
        let events = source.batches[0]
        XCTAssertEqual(events.map(\.type), ["open", "dwell", "open", "quick_exit"])
        XCTAssertEqual(events.map(\.contentId), ["a", "a", "b", "b"])
        XCTAssertEqual(events.map(\.surface), ["recommend", "recommend", "profile", "profile"])
    }

    func testClosingWithNothingOpenOrTwiceReportsNothing() async throws {
        let clock = t0
        let source = WiringSource()
        let store = make(source) { clock }
        store.onDetailClosed(flush: true)
        XCTAssertEqual(store.pendingEventCount, 0)
        store.onDetailOpened(contentId: "a", surface: .recommend)
        store.onDetailClosed()
        let pending = store.pendingEventCount
        store.onDetailClosed()
        XCTAssertEqual(store.pendingEventCount, pending, "第二次离开什么都不报")
        store.onFeedHidden()
        await store.waitForEventFlushes()
        XCTAssertEqual(source.batches.count, 1)
    }

    func testTheEventsJoinTheImpressionBufferAndGoOutWithThePageHidden() async throws {
        var clock = t0
        let source = WiringSource()
        let store = make(source) { clock }
        store.onCardsVisible(.recommend, ["x"])
        clock = t0.addingTimeInterval(2)
        store.onCardsVisible(.recommend, ["x"])
        store.onDetailOpened(contentId: "x", surface: .recommend)
        XCTAssertEqual(store.pendingEventCount, 2)
        store.onFeedHidden()
        await store.waitForEventFlushes()
        XCTAssertEqual(source.batches.flatMap { $0 }.map(\.type), ["impression", "open"])
    }

    func testAFullBufferIsSentRightAway() async throws {
        var clock = t0
        let source = WiringSource()
        let store = make(source) { clock }
        for index in 0..<25 {
            store.onDetailOpened(contentId: "c\(index)", surface: .recommend)
            clock = clock.addingTimeInterval(1)
            store.onDetailClosed()
        }
        await store.waitForEventFlushes()
        XCTAssertEqual(source.batches.map(\.count), [50], "25 次打开 + 25 次快速退出 = 50 条，满了就发")
    }

    // MARK: - 分享

    func testOnlyACompletedShareOfAShareableCardIsReported() async throws {
        let source = WiringSource()
        let store = make(source) { self.t0 }
        store.onShareFinished(contentId: "a", surface: .recommend, shareable: true, outcome: .cancelled)
        store.onShareFinished(contentId: "a", surface: .recommend, shareable: false, outcome: .completed)
        XCTAssertEqual(store.pendingEventCount, 0)
        store.onShareFinished(contentId: "a", surface: .profile, shareable: true, outcome: .completed)
        XCTAssertEqual(store.pendingEventCount, 1)
        store.onFeedHidden()
        await store.waitForEventFlushes()
        XCTAssertEqual(source.batches[0].map(\.type), ["share"])
        XCTAssertEqual(source.batches[0][0].surface, "profile")
        XCTAssertNil(source.batches[0][0].value)
    }
}

@MainActor
final class TellomiFeedShareMenuTests: XCTestCase {
    private func post(shareable: Bool = true, kind: String = FeedCard.kindPost, author: Bool = false) -> FeedCard {
        var card = FeedCard(id: "p", kind: kind, publishedAt: "2026-10-19T00:00:00Z", text: "hi", viewer: FeedViewer(isAuthor: author))
        card.shareable = shareable
        return card
    }

    func testShareAndCopyLinkComeBeforeTheOtherItemsOnlyWhenAllowed() async {
        XCTAssertEqual(FeedDetailMenu.items(forPost: post(), canShare: true), [.share, .copyLink, .notInterested, .report])
        XCTAssertEqual(FeedDetailMenu.items(forPost: post()), [.notInterested, .report], "默认没有")
        let own = FeedDetailMenu.items(forPost: post(author: true), canEdit: true, canShare: true)
        XCTAssertEqual(Array(own.prefix(3)), [.edit, .share, .copyLink])
        XCTAssertEqual(own.last, .deletePost)
    }

    func testShareItemsAreShownNeedNoConfirmationAndHaveTitles() async {
        XCTAssertEqual(FeedDetailMenu.shown([.share, .copyLink], reportAvailable: false), [.share, .copyLink])
        for item in [FeedDetailMenuItem.share, .copyLink] {
            XCTAssertFalse(item.isDestructive)
            XCTAssertFalse(item.needsConfirmation)
            XCTAssertNil(item.confirmationTitleKey)
        }
        XCTAssertEqual(FeedDetailMenuItem.share.titleKey, "TELLOMI_FEED_MENU_SHARE")
        XCTAssertEqual(FeedDetailMenuItem.copyLink.titleKey, "TELLOMI_FEED_MENU_COPY_LINK")
    }

    func testTheStateAllowsSharingOnlyForAShareablePostWithTheSwitchOn() async {
        func state(_ card: FeedCard, on: Bool) -> FeedPostDetailState {
            var state = FeedPostDetailState(post: card)
            state.shareEnabled = on
            return state
        }
        XCTAssertTrue(state(post(), on: true).canSharePost)
        XCTAssertFalse(state(post(), on: false).canSharePost)
        XCTAssertFalse(state(post(shareable: false), on: true).canSharePost, "私密账号 / 非公开动态没有外链")
        XCTAssertFalse(state(post(kind: FeedCard.kindComment), on: true).canSharePost)
        XCTAssertEqual(state(post(), on: true).postMenu, [.share, .copyLink, .notInterested, .report])
        XCTAssertEqual(state(post(), on: false).postMenu, [.notInterested, .report])
    }

    func testTheStoreTakesTheSwitch() async {
        let on = FeedPostDetailStore(initial: post(), source: WiringSource(), shareEnabled: true)
        XCTAssertTrue(on.state.canSharePost)
        let off = FeedPostDetailStore(initial: post(), source: WiringSource())
        XCTAssertFalse(off.state.canSharePost)
    }

    func testTheLinkIsTheLowercaseContentIdOnTheShortHost() async {
        var card = post()
        card.id = "ABC-1"
        XCTAssertEqual(FeedShare.link(for: card), "https://tell.cc/m#abc-1")
    }
}

private final class WiringSource: FeedSource {
    private(set) var batches = [[FeedEventPayload]]()

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        throw NSError(domain: "wiring", code: 1)
    }

    func reportEvents(_ events: [FeedEventPayload]) async throws {
        batches.append(events)
    }
}
