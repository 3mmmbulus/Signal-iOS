//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// chat-telegram-parity F03（iOS）：日历上只有会话里有消息的日子能选。
final class TellomiJumpToDateTests: XCTestCase {

    func testOnlyDaysWithMessagesCanBePicked() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18))!
        let days: Set<Date> = [day]

        XCTAssertTrue(TellomiJumpToDateViewController.canSelect(DateComponents(year: 2026, month: 10, day: 18), days: days, calendar: calendar))
        XCTAssertFalse(TellomiJumpToDateViewController.canSelect(DateComponents(year: 2026, month: 10, day: 17), days: days, calendar: calendar))
        XCTAssertFalse(TellomiJumpToDateViewController.canSelect(nil, days: days, calendar: calendar))
    }
}
