//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
import SignalUI
public import UIKit

protocol PinnedMessageInteractionManagerDelegate: AnyObject {

    /// Scrolls to the message specified.
    /// If nil, scrolls to the message found at pinnedMessageIndex, the current one displayed in the UI banner.
    func goToMessage(message: TSMessage?)

    /// Unpins the message specified.
    /// If nil, unpins the message found at pinnedMessageIndex, the current one displayed in the UI banner.
    func unpinMessage(message: TSMessage?, modalDelegate: UIViewController?)

    /// Presents the "see all messages" details view.
    func presentSeeAllMessages()

    /// Unpins all messages
    func unpinAllMessages()

    /// Tellomi (pinned-messages.md 3.4): × on the bar when there is one pin — unpin (with Undo) or, without the permission, hide it here.
    func tellomiClosePinnedBar()

    /// Tellomi (pinned-messages.md 3.5): "Hide pinned messages" in the pinned list, for someone who may not unpin them — hidden here
    /// until there's a newer pin, with Undo.
    func tellomiHidePinnedMessages()
}

public struct PinnedMessageBannerData {
    let authorName: String
    let previewText: NSAttributedString
    let thumbnail: UIImageView?
}

public extension ConversationViewController {
    func handleTappedPinnedMessage() {
        // Tellomi (pinned-messages.md 3.4): pins in message order (`tellomiPinnedBarPins`). Jump to the one shown, then show the one
        // before it — after the oldest, the newest — and hold it there until the user scrolls it away (`TellomiPinnedBar`).
        let pins = tellomiPinnedBarPins
        guard pins.indices.contains(pinnedMessageIndex) else {
            owsFailDebug("Invalid pinned message index")
            return
        }

        let currentPin = pins[pinnedMessageIndex]

        if pins.count > 1 {
            pinnedMessageIndex = TellomiPinnedBar.nextAfterTap(pinnedMessageIndex, count: pins.count)
            viewState.tellomiForcedPinUniqueId = pins[pinnedMessageIndex].uniqueId
            animateToNextPinnedMessage()
        }

        ensureInteractionLoadedThenScrollToInteraction(
            currentPin.uniqueId,
            alignment: .centerIfNotEntirelyOnScreen,
            isAnimated: true,
        )
    }

    func pinnedMessageLeadingAccessoryView() -> UIView? {
        // Tellomi (pinned-messages.md 3.4): one segment per pin, at most three, fading where there are more (`TellomiPinnedLineView`).
        let count = tellomiPinnedBarPins.count
        guard count > 1 else {
            return nil
        }
        return TellomiPinnedLineView(index: pinnedMessageIndex, count: count)
    }

    func pinnedMessageData(for message: TSMessage) -> PinnedMessageBannerData? {
        func needsThumbnail(mimeType: String, attachment: ReferencedAttachment) -> Bool {
            if MimeTypeUtil.isSupportedDefinitelyAnimatedMimeType(mimeType) || attachment.reference.renderingFlag == .shouldLoop {
                return false
            }
            return MimeTypeUtil.isSupportedImageMimeType(mimeType) || MimeTypeUtil.isSupportedVideoMimeType(mimeType)
        }

        guard let messageRowId = message.grdbId?.int64Value else {
            return nil
        }

        return DependenciesBridge.shared.db.read { tx in
            let attachment = DependenciesBridge.shared.attachmentStore
                .fetchAnyReferencedAttachment(for: .messageBodyAttachment(messageRowId: messageRowId), tx: tx)

            var authorAddress: SignalServiceAddress?
            if message.isOutgoing {
                authorAddress = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aciAddress
            } else if let incomingMessage = message as? TSIncomingMessage {
                authorAddress = incomingMessage.authorAddress
            }

            guard
                let authorAddress,
                let previewText = pinnedMessagePreviewText(tx, message: message, mediaAttachment: attachment)
            else {
                return nil
            }
            let voteAuthorName = SSKEnvironment.shared.contactManagerRef.nameForAddress(
                authorAddress,
                localUserDisplayMode: .asLocalUser,
                short: false,
                transaction: tx,
            )

            var thumbnail: UIImageView?
            if let attachment, needsThumbnail(mimeType: attachment.attachment.mimeType, attachment: attachment) {
                thumbnail = mediaAttachmentThumbnail(messageRowId: messageRowId, tx: tx)
            }

            return PinnedMessageBannerData(
                authorName: voteAuthorName.string,
                previewText: previewText,
                thumbnail: thumbnail,
            )
        }
    }

