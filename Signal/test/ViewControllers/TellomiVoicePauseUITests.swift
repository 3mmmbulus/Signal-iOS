//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import XCTest

@testable import Signal

/// Telegram 对照 3.3（F12）：锁定录音时暂停 / 继续按钮的逻辑。
final class TellomiVoicePauseUITests: XCTestCase {

    private final class FakeControl: TellomiVoicePauseControlling {
        var isPaused = false
        var tellomiElapsed: TimeInterval = 0
        var canResume = true
        var pauseCalls = 0
        var resumeCalls = 0

        func pauseRecording() -> Bool {
            pauseCalls += 1
            guard !isPaused else { return false }
            isPaused = true
            return true
        }

        func resumeRecording() -> Bool {
            resumeCalls += 1
            guard isPaused, canResume else { return false }
            isPaused = false
            return true
        }
    }

    func testIconAndActionFollowState() {
        XCTAssertEqual(TellomiVoicePauseUI.imageName(isPaused: false), "pause-fill")
        XCTAssertEqual(TellomiVoicePauseUI.imageName(isPaused: true), "play-fill")
        XCTAssertEqual(TellomiVoicePauseUI.action(isPaused: false), .pause)
        XCTAssertEqual(TellomiVoicePauseUI.action(isPaused: true), .resume)
        XCTAssertNotEqual(
            TellomiVoicePauseUI.accessibilityLabel(isPaused: false),
            TellomiVoicePauseUI.accessibilityLabel(isPaused: true),
        )
    }

    func testToggleAlternatesPauseAndResume() {
        let control = FakeControl()
        XCTAssertTrue(TellomiVoicePauseUI.toggle(control))
        XCTAssertEqual(control.pauseCalls, 1)
        XCTAssertFalse(TellomiVoicePauseUI.toggle(control))
        XCTAssertEqual(control.resumeCalls, 1)
        XCTAssertEqual(control.pauseCalls, 1)
    }

    func testFailedResumeStaysPaused() {
        let control = FakeControl()
        control.isPaused = true
        control.canResume = false
        XCTAssertTrue(TellomiVoicePauseUI.toggle(control), "继续失败时按钮仍显示暂停态")
    }

    func testDurationTextUsesElapsed() {
        XCTAssertEqual(TellomiVoicePauseUI.durationText(elapsed: 0), TellomiVoicePauseUI.durationText(elapsed: -3))
        XCTAssertEqual(TellomiVoicePauseUI.durationText(elapsed: 64.6), OWSFormat.formatDurationSeconds(65))
        XCTAssertEqual(TellomiVoicePauseUI.durationText(elapsed: 3.4), OWSFormat.formatDurationSeconds(3))
    }
}
