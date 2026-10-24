//
// Copyright 2017 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit

public enum MessageReceiptStatus: Int {
    case uploading
    case sending
    case sent
    case delivered
    case read
    case viewed
    case failed
    case skipped
    case pending
}

public class MessageRecipientStatusUtils {

    private init() {}

    // This method is per-recipient.
    public class func recipientStatusAndStatusMessage(
        outgoingMessage: TSOutgoingMessage,
        recipientState: TSOutgoingMessageRecipientState,
        transaction: DBReadTransaction,
    ) -> (status: MessageReceiptStatus, shortStatusMessage: String, longStatusMessage: String) {
        let hasBodyAttachments = outgoingMessage.hasBodyAttachments(transaction: transaction)
        return recipientStatusAndStatusMessage(
            outgoingMessage: outgoingMessage,
            recipientState: recipientState,
            hasBodyAttachments: hasBodyAttachments,
            showsReadStates: OWSReceiptManager.areReadReceiptsEnabled(transaction: transaction),
        )
    }

    // This method is per-recipient.
    /// Tellomi（#1184）：`showsReadStates` 为 false（我关着已读回执）时，已读 / 已查看按已送达显示（对等规则）。
    public class func recipientStatusAndStatusMessage(
        outgoingMessage: TSOutgoingMessage,
        recipientState: TSOutgoingMessageRecipientState,
        hasBodyAttachments: Bool,
        showsReadStates: Bool = true,
    ) -> (status: MessageReceiptStatus, shortStatusMessage: String, longStatusMessage: String) {

        switch tellomiStatusForDisplay(recipientState.status, showsReadStates: showsReadStates) {
        case .failed:
            let shortStatusMessage = OWSLocalizedString("MESSAGE_STATUS_FAILED_SHORT", comment: "status message for failed messages")
            let longStatusMessage = OWSLocalizedString("MESSAGE_STATUS_FAILED", comment: "status message for failed messages")
            return (status: .failed, shortStatusMessage: shortStatusMessage, longStatusMessage: longStatusMessage)
        case .pending:
            let shortStatusMessage = OWSLocalizedString("MESSAGE_STATUS_PENDING_SHORT", comment: "Label indicating that a message send was paused.")
            let longStatusMessage = OWSLocalizedString("MESSAGE_STATUS_PENDING", comment: "Label indicating that a message send was paused.")
            return (status: .pending, shortStatusMessage: shortStatusMessage, longStatusMessage: longStatusMessage)
        case .sending:
            if hasBodyAttachments {
                assert(outgoingMessage.messageState == .sending)

                let statusMessage = OWSLocalizedString(
                    "MESSAGE_STATUS_UPLOADING",
                    comment: "status message while attachment is uploading",
                )
                return (status: .uploading, shortStatusMessage: statusMessage, longStatusMessage: statusMessage)
            } else {
                assert(outgoingMessage.messageState == .sending)

                let statusMessage = OWSLocalizedString(
                    "MESSAGE_STATUS_SENDING",
                    comment: "message status while message is sending.",
                )
                return (status: .sending, shortStatusMessage: statusMessage, longStatusMessage: statusMessage)
            }
        case .sent:
            let timestampString = DateUtil.formatPastTimestampRelativeToNow(outgoingMessage.timestamp)
            let shortStatusMessage = timestampString
            let longStatusMessage = OWSLocalizedString(
                "MESSAGE_STATUS_SENT",
                comment: "status message for sent messages",
            ) + " " + timestampString
            return (status: .sent, shortStatusMessage: shortStatusMessage, longStatusMessage: longStatusMessage)
        case .delivered:
            let timestampString = DateUtil.formatPastTimestampRelativeToNow(recipientState.statusTimestamp)
            let shortStatusMessage = timestampString
            let longStatusMessage = OWSLocalizedString(
                "MESSAGE_STATUS_DELIVERED",
                comment: "message status for message delivered to their recipient.",
            ) + " " + timestampString
            return (status: .delivered, shortStatusMessage: shortStatusMessage, longStatusMessage: longStatusMessage)
        case .read:
            let timestampString = DateUtil.formatPastTimestampRelativeToNow(recipientState.statusTimestamp)
            let shortStatusMessage = timestampString
            let longStatusMessage = OWSLocalizedString("MESSAGE_STATUS_READ", comment: "status message for read messages") + " " + timestampString
            return (status: .read, shortStatusMessage: shortStatusMessage, longStatusMessage: longStatusMessage)
        case .viewed:
            let timestampString = DateUtil.formatPastTimestampRelativeToNow(recipientState.statusTimestamp)
            let shortStatusMessage = timestampString
            let longStatusMessage = OWSLocalizedString("MESSAGE_STATUS_VIEWED", comment: "status message for viewed messages") + " " + timestampString
            return (status: .viewed, shortStatusMessage: shortStatusMessage, longStatusMessage: longStatusMessage)
        case .skipped:
            let statusMessage = OWSLocalizedString(
                "MESSAGE_STATUS_RECIPIENT_SKIPPED",
                comment: "message status if message delivery to a recipient is skipped. We skip delivering group messages to users who have left the group or unregistered their Signal account.",
            )
            return (status: .skipped, shortStatusMessage: statusMessage, longStatusMessage: statusMessage)
        }
    }

