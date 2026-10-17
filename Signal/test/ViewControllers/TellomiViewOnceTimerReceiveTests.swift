//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit

/// ADR-0079 §4.3 (tellomi/tellomi#1714): the bubble of a timed view-once message shows its seconds next to
/// "Photo" / "Video" (both sides), and the viewer counts down with a ring that empties.
final class TellomiViewOnceTimerReceiveTests: XCTestCase {

    func testTheBubbleLabelGetsTheSeconds() {
        let seconds = String(format: OWSLocalizedString("TELLOMI_VIEW_ONCE_SECONDS_SHORT_FORMAT", comment: ""), "10")
        XCTAssertEqual(CVComponentViewOnce.tellomiAppendingSeconds(10, to: "Photo"), "Photo · \(seconds)")
        XCTAssertEqual(CVComponentViewOnce.tellomiAppendingSeconds(nil, to: "Photo"), "Photo", "plain view once: unchanged")
    }

    @MainActor
    func testTheCountdownRingEmptiesOverTheDuration() async throws {
        let ring = TellomiViewOnceCountdownView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        XCTAssertEqual(ring.intrinsicContentSize, CGSize(width: 24, height: 24))
        XCTAssertEqual(ring.remainingFractionForTesting, 1)

        ring.start(duration: 0.4)
        XCTAssertEqual(ring.duration, 0.4)
        XCTAssertEqual(
            ring.accessibilityLabel,
            String(format: OWSLocalizedString("TELLOMI_VIEW_ONCE_COUNTDOWN_FORMAT", comment: ""), "0"),
            "rounded seconds",
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThan(ring.remainingFractionForTesting, 0.75)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(ring.remainingFractionForTesting, 0)
    }
}
