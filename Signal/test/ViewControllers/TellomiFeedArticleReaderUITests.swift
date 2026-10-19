//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 长文阅读页的界面检查（UIKit）：帖子详情页里长文那一行换成整篇长文（`TellomiFeed.isArticleReaderEnabled`，默认关）。
/// 样例：`mine-seed-5`（「我的动态」里第 5 条已发布的长文，有小标题、引用、列表、粗体、斜体）；`mine-seed-1` 是普通动态。
final class TellomiFeedArticleReaderUITests: XCTestCase {

    @MainActor
    private func open(_ id: String, articleReader: Bool, summaryOnly: Bool = false) async throws -> (FeedPostDetailViewController, UIWindow, SampleFeedSource) {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let cardOptional = try await source.card(contentId: id)
        var card = try XCTUnwrap(cardOptional)
        if summaryOnly {
            card.text = nil
            card.summary = "Only the summary"
        }
        let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: false, articleReader: articleReader)
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
    func testTheFlagIsOffByDefaultAndTheDetailPageKeepsTheFeedCard() async throws {
        XCTAssertFalse(TellomiFeed.isArticleReaderEnabled, "默认关（测试里没人打开过）")
        let (detail, window, _) = try await open("mine-seed-5", articleReader: false)
        defer { window.isHidden = true }
        XCTAssertNotNil(detail.postCell)
        XCTAssertNil(detail.articleCell, "关着：和之前一样，长文只是卡片")
    }

    @MainActor
    func testWhenOnAnArticleShowsTheReadingLayout() async throws {
        let (detail, window, _) = try await open("mine-seed-5", articleReader: true)
        defer { window.isHidden = true }
        XCTAssertNil(detail.postCell)
        let cell = try XCTUnwrap(detail.articleCell)
        let presentation = try XCTUnwrap(cell.presentation)
        XCTAssertEqual(presentation.title, "My sample article 5")
        XCTAssertFalse(presentation.summaryOnly)
        XCTAssertGreaterThan(cell.contentView.bounds.height, 400, "整篇正文都排出来了，比信息流里的卡片高得多")
    }

    @MainActor
    func testAPlainPostStaysAPostCellEvenWhenOn() async throws {
        let (detail, window, _) = try await open("mine-seed-1", articleReader: true)
        defer { window.isHidden = true }
        XCTAssertNotNil(detail.postCell)
        XCTAssertNil(detail.articleCell)
    }

    @MainActor
    func testTheFullTextArrivesAfterTheCardRefreshAndReplacesTheSummary() async throws {
        // 信息流里带来的卡片只有摘要：打开后 Card API 取回完整的长文，这一格就地换成整篇
        let (detail, window, _) = try await open("mine-seed-5", articleReader: true, summaryOnly: true)
        defer { window.isHidden = true }
        let cell = try XCTUnwrap(detail.articleCell)
        let presentation = try XCTUnwrap(cell.presentation)
        XCTAssertFalse(presentation.summaryOnly)
        XCTAssertGreaterThan(presentation.blocks.count, 5)
    }

    @MainActor
    func testTheMetaLineHasTheReadingTime() {
        var card = FeedCard(id: "x", kind: FeedCard.kindArticle, publishedAt: FeedDates.format(Date().addingTimeInterval(-3600)))
        card.author = FeedAuthor(profileId: "a", displayName: "A", handle: "aaa")
        let text = FeedArticleCell.metaText(card: card, minutes: 3, showIpRegion: false, now: Date())
        XCTAssertTrue(text.contains("@aaa"))
        XCTAssertTrue(text.contains(String(format: OWSLocalizedString("TELLOMI_FEED_ARTICLE_MINUTES_FORMAT", comment: ""), "3")))
        XCTAssertFalse(FeedArticleCell.metaText(card: card, minutes: 0, showIpRegion: false, now: Date()).contains("3"))
    }

    @MainActor
    func testTheAttributedBodyHasBoldItalicAndIndentedQuotes() {
        let blocks = FeedArticleBody.parse("**bold** and *it*\n\n> quote\n\n- item")
        let text = FeedArticleAttributedText.make(blocks)
        XCTAssertEqual(text.string, "bold and it\nquote\n•\titem")
        let boldFont = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        let plainFont = text.attribute(.font, at: 6, effectiveRange: nil) as? UIFont
        XCTAssertNotEqual(boldFont, plainFont)
        let quoteStart = (text.string as NSString).range(of: "quote").location
        let style = text.attribute(.paragraphStyle, at: quoteStart, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, 16)
    }
}
