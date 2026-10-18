//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import GRDB
public import LibSignalClient

/// Tellomi（ADR-0081 §4.4，pinned-messages.md 3.2）：置顶系统消息的那一句——「××置顶了«前 15 个字…»」、「你置顶了一张图片」，
/// 被置顶的那条找不到（删了）就是「××置顶了一条消息」。会话里的系统消息、聊天列表的预览、通知都是这一句（都走
/// `TSInfoMessage.pinnedMessageDescription`）。与安卓 `TellomiPinNotice` 一致。
///
/// 照 Telegram 两端（只读机制，没搬代码）：iOS `TelegramStringFormatting/Sources/ServiceMessageStrings.swift` 置顶那一段
/// （一行、换行变空格，多于 15 个字截成 15 个加省略号；`Notification_PinnedTextMessage` / `…PhotoMessage` 等按内容各一种说法）；
/// 安卓 `MessageObject.java` 置顶那一段（`ActionPinnedText` 截 20 个字，`ActionPinnedPhoto` 等）。两端截的长度不同，取 15。
/// 带说明的图片、视频按媒体说（两端相同）。
public enum TellomiPinNotice {

    /// 引号里最多几个字（Swift 的 `Character` 就是字形，不会拆开表情）。
    static let previewLength = 15

    /// 别人的「为双方」置顶要不要推送：只有群里、而且没选「置顶但不通知」（`pinSilent`）时推；未读、聊天列表照样算。
    /// 单聊不推：Telegram iOS 单聊置顶会推，安卓单聊是静默的（`ChatActivity` 单聊 `checks = {false, false}`），只有一端有，
    /// 按 owner 10-14 的规则不做；「置顶消息」通知开关只有 Telegram 安卓有（`NotificationsSettingsActivity` 的 `PinnedMessages`），
    /// iOS 没有，也不加。
    public static func notifies(silent: Bool, isGroup: Bool) -> Bool {
        return isGroup && !silent
    }

