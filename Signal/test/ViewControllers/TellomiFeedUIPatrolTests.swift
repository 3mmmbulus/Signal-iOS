//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import XCTest

@testable import Signal

/// UI 巡检（2026-10-24）：已删除页能退出、iPad 内容限宽、发布页话题 / 回复入口、举报页关闭按钮颜色、动态图标横条。
final class TellomiFeedUIPatrolTests: XCTestCase {

    // MARK: P1a 已删除页

    func testCloseButtonOnlyForPresentedRootWithoutLeftItem() {
        XCTAssertTrue(FeedSheetChrome.needsCloseButton(isRootOfNavigation: true, isPresented: true, hasLeftItem: false))
        XCTAssertFalse(FeedSheetChrome.needsCloseButton(isRootOfNavigation: false, isPresented: true, hasLeftItem: false), "推进来的页面有系统返回")
        XCTAssertFalse(FeedSheetChrome.needsCloseButton(isRootOfNavigation: true, isPresented: false, hasLeftItem: false))
        XCTAssertFalse(FeedSheetChrome.needsCloseButton(isRootOfNavigation: true, isPresented: true, hasLeftItem: true), "已有取消 / 关闭不重复加")
    }

    @MainActor
    func testGoneStateHasBackButton() async throws {
        let source = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_790_000_000) }, commentsLatencyNanos: 0)
        let card = try XCTUnwrap(try await source.card(contentId: "sample-1"))
        let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: false)
        detail.loadViewIfNeeded()
        XCTAssertEqual(detail.goneStateView.actionButton?.title(for: .normal), CommonStrings.backButton)
    }

    // MARK: P1b 可读宽度

    func testReadableWidthClampsOnIPadOnly() {
        XCTAssertEqual(FeedReadableWidth.contentWidth(forContainerWidth: 390), 390, "手机竖屏不限")
        XCTAssertEqual(FeedReadableWidth.contentWidth(forContainerWidth: 1024), FeedReadableWidth.maxWidth)
        XCTAssertEqual(FeedReadableWidth.contentWidth(forContainerWidth: 1366), FeedReadableWidth.maxWidth)
        XCTAssertTrue((600...680).contains(FeedReadableWidth.maxWidth))
    }

    @MainActor
    func testPinnedContentIsCenteredAndClamped() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 1024, height: 800))
        let content = UIView()
        container.addSubview(content)
        FeedReadableWidth.pin(content, in: container)
        container.layoutIfNeeded()
        XCTAssertEqual(content.frame.width, FeedReadableWidth.maxWidth, accuracy: 0.5)
        XCTAssertEqual(content.frame.midX, 512, accuracy: 0.5)

        container.frame.size.width = 375
        container.layoutIfNeeded()
        XCTAssertEqual(content.frame.width, 375, accuracy: 0.5)
    }

    // MARK: P2a 发布页话题 / 回复

    @MainActor
    func testComposeShowsTopicAndReplyEntries() {
        let compose = FeedComposeViewController(source: SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0), articleDrafts: InMemoryFeedArticleDrafts()) { _ in }
        compose.loadViewIfNeeded()
        XCTAssertTrue(compose.layout.showsTopicButton)
        XCTAssertTrue(compose.layout.showsReplyButton)
        XCTAssertFalse(compose.topicButtonForTesting.isHidden)
        XCTAssertFalse(compose.replyButtonForTesting.isHidden)
        XCTAssertNotNil(compose.topicButtonForTesting.menu)
        XCTAssertNotNil(compose.replyButtonForTesting.menu)
    }

    func testTopicAndReplyTitles() {
        XCTAssertEqual(FeedComposeViewController.topicButtonTitle([]), OWSLocalizedString("TELLOMI_FEED_COMPOSE_TOPICS", comment: ""))
        XCTAssertEqual(FeedComposeViewController.topicButtonTitle(["ai"]), "#" + FeedRecommendationSettingsViewController.topicName(.ai))
        XCTAssertEqual(FeedComposeViewController.topicButtonTitle(["unknown-slug"]), "#unknown-slug")
        var settings = FeedReplySettings()
        XCTAssertEqual(FeedComposeViewController.replyButtonTitle(settings), OWSLocalizedString("TELLOMI_FEED_COMPOSE_REPLIES", comment: ""))
        settings.policy = .friends
        XCTAssertEqual(FeedComposeViewController.replyButtonTitle(settings), FeedComposeViewController.replyPolicyName(.friends))
        settings.commentsClosed = true
        XCTAssertEqual(FeedComposeViewController.replyButtonTitle(settings), OWSLocalizedString("TELLOMI_FEED_COMPOSE_REPLIES_CLOSED", comment: ""))
    }

    // MARK: P2b 举报页关闭按钮

    func testReportBarItemUsesLabelColor() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let light = UITraitCollection(userInterfaceStyle: .light)
        XCTAssertEqual(FeedReportViewController.barItemTint.resolvedColor(with: dark), UIColor.Signal.label.resolvedColor(with: dark))
        XCTAssertEqual(FeedReportViewController.barItemTint.resolvedColor(with: light), UIColor.Signal.label.resolvedColor(with: light))
    }

    // MARK: P2c 图标横条（DESIGN.md §9）

    func testIconPreviewMakesIconStripWithoutCompass() throws {
        let url = try XCTUnwrap(URL(string: "https://example.edu/tools/type"))
        let card = try XCTUnwrap(FeedLinkCard.make(url: url, preview: .init(title: "t", iconName: SampleFeedSource.sampleSiteIconName)))
        XCTAssertEqual(card.kind, .iconStrip)
        XCTAssertEqual(card.iconName, SampleFeedSource.sampleSiteIconName)
        XCTAssertFalse(card.showsCompass, "指南针只给只有域名的卡")
        // 大图优先
        let large = try XCTUnwrap(FeedLinkCard.make(url: url, preview: .init(title: "t", imageName: "x", iconName: "y")))
        XCTAssertEqual(large.kind, .largeImage)
        XCTAssertNil(large.iconName)
    }

    @MainActor
    func testIconStripRendersIconAndTint() throws {
        XCTAssertNotNil(UIImage(named: SampleFeedSource.sampleSiteIconName), "示例图标随包")
        let url = try XCTUnwrap(URL(string: "https://example.edu/tools/type"))
        let view = FeedLinkCardView()
        view.configure(FeedLinkCard.make(url: url, preview: .init(title: "t", iconName: SampleFeedSource.sampleSiteIconName)))
        XCTAssertNotNil(view.iconForTesting)
        XCTAssertFalse(view.isCompassVisibleForTesting)
        XCTAssertNotNil(view.stripColorForTesting, "底色取图标主色")
        XCTAssertEqual(view.textInsetsForTesting, [9, 14, -9, -10])

        // 换回只有标题：不留图标、回到中性灰
        view.configure(FeedLinkCard.make(url: url, preview: .init(title: "t")))
        XCTAssertNil(view.iconForTesting)
        XCTAssertNil(view.stripColorForTesting)
    }

    func testSampleHasIconStrip() async throws {
        let source = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_790_000_000) }, commentsLatencyNanos: 0)
        let post = try XCTUnwrap(try await source.card(contentId: "sample-8"))
        let card = try XCTUnwrap(FeedLinkCard.make(body: post.text, isArticle: post.isArticle, preview: post.linkPreview))
        XCTAssertEqual(card.kind, .iconStrip)
    }
}
