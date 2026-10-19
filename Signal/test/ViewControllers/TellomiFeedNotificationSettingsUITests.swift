//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 动态通知设置页的界面检查（UIKit）：从通知页右上角的齿轮进来，样例数据（`SampleFeedSource+Notifications.swift`，设置存在内存里）。
/// 读失败 / 存失败 / 要先建主页 / 限速 / `feed_hidden` 用 `source.simulation` 的 `notificationSettings…` 开关切，截图方法见报告。
final class TellomiFeedNotificationSettingsUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
        let source: SampleFeedSource

        func openSettings() async -> FeedNotificationSettingsViewController {
            let page = FeedNotificationSettingsViewController(source: source)
            navigation.pushViewController(page, animated: false)
            page.loadViewIfNeeded()
            await page.store.waitForTasks()
            window.layoutIfNeeded()
            return page
        }
    }

    @MainActor
    private func makeHarness() async -> Harness {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source, profilePageEnabled: false, notificationsEnabled: true)
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
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<60 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @MainActor
    func testTheNotificationsPageHasAGearThatOpensTheSettings() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.feed.openNotifications()
        let notes = try XCTUnwrap(harness.navigation.topViewController as? FeedNotificationsViewController)
        notes.loadViewIfNeeded()
        let gear = try XCTUnwrap(notes.navigationItem.rightBarButtonItem)
        XCTAssertEqual(gear.accessibilityLabel, FeedNotificationSettingsViewController.title)
        try await Task.sleep(nanoseconds: 800_000_000)
        notes.openSettings()
        XCTAssertTrue(harness.navigation.topViewController is FeedNotificationSettingsViewController)
    }

    @MainActor
    func testTheSettingsShowTheChoiceAndThreeSwitches() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        XCTAssertEqual(page.title, FeedNotificationSettingsViewController.title)
        XCTAssertEqual(page.contents.sections.count, 2)
        XCTAssertEqual(page.contents.sections[0].items.count, FeedNotificationSettings.fromValues.count)
        XCTAssertEqual(page.contents.sections[1].items.count, 3)
        XCTAssertEqual(page.store.state.settings, FeedNotificationSettings())
        for value in FeedNotificationSettings.fromValues {
            XCTAssertFalse(FeedNotificationSettingsViewController.fromTitle(value).isEmpty)
        }
    }

    @MainActor
    func testPickingAChoiceSavesItAndThePageShowsIt() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        let none = try XCTUnwrap(page.contents.sections[0].items.last)
        none.actionBlock?()
        await page.store.waitForTasks()
        XCTAssertEqual(page.store.state.settings?.fromWhom, FeedNotificationSettings.fromNone)
        XCTAssertFalse(page.store.state.categoriesEnabled, "都不接收：下面三个开关变灰")
        let saved = try await harness.source.notificationSettings()
        XCTAssertEqual(saved.fromWhom, FeedNotificationSettings.fromNone)
    }

    @MainActor
    func testASaveThatNeedsAProfileIsRolledBackAndSaysSo() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        harness.source.simulation.notificationSettingsNeedProfile = true
        page.store.setLikes(false)
        await page.store.waitForTasks()
        await waitUntil { page.lastToastText != nil }
        XCTAssertEqual(page.store.state.settings?.likes, true)
        XCTAssertEqual(page.lastToastText, FeedNotificationSettingsViewController.toastText(for: .profileRequired))
    }

    @MainActor
    func testAThrottledSaveSaysHowLongToWait() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        harness.source.simulation.notificationSettingsThrottledRetryAfterSeconds = 7
        page.store.setComments(false)
        await page.store.waitForTasks()
        await waitUntil { page.lastToastText != nil }
        XCTAssertEqual(page.lastToastText, FeedProfileViewController.throttledText(7))
    }

    @MainActor
    func testALoadFailureShowsRetryRowsAndTappingRetryLoads() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.failsNotificationSettingsLoad = true
        let page = await harness.openSettings()
        XCTAssertTrue(page.store.state.loadFailed)
        XCTAssertEqual(page.contents.sections.count, 1)
        XCTAssertEqual(page.contents.sections[0].items.count, 2, "说一句失败 + 点按重试")
        harness.source.simulation.failsNotificationSettingsLoad = false
        let retry = try XCTUnwrap(page.contents.sections[0].items.last)
        retry.actionBlock?()
        await page.store.waitForTasks()
        XCTAssertNotNil(page.store.state.settings)
        XCTAssertEqual(page.contents.sections.count, 2)
    }

    @MainActor
    func testFeedHiddenClosesThePage() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.feedHidden = true
        let page = await harness.openSettings()
        await waitUntil { page.didClose }
        XCTAssertTrue(page.didClose)
        await waitUntil { harness.navigation.topViewController === harness.feed }
        XCTAssertTrue(harness.navigation.topViewController === harness.feed)
    }
}
