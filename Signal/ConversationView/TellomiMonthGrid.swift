//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（清单 7.2 / F03b）：跳日期月历里的一个月——第一天前空几格、有几天。一行 7 格，从 `calendar.firstWeekday` 开始。
struct TellomiMonthGrid: Equatable {
    /// 这个月 1 号本地 0 点。
    let monthStart: Date
    /// 1 号前面空几格（0...6）。
    let leadingBlanks: Int
    /// 这个月有几天。
    let dayCount: Int

    var itemCount: Int { leadingBlanks + dayCount }

    init?(containing date: Date, calendar: Calendar) {
        guard
            let monthStart = calendar.dateInterval(of: .month, for: date)?.start,
            let range = calendar.range(of: .day, in: .month, for: monthStart)
        else {
            return nil
        }
        let weekday = calendar.component(.weekday, from: monthStart)
        self.monthStart = monthStart
        self.leadingBlanks = (weekday - calendar.firstWeekday + 7) % 7
        self.dayCount = range.count
    }

    /// 第 [item] 格是哪天（0 点）；空格返回 nil。
    func day(at item: Int, calendar: Calendar) -> Date? {
        let dayIndex = item - leadingBlanks
        guard dayIndex >= 0, dayIndex < dayCount else {
            return nil
        }
        return calendar.date(byAdding: .day, value: dayIndex, to: monthStart)
    }

    /// [day] 在这个月的第几格；不在这个月返回 nil。
    func item(of day: Date, calendar: Calendar) -> Int? {
        guard calendar.isDate(day, equalTo: monthStart, toGranularity: .month) else {
            return nil
        }
        return leadingBlanks + calendar.component(.day, from: day) - 1
    }

    /// 从 [earliest] 所在的月到 [latest] 所在的月，按先后排。
    static func months(from earliest: Date, to latest: Date, calendar: Calendar) -> [TellomiMonthGrid] {
        guard var month = TellomiMonthGrid(containing: min(earliest, latest), calendar: calendar) else {
            return []
        }
        let last = max(earliest, latest)
        var result = [month]
        while
            let next = calendar.date(byAdding: .month, value: 1, to: month.monthStart),
            next <= last,
            let nextMonth = TellomiMonthGrid(containing: next, calendar: calendar)
        {
            month = nextMonth
            result.append(month)
        }
        return result
    }

    /// 表头一行星期的缩写，从 `firstWeekday` 开始。
    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else {
            return symbols
        }
        let start = (calendar.firstWeekday - 1 + 7) % 7
        return Array(symbols[start...] + symbols[..<start])
    }
}
