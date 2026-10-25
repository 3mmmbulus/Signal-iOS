//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import Signal

final class TellomiPartialTextSelectionTest: XCTestCase {
    private typealias S = TellomiPartialTextSelection

    func testInitialSelectionPicksWord() {
        let t = "hello world foo"
        XCTAssertEqual(S.initialSelection(at: 7, in: t), NSRange(location: 6, length: 5))
        XCTAssertEqual(S.initialSelection(at: 0, in: t), NSRange(location: 0, length: 5))
        XCTAssertEqual(S.initialSelection(at: 99, in: t), NSRange(location: 12, length: 3))
    }

    func testInitialSelectionCJKIsOneCharacter() {
        let t = "今天天气不错"
        XCTAssertEqual(S.initialSelection(at: 2, in: t), NSRange(location: 2, length: 1))
    }

    func testInitialSelectionEmojiWhole() {
        let t = "hi 👨‍👩‍👧 ok"
        let r = S.initialSelection(at: 4, in: t)
        XCTAssertEqual((t as NSString).substring(with: r), "👨‍👩‍👧")
    }

    func testSnapNeverSplitsGrapheme() {
        let t = "a🇨🇳b"
        let r = S.snapped(NSRange(location: 2, length: 1), in: t)
        XCTAssertEqual((t as NSString).substring(with: r), "🇨🇳")
        XCTAssertEqual(S.snapped(NSRange(location: -3, length: 100), in: t), NSRange(location: 0, length: (t as NSString).length))
    }

    func testDragEndAndStart() {
        let t = "hello world"
        var r = S.drag(.end, to: 11, current: NSRange(location: 6, length: 1), in: t)
        XCTAssertEqual(r.range, NSRange(location: 6, length: 5)); XCTAssertEqual(r.handle, .end)
        r = S.drag(.start, to: 0, current: r.range, in: t)
        XCTAssertEqual(r.range, NSRange(location: 0, length: 11)); XCTAssertEqual(r.handle, .start)
    }

    func testDragPastOtherHandleSwaps() {
        let t = "hello world"
        let r = S.drag(.start, to: 10, current: NSRange(location: 2, length: 3), in: t)
        XCTAssertEqual(r.range, NSRange(location: 5, length: 5))
        XCTAssertEqual(r.handle, .end)
    }

    func testDragNeverEmpty() {
        let t = "abc"
        XCTAssertEqual(S.drag(.end, to: 1, current: NSRange(location: 1, length: 1), in: t).range, NSRange(location: 1, length: 1))
        XCTAssertEqual(S.drag(.start, to: 3, current: NSRange(location: 2, length: 1), in: t).range, NSRange(location: 2, length: 1))
    }

    func testCopyText() {
        let t = "价格 ¥99，明天见"
        XCTAssertEqual(S.textToCopy(NSRange(location: 3, length: 3), in: t), "¥99")
        XCTAssertNil(S.textToCopy(NSRange(location: 2, length: 0), in: t))
        XCTAssertNil(S.textToCopy(NSRange(location: 0, length: 5), in: ""))
    }

    func testIsWholeText() {
        let t = "abc"
        XCTAssertTrue(S.isWholeText(NSRange(location: 0, length: 3), in: t))
        XCTAssertFalse(S.isWholeText(NSRange(location: 1, length: 2), in: t))
    }
}
