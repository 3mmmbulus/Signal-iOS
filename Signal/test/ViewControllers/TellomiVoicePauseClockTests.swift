//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// Telegram 对照 3.3（F12）：录音暂停 / 继续的时长只算真正在录的时间。
final class TellomiVoicePauseClockTests: XCTestCase {

    func testPausedTimeIsNotCounted() {
        var c = TellomiVoicePauseClock()
        XCTAssertTrue(c.start(at: 100))
        XCTAssertTrue(c.pause(at: 103))
        XCTAssertTrue(c.isPaused)
        XCTAssertEqual(c.elapsed(at: 200), 3, accuracy: 0.0001, "暂停期间不涨")
        XCTAssertTrue(c.resume(at: 200))
        XCTAssertTrue(c.isRecording)
        XCTAssertEqual(c.elapsed(at: 202), 5, accuracy: 0.0001)
        XCTAssertEqual(c.stop(at: 204) ?? -1, 7, accuracy: 0.0001)
        XCTAssertEqual(c.state, .stopped)
    }

    func testStopWhilePausedKeepsRecordedTime() {
        var c = TellomiVoicePauseClock()
        c.start(at: 0)
        c.pause(at: 4)
        XCTAssertEqual(c.stop(at: 60) ?? -1, 4, accuracy: 0.0001)
    }

    func testInvalidTransitionsAreIgnored() {
        var c = TellomiVoicePauseClock()
        XCTAssertFalse(c.pause(at: 1), "没开始不能暂停")
        XCTAssertFalse(c.resume(at: 1), "没暂停不能继续")
        XCTAssertNil(c.stop(at: 1))
        c.start(at: 0)
        XCTAssertFalse(c.start(at: 1), "录音中不能重复开始")
        XCTAssertFalse(c.resume(at: 1), "录音中不能继续")
        c.pause(at: 2)
        XCTAssertFalse(c.pause(at: 3), "已暂停不能再暂停")
        c.stop(at: 3)
        XCTAssertFalse(c.resume(at: 4), "结束后不能继续")
        XCTAssertNil(c.stop(at: 5))
    }

    func testClockGoingBackwardsNeverNegative() {
        var c = TellomiVoicePauseClock()
        c.start(at: 10)
        XCTAssertEqual(c.elapsed(at: 5), 0)
        c.pause(at: 5)
        XCTAssertEqual(c.elapsed(at: 5), 0)
    }
}
