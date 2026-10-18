//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

/// ADR-0081 §4.3 / §七 3, through the real receive pipeline (encrypted envelope → `MessageProcessor` → `MessageReceiver`):
/// a pin "for me only" that reaches someone else is dropped whole; the same pin without the flag is an ordinary pin; my own pin for
/// me only, synced from my linked device, pins without a "pinned a message".
class TellomiPinForSelfOnlyReceiveTest: SSKBaseTest {

    private let localAci = Aci.randomForTesting()
    private var bobClient: TestSignalClient!
    private var linkedClient: TestSignalClient!
    private lazy var localClient = LocalSignalClient()
    private let runner = TestProtocolRunner()

    override func setUp() {
        super.setUp()

        let identityManager = DependenciesBridge.shared.identityManager
        identityManager.generateAndPersistNewIdentityKey(for: .aci)
        identityManager.generateAndPersistNewIdentityKey(for: .pni)
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .init(aci: localAci, pni: Pni.randomForTesting(), e164: .init("+13235551234")!),
                tx: tx,
            )
            DependenciesBridge.shared.tsAccountManager.setRegistrationId(RegistrationIdGenerator.generate(), for: .aci, tx: tx)
            DependenciesBridge.shared.tsAccountManager.setRegistrationId(RegistrationIdGenerator.generate(), for: .pni, tx: tx)
        }

        bobClient = FakeSignalClient.generate(e164Identifier: "+18083235555")
        linkedClient = localClient.linkedDevice(deviceID: 2)
    }

    override func tearDown() {
        try! SSKEnvironment.shared.databaseStorageRef.grdbStorage.testing_tearDownDatabaseChangeObserver()

        super.tearDown()
    }

    func testBobsPinForHimselfOnlyIsDropped() async throws {
        let target = try await receiveTextFromBob()
        try await acceptBob()

        try await deliver(content(pinOf: target, forSelfOnly: true), from: bobClient)

        read { tx in
            XCTAssertEqual(try! PinnedMessageRecord.fetchCount(tx.database), 0, "not pinned")
            XCTAssertEqual(TSInteraction.anyCount(transaction: tx), 1, "no \"pinned a message\"")
        }
    }

    func testTheSamePinWithoutTheFlagIsAnOrdinaryPin() async throws {
        let target = try await receiveTextFromBob()
        try await acceptBob()

        try await deliver(content(pinOf: target, forSelfOnly: false), from: bobClient)

        read { tx in
            XCTAssertEqual(try! PinnedMessageRecord.fetchCount(tx.database), 1)
            XCTAssertEqual(TSInteraction.anyCount(transaction: tx), 2, "plus \"pinned a message\"")
            XCTAssertFalse(TellomiPinsForMe.isPinnedForMe(interactionId: target.rowId, tx: tx))
        }
    }

    func testMyPinForMeFromMyLinkedDevicePinsWithoutAnUpdate() async throws {
        let target = try await receiveTextFromBob()
        try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            try self.runner.initializePreKeys(senderClient: self.linkedClient, recipientClient: self.localClient, transaction: tx)
        }

        try await deliver(syncContent(pinOf: target, forSelfOnly: true), from: linkedClient)

        read { tx in
            XCTAssertEqual(try! PinnedMessageRecord.fetchCount(tx.database), 1)
            XCTAssertTrue(TellomiPinsForMe.isPinnedForMe(interactionId: target.rowId, tx: tx))
            XCTAssertEqual(TSInteraction.anyCount(transaction: tx), 1, "no \"pinned a message\"")
        }
    }

    // MARK: - Helpers

    private struct Target {
        let timestamp: UInt64
        let rowId: Int64
    }

    private func receiveTextFromBob() async throws -> Target {
        try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            try self.runner.initializePreKeys(senderClient: self.bobClient, recipientClient: self.localClient, transaction: tx)
        }
        let timestamp = MessageTimestampGenerator.sharedInstance.generateTimestamp()
        let dataMessage = SSKProtoDataMessage.builder()
        dataMessage.setTimestamp(timestamp)
        dataMessage.setBody("Pin me")
        let content = SSKProtoContent.builder()
        content.setDataMessage(try! dataMessage.build())

        try await deliver(try! content.build(), from: bobClient)

        return try SSKEnvironment.shared.databaseStorageRef.read { tx in
            let message = try XCTUnwrap(try InteractionFinder.fetchInteractions(timestamp: timestamp, transaction: tx).first as? TSIncomingMessage)
            return Target(timestamp: timestamp, rowId: try XCTUnwrap(message.sqliteRowId))
        }
    }

    /// Bob's chat is no longer a message request, so his ordinary pins count.
    private func acceptBob() async throws {
        await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: self.bobClient.serviceId, tx: tx)
            SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .localUser, tx: tx)
        }
    }

    private func pinMessage(of target: Target, forSelfOnly: Bool) -> SSKProtoDataMessage {
        let pin = SSKProtoDataMessagePinMessage.builder()
        pin.setTargetAuthorAciBinary(bobClient.serviceId.serviceIdBinary)
        pin.setTargetSentTimestamp(target.timestamp)
        pin.setPinDurationForever(true)

        let dataMessage = SSKProtoDataMessage.builder()
        dataMessage.setTimestamp(MessageTimestampGenerator.sharedInstance.generateTimestamp())
        dataMessage.setPinMessage(pin.buildInfallibly())
        if forSelfOnly {
            let tellomi = SSKProtoTellomiDataMessage.builder()
            tellomi.setPinForSelfOnly(true)
            dataMessage.setTellomi(tellomi.buildInfallibly())
        }
        return try! dataMessage.build()
    }

    private func content(pinOf target: Target, forSelfOnly: Bool) -> SSKProtoContent {
        let content = SSKProtoContent.builder()
        content.setDataMessage(pinMessage(of: target, forSelfOnly: forSelfOnly))
        return try! content.build()
    }

    /// The "sent" transcript my linked device sends for a pin in my chat with Bob.
    private func syncContent(pinOf target: Target, forSelfOnly: Bool) -> SSKProtoContent {
        let dataMessage = pinMessage(of: target, forSelfOnly: forSelfOnly)
        let sent = SSKProtoSyncMessageSent.builder()
        sent.setTimestamp(dataMessage.timestamp)
        sent.setDestinationServiceIDBinary(bobClient.serviceId.serviceIdBinary)
        sent.setMessage(dataMessage)
        let syncMessage = SSKProtoSyncMessage.builder()
        syncMessage.setSent(try! sent.build())
        let content = SSKProtoContent.builder()
        content.setSyncMessage(try! syncMessage.build())
        return try! content.build()
    }

    private func deliver(_ content: SSKProtoContent, from sender: TestSignalClient) async throws {
        let plaintext = try content.serializedData()
        let ciphertext = try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            try self.runner.encrypt(plaintext, senderClient: sender, recipient: self.localClient.protocolAddress, context: tx)
        }

        // The envelope carries the message's own timestamp, as a real one does (a transcript must match its message).
        let timestamp = content.dataMessage?.timestamp ?? content.syncMessage?.sent?.timestamp ?? MessageTimestampGenerator.sharedInstance.generateTimestamp()
        let envelopeBuilder = SSKProtoEnvelope.builder(timestamp: timestamp)
        envelopeBuilder.setContent(ciphertext.serialize())
        envelopeBuilder.setType(ciphertext.messageType == .preKey ? .prekeyBundle : .ciphertext)
        envelopeBuilder.setSourceServiceIDBinary(sender.serviceId.serviceIdBinary)
        envelopeBuilder.setSourceDevice(sender.deviceId)
        envelopeBuilder.setServerTimestamp(NSDate.ows_millisecondTimeStamp())
        envelopeBuilder.setServerGuidBinary(UUID().data)
        envelopeBuilder.setDestinationServiceIDBinary(localClient.serviceId.serviceIdBinary)
        let envelopeData = try envelopeBuilder.buildSerializedData()

        await withCheckedContinuation { continuation in
            SSKEnvironment.shared.messageProcessorRef.enqueueReceivedEnvelopeData(
                envelopeData,
                serverDeliveryTimestamp: NSDate.ows_millisecondTimeStamp(),
                envelopeSource: .tests,
            ) { continuation.resume() }
        }
        try await SSKEnvironment.shared.messageProcessorRef.waitForFetchingAndProcessing(stages: [.messageProcessor])
    }
}
