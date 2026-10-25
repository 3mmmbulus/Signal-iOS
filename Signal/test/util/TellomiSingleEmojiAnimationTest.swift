//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import Signal

final class TellomiSingleEmojiAnimationTest: XCTestCase {
    private typealias A = TellomiSingleEmojiAnimation

    func testOnlySingleEmojiAnimates() {
        XCTAssertFalse(A.shouldAnimate(jumbomojiCount: nil, trigger: .appeared, reduceMotion: false, alreadyPlayedOnAppear: false))
        XCTAssertFalse(A.shouldAnimate(jumbomojiCount: 0, trigger: .tapped, reduceMotion: false, alreadyPlayedOnAppear: false))
        XCTAssertTrue(A.shouldAnimate(jumbomojiCount: 1, trigger: .appeared, reduceMotion: false, alreadyPlayedOnAppear: false))
        XCTAssertFalse(A.shouldAnimate(jumbomojiCount: 2, trigger: .tapped, reduceMotion: false, alreadyPlayedOnAppear: false))
        XCTAssertFalse(A.shouldAnimate(jumbomojiCount: 5, trigger: .appeared, reduceMotion: false, alreadyPlayedOnAppear: false))
    }

    func testReduceMotionDisables() {
        XCTAssertFalse(A.shouldAnimate(jumbomojiCount: 1, trigger: .appeared, reduceMotion: true, alreadyPlayedOnAppear: false))
        XCTAssertFalse(A.shouldAnimate(jumbomojiCount: 1, trigger: .tapped, reduceMotion: true, alreadyPlayedOnAppear: false))
    }

    func testAppearPlaysOnceTapAlwaysReplays() {
        XCTAssertFalse(A.shouldAnimate(jumbomojiCount: 1, trigger: .appeared, reduceMotion: false, alreadyPlayedOnAppear: true))
        XCTAssertTrue(A.shouldAnimate(jumbomojiCount: 1, trigger: .tapped, reduceMotion: false, alreadyPlayedOnAppear: true))
    }

    func testKeyframesShape() {
        XCTAssertEqual(A.keyframes.first?.relativeTime, 0)
        XCTAssertEqual(A.keyframes.last?.relativeTime, 1)
        XCTAssertEqual(A.keyframes.last?.scale, 1)
        let times = A.keyframes.map(\.relativeTime)
        XCTAssertEqual(times, times.sorted())
        XCTAssertGreaterThan(A.duration, 0)
        XCTAssertLessThanOrEqual(A.duration, 0.6)
    }
}
