//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalUI
import XCTest
@testable import Signal

final class TellomiTextSelectionModelTest: XCTestCase {
    private typealias M = TellomiTextSelectionModel

    func testPlainTextFromText() {
        XCTAssertEqual(M.plainText(.text("你好 world")), "你好 world")
    }

    func testPlainTextDropsLinkAttributes() {
        let attributed = NSMutableAttributedString(string: "看 https://tellomi.com 吧")
        attributed.addAttribute(.link, value: URL(string: "https://tellomi.com")!, range: NSRange(location: 2, length: 19))
        XCTAssertEqual(M.plainText(.attributedText(attributed)), "看 https://tellomi.com 吧")
    }

    func testInitialRangeIsWholeText() {
        let text = "早上好👍🏽"
        XCTAssertEqual(M.initialRange(in: text), NSRange(location: 0, length: (text as NSString).length))
        XCTAssertEqual(M.initialRange(in: ""), NSRange(location: 0, length: 0))
    }

    func testCopyOnlySelectedPart() {
        XCTAssertEqual(M.stringToCopy(selectedRange: NSRange(location: 2, length: 3), in: "你好世界啊"), "世界啊")
    }

    func testCopyNeverSplitsEmoji() {
        let text = "a👍🏽b"
        // 只选中了表情的一半（UTF-16），拷贝时要扩成整个表情
        XCTAssertEqual(M.stringToCopy(selectedRange: NSRange(location: 1, length: 1), in: text), "👍🏽")
    }

    func testCopyEmptyOrOutOfRangeSelection() {
        XCTAssertNil(M.stringToCopy(selectedRange: NSRange(location: 3, length: 0), in: "abc"))
        XCTAssertEqual(M.stringToCopy(selectedRange: NSRange(location: 1, length: 99), in: "abc"), "bc")
    }

    func testSelectableTextViewCopiesPlainSelection() {
        let view = TellomiSelectableTextView()
        view.plainText = "提及 @小明 和链接"
        view.text = view.plainText
        view.selectedRange = NSRange(location: 3, length: 3)
        UIPasteboard.general.string = ""
        view.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string, "@小明")
        XCTAssertFalse(view.canPerformAction(#selector(UIResponderStandardEditActions.paste(_:)), withSender: nil))
    }
}
