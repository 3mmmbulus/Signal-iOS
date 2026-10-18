//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 帖子详情页的界面检查（UIKit）：在测试进程里放一个真的 `FeedViewController`（样例数据）+ 导航栏，点开一条帖子，看详情页和列表是不是共用同一个 `FeedStore`。
/// 真 App 在无签名模拟器里起不来（App Group），所以界面都在测试进程里渲染、检查；截图的写法见 `docs`/报告里的「截图方法」。
final class TellomiFeedDetailUITests: XCTestCase {

    /// 一个放着真 `FeedViewController` 的窗口。
    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow

        var store: FeedStore { feed.store }

        /// 和用户点一行一样：走列表的 `didSelectRowAt`，所以走的是真的接线（`onOpenPost` → `openPost` → push）。
        func openPost(row: Int) -> FeedPostDetailViewController? {
            let table = feed.pages[0].tableView
            table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: row, section: 0))
            window.layoutIfNeeded()
            let detail = navigation.topViewController as? FeedPostDetailViewController
            detail?.loadViewIfNeeded()
            window.layoutIfNeeded()
            return detail
        }

        /// 直接推一个详情页（卡片不一定在列表第一页，比如 `sample-9`）；接线和 `openPost` 一样用列表的 store。
        func openDetail(of card: FeedCard, source: FeedSource) -> FeedPostDetailViewController {
            let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: false, feed: store)
            navigation.pushViewController(detail, animated: false)
            detail.loadViewIfNeeded()
            window.layoutIfNeeded()
            return detail
        }

        func pop() {
            navigation.popViewController(animated: false)
            window.layoutIfNeeded()
        }
    }

    @MainActor
    private func makeHarness(source: SampleFeedSource) async -> Harness {
        let feed = FeedViewController(source: source)
        let navigation = OWSNavigationController(rootViewController: feed)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        await feed.store.loadConfig()
        await feed.store.waitForLoad(.recommend)
        window.layoutIfNeeded()
        return Harness(feed: feed, navigation: navigation, window: window)
    }

    private func quickSource() -> SampleFeedSource {
        return SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
    }

    // MARK: - (a) 详情页和列表共用一个 FeedStore

    /// 点开一条帖子：详情页拿到的是列表的 store；列表页和详情页各订一个。
    @MainActor
    func testTheDetailPageSharesTheListsStoreAndBothSubscribe() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        XCTAssertEqual(harness.store.subscriberCount, 1, "只有列表订着")
        let cards = harness.store.tab(.recommend).cards
        let detail = try XCTUnwrap(harness.openPost(row: 1))
        XCTAssertEqual(detail.detailStore.state.post.id, cards[1].id)
        XCTAssertTrue(detail.detailStore.isObservingFeed)
        XCTAssertEqual(harness.store.subscriberCount, 2, "列表 + 详情")
        harness.pop()
        harness.window.isHidden = true
    }

    /// 详情页退出（弹出）后放掉订阅和借着的卡片，列表还订着。
    @MainActor
    func testPoppingTheDetailReleasesItsSubscriptionAndBorrowedCard() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 2))
        XCTAssertEqual(harness.store.subscriberCount, 2)
        harness.pop()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(detail.detailStore.isObservingFeed)
        XCTAssertEqual(harness.store.subscriberCount, 1)
    }

    /// 详情页里改了点赞（走和点按钮一样的 `toggleLike`），列表那一行马上跟着变；两边读到的是 store 里同一张卡片。
    @MainActor
    func testALikeChangedInTheDetailUpdatesTheListRow() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        let before = harness.store.tab(.recommend).cards[3]
        XCTAssertFalse(before.viewer.liked)
        let detail = try XCTUnwrap(harness.openPost(row: 3))
        detail.detailStore.toggleLike()
        XCTAssertTrue(detail.detailStore.state.post.viewer.liked)
        XCTAssertTrue(harness.feed.pages[0].rows[3].card.viewer.liked, "列表那一行已经画成点过赞")
        XCTAssertEqual(harness.feed.pages[0].rows[3].card.stats.likes, before.stats.likes + 1)
        XCTAssertEqual(harness.store.card(id: before.id), detail.detailStore.state.post)
        await detail.detailStore.waitForTasks()
        harness.pop()
        harness.window.isHidden = true
    }

    /// 列表里点的赞，已经打开着的详情页也跟着变（详情只是从 store 重读）。
    @MainActor
    func testALikeChangedInTheListUpdatesTheOpenDetail() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 3))
        let card = harness.store.tab(.recommend).cards[3]
        harness.store.toggleLike(card)
        XCTAssertTrue(detail.detailStore.state.post.viewer.liked)
        await harness.store.waitForActions()
        harness.pop()
        harness.window.isHidden = true
    }

    /// 详情页的帖子那一格在行没变时就地更新（不整表重载）：点赞后那一格上的数字变了。
    @MainActor
    func testTheDetailPostCellUpdatesInPlaceWhenTheLikeChanges() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 3))
        try await Task.sleep(nanoseconds: 100_000_000)
        let cell = try XCTUnwrap(detail.postCell)
        let likes = cell.card?.stats.likes
        detail.detailStore.toggleLike()
        XCTAssertTrue(cell === detail.postCell, "还是同一个格子")
        XCTAssertEqual(detail.postCell?.card?.stats.likes, (likes ?? 0) + 1)
        await detail.detailStore.waitForTasks()
        harness.pop()
        harness.window.isHidden = true
    }

    // MARK: - (b) 详情页的点赞按钮

    private var unlikeLabel: String { OWSLocalizedString("TELLOMI_FEED_UNLIKE", comment: "") }
    private var likeLabel: String { OWSLocalizedString("TELLOMI_FEED_LIKE", comment: "") }

    /// 详情页的赞可以点（「···」仍然收起来）：点一下马上点亮、列表那一行同步，再点一下取消。
    @MainActor
    func testTheDetailLikeButtonWorksAndTheListFollowsBothWays() async throws {
        let harness = await makeHarness(source: quickSource())
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 3))
        try await Task.sleep(nanoseconds: 100_000_000)
        let button = try XCTUnwrap(detail.postCell?.likeButton)
        XCTAssertTrue(button.isUserInteractionEnabled)
        XCTAssertEqual(button.accessibilityLabel, likeLabel)
        let likes = harness.feed.pages[0].rows[3].card.stats.likes

        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(detail.postCell?.likeButton.accessibilityLabel, unlikeLabel, "按钮马上点亮")
        XCTAssertTrue(harness.feed.pages[0].rows[3].card.viewer.liked)
        XCTAssertEqual(harness.feed.pages[0].rows[3].card.stats.likes, likes + 1)
        await detail.detailStore.waitForTasks()

        detail.postCell?.likeButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(detail.postCell?.likeButton.accessibilityLabel, likeLabel)
        XCTAssertFalse(harness.feed.pages[0].rows[3].card.viewer.liked)
        XCTAssertEqual(harness.feed.pages[0].rows[3].card.stats.likes, likes)
        await detail.detailStore.waitForTasks()
        harness.pop()
        harness.window.isHidden = true
    }

    /// 请求还在路上时按钮已经点亮（`likeLatencyNanos` 拖慢样例，方便截图）。
    @MainActor
    func testTheLikeIsLitWhileTheRequestIsStillOnItsWay() async throws {
        let source = quickSource()
        source.simulation.likeLatencyNanos = 600_000_000
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 3))
        try await Task.sleep(nanoseconds: 100_000_000)
        detail.postCell?.likeButton.sendActions(for: .touchUpInside)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(detail.postCell?.likeButton.accessibilityLabel, unlikeLabel)
        XCTAssertTrue(harness.feed.pages[0].rows[3].card.viewer.liked)
        await detail.detailStore.waitForTasks()
        XCTAssertEqual(detail.postCell?.likeButton.accessibilityLabel, unlikeLabel, "成功后还是点亮")
        harness.pop()
        harness.window.isHidden = true
    }

    /// 点赞失败：详情和列表都改回、详情弹「操作失败」（和列表同一句），提示弹过就清掉。
    @MainActor
    func testAFailedLikeRollsBackDetailAndListAndToastsTheActionFailedText() async throws {
        let source = quickSource()
        source.simulation.failsLikes = true
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 3))
        try await Task.sleep(nanoseconds: 100_000_000)
        let likes = harness.feed.pages[0].rows[3].card.stats.likes

        detail.postCell?.likeButton.sendActions(for: .touchUpInside)
        XCTAssertEqual(detail.postCell?.likeButton.accessibilityLabel, unlikeLabel, "先点亮")
        await detail.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(detail.postCell?.likeButton.accessibilityLabel, likeLabel, "失败：改回")
        XCTAssertFalse(harness.feed.pages[0].rows[3].card.viewer.liked)
        XCTAssertEqual(harness.feed.pages[0].rows[3].card.stats.likes, likes)
        XCTAssertEqual(detail.lastToastText, OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: ""))
        XCTAssertNil(detail.detailStore.state.notice, "提示弹过就清掉")
        harness.pop()
        harness.window.isHidden = true
    }

    // MARK: - (c) 评论输入框

    /// 和用户在键盘上敲一样走 `shouldChangeTextIn` → 写入 → `textViewDidChange`。回 false 表示被拦下 / 截了（文字已被设成该显示的）。
    @discardableResult
    @MainActor
    private func type(_ text: String, into input: FeedCommentInputView) -> Bool {
        let textView = input.textView
        let current = textView.text ?? ""
        let range = NSRange(location: (current as NSString).length, length: 0)
        guard input.textView(textView, shouldChangeTextIn: range, replacementText: text) else {
            input.textViewDidChange(textView)
            return false
        }
        textView.text = current + text
        input.textViewDidChange(textView)
        return true
    }

    @MainActor
    private func openComments(of id: String, source: SampleFeedSource, harness: Harness) async throws -> FeedPostDetailViewController {
        let fetched = try await source.card(contentId: id)
        let card = try XCTUnwrap(fetched)
        let detail = harness.openDetail(of: card, source: source)
        await detail.detailStore.waitForTasks()
        harness.window.layoutIfNeeded()
        return detail
    }

    /// 评论允许时输入框在最下面（贴着安全区 / 键盘），评论关了（`sample-9`）收起来、不占位。
    @MainActor
    func testTheCommentBoxIsAtTheBottomAndHiddenWhenCommentsAreClosed() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let open = try await openComments(of: "sample-1", source: source, harness: harness)
        XCTAssertFalse(open.commentInput.isHidden)
        let frame = open.commentInput.convert(open.commentInput.bounds, to: open.view)
        XCTAssertGreaterThan(frame.size.height, 40)
        XCTAssertGreaterThan(frame.minY, open.view.bounds.size.height / 2, "在下半屏")
        XCTAssertLessThanOrEqual(frame.maxY, open.view.bounds.size.height + 0.5)
        let table = open.detailTableView.convert(open.detailTableView.bounds, to: open.view)
        XCTAssertLessThanOrEqual(table.maxY, frame.minY + 0.5, "表格在输入框上面，不重叠")
        harness.pop()

        let closed = try await openComments(of: "sample-9", source: source, harness: harness)
        XCTAssertTrue(closed.commentInput.isHidden, "评论关了：不显示输入框")
        XCTAssertFalse(closed.detailStore.state.canComment)
        harness.pop()
        harness.window.isHidden = true
    }

    /// Mac 截图（2026-10-18）：灰色输入区只有屏幕约 40% 宽，右边一大片空白。输入区应该占满一行里除了发送键以外的宽度。
    @MainActor
    func testTheTextBoxFillsTheRowAndSendKeepsItsWidth() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let open = try await openComments(of: "sample-1", source: source, harness: harness)
        let input = open.commentInput
        let box = try XCTUnwrap(input.textView.superview)
        let boxFrame = box.convert(box.bounds, to: input)
        let sendFrame = input.sendButton.convert(input.sendButton.bounds, to: input)
        XCTAssertGreaterThan(input.bounds.size.width, 200)
        XCTAssertGreaterThanOrEqual(boxFrame.size.width, input.bounds.size.width * 0.6, "空的时候输入区也要占满")
        XCTAssertGreaterThanOrEqual(input.textView.bounds.size.width, boxFrame.size.width - 0.5, "里面的文字区和灰框一样宽")
        XCTAssertLessThanOrEqual(boxFrame.maxX, sendFrame.minX, "灰框在发送键左边，不重叠")
        XCTAssertLessThan(sendFrame.minX - boxFrame.maxX, 24, "灰框和发送键之间没有大片空白")
        XCTAssertLessThanOrEqual(sendFrame.maxX, input.bounds.size.width + 0.5)
        XCTAssertGreaterThan(sendFrame.size.width, 20, "发送键没被挤没")

        // 长文字也不改宽度（以前是按「一行排下来」的宽度算）
        type(String(repeating: "很长的一句话。", count: 20), into: input)
        harness.window.layoutIfNeeded()
        let afterFrame = box.convert(box.bounds, to: input)
        XCTAssertEqual(afterFrame.size.width, boxFrame.size.width, accuracy: 0.5)
        harness.pop()
        harness.window.isHidden = true
    }

    /// 输入第一个字时不跳高；一行字在灰框里上下居中；长高有上限。
    @MainActor
    func testTheFirstCharacterDoesNotJumpTheHeightAndOneLineIsCentred() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let open = try await openComments(of: "sample-1", source: source, harness: harness)
        let input = open.commentInput
        let before = input.currentTextHeight
        XCTAssertEqual(before, FeedCommentInputView.minTextHeight, accuracy: 1)
        XCTAssertEqual(input.textView.textContainerInset.top, input.textView.textContainerInset.bottom, "上下内边距一样 = 一行居中")
        XCTAssertEqual(
            input.textView.textContainerInset.top * 2 + UIFont.dynamicTypeBody.lineHeight,
            FeedCommentInputView.minTextHeight,
            accuracy: 1,
            "一行字加上下内边距正好是最小高度",
        )

        type("好", into: input)
        harness.window.layoutIfNeeded()
        XCTAssertEqual(input.currentTextHeight, before, accuracy: 0.5, "第一个字不跳高")
        type("看的一句话，", into: input)
        XCTAssertEqual(input.currentTextHeight, before, accuracy: 0.5, "一行还没满")

        type(String(repeating: "很长的一句话。", count: 60), into: input)
        harness.window.layoutIfNeeded()
        XCTAssertGreaterThan(input.currentTextHeight, before)
        XCTAssertLessThanOrEqual(input.currentTextHeight, FeedCommentInputView.maxTextHeight)
        XCTAssertTrue(input.textView.isScrollEnabled || input.currentTextHeight < FeedCommentInputView.maxTextHeight)
        harness.pop()
        harness.window.isHidden = true
    }

    /// 提示条不能盖住输入框：输入框在、键盘没出来 → 抬高一个输入框；键盘出来了 → 放到上面；输入框收起 → 和别的页面一样。
    @MainActor
    func testToastsStayOffTheCommentBox() async throws {
        typealias VC = FeedPostDetailViewController
        XCTAssertEqual(VC.toastPlacement(inputVisible: false, keyboardUp: false), .bottom)
        XCTAssertEqual(VC.toastPlacement(inputVisible: false, keyboardUp: true), .bottom)
        XCTAssertEqual(VC.toastPlacement(inputVisible: true, keyboardUp: false), .aboveInput)
        XCTAssertEqual(VC.toastPlacement(inputVisible: true, keyboardUp: true), .top)

        let source = quickSource()
        source.simulation.failsComments = true
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let open = try await openComments(of: "sample-1", source: source, harness: harness)
        type("会失败", into: open.commentInput)
        open.commentInput.sendButton.sendActions(for: .touchUpInside)
        await open.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(open.lastToastText)
        XCTAssertEqual(open.lastToastPlacement, .aboveInput, "输入框在、键盘没出来（进程内没有键盘）")
        harness.pop()
        harness.window.isHidden = true
    }

    /// 发送按钮的几种状态都来自逻辑层：空 / 只有空白 → 灰；有字 → 可点；发送中 → 按钮换成转圈、输入框不能改。
    @MainActor
    func testTheSendButtonFollowsTheSendStates() async throws {
        let source = quickSource()
        source.simulation.postCommentLatencyNanos = 400_000_000
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let detail = try await openComments(of: "sample-1", source: source, harness: harness)
        let input = detail.commentInput
        XCTAssertFalse(input.sendButton.isEnabled, "空")
        type("   ", into: input)
        XCTAssertFalse(input.sendButton.isEnabled, "只有空白")
        type("你好", into: input)
        XCTAssertTrue(input.sendButton.isEnabled)

        input.sendButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(input.sendButton.isHidden, "发送中：按钮换成转圈")
        XCTAssertFalse(input.textView.isEditable, "发送中：不能改")
        XCTAssertEqual(input.presentation?.submit, .sending)
        await detail.detailStore.waitForTasks()
        XCTAssertFalse(input.sendButton.isHidden)
        XCTAssertTrue(input.textView.isEditable)
        XCTAssertEqual(input.textView.text, "", "发送成功：清空")
        XCTAssertFalse(input.sendButton.isEnabled)
        harness.pop()
        harness.window.isHidden = true
    }

    /// 发出去的评论出现在评论区最后；详情上的评论数和列表那一行的评论数一起 +1；弹「已发布」。
    @MainActor
    func testAPostedCommentShowsUpAndTheListCountFollows() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 1))
        await detail.detailStore.waitForTasks()
        let before = harness.feed.pages[0].rows[1].card.stats.comments
        type("来了", into: detail.commentInput)
        detail.commentInput.sendButton.sendActions(for: .touchUpInside)
        await detail.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(detail.detailStore.state.comments.last?.text, "来了")
        XCTAssertEqual(harness.feed.pages[0].rows[1].card.stats.comments, before + 1)
        XCTAssertEqual(detail.lastToastText, OWSLocalizedString("TELLOMI_FEED_COMPOSE_PUBLISHED", comment: ""))
        harness.pop()
        harness.window.isHidden = true
    }

    /// 评论 500 个码点：敲满后再敲被拦下（文字不变、计数 0）；粘贴超出的部分被截掉，计数变红。
    @MainActor
    func testTheBoxStopsAt500CodePointsAndShowsTheCounter() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let detail = try await openComments(of: "sample-1", source: source, harness: harness)
        let input = detail.commentInput
        XCTAssertTrue(input.counterLabel.isHidden, "离上限还远：不显示计数")

        XCTAssertTrue(type(String(repeating: "a", count: 460), into: input))
        XCTAssertFalse(input.counterLabel.isHidden, "剩余 ≤ 50 才显示计数：460 → 40")
        XCTAssertEqual(input.counterLabel.text, "40")

        XCTAssertFalse(type(String(repeating: "b", count: 100), into: input), "粘贴超出：被截")
        XCTAssertEqual(FeedTextCap.count(input.textView.text), 500)
        XCTAssertEqual(input.counterLabel.text, "0")
        XCTAssertFalse(input.counterLabel.isHidden)
        XCTAssertFalse(type("c", into: input), "满了：再敲被拦下")
        XCTAssertEqual(FeedTextCap.count(input.textView.text), 500)
        XCTAssertEqual(detail.detailStore.state.draft, input.textView.text, "store 里的草稿和输入框一致")
        XCTAssertTrue(input.sendButton.isEnabled, "刚好 500 可以发")
        harness.pop()
        harness.window.isHidden = true
    }

    /// 点一条评论回复它：输入框上面出现「正在回复 xxx」，取消后回到直接评论。
    @MainActor
    func testTappingACommentRepliesToItAndCancelGoesBack() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let detail = try await openComments(of: "sample-1", source: source, harness: harness)
        let input = detail.commentInput
        XCTAssertTrue(input.replyBanner.isHidden)

        let table = detail.detailTableView
        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        let target = try XCTUnwrap(detail.detailStore.state.replyTarget)
        XCTAssertFalse(input.replyBanner.isHidden)
        let name = try XCTUnwrap(target.author?.displayName)
        XCTAssertTrue(input.replyLabel.text?.contains(name) ?? false)
        XCTAssertTrue(input.textView.isEditable)

        type("回复", into: input)
        input.sendButton.sendActions(for: .touchUpInside)
        await detail.detailStore.waitForTasks()
        XCTAssertNil(detail.detailStore.state.replyTarget, "发出去后回复对象清掉")
        XCTAssertTrue(input.replyBanner.isHidden)
        XCTAssertEqual(detail.detailStore.state.comments.last?.parentId, target.id)

        table.delegate?.tableView?(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertFalse(input.replyBanner.isHidden)
        input.cancelReplyButton.sendActions(for: .touchUpInside)
        XCTAssertNil(detail.detailStore.state.replyTarget)
        XCTAssertTrue(input.replyBanner.isHidden)
        harness.pop()
        harness.window.isHidden = true
    }

    /// 发失败（样例开关）：文字还在、可以再发，弹「操作失败」；发完又回到能发的状态。
    @MainActor
    func testAFailedSendKeepsTheTextAndToasts() async throws {
        let source = quickSource()
        source.simulation.failsComments = true
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let detail = try await openComments(of: "sample-1", source: source, harness: harness)
        let input = detail.commentInput
        type("会失败", into: input)
        input.sendButton.sendActions(for: .touchUpInside)
        await detail.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(input.textView.text, "会失败")
        XCTAssertTrue(input.sendButton.isEnabled)
        XCTAssertEqual(detail.lastToastText, OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: ""))
        harness.pop()
        harness.window.isHidden = true
    }

    // MARK: - 给截图用的中间状态

    /// 样例的「已不可见」可以拖慢：先显示帖子，Card API 回来才变成「已不可见」。
    @MainActor
    func testSample7ShowsThePostFirstThenGoneWhenTheCardLatencyIsSet() async throws {
        let source = quickSource()
        source.simulation.cardLatencyNanos = 800_000_000
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let detail = try XCTUnwrap(harness.openPost(row: 7))
        XCTAssertEqual(detail.detailStore.state.post.id, "sample-7")
        XCTAssertFalse(detail.detailTableView.isHidden, "Card API 还没回来：显示帖子")
        await detail.detailStore.waitForTasks()
        detail.view.layoutIfNeeded()
        XCTAssertTrue(detail.detailTableView.isHidden, "回来了：已不可见")
        harness.pop()
        harness.window.isHidden = true
    }
    // MARK: - 「···」菜单

    /// 别人的帖子：导航栏有「···」（「不感兴趣」和「举报」）；评论关了的帖子照样有。
    @MainActor
    func testTheNavigationMenuHasNotInterestedForSomeoneElsesPost() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let open = try await openComments(of: "sample-1", source: source, harness: harness)
        XCTAssertEqual(open.shownPostMenu, [.notInterested, .report])
        XCTAssertNotNil(open.navigationItem.rightBarButtonItem)
        XCTAssertEqual(
            FeedPostDetailViewController.menuTitle(for: .notInterested),
            OWSLocalizedString("TELLOMI_FEED_NOT_INTERESTED", comment: ""),
        )
        harness.pop()

        let gone = try await openComments(of: "sample-7", source: source, harness: harness)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(gone.shownPostMenu, [], "帖子已不可见：没有菜单")
        XCTAssertNil(gone.navigationItem.rightBarButtonItem)
        harness.pop()
        harness.window.isHidden = true
    }

    /// 长按评论：自己的评论有「删除」，别人的评论有「举报」。删除先确认，确认了才删。
    @MainActor
    func testDeletingMyCommentAsksFirstAndOnlyThenDeletes() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let open = try await openComments(of: "sample-1", source: source, harness: harness)
        type("我的评论", into: open.commentInput)
        open.commentInput.sendButton.sendActions(for: .touchUpInside)
        await open.detailStore.waitForTasks()
        harness.window.layoutIfNeeded()

        let mine = try XCTUnwrap(open.detailStore.state.comments.last)
        XCTAssertTrue(mine.viewer.isAuthor)
        XCTAssertEqual(open.commentMenuItems(for: mine), [.deleteComment])
        let other = try XCTUnwrap(open.detailStore.state.comments.first)
        XCTAssertEqual(open.commentMenuItems(for: other), [.report], "别人的评论可以举报")

        let table = open.detailTableView
        let lastRow = table.numberOfRows(inSection: 0) - 1
        XCTAssertNotNil(open.tableView(table, contextMenuConfigurationForRowAt: IndexPath(row: lastRow, section: 0), point: .zero), "长按自己的评论有菜单")
        XCTAssertNotNil(open.tableView(table, contextMenuConfigurationForRowAt: IndexPath(row: 1, section: 0), point: .zero), "别人的评论长按有「举报」")
        XCTAssertNil(open.tableView(table, contextMenuConfigurationForRowAt: IndexPath(row: 0, section: 0), point: .zero), "帖子那一行不弹评论菜单")

        var asked = [FeedDetailMenuItem]()
        var proceed: (() -> Void)?
        open.confirmDestructive = { item, go in
            asked.append(item)
            proceed = go
        }
        let before = open.detailStore.state.comments.count
        open.handleMenuItem(.deleteComment, comment: mine)
        await open.detailStore.waitForTasks()
        XCTAssertEqual(asked, [.deleteComment])
        XCTAssertEqual(open.detailStore.state.comments.count, before, "还没确认：不删")

        proceed?()
        await open.detailStore.waitForTasks()
        XCTAssertEqual(open.detailStore.state.comments.count, before - 1)
        XCTAssertFalse(open.detailStore.state.comments.contains { $0.id == mine.id })
        harness.pop()
        harness.window.isHidden = true
    }

    /// 菜单文字和确认问题都是本地化过的，不是键名。
    @MainActor
    func testMenuTextsAreLocalizedNotKeys() {
        for item in [FeedDetailMenuItem.notInterested, .report, .deleteComment, .deletePost] {
            let title = FeedPostDetailViewController.menuTitle(for: item)
            XCTAssertFalse(title.isEmpty)
            XCTAssertFalse(title.hasPrefix("TELLOMI_"), "\(item) 的菜单文字没有翻译")
        }
        for item in [FeedDetailMenuItem.deleteComment, .deletePost] {
            let title = FeedPostDetailViewController.confirmationTitle(for: item)
            XCTAssertFalse(title.isEmpty)
            XCTAssertFalse(title.hasPrefix("TELLOMI_"))
        }
    }

    // MARK: - 「···」做完之后：提示、关页

    /// 新的几种提示都有本地化文字（不是键名），限速带秒数、没有秒数各一句。
    @MainActor
    func testTheNewNoticesHaveLocalizedToasts() {
        typealias VC = FeedPostDetailViewController
        for notice in [FeedPostDetailState.Notice.commentDeleted, .reported, .throttled, .hideProfileRequired, .failed] {
            let text = VC.toastText(for: notice)
            XCTAssertNotNil(text, "\(notice)")
            XCTAssertFalse(text?.hasPrefix("TELLOMI_") ?? true)
        }
        XCTAssertTrue(VC.toastText(for: .throttled, retryAfterSeconds: 30)?.contains("30") ?? false, "带秒数")
        XCTAssertFalse(VC.toastText(for: .throttled)?.contains("%") ?? true)
        XCTAssertNotEqual(VC.toastText(for: .throttled), VC.toastText(for: .throttled, retryAfterSeconds: 30))
        XCTAssertNil(VC.toastText(for: .holdToRecord))
    }

    /// 删自己的评论成功：提示「评论已删除」，评论没了；失败：评论留着，提示「操作失败」；限速：提示带秒数。
    @MainActor
    func testDeleteCommentToastsForSuccessFailureAndThrottle() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let open = try await openComments(of: "sample-1", source: source, harness: harness)
        open.confirmDestructive = { _, proceed in proceed() }

        func postMine(_ text: String) async throws -> FeedCard {
            type(text, into: open.commentInput)
            open.commentInput.sendButton.sendActions(for: .touchUpInside)
            await open.detailStore.waitForTasks()
            try await Task.sleep(nanoseconds: 50_000_000)
            return try XCTUnwrap(open.detailStore.state.comments.last)
        }

        let first = try await postMine("第一条")
        source.simulation.failsDeletes = true
        open.handleMenuItem(.deleteComment, comment: first)
        await open.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(open.lastToastText, OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: ""))
        XCTAssertTrue(open.detailStore.state.comments.contains { $0.id == first.id }, "失败：留着")

        source.simulation.failsDeletes = false
        source.simulation.throttledRetryAfterSeconds = 42
        open.handleMenuItem(.deleteComment, comment: first)
        await open.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(open.lastToastText?.contains("42") ?? false, "限速：说要等几秒")
        XCTAssertTrue(open.detailStore.state.comments.contains { $0.id == first.id })

        source.simulation.throttledRetryAfterSeconds = nil
        open.handleMenuItem(.deleteComment, comment: first)
        await open.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(open.lastToastText, OWSLocalizedString("TELLOMI_FEED_COMMENT_DELETED", comment: ""))
        XCTAssertFalse(open.detailStore.state.comments.contains { $0.id == first.id })
        harness.pop()
        harness.window.isHidden = true
    }

    /// 「不感兴趣」成了：详情页关掉，列表那一行换成可撤销的反馈卡。失败：留在页面、提示「操作失败」。
    @MainActor
    func testNotInterestedClosesThePageAndTheListRowBecomesAFeedbackCard() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }
        let id = harness.store.tab(.recommend).cards[2].id

        source.simulation.failsNotInterested = true
        let failing = try XCTUnwrap(harness.openPost(row: 2))
        failing.handleMenuItem(.notInterested)
        await failing.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(failing.closeReason)
        XCTAssertTrue(harness.navigation.topViewController === failing, "失败：还在这一页")
        XCTAssertEqual(failing.lastToastText, OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: ""))
        XCTAssertFalse(harness.store.hiddenIds.contains(id))
        harness.pop()

        source.simulation.failsNotInterested = false
        let detail = try XCTUnwrap(harness.openPost(row: 2))
        detail.handleMenuItem(.notInterested)
        await detail.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(detail.closeReason, .notInterested)
        XCTAssertTrue(harness.navigation.topViewController === harness.feed, "成了：页面关掉")
        XCTAssertTrue(harness.store.hiddenIds.contains(id), "列表那一行是反馈卡")
        harness.window.isHidden = true
    }

    /// 动态被关了（404 feed_hidden）：页面关掉、不弹「操作失败」；限速时留在页面并提示秒数。
    @MainActor
    func testFeedHiddenClosesThePageAndThrottleKeepsIt() async throws {
        let source = quickSource()
        let harness = await makeHarness(source: source)
        defer { harness.window.isHidden = true }

        source.simulation.throttledRetryAfterSeconds = 15
        let throttled = try XCTUnwrap(harness.openPost(row: 1))
        throttled.handleMenuItem(.notInterested)
        await throttled.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(throttled.closeReason)
        XCTAssertTrue(throttled.lastToastText?.contains("15") ?? false)
        harness.pop()

        source.simulation.throttledRetryAfterSeconds = nil
        source.simulation.feedHidden = true
        let hidden = try XCTUnwrap(harness.openPost(row: 1))
        hidden.handleMenuItem(.notInterested)
        await hidden.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(hidden.closeReason, .feedHidden)
        XCTAssertNil(hidden.lastToastText, "不弹「操作失败」")
        XCTAssertTrue(harness.navigation.topViewController === harness.feed)
        harness.window.isHidden = true
    }

}
