//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

// ---- DRAFT regression (tellomi测试, not pushed) — TF43 P1 links ----
final class TellomiLinkRegressionDraft: XCTestCase {
    private func links(_ text: String) -> [(String, String)] {
        let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return TextCheckingDataItem.detectedItems(in: text, using: detector).filter { $0.dataType == .link }.map { ($0.snippet, $0.url.absoluteString) }
    }
    func testBareDomainIsALinkAndOpensWithHttps() {
        XCTAssertEqual(links("baidu.com").map { $0.1 }, ["https://baidu.com"])
        XCTAssertEqual(links("看 qq.com 吧").map { $0.1 }, ["https://qq.com"])
    }
    func testDomainGluedToChineseIsDetected() {
        XCTAssertEqual(links("打开baidu.com").map { $0.0 }, ["baidu.com"])
        XCTAssertEqual(links("打开baidu.com").map { $0.1 }, ["https://baidu.com"])
    }
    func testCjkPunctuationStaysOutOfTheLink() {
        XCTAssertEqual(links("看 baidu.com。").map { $0.0 }, ["baidu.com"])
        XCTAssertEqual(links("（baidu.com）").map { $0.0 }, ["baidu.com"])
    }
    func testFileNamesAreNotLinks() {
        XCTAssertTrue(links("运行 setup.py").isEmpty)
        XCTAssertTrue(links("看 README.md").isEmpty)
    }
}
