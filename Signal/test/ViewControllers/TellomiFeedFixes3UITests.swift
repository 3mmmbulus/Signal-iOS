//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// fixes-r3 的界面检查（UIKit，Mac 2026-10-19 报告里 fixes-r2 之后还在的几项）：举报页的紧急提示不夹紧且能滚到计数和 12377、
/// 顶栏 4 个入口时收进菜单、通知设置页的受众行和开关行、我的动态行里备注不省略和「申诉」间距。
/// 最大字号下的实际样子要在 Mac 上截图看（这里是进程内的结构检查）。
final class TellomiFeedFixes3UITests: XCTestCase {

    @MainActor
    private func makeWindow(_ root: UIViewController) -> UIWindow {
        let navigation = OWSNavigationController(rootViewController: root)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        return window
    }

    // MARK: - 举报页

    @MainActor
    func testTheEmergencyNoticeIsNotClampedAndTheCounterAndHotlineCanBeScrolledTo() async throws {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source)
        let window = makeWindow(feed)
        defer { window.isHidden = true }
        await feed.store.loadConfig()
        await feed.store.waitForLoad(.recommend)
        let fetched = try await source.card(contentId: "sample-1")
        let card = try XCTUnwrap(fetched)
        let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: false, feed: feed.store)
        feed.navigationController?.pushViewController(detail, animated: false)
        detail.loadViewIfNeeded()
        await detail.detailStore.waitForTasks()
        detail.handleMenuItem(.report, comment: nil)
        let report = try XCTUnwrap(detail.presentedReport)
        report.loadViewIfNeeded()
        await report.store.waitForTasks()
        report.view.layoutIfNeeded()
        let reason = try XCTUnwrap(report.presentation.groups.flatMap(\.reasons).first { $0.code == "self_harm" })
        report.pick(reason)
        report.view.layoutIfNeeded()

        XCTAssertEqual(report.emergencyLabel.font.pointSize, UIFont.dynamicTypeSubheadline.pointSize, "紧急提示不夹紧（和 ff8023f 一样）")
        let scroll = report.formScroll
        let content = scroll.contentSize.height
        for target in [report.detailCounterLabel, report.hotlineLabel] as [UIView] {
            let frame = target.convert(target.bounds, to: scroll)
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxY, content + 0.5, "计数 / 12377 在可滚动的内容里")
            XCTAssertLessThanOrEqual(frame.height, scroll.bounds.height, "一屏放得下它")
        }
        let maxOffset = max(0, content - scroll.bounds.height)
        scroll.contentOffset = CGPoint(x: 0, y: maxOffset)
        let hotline = report.hotlineLabel.convert(report.hotlineLabel.bounds, to: scroll)
        XCTAssertLessThanOrEqual(hotline.maxY - scroll.contentOffset.y, scroll.bounds.height + 0.5, "滚到底：12377 那段整段在屏幕上")
    }

    // MARK: - 顶栏

    @MainActor
    func testFourEntryButtonsFoldMyPostsAndSettingsIntoAMenu() async throws {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let blocked = InMemoryFeedBlockedKeywords()
        let feed = FeedViewController(source: source, profilePageEnabled: false, searchEnabled: true, notificationsEnabled: true, myPostsEnabled: true, settingsEnabled: true, blockedKeywords: blocked)
        let window = makeWindow(feed)
        defer { window.isHidden = true }
        let more = try XCTUnwrap(feed.overflowItem)
        XCTAssertNil(feed.myPostsItem)
        XCTAssertNil(feed.settingsItem)
        XCTAssertEqual(feed.navigationItem.leftBarButtonItems?.count, 1, "左边只剩铃铛")
        let right = try XCTUnwrap(feed.navigationItem.rightBarButtonItems)
        XCTAssertEqual(right.count, 2)
        XCTAssertTrue(right[1] === more, "第一个是最右的：搜索在最右，菜单在左")
        let titles = more.menu?.children.map(\.title)
        XCTAssertEqual(titles, [FeedMyPostsViewController.title, FeedRecommendationSettingsViewController.title])
    }

    @MainActor
    func testThreeEntryButtonsStayOnTheBarAsBefore() async throws {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source, profilePageEnabled: false, searchEnabled: true, notificationsEnabled: true, myPostsEnabled: true, settingsEnabled: false)
        let window = makeWindow(feed)
        defer { window.isHidden = true }
        XCTAssertNil(feed.overflowItem)
        XCTAssertNotNil(feed.myPostsItem)
        XCTAssertEqual(feed.navigationItem.leftBarButtonItems?.count, 2)
        XCTAssertEqual(feed.navigationItem.rightBarButtonItems?.count, 1)
    }

    // MARK: - 通知设置页

    @MainActor
    func testTheAudienceRowsAndSwitchesAreWrappingUnclampedRows() async throws {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let page = FeedNotificationSettingsViewController(source: source)
        let window = makeWindow(page)
        defer { window.isHidden = true }
        page.loadViewIfNeeded()
        await page.store.waitForTasks()
        window.layoutIfNeeded()
        page.tableView.layoutIfNeeded()

        func label(in cell: UITableViewCell) -> UILabel? {
            return cell.contentView.allSubviews().compactMap { $0 as? UILabel }.first
        }
        let selected = page.store.state.settings?.fromWhom
        for (index, value) in FeedNotificationSettings.fromValues.enumerated() {
            let cell = try XCTUnwrap(page.tableView.cellForRow(at: IndexPath(row: index, section: 0)))
            let text = try XCTUnwrap(label(in: cell))
            XCTAssertEqual(text.text, FeedNotificationSettingsViewController.fromTitle(value))
            XCTAssertEqual(text.numberOfLines, 0, "可以换行")
            XCTAssertEqual(text.font.pointSize, UIFont.dynamicTypeBody.pointSize, "不夹紧")
            XCTAssertEqual(cell.accessoryType, value == selected ? .checkmark : .none)
        }
        for index in 0..<3 {
            let cell = try XCTUnwrap(page.tableView.cellForRow(at: IndexPath(row: index, section: 1)))
            let text = try XCTUnwrap(label(in: cell))
            XCTAssertEqual(text.numberOfLines, 0)
            XCTAssertEqual(text.font.pointSize, UIFont.dynamicTypeBody.pointSize)
            XCTAssertNotNil(cell.contentView.allSubviews().compactMap { $0 as? UISwitch }.first)
        }
    }

    @MainActor
    func testFlippingASwitchSavesIt() async throws {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let page = FeedNotificationSettingsViewController(source: source)
        let window = makeWindow(page)
        defer { window.isHidden = true }
        page.loadViewIfNeeded()
        await page.store.waitForTasks()
        page.tableView.layoutIfNeeded()
        let cell = try XCTUnwrap(page.tableView.cellForRow(at: IndexPath(row: 0, section: 1)))
        let toggle = try XCTUnwrap(cell.contentView.allSubviews().compactMap { $0 as? UISwitch }.first)
        XCTAssertTrue(toggle.isOn)
        toggle.isOn = false
        toggle.sendActions(for: .valueChanged)
        await page.store.waitForTasks()
        XCTAssertEqual(page.store.state.settings?.likes, false)
        let saved = try await source.notificationSettings()
        XCTAssertFalse(saved.likes)
    }

    // MARK: - 我的动态行

    @MainActor
    func testMyPostsNotesWrapAndTheAppealButtonHasRoom() async throws {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source, profilePageEnabled: false)
        let window = makeWindow(feed)
        defer { window.isHidden = true }
        await feed.store.loadConfig()
        await feed.store.waitForLoad(.recommend)
        let page = FeedMyPostsViewController(source: source, feed: feed.store)
        feed.navigationController?.pushViewController(page, animated: false)
        page.loadViewIfNeeded()
        await page.store.waitForTasks()
        window.layoutIfNeeded()
        let index = try XCTUnwrap(page.rows.firstIndex { row in
            if case .post(let value) = row { return value.id == "mine-seed-r2" }
            return false
        })
        page.postsTableView.layoutIfNeeded()
        let cell = try XCTUnwrap(page.postsTableView.cellForRow(at: IndexPath(row: index, section: 0)) as? FeedMyPostCell)
        cell.layoutIfNeeded()
        XCTAssertFalse(cell.notesStack.arrangedSubviews.isEmpty)
        for note in cell.notesStack.arrangedSubviews.compactMap({ $0 as? UILabel }) {
            XCTAssertEqual(note.numberOfLines, 0)
            XCTAssertEqual(note.lineBreakMode, .byWordWrapping)
            XCTAssertEqual(note.contentCompressionResistancePriority(for: .vertical), .required)
            let needed = note.sizeThatFits(CGSize(width: note.bounds.width, height: .greatestFiniteMagnitude)).height
            XCTAssertGreaterThanOrEqual(note.bounds.height + 0.5, needed.rounded(.down), "备注整段都显示出来，没被截")
        }
        let accessibility = cell.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        XCTAssertEqual(cell.appealSpacingForTesting, FeedDynamicTypeLayout.appealSpacing(isAccessibilityCategory: accessibility))
        XCTAssertGreaterThan(cell.appealSpacingForTesting, 6, "比别的行（6）宽")
    }
}

private extension UIView {
    func allSubviews() -> [UIView] {
        return subviews + subviews.flatMap { $0.allSubviews() }
    }
}
