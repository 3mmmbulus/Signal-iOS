//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedInputLimitTests.swift (new file)
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class TellomiFeedInputLimitTests: XCTestCase {
    private let flag = "\u{1F1E8}\u{1F1F3}"                                                     // 2 code points
    private let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"          // 7 code points
    private func end(_ s: String) -> NSRange { NSRange(location: s.utf16.count, length: 0) }

    func testNamedLimitsMatchTheEngine() {
        XCTAssertEqual(FeedInputLimit.commentText, 500)
        XCTAssertEqual(FeedInputLimit.articleTitle, 100)
        XCTAssertEqual(FeedInputLimit.profileName, 32)
        XCTAssertEqual(FeedInputLimit.profileBio, 200)
        XCTAssertEqual(FeedInputLimit.postText, 500)
        XCTAssertEqual(FeedInputLimit.articleText, 10_000)
    }

    func testTypingBelowTheLimitIsAcceptedAsIs() {
        let e = FeedInputLimit.edit(current: "abc", range: end("abc"), replacement: "d", limit: 5)
        XCTAssertTrue(e.accepted)
        XCTAssertFalse(e.blocked)
        XCTAssertFalse(e.clipped)
        XCTAssertEqual(e.text, "abcd")
        XCTAssertEqual(e.inserted, "d")
        XCTAssertEqual(e.remaining, 1)
        XCTAssertEqual(e.caret, 4)
        XCTAssertFalse(e.limitHit)
    }

    func testTypingExactlyUpToTheLimitIsAccepted() {
        let e = FeedInputLimit.edit(current: "abcd", range: end("abcd"), replacement: "e", limit: 5)
        XCTAssertTrue(e.accepted)
        XCTAssertEqual(e.remaining, 0)
    }

    func testTypingAtTheLimitIsBlockedAndTheTextStaysUnchanged() {
        let e = FeedInputLimit.edit(current: "abcde", range: end("abcde"), replacement: "f", limit: 5)
        XCTAssertFalse(e.accepted)
        XCTAssertTrue(e.blocked)
        XCTAssertFalse(e.clipped)
        XCTAssertEqual(e.text, "abcde")
        XCTAssertEqual(e.inserted, "")
        XCTAssertEqual(e.remaining, 0)
        XCTAssertEqual(e.caret, 5)
        XCTAssertFalse(e.changed)
        XCTAssertTrue(e.limitHit)
    }

    func testDeletingIsAlwaysAllowedEvenWhenTheTextIsOverTheLimit() {
        let over = String(repeating: "a", count: 12)   // 程序设置的过长文本
        let e = FeedInputLimit.edit(current: over, range: NSRange(location: 11, length: 1), replacement: "", limit: 10)
        XCTAssertTrue(e.accepted)
        XCTAssertEqual(e.text.count, 11)
        XCTAssertEqual(e.remaining, -1)
        XCTAssertTrue(e.isOver)
    }

    func testPasteIsClippedToTheLimitByCodePoint() {
        let e = FeedInputLimit.edit(current: "ab", range: end("ab"), replacement: "cdefgh", limit: 5)
        XCTAssertFalse(e.accepted, "截了一部分：钩子要返回 false 并自己设文本")
        XCTAssertFalse(e.blocked)
        XCTAssertTrue(e.clipped)
        XCTAssertEqual(e.text, "abcde")
        XCTAssertEqual(e.inserted, "cde")
        XCTAssertEqual(e.remaining, 0)
        XCTAssertEqual(e.caret, 5)
        XCTAssertTrue(e.changed)
    }

    func testPastedEmojiFlagsAndZWJSequencesAreClippedByCodePointNeverSplit() {
        // 😀 = 1 个码点
        var e = FeedInputLimit.edit(current: "", range: NSRange(location: 0, length: 0), replacement: String(repeating: "😀", count: 10), limit: 4)
        XCTAssertEqual(e.text, String(repeating: "😀", count: 4))
        XCTAssertTrue(e.clipped)
        // 🇨🇳 = 2 个码点：上限 5 只放得下 2 面旗（4 个码点），第 3 面放不下就整个去掉
        e = FeedInputLimit.edit(current: "", range: NSRange(location: 0, length: 0), replacement: String(repeating: flag, count: 5), limit: 5)
        XCTAssertEqual(e.text, String(repeating: flag, count: 2))
        XCTAssertEqual(e.remaining, 1)
        // 家庭 emoji = 7 个码点
        e = FeedInputLimit.edit(current: "", range: NSRange(location: 0, length: 0), replacement: String(repeating: family, count: 3), limit: 15)
        XCTAssertEqual(e.text, String(repeating: family, count: 2))
        XCTAssertEqual(e.remaining, 1)
        // 剩 3 个位置，来了个 7 码点的 emoji：一个字都放不下 → 拦下，不留半个
        e = FeedInputLimit.edit(current: "ab", range: end("ab"), replacement: family, limit: 5)
        XCTAssertTrue(e.blocked)
        XCTAssertEqual(e.text, "ab")
        // 同样的 emoji 剩 7 个位置刚好放得下
        e = FeedInputLimit.edit(current: "ab", range: end("ab"), replacement: family, limit: 9)
        XCTAssertTrue(e.accepted)
        XCTAssertEqual(e.remaining, 0)
    }

    func testReplacingASelectedRangeCountsTheRemovedTextAsFreedRoom() {
        // "abcde" 满了；选中 "bc" 换成 "XYZ"：保留 3，余地 2 → 只放进 "XY"
        var e = FeedInputLimit.edit(current: "abcde", range: NSRange(location: 1, length: 2), replacement: "XYZ", limit: 5)
        XCTAssertTrue(e.clipped)
        XCTAssertEqual(e.text, "aXYde")
        XCTAssertEqual(e.inserted, "XY")
        XCTAssertEqual(e.caret, 3)
        // 满了，选中 1 个字换成 1 个字：放得下（不是 +1）
        e = FeedInputLimit.edit(current: "abcde", range: NSRange(location: 2, length: 1), replacement: "Z", limit: 5)
        XCTAssertTrue(e.accepted)
        XCTAssertEqual(e.text, "abZde")
        // 选中整段换成过长的粘贴：从 0 开始截
        e = FeedInputLimit.edit(current: "abcde", range: NSRange(location: 0, length: 5), replacement: "0123456789", limit: 5)
        XCTAssertEqual(e.text, "01234")
        XCTAssertTrue(e.clipped)
        // 选区里有一个多码点的字：它的码点数算作释放的余地（UTF-16 区间 = 4）
        let text = "a" + flag + "b"
        e = FeedInputLimit.edit(current: text, range: NSRange(location: 1, length: 4), replacement: "XY", limit: 4)
        XCTAssertTrue(e.accepted, "保留 a、b 共 2 个，加 2 个 = 4")
        XCTAssertEqual(e.text, "aXYb")
    }

    func testInsertingInTheMiddleKeepsThePrefixAndSuffix() {
        let e = FeedInputLimit.edit(current: "abXYZ", range: NSRange(location: 2, length: 0), replacement: "12345", limit: 8)
        XCTAssertEqual(e.text, "ab123XYZ")
        XCTAssertEqual(e.inserted, "123")
        XCTAssertEqual(e.caret, 5)
    }

    func testAnInvalidRangeIsBlocked() {
        for range in [NSRange(location: 9, length: 0), NSRange(location: 2, length: 5), NSRange(location: NSNotFound, length: 0), NSRange(location: -1, length: 1)] {
            let e = FeedInputLimit.edit(current: "abc", range: range, replacement: "x", limit: 10)
            XCTAssertTrue(e.blocked, "\(range)")
            XCTAssertEqual(e.text, "abc")
        }
    }

    /// 组字（输入法的候选）：拦或截会把组字弄坏，所以放行，剩余数可以是负的；组字结束后 `clip` 再按码点截一次。
    func testComposingTextIsNeverBlockedOrClippedButIsClippedOnceWhenCompositionEnds() {
        let e = FeedInputLimit.edit(current: "abcde", range: end("abcde"), replacement: "nihao", limit: 5, composing: true)
        XCTAssertTrue(e.accepted)
        XCTAssertFalse(e.blocked)
        XCTAssertFalse(e.clipped)
        XCTAssertEqual(e.text, "abcdenihao")
        XCTAssertEqual(e.remaining, -5)
        XCTAssertTrue(e.isOver)

        XCTAssertEqual(FeedInputLimit.clip(e.text, limit: 5, composing: true).text, e.text, "还在组字：不动")
        let done = FeedInputLimit.clip(e.text, limit: 5)
        XCTAssertTrue(done.clipped)
        XCTAssertEqual(done.text, "abcde")
        XCTAssertEqual(done.remaining, 0)
    }

    func testClipOfAWholeText() {
        XCTAssertTrue(FeedInputLimit.clip("abc", limit: 5).accepted)
        XCTAssertEqual(FeedInputLimit.clip("abc", limit: 5).remaining, 2)
        let cut = FeedInputLimit.clip(String(repeating: family, count: 3), limit: 20)
        XCTAssertEqual(cut.text, String(repeating: family, count: 2))
        XCTAssertTrue(cut.clipped)
        XCTAssertEqual(FeedInputLimit.clip("", limit: 5).remaining, 5)
        XCTAssertEqual(FeedInputLimit.clip("abc", limit: 0).text, "")
        XCTAssertEqual(FeedInputLimit.clip("abc", limit: -3).text, "")
    }

    func testRemainingCountIsInCodePoints() {
        XCTAssertEqual(FeedInputLimit.remaining("", limit: 32), 32)
        XCTAssertEqual(FeedInputLimit.remaining("字字字", limit: 32), 29)
        XCTAssertEqual(FeedInputLimit.remaining(flag, limit: 32), 30)
        XCTAssertEqual(FeedInputLimit.remaining(family, limit: 32), 25)
        XCTAssertEqual(FeedInputLimit.remaining(String(repeating: "a", count: 35), limit: 32), -3)
        XCTAssertTrue(FeedInputLimit.fits("abc", limit: 3))
        XCTAssertFalse(FeedInputLimit.fits("abcd", limit: 3))
    }

    /// 性质：任何输入之后（非组字），文本不会超过上限；上限内的输入文本和「期望值」一致。
    func testNoNonComposingEditEverEndsOverTheLimit() {
        let pieces = ["", "a", "字", "😀", flag, family, "e\u{301}", "hello world 🇨🇳 👨‍👩‍👧‍👦"]
        for limit in [0, 1, 3, 7, 12] {
            for current in pieces {
                guard FeedTextCap.fits(current, codePoints: limit) else { continue }
                for replacement in pieces {
                    for loc in [0, current.utf16.count] {
                        let e = FeedInputLimit.edit(current: current, range: NSRange(location: loc, length: 0), replacement: replacement, limit: limit)
                        XCTAssertLessThanOrEqual(FeedTextCap.count(e.text), limit, "\(current)+\(replacement) @\(limit)")
                        XCTAssertGreaterThanOrEqual(e.remaining, 0)
                    }
                }
            }
        }
    }
}
