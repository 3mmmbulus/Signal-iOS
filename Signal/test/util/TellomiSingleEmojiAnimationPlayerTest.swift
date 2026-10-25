//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import Signal

final class TellomiSingleEmojiAnimationPlayerTest: XCTestCase {

    func testAppearPlaysOncePerMessage() {
        let player = TellomiSingleEmojiAnimationPlayer()
        XCTAssertTrue(player.consumeAppear(messageId: "a", jumbomojiCount: 1, reduceMotion: false))
        XCTAssertFalse(player.consumeAppear(messageId: "a", jumbomojiCount: 1, reduceMotion: false))
        XCTAssertTrue(player.consumeAppear(messageId: "b", jumbomojiCount: 1, reduceMotion: false))
    }

    func testNonSingleEmojiAndReduceMotionNeverRecorded() {
        let player = TellomiSingleEmojiAnimationPlayer()
        XCTAssertFalse(player.consumeAppear(messageId: "a", jumbomojiCount: 2, reduceMotion: false))
        XCTAssertFalse(player.consumeAppear(messageId: "a", jumbomojiCount: nil, reduceMotion: false))
        XCTAssertFalse(player.consumeAppear(messageId: "a", jumbomojiCount: 1, reduceMotion: true))
        XCTAssertFalse(player.hasPlayedOnAppear(messageId: "a"))
    }

    func testTapAlwaysReplaysUnlessReduceMotion() {
        let player = TellomiSingleEmojiAnimationPlayer()
        _ = player.consumeAppear(messageId: "a", jumbomojiCount: 1, reduceMotion: false)
        XCTAssertTrue(player.shouldPlayOnTap(jumbomojiCount: 1, reduceMotion: false))
        XCTAssertTrue(player.shouldPlayOnTap(jumbomojiCount: 1, reduceMotion: false))
        XCTAssertFalse(player.shouldPlayOnTap(jumbomojiCount: 1, reduceMotion: true))
        XCTAssertFalse(player.shouldPlayOnTap(jumbomojiCount: 3, reduceMotion: false))
    }

    func testAnimationMatchesKeyframes() {
        let animation = TellomiSingleEmojiAnimationPlayer.makeAnimation()
        XCTAssertEqual(animation.keyPath, "transform.scale")
        XCTAssertEqual(animation.duration, TellomiSingleEmojiAnimation.duration)
        XCTAssertEqual(animation.values?.count, TellomiSingleEmojiAnimation.keyframes.count)
        XCTAssertEqual((animation.values?.last as? NSNumber)?.doubleValue, 1.0)
        XCTAssertEqual((animation.keyTimes?.last)?.doubleValue, 1.0)
    }

    func testPlayAddsAnimationToLayer() {
        let view = UIView()
        TellomiSingleEmojiAnimationPlayer.play(on: view)
        XCTAssertNotNil(view.layer.animation(forKey: TellomiSingleEmojiAnimationPlayer.animationKey))
    }
}
