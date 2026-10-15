//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import SignalServiceKit

/// Tellomi (tellomi/tellomi#1366): how often an incoming 1:1 message refetches the sender's profile.
final class TellomiProfileRefreshTest: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRefetchesWhenNeverFetched() {
        XCTAssertTrue(TellomiProfileRefresh.shouldRefreshOnMessage(lastFetchDate: nil, now: now))
    }

    func testRefetchesAnHourAfterTheLastFetchNotBefore() {
        XCTAssertFalse(TellomiProfileRefresh.shouldRefreshOnMessage(lastFetchDate: now.addingTimeInterval(-1 * .minute), now: now))
        XCTAssertFalse(TellomiProfileRefresh.shouldRefreshOnMessage(lastFetchDate: now.addingTimeInterval(-59 * .minute), now: now))
        XCTAssertTrue(TellomiProfileRefresh.shouldRefreshOnMessage(lastFetchDate: now.addingTimeInterval(-1 * .hour), now: now))
        XCTAssertTrue(TellomiProfileRefresh.shouldRefreshOnMessage(lastFetchDate: now.addingTimeInterval(-1 * .day), now: now))
    }

    func testAFetchDateInTheFutureCountsAsDue() {
        XCTAssertTrue(TellomiProfileRefresh.shouldRefreshOnMessage(lastFetchDate: now.addingTimeInterval(1 * .hour), now: now))
    }

    func testRoutineRefreshIsMoreOftenThanUpstream() {
        XCTAssertLessThan(TellomiProfileRefresh.staleFetchInterval, 1 * .day)
        XCTAssertLessThan(TellomiProfileRefresh.staleAfter, 1 * .day)
        XCTAssertLessThanOrEqual(TellomiProfileRefresh.staleFetchInterval, TellomiProfileRefresh.staleAfter)
    }
}
