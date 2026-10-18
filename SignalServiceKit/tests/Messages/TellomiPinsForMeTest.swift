//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

/// Tellomi (ADR-0081 §4.3, §4.6): a pin "for me only" is an ordinary `PinnedMessage` row plus a mark that every new pin row
/// wipes; the pin sheet's choices; the Tellomi fields a pin or an unpin carries. Uses the real `PinnedMessageManager` and database.
class TellomiPinsForMeTest: SSKBaseTest {

    private let author = Aci.randomForTesting()

    private var pinnedMessageManager: PinnedMessageManager {
        DependenciesBridge.shared.pinnedMessageManager
    }

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    // MARK: - Choices

    func testWhatThePinSheetOffers() {
        XCTAssertEqual(TellomiPinChoice.choices(isNoteToSelf: false, isGroup: false, canPinForEveryone: true), [.forBoth, .forMe])
        XCTAssertEqual(TellomiPinChoice.choices(isNoteToSelf: false, isGroup: false, canPinForEveryone: false), [.forBoth, .forMe], "pinning in a 1:1 chat needs no permission")
        XCTAssertEqual(TellomiPinChoice.choices(isNoteToSelf: false, isGroup: true, canPinForEveryone: true), [.forEveryone, .forEveryoneSilent, .forMe])
        XCTAssertEqual(TellomiPinChoice.choices(isNoteToSelf: false, isGroup: true, canPinForEveryone: false), [.forMe], "without permission, only for me")
        XCTAssertNil(TellomiPinChoice.choices(isNoteToSelf: true, isGroup: false, canPinForEveryone: true), "Saved Messages pins without asking")
    }

    // MARK: - On the wire

    func testTheFlagOnlyCountsOnAPinOrAnUnpin() {
        XCTAssertTrue(TellomiPinsForMe.isSelfOnly(dataMessage(pin: true, forSelfOnly: true)))
        XCTAssertTrue(TellomiPinsForMe.isSelfOnly(dataMessage(unpin: true, forSelfOnly: true)))
        XCTAssertFalse(TellomiPinsForMe.isSelfOnly(dataMessage(pin: true, forSelfOnly: false)))
        XCTAssertFalse(TellomiPinsForMe.isSelfOnly(dataMessage(body: "hi", forSelfOnly: true)))
    }

    func testTheTellomiFieldsAPinOrAnUnpinCarries() {
        XCTAssertNil(TellomiPinsForMe.tellomiProto(isPin: true, forSelfOnly: false, silent: false, isGroup: true), "a plain pin keeps upstream bytes")
        XCTAssertNil(TellomiPinsForMe.tellomiProto(isPin: true, forSelfOnly: false, silent: true, isGroup: false), "1:1 pins always notify")
        XCTAssertNil(TellomiPinsForMe.tellomiProto(isPin: false, forSelfOnly: false, silent: true, isGroup: true), "not on an unpin")
        XCTAssertEqual(TellomiPinsForMe.tellomiProto(isPin: true, forSelfOnly: false, silent: true, isGroup: true)?.pinSilent, true)
        XCTAssertEqual(TellomiPinsForMe.tellomiProto(isPin: true, forSelfOnly: true, silent: false, isGroup: false)?.pinForSelfOnly, true)
        XCTAssertEqual(TellomiPinsForMe.tellomiProto(isPin: false, forSelfOnly: true, silent: false, isGroup: true)?.pinForSelfOnly, true)
    }

    // MARK: - Stored

    func testAPinForMeIsAPinThatIsMineOnly() {
        let (thread, interactionId, threadId) = insertThreadAndMessage()

        pinForMe(in: thread)

        read { tx in
            XCTAssertEqual(self.pinnedMessageManager.fetchPinnedMessagesForThread(threadId: threadId, tx: tx).map { $0.sqliteRowId }, [interactionId])
            XCTAssertTrue(TellomiPinsForMe.isPinnedForMe(interactionId: interactionId, tx: tx))
            XCTAssertEqual(TellomiPinsForMe.pinnedForMeInteractionIds(threadId: threadId, tx: tx), [interactionId])
            XCTAssertEqual(TSInteraction.anyCount(transaction: tx), 1, "no \"pinned a message\"")
        }
    }

    func testAnOrdinaryPinOfTheSameMessageMakesItEveryones() {
        let (thread, interactionId, threadId) = insertThreadAndMessage()
        pinForMe(in: thread)

        // What every ordinary pin does: replace the row.
        write { tx in
            self.pinnedMessageManager.deletePinForMessage(interactionId: interactionId, transaction: tx)
            _ = try! PinnedMessageRecord.insertRecord(interactionId: interactionId, threadId: threadId, sentTimestamp: 3000, receivedTimestamp: 3000, tx: tx)
        }

        read { tx in
            XCTAssertEqual(self.pinnedMessageManager.fetchPinnedMessagesForThread(threadId: threadId, tx: tx).count, 1)
            XCTAssertFalse(TellomiPinsForMe.isPinnedForMe(interactionId: interactionId, tx: tx))
        }
    }

    func testAMarkWithoutItsPinIsNotAPin() {
        let (thread, interactionId, threadId) = insertThreadAndMessage()
        pinForMe(in: thread)

        write { tx in
            self.pinnedMessageManager.deletePinForMessage(interactionId: interactionId, transaction: tx)
        }

        read { tx in
            XCTAssertFalse(TellomiPinsForMe.isPinnedForMe(interactionId: interactionId, tx: tx))
            XCTAssertTrue(TellomiPinsForMe.pinnedForMeInteractionIds(threadId: threadId, tx: tx).isEmpty)
        }
    }

