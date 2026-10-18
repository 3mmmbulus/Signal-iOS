//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// Tellomi (pinned-messages.md 3.4): the pinned bar — which pin, its title, the line on its left — as in both Telegram apps.
/// The same cases as Android's `TellomiPinnedBarTest`.
class TellomiPinnedBarTest: XCTestCase {

    private let pins: [UInt64] = [100, 200, 300, 400, 500]

    func testWhileScrollingItShowsTheNewestPinAtOrBeforeTheNewestMessageOnScreen() {
        XCTAssertEqual(TellomiPinnedBar.pinFor(pins, newestVisible: 900), 4, "at the bottom: the newest")
        XCTAssertEqual(TellomiPinnedBar.pinFor(pins, newestVisible: 350), 2)
        XCTAssertEqual(TellomiPinnedBar.pinFor(pins, newestVisible: 300), 2, "on a pinned message")
        XCTAssertEqual(TellomiPinnedBar.pinFor(pins, newestVisible: 50), 0, "above every pin: the oldest")
        XCTAssertEqual(TellomiPinnedBar.pinFor(pins, newestVisible: .max), 4, "nothing on screen yet: the newest")
    }

    func testEachTapGoesToAnOlderPinAndFromTheOldestBackToTheNewest() {
        var index = 4
        var shown = [index]
        for _ in 0..<5 {
            index = TellomiPinnedBar.nextAfterTap(index, count: pins.count)
            shown.append(index)
        }
        XCTAssertEqual(shown, [4, 3, 2, 1, 0, 4])
    }

    func testTitlesOnePinTheOlderOfTwoNumbersFromTheOldest() {
        XCTAssertEqual(TellomiPinnedBar.title(0, count: 1), .pinned)
        XCTAssertEqual(TellomiPinnedBar.title(1, count: 2), .pinned)
        XCTAssertEqual(TellomiPinnedBar.title(0, count: 2), .previous)
        XCTAssertEqual(TellomiPinnedBar.title(6, count: 7), .pinned, "the newest has no number")
        XCTAssertEqual(TellomiPinnedBar.title(0, count: 7), .numbered(1))
        XCTAssertEqual(TellomiPinnedBar.title(5, count: 7), .numbered(6))
    }

    func testTheLineShowsAtMostThreeSegmentsTheSelectedOneInTheMiddleWhereItCan() {
        typealias Segments = TellomiPinnedBar.Segments
        XCTAssertEqual(TellomiPinnedBar.segments(1, count: 2), Segments(first: 0, count: 2, fadeTop: false, fadeBottom: false))
        XCTAssertEqual(TellomiPinnedBar.segments(2, count: 3), Segments(first: 0, count: 3, fadeTop: false, fadeBottom: false))
        XCTAssertEqual(TellomiPinnedBar.segments(0, count: 7), Segments(first: 0, count: 3, fadeTop: false, fadeBottom: true), "the oldest of seven")
        XCTAssertEqual(TellomiPinnedBar.segments(3, count: 7), Segments(first: 2, count: 3, fadeTop: true, fadeBottom: true))
        XCTAssertEqual(TellomiPinnedBar.segments(6, count: 7), Segments(first: 4, count: 3, fadeTop: true, fadeBottom: false), "the newest of seven")
    }

    func testAPinChosenByATapIsLetGoByTheUserScrollingNotByTheJump() {
        XCTAssertFalse(
            TellomiPinnedBar.releasesForcedPin(userDragging: false, newestVisibleBefore: 900, newestVisibleNow: 300, forcedPinPosition: 200),
            "the jump's own scrolling",
        )
        XCTAssertTrue(
            TellomiPinnedBar.releasesForcedPin(userDragging: true, newestVisibleBefore: 300, newestVisibleNow: 320, forcedPinPosition: 200),
            "dragged toward newer messages",
        )
        XCTAssertFalse(
            TellomiPinnedBar.releasesForcedPin(userDragging: true, newestVisibleBefore: 300, newestVisibleNow: 250, forcedPinPosition: 200),
            "dragged toward older, not past it yet",
        )
        XCTAssertTrue(
            TellomiPinnedBar.releasesForcedPin(userDragging: true, newestVisibleBefore: 250, newestVisibleNow: 150, forcedPinPosition: 200),
            "dragged past it",
        )
    }

    func testTheCrossUnpinsAPinForMeAlwaysOtherPinsWithThePermissionInAGroupThatIsStillThere() {
        XCTAssertTrue(TellomiPinChoice.canUnpin(isPinnedForMe: true, canPinForEveryone: false, isTerminatedGroup: true))
        XCTAssertTrue(TellomiPinChoice.canUnpin(isPinnedForMe: false, canPinForEveryone: true, isTerminatedGroup: false))
        XCTAssertFalse(TellomiPinChoice.canUnpin(isPinnedForMe: false, canPinForEveryone: false, isTerminatedGroup: false), "no permission: × hides")
        XCTAssertFalse(TellomiPinChoice.canUnpin(isPinnedForMe: false, canPinForEveryone: true, isTerminatedGroup: true), "the group has ended")
    }

    func testTheListUnpinsAllOnlyWhenEveryPinCanBeUnpinnedOtherwiseItHidesThemHere() {
        XCTAssertTrue(TellomiPinChoice.canUnpinAll(pinnedForMe: [false, true], canPinForEveryone: true, isTerminatedGroup: false))
        XCTAssertTrue(TellomiPinChoice.canUnpinAll(pinnedForMe: [true, true], canPinForEveryone: false, isTerminatedGroup: false), "all of them mine only")
        XCTAssertFalse(TellomiPinChoice.canUnpinAll(pinnedForMe: [true, false], canPinForEveryone: false, isTerminatedGroup: false), "someone else's pin without permission")
        XCTAssertFalse(TellomiPinChoice.canUnpinAll(pinnedForMe: [false], canPinForEveryone: true, isTerminatedGroup: true))
    }

    func testHidingTheBarLastsUntilThereIsANewerPinAndOnlyInThatChat() {
        let db = InMemoryDB()
        db.read { tx in
            XCTAssertFalse(TellomiPinnedBar.isHidden(threadUniqueId: "a", newestPinRowId: 5, tx: tx), "not hidden to begin with")
        }
        db.write { tx in
            TellomiPinnedBar.hide(threadUniqueId: "a", newestPinRowId: 5, tx: tx)
        }
        db.read { tx in
            XCTAssertTrue(TellomiPinnedBar.isHidden(threadUniqueId: "a", newestPinRowId: 5, tx: tx))
            XCTAssertFalse(TellomiPinnedBar.isHidden(threadUniqueId: "a", newestPinRowId: 9, tx: tx), "a newer pin brings it back")
            XCTAssertFalse(TellomiPinnedBar.isHidden(threadUniqueId: "b", newestPinRowId: 5, tx: tx), "another chat")
            XCTAssertEqual(TellomiPinnedBar.hiddenPinRowId(threadUniqueId: "a", tx: tx), 5)
        }
        db.write { tx in
            // "Undo" on "Hide pinned messages" puts back what was there before: here, not hidden.
            TellomiPinnedBar.hide(threadUniqueId: "a", newestPinRowId: nil, tx: tx)
        }
        db.read { tx in
            XCTAssertFalse(TellomiPinnedBar.isHidden(threadUniqueId: "a", newestPinRowId: 5, tx: tx))
            XCTAssertNil(TellomiPinnedBar.hiddenPinRowId(threadUniqueId: "a", tx: tx))
        }
    }
}
