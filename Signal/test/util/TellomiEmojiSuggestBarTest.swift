//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import Signal

/// Telegram 对照 3.4（F22）：输入框上方表情建议栏的逻辑。
final class TellomiEmojiSuggestBarTest: XCTestCase {
    private typealias M = TellomiEmojiSuggestBarModel

    private func cursorAtEnd(_ text: String) -> NSRange {
        NSRange(location: (text as NSString).length, length: 0)
    }

    func testNoSuggestionsHidesBar() {
        XCTAssertEqual(M.visibleEmoji(text: "hello there", selectedRange: cursorAtEnd("hello there")), [])
        XCTAssertEqual(M.visibleEmoji(text: "", selectedRange: NSRange(location: 0, length: 0)), [])
    }

    func testColonQueryShowsAtMostEight() {
        let text = "hi :smi"
        let emoji = M.visibleEmoji(text: text, selectedRange: cursorAtEnd(text))
        XCTAssertFalse(emoji.isEmpty)
        XCTAssertLessThanOrEqual(emoji.count, 8)
        XCTAssertEqual(emoji.count, Set(emoji).count, "不重复")
    }

    func testRangeSelectionShowsNothing() {
        let text = "hi :smi"
        XCTAssertEqual(M.visibleEmoji(text: text, selectedRange: NSRange(location: 3, length: 4)), [])
    }

    func testApplyingReplacesQueryAndMovesCursor() throws {
        let text = "hi :smi"
        let first = try XCTUnwrap(M.visibleEmoji(text: text, selectedRange: cursorAtEnd(text)).first)
        let result = try XCTUnwrap(M.applying(emoji: first, text: text, selectedRange: cursorAtEnd(text)))
        XCTAssertEqual(result.text, "hi " + first)
        XCTAssertEqual(result.replacedRange, NSRange(location: 3, length: 4))
        XCTAssertEqual(result.cursor, ("hi " + first as NSString).length)
    }

    func testApplyingUnknownEmojiOrStaleTextIsNil() {
        let text = "hi :smi"
        XCTAssertNil(M.applying(emoji: "🦖🦖", text: text, selectedRange: cursorAtEnd(text)))
        XCTAssertNil(M.applying(emoji: "😄", text: "hi there", selectedRange: cursorAtEnd("hi there")))
    }

    func testBarHidesWhenEmpty() {
        let bar = TellomiEmojiSuggestBar()
        XCTAssertTrue(bar.isHidden)
        XCTAssertTrue(bar.update(emoji: ["😄", "😀"]))
        XCTAssertFalse(bar.isHidden)
        XCTAssertFalse(bar.update(emoji: ["😄"]))
        XCTAssertTrue(bar.update(emoji: []))
        XCTAssertTrue(bar.isHidden)
    }
}
