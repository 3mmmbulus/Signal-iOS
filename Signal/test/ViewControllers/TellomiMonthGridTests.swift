//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 清单 7.2 / F03b：跳日期月历的排格。
final class TellomiMonthGridTests: XCTestCase {

    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testLeadingBlanksFollowFirstWeekday() {
        // 2026-10-01 是星期四。
        let sundayFirst = calendar(firstWeekday: 1)
        let mondayFirst = calendar(firstWeekday: 2)

        let sunday = TellomiMonthGrid(containing: date(2026, 10, 18, calendar: sundayFirst), calendar: sundayFirst)!
        let monday = TellomiMonthGrid(containing: date(2026, 10, 18, calendar: mondayFirst), calendar: mondayFirst)!

        XCTAssertEqual(sunday.leadingBlanks, 4)
        XCTAssertEqual(monday.leadingBlanks, 3)
        XCTAssertEqual(sunday.dayCount, 31)
        XCTAssertEqual(sunday.itemCount, 35)
    }

    func testDayAndItemRoundTrip() {
        let cal = calendar(firstWeekday: 2)
        let grid = TellomiMonthGrid(containing: date(2026, 10, 18, calendar: cal), calendar: cal)!

        XCTAssertNil(grid.day(at: 0, calendar: cal), "blank before the 1st")
        XCTAssertEqual(grid.day(at: 3, calendar: cal), date(2026, 10, 1, calendar: cal))
        XCTAssertEqual(grid.item(of: date(2026, 10, 18, calendar: cal), calendar: cal), 20)
        XCTAssertEqual(grid.day(at: 20, calendar: cal), date(2026, 10, 18, calendar: cal))
        XCTAssertNil(grid.day(at: grid.itemCount, calendar: cal))
        XCTAssertNil(grid.item(of: date(2026, 11, 1, calendar: cal), calendar: cal))
    }

    func testMonthsSpanEarliestToLatest() {
        let cal = calendar(firstWeekday: 1)
        let months = TellomiMonthGrid.months(from: date(2025, 11, 30, calendar: cal), to: date(2026, 2, 1, calendar: cal), calendar: cal)

        XCTAssertEqual(months.map(\.monthStart), [
            date(2025, 11, 1, calendar: cal),
            date(2025, 12, 1, calendar: cal),
            date(2026, 1, 1, calendar: cal),
            date(2026, 2, 1, calendar: cal),
        ])
        XCTAssertEqual(months[3].dayCount, 28)
    }

    func testWeekdaySymbolsStartAtFirstWeekday() {
        XCTAssertEqual(TellomiMonthGrid.weekdaySymbols(calendar: calendar(firstWeekday: 2)), ["M", "T", "W", "T", "F", "S", "S"])
        XCTAssertEqual(TellomiMonthGrid.weekdaySymbols(calendar: calendar(firstWeekday: 1)).first, "S")
    }
}
