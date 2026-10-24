//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import XCTest

@testable import Signal

/// 动态的链接卡片（`FeedLinkCard`、`FeedLinkCardView`）和评论 / 引用里可以点的网址。
final class TellomiFeedLinkCardTests: XCTestCase {

    // MARK: - 模型

    func testNoCardWithoutLink() {
        XCTAssertNil(FeedLinkCard.make(body: nil, isArticle: false))
        XCTAssertNil(FeedLinkCard.make(body: "", isArticle: false))
        XCTAssertNil(FeedLinkCard.make(body: "没有链接的一句话", isArticle: false))
        XCTAssertNil(FeedLinkCard.make(body: "写信 someone@example.com", isArticle: false))
    }

    func testArticlesGetNoCard() {
        XCTAssertNil(FeedLinkCard.make(body: "看 https://example.com", isArticle: true))
    }

    /// 没有预览数据（TestFlight 的示例数据）：只有域名的横条 + 指南针，「完全没信息」的那一种。
    func testNoPreviewIsDomainStripWithCompass() throws {
        let card = try XCTUnwrap(FeedLinkCard.make(body: "看这个 https://www.Example.com/a?b=1 不错", isArticle: false))
        XCTAssertEqual(card.kind, .domainStrip)
        XCTAssertTrue(card.showsCompass)
        XCTAssertNil(card.text.title)
        XCTAssertEqual(card.text.domain, "example.com")
        XCTAssertEqual(card.url.absoluteString, "https://www.Example.com/a?b=1")
        XCTAssertEqual(card.accessibilityLabel, "example.com")
    }

    func testUsesFirstLinkOnly() throws {
        let card = try XCTUnwrap(FeedLinkCard.make(body: "a.cn/x 和 https://b.org", isArticle: false))
        XCTAssertEqual(card.url.absoluteString, "https://a.cn/x")
        XCTAssertEqual(card.text.domain, "a.cn")
    }

    func testPreviewWithTitleIsTextStrip() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/p"))
        let card = try XCTUnwrap(FeedLinkCard.make(url: url, preview: .init(title: "  标题\n 两段 ")))
        XCTAssertEqual(card.kind, .textStrip)
        XCTAssertEqual(card.text.title, "标题 两段")
        XCTAssertFalse(card.showsCompass, "有标题的横条不画指南针（产品经理 2026-10-24）")
        XCTAssertEqual(card.accessibilityLabel, "标题 两段, example.com")
    }

    func testClaimedPreviewHasNoCompass() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let card = try XCTUnwrap(FeedLinkCard.make(url: url, preview: .init(title: "Example", isClaimed: true)))
        XCTAssertEqual(card.kind, .textStrip)
        XCTAssertFalse(card.showsCompass)
    }

    /// 预览里标题和域名一样 / 空白：当没有标题，退回只有域名的横条。
    func testPreviewWithoutUsefulTitleIsDomainStrip() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertEqual(FeedLinkCard.make(url: url, preview: .init(title: "EXAMPLE.com"))?.kind, .domainStrip)
        XCTAssertEqual(FeedLinkCard.make(url: url, preview: .init(title: "   "))?.kind, .domainStrip)
        XCTAssertEqual(FeedLinkCard.make(url: url, preview: .init(title: nil))?.showsCompass, true)
    }

    // MARK: - 视图

    @MainActor
    func testViewShowsDomainAndCompassAndOpens() throws {
        let view = FeedLinkCardView()
        let card = try XCTUnwrap(FeedLinkCard.make(body: "https://example.com/x", isArticle: false))
        view.configure(card)
        XCTAssertFalse(view.isHidden)
        XCTAssertNil(view.titleTextForTesting)
        XCTAssertEqual(view.domainTextForTesting, "example.com")
        XCTAssertTrue(view.isCompassVisibleForTesting)
        XCTAssertTrue(view.accessibilityTraits.contains(.link))
        XCTAssertEqual(view.layer.cornerRadius, FeedLinkCardView.cornerRadius)

        var opened: URL?
        view.onOpen = { opened = $0 }
        view.simulateTapForTesting()
        XCTAssertEqual(opened, card.url)

        view.configure(nil)
        XCTAssertTrue(view.isHidden)
    }

    @MainActor
    func testClaimedViewHidesCompass() throws {
        let view = FeedLinkCardView()
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        view.configure(FeedLinkCard.make(url: url, preview: .init(title: "Example", isClaimed: true)))
        XCTAssertEqual(view.titleTextForTesting, "Example")
        XCTAssertFalse(view.isCompassVisibleForTesting)
    }

    @MainActor
    func testPostCellShowsCardOnlyForPostsWithLinks() {
        let cell = FeedPostCell(style: .default, reuseIdentifier: nil)
        var post = FeedCard(id: "a", kind: FeedCard.kindPost, author: FeedAuthor(profileId: "p", displayName: "Ann"), text: "看 https://example.com/a")
        cell.configure(card: post, showIpRegion: false)
        XCTAssertFalse(cell.linkCardViewForTesting.isHidden)
        XCTAssertEqual(cell.linkCardViewForTesting.card?.text.domain, "example.com")

        // 复用：没有网址的帖子不能留着上一条的卡片
        post.text = "没有链接"
        cell.configure(card: post, showIpRegion: false)
        XCTAssertTrue(cell.linkCardViewForTesting.isHidden)
    }

    // MARK: - 评论 / 引用里的网址

    @MainActor
    func testCommentBodyLinksAreTappable() {
        let cell = FeedCommentCell(style: .default, reuseIdentifier: nil)
        let comment = FeedCard(id: "c", kind: FeedCard.kindComment, author: FeedAuthor(profileId: "p", displayName: "Bo"), text: "见 https://example.com/c")
        cell.configure(row: .init(comment: comment, isReply: false, replyToName: nil))
        let label = cell.bodyLabelForTesting
        XCTAssertEqual(label.links.map(\.url.absoluteString), ["https://example.com/c"])
        XCTAssertTrue(label.isUserInteractionEnabled)
        XCTAssertEqual(label.attributedText?.string, "见 https://example.com/c")

        let plain = FeedCard(id: "d", kind: FeedCard.kindComment, author: FeedAuthor(profileId: "p", displayName: "Bo"), text: "没有链接")
        cell.configure(row: .init(comment: plain, isReply: false, replyToName: nil))
        XCTAssertTrue(label.links.isEmpty)
        XCTAssertFalse(label.isUserInteractionEnabled)
    }

    @MainActor
    func testQuotedBoxLinksAreTappableButGoneTextIsNot() {
        let box = FeedQuotedBoxView()
        box.configure(.init(authorName: "Ann", text: "原帖 https://example.com/q", goneText: nil))
        let label = box.bodyLabelForTesting
        XCTAssertEqual(label.links.map(\.url.absoluteString), ["https://example.com/q"])
        XCTAssertTrue(label.isUserInteractionEnabled)
        XCTAssertTrue(box.isEnabled)

        box.configure(.init(authorName: nil, text: nil, goneText: "已删除 example.com"))
        XCTAssertFalse(label.isUserInteractionEnabled)
        XCTAssertFalse(box.isEnabled)
    }
}
