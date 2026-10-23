//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// 聊天里可点的链接在第一个全角中文标点 / 右括号前结束（产品 2026-10-24，`TellomiLinkPunctuation`）。
final class TellomiLinkPunctuationTest: XCTestCase {

    private let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private func links(_ text: String) -> [String] {
        return TextCheckingDataItem.detectedItems(in: text, using: detector)
            .filter { $0.dataType == .link }
            .map { (text as NSString).substring(with: $0.range) }
    }

    func testCutLength() {
        XCTAssertNil(TellomiLinkPunctuation.cutLength(of: "https://x.com/a,b"))
        XCTAssertEqual(TellomiLinkPunctuation.cutLength(of: "https://x.com/abc，后面"), 17)
        XCTAssertEqual(TellomiLinkPunctuation.cutLength(of: "。"), 0)
        for mark in ["。", "，", "、", "！", "？", "；", "：", "」", "）", "】", "』", "》", "〉", "”", "’"] {
            XCTAssertEqual(TellomiLinkPunctuation.cutLength(of: ("ab" + mark) as NSString), 2, mark)
        }
    }

    func testTrailingChinesePunctuationIsNotPartOfTheLink() {
        XCTAssertEqual(links("看 https://x.com/abc。"), ["https://x.com/abc"])
        XCTAssertEqual(links("快看 https://x.com/abc！"), ["https://x.com/abc"])
        XCTAssertEqual(links("是 https://x.com/abc？"), ["https://x.com/abc"])
        XCTAssertEqual(links("https://x.com/abc）。"), ["https://x.com/abc"])
    }

    func testChinesePunctuationInTheMiddleEndsTheLink() {
        XCTAssertEqual(links("https://x.com/abc，后面"), ["https://x.com/abc"])
        XCTAssertEqual(links("https://x.com/abc；下一个"), ["https://x.com/abc"])
        XCTAssertEqual(links("https://x.com/abc：说明"), ["https://x.com/abc"])
        XCTAssertEqual(links("https://x.com/s?q=1，后面"), ["https://x.com/s?q=1"])
        XCTAssertEqual(links("https://x.com，后面"), ["https://x.com"])
    }

    func testChineseBracketsAroundTheLink() {
        XCTAssertEqual(links("「https://x.com/abc」"), ["https://x.com/abc"])
        XCTAssertEqual(links("（https://x.com/abc）"), ["https://x.com/abc"])
        XCTAssertEqual(links("【https://x.com/abc】"), ["https://x.com/abc"])
    }

    func testUrlOfTrimmedLink() {
        let items = TextCheckingDataItem.detectedItems(in: "https://x.com/abc，后面", using: detector)
        XCTAssertEqual(items.map(\.url.absoluteString), ["https://x.com/abc"])
        let bare = TextCheckingDataItem.detectedItems(in: "打开 signal.org，然后", using: detector)
        XCTAssertEqual(bare.map { (("打开 signal.org，然后") as NSString).substring(with: $0.range) }, ["signal.org"])
    }

    func testAsciiBehaviourUnchanged() {
        XCTAssertEqual(links("https://x.com/a,b"), ["https://x.com/a,b"])
        XCTAssertEqual(links("Visit https://signal.org."), ["https://signal.org"])
        XCTAssertEqual(links("https://en.wikipedia.org/wiki/Foo_(bar)"), ["https://en.wikipedia.org/wiki/Foo_(bar)"])
    }
}
