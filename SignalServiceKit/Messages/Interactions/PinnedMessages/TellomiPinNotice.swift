//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

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
    func tellomiPinnedMessageDescription(item: PersistablePinnedMessageItem, localAci: Aci, tx: DBReadTransaction) -> String {
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
            pinnerIsLocalUser: localAci == item.pinnedMessageAuthorAci,
            pinnerName: pinnerName,
            target: target,
            tx: tx,
        )
    }

    /// Tellomi (ADR-0081 §4.4): who pinned, for the notification's sender.
    var tellomiPinnerAci: Aci? {
        let item: PersistablePinnedMessageItem? = infoMessageValue(forKey: .pinnedMessage)
        return item?.pinnedMessageAuthorAci
    }
}
