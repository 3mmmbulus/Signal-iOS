//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import SignalServiceKit

extension ThreadUtil {

    // MARK: - Durable Message Enqueue

    public class func enqueueMessage(
        body messageBody: MessageBody?,
        attachments: ([SendableAttachment], isViewOnce: Bool) = ([], isViewOnce: false),
        thread: TSThread,
        quotedReplyDraft: DraftQuotedReplyModel? = nil,
        linkPreviewDraft: OWSLinkPreviewDraft? = nil,
        tellomiCaptionAboveMedia: Bool = false,
        persistenceCompletionHandler persistenceCompletion: PersistenceCompletion? = nil,
    ) {
        let messageTimestamp = MessageTimestampGenerator.sharedInstance.generateTimestamp()

        let benchEventId = sendMessageBenchEventStart(messageTimestamp: messageTimestamp)
        self.enqueueSendQueue.enqueue {
            let unpreparedMessage: UnpreparedOutgoingMessage
            let tellomiMedia: TellomiOutgoingMedia
            do {
                let messageBody = try await messageBody.mapAsync {
                    try await DependenciesBridge.shared.attachmentContentValidator
                        .prepareOversizeTextIfNeeded($0)
                } ?? nil
                let linkPreviewDataSource = try await linkPreviewDraft.mapAsync {
                    try await DependenciesBridge.shared.linkPreviewManager.buildDataSource(from: $0)
                }
                let attachmentContentValidator = DependenciesBridge.shared.attachmentContentValidator
                let attachmentsForSending = try await attachments.0.mapAsync {
                    try await $0.forSending(attachmentContentValidator: attachmentContentValidator)
                }
                tellomiMedia = TellomiOutgoingMedia(spoilers: attachmentsForSending.map(\.isTellomiSpoiler))
                let quotedReplyDraft = try await quotedReplyDraft.mapAsync {
                    try await DependenciesBridge.shared.quotedReplyManager.prepareDraftForSending($0)
                }

                unpreparedMessage = SSKEnvironment.shared.databaseStorageRef.read { readTransaction in
                    UnpreparedOutgoingMessage.build(
                        thread: thread,
                        timestamp: messageTimestamp,
                        messageBody: messageBody,
                        mediaAttachments: attachmentsForSending,
                        isViewOnce: attachments.isViewOnce,
                        quotedReplyDraft: quotedReplyDraft,
                        linkPreviewDataSource: linkPreviewDataSource,
                        transaction: readTransaction,
                    )
                }
            } catch {
                owsFailDebug("Failed to build message")
                return
            }

            await Self.enqueueMessageSync(
                unpreparedMessage,
                benchEventId: benchEventId,
                thread: thread,
                tellomiCaptionAboveMedia: tellomiCaptionAboveMedia,
                tellomiMedia: tellomiMedia,
                persistenceCompletionHandler: persistenceCompletion,
            )
        }
    }

    public class func enqueueEditMessage(
        body messageBody: MessageBody?,
        thread: TSThread,
        quotedReplyEdit: MessageEdits.Edit<Void>,
        linkPreviewDraft: OWSLinkPreviewDraft?,
        editTarget: TSOutgoingMessage,
        persistenceCompletionHandler persistenceCompletion: PersistenceCompletion? = nil,
    ) {
        AssertIsOnMainThread()

        let messageTimestamp = MessageTimestampGenerator.sharedInstance.generateTimestamp()

        let benchEventId = sendMessageBenchEventStart(messageTimestamp: messageTimestamp)
        self.enqueueSendQueue.enqueue {
            let unpreparedMessage: UnpreparedOutgoingMessage
            do {
                let messageBody = try await messageBody.mapAsync {
                    try await DependenciesBridge.shared.attachmentContentValidator
                        .prepareOversizeTextIfNeeded($0)
                } ?? nil
                let linkPreviewDataSource = try await linkPreviewDraft.mapAsync {
                    try await DependenciesBridge.shared.linkPreviewManager.buildDataSource(from: $0)
                }

                unpreparedMessage = UnpreparedOutgoingMessage.buildForEdit(
                    thread: thread,
                    timestamp: messageTimestamp,
                    messageBody: messageBody,
                    quotedReplyEdit: quotedReplyEdit,
                    linkPreviewDataSource: linkPreviewDataSource,
                    editTarget: editTarget,
                )
            } catch {
                owsFailDebug("Failed to build message")
                return
            }

            await Self.enqueueMessageSync(
                unpreparedMessage,
                benchEventId: benchEventId,
                thread: thread,
                persistenceCompletionHandler: persistenceCompletion,
            )
        }
    }

    // MARK: - Durable Message Enqueue

    class func enqueueMessage(
        _ unpreparedMessage: UnpreparedOutgoingMessage,
        thread: TSThread,
        persistenceCompletionHandler persistenceCompletion: PersistenceCompletion? = nil,
    ) {
        let benchEventId = sendMessageBenchEventStart(messageTimestamp: unpreparedMessage.messageTimestampForLogging)
        self.enqueueSendQueue.enqueue {
            await Self.enqueueMessageSync(
                unpreparedMessage,
                benchEventId: benchEventId,
                thread: thread,
                persistenceCompletionHandler: persistenceCompletion,
            )
        }
    }

