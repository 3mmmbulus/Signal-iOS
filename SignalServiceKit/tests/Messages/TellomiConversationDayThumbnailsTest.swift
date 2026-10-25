//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

/// Tellomi（清单 7.2 / F03b）：月历缩略图的取数。
class TellomiConversationDayThumbnailsTest: SSKBaseTest {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func testDayIntervalIsOneLocalDay() {
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 12))!
        let interval = TellomiConversationDayThumbnails.dayInterval(noon, calendar: calendar)!

        XCTAssertEqual(interval.start, calendar.date(from: DateComponents(year: 2026, month: 10, day: 18))!)
        XCTAssertEqual(interval.end, calendar.date(from: DateComponents(year: 2026, month: 10, day: 19))!)
    }

    func testTextOnlyDaysHaveNoThumbnail() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 9))!
        let thread = write { tx -> TSThread in
            let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(phoneNumber: "+12345678900"), transaction: tx)
            let builder: TSOutgoingMessageBuilder = .withDefaultValues(
                thread: thread,
                timestamp: day.ows_millisecondsSince1970,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("hi"),
            )
            TSOutgoingMessage(outgoingMessageWith: builder, recipientAddressStates: [:]).anyInsert(transaction: tx)
            return thread
        }

        var thumbnails = [Date: ReferencedAttachment]()
        read { tx in
            thumbnails = TellomiConversationDayThumbnails.firstVisualMedia(
                threadRowId: thread.sqliteRowId!,
                days: [day],
                calendar: self.calendar,
                tx: tx,
            )
        }

        XCTAssertTrue(thumbnails.isEmpty)
    }
}