    private func mediaSymbol(attachment: ReferencedAttachment?) -> NSAttributedString? {
        guard let attachment else {
            return nil
        }
        let mimeType = attachment.attachment.mimeType
        if MimeTypeUtil.isSupportedAudioMimeType(mimeType) {
            if attachment.reference.renderingFlag == .voiceMessage {
                return SignalSymbol.audio.attributedString(
                    dynamicTypeBaseSize: 15.0,
                )
            }
        }

        if MimeTypeUtil.isSupportedDefinitelyAnimatedMimeType(mimeType) || attachment.reference.renderingFlag == .shouldLoop {
            return SignalSymbol.gifRectangle.attributedString(
                dynamicTypeBaseSize: 15.0,
            )
        } else if MimeTypeUtil.isSupportedImageMimeType(mimeType) || MimeTypeUtil.isSupportedVideoMimeType(mimeType) {
            // These will show a thumbnail instead.
            return nil
        } else {
            return SignalSymbol.file.attributedString(
                dynamicTypeBaseSize: 15.0,
            )
        }
    }

    private func pinnedMessagePreviewText(
        _ tx: DBReadTransaction,
        message: TSMessage,
        mediaAttachment: ReferencedAttachment?,
    ) -> NSAttributedString? {
        // Payments
        if message is OWSPaymentMessage || message is OWSArchivedPaymentMessage {
            let paymentIcon = SignalSymbol.creditcard.attributedString(
                dynamicTypeBaseSize: 15.0,
            ) + " "
            return paymentIcon + NSAttributedString(string: message.body ?? "")
        }

        // View once
        if message.isViewOnceMessage {
            let viewOnceIcon = SignalSymbol.viewOnce.attributedString(
                dynamicTypeBaseSize: 15.0,
            ) + " "
            return viewOnceIcon + NSAttributedString(string: OWSLocalizedString(
                "PER_MESSAGE_EXPIRATION_NOT_VIEWABLE",
                comment: "inbox cell and notification text for an already viewed view-once media message.",
            ))
        }

        // Regular body text
        let bodyDescription = message.rawBody(transaction: tx)
        if let bodyDescription = bodyDescription?.nilIfEmpty {

            // Polls are a special case because the poll question is in the
            // message body.
            var pollPrefix: NSAttributedString = .init(string: "")
            if message.isPoll {
                let locPollString = OWSLocalizedString(
                    "POLL_PREFIX",
                    comment: "Prefix for a poll preview",
                ) + " "
                let pollIcon = SignalSymbol.poll.attributedString(
                    dynamicTypeBaseSize: 15.0,
                ) + " "
                pollPrefix = pollIcon + NSAttributedString(string: locPollString)
            }

            // Generic files are a special case because the caption should be the filename.
            let fileSymbol = SignalSymbol.file.attributedString(dynamicTypeBaseSize: 15)
            if
                mediaSymbol(attachment: mediaAttachment) == fileSymbol,
                let fileName = mediaAttachment?.previewText(includeFileName: true, includeEmoji: false)
            {
                return fileSymbol + " " + NSAttributedString(string: fileName)
            }

            let hydrated = MessageBody(
                text: bodyDescription,
                ranges: message.bodyRanges ?? .empty,
            ).hydrating(mentionHydrator: ContactsMentionHydrator.mentionHydrator(transaction: tx))
            return pollPrefix + NSAttributedString(string: hydrated.asPlaintext())
        }

        // Attachments
        let attachmentIcon = mediaSymbol(attachment: mediaAttachment)
        let attachmentDescription = mediaAttachment?.previewText(includeFileName: true, includeEmoji: false)
        if let attachmentDescription = attachmentDescription?.nilIfEmpty {
            if let attachmentIcon {
                return attachmentIcon + " " + NSAttributedString(string: attachmentDescription)
            }
            return NSAttributedString(string: attachmentDescription)
        }

        // Contact share
        if let contactShare = message.contactShare {
            let contactIcon = SignalSymbol.personCircle.attributedString(
                dynamicTypeBaseSize: 15.0,
            ) + " "
            return contactIcon + NSAttributedString(string: contactShare.name.displayName)
        }

        // Sticker
        if message.messageSticker != nil {
            let stickerIcon = SignalSymbol.sticker.attributedString(
                dynamicTypeBaseSize: 15.0,
            ) + " "

            let stickerDescription = OWSLocalizedString(
                "STICKER_MESSAGE_PREVIEW",
                comment: "Preview text shown in notifications and conversation list for sticker messages.",
            )
            return stickerIcon + NSAttributedString(string: stickerDescription)
        }

        // Unknown
        return nil
    }

