//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// card-visual §3.5（tellomi/tellomi#1423）：消息除了一条链接什么都没有时，只显示卡片。
/// 与 Android `TellomiLinkOnlyTest`、Desktop `linkOnlyMessage_test` 同一批用例。
final class TellomiLinkOnlyTest: XCTestCase {

    private let url = "https://www.bilibili.com/video/BV1YDhJ6ZEL6"
    private let card = TellomiLinkCard(level: .generic, title: "Sender title", domain: "bilibili.com")

    /// 测试里的「Signal 的链接识别」：按空白切开，凡是 http(s):// 开头的词都算一条链接，
    /// 并且把结尾的标点留在外面（和 NSDataDetector 的做法一致）。
    private func detectLinks(in text: String) -> [Range<String.Index>] {
        var ranges = [Range<String.Index>]()
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
            guard start < index else { break }
            var end = index
            while end > start, ".,;:!?)".contains(text[text.index(before: end)]) { end = text.index(before: end) }
            let word = text[start..<end].lowercased()
            if word.hasPrefix("https://") || word.hasPrefix("http://") {
                ranges.append(start..<end)
            }
        }
        return ranges
    }

    private func linkOnly(_ body: String?, other: Bool = false) -> String? {
        TellomiLinkOnly.linkOnlyUrl(body: body, hasOtherContent: other, linkRanges: detectLinks(in:))
    }

    func testTheLinkIsTheWholeBodyAroundWhiteSpace() {
        XCTAssertEqual(linkOnly(url), url)
        XCTAssertEqual(linkOnly("  \(url)\n"), url)
        XCTAssertEqual(linkOnly("http://www.163.com/news/article/K1234.html"), "http://www.163.com/news/article/K1234.html")
        XCTAssertEqual(linkOnly("HTTPS://WWW.BILIBILI.COM/video/BV1"), "HTTPS://WWW.BILIBILI.COM/video/BV1")
    }

    func testAnyOtherTextKeepsTheText() {
        XCTAssertNil(linkOnly("看看这个 \(url)"))
        XCTAssertNil(linkOnly("\(url) 看看"))
        XCTAssertNil(linkOnly("\(url)\n\(url)"))
    }

    func testALinkTheBodyShowsShorterThanTheTextKeepsTheText() {
        XCTAssertNil(linkOnly("https://www.163.com/a."))
        XCTAssertNil(linkOnly("https://www.163.com/a b"))
    }

    func testOnlyHttpAndHttpsLinksWrittenOutInFull() {
        XCTAssertNil(linkOnly("tell.cc/kaixin"))
        XCTAssertNil(linkOnly("www.bilibili.com"))
        XCTAssertNil(linkOnly("ftp://example.org/file"))
        XCTAssertNil(linkOnly("mailto:someone@example.org"))
        XCTAssertNil(linkOnly("sgnl://signal.group/#abc"))
        XCTAssertNil(linkOnly("https://"))
    }

    /// 产品经理 2026-10-19（卡片样式定稿）：消息带着预览时，没写协议的链接也只显示卡片，按 https 写法比对预览。
    func testSchemelessLinkCountsOnlyWhenTheCallerAllowsIt() {
        func schemeless(_ body: String) -> String? {
            TellomiLinkOnly.linkOnlyUrl(body: body, hasOtherContent: false, allowSchemeless: true, linkRanges: { text in
                // NSDataDetector 把整段裸域名认成一条链接
                text.contains(".") ? [text.startIndex..<text.endIndex] : []
            })
        }
        XCTAssertEqual(schemeless("b23.tv/abc"), "https://b23.tv/abc")
        XCTAssertEqual(schemeless("  www.jd.com \n"), "https://www.jd.com")
        XCTAssertEqual(schemeless(url), url)
        XCTAssertNil(schemeless("mailto:someone@example.org"))
        XCTAssertNil(schemeless("sgnl://signal.group/#abc"))
        XCTAssertNil(schemeless("localhost"))
        XCTAssertNil(schemeless("看 jd.com"))
        // 默认不开：没有预览时照旧显示文字。
        XCTAssertNil(linkOnly("b23.tv/abc"))
    }

    func testAnythingButPlainTextKeepsSignalsLayout() {
        XCTAssertNil(linkOnly(url, other: true))
        XCTAssertNil(linkOnly(nil))
        XCTAssertNil(linkOnly(""))
        XCTAssertNil(linkOnly("   "))
    }

    func testTheLinkRecognitionHasToTakeTheWholeBody() {
        // Signal 的识别把整段认成两条、或者没认出来，都不算。
        XCTAssertNil(TellomiLinkOnly.linkOnlyUrl(body: url, hasOtherContent: false, linkRanges: { _ in [] }))
        XCTAssertNil(TellomiLinkOnly.linkOnlyUrl(body: url, hasOtherContent: false, linkRanges: { text in
            let middle = text.index(text.startIndex, offsetBy: 10)
            return [text.startIndex..<middle, middle..<text.endIndex]
        }))
        XCTAssertNil(TellomiLinkOnly.linkOnlyUrl(body: url, hasOtherContent: false, linkRanges: { text in
            [text.startIndex..<text.index(before: text.endIndex)]
        }))
    }

    func testTheCardStandsAloneOnlyForTheOnePreviewOfThatLinkWithADecision() {
        XCTAssertTrue(TellomiLinkOnly.isLinkCardOnly(linkOnlyUrl: url, previewUrls: [url], card: card))
        XCTAssertFalse(TellomiLinkOnly.isLinkCardOnly(linkOnlyUrl: url, previewUrls: [url], card: nil), "no decision: Signal's layout")
        XCTAssertFalse(TellomiLinkOnly.isLinkCardOnly(linkOnlyUrl: url, previewUrls: [url + "/"], card: card))
        XCTAssertFalse(TellomiLinkOnly.isLinkCardOnly(linkOnlyUrl: url, previewUrls: [], card: card))
        XCTAssertFalse(TellomiLinkOnly.isLinkCardOnly(linkOnlyUrl: url, previewUrls: [url, url], card: card))
        XCTAssertFalse(TellomiLinkOnly.isLinkCardOnly(linkOnlyUrl: nil, previewUrls: [url], card: card))
    }

    func testAPlainCardKeepsOnlyTheDomainAndTheLookalikeWarning() {
        var firstParty = card
        firstParty.level = .firstParty
        firstParty.provider = "tellomi"
        firstParty.kind = "tellomi.official"
        firstParty.description = "Description"
        firstParty.attrs = [TellomiLinkCard.Attr(key: "author", value: "Someone")]
        firstParty.domain = "tellomi.app"
        firstParty.officialBadge = true
        firstParty.firstParty = TellomiLinkCard.FirstParty(type: "official", path: "/download")
        firstParty.lookalike = "tellomi.app"
        firstParty.showImage = true
        firstParty.tintable = true

        XCTAssertEqual(
            TellomiLinkOnly.toPlainLinkCard(firstParty, lookalike: nil),
            TellomiLinkCard(level: .plainLink, domain: "tellomi.app", lookalike: "tellomi.app", showImage: false, tintable: false),
        )
        var imitation = card
        imitation.domain = "bi1ibili.com"
        XCTAssertEqual(TellomiLinkOnly.toPlainLinkCard(imitation, lookalike: "bilibili.com").lookalike, "bilibili.com")
        imitation.lookalike = "apple.com"
        XCTAssertEqual(TellomiLinkOnly.toPlainLinkCard(imitation, lookalike: nil).lookalike, "apple.com")
    }
}
