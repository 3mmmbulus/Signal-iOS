//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// Tellomi (pinned-messages.md 3.5 / 3.6): unpins wait out their "Undo", then go out once, and stay off the bar until they're done.
/// The same cases as Android's `TellomiHeldUnpinsTest`.
class TellomiHeldUnpinsTest: XCTestCase {

    func testUndoPutsThemBackAndNothingGoesOut() {
        var unpins = TellomiHeldUnpins<Int>()
        unpins.hold([1, 2])
        XCTAssertEqual(unpins.held, [1, 2])

        XCTAssertEqual(unpins.undo([1, 2]), [1, 2])
        XCTAssertEqual(unpins.held, [])
        XCTAssertEqual(unpins.commit([1, 2]), [], "too late to send")
    }

    func testAfterTheWaitTheyGoOutOnceAndStayOffTheBarUntilThePinsAreGone() {
        var unpins = TellomiHeldUnpins<Int>()
        unpins.hold([1, 2])

        XCTAssertEqual(unpins.commit([1, 2]), [1, 2])
        XCTAssertEqual(unpins.commit([1, 2]), [], "not twice")
        XCTAssertEqual(unpins.undo([1]), [], "too late to undo")
        XCTAssertEqual(unpins.held, [1, 2], "still sending: still off the bar")

        unpins.prune(pinned: [2, 7])
        XCTAssertEqual(unpins.held, [2], "1 is gone, 2 not yet")
        unpins.prune(pinned: [7])
        XCTAssertEqual(unpins.held, [])
    }

    func testAPinThatCouldNotBeUnpinnedComesBack() {
        var unpins = TellomiHeldUnpins<Int>()
        unpins.hold([1, 2])
        _ = unpins.commit([1, 2])

        unpins.failed([2])
        XCTAssertEqual(unpins.held, [1])
    }

    func testAPinStillWaitingOnUndoStaysOffTheBarWhileThePinsChange() {
        var unpins = TellomiHeldUnpins<Int>()
        unpins.hold([1])
        unpins.prune(pinned: [])
        XCTAssertEqual(unpins.held, [1])
        XCTAssertEqual(unpins.commit([1]), [1])
    }
}