    private func mediaAttachmentThumbnail(messageRowId: Int64, tx: DBReadTransaction) -> UIImageView? {
        let attachment = DependenciesBridge.shared.attachmentStore.fetchAnyReferencedAttachment(
            for: .messageBodyAttachment(messageRowId: messageRowId),
            tx: tx,
        )
        guard let attachment, let attachmentStream = attachment.asReferencedStream else {
            return nil
        }

        let imageView = UIImageView()
        imageView.clipsToBounds = true
        if #available(iOS 26, *) {
            imageView.layer.cornerCurve = .continuous
            imageView.layer.cornerRadius = 11
        } else {
            imageView.layer.cornerRadius = 4
        }
        imageView.contentMode = .scaleAspectFill
        imageView.image = attachmentStream.attachmentStream.thumbnailImageSync(quality: .small)
        // Tellomi (tellomi/tellomi#1263, spec R-1): like a quote, the pinned bar never shows a covered image / video.
        if TellomiMediaSpoiler.isSpoiler(attachment.reference, tx: tx) {
            imageView.image = TellomiSpoilerCoverView.coveredThumbnail(imageView.image)
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 30),
            imageView.heightAnchor.constraint(equalToConstant: 30),
        ])
        return imageView
    }
}

extension ConversationViewController: PinnedMessageInteractionManagerDelegate {
    func goToMessage(message: TSMessage?) {
        let targetMessage: TSMessage
        if let message {
            targetMessage = message
        } else {
            // Tellomi (pinned-messages.md 3.4): the index is into the pins in message order.
            let pins = tellomiPinnedBarPins
            guard pins.indices.contains(pinnedMessageIndex) else {
                return
            }
            targetMessage = pins[pinnedMessageIndex]
        }

        ensureInteractionLoadedThenScrollToInteraction(
            targetMessage.uniqueId,
            alignment: .centerIfNotEntirelyOnScreen,
            isAnimated: true,
        )
    }

    func unpinMessage(message: TSMessage?, modalDelegate: UIViewController?) {
        let messageToUnpin: TSMessage
        if let message {
            messageToUnpin = message
        } else {
            // Tellomi (pinned-messages.md 3.4): the index is into the pins in message order.
            let pins = tellomiPinnedBarPins
            guard pins.indices.contains(pinnedMessageIndex) else {
                return
            }
            messageToUnpin = pins[pinnedMessageIndex]
        }

        // Tellomi (pinned-messages.md 3.6): with "Message unpinned · Undo", as from the bar and the message menu.
        tellomiUnpinWithUndo(messageToUnpin)
    }

    func presentSeeAllMessages() {
        let pmDetailsController = UINavigationController(rootViewController: PinnedMessagesDetailsViewController(
            pinnedMessages: threadViewModel.pinnedMessages,
            threadViewModel: threadViewModel,
            database: DependenciesBridge.shared.db,
            delegate: self,
            databaseChangeObserver: DependenciesBridge.shared.databaseChangeObserver,
            pinnedMessageManager: DependenciesBridge.shared.pinnedMessageManager,
            spoilerState: self.viewState.spoilerState,
        ))
        pmDetailsController.modalPresentationStyle = .pageSheet
        present(pmDetailsController, animated: true)
    }

    func unpinAllMessages() {
        // Tellomi (pinned-messages.md 3.5, as in both Telegram apps): no question and no spinner — "N messages unpinned · Undo" for
        // 5 s, then the unpins go out.
        tellomiUnpinAllWithUndo()
    }
}