    // This method is per-message.
    public class func receiptStatusAndMessage(
        outgoingMessage: TSOutgoingMessage,
        transaction: DBReadTransaction,
    ) -> (status: MessageReceiptStatus, message: String) {
        let hasBodyAttachments = outgoingMessage.hasBodyAttachments(transaction: transaction)
        return receiptStatusAndMessage(
            outgoingMessage: outgoingMessage,
            hasBodyAttachments: hasBodyAttachments,
            showsReadStates: OWSReceiptManager.areReadReceiptsEnabled(transaction: transaction),
        )
    }

    /// Tellomi（#1184）：气泡与聊天列表只有两档勾——已送达并入已发出（一个勾），送达只在「信息」里看；
    /// `showsReadStates` 为 false（我关着已读回执）时，已读 / 已查看也不显示（对等规则，连关之前收到的也藏）。
    public class func receiptStatusAndMessage(
        outgoingMessage: TSOutgoingMessage,
        hasBodyAttachments: Bool,
        showsReadStates: Bool = true,
    ) -> (status: MessageReceiptStatus, message: String) {
        switch outgoingMessage.messageState {
        case .failed:
            // Use the "long" version of this message here.
            return (.failed, OWSLocalizedString("MESSAGE_STATUS_FAILED", comment: "status message for failed messages"))
        case .pending:
            return (.pending, OWSLocalizedString("MESSAGE_STATUS_PENDING", comment: "Label indicating that a message send was paused."))
        case .sending:
            if hasBodyAttachments {
                return (.uploading, OWSLocalizedString(
                    "MESSAGE_STATUS_UPLOADING",
                    comment: "status message while attachment is uploading",
                ))
            } else {
                return (.sending, OWSLocalizedString(
                    "MESSAGE_STATUS_SENDING",
                    comment: "message status while message is sending.",
                ))
            }
        case .sent:
            if showsReadStates, outgoingMessage.viewedRecipientAddresses().count > 0 {
                return (.viewed, OWSLocalizedString("MESSAGE_STATUS_VIEWED", comment: "status message for viewed messages"))
            }
            if showsReadStates, outgoingMessage.readRecipientAddresses().count > 0 {
                return (.read, OWSLocalizedString("MESSAGE_STATUS_READ", comment: "status message for read messages"))
            }
            return (.sent, OWSLocalizedString(
                "MESSAGE_STATUS_SENT",
                comment: "status message for sent messages",
            ))
        default:
            owsFailDebug("Message has unexpected status: \(outgoingMessage.messageState).")
            return (.sent, OWSLocalizedString(
                "MESSAGE_STATUS_SENT",
                comment: "status message for sent messages",
            ))
        }
    }

    // This method is per-message.
    public class func recipientStatus(
        outgoingMessage: TSOutgoingMessage,
        transaction: DBReadTransaction,
    ) -> MessageReceiptStatus {
        let (status, _) = receiptStatusAndMessage(outgoingMessage: outgoingMessage, transaction: transaction)
        return status
    }

    // This method is per-message.
    public class func recipientStatus(
        outgoingMessage: TSOutgoingMessage,
        hasBodyAttachments: Bool,
    ) -> MessageReceiptStatus {
        let (status, _) = receiptStatusAndMessage(outgoingMessage: outgoingMessage, hasBodyAttachments: hasBodyAttachments)
        return status
    }

    public class func recipientStatus(
        outgoingMessage: TSOutgoingMessage,
        paymentModel: TSPaymentModel,
    ) -> MessageReceiptStatus {
        return paymentModel.paymentState.combinedMessageReceiptStatus(with: outgoingMessage)
    }

    @objc
    public class func receiptMessage(
        outgoingMessage: TSOutgoingMessage,
        paymentModel: TSPaymentModel,
    ) -> String {
        let status = paymentModel.paymentState.combinedMessageReceiptStatus(with: outgoingMessage)
        switch status {
        case .failed:
            // Use the "long" version of this message here.
            return OWSLocalizedString(
                "MESSAGE_STATUS_FAILED",
                comment: "status message for failed messages",
            )
        case .pending:
            return OWSLocalizedString(
                "MESSAGE_STATUS_PENDING",
                comment: "Label indicating that a message send was paused.",
            )
        case .sending:
            return OWSLocalizedString(
                "MESSAGE_STATUS_SENDING",
                comment: "message status while message is sending.",
            )
        case .sent:
            return OWSLocalizedString(
                "MESSAGE_STATUS_SENT",
                comment: "status message for sent messages",
            )
        case .delivered:
            return OWSLocalizedString(
                "MESSAGE_STATUS_DELIVERED",
                comment: "message status for message delivered to their recipient.",
            )
        case .read:
            return OWSLocalizedString(
                "MESSAGE_STATUS_READ",
                comment: "status message for read messages",
            )
        case .viewed:
            return OWSLocalizedString(
                "MESSAGE_STATUS_VIEWED",
                comment: "status message for viewed messages",
            )
        case .uploading, .skipped:
            fallthrough
        @unknown default:
            owsFailDebug("Message has unexpected status")
            return OWSLocalizedString(
                "MESSAGE_STATUS_SENT",
                comment: "status message for sent messages",
            )
        }
    }

