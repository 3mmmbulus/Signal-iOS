//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedTextCapTests.swift (new file)
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

final class TellomiFeedTextCapTests: XCTestCase {
    private let flag = "\u{1F1E8}\u{1F1F3}"                                                     // 🇨🇳  1 Character, 2 code points
    private let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"          // 👨‍👩‍👧‍👦 1 Character, 7 code points
    private let thumbsUpMedium = "\u{1F44D}\u{1F3FD}"                                           // 👍🏽 1 Character, 2 code points
    private let eAcute = "e\u{301}"                                                             // é as e + combining acute: 1 Character, 2 code points

    func testTheSamplesReallyDifferBetweenCharactersAndCodePoints() {
        for (sample, characters, scalars) in [(flag, 1, 2), (family, 1, 7), (thumbsUpMedium, 1, 2), (eAcute, 1, 2), ("字", 1, 1), ("😀", 1, 1)] {
            XCTAssertEqual(sample.count, characters)
            XCTAssertEqual(FeedTextCap.count(sample), scalars)
        }
    }

    func testShortTextAndZeroOrNegativeCaps() {
        XCTAssertEqual(FeedTextCap.cap("", codePoints: 5), "")
        XCTAssertEqual(FeedTextCap.cap("abc", codePoints: 5), "abc")
        XCTAssertEqual(FeedTextCap.cap("abc", codePoints: 3), "abc", "刚好等于上限")
        XCTAssertEqual(FeedTextCap.cap("abc", codePoints: 2), "ab")
        XCTAssertEqual(FeedTextCap.cap("abc", codePoints: 0), "")
        XCTAssertEqual(FeedTextCap.cap("abc", codePoints: -3), "")
        XCTAssertTrue(FeedTextCap.fits("abc", codePoints: 3))
        XCTAssertFalse(FeedTextCap.fits("abcd", codePoints: 3))
    }

    func testSingleCodePointCharactersAreCutExactly() {
        XCTAssertEqual(FeedTextCap.cap(String(repeating: "字", count: 600), codePoints: 500), String(repeating: "字", count: 500))
        XCTAssertEqual(FeedTextCap.cap(String(repeating: "😀", count: 501), codePoints: 500), String(repeating: "😀", count: 500))
    }

    func testMultiCodePointCharactersAreCountedLikeTheEngineAndNeverSplit() {
        XCTAssertEqual(FeedTextCap.cap(String(repeating: flag, count: 400), codePoints: 500), String(repeating: flag, count: 250))
        XCTAssertEqual(FeedTextCap.cap(String(repeating: family, count: 10), codePoints: 40), String(repeating: family, count: 5), "5×7 = 35；第 6 个会到 42")
        XCTAssertEqual(FeedTextCap.cap(String(repeating: "a", count: 39) + flag, codePoints: 40), String(repeating: "a", count: 39), "旗放不下就整个去掉，不留半个")
        XCTAssertEqual(FeedTextCap.cap(eAcute + eAcute, codePoints: 3), eAcute, "é = e + 组合符，第二个放不下")
        XCTAssertEqual(FeedTextCap.cap(thumbsUpMedium + thumbsUpMedium, codePoints: 3), thumbsUpMedium)
        XCTAssertEqual(FeedTextCap.cap(family, codePoints: 6), "", "一个字就超过上限：结果是空，不是半个 emoji")
        XCTAssertEqual(FeedTextCap.cap(family, codePoints: 7), family)
    }

    /// 性质：结果一定是原文的 Character 前缀、不超过上限，并且再多放下一个字就会超过（尽量多留）。
    func testResultIsTheLongestCharacterPrefixThatFits() {
        let samples = ["", "plain ascii", "混合 mixed 🇨🇳 text 👨‍👩‍👧‍👦 and e\u{301}", String(repeating: flag, count: 30), family + family + "x"]
        for text in samples {
            for limit in 0...40 {
                let result = FeedTextCap.cap(text, codePoints: limit)
                XCTAssertLessThanOrEqual(FeedTextCap.count(result), limit, "\(text) @\(limit)")
                XCTAssertEqual(result, String(text.prefix(result.count)), "必须是 Character 前缀 \(text) @\(limit)")
                if result.count < text.count {
                    let next = String(text.prefix(result.count + 1))
                    XCTAssertGreaterThan(FeedTextCap.count(next), limit, "再多一个字就超了 \(text) @\(limit)")
                }
            }
        }
    }
}
