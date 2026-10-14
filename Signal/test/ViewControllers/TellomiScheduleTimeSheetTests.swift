//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit

/// Tellomi（tellomi/tellomi#1519 M-4）：「定时发送」选时间的规则，照 Telegram 两端——最早现在 + 1 分钟（抹掉秒）、最晚一年后、
/// 默认下一个整 5 分钟、按钮「今天 / 明天 / 某天 … 发送」（收藏里是「提醒」）、点的时候已过最早时间就推到最早。
final class TellomiScheduleTimeSheetTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    func testTheEarliestIsTheNextWholeMinute() {
        XCTAssertEqual(TellomiScheduleTimeSheet.minimumDate(now: date(14, 10, 2, 37), calendar: calendar), date(14, 10, 3))
        XCTAssertEqual(TellomiScheduleTimeSheet.minimumDate(now: date(14, 10, 2, 0), calendar: calendar), date(14, 10, 3))
    }

    func testTheLatestIsAYearAhead() {
        let now = date(14, 10, 2)
        XCTAssertEqual(TellomiScheduleTimeSheet.maximumDate(now: now), now.addingTimeInterval(365 * 24 * 3600))
    }

    func testTheDefaultIsTheNextFiveMinuteMark() {
        XCTAssertEqual(TellomiScheduleTimeSheet.defaultDate(now: date(14, 10, 2, 37), calendar: calendar), date(14, 10, 5))
        XCTAssertEqual(TellomiScheduleTimeSheet.defaultDate(now: date(14, 10, 4, 59), calendar: calendar), date(14, 10, 5))
        XCTAssertEqual(TellomiScheduleTimeSheet.defaultDate(now: date(14, 10, 5, 20), calendar: calendar), date(14, 10, 10), "on a 5-minute mark: the next one")
        XCTAssertEqual(TellomiScheduleTimeSheet.defaultDate(now: date(14, 23, 58), calendar: calendar), date(15, 0, 0))
    }

    func testAStaleChoiceIsMovedToTheEarliest() {
        let now = date(14, 10, 7, 10)
        XCTAssertEqual(TellomiScheduleTimeSheet.clamped(date(14, 10, 5), now: now, calendar: calendar), date(14, 10, 8))
        XCTAssertEqual(TellomiScheduleTimeSheet.clamped(date(14, 11, 0), now: now, calendar: calendar), date(14, 11, 0))
    }

    func testTheButtonSaysTodayTomorrowOrTheDay() {
        let now = date(14, 10, 2)
        let locale = Locale(identifier: "en_US")
        func title(_ when: Date, reminder: Bool = false) -> String {
            TellomiScheduleTimeSheet.confirmTitle(for: when, now: now, isReminder: reminder, calendar: calendar, locale: locale)
        }
        XCTAssertEqual(title(date(14, 18, 30)), "Send today at 6:30\u{202F}PM")
        XCTAssertEqual(title(date(15, 9, 0)), "Send tomorrow at 9:00\u{202F}AM")
        XCTAssertEqual(title(date(20, 9, 0)), "Send on 10/20/26 at 9:00\u{202F}AM")
        XCTAssertEqual(title(date(14, 18, 30), reminder: true), "Remind today at 6:30\u{202F}PM")
        XCTAssertEqual(title(date(15, 9, 0), reminder: true), "Remind tomorrow at 9:00\u{202F}AM")
        XCTAssertEqual(title(date(20, 9, 0), reminder: true), "Remind on 10/20/26 at 9:00\u{202F}AM")
    }

    /// 打开时：滚轮的上下限和默认值、按钮字；点按钮交出（推过的）时间。
    @MainActor
    func testTheSheetStartsAtTheDefaultAndHandsBackTheChoice() {
        let now = Date()
        var chosen: Date?
        let sheet = TellomiScheduleTimeSheet(isReminder: false, now: { now }) { chosen = $0 }
        sheet.loadViewIfNeeded()

        let picker = sheet.datePickerForTesting
        XCTAssertEqual(picker.datePickerMode, .dateAndTime)
        XCTAssertEqual(picker.preferredDatePickerStyle, .wheels)
        XCTAssertEqual(picker.minimumDate, TellomiScheduleTimeSheet.minimumDate(now: now))
        XCTAssertEqual(picker.maximumDate, TellomiScheduleTimeSheet.maximumDate(now: now))
        XCTAssertEqual(picker.date, TellomiScheduleTimeSheet.defaultDate(now: now))
        XCTAssertEqual(sheet.confirmTitleForTesting, TellomiScheduleTimeSheet.confirmTitle(for: picker.date, now: now, isReminder: false))

        sheet.tapConfirmForTesting()
        XCTAssertEqual(chosen, TellomiScheduleTimeSheet.defaultDate(now: now))
    }

    /// 开着放了一会儿：最早时间跟着往后挪，选着的过去时间被推上来；点按钮时再按当时的「现在」推一次。
    @MainActor
    func testTheEarliestTimeMovesWhileTheSheetIsOpen() {
        var now = Date()
        var chosen: Date?
        let sheet = TellomiScheduleTimeSheet(isReminder: false, now: { now }) { chosen = $0 }
        sheet.loadViewIfNeeded()
        let picker = sheet.datePickerForTesting
        picker.date = TellomiScheduleTimeSheet.minimumDate(now: now)

        now = now.addingTimeInterval(10 * 60)
        sheet.refreshMinimumDateForTesting()
        XCTAssertEqual(picker.minimumDate, TellomiScheduleTimeSheet.minimumDate(now: now))
        XCTAssertEqual(picker.date, TellomiScheduleTimeSheet.minimumDate(now: now))
        XCTAssertEqual(sheet.confirmTitleForTesting, TellomiScheduleTimeSheet.confirmTitle(for: picker.date, now: now, isReminder: false))

        // 定时器还没来得及刷新就点了：照样推到点按钮那一刻的最早时间。
        now = now.addingTimeInterval(5 * 60)
        sheet.tapConfirmForTesting()
        XCTAssertEqual(chosen, TellomiScheduleTimeSheet.minimumDate(now: now))
    }

    /// 高度贴着内容：比滚轮 + 按钮高，又不会大出一截；字号调大时更高。
    @MainActor
    func testTheSheetIsAsTallAsItsContent() {
        let sheet = TellomiScheduleTimeSheet(isReminder: false) { _ in }
        let height = sheet.contentHeight(width: 402)
        XCTAssertGreaterThan(height, 216 + 50)
        XCTAssertLessThan(height, 420)
    }
}