    public class func description(forMessageReceiptStatus value: MessageReceiptStatus) -> String {
        switch value {
        case .read:
            return "read"
        case .viewed:
            return "viewed"
        case .uploading:
            return "uploading"
        case .delivered:
            return "delivered"
        case .sent:
            return "sent"
        case .sending:
            return "sending"
        case .failed:
            return "failed"
        case .skipped:
            return "skipped"
        case .pending:
            return "pending"
        }
    }
}

// MARK: - Tellomi（tellomi/tellomi#1184，需求 message-status-and-read-receipts §3.1–3.2）

extension MessageRecipientStatusUtils {

    /// 文字消息发送中的转圈要等这么久才露出来（owner 2026-09-24 定）。
    public static let tellomiTextSendingIndicatorDelayMs: UInt64 = 2000

    /// 「信息」页逐人状态：我关着已读回执时，已读 / 已查看按已送达显示。
    static func tellomiStatusForDisplay(_ status: OWSOutgoingMessageRecipientStatus, showsReadStates: Bool) -> OWSOutgoingMessageRecipientStatus {
        if !showsReadStates, status == .read || status == .viewed {
            return .delivered
        }
        return status
    }

    /// 按有没有真正的附件判断「是不是文字」：正文附件（图片 / 视频 / 文件 / 语音 / GIF）和贴纸算附件；
    /// 长文字（oversize text）、引用缩略图、链接预览图、联系人头像都不算（上游 hasBodyAttachments 把长文字也算进去了）。
    public static func tellomiIsTextOnly(outgoingMessage: TSOutgoingMessage, transaction: DBReadTransaction) -> Bool {
        return outgoingMessage.messageSticker == nil && !outgoingMessage.hasMediaAttachments(transaction: transaction)
    }

    /// 发送中的转圈什么时候（毫秒时间戳）才露出来；nil = 立即（有附件）。
    public static func tellomiSendingIndicatorRevealTimestamp(outgoingMessage: TSOutgoingMessage, transaction: DBReadTransaction) -> UInt64? {
        guard tellomiIsTextOnly(outgoingMessage: outgoingMessage, transaction: transaction) else {
            return nil
        }
        return outgoingMessage.timestamp + tellomiTextSendingIndicatorDelayMs
    }

    /// 离露出还剩多少秒；0 = 立即。本机时钟往回拨时最多等 2 秒。
    public static func tellomiSendingIndicatorDelay(revealAtMs: UInt64?, nowMs: UInt64) -> TimeInterval {
        guard let revealAtMs, revealAtMs > nowMs else {
            return 0
        }
        return TimeInterval(min(revealAtMs - nowMs, tellomiTextSendingIndicatorDelayMs)) / 1000
    }
}

extension TSPaymentState {
    public var messageReceiptStatus: MessageReceiptStatus {
        switch self {
        case .outgoingUnsubmitted, .outgoingUnverified, .outgoingSending, .incomingUnverified:
            return .sending
        case .outgoingSent:
            return .sent
        case .outgoingVerified, .incomingVerified:
            return .delivered
        case .outgoingComplete, .incomingComplete:
            return .read
        case .outgoingFailed, .incomingFailed:
            return .failed
        @unknown default:
            Logger.error("Unknown Payment State")
            return .failed
        }
    }

    fileprivate func combinedMessageReceiptStatus(
        with message: TSOutgoingMessage,
    ) -> MessageReceiptStatus {

        // Computed with `TSPaymentModel` && `TSOutgoingMessage.messageState`.
        let status: MessageReceiptStatus = {
            switch (self, message.messageState) {
            case (.incomingFailed, _), (.outgoingFailed, _), (_, .failed):
                return .failed
            case (.incomingVerified, _), (.incomingComplete, _):
                return .delivered
            case (.outgoingVerified, _), (.outgoingComplete, _):
                return .delivered
            case (.outgoingSent, _), (_, .sent):
                return .sent
            case (_, .pending):
                return .pending
            case
                (.outgoingUnsubmitted, _),
                (.outgoingUnverified, _),
                (.outgoingSending, _),
                (.incomingUnverified, _),
                (_, .sending):
                return .sending
            @unknown default:
                Logger.error("Unknown Payment State")
                return .failed
            }
        }()

        switch status {
        case .sent, .delivered:
            // Compute "read"/"viewed" status if available.
            switch message {
            case _ where message.viewedRecipientAddresses().count > 0:
                return .viewed
            case _ where message.readRecipientAddresses().count > 0:
                return .read
            case _ where message.wasDeliveredToAnyRecipient:
                return .delivered
            default:
                return status
            }
        default:
            return status
        }
    }
}
