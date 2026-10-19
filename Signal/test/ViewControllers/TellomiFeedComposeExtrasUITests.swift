//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 发布页扩展的界面检查（UIKit，只在 Mac 上跑）：编辑页、选人页、「我的动态」的编辑入口和草稿入口。
/// 规则本身（谁能选、几分钟内能改、草稿入口写什么）在 `TellomiFeedComposeExtrasTests`（Linux 上也跑）。
final class TellomiFeedComposeExtrasUITests: XCTestCase {

    @MainActor
    private func show(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = OWSNavigationController(rootViewController: controller)
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - 编辑页

    @MainActor
    func testEditPageHidesWhatEditingCannotChangeAndSavesThroughEditPost() async throws {
        let sample = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        var published = [String]()
        let target = FeedEditTarget(id: "mine-seed-p1", kind: "post", title: nil, text: "Waiting for review (sample)", publishedAt: nil)
        let compose = FeedComposeViewController(source: sample, editTarget: target, articleDrafts: InMemoryFeedArticleDrafts(), extrasEnabled: true) { published.append($0) }
        let window = show(compose)
        defer { window.isHidden = true }

        XCTAssertTrue(compose.isEditingPost)
        XCTAssertFalse(compose.navigationItem.titleView is FeedKindSwitch)
        XCTAssertEqual((compose.navigationItem.titleView as? UILabel)?.text, OWSLocalizedString("TELLOMI_FEED_COMPOSE_EDIT_POST", comment: ""))
        XCTAssertEqual(compose.navigationItem.rightBarButtonItem?.title, OWSLocalizedString("TELLOMI_FEED_COMPOSE_SAVE", comment: ""))
        XCTAssertEqual(compose.layout.publishButton, .save)
        XCTAssertFalse(compose.layout.showsVisibilityButton)
        XCTAssertFalse(compose.layout.showsPhotoButton)
        XCTAssertEqual(compose.navigationItem.rightBarButtonItem?.isEnabled, false, "没改动不能保存")

        compose.setText("Rewritten in the sample")
        XCTAssertEqual(compose.navigationItem.rightBarButtonItem?.isEnabled, true)
        compose.publish()
        await waitUntil { !published.isEmpty }
        XCTAssertEqual(published, [FeedMyPost.statePending], "样例里这条还在审核中，保存后状态不变")
        let page = try await sample.myPosts(before: nil)
        XCTAssertEqual(page.posts.first { $0.id == "mine-seed-p1" }?.text, "Rewritten in the sample")
    }

    @MainActor
    func testEditAfterTheWindowClosedShowsTheClosedToastAndStaysOpen() async throws {
        let sample = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        sample.simulation.editsWindowClosed = true
        var published = [String]()
        let target = FeedEditTarget(id: "mine-seed-p1", kind: "post", title: nil, text: "x", publishedAt: nil)
        let compose = FeedComposeViewController(source: sample, editTarget: target, articleDrafts: InMemoryFeedArticleDrafts(), extrasEnabled: true) { published.append($0) }
        let window = show(compose)
        defer { window.isHidden = true }
        compose.setText("changed")
        compose.publish()
        await waitUntil { !compose.isPublishing && sample.simulation.editsWindowClosed }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(published.isEmpty)
        XCTAssertEqual(compose.navigationItem.rightBarButtonItem?.isEnabled, true, "页面还开着，可以改回去 / 关掉")
    }

    // MARK: - 发布页：可见范围和草稿

    @MainActor
    func testPeopleOptionsOpenThePickerOnlyWhenASourceAndTheEngineFeatureExist() async {
        let withPicker = FeedComposeViewController(
            source: SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0),
            articleDrafts: InMemoryFeedArticleDrafts(),
            features: StaticFeedFeatureGate([FeedFeature.audienceTokens]),
            audienceCandidates: StaticFeedAudienceCandidates(FeedAudienceSamples.candidates()),
            extrasEnabled: true,
        ) { _ in }
        let window = show(withPicker)
        defer { window.isHidden = true }
        await waitUntil { withPicker.layout.visibilityOptions.contains { $0.availability == .picksPeople(count: 0) } }
        XCTAssertEqual(withPicker.layout.visibilityOptions.map(\.availability), [.available, .available, .picksPeople(count: 0), .picksPeople(count: 0), .available])

        let without = FeedComposeViewController(source: SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)) { _ in }
        let other = show(without)
        defer { other.isHidden = true }
        XCTAssertEqual(without.layout.visibilityOptions.map(\.availability), [.available, .available, .comingSoon, .comingSoon, .available], "没接选人来源：和之前一样显示还不能选")
    }

    @MainActor
    func testWithExtrasOffAnArticleDraftStaysInMemoryAndIsNotRestored() async {
        let first = FeedComposeViewController(source: SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0), extrasEnabled: false) { _ in }
        let window = show(first)
        defer { window.isHidden = true }
        first.setKind(.article)
        first.setTitle("T")
        first.setText("B")
        let second = FeedComposeViewController(source: SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0), extrasEnabled: false) { _ in }
        second.loadViewIfNeeded()
        XCTAssertEqual(second.draft.kind, .post)
        XCTAssertTrue(second.draft.isEmpty)
    }

    @MainActor
    func testWithExtrasOnTheSavedArticleComesBackWhenReopened() async {
        let drafts = InMemoryFeedArticleDrafts()
        let first = FeedComposeViewController(source: SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0), articleDrafts: drafts, extrasEnabled: true) { _ in }
        let window = show(first)
        first.setKind(.article)
        first.setTitle("T")
        first.setText("B")
        window.isHidden = true
        let second = FeedComposeViewController(source: SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0), articleDrafts: drafts, extrasEnabled: true) { _ in }
        let other = show(second)
        defer { other.isHidden = true }
        XCTAssertEqual(second.draft.kind, .article)
        XCTAssertEqual(second.draft.title, "T")
        XCTAssertEqual(second.draft.text, "B")
        XCTAssertTrue(second.layout.showsDiscardDraft)
    }

    // MARK: - 选人页

    @MainActor
    func testPickerListsSelectsAndReturnsThePeople() async throws {
        var result: [FeedAudienceMember]?
        let picker = FeedAudiencePickerViewController(
            visibility: .include,
            preselected: [],
            source: StaticFeedAudienceCandidates(FeedAudienceSamples.candidates(count: 5)),
            maxMembers: 2,
        ) { result = $0 }
        let window = show(picker)
        defer { window.isHidden = true }
        let done = try XCTUnwrap(picker.navigationItem.rightBarButtonItem)
        XCTAssertFalse(done.isEnabled, "一个都没选不能完成")
        XCTAssertEqual(picker.title, OWSLocalizedString("TELLOMI_FEED_AUDIENCE_TITLE_INCLUDE", comment: ""))

        await waitUntil { picker.candidateCount == 5 }
        picker.toggle(recipientId: 1000)
        picker.toggle(recipientId: 1002)
        picker.toggle(recipientId: 1003)
        XCTAssertEqual(picker.selectedCount, 2, "最多 2 人")
        XCTAssertTrue(done.isEnabled)
        if let action = done.action { _ = done.target?.perform(action, with: done) }
        await waitUntil { result != nil }
        XCTAssertEqual(result?.map(\.recipientId), [1000, 1002])
    }

    @MainActor
    func testExcludePickerUsesItsOwnTitleAndHint() {
        XCTAssertNotEqual(FeedAudiencePickerViewController.title(for: .exclude), FeedAudiencePickerViewController.title(for: .include))
        XCTAssertNotEqual(FeedAudiencePickerViewController.hint(for: .exclude), FeedAudiencePickerViewController.hint(for: .include))
        XCTAssertTrue(FeedAudiencePickerViewController.countText(selected: 3, maximum: 500).contains("500"))
    }

    // MARK: - 我的动态

    @MainActor
    private func openMyPosts(extras: Bool, drafts: FeedArticleDrafts? = nil) async -> (FeedMyPostsViewController, UIWindow) {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source, profilePageEnabled: false)
        let navigation = OWSNavigationController(rootViewController: feed)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        let page = FeedMyPostsViewController(source: source, feed: feed.store, composeExtras: extras, articleDrafts: extras ? (drafts ?? InMemoryFeedArticleDrafts()) : nil)
        navigation.pushViewController(page, animated: false)
        page.loadViewIfNeeded()
        await page.store.waitForTasks()
        window.layoutIfNeeded()
        return (page, window)
    }

    @MainActor
    private func swipeTitles(_ page: FeedMyPostsViewController, id: String) -> [String] {
        guard let index = page.rows.firstIndex(where: { if case .post(let row) = $0 { return row.id == id }; return false }),
              let configuration = page.tableView(page.postsTableView, trailingSwipeActionsConfigurationForRowAt: IndexPath(row: index, section: 0)) else { return [] }
        return configuration.actions.compactMap(\.title)
    }

    @MainActor
    func testSwipeShowsEditOnlyForPostsInsideTheWindowAndOnlyWithExtras() async {
        let (page, window) = await openMyPosts(extras: true)
        defer { window.isHidden = true }
        XCTAssertTrue(swipeTitles(page, id: "mine-seed-p1").contains(FeedMyPostsViewController.editTitle), "审核中 10 分钟前：能编辑")
        XCTAssertFalse(swipeTitles(page, id: "mine-seed-r1").contains(FeedMyPostsViewController.editTitle), "未通过不能编辑")
        XCTAssertFalse(swipeTitles(page, id: "mine-seed-1").contains(FeedMyPostsViewController.editTitle), "发布很久了")

        let (off, offWindow) = await openMyPosts(extras: false)
        defer { offWindow.isHidden = true }
        XCTAssertFalse(swipeTitles(off, id: "mine-seed-p1").contains(FeedMyPostsViewController.editTitle), "扩展关着：没有编辑")
    }

    @MainActor
    func testEditSavedToastTextsDifferForPendingAndPublished() {
        XCTAssertNotEqual(
            FeedMyPostsViewController.editToastText(publishState: FeedCreatePostResponse.statePending),
            FeedMyPostsViewController.editToastText(publishState: FeedCreatePostResponse.statePublished),
        )
    }

    @MainActor
    func testDraftEntryRowShowsOnlyWithExtrasAndASavedArticle() async {
        let drafts = InMemoryFeedArticleDrafts()
        let (page, window) = await openMyPosts(extras: true, drafts: drafts)
        defer { window.isHidden = true }
        XCTAssertNil(page.postsTableView.tableHeaderView, "没有草稿：没有入口")
        drafts.save(FeedSavedArticle(title: "周末去山里", text: "正文"))
        page.refreshDraftEntry()
        XCTAssertNotNil(page.postsTableView.tableHeaderView)
        drafts.clear()
        page.refreshDraftEntry()
        XCTAssertNil(page.postsTableView.tableHeaderView)
    }
}