    /// WARNING: MUST be called on enqueueSendQueue!
    @discardableResult
    private class func enqueueMessageSync(
        _ unpreparedMessage: UnpreparedOutgoingMessage,
        benchEventId: String,
        thread: TSThread,
        tellomiCaptionAboveMedia: Bool = false,
        tellomiMedia: TellomiOutgoingMedia = TellomiOutgoingMedia(),
        tellomiClaim: TellomiEnqueueClaim? = nil,
        persistenceCompletionHandler persistenceCompletion: PersistenceCompletion? = nil,
    ) async -> TellomiEnqueueOutcome {
        return await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { writeTransaction in
            // Tellomi（tellomi/tellomi#1519 M-4）：定时消息的记录已经没了（别处发了 / 删了）或改了时间就不发。
            if let tellomiClaim, !tellomiClaim.isStillDue(writeTransaction) {
                return .notDue
            }
            guard let preparedMessage = try? unpreparedMessage.prepare(tx: writeTransaction) else {
                owsFailDebug("Failed to prepare message")
                return .failedToPrepare
            }
            // Tellomi（#1519 M-4）：建好了才在同一个事务里删定时记录（认领）；建不成记录留着，下次再试。
            tellomiClaim?.claim(writeTransaction)
            // Tellomi（tellomi/tellomi#1263，ADR-0068 §4.7）：进发送队列之前、同一个事务里记上，发送时组 DataMessage 读得到。
            if tellomiCaptionAboveMedia {
                TellomiCaptionAbove.mark(preparedMessage, tx: writeTransaction)
            }
            // Tellomi（#1263，ADR-0068 §4.4）：罩住的图；回复被罩住的图时引用缩略图也罩着。同一个事务里、进发送队列之前。
            TellomiOutgoingMedia.mark(preparedMessage, media: tellomiMedia, tx: writeTransaction)
            let promise = SSKEnvironment.shared.messageSenderJobQueueRef.add(
                .promise,
                message: preparedMessage,
                transaction: writeTransaction,
            )
            if let persistenceCompletion {
                writeTransaction.addSyncCompletion {
                    Task { @MainActor in
                        persistenceCompletion()
                    }
                }
            }
            _ = promise.done(on: DispatchQueue.global()) {
                BenchEventComplete(eventId: benchEventId)
            }

            if
                let messageForIntent = preparedMessage.messageForIntentDonation(tx: writeTransaction),
                let thread = messageForIntent.thread(tx: writeTransaction)
            {
                thread.donateSendMessageIntent(for: messageForIntent, transaction: writeTransaction)
            }
            return .enqueued
        }
    }

    // MARK: - Tellomi

    /// Tellomi（tellomi/tellomi#1519 M-4）：定时消息到点入队时的认领。两步都在落库的那个写事务里，所以几处同时发、
    /// 崩溃重来都只会发一次。
    public struct TellomiEnqueueClaim {
        /// 落库前看（没有副作用）：记录还在、还是到点的。
        public let isStillDue: (DBWriteTransaction) -> Bool
        /// 消息建好以后：删记录。
        public let claim: (DBWriteTransaction) -> Void

        public init(isStillDue: @escaping (DBWriteTransaction) -> Bool, claim: @escaping (DBWriteTransaction) -> Void) {
            self.isStillDue = isStillDue
            self.claim = claim
        }
    }

    public enum TellomiEnqueueOutcome {
        case enqueued
        /// 记录已经没了或改了时间：没落库。
        case notDue
        /// 消息建不成：没认领，记录还在。
        case failedToPrepare
    }

