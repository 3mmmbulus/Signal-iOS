//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import XCTest

@testable import Signal

/// TestFlight 本机示例数据里的三种链接卡片：大图卡、只有标题的横条、灰色指南针横条（`SampleFeedSource.sampleLinks`）。
final class TellomiFeedSamplePreviewTests: XCTestCase {

    private func samplePost(_ id: String) async throws -> FeedCard {
        let source = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_790_000_000) }, commentsLatencyNanos: 0)
        let card = try await source.card(contentId: id)
        return try XCTUnwrap(card)
    }

    private func linkCard(for post: FeedCard) throws -> FeedLinkCard {
        try XCTUnwrap(FeedLinkCard.make(body: post.text, isArticle: post.isArticle, preview: post.linkPreview))
    }

    func testSampleImageIsBundledLocally() {
        XCTAssertNotNil(UIImage(named: SampleFeedSource.sampleLinkImageName), "示例图随包，不连网")
    }

    func testLargeImageSample() async throws {
        let post = try await samplePost("sample-2")
        XCTAssertTrue(post.media.isEmpty)
        let card = try linkCard(for: post)
        XCTAssertEqual(card.kind, .largeImage)
        XCTAssertEqual(card.imageName, SampleFeedSource.sampleLinkImageName)
        XCTAssertFalse(card.showsCompass)
        XCTAssertEqual(card.text.domain, "example.com")
        XCTAssertEqual(card.text.title, "山脊日落步道：全程 6 公里，适合新手")
        XCTAssertEqual(card.imageAspectRatio, 630.0 / 1200.0, accuracy: 0.0001)
    }

    func testTitleOnlySample() async throws {
        let post = try await samplePost("sample-4")
        let card = try linkCard(for: post)
        XCTAssertEqual(card.kind, .textStrip)
        XCTAssertNil(card.imageName)
        XCTAssertEqual(card.text.title, "家常酸面包：从养酵种到出炉")
        XCTAssertEqual(card.text.domain, "example.org")
        XCTAssertFalse(card.showsCompass, "有标题的横条不画指南针（产品经理 2026-10-24）")
    }

    func testNoInfoSample() async throws {
        let post = try await samplePost("sample-6")
        XCTAssertNil(post.linkPreview)
        let card = try linkCard(for: post)
        XCTAssertEqual(card.kind, .domainStrip)
        XCTAssertNil(card.text.title)
        XCTAssertEqual(card.text.domain, "example.net")
        XCTAssertTrue(card.showsCompass)
    }

    /// 大图比例同聊天：夹在 1 / 1.91 和 1 之间；有图名但不是大图（纯链接）不带图。
    func testAspectRatioClampAndPlainLinkDropsImage() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let tall = try XCTUnwrap(FeedLinkCard.make(url: url, preview: .init(title: "t", imageName: "x", imagePixelSize: CGSize(width: 100, height: 400))))
        XCTAssertEqual(tall.imageAspectRatio, 1)
        let wide = try XCTUnwrap(FeedLinkCard.make(url: url, preview: .init(title: "t", imageName: "x", imagePixelSize: CGSize(width: 1000, height: 100))))
        XCTAssertEqual(wide.imageAspectRatio, 1 / 1.91, accuracy: 0.0001)
        let plain = try XCTUnwrap(FeedLinkCard.make(url: url, preview: nil))
        XCTAssertNil(plain.imageName)
    }

    @MainActor
    func testPostCellRendersThreeKinds() async throws {
        let cell = FeedPostCell(style: .default, reuseIdentifier: nil)
        let view = cell.linkCardViewForTesting

        cell.configure(card: try await samplePost("sample-2"), showIpRegion: false)
        XCTAssertFalse(view.isHidden)
        XCTAssertNotNil(view.imageForTesting)
        XCTAssertEqual(view.imageAspectMultiplierForTesting ?? 0, 630.0 / 1200.0, accuracy: 0.0001)
        XCTAssertEqual(view.titleTextForTesting, "山脊日落步道：全程 6 公里，适合新手")
        XCTAssertFalse(view.isCompassVisibleForTesting)
        XCTAssertEqual(view.textInsetsForTesting, [9, 14, -10, -14])

        // 复用：换成没有图的帖子，图和比例约束都要清掉
        cell.configure(card: try await samplePost("sample-4"), showIpRegion: false)
        XCTAssertNil(view.imageForTesting)
        XCTAssertNil(view.imageAspectMultiplierForTesting)
        XCTAssertEqual(view.titleTextForTesting, "家常酸面包：从养酵种到出炉")
        XCTAssertFalse(view.isCompassVisibleForTesting)
        XCTAssertEqual(view.textInsetsForTesting, [9, 14, -9, -10])

        cell.configure(card: try await samplePost("sample-6"), showIpRegion: false)
        XCTAssertNil(view.imageForTesting)
        XCTAssertNil(view.titleTextForTesting)
        XCTAssertEqual(view.domainTextForTesting, "example.net")
        XCTAssertTrue(view.isCompassVisibleForTesting)
    }
}
