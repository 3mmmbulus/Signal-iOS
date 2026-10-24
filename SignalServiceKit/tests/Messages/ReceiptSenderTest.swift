//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

class ReceiptSenderTest: XCTestCase {
    private var mockDb: InMemoryDB!
    private var receiptSender: ReceiptSender!
    private var recipientDatabaseTable: RecipientDatabaseTable!

    override func setUp() {
        super.setUp()

        mockDb = InMemoryDB()
        recipientDatabaseTable = RecipientDatabaseTable()
        receiptSender = ReceiptSender(
            appReadiness: AppReadinessMock(),
            recipientDatabaseTable: recipientDatabaseTable,
        )
    }

    func testMergeAll() {
        // Setup – Store two different receipt sets for an ACI and an e164.
        let aci = Aci.constantForTesting("00000000-0000-4000-8000-0000000000a1")
        let aciReceiptSet = MessageReceiptSet()
        aciReceiptSet.insert(timestamp: 1234, messageUniqueId: "00000000-0000-4000-8000-000000000AAA")

        let e164 = E164("+16505550101")!
        let e164ReceiptSet = MessageReceiptSet()
        e164ReceiptSet.insert(timestamp: 5678, messageUniqueId: "00000000-0000-4000-8000-000000000BBB")

        mockDb.write { tx in
            _ = try! SignalRecipient.insertRecord(aci: aci, phoneNumber: e164, tx: tx)
            receiptSender._storeReceiptSet(aciReceiptSet, receiptType: .delivery, identifier: aci.serviceIdUppercaseString, tx: tx)
            receiptSender._storeReceiptSet(e164ReceiptSet, receiptType: .delivery, identifier: e164.stringValue, tx: tx)
        }

        // Test – Fetch the receipt set for a merged address
        let results = mockDb.read { tx in
            receiptSender.fetchAllReceiptSets(receiptType: .delivery, tx: tx)
        }

        // Verify – All timestamps were fetched and batched together.
        XCTAssertEqual(results.count, 1)
        let receiptSets = results[aci]!.sorted(by: { $0.identifier < $1.identifier })
        XCTAssertEqual(receiptSets[0].identifier, e164.stringValue)
        XCTAssertEqual(receiptSets[0].receiptSet.timestamps, [5678])
        XCTAssertEqual(receiptSets[1].identifier, aci.serviceIdUppercaseString)
        XCTAssertEqual(receiptSets[1].receiptSet.timestamps, [1234])
    }
}

// MARK: - Tellomi（tellomi/tellomi#1184）

/// 已读回执按「消息到达时」的开关判断（需求 message-status-and-read-receipts §3.4 第 3 条、判据 6）。
class TellomiReadReceiptHistoryTest: SSKBaseTest {

    private typealias History = TellomiReadReceiptHistory.History
    private typealias Event = TellomiReadReceiptHistory.Event

    private var receiptManager: OWSReceiptManager { SSKEnvironment.shared.receiptManagerRef }

    func testTheFirstWriteAndWritesThatChangeNothingAreNotSwitches() {
        write { tx in
            receiptManager.setAreReadReceiptsEnabled(true, transaction: tx)
            receiptManager.setAreReadReceiptsEnabled(true, transaction: tx)
            XCTAssertEqual(TellomiReadReceiptHistory.history(tx: tx).events, [])

            receiptManager.setAreReadReceiptsEnabled(false, transaction: tx)
            receiptManager.setAreReadReceiptsEnabled(true, transaction: tx)
            XCTAssertEqual(TellomiReadReceiptHistory.history(tx: tx).events.map(\.enabled), [false, true])
        }
    }

    func testMessagesThatArrivedWhileReadReceiptsWereOffNeverGetAReceipt() {
        write { tx in
            receiptManager.setAreReadReceiptsEnabled(true, transaction: tx)
            TellomiReadReceiptHistory.recordSettingWrite(hadValue: true, previous: true, enabled: false, nowMs: 2000, tx: tx)
            TellomiReadReceiptHistory.recordSettingWrite(hadValue: true, previous: false, enabled: true, nowMs: 3000, tx: tx)

            let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(phoneNumber: "+12223334444"), transaction: tx)
            func arrivedWhileEnabled(_ arrivedAtMs: UInt64) -> Bool {
                let message = TSIncomingMessageBuilder.withDefaultValues(thread: thread, receivedAtTimestamp: arrivedAtMs).build()
                return TellomiReadReceiptHistory.arrivedWhileEnabled(message, tx: tx)
            }

            XCTAssertTrue(arrivedWhileEnabled(1500))
            XCTAssertFalse(arrivedWhileEnabled(2100))
            XCTAssertFalse(arrivedWhileEnabled(2200))
            XCTAssertFalse(arrivedWhileEnabled(2300))
            XCTAssertTrue(arrivedWhileEnabled(3500))
        }
    }

    func testAfterUpgradingWithReadReceiptsOffEverythingBeforeTheFirstSwitchOnCountsAsOff() {
        let history = History(events: [Event(atMs: 2000, enabled: true)], truncated: false)
        XCTAssertFalse(TellomiReadReceiptHistory.wasEnabled(atArrival: 1000, history: history, currentlyEnabled: true))
        XCTAssertTrue(TellomiReadReceiptHistory.wasEnabled(atArrival: 2500, history: history, currentlyEnabled: true))
    }

    func testSwitchesAreReadByTimeNotByTheOrderTheyWereRecordedInWhenTheClockWasMovedBack() {
        let history = History(events: [Event(atMs: 5000, enabled: false), Event(atMs: 3000, enabled: true)], truncated: false)
        XCTAssertTrue(TellomiReadReceiptHistory.wasEnabled(atArrival: 4000, history: history, currentlyEnabled: true))
        XCTAssertFalse(TellomiReadReceiptHistory.wasEnabled(atArrival: 6000, history: history, currentlyEnabled: true))
        XCTAssertFalse(TellomiReadReceiptHistory.wasEnabled(atArrival: 2000, history: history, currentlyEnabled: true))
    }

    func testWithoutAnyRecordedSwitchTheCurrentSettingApplies() {
        XCTAssertTrue(TellomiReadReceiptHistory.wasEnabled(atArrival: 1000, history: .empty, currentlyEnabled: true))
        XCTAssertFalse(TellomiReadReceiptHistory.wasEnabled(atArrival: 1000, history: .empty, currentlyEnabled: false))
    }

    func testOnceOlderSwitchesAreDroppedMessagesFromBeforeTheOldestKeptSwitchCountAsOff() {
        var history = History.empty
        for i in 1...(TellomiReadReceiptHistory.maxEvents + 2) {
            history = TellomiReadReceiptHistory.appending(Event(atMs: UInt64(i) * 1000, enabled: i % 2 == 0), to: history)
        }
        XCTAssertTrue(history.truncated)
        XCTAssertEqual(history.events.count, TellomiReadReceiptHistory.maxEvents)
        XCTAssertFalse(TellomiReadReceiptHistory.wasEnabled(atArrival: 500, history: history, currentlyEnabled: true))
        XCTAssertEqual(
            TellomiReadReceiptHistory.wasEnabled(atArrival: history.events.last!.atMs + 1, history: history, currentlyEnabled: true),
            history.events.last!.enabled,
        )
    }
}
