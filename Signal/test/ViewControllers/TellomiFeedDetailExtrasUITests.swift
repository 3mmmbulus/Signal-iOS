//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 详情页补全的界面检查（UIKit，`TellomiFeed.isDetailExtrasEnabled`，默认关）：投票、转发 / 收藏、待审回复的批准 / 拒绝、语音评论、定位到评论、「编辑」。
/// 样例：`mine-seed-2`（单选投票）、`mine-seed-3`（多选）；`mine-seed-N` 的评论是「普通 / 等我批准 / 语音」三条。
final class TellomiFeedDetailExtrasUITests: XCTestCase {

    private final class FakeSaved: FeedSavedMessages {
        func add(_ card: FeedCard) async throws {}
        func remove(contentId: String) async throws {}
    }

    @MainActor
    private func open(
        _ id: String,
        extras: Bool,
        saved: FeedSavedMessages? = nil,
        focus: String? = nil,
        freshlyPublished: Bool = false
    ) async throws -> (FeedPostDetailViewController, UIWindow, SampleFeedSource) {
        // 「刚发布」：样例的 `mine-seed-1` 是 490 分钟前发的，把样例的「现在」往后拨 489 分钟，它就是 1 分钟前发的。
        // （不能只改传进来的那张卡片：打开页面后详情会再向 Card API 取一次，换回样例里原来的时间，「编辑」就没了。）
        let offset: TimeInterval = freshlyPublished ? 489 * 60 : 0
        let source = SampleFeedSource(now: { Date().addingTimeInterval(offset) }, commentsLatencyNanos: 0)
        let cardOptional = try await source.card(contentId: id)
        let card = try XCTUnwrap(cardOptional)
        let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: false, articleReader: false, extras: extras, savedMessages: saved, focusCommentId: focus)
        let navigation = OWSNavigationController(rootViewController: detail)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        detail.loadViewIfNeeded()
        await detail.detailStore.waitForTasks()
        window.layoutIfNeeded()
        return (detail, window, source)
    }

    @MainActor
    func testTheFlagIsOffByDefaultAndNothingChanges() async throws {
        XCTAssertFalse(TellomiFeed.isDetailExtrasEnabled, "Default OFF (no one turned it on in tests)")
        let (detail, window, _) = try await open("mine-seed-2", extras: false)
        defer { window.isHidden = true }
        XCTAssertNil(detail.pollCell)
        XCTAssertNil(detail.actionsCell)
        let voice = try XCTUnwrap(detail.commentCell("mine-seed-2-voice"))
        XCTAssertFalse(voice.isVoiceRowVisible, "Off: a voice comment is just its transcript as text")
        let held = try XCTUnwrap(detail.commentCell("mine-seed-2-held1"))
        XCTAssertFalse(held.isModerationVisible)
        XCTAssertFalse(detail.shownPostMenu.contains(.edit))
    }

    @MainActor
    func testEveryNewNoticeHasAToastText() {
        for notice in [FeedPostDetailState.Notice.saved, .reposted, .edited, .editedPending, .commentNotFound] {
            XCTAssertNotNil(FeedPostDetailViewController.toastText(for: notice), "\(notice)")
        }
    }

    // MARK: - 投票

    @MainActor
    func testASingleChoicePollVotesOnTapAndThenShowsResults() async throws {
        let (detail, window, _) = try await open("mine-seed-2", extras: true)
        defer { window.isHidden = true }
        let cell = try XCTUnwrap(detail.pollCell)
        XCTAssertEqual(cell.optionViews.count, 3)
        cell.tapped(1)
        await detail.detailStore.waitForTasks()
        window.layoutIfNeeded()
        XCTAssertEqual(detail.detailStore.state.post.pollState?.voted, [1])
        let after = try XCTUnwrap(detail.pollCell)
        XCTAssertEqual(after.optionViews.count, 3)
        after.tapped(0)
        await detail.detailStore.waitForTasks()
        XCTAssertEqual(detail.detailStore.state.post.pollState?.voted, [1], "Voted once: no change")
    }

    @MainActor
    func testAMultiChoicePollNeedsTheVoteButton() async throws {
        let (detail, window, source) = try await open("mine-seed-3", extras: true)
        defer { window.isHidden = true }
        let cell = try XCTUnwrap(detail.pollCell)
        cell.tapped(0)
        cell.tapped(2)
        await detail.detailStore.waitForTasks()
        XCTAssertNil(detail.detailStore.state.post.pollState?.voted.first, "Ticking alone sends nothing")
        XCTAssertEqual(source.detailExtras.calls, [])
        cell.onVote?([0, 2])
        await detail.detailStore.waitForTasks()
        XCTAssertEqual(source.detailExtras.calls, ["vote:mine-seed-3:0,2"])
    }

    // MARK: - 转发 / 收藏

    @MainActor
    func testRepostButtonTogglesAndSaveIsHiddenWithoutSavedMessages() async throws {
        let (detail, window, source) = try await open("mine-seed-1", extras: true)
        defer { window.isHidden = true }
        let cell = try XCTUnwrap(detail.actionsCell)
        XCTAssertFalse(cell.repostButton.isHidden)
        XCTAssertTrue(cell.saveButton.isHidden, "No Saved Messages implementation yet: no Save button")
        cell.onRepost?()
        await detail.detailStore.waitForTasks()
        XCTAssertTrue(detail.detailStore.state.post.viewer.reposted)
        XCTAssertEqual(source.detailExtras.calls, ["repost:mine-seed-1:true"])
        XCTAssertEqual(detail.actionsCell?.repostButton.configuration?.title, FeedDetailActionsCell.repostTitle(reposted: true))
    }

    @MainActor
    func testSaveButtonShowsWhenThereIsASavedMessagesImplementation() async throws {
        let (detail, window, source) = try await open("mine-seed-1", extras: true, saved: FakeSaved())
        defer { window.isHidden = true }
        let cell = try XCTUnwrap(detail.actionsCell)
        XCTAssertFalse(cell.saveButton.isHidden)
        cell.onSave?()
        await detail.detailStore.waitForTasks()
        XCTAssertTrue(detail.detailStore.state.post.viewer.saved)
        XCTAssertEqual(source.detailExtras.calls, ["save:mine-seed-1:true"])
    }

    // MARK: - 待审回复

    @MainActor
    func testTheAuthorSeesApproveAndDeclineOnAHeldReply() async throws {
        let (detail, window, _) = try await open("mine-seed-1", extras: true)
        defer { window.isHidden = true }
        let held = try XCTUnwrap(detail.commentCell("mine-seed-1-held1"))
        XCTAssertTrue(held.isModerationVisible)
        XCTAssertFalse(held.approveButtonForTesting.isHidden)
        held.onApprove?()
        await detail.detailStore.waitForTasks()
        window.layoutIfNeeded()
        let approved = try XCTUnwrap(detail.commentCell("mine-seed-1-held1"))
        XCTAssertFalse(approved.isModerationVisible)
    }

    @MainActor
    func testDecliningAsksFirstAndThenDeletesTheReply() async throws {
        let (detail, window, _) = try await open("mine-seed-1", extras: true)
        defer { window.isHidden = true }
        var asked = 0
        var proceed: (() -> Void)?
        detail.confirmDecline = { action in asked += 1; proceed = action }
        let held = try XCTUnwrap(detail.commentCell("mine-seed-1-held1"))
        held.onDecline?()
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(detail.detailStore.state.comments.contains { $0.id == "mine-seed-1-held1" }, "Not deleted before the answer")
        proceed?()
        await detail.detailStore.waitForTasks()
        XCTAssertFalse(detail.detailStore.state.comments.contains { $0.id == "mine-seed-1-held1" })
    }

    @MainActor
    func testTappingAHeldReplyDoesNotStartAReply() async throws {
        let (detail, window, _) = try await open("mine-seed-1", extras: true)
        defer { window.isHidden = true }
        let table = detail.detailTableView
        let heldIndex = try XCTUnwrap(table.visibleCells.firstIndex { ($0 as? FeedCommentCell)?.isModerationVisible == true })
        let indexPath = try XCTUnwrap(table.indexPath(for: table.visibleCells[heldIndex]))
        table.delegate?.tableView?(table, didSelectRowAt: indexPath)
        XCTAssertNil(detail.detailStore.state.replyTarget)
    }

    // MARK: - 语音评论

    @MainActor
    func testAVoiceCommentShowsItsRowAndTranscriptAndAFailedPlayShowsTheError() async throws {
        let (detail, window, _) = try await open("mine-seed-1", extras: true)
        defer { window.isHidden = true }
        let cell = try XCTUnwrap(detail.commentCell("mine-seed-1-voice"))
        XCTAssertTrue(cell.isVoiceRowVisible)
        XCTAssertEqual(cell.voiceTimeText, "0:04")
        // 样例的配置没有 media_base_url，播不了：显示「播放失败」，不崩
        cell.voiceButtonForTesting.sendActions(for: .touchUpInside)
        await detail.waitForVoice()
        XCTAssertEqual(detail.voicePlayback.failedKey, "sample/voice/mine-seed-1.m4a")
        XCTAssertTrue(try XCTUnwrap(detail.commentCell("mine-seed-1-voice")).isVoiceFailedVisible)
    }

    // MARK: - 定位到评论

    @MainActor
    func testOpeningWithACommentIdScrollsToItAndHighlightsIt() async throws {
        let (detail, window, _) = try await open("mine-seed-1", extras: true, focus: "mine-seed-1-voice")
        defer { window.isHidden = true }
        for _ in 0..<50 where detail.highlightedCommentId == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(detail.highlightedCommentId, "mine-seed-1-voice")
        XCTAssertNil(detail.detailStore.state.scrollTarget, "The page took the target")
    }

    @MainActor
    func testAMissingCommentShowsTheNotice() async throws {
        let (detail, window, _) = try await open("mine-seed-1", extras: true, focus: "nope")
        defer { window.isHidden = true }
        for _ in 0..<50 where detail.lastToastText == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(detail.lastToastText, FeedPostDetailViewController.toastText(for: .commentNotFound))
        XCTAssertNil(detail.highlightedCommentId)
    }

    @MainActor
    func testTheFocusIsIgnoredWhenTheSwitchIsOff() async throws {
        let (detail, window, _) = try await open("mine-seed-1", extras: false, focus: "mine-seed-1-voice")
        defer { window.isHidden = true }
        XCTAssertNil(detail.detailStore.state.focusCommentId)
        XCTAssertNil(detail.detailStore.state.scrollTarget)
        XCTAssertNil(detail.highlightedCommentId)
    }

    // MARK: - 编辑

    @MainActor
    func testEditIsInTheMenuInsideTheWindowAndOpensTheComposePage() async throws {
        let (detail, window, _) = try await open("mine-seed-1", extras: true, freshlyPublished: true)
        defer { window.isHidden = true }
        XCTAssertEqual(detail.shownPostMenu.first, .edit)
        XCTAssertEqual(FeedPostDetailViewController.menuTitle(for: .edit), OWSLocalizedString("TELLOMI_FEED_MINE_EDIT", comment: ""))
        detail.handleMenuItem(.edit)
        XCTAssertNotNil(detail.presentedEditor)
    }

    @MainActor
    func testEditIsMissingOutsideTheWindowOrWithTheSwitchOff() async throws {
        let (late, window, _) = try await open("mine-seed-1", extras: true)   // 样例里这条是很久以前发的
        defer { window.isHidden = true }
        XCTAssertFalse(late.shownPostMenu.contains(.edit))
        late.handleMenuItem(.edit)
        XCTAssertNil(late.presentedEditor)

        let (off, window2, _) = try await open("mine-seed-1", extras: false, freshlyPublished: true)
        defer { window2.isHidden = true }
        XCTAssertFalse(off.shownPostMenu.contains(.edit))
        off.handleMenuItem(.edit)
        XCTAssertNil(off.presentedEditor)
    }
}
