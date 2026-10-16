//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import QuartzCore
import XCTest

@testable import Signal
@testable import SignalUI

/// 交互审计 A-04：ProMotion 的 iPhone 上逐帧动效能跑过 60 Hz，但每个动效按性质要帧率，不全局拉满。
final class TellomiFrameRateTests: XCTestCase {

    func testTheAppOptsIntoHighRefreshRates() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool, true, "不加这个键，CADisplayLink 在 iPhone 上最高 60 Hz")
    }

    func testFollowTheFingerAsksForUpTo120AndIndicatorsStayAt60() {
        XCTAssertEqual(TellomiFrameRate.interactive.maximum, 120)
        XCTAssertEqual(TellomiFrameRate.interactive.preferred, 120)
        XCTAssertGreaterThanOrEqual(TellomiFrameRate.interactive.minimum, 80)
        XCTAssertEqual(TellomiFrameRate.ambient.maximum, 60)
        XCTAssertLessThanOrEqual(TellomiFrameRate.ambient.minimum, 30)
    }
}