    /// 那一句。`target` 是被置顶的那条（已经换成最新的编辑版本）；nil 就是找不到了。
    static func describe(pinnerIsLocalUser: Bool, pinnerName: String, target: TSMessage?, tx: DBReadTransaction) -> String {
        let subject = target.flatMap { subject(of: $0, tx: tx) } ?? OWSLocalizedString(
            "TELLOMI_PIN_NOTICE_A_MESSAGE",
            comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned when the message is gone. Used in TELLOMI_PIN_NOTICE_YOU / TELLOMI_PIN_NOTICE_OTHER.",
        )
        if pinnerIsLocalUser {
            return String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString(
                    "TELLOMI_PIN_NOTICE_YOU",
                    comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): the local user pinned a message. Embeds {{ what was pinned: a quote, or e.g. 'a photo' }}.",
                ),
                subject,
            )
        }
        return String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString(
                "TELLOMI_PIN_NOTICE_OTHER",
                comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): someone pinned a message. Embeds {{ %1$@ who pinned, %2$@ what was pinned: a quote, or e.g. 'a photo' }}.",
            ),
            pinnerName,
            subject,
        )
    }

    /// 「«…»」或「一张图片」之类；说不出来（删了、空的）就是 nil。
    static func subject(of message: TSMessage, tx: DBReadTransaction) -> String? {
        if message.wasRemotelyDeleted {
            return nil
        }
        if message.contactShare != nil {
            return OWSLocalizedString("TELLOMI_PIN_NOTICE_A_CONTACT", comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned: a contact.")
        }
        if let body = message.body, TellomiLocationMessage.parse(body: body) != nil {
            return OWSLocalizedString("TELLOMI_PIN_NOTICE_A_LOCATION", comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned: a location.")
        }
        if message.isPoll {
            return OWSLocalizedString("TELLOMI_PIN_NOTICE_A_POLL", comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned: a poll.")
        }
        if message.messageSticker != nil {
            return OWSLocalizedString("TELLOMI_PIN_NOTICE_A_STICKER", comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned: a sticker.")
        }
        if
            let rowId = message.sqliteRowId,
            let first = DependenciesBridge.shared.attachmentStore.fetchReferencedAttachments(for: .messageBodyAttachment(messageRowId: rowId), tx: tx).first
        {
            return mediaSubject(mimeType: first.attachment.mimeType, renderingFlag: first.reference.renderingFlag)
        }

        let text = MessageBody(text: message.body ?? "", ranges: message.bodyRanges ?? .empty)
            .hydrating(mentionHydrator: ContactsMentionHydrator.mentionHydrator(transaction: tx))
            .asPlaintext()
        let clipped = clip(text)
        guard !clipped.isEmpty else {
            return nil
        }
        return String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString(
                "TELLOMI_PIN_NOTICE_QUOTE",
                comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): the first characters of a pinned text message, quoted. Embeds {{ the text }}.",
            ),
            clipped,
        )
    }

    static func mediaSubject(mimeType: String, renderingFlag: AttachmentReference.RenderingFlag) -> String {
        if renderingFlag == .voiceMessage {
            return OWSLocalizedString("TELLOMI_PIN_NOTICE_A_VOICE_MESSAGE", comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned: a voice message.")
        }
        if renderingFlag == .shouldLoop || MimeTypeUtil.isSupportedDefinitelyAnimatedMimeType(mimeType) {
            return OWSLocalizedString("TELLOMI_PIN_NOTICE_A_GIF", comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned: a GIF.")
        }
        if MimeTypeUtil.isSupportedVideoMimeType(mimeType) {
            return OWSLocalizedString("TELLOMI_PIN_NOTICE_A_VIDEO", comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned: a video.")
        }
        if MimeTypeUtil.isSupportedImageMimeType(mimeType) {
            return OWSLocalizedString("TELLOMI_PIN_NOTICE_A_PHOTO", comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned: a photo.")
        }
        if MimeTypeUtil.isSupportedAudioMimeType(mimeType) {
            return OWSLocalizedString("TELLOMI_PIN_NOTICE_AN_AUDIO_FILE", comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned: an audio file (not a voice message).")
        }
        return OWSLocalizedString("TELLOMI_PIN_NOTICE_A_FILE", comment: "Tellomi (ADR-0081, pinned-messages.md 3.2): what was pinned: a file.")
    }

    /// 一行（换行变空格），多于 15 个字截断加「…」。
    public static func clip(_ text: String) -> String {
        let oneLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard oneLine.count > previewLength else {
            return oneLine
        }
        return String(oneLine.prefix(previewLength)) + "…"
    }
}

extension TSInfoMessage {

    /// Tellomi (ADR-0081 §4.4): "×× pinned «…»" for a pinned-message info message, reading what was pinned (its latest edit).
    /// `thirdPerson`: my own pin is "<my name> pinned «…»", not "You pinned «…»" (the line a reply carries as its quote).
    func tellomiPinnedMessageDescription(item: PersistablePinnedMessageItem, localAci: Aci, thirdPerson: Bool = false, tx: DBReadTransaction) -> String {
        var target = try? DependenciesBridge.shared.interactionStore.fetchMessage(
            timestamp: UInt64(item.timestamp),
            incomingMessageAuthor: localAci == item.originalMessageAuthorAci ? nil : item.originalMessageAuthorAci,
            threadUniqueId: uniqueThreadId,
            transaction: tx,
        )
        if let pastRevision = target, pastRevision.editState == .pastRevision {
            target = DependenciesBridge.shared.editMessageStore.findMessage(fromEdit: pastRevision, tx: tx)
        }

        let pinnerName = SSKEnvironment.shared.contactManagerRef.displayName(
            for: SignalServiceAddress(item.pinnedMessageAuthorAci),
            tx: tx,
        ).resolvedValue()

        return TellomiPinNotice.describe(
            pinnerIsLocalUser: !thirdPerson && localAci == item.pinnedMessageAuthorAci,
            pinnerName: pinnerName,
            target: target,
            tx: tx,
        )
    }

    /// Tellomi (ADR-0081 §4.2, §4.6): the line a reply carries as its quote of "×× pinned «…»" — in the third person even for
    /// my own pin, since apps that can't find the notice show it as it is (Android `TellomiPinNotice.describeForQuote`).
    func tellomiPinNoticeQuoteText(tx: DBReadTransaction) -> String? {
        guard
            let item: PersistablePinnedMessageItem = infoMessageValue(forKey: .pinnedMessage),
            let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
        else {
            return nil
        }
        return tellomiPinnedMessageDescription(item: item, localAci: localAci, thirdPerson: true, tx: tx)
    }

    /// Tellomi (ADR-0081 §4.4): who pinned, for the notification's sender.
    var tellomiPinnerAci: Aci? {
        let item: PersistablePinnedMessageItem? = infoMessageValue(forKey: .pinnedMessage)
        return item?.pinnedMessageAuthorAci
    }
}

// MARK: - Identity (ADR-0081 §4.2)

extension TSInfoMessage {

    /// Tellomi (ADR-0081 §4.2): who pinned, and when the pin was sent — how a quote, a reaction or a delete names "×× pinned
    /// «…»" (on Android and Desktop, the notice's own sender and sent time). Nil for any other message, and for notices from
    /// before iOS kept the time.
    public var tellomiPinNoticeIdentity: (pinner: Aci, pinSentTimestamp: UInt64)? {
        guard
            messageType == .typePinnedMessage,
            let item: PersistablePinnedMessageItem = infoMessageValue(forKey: .pinnedMessage),
            let pinSentTimestamp = item.tellomiPinSentTimestamp
        else {
            return nil
        }
        return (item.pinnedMessageAuthorAci, pinSentTimestamp)
    }
}

extension InteractionFinder {

    /// Tellomi (ADR-0081 §4.2): the "×× pinned «…»" in this chat that `pinner` sent at `pinSentTimestamp`, newest first.
    public func tellomiPinNotice(pinner: Aci, pinSentTimestamp: UInt64, tx: DBReadTransaction) -> TSInfoMessage? {
        let sql = """
        SELECT *
        FROM \(InteractionRecord.databaseTableName)
        \(DEBUG_INDEXED_BY("index_model_TSInteraction_on_uniqueThreadId_recordType_messageType"))
        WHERE \(interactionColumn: .threadUniqueId) = ?
        AND \(interactionColumn: .recordType) = \(SDSRecordType.infoMessage.rawValue)
        AND \(interactionColumn: .messageType) = \(TSInfoMessageType.typePinnedMessage.rawValue)
        ORDER BY \(interactionColumn: .id) DESC
        """
        let cursor = TSInfoMessage.grdbFetchCursor(sql: sql, arguments: [threadUniqueId], transaction: tx)
        return failIfThrows {
            while let interaction = try cursor.next() {
                guard
                    let notice = interaction as? TSInfoMessage,
                    let identity = notice.tellomiPinNoticeIdentity,
                    identity.pinner == pinner,
                    identity.pinSentTimestamp == pinSentTimestamp
                else {
                    continue
                }
                return notice
            }
            return nil
        }
    }
}

// MARK: - Deleted for everyone (ADR-0081 §4.2)

extension TellomiPinNotice {

    /// Tellomi (ADR-0081 §4.2, pinned-messages.md 3.7): only whoever pinned can delete "×× pinned «…»" for everyone, within the
    /// time a message can be (Signal's rule, owner 2026-09-24), counted from when the pin was sent.
    public static func canDeleteForEveryone(_ notice: TSInfoMessage, localAci: Aci?, nowMs: UInt64) -> Bool {
        guard let identity = notice.tellomiPinNoticeIdentity, let localAci, identity.pinner == localAci else {
            return false
        }
        let (elapsed, isInFuture) = nowMs.subtractingReportingOverflow(identity.pinSentTimestamp)
        return isInFuture || TimeInterval(elapsed) <= RemoteConfig.current.normalDeleteMaxAgeInSeconds * TimeInterval(MSEC_PER_SEC)
    }

    /// Deletes my "You pinned «…»" for everyone. It leaves this device at once (a message turns into "You deleted this message"
    /// at once), and the delete names it by when the pin was sent. The pin itself stays.
    public static func deleteForEveryone(_ notice: TSInfoMessage, thread: TSThread, tx: DBWriteTransaction) {
        guard let identity = notice.tellomiPinNoticeIdentity else {
            owsFailDebug("Not a pin notice that can be named.")
            return
        }
        let deleteMessage = OutgoingDeleteMessage(thread: thread, tellomiPinSentTimestamp: identity.pinSentTimestamp, tx: tx)
        remove(notice, tx: tx)
        SSKEnvironment.shared.messageSenderJobQueueRef.add(
            message: .preprepared(transientMessageWithoutAttachments: deleteMessage),
            transaction: tx,
        )
    }

    /// A delete for everyone from whoever pinned "×× pinned «…»" takes it away; the pin itself stays. From someone else it has
    /// to come within the time a message's delete may (as `TSMessage.remotelyDeleteMessage`); mine were checked when sent.
    static func applyDeleteForEveryone(
        _ notice: TSInfoMessage,
        deleteAuthorAci: Aci,
        serverTimestamp: UInt64,
        tx: DBWriteTransaction,
    ) throws(TSMessage.RemoteDeleteError) {
        let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
        if deleteAuthorAci != localAci, let identity = notice.tellomiPinNoticeIdentity {
            let allowed = RemoteConfig.current.normalDeleteMaxAgeInSeconds + .day
            let pinDate = Date(millisecondsSince1970: identity.pinSentTimestamp)
            guard pinDate.addingTimeInterval(allowed) > Date(millisecondsSince1970: serverTimestamp) else {
                Logger.warn("Ignoring a pin notice's delete sent too long after the pin.")
                throw .invalidDelete
            }
        }
        remove(notice, tx: tx)
    }

    private static func remove(_ notice: TSInfoMessage, tx: DBWriteTransaction) {
        DependenciesBridge.shared.interactionDeleteManager.delete(notice, sideEffects: .default(), tx: tx)
    }
}
