//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

public enum SentMessageTranscriptTarget {
    case group(TSGroupThread)
    case contact(TSContactThread, VersionedDisappearingMessageToken)

    var thread: TSThread {
        switch self {
        case .group(let thread):
            return thread
        case .contact(let thread, _):
            return thread
        }
    }
}

public enum SentMessageTranscriptType {

    public struct Message {
        public let target: SentMessageTranscriptTarget

        public let body: ValidatedInlineMessageBody?

        public let attachmentPointerProtos: [SSKProtoAttachmentPointer]

        public let validatedContactShare: ValidatedContactShareProto?
        public let validatedQuotedReply: ValidatedQuotedReply?
        public let validatedLinkPreview: ValidatedLinkPreviewProto?
        public let validatedMessageSticker: ValidatedMessageStickerProto?
        public let validatedPollCreate: ValidatedIncomingPollCreate?
        public let giftBadge: OWSGiftBadge?

        public let isViewOnceMessage: Bool

        public let expirationStartedAt: UInt64
        public let expirationDurationSeconds: UInt32
        public let expireTimerVersion: UInt32

        public let storyTimestamp: UInt64?
        public let storyAuthorAci: Aci?

        /// Tellomi（tellomi/tellomi#1263，ADR-0068 §4.7）：`DataMessage.tellomi.captionAboveMedia`。
        public var tellomiCaptionAboveMedia: Bool = false
        /// ADR-0075：`DataMessage.tellomi.messageCaption`（整条消息的说明）。
        public var tellomiMessageCaption: String? = nil
        /// ADR-0079：`DataMessage.tellomi.viewOnceSeconds`（计时的一次性查看）。
        public var tellomiViewOnceSeconds: UInt32? = nil
    }

    public struct PaymentNotification {
        public let target: SentMessageTranscriptTarget
        public let serverTimestamp: UInt64
        public let notification: TSPaymentNotification
    }

    case message(Message)
    case recipientUpdate(TSGroupThread)
    case expirationTimerUpdate(SentMessageTranscriptTarget)
    case paymentNotification(PaymentNotification)
}

/// A transcript for a message that has already been sent, and which came in
/// as a sync message from a linked device.
public protocol SentMessageTranscript {

    var type: SentMessageTranscriptType { get }

    var timestamp: UInt64 { get }

    var requiredProtocolVersion: UInt32? { get }

    var recipientStates: [SignalServiceAddress: TSOutgoingMessageRecipientState] { get }
}

extension SentMessageTranscript {

    public var threadForDataMessage: TSThread? {
        switch type {
        case .expirationTimerUpdate:
            return nil
        case .message(let messageParams):
            return messageParams.target.thread
        case .paymentNotification(let notification):
            return notification.target.thread
        case .recipientUpdate(let thread):
            return thread
        }
    }
}
