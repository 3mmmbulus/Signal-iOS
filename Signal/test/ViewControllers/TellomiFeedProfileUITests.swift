//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 作者主页的界面检查（UIKit）：在测试进程里放一个真的 `FeedViewController`（样例数据）+ 导航栏，推一个主页。
/// 样例主页：`s-1` 山风（已关注）、`s-2` 小满（私密）、`s-3` 阿禾（已关注）、`s-4` 周末烘焙（没关注）、`s-5` 夜跑的猫（另一个内容区域）、`s-me` 自己。
/// 各种失败 / 慢 / 限速用 `source.simulation` 切，截图方法见报告。
final class TellomiFeedProfileUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
        let source: SampleFeedSource

        func openProfile(_ id: String, wait: Bool = true) async -> FeedProfileViewController {
            let profile = FeedProfileViewController(profileId: id, source: source, feed: feed.store)
            navigation.pushViewController(profile, animated: false)
            profile.loadViewIfNeeded()
            window.layoutIfNeeded()
            if wait {
                await profile.store.waitForTasks()
                window.layoutIfNeeded()
            }
            return profile
        }
    }

    @MainActor
    private func makeHarness() async -> Harness {
        let source = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source)
        let navigation = OWSNavigationController(rootViewController: feed)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        await feed.store.loadConfig()
        await feed.store.waitForLoad(.recommend)
        window.layoutIfNeeded()
        return Harness(feed: feed, navigation: navigation, window: window, source: source)
    }

    @MainActor
    private func header(of profile: FeedProfileViewController) -> FeedProfileHeaderCell? {
        profile.profileTableView.layoutIfNeeded()
        return profile.profileTableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? FeedProfileHeaderCell
    }

    private func settle(_ profile: FeedProfileViewController) async throws {
        await profile.store.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    // MARK: - 显示

    @MainActor
    func testAFollowedProfileShowsHeaderThenThePostsAndPagesOnDemand() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let profile = await harness.openProfile("s-1")

        XCTAssertEqual(profile.presentation.page, .content)
        XCTAssertEqual(profile.rows.first, .header)
        XCTAssertEqual(profile.rows.count, 1 + SampleFeedSource.profilePostsPageSize)
        XCTAssertEqual(profile.navigationItem.title, "山风")
        let cell = try XCTUnwrap(header(of: profile))
        XCTAssertEqual(cell.followButton.configuration?.title, FeedProfileViewController.followTitle(for: .following))
        XCTAssertFalse(cell.followButton.isHidden)
        XCTAssertTrue(profile.presentation.canLoadMore)

        profile.store.loadMorePosts()
        await profile.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertGreaterThan(profile.rows.count, 1 + SampleFeedSource.profilePostsPageSize, "翻页：又来了一页")
        XCTAssertTrue(profile.presentation.posts.allSatisfy { $0.author?.profileId == "s-1" })
        harness.window.isHidden = true
    }

    @MainActor
    func testPrivateBlockedRegionAndSelfProfilesDrawTheirOwnBody() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }

        var profile = await harness.openProfile("s-2")
        XCTAssertEqual(profile.rows, [.header, .status(.privateLocked)])
        XCTAssertEqual(header(of: profile)?.followButton.configuration?.title, FeedProfileViewController.followTitle(for: .follow))
        harness.navigation.popViewController(animated: false)

        profile = await harness.openProfile("s-5")
        XCTAssertEqual(profile.rows, [.header, .status(.regionUnavailable)])
        harness.navigation.popViewController(animated: false)

        profile = await harness.openProfile("s-me")
        XCTAssertTrue(header(of: profile)?.followButton.isHidden ?? false, "自己的主页没有关注按钮")
        XCTAssertEqual(profile.presentation.menu, [])
        XCTAssertNil(profile.navigationItem.rightBarButtonItem)
        harness.navigation.popViewController(animated: false)

        profile = await harness.openProfile("nobody")
        XCTAssertEqual(profile.rows, [.status(.gone)])
        harness.window.isHidden = true
    }

    @MainActor
    func testLoadFailureShowsRetryAndThrottleSaysHowLong() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.failsProfile = true
        let profile = await harness.openProfile("s-1")
        XCTAssertEqual(profile.rows, [.status(.failed(retryAfterSeconds: nil))])

        harness.source.simulation.failsProfile = false
        harness.source.simulation.profileThrottledRetryAfterSeconds = 25
        profile.store.refresh()
        await profile.store.waitForTasks()
        XCTAssertEqual(profile.rows, [.status(.failed(retryAfterSeconds: 25))])
        let texts = FeedProfileViewController.statusTexts(for: .failed(retryAfterSeconds: 25))
        XCTAssertTrue(texts.body?.contains("25") ?? false)

        harness.source.simulation.profileThrottledRetryAfterSeconds = nil
        profile.store.refresh()
        await profile.store.waitForTasks()
        XCTAssertEqual(profile.presentation.page, .content, "重试成功")
        harness.window.isHidden = true
    }

    @MainActor
    func testFirstPostsFailureShowsRetryRow() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.failsProfilePosts = true
        let profile = await harness.openProfile("s-1")
        XCTAssertEqual(profile.rows, [.header, .status(.postsFailed)])
        harness.source.simulation.failsProfilePosts = false
        profile.store.refresh()
        await profile.store.waitForTasks()
        XCTAssertEqual(profile.rows.count, 1 + SampleFeedSource.profilePostsPageSize)
        harness.window.isHidden = true
    }

    // MARK: - 关注

    @MainActor
    func testFollowingAPublicAuthorIsOptimisticThenToastsAndUnfollowAsksFirst() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.followLatencyNanos = 150_000_000
        let profile = await harness.openProfile("s-4")
        XCTAssertEqual(profile.presentation.followButton, .follow)

        profile.followTapped()
        XCTAssertEqual(profile.presentation.followButton, .following, "先改按钮")
        XCTAssertFalse(profile.presentation.isFollowEnabled, "在路上不响应第二下")
        await profile.store.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(profile.lastToastText, OWSLocalizedString("TELLOMI_FEED_PROFILE_FOLLOWED", comment: ""))
        XCTAssertTrue(profile.presentation.isFollowEnabled)

        var asked = [FeedProfileViewController.Confirmation]()
        var proceed: (() -> Void)?
        profile.confirmDestructive = { confirmation, go in
            asked.append(confirmation)
            proceed = go
        }
        profile.followTapped()
        await profile.store.waitForTasks()
        XCTAssertEqual(asked, [.unfollow])
        XCTAssertEqual(profile.presentation.followButton, .following, "还没确认：不取消")
        proceed?()
        await profile.store.waitForTasks()
        XCTAssertEqual(profile.presentation.followButton, .follow)
        harness.window.isHidden = true
    }

    @MainActor
    func testFollowingAPrivateAuthorIsARequestAndTappingItAsksToWithdraw() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let profile = await harness.openProfile("s-2")
        profile.followTapped()
        await profile.store.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(profile.presentation.followButton, .requested)
        XCTAssertEqual(profile.lastToastText, OWSLocalizedString("TELLOMI_FEED_PROFILE_REQUESTED", comment: ""))
        XCTAssertEqual(profile.rows, [.header, .status(.privateLocked)], "批准之前还是看不到帖子")

        var asked = [FeedProfileViewController.Confirmation]()
        profile.confirmDestructive = { confirmation, _ in asked.append(confirmation) }
        profile.followTapped()
        XCTAssertEqual(asked, [.cancelRequest])
        harness.window.isHidden = true
    }

    @MainActor
    func testFollowFailureThrottleAndFeedHiddenAreToldApart() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let profile = await harness.openProfile("s-4")

        harness.source.simulation.failsFollow = true
        profile.followTapped()
        try await settle(profile)
        XCTAssertEqual(profile.lastToastText, OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: ""))
        XCTAssertEqual(profile.presentation.followButton, .follow, "改回来")

        harness.source.simulation.failsFollow = false
        harness.source.simulation.throttledRetryAfterSeconds = 17
        profile.followTapped()
        try await settle(profile)
        XCTAssertTrue(profile.lastToastText?.contains("17") ?? false)
        XCTAssertEqual(profile.presentation.followButton, .follow)

        harness.source.simulation.throttledRetryAfterSeconds = nil
        harness.source.simulation.feedHidden = true
        let before = harness.navigation.viewControllers.count
        profile.followTapped()
        try await settle(profile)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(profile.didClose, "动态被关了：页面收起")
        XCTAssertEqual(harness.navigation.viewControllers.count, before - 1)
        harness.window.isHidden = true
    }

    @MainActor
    func testUnblockButtonOnABlockedProfile() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        try await harness.source.setBlocked(profileId: "s-1", blocked: true)
        let profile = await harness.openProfile("s-1")
        XCTAssertEqual(profile.presentation.followButton, .unblock)
        XCTAssertEqual(profile.rows, [.header, .status(.blocked)])
        profile.followTapped()
        try await settle(profile)
        XCTAssertEqual(profile.lastToastText, OWSLocalizedString("TELLOMI_FEED_PROFILE_UNBLOCKED", comment: ""))
        XCTAssertEqual(profile.presentation.page, .content)
        XCTAssertNotEqual(profile.rows, [.header, .status(.blocked)], "取消屏蔽后重新取主页：帖子回来了")
        harness.window.isHidden = true
    }

    // MARK: - 和信息流同步

    @MainActor
    func testLikingAPostOnTheProfileChangesTheFeedToo() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let profile = await harness.openProfile("s-1")
        guard case .post(let id) = profile.rows[1] else { return XCTFail("没有帖子") }
        let card = try XCTUnwrap(profile.presentation.posts.first { $0.id == id })
        profile.store.toggleLike(card)
        await profile.store.waitForTasks()
        harness.window.layoutIfNeeded()
        XCTAssertTrue(profile.presentation.posts.first { $0.id == id }?.viewer.liked ?? false)
        if let inFeed = harness.feed.store.card(id: id) {
            XCTAssertTrue(inFeed.viewer.liked, "信息流里那张同时点亮")
        }
        harness.window.isHidden = true
    }

    @MainActor
    func testPoppingThePageStopsFollowingTheFeed() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let profile = await harness.openProfile("s-1")
        XCTAssertTrue(profile.store.isObservingFeed)
        let leases = profile.store.leaseCount
        XCTAssertGreaterThan(leases, 0)
        harness.navigation.popViewController(animated: false)
        XCTAssertFalse(profile.store.isObservingFeed)
        XCTAssertEqual(profile.store.leaseCount, 0)
        harness.window.isHidden = true
    }

    // MARK: - 文案

    @MainActor
    func testAllTextsAreLocalizedNotKeys() {
        typealias VC = FeedProfileViewController
        let statuses: [FeedProfilePresentation.Status] = [
            .failed(retryAfterSeconds: nil), .failed(retryAfterSeconds: 5), .gone, .empty(isSelf: false), .empty(isSelf: true),
            .postsFailed, .privateLocked, .blocked, .regionUnavailable, .loadMoreFailed,
        ]
        for status in statuses {
            let texts = VC.statusTexts(for: status)
            for text in [texts.title, texts.body].compactMap({ $0 }) {
                XCTAssertFalse(text.isEmpty)
                XCTAssertFalse(text.hasPrefix("TELLOMI_"), "\(status) 的文字没有翻译")
            }
            XCTAssertNotNil(texts.title, "\(status)")
        }
        XCTAssertEqual(VC.statusTexts(for: .loading).title, nil)
        for button in [FeedProfilePresentation.FollowButton.follow, .requested, .following, .unblock] {
            XCTAssertFalse(VC.followTitle(for: button).hasPrefix("TELLOMI_"), "\(button)")
        }
        for confirmation in [VC.Confirmation.unfollow, .cancelRequest, .block] {
            XCTAssertFalse(VC.confirmationTitle(for: confirmation).hasPrefix("TELLOMI_"))
            XCTAssertFalse(VC.confirmationButton(for: confirmation).hasPrefix("TELLOMI_"))
        }
        let notices: [FeedProfilePageState.Notice] = [.followed, .requested, .profileRequired, .blocked, .unblocked, .muted, .hiddenFrom, .throttled, .reported, .failed]
        for notice in notices {
            let text = VC.toastText(for: notice, retryAfterSeconds: 9)
            XCTAssertNotNil(text, "\(notice)")
            XCTAssertFalse(text?.hasPrefix("TELLOMI_") ?? true, "\(notice)")
        }
        XCTAssertTrue(VC.toastText(for: .throttled, retryAfterSeconds: 9)?.contains("9") ?? false)
        XCTAssertNil(VC.toastText(for: .pinLimit))
        var presentation = FeedProfilePresentation(state: FeedProfilePageState())
        presentation.followers = 1200
        presentation.following = 3
        let counts = VC.countsLine(presentation)
        XCTAssertFalse(counts.contains("TELLOMI_"))
        XCTAssertFalse(counts.contains("%"))
    }

    @MainActor
    func testIdentityLineShowsHandleOrNumberAndTheRegionOnlyWhenAllowed() {
        var state = FeedProfilePageState()
        var page = FeedProfilePage(id: "p", displayName: "A")
        page.handle = "ann"
        page.ipRegionLabel = "四川"
        state.profile = page
        state.showIpRegion = true
        XCTAssertTrue(FeedProfileViewController.identityLine(FeedProfilePresentation(state: state)).hasPrefix("@ann"))
        XCTAssertTrue(FeedProfileViewController.identityLine(FeedProfilePresentation(state: state)).contains("四川"))
        state.showIpRegion = false
        XCTAssertEqual(FeedProfileViewController.identityLine(FeedProfilePresentation(state: state)), "@ann")
        page.handle = nil
        page.tellomiNumber = "3820145967"
        state.profile = page
        XCTAssertTrue(FeedProfileViewController.identityLine(FeedProfilePresentation(state: state)).contains("3820145967"))
    }
}
