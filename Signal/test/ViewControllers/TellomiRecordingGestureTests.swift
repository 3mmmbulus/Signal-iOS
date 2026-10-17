//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// Tellomi（交互审计 A-12 iOS 半边）：左滑取消时录音圆和提示跟着进度淡、缩，数和 Android `TellomiRecordingGesture` 同一组。
final class TellomiRecordingGestureTests: XCTestCase {

    func testTheNumbersMatchAndroid() {
        XCTAssertEqual(TellomiRecordingGesture.buttonMinAlpha, 0.5)
        XCTAssertEqual(TellomiRecordingGesture.buttonMinScale, 0.8)
        XCTAssertEqual(TellomiRecordingGesture.hintMinAlpha, 0.3)
    }

    func testNothingChangesBeforeYouSlide() {
        XCTAssertEqual(TellomiRecordingGesture.buttonAlpha(cancelProgress: 0), 1)
        XCTAssertEqual(TellomiRecordingGesture.buttonScale(cancelProgress: 0), 1)
        XCTAssertEqual(TellomiRecordingGesture.hintAlpha(cancelProgress: 0), 1)
    }

    func testHalfwayToTheCancelLineIsHalfwayFaded() {
        XCTAssertEqual(TellomiRecordingGesture.buttonAlpha(cancelProgress: 0.5), 0.75, accuracy: 1e-6)
        XCTAssertEqual(TellomiRecordingGesture.buttonScale(cancelProgress: 0.5), 0.9, accuracy: 1e-6)
        XCTAssertEqual(TellomiRecordingGesture.hintAlpha(cancelProgress: 0.5), 0.65, accuracy: 1e-6)
    }

    /// 到线上（和越过一点）停在下限：圆不会淡没、不会缩成点，提示还看得见。
    func testAtTheLineItStopsAtTheFloor() {
        for progress in [1, 1.2, 5] as [CGFloat] {
            XCTAssertEqual(TellomiRecordingGesture.buttonAlpha(cancelProgress: progress), 0.5, accuracy: 1e-6)
            XCTAssertEqual(TellomiRecordingGesture.buttonScale(cancelProgress: progress), 0.8, accuracy: 1e-6)
            XCTAssertEqual(TellomiRecordingGesture.hintAlpha(cancelProgress: progress), 0.3, accuracy: 1e-6)
        }
        XCTAssertEqual(TellomiRecordingGesture.buttonAlpha(cancelProgress: -1), 1)
    }
}
