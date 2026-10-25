//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit

/// 审计 1.3（F19 的一部分）：群里长按自己的消息，「信息」项显示「已读 N/M」。
final class TellomiReadByMenuTitleTests: XCTestCase {

    func testCountsReadAndViewedSkipsSkipped() {
        let counts = TellomiReadByMenuTitle.counts(statuses: [.read, .viewed, .delivered, .sent, .skipped, .failed])
        XCTAssertEqual(counts, TellomiReadByMenuTitle.Counts(read: 2, total: 5))
    }

    func testCountsNoneRead() {
        let counts = TellomiReadByMenuTitle.counts(statuses: [.sending, .sent, .delivered])
        XCTAssertEqual(counts, TellomiReadByMenuTitle.Counts(read: 0, total: 3))
    }

    func testOnlySkippedGivesNilTitle() {
        let counts = TellomiReadByMenuTitle.counts(statuses: [.skipped, .skipped])
        XCTAssertEqual(counts.total, 0)
        XCTAssertNil(TellomiReadByMenuTitle.title(counts: counts))
    }

    func testTitleContainsBothNumbers() throws {
        let title = try XCTUnwrap(TellomiReadByMenuTitle.title(counts: .init(read: 3, total: 5)))
        XCTAssertTrue(title.contains("3"), title)
        XCTAssertTrue(title.contains("5"), title)
        XCTAssertNotEqual(title, OWSLocalizedString("CONTEXT_MENU_DETAILS", comment: ""))
    }
}
