//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public class OutgoingPinMessage: TransientOutgoingMessage {
    override public class var supportsSecureCoding: Bool { true }

    public required init?(coder: NSCoder) {
        guard let pinDurationForever = coder.decodeObject(of: NSNumber.self, forKey: "pinDurationForever") else {
            return nil
        }
        self.pinDurationForever = pinDurationForever.boolValue
        guard let pinDurationSeconds = coder.decodeObject(of: NSNumber.self, forKey: "pinDurationSeconds") else {
            return nil
        }
        self.pinDurationSeconds = pinDurationSeconds.int32Value
        guard
            let targetMessageAuthorAciBinary = coder.decodeObject(of: NSData.self, forKey: "targetMessageAuthorAciBinary") as Data?,
            let targetMessageAuthorAci = try? Aci.parseFrom(serviceIdBinary: targetMessageAuthorAciBinary)
        else {
            return nil
        }
        self.targetMessageAuthorAci = targetMessageAuthorAci
        guard let targetMessageTimestamp = coder.decodeObject(of: NSNumber.self, forKey: "targetMessageTimestamp") else {
            return nil
        }
        self.targetMessageTimestamp = targetMessageTimestamp.uint64Value
        self.tellomiPinForSelfOnly = coder.decodeBool(forKey: "tellomiPinForSelfOnly")
        self.tellomiPinSilent = coder.decodeBool(forKey: "tellomiPinSilent")
        super.init(coder: coder)
    }

    override public func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(NSNumber(value: self.pinDurationForever), forKey: "pinDurationForever")
        coder.encode(NSNumber(value: self.pinDurationSeconds), forKey: "pinDurationSeconds")
        coder.encode(targetMessageAuthorAci.serviceIdBinary, forKey: "targetMessageAuthorAciBinary")
        coder.encode(NSNumber(value: self.targetMessageTimestamp), forKey: "targetMessageTimestamp")
        coder.encode(tellomiPinForSelfOnly, forKey: "tellomiPinForSelfOnly")
        coder.encode(tellomiPinSilent, forKey: "tellomiPinSilent")
    }

    override public var hash: Int {
        var hasher = Hasher()
        hasher.combine(super.hash)
        hasher.combine(pinDurationForever)
        hasher.combine(pinDurationSeconds)
        hasher.combine(targetMessageAuthorAci)
        hasher.combine(targetMessageTimestamp)
        hasher.combine(tellomiPinForSelfOnly)
        hasher.combine(tellomiPinSilent)
        return hasher.finalize()
    }

    override public func isEqual(_ object: Any?) -> Bool {
        guard let object = object as? Self else { return false }
        guard super.isEqual(object) else { return false }
        guard self.pinDurationForever == object.pinDurationForever else { return false }
        guard self.pinDurationSeconds == object.pinDurationSeconds else { return false }
        guard self.targetMessageAuthorAci == object.targetMessageAuthorAci else { return false }
        guard self.targetMessageTimestamp == object.targetMessageTimestamp else { return false }
        guard self.tellomiPinForSelfOnly == object.tellomiPinForSelfOnly else { return false }
        guard self.tellomiPinSilent == object.tellomiPinSilent else { return false }
        return true
    }

    public let targetMessageTimestamp: UInt64
    public let targetMessageAuthorAci: Aci
    public let pinDurationSeconds: Int32
    private let pinDurationForever: Bool

    /// Tellomi (ADR-0081 §4.3): pin for me only — goes to my own devices in a transcript (`TellomiPinsForMe.send`), never to the chat,
    /// so it needs no permission to pin.
    public var tellomiPinForSelfOnly = false

    /// Tellomi (ADR-0081 §4.6): a group pin for everyone without notifying.
    public var tellomiPinSilent = false

    public init(
        thread: TSThread,
        targetMessageTimestamp: UInt64,
        targetMessageAuthorAciBinary: Aci,
        pinDurationSeconds: Int32,
        pinDurationForever: Bool,
        messageExpiresInSeconds: UInt32,
        tx: DBReadTransaction,
    ) {
        self.targetMessageTimestamp = targetMessageTimestamp
        self.targetMessageAuthorAci = targetMessageAuthorAciBinary
        self.pinDurationSeconds = pinDurationSeconds
        self.pinDurationForever = pinDurationForever

        let builder: TSOutgoingMessageBuilder = .withDefaultValues(
            thread: thread,
            expiresInSeconds: messageExpiresInSeconds,
        )

        super.init(
            outgoingMessageWith: builder,
            additionalRecipients: [],
            explicitRecipients: [],
            skippedRecipients: [],
            transaction: tx,
        )
    }

    override var contentHint: SealedSenderContentHint { .implicit }

    override public func dataMessageBuilder(
        with thread: TSThread,
        transaction: DBReadTransaction,
    ) -> SSKProtoDataMessageBuilder? {
        guard
            let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: transaction)?.aci,
            tellomiPinForSelfOnly || thread.canUserEditPinnedMessages(aci: localAci, tx: transaction)
        else {
            Logger.error("Local user no longer has permission to change pin status")
            return nil
        }

        guard
            let dataMessageBuilder = super.dataMessageBuilder(
                with: thread,
                transaction: transaction,
            )
        else {
            return nil
        }

        let pinMessageBuilder = SSKProtoDataMessagePinMessage.builder()

        pinMessageBuilder.setTargetSentTimestamp(targetMessageTimestamp)

        pinMessageBuilder.setTargetAuthorAciBinary(targetMessageAuthorAci.serviceIdBinary)

        if pinDurationSeconds > 0 {
            pinMessageBuilder.setPinDurationSeconds(UInt32(pinDurationSeconds))
        } else if pinDurationForever {
            pinMessageBuilder.setPinDurationForever(pinDurationForever)
        }

        dataMessageBuilder.setPinMessage(
            pinMessageBuilder.buildInfallibly(),
        )

        if let tellomi = TellomiPinsForMe.tellomiProto(isPin: true, forSelfOnly: tellomiPinForSelfOnly, silent: tellomiPinSilent, isGroup: thread.isGroupThread) {
            dataMessageBuilder.setTellomi(tellomi)
        }

        return dataMessageBuilder
    }

    override public func updateWithSendSuccess(tx: DBWriteTransaction) {
        let pinnedMessageManager = DependenciesBridge.shared.pinnedMessageManager

        var expiresAtMs: UInt64?
        if pinDurationSeconds > 0 {
            let pinDurationMilliseconds = UInt64(pinDurationSeconds) * 1000
            expiresAtMs = Date.ows_millisecondTimestamp() + pinDurationMilliseconds
        }

        pinnedMessageManager.applyPinMessageChangeToLocalState(
            targetTimestamp: targetMessageTimestamp,
            targetAuthorAci: targetMessageAuthorAci,
            expiresAt: expiresAtMs,
            isPin: true,
            sentTimestamp: timestamp,
            threadUniqueId: threadUniqueId,
            tellomiForMeOnly: tellomiPinForSelfOnly,
            tx: tx,
        )
    }
}
