//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

/// Tellomi（chat-telegram-parity F03）：会话里哪些天有消息，某天开头的第一条。
class TellomiConversationDaysTest: SSKBaseTest {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    /// 按给的发出时间插几条消息（插入顺序就是会话里的先后）。
    private func makeThread(sentAt dates: [Date]) -> (TSThread, [TSOutgoingMessage]) {
        write { tx in
            let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(phoneNumber: "+12345678900"), transaction: tx)
            let messages = dates.map { date -> TSOutgoingMessage in
                let builder: TSOutgoingMessageBuilder = .withDefaultValues(
                    thread: thread,
                    timestamp: date.ows_millisecondsSince1970,
                    messageBody: AttachmentContentValidatorMock.mockValidatedBody("hi"),
                )
                let message = TSOutgoingMessage(outgoingMessageWith: builder, recipientAddressStates: [:])
                message.anyInsert(transaction: tx)
                return message
            }
            return (thread, messages)
        }
    }

    func testDaysWithMessagesAreLocalMidnights() {
        let (thread, _) = makeThread(sentAt: [date(16, 23), date(18, 1), date(18, 22)])

        var days = Set<Date>()
        read { tx in days = TellomiConversationDays.daysWithMessages(threadUniqueId: thread.uniqueId, calendar: self.calendar, tx: tx) }

        XCTAssertEqual(days, [date(16, 0), date(18, 0)])
    }

    func testFirstMessageOnOrAfterADay() {
        let (thread, messages) = makeThread(sentAt: [date(16, 23), date(18, 1), date(18, 22)])

        var onTheDay: String?
        var onAnEmptyDay: String?
        var afterTheLast: String?
        read { tx in
            onTheDay = TellomiConversationDays.firstMessageUniqueId(onOrAfter: self.date(18, 0), threadUniqueId: thread.uniqueId, tx: tx)
            onAnEmptyDay = TellomiConversationDays.firstMessageUniqueId(onOrAfter: self.date(17, 0), threadUniqueId: thread.uniqueId, tx: tx)
            afterTheLast = TellomiConversationDays.firstMessageUniqueId(onOrAfter: self.date(19, 0), threadUniqueId: thread.uniqueId, tx: tx)
        }

        XCTAssertEqual(onTheDay, messages[1].uniqueId)
        XCTAssertEqual(onAnEmptyDay, messages[1].uniqueId, "a day without messages goes to the next one that has some")
        XCTAssertNil(afterTheLast)
    }

    func testEditedOldVersionsDoNotCount() {
        let (thread, messages) = write { tx -> (TSThread, [TSOutgoingMessage]) in
            let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(phoneNumber: "+12345678900"), transaction: tx)
            let old: TSOutgoingMessageBuilder = .withDefaultValues(
                thread: thread,
                timestamp: date(15, 9).ows_millisecondsSince1970,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("old"),
                editState: .pastRevision,
            )
            let oldMessage = TSOutgoingMessage(outgoingMessageWith: old, recipientAddressStates: [:])
            oldMessage.anyInsert(transaction: tx)
            let current: TSOutgoingMessageBuilder = .withDefaultValues(
                thread: thread,
                timestamp: date(18, 9).ows_millisecondsSince1970,
                messageBody: AttachmentContentValidatorMock.mockValidatedBody("new"),
            )
            let currentMessage = TSOutgoingMessage(outgoingMessageWith: current, recipientAddressStates: [:])
            currentMessage.anyInsert(transaction: tx)
            return (thread, [oldMessage, currentMessage])
        }

        var days = Set<Date>()
        var first: String?
        read { tx in
            days = TellomiConversationDays.daysWithMessages(threadUniqueId: thread.uniqueId, calendar: self.calendar, tx: tx)
            first = TellomiConversationDays.firstMessageUniqueId(onOrAfter: self.date(15, 0), threadUniqueId: thread.uniqueId, tx: tx)
        }

        XCTAssertEqual(days, [date(18, 0)])
        XCTAssertEqual(first, messages[1].uniqueId)
    }
}