    /// Tellomi（#1519 M-4）：定时消息到点入队。和上面 `enqueueMessage(body:…)` 一样建消息——时间戳 = 现在
    /// （实际发出时刻），阅后即焚取现在的设置（同安卓 `MessageTable.clearScheduledStatus`）——只是落库时按 `claim` 认领，
    /// 而且等落库（或没落库）才返回。
    public class func tellomiEnqueueScheduledMessage(
        body messageBody: MessageBody?,
        attachments: [SendableAttachment.ForSending],
        isViewOnce: Bool,
        thread: TSThread,
        quotedReplyDraft: DraftQuotedReplyModel?,
        linkPreviewDraft: OWSLinkPreviewDraft?,
        captionAboveMedia: Bool,
        claim: TellomiEnqueueClaim,
    ) async throws -> TellomiEnqueueOutcome {
        let messageTimestamp = MessageTimestampGenerator.sharedInstance.generateTimestamp()

        let benchEventId = sendMessageBenchEventStart(messageTimestamp: messageTimestamp)
        let task = self.enqueueSendQueue.enqueue {
            let messageBody = try await messageBody.mapAsync {
                try await DependenciesBridge.shared.attachmentContentValidator
                    .prepareOversizeTextIfNeeded($0)
            } ?? nil
            let linkPreviewDataSource = try await linkPreviewDraft.mapAsync {
                try await DependenciesBridge.shared.linkPreviewManager.buildDataSource(from: $0)
            }
            let quotedReplyDraft = try await quotedReplyDraft.mapAsync {
                try await DependenciesBridge.shared.quotedReplyManager.prepareDraftForSending($0)
            }

            let unpreparedMessage = SSKEnvironment.shared.databaseStorageRef.read { readTransaction in
                UnpreparedOutgoingMessage.build(
                    thread: thread,
                    timestamp: messageTimestamp,
                    messageBody: messageBody,
                    mediaAttachments: attachments,
                    isViewOnce: isViewOnce,
                    quotedReplyDraft: quotedReplyDraft,
                    linkPreviewDataSource: linkPreviewDataSource,
                    transaction: readTransaction,
                )
            }

            return await Self.enqueueMessageSync(
                unpreparedMessage,
                benchEventId: benchEventId,
                thread: thread,
                tellomiCaptionAboveMedia: captionAboveMedia && messageBody != nil,
                tellomiMedia: TellomiOutgoingMedia(spoilers: attachments.map(\.isTellomiSpoiler)),
                tellomiClaim: claim,
            )
        }
        let outcome: TellomiEnqueueOutcome
        do {
            outcome = try await task.value
        } catch {
            BenchEventComplete(eventId: benchEventId)
            throw error
        }
        if outcome != .enqueued {
            BenchEventComplete(eventId: benchEventId)
        }
        return outcome
    }

    private static func sendMessageBenchEventStart(messageTimestamp: UInt64) -> String {
        let eventId = "sendMessageMarkedAsSent-\(messageTimestamp)"
        BenchEventStart(
            title: "Send Message Milestone: Marked as Sent (\(messageTimestamp))",
            eventId: eventId,
            logInProduction: true,
        )
        return eventId
    }
}

// MARK: -

extension UnpreparedOutgoingMessage {

    public static func build(
        thread: TSThread,
        timestamp: UInt64? = nil,
        messageBody: ValidatedMessageBody?,
        mediaAttachments: [SendableAttachment.ForSending] = [],
        isViewOnce: Bool = false,
        quotedReplyDraft: DraftQuotedReplyModel.ForSending?,
        linkPreviewDataSource: LinkPreviewDataSource?,
        transaction: DBReadTransaction,
    ) -> UnpreparedOutgoingMessage {
        assert(!isViewOnce || mediaAttachments.count == 1)
        assert(!mediaAttachments.contains(where: { $0.renderingFlag == .borderless }) || mediaAttachments.count == 1)

        let dmConfigurationStore = DependenciesBridge.shared.disappearingMessagesConfigurationStore
        let dmConfig = dmConfigurationStore.fetchOrBuildDefault(for: .thread(thread), tx: transaction)

        let isVoiceMessage = mediaAttachments.count == 1
            && messageBody?.oversizeText == nil
            && mediaAttachments.last?.renderingFlag == .voiceMessage

        let messageBuilder: TSOutgoingMessageBuilder = .withDefaultValues(thread: thread, timestamp: timestamp)

        messageBuilder.setMessageBody(messageBody)

        messageBuilder.expiresInSeconds = dmConfig.durationSeconds
        messageBuilder.expireTimerVersion = NSNumber(value: dmConfig.timerVersion)
        messageBuilder.isVoiceMessage = isVoiceMessage
        messageBuilder.isViewOnceMessage = isViewOnce

        let message = messageBuilder.build(transaction: transaction)

        let attachmentInfos = mediaAttachments.map(\.dataSource)

        let unpreparedMessage = UnpreparedOutgoingMessage.forMessage(
            message,
            body: messageBody,
            unsavedBodyMediaAttachments: attachmentInfos,
            linkPreviewDraft: linkPreviewDataSource,
            quotedReplyDraft: quotedReplyDraft,
        )
        return unpreparedMessage
    }

    public static func buildForEdit(
        thread: TSThread,
        timestamp: UInt64,
        messageBody: ValidatedMessageBody?,
        quotedReplyEdit: MessageEdits.Edit<Void>,
        linkPreviewDataSource: LinkPreviewDataSource?,
        editTarget: TSOutgoingMessage,
    ) -> UnpreparedOutgoingMessage {

        let oversizeTextDataSource: AttachmentDataSource? = messageBody?.oversizeText.map { .pendingAttachment($0) }

        let edits: MessageEdits = .forOutgoingEdit(
            timestamp: .change(timestamp),
            // "Received" now!
            receivedAtTimestamp: .change(Date.ows_millisecondTimestamp()),
            body: .change(messageBody),
        )

        let unpreparedMessage = UnpreparedOutgoingMessage.forEditMessage(
            targetMessage: editTarget,
            edits: edits,
            oversizeTextDataSource: oversizeTextDataSource,
            linkPreviewDraft: linkPreviewDataSource,
            quotedReplyEdit: quotedReplyEdit,
        )
        return unpreparedMessage
    }
}
