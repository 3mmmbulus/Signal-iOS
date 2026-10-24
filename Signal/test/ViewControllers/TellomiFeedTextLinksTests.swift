//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 动态正文里的网址可以点（`FeedTextLinks`、`FeedLinkLabel`、长文 `FeedArticleAttributedText.withLinks`）。
final class TellomiFeedTextLinksTests: XCTestCase {

    private func urls(_ text: String) -> [String] {
        return FeedTextLinks.detect(in: text).map(\.url.absoluteString)
    }

    func testFindsHttpAndHttpsLinks() {
        XCTAssertEqual(urls("看这个 https://example.com/a?b=1 还有 http://foo.org"), ["https://example.com/a?b=1", "http://foo.org"])
    }

    func testBareDomainsBecomeHttps() {
        XCTAssertEqual(urls("去 example.com/path 看看"), ["https://example.com/path"])
        XCTAssertEqual(urls("www.taobao.com"), ["https://www.taobao.com"])
    }

    func testIgnoresNonWebSchemesAndEmails() {
        XCTAssertEqual(urls("写信 someone@example.com"), [])
        XCTAssertEqual(urls("mailto:someone@example.com"), [])
        XCTAssertEqual(urls("tel:10086"), [])
        XCTAssertEqual(urls("ftp://example.com/x"), [])
        XCTAssertEqual(urls(""), [])
        XCTAssertEqual(urls("没有链接的一句话"), [])
    }

    func testRangesAreUtf16AndMatchTheText() {
        let text = "😀 中文 https://a.cn/x 尾巴"
        let links = FeedTextLinks.detect(in: text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual((text as NSString).substring(with: links[0].range), "https://a.cn/x")
        XCTAssertEqual(FeedTextLinks.link(atCharacter: links[0].range.location, in: links), links[0])
        XCTAssertNil(FeedTextLinks.link(atCharacter: 0, in: links))
        XCTAssertNil(FeedTextLinks.link(atCharacter: NSMaxRange(links[0].range), in: links), "链接后面那个字不算")
    }

    func testAttributedMarksOnlyTheLink() {
        let text = "a https://b.cn c"
        let links = FeedTextLinks.detect(in: text)
        let attributed = FeedTextLinks.attributed(text, font: .systemFont(ofSize: 15), color: .black, links: links)
        XCTAssertEqual(attributed.string, text)
        XCTAssertEqual(attributed.attribute(.link, at: links[0].range.location, effectiveRange: nil) as? URL, links[0].url)
        XCTAssertNil(attributed.attribute(.link, at: 0, effectiveRange: nil))
    }

    func testArticleBodyGetsLinksAndKeepsFonts() {
        let base = NSAttributedString(string: "读 https://x.cn/a", attributes: [.font: UIFont.boldSystemFont(ofSize: 17)])
        let result = FeedArticleAttributedText.withLinks(base)
        XCTAssertEqual(result.string, base.string)
        XCTAssertNotNil(result.attribute(.link, at: 3, effectiveRange: nil))
        XCTAssertEqual((result.attribute(.font, at: 3, effectiveRange: nil) as? UIFont)?.pointSize, 17)
        let plain = NSAttributedString(string: "没有链接")
        XCTAssertTrue(FeedArticleAttributedText.withLinks(plain) === plain)
    }

    func testLabelOnlyTakesTouchesWhenThereAreLinks() {
        let label = FeedLinkLabel()
        label.setText("没有链接", font: .systemFont(ofSize: 15), color: .black)
        XCTAssertFalse(label.isUserInteractionEnabled, "没链接时点哪里都是「打开帖子」")
        label.setText("有 https://a.cn", font: .systemFont(ofSize: 15), color: .black)
        XCTAssertTrue(label.isUserInteractionEnabled)
        XCTAssertEqual(label.links.count, 1)
        label.setText(nil, font: .systemFont(ofSize: 15), color: .black)
        XCTAssertFalse(label.isUserInteractionEnabled)
        XCTAssertTrue(label.links.isEmpty)
    }

    func testLabelHitTestFindsTheLinkAndNotTheRest() {
        let label = FeedLinkLabel(frame: CGRect(x: 0, y: 0, width: 320, height: 40))
        label.numberOfLines = 0
        label.setText("https://example.com 后面是字", font: .systemFont(ofSize: 15), color: .black)
        XCTAssertEqual(label.link(at: CGPoint(x: 10, y: 20))?.url.absoluteString, "https://example.com")
        XCTAssertNil(label.link(at: CGPoint(x: 310, y: 20)), "行尾空白不算")
        XCTAssertNil(label.link(at: CGPoint(x: 10, y: 38)), "字下面（居中后留的空白）不算")
    }

    /// 产品 2026-10-24：全角中文标点 / 右括号不算进链接（`TellomiLinkPunctuation`，和聊天一样）。
    func testChinesePunctuationEndsTheLink() {
        let text = "看 https://x.com/abc，后面「https://y.com/b」。"
        let links = FeedTextLinks.detect(in: text)
        XCTAssertEqual(links.map { (text as NSString).substring(with: $0.range) }, ["https://x.com/abc", "https://y.com/b"])
        XCTAssertEqual(links.map(\.url.absoluteString), ["https://x.com/abc", "https://y.com/b"])
        XCTAssertEqual(urls("去 example.com/path。"), ["https://example.com/path"])
        XCTAssertEqual(urls("（https://x.com/abc）"), ["https://x.com/abc"])
        XCTAssertEqual(urls("https://x.com/a,b"), ["https://x.com/a,b"])
        XCTAssertEqual(urls("看 https://x.com/abc…"), ["https://x.com/abc"])
        XCTAssertEqual(urls("看 https://x.com/abc—后面"), ["https://x.com/abc"])
        XCTAssertEqual(urls("看 https://x.com/abc－．"), ["https://x.com/abc"])
    }
}
