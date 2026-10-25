//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

/// 审计 3.4（F22）：打字时的表情建议，纯逻辑。
class TellomiEmojiSuggestTest: XCTestCase {
    private func s(_ text: String, at cursor: Int? = nil) -> TellomiEmojiSuggestion? {
        let c = cursor ?? (text as NSString).length
        return TellomiEmojiSuggest.suggestion(text: text, selectedRange: NSRange(location: c, length: 0))
    }

    func testColonPrefixQuery() {
        let r = s("hi :smi")
        XCTAssertEqual(r?.query, "smi")
        XCTAssertEqual(r?.emoji.first, "😄")
        XCTAssertEqual(r?.replacementRange, NSRange(location: 3, length: 4))
    }

    func testColonQueryNeedsTwoChars() {
        XCTAssertNil(s(":s"))
        XCTAssertNotNil(s(":lo"))
    }

    func testColonQueryNotAfterWordOrUrl() {
        XCTAssertNil(s("http:lo"))
        XCTAssertNil(s("a::lo"))
        XCTAssertNil(s("https://love"))
    }

    func testWholeEnglishWord() {
        let r = s("I am OK")
        XCTAssertEqual(r?.query, "ok")
        XCTAssertEqual(r?.emoji, ["👌", "🆗"])
        XCTAssertEqual(r?.replacementRange, NSRange(location: 5, length: 2))
        XCTAssertNil(s("smi"), "without colon only whole keywords match")
    }

    func testChineseLongestSuffix() {
        let r = s("祝你生日快乐")
        XCTAssertEqual(r?.query, "生日快乐")
        XCTAssertEqual(r?.replacementRange, NSRange(location: 2, length: 4))
        XCTAssertEqual(s("哈哈哈")?.query, "哈哈")
        XCTAssertEqual(s("太好")?.query, "好")
    }

    func testNoSuggestionMidWordOrWithSelection() {
        XCTAssertNil(s("okay", at: 2))
        XCTAssertNil(s("好的呀", at: 2))
        XCTAssertNil(TellomiEmojiSuggest.suggestion(text: "ok", selectedRange: NSRange(location: 0, length: 2)))
        XCTAssertNil(s(""))
        XCTAssertNil(s("ok "))
    }

    func testCursorInMiddleBeforeSpace() {
        let r = s("lol and more", at: 3)
        XCTAssertEqual(r?.query, "lol")
    }

    func testResultsDedupedAndCapped() {
        let r = s(":l")  // too short
        XCTAssertNil(r)
        let many = s(":c")
        XCTAssertNil(many)
        let love = s(":lo")!
        XCTAssertEqual(Set(love.emoji).count, love.emoji.count)
        XCTAssertLessThanOrEqual(love.emoji.count, TellomiEmojiSuggest.maxResults)
    }

    func testApplyReplacesQueryAndMovesCursor() {
        let text = "好的 :smi"
        let r = s(text)!
        let (out, cursor) = TellomiEmojiSuggest.apply(r, emoji: "😄", to: text)
        XCTAssertEqual(out, "好的 😄")
        XCTAssertEqual(cursor, (out as NSString).length)
    }

    func testEmojiTableHasNoEmptyRowsOrDuplicateKeywords() {
        let kws = TellomiEmojiSuggest.table.map { $0.keyword }
        XCTAssertEqual(Set(kws).count, kws.count)
        XCTAssertTrue(TellomiEmojiSuggest.table.allSatisfy { !$0.emoji.isEmpty })
    }
}