    func testASyncedPinForMeFromMyOtherDeviceIsMarkedWithoutAnUpdate() throws {
        let (thread, interactionId, _) = insertThreadAndMessage()
        let pin = SSKProtoDataMessagePinMessage.builder()
        pin.setTargetAuthorAciBinary(author.serviceIdBinary)
        pin.setTargetSentTimestamp(1000)
        pin.setPinDurationForever(true)

        try write { tx in
            try self.pinnedMessageManager.pinMessage(
                pinMessageProto: pin.buildInfallibly(),
                pinAuthor: LocalIdentifiers.forUnitTests.aci,
                thread: thread,
                pinSentAtTimestamp: 2000,
                expireTimer: 0,
                expireTimerVersion: 0,
                tellomiForMeOnly: true,
                transaction: tx,
            )
        }

        read { tx in
            XCTAssertTrue(TellomiPinsForMe.isPinnedForMe(interactionId: interactionId, tx: tx))
            XCTAssertEqual(TSInteraction.anyCount(transaction: tx), 1, "no \"pinned a message\"")
        }
    }

    // MARK: - Unpinned

    func testSomeoneElsesUnpinLeavesMyPinForMeAlone() throws {
        let (thread, interactionId, _) = insertThreadAndMessage()
        pinForMe(in: thread)

        try write { tx in
            _ = try self.pinnedMessageManager.unpinMessage(unpinMessageProto: self.unpin(), threadUniqueId: thread.uniqueId, tellomiRule: .keepPinForMe, transaction: tx)
        }

        read { tx in
            XCTAssertTrue(TellomiPinsForMe.isPinnedForMe(interactionId: interactionId, tx: tx))
        }
    }

    func testMyUnpinForMeTakesAwayOnlyAPinForMe() throws {
        let (thread, interactionId, threadId) = insertThreadAndMessage()
        write { tx in
            _ = try! PinnedMessageRecord.insertRecord(interactionId: interactionId, threadId: threadId, sentTimestamp: 3000, receivedTimestamp: 3000, tx: tx)
        }

        try write { tx in
            _ = try self.pinnedMessageManager.unpinMessage(unpinMessageProto: self.unpin(), threadUniqueId: thread.uniqueId, tellomiRule: .onlyPinForMe, transaction: tx)
        }
        read { tx in
            XCTAssertEqual(self.pinnedMessageManager.fetchPinnedMessagesForThread(threadId: threadId, tx: tx).count, 1, "an ordinary pin stays")
        }

        pinForMe(in: thread)
        try write { tx in
            _ = try self.pinnedMessageManager.unpinMessage(unpinMessageProto: self.unpin(), threadUniqueId: thread.uniqueId, tellomiRule: .onlyPinForMe, transaction: tx)
        }
        read { tx in
            XCTAssertTrue(self.pinnedMessageManager.fetchPinnedMessagesForThread(threadId: threadId, tx: tx).isEmpty)
        }
    }

    // MARK: - Helpers

    private func insertThreadAndMessage() -> (thread: TSThread, interactionId: Int64, threadId: Int64) {
        write { tx in
            let thread = TSContactThread.getOrCreateThread(withContactAddress: SignalServiceAddress(self.author), transaction: tx)
            let message = TSIncomingMessageBuilder.withDefaultValues(thread: thread, timestamp: 1000, authorAci: self.author).build()
            message.anyInsert(transaction: tx)
            return (thread, message.sqliteRowId!, thread.sqliteRowId!)
        }
    }

    private func pinForMe(in thread: TSThread) {
        write { tx in
            self.pinnedMessageManager.applyPinMessageChangeToLocalState(
                targetTimestamp: 1000,
                targetAuthorAci: self.author,
                expiresAt: nil,
                isPin: true,
                sentTimestamp: 2000,
                threadUniqueId: thread.uniqueId,
                tellomiForMeOnly: true,
                tx: tx,
            )
        }
    }

    private func unpin() -> SSKProtoDataMessageUnpinMessage {
        let unpin = SSKProtoDataMessageUnpinMessage.builder()
        unpin.setTargetAuthorAciBinary(author.serviceIdBinary)
        unpin.setTargetSentTimestamp(1000)
        return unpin.buildInfallibly()
    }

    private func dataMessage(pin: Bool = false, unpin: Bool = false, body: String? = nil, forSelfOnly: Bool) -> SSKProtoDataMessage {
        let builder = SSKProtoDataMessage.builder()
        if pin {
            let pinBuilder = SSKProtoDataMessagePinMessage.builder()
            pinBuilder.setTargetAuthorAciBinary(author.serviceIdBinary)
            pinBuilder.setTargetSentTimestamp(1000)
            pinBuilder.setPinDurationForever(true)
            builder.setPinMessage(pinBuilder.buildInfallibly())
        }
        if unpin {
            builder.setUnpinMessage(self.unpin())
        }
        if let body {
            builder.setBody(body)
        }
        if forSelfOnly {
            let tellomi = SSKProtoTellomiDataMessage.builder()
            tellomi.setPinForSelfOnly(true)
            builder.setTellomi(tellomi.buildInfallibly())
        }
        return try! builder.build()
    }
}
