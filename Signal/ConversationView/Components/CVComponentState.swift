//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import MobileCoin
public import SignalServiceKit
import SignalUI

public enum CVAttachment: Equatable {
    case stream(ReferencedAttachmentStream, isUploading: Bool, imageMetadata: ImageMetadata?)
    case pointer(ReferencedAttachmentPointer, downloadState: AttachmentDownloadState)
    case backupThumbnail(ReferencedAttachmentBackupThumbnail)
    /// The attachment has no stream and cannot be downloaded because there is no cdn info.
    /// Typically happens if we restore from a free-tier backup with old media expired from transit tier.
    case undownloadable(ReferencedAttachment)

    public var contentType: Attachment.ContentType {
        return attachment.attachment.contentType
    }

    public var attachmentID: Attachment.IDType {
        return attachment.attachment.id
    }

    public var attachment: ReferencedAttachment {
        switch self {
        case .stream(let stream, _, _):
            return stream
        case .pointer(let pointer, _):
            return pointer
        case .backupThumbnail(let thumbnail):
            return thumbnail
        case .undownloadable(let attachment):
            return attachment
        }
    }

    public var attachmentStream: AttachmentStream? {
        switch self {
        case .stream(let stream, _, _):
            return stream.attachmentStream
        case .pointer, .backupThumbnail:
            return nil
        case .undownloadable:
            return nil
        }
    }

    public var attachmentPointer: AttachmentPointer? {
        switch self {
        case .stream, .backupThumbnail:
            return nil
        case .pointer(let pointer, _):
            return pointer.attachmentPointer
        case .undownloadable:
            return nil
        }
    }

    public var attachmentBackupThumbnail: AttachmentBackupThumbnail? {
        switch self {
        case .stream, .pointer:
            return nil
        case .backupThumbnail(let thumbnail):
            return thumbnail.attachmentBackupThumbnail
        case .undownloadable:
            return nil
        }
    }

    public static func from(
        referencedAttachment: ReferencedAttachment,
        message: TSMessage,
        tx: DBReadTransaction,
    ) -> CVAttachment {
        if let stream = referencedAttachment.asReferencedStream {
            let attachmentBackfillManager = DependenciesBridge.shared.attachmentBackfillManager
            var isUploading = false

            // We can infer from the properties of an outgoing message whether
            // it's got things being uploaded.
            if
                let outgoingMessage = message as? TSOutgoingMessage,
                referencedAttachment.attachment.latestTransitTierInfo == nil,
                referencedAttachment.attachment.mediaTierInfo == nil,
                !outgoingMessage.wasNotCreatedLocally,
                outgoingMessage.messageState != .failed
            {
                isUploading = true
            }

            // If we have an enqueued backfill for this message, assume this
            // attachment is being reuploaded.
            if
                attachmentBackfillManager.hasEnqueuedInboundRequest(
                    interactionRowId: message.sqliteRowId!,
                    tx: tx,
                )
            {
                isUploading = true
            }

            return .stream(
                stream,
                isUploading: isUploading,
                imageMetadata: stream.attachmentStream.imageMetadata(),
            )
        } else if let thumbnail = referencedAttachment.asReferencedBackupThumbnail {
            return .backupThumbnail(thumbnail)
        } else if let pointer = referencedAttachment.asReferencedAnyPointer {
            return .pointer(pointer, downloadState: pointer.attachmentPointer.downloadState(tx: tx))
        } else {
            return .undownloadable(referencedAttachment)
        }
    }

    public static func ==(lhs: CVAttachment, rhs: CVAttachment) -> Bool {
        switch (lhs, rhs) {
        case (.stream(let lhsStream, let lhsIsUploading, imageMetadata: _), .stream(let rhsStream, let rhsIsUploading, imageMetadata: _)):
            return lhsStream.attachment.id == rhsStream.attachment.id
                && lhsStream.reference.hasSameOwner(as: rhsStream.reference)
                && lhsIsUploading == rhsIsUploading
        case (.pointer(let lhsPointer, let lhsState), .pointer(let rhsPointer, let rhsState)):
            return lhsPointer.attachment.id == rhsPointer.attachment.id
                && lhsPointer.reference.hasSameOwner(as: rhsPointer.reference)
                && lhsState == rhsState
        case (.backupThumbnail(let lhsThumbnail), .backupThumbnail(let rhsThumbnail)):
            return lhsThumbnail.attachment.id == rhsThumbnail.attachment.id
                && lhsThumbnail.reference.hasSameOwner(as: rhsThumbnail.reference)
        case (.undownloadable(let lhsAttachment), .undownloadable(let rhsAttachment)):
            return lhsAttachment.attachment.id == rhsAttachment.attachment.id
                && lhsAttachment.reference.hasSameOwner(as: rhsAttachment.reference)
        case
            (.stream, .pointer),
            (.stream, .backupThumbnail),
            (.stream, .undownloadable),
            (.pointer, .stream),
            (.pointer, .backupThumbnail),
            (.pointer, .undownloadable),
            (.backupThumbnail, .pointer),
            (.backupThumbnail, .stream),
            (.backupThumbnail, .undownloadable),
            (.undownloadable, .stream),
            (.undownloadable, .pointer),
            (.undownloadable, .backupThumbnail):
            return false
        }
    }
}

public struct CVComponentState: Equatable {
    let messageCellType: CVMessageCellType

    struct SenderName: Equatable {
        let senderName: NSAttributedString
        let senderNameColor: UIColor
        let memberLabel: String?
    }

    let senderName: SenderName?

    struct SenderAvatar: Equatable {
        let avatarDataSource: ConversationAvatarDataSource
    }

    let senderAvatar: SenderAvatar?

    enum BodyText: Equatable {
        case bodyText(displayableText: DisplayableText, hasTapForMore: Bool)

        case oversizeTextDownloading(truncatedBody: DisplayableText)

        case oversizeTextSkipped(truncatedBody: DisplayableText)

        case oversizeTextUndownloadable(truncatedBody: DisplayableText)

        // We use the "body text" component to
        // render the "remotely deleted" indicator.
        case remotelyDeleted(deleteAuthor: RemoteDeleteAuthor)

        var displayableText: DisplayableText? {
            switch self {
            case .bodyText(let text, _), .oversizeTextUndownloadable(let text), .oversizeTextSkipped(let text), .oversizeTextDownloading(let text):
                return text
            case .remotelyDeleted:
                return nil
            }
        }

        func textValue(isTextExpanded: Bool) -> CVTextValue? {
            switch self {
            case .bodyText(let text, _), .oversizeTextUndownloadable(let text), .oversizeTextSkipped(let text), .oversizeTextDownloading(let text):
                return text.textValue(isTextExpanded: isTextExpanded)
            case .remotelyDeleted:
                return nil
            }
        }

        var jumbomojiCount: UInt? {
            switch self {
            case .bodyText(let text, _), .oversizeTextUndownloadable(let text), .oversizeTextSkipped(let text), .oversizeTextDownloading(let text):
                return text.jumbomojiCount
            case .remotelyDeleted:
                return nil
            }
        }

        var isJumbomojiMessage: Bool {
            guard let jumbomojiCount else {
                return false
            }
            return jumbomojiCount > 0
        }
    }

    let bodyText: BodyText?

    struct BodyMedia: Equatable {
        let items: [CVMediaAlbumItem]
        let mediaAlbumHasFailedAttachment: Bool
        let mediaAlbumHasSkippedAttachment: Bool
    }

    let bodyMedia: BodyMedia?

    struct GenericAttachment: Equatable {
        let attachment: CVAttachment

        var attachmentStream: AttachmentStream? {
            attachment.attachmentStream
        }

        var attachmentPointer: AttachmentPointer? {
            attachment.attachmentPointer
        }

        var attachmentBackupThumbnail: AttachmentBackupThumbnail? {
            attachment.attachmentBackupThumbnail
        }
    }

    let genericAttachment: GenericAttachment?

    public struct PaymentAttachment: Equatable {
        let notification: TSPaymentNotification
        let model: TSPaymentModel?
        let otherUserShortName: String

        var status: TSPaymentState? { model?.paymentState }
    }

    var paymentAttachment: PaymentAttachment?

    public struct ArchivedPaymentAttachment: Equatable {
        let amount: String?
        let fee: String?
        let note: String?
        let otherUserShortName: String
        let archivedPayment: ArchivedPayment?

        public static func ==(lhs: Self, rhs: Self) -> Bool {
            lhs.amount == rhs.amount
                && lhs.fee == rhs.fee
                && lhs.note == rhs.note
                && lhs.otherUserShortName == rhs.otherUserShortName
        }
    }

    var archivedPaymentAttachment: ArchivedPaymentAttachment?

    // It's not practical to reload the audio cell every time
    // playback state or progress changes.  Therefore we only
    // capture the stable state related to the audio. Dynamic
    // state is obtained from CVAudioPlayer.
    //
    // NOTE: We use the existing AudioAttachment entity,
    //       not a custom struct.
    let audioAttachment: AudioAttachment?

    struct ViewOnce: Equatable {
        let viewOnceState: ViewOnceState
        /// Tellomi（tellomi/tellomi#1714，ADR-0079 §4.3 第 4 条）：计时的一次性查看打开后看几秒；nil = 普通一次性查看。
        var tellomiSeconds: UInt32? = nil
    }

    let viewOnce: ViewOnce?

    let hasRenderableContent: Bool

    struct QuotedReply: Equatable {
        let viewState: CVQuotedMessageView.State

        var quotedReplyModel: QuotedReplyModel { viewState.quotedReplyModel }
    }

    let quotedReply: QuotedReply?

    enum Sticker: Equatable {
        case available(
            stickerMetadata: any StickerMetadata,
            attachmentStream: ReferencedAttachmentStream,
            isUploading: Bool,
            imageMetadata: ImageMetadata,
        )
        case invalidImage(attachmentId: Attachment.IDType)
        case downloading(attachmentPointer: ReferencedAttachmentPointer)
        case skipped(
            attachmentPointer: ReferencedAttachmentPointer,
            downloadState: AttachmentDownloadState,
        )

        var stickerMetadata: (any StickerMetadata)? {
            switch self {
            case .available(let stickerMetadata, attachmentStream: _, isUploading: _, imageMetadata: _):
                return stickerMetadata
            case .invalidImage, .downloading, .skipped:
                return nil
            }
        }

        var attachmentStream: ReferencedAttachmentStream? {
            switch self {
            case .available(stickerMetadata: _, let attachmentStream, isUploading: _, imageMetadata: _):
                return attachmentStream
            case .invalidImage, .downloading, .skipped:
                return nil
            }
        }

        var attachmentPointer: ReferencedAttachmentPointer? {
            switch self {
            case .available, .invalidImage:
                return nil
            case .downloading(let attachmentPointer),
                 .skipped(let attachmentPointer, _):
                return attachmentPointer
            }
        }

        static func ==(lhs: CVComponentState.Sticker, rhs: CVComponentState.Sticker) -> Bool {
            switch (lhs, rhs) {
            case let (
                .available(lhsData, lhsStream, lhsIsUploading, imageMetadata: _),
                .available(rhsData, rhsStream, rhsIsUploading, imageMetadata: _),
            ):
                return lhsData.stickerInfo.asKey() == rhsData.stickerInfo.asKey()
                    && lhsStream.attachment.id == rhsStream.attachment.id
                    && lhsStream.reference.hasSameOwner(as: rhsStream.reference)
                    && lhsIsUploading == rhsIsUploading
            case let (.downloading(lhsPointer), .downloading(rhsPointer)):
                return lhsPointer.attachment.id == rhsPointer.attachment.id
                    && lhsPointer.reference.hasSameOwner(as: rhsPointer.reference)
            case let (.skipped(lhsPointer, lhsState), .skipped(rhsPointer, rhsState)):
                return lhsPointer.attachment.id == rhsPointer.attachment.id
                    && lhsPointer.reference.hasSameOwner(as: rhsPointer.reference)
                    && lhsState == rhsState
            case let (.invalidImage(lhsAttachmentId), .invalidImage(rhsAttachmentId)):
                return lhsAttachmentId == rhsAttachmentId
            case (.available, _), (.downloading, _), (.skipped, _), (.invalidImage, _):
                return false
            }
        }
    }

    let sticker: Sticker?

    /// The attachment has no stream and cannot be downloaded because there is no cdn info.
    /// Typically happens if we restore from a free-tier backup with old media expired from transit tier.
    enum UndownloadableAttachment: Equatable {
        case audio
        case sticker
    }

    let undownloadableAttachment: UndownloadableAttachment?

    struct ContactShare: Equatable {
        let state: CVContactShareView.State
    }

    let contactShare: ContactShare?

    struct LinkPreview: Equatable {
        let linkPreview: OWSLinkPreview
        let state: LinkPreviewState

        // MARK: - Equatable

        static func ==(lhs: LinkPreview, rhs: LinkPreview) -> Bool {
            return lhs.state === rhs.state
        }
    }

    let linkPreview: LinkPreview?

    struct GiftBadge: Equatable {
        let messageUniqueId: String
        let otherUserShortName: String
        let profileBadge: ProfileBadge?
        let expirationDate: Date
        let redemptionState: OWSGiftBadgeRedemptionState
    }

    let giftBadge: GiftBadge?

    struct Poll: Equatable {
        let state: CVPollView.State
        let prevPollState: CVPollView.State?
    }

    let poll: Poll?

    struct SystemMessage: Equatable {
        typealias ReferencedUser = CVTextLabel.ReferencedUserItem

        let title: NSAttributedString
        let titleColorOverride: UIColor?
        let action: CVMessageAction?

        struct Expiration: Equatable {
            let expirationTimestamp: UInt64
            let expiresInSeconds: UInt32
        }

        let expiration: Expiration?

        /// Represents users whose names appear in the title. Only applies to
        /// system messages in group threads.
        let namesInTitle: [ReferencedUser]

        init(
            title: NSAttributedString,
            titleColorOverride: UIColor?,
            action: CVMessageAction?,
            expiration: Expiration?,
        ) {
            let mutableTitle = NSMutableAttributedString(attributedString: title)
            mutableTitle.removeAttribute(
                .addressOfName,
                range: NSRange(location: 0, length: mutableTitle.length),
            )
            self.title = NSAttributedString(attributedString: mutableTitle)
            self.titleColorOverride = titleColorOverride
            self.action = action
            self.expiration = expiration

            self.namesInTitle = {
                // Extract the addresses for names in the string. These are only
                // stored for system messages in group threads.

                var referencedUsers = [ReferencedUser]()

                title.enumerateAddressesOfNames { address, range, _ in
                    if let address {
                        referencedUsers.append(ReferencedUser(
                            address: address,
                            range: range,
                        ))
                    }
                }

                return referencedUsers
            }()
        }
    }

    let systemMessage: SystemMessage?

    struct DateHeader: Equatable {
    }

    let dateHeader: DateHeader?

    struct UnreadIndicator: Equatable {
    }

    let unreadIndicator: UnreadIndicator?

    struct Reactions: Equatable {
        let reactionState: InteractionReactionState
        let viewState: CVReactionCountsView.State
    }

    let reactions: Reactions?

    struct TypingIndicator: Equatable {
        let address: SignalServiceAddress
        let avatarDataSource: ConversationAvatarDataSource?
    }

    let typingIndicator: TypingIndicator?

    struct ThreadDetails: Equatable {
        struct SafetySection: Equatable {
            /// For "Profile names are not verified"
            let shouldShowProfileNamesEducation: Bool
            /// For phone numbers or group member count
            let detailsText: NSAttributedString?
            /// For mutual groups, lack thereof and note-to-self description.
            let mutualGroupsText: NSAttributedString?
            /// Populated if `mutualGroupsText` is not suitable for a11y, for
            /// example if it embeds an image.
            let mutualGroupsAccessibilityText: String?
            let threadType: SafetyTipsType
            let shouldShowSafetyTipsButton: Bool
            let isOfficialChat: Bool
        }

        let avatarDataSource: ConversationAvatarDataSource?
        let isAvatarBlurred: Bool
        let isAvatarBeingDownloaded: Bool
        let titleText: String
        let shouldShowVerifiedBadge: Bool
        let shouldShowContactIcon: Bool
        let safetySection: SafetySection?
        let groupDescriptionText: String?
    }

    let threadDetails: ThreadDetails?

    typealias UnknownThreadWarning = CVComponentState.SystemMessage
    let unknownThreadWarning: UnknownThreadWarning?

    typealias DefaultDisappearingMessageTimer = CVComponentState.SystemMessage
    let defaultDisappearingMessageTimer: DefaultDisappearingMessageTimer?

    struct CollapseSet: Equatable {
        let collapsedInteractions: [TSInteraction]
        let collapseSetType: CollapseSetInteraction.MessagesType
        let isExpanded: Bool
        let finalTimerDescription: String?

        static func ==(lhs: CollapseSet, rhs: CollapseSet) -> Bool {
            return lhs.collapsedInteractions.map(\.uniqueId) == rhs.collapsedInteractions.map(\.uniqueId)
                && lhs.collapseSetType == rhs.collapseSetType
                && lhs.finalTimerDescription == rhs.finalTimerDescription
        }
    }

    let collapseSet: CollapseSet?

    struct BottomButtons: Equatable {
        let actions: [CVMessageAction]
    }

    let bottomButtons: BottomButtons?

    let bottomLabel: String?

    struct SkippedDownloads: Equatable {
        let attachmentIds: Set<Attachment.IDType>

        init?(attachmentIds: Set<Attachment.IDType>) {
            if attachmentIds.isEmpty {
                return nil
            }
            self.attachmentIds = attachmentIds
        }

    }

    let skippedDownloads: SkippedDownloads?

    struct SendFailureBadge: Equatable {
        let color: UIColor
    }

    let sendFailureBadge: SendFailureBadge?

    let messageHasBodyAttachments: Bool

    /// Tellomi（tellomi/tellomi#1263，ADR-0068 §4.7）：说明文字画在媒体上方——有正文、按媒体显示的图片 / 视频，
    /// 标记为真（`TellomiCaptionAbove`）。一次性查看、带链接预览的不适用。
    let tellomiCaptionAboveMedia: Bool

    /// Tellomi（spec attachment-files-location L-11）：认出来的位置消息（正好一张图 + 文字最后一行是地图链接）。
    /// 有它时气泡画成地图（宽 × 半宽）+ 名称 / 地址，不画图片 + 说明文字；消息内容本身不变（转发、复制照旧）。
    let tellomiLocation: TellomiLocationMessage?

    fileprivate init(
        messageCellType: CVMessageCellType,
        senderName: SenderName?,
        senderAvatar: SenderAvatar?,
        bodyText: BodyText?,
        bodyMedia: BodyMedia?,
        genericAttachment: GenericAttachment?,
        paymentAttachment: PaymentAttachment?,
        archivedPaymentAttachment: ArchivedPaymentAttachment?,
        audioAttachment: AudioAttachment?,
        viewOnce: ViewOnce?,
        quotedReply: QuotedReply?,
        sticker: Sticker?,
        undownloadableAttachment: UndownloadableAttachment?,
        contactShare: ContactShare?,
        linkPreview: LinkPreview?,
        giftBadge: GiftBadge?,
        systemMessage: SystemMessage?,
        dateHeader: DateHeader?,
        unreadIndicator: UnreadIndicator?,
        reactions: Reactions?,
        typingIndicator: TypingIndicator?,
        threadDetails: ThreadDetails?,
        unknownThreadWarning: UnknownThreadWarning?,
        defaultDisappearingMessageTimer: DefaultDisappearingMessageTimer?,
        collapseSet: CollapseSet?,
        bottomButtons: BottomButtons?,
        bottomLabel: String?,
        skippedDownloads: SkippedDownloads?,
        sendFailureBadge: SendFailureBadge?,
        messageHasBodyAttachments: Bool,
        hasRenderableContent: Bool,
        poll: Poll?,
        tellomiCaptionAboveMedia: Bool = false,
        tellomiLocation: TellomiLocationMessage? = nil,
    ) {
        self.tellomiCaptionAboveMedia = tellomiCaptionAboveMedia
        self.tellomiLocation = tellomiLocation
        self.messageCellType = messageCellType
        self.senderName = senderName
        self.senderAvatar = senderAvatar
        self.bodyText = bodyText
        self.bodyMedia = bodyMedia
        self.genericAttachment = genericAttachment
        self.paymentAttachment = paymentAttachment
        self.archivedPaymentAttachment = archivedPaymentAttachment
        self.audioAttachment = audioAttachment
        self.viewOnce = viewOnce
        self.quotedReply = quotedReply
        self.sticker = sticker
        self.undownloadableAttachment = undownloadableAttachment
        self.contactShare = contactShare
        self.linkPreview = linkPreview
        self.giftBadge = giftBadge
        self.systemMessage = systemMessage
        self.dateHeader = dateHeader
        self.unreadIndicator = unreadIndicator
        self.reactions = reactions
        self.typingIndicator = typingIndicator
        self.threadDetails = threadDetails
        self.unknownThreadWarning = unknownThreadWarning
        self.defaultDisappearingMessageTimer = defaultDisappearingMessageTimer
        self.collapseSet = collapseSet
        self.bottomButtons = bottomButtons
        self.bottomLabel = bottomLabel
        self.skippedDownloads = skippedDownloads
        self.sendFailureBadge = sendFailureBadge
        self.messageHasBodyAttachments = messageHasBodyAttachments
        self.hasRenderableContent = hasRenderableContent
        self.poll = poll
    }

    // MARK: - Equatable

    public static func ==(lhs: CVComponentState, rhs: CVComponentState) -> Bool {
        return lhs.messageCellType == rhs.messageCellType &&
            lhs.senderName == rhs.senderName &&
            lhs.senderAvatar == rhs.senderAvatar &&
            lhs.bodyText == rhs.bodyText &&
            lhs.bodyMedia == rhs.bodyMedia &&
            lhs.genericAttachment == rhs.genericAttachment &&
            lhs.paymentAttachment == rhs.paymentAttachment &&
            lhs.archivedPaymentAttachment == rhs.archivedPaymentAttachment &&
            lhs.audioAttachment == rhs.audioAttachment &&
            lhs.viewOnce == rhs.viewOnce &&
            lhs.quotedReply == rhs.quotedReply &&
            lhs.sticker == rhs.sticker &&
            lhs.undownloadableAttachment == rhs.undownloadableAttachment &&
            lhs.contactShare == rhs.contactShare &&
            lhs.linkPreview == rhs.linkPreview &&
            lhs.giftBadge == rhs.giftBadge &&
            lhs.systemMessage == rhs.systemMessage &&
            lhs.dateHeader == rhs.dateHeader &&
            lhs.unreadIndicator == rhs.unreadIndicator &&
            lhs.reactions == rhs.reactions &&
            lhs.typingIndicator == rhs.typingIndicator &&
            lhs.threadDetails == rhs.threadDetails &&
            lhs.unknownThreadWarning == rhs.unknownThreadWarning &&
            lhs.defaultDisappearingMessageTimer == rhs.defaultDisappearingMessageTimer &&
            lhs.collapseSet == rhs.collapseSet &&
            lhs.bottomButtons == rhs.bottomButtons &&
            lhs.bottomLabel == rhs.bottomLabel &&
            lhs.skippedDownloads == rhs.skippedDownloads &&
            lhs.sendFailureBadge == rhs.sendFailureBadge &&
            lhs.poll == rhs.poll &&
            lhs.tellomiLocation == rhs.tellomiLocation
    }

    // MARK: - Building

    fileprivate struct Builder: CVItemBuilding {
        typealias SenderName = CVComponentState.SenderName
        typealias SenderAvatar = CVComponentState.SenderAvatar
        typealias BodyText = CVComponentState.BodyText
        typealias BodyMedia = CVComponentState.BodyMedia
        typealias GenericAttachment = CVComponentState.GenericAttachment
        typealias PaymentAttachment = CVComponentState.PaymentAttachment
        typealias ArchivedPaymentAttachment = CVComponentState.ArchivedPaymentAttachment
        typealias ViewOnce = CVComponentState.ViewOnce
        typealias QuotedReply = CVComponentState.QuotedReply
        typealias Sticker = CVComponentState.Sticker
        typealias UndownloadableAttachment = CVComponentState.UndownloadableAttachment
        typealias SystemMessage = CVComponentState.SystemMessage
        typealias ContactShare = CVComponentState.ContactShare
        typealias Reactions = CVComponentState.Reactions
        typealias LinkPreview = CVComponentState.LinkPreview
        typealias GiftBadge = CVComponentState.GiftBadge
        typealias DateHeader = CVComponentState.DateHeader
        typealias UnreadIndicator = CVComponentState.UnreadIndicator
        typealias TypingIndicator = CVComponentState.TypingIndicator
        typealias ThreadDetails = CVComponentState.ThreadDetails
        typealias UnknownThreadWarning = CVComponentState.UnknownThreadWarning
        typealias DefaultDisappearingMessageTimer = CVComponentState.DefaultDisappearingMessageTimer
        typealias SkippedDownloads = CVComponentState.SkippedDownloads
        typealias BottomButtons = CVComponentState.BottomButtons
        typealias SendFailureBadge = CVComponentState.SendFailureBadge
        typealias Poll = CVComponentState.Poll

        let interaction: TSInteraction
        let itemBuildingContext: CVItemBuildingContext

        var revealedSpoilerIdsSnapshot: Set<StyleId> {
            return itemBuildingContext.viewStateSnapshot.spoilerReveal[.fromInteraction(interaction)] ?? Set()
        }

        var senderName: SenderName?
        var senderAvatar: SenderAvatar?
        var bodyText: BodyText?
        var bodyMedia: BodyMedia?
        var genericAttachment: GenericAttachment?
        var paymentAttachment: PaymentAttachment?
        var archivedPaymentAttachment: ArchivedPaymentAttachment?
        var audioAttachment: AudioAttachment?
        var viewOnce: ViewOnce?
        var quotedReply: QuotedReply?
        var sticker: Sticker?
        var undownloadableAttachment: UndownloadableAttachment?
        var systemMessage: SystemMessage?
        var contactShare: ContactShare?
        var linkPreview: LinkPreview?
        var giftBadge: GiftBadge?
        var dateHeader: DateHeader?
        var unreadIndicator: UnreadIndicator?
        var typingIndicator: TypingIndicator?
        var threadDetails: ThreadDetails?
        var unknownThreadWarning: UnknownThreadWarning?
        var defaultDisappearingMessageTimer: DefaultDisappearingMessageTimer?
        var collapseSet: CollapseSet?
        var reactions: Reactions?
        var skippedDownloads: SkippedDownloads?
        var sendFailureBadge: SendFailureBadge?
        var messageHasBodyAttachments: Bool
        var hasRenderableContent: Bool
        var poll: Poll?

        var bottomButtonsActions = [CVMessageAction]()
        var bottomLabel: String?

        init(interaction: TSInteraction, itemBuildingContext: CVItemBuildingContext) {
            self.interaction = interaction
            self.messageHasBodyAttachments = (interaction as? TSMessage)?.hasBodyAttachments(transaction: itemBuildingContext.transaction) ?? false
            self.hasRenderableContent = (interaction as? TSMessage)?.hasRenderableContent(tx: itemBuildingContext.transaction) ?? false
            self.itemBuildingContext = itemBuildingContext
        }

        mutating func build() -> CVComponentState {
            var bottomButtons: BottomButtons?
            if !bottomButtonsActions.isEmpty {
                bottomButtons = BottomButtons(actions: bottomButtonsActions)
            }

            let tellomiLocation = self.tellomiLocation
            return CVComponentState(
                messageCellType: messageCellType,
                senderName: senderName,
                senderAvatar: senderAvatar,
                bodyText: bodyText,
                bodyMedia: tellomiLocation != nil ? bodyMedia.map(Self.tellomiLocationMap) : bodyMedia,
                genericAttachment: genericAttachment,
                paymentAttachment: paymentAttachment,
                archivedPaymentAttachment: archivedPaymentAttachment,
                audioAttachment: audioAttachment,
                viewOnce: viewOnce,
                quotedReply: quotedReply,
                sticker: sticker,
                undownloadableAttachment: undownloadableAttachment,
                contactShare: contactShare,
                linkPreview: linkPreview,
                giftBadge: giftBadge,
                systemMessage: systemMessage,
                dateHeader: dateHeader,
                unreadIndicator: unreadIndicator,
                reactions: reactions,
                typingIndicator: typingIndicator,
                threadDetails: threadDetails,
                unknownThreadWarning: unknownThreadWarning,
                defaultDisappearingMessageTimer: defaultDisappearingMessageTimer,
                collapseSet: collapseSet,
                bottomButtons: bottomButtons,
                bottomLabel: bottomLabel,
                skippedDownloads: skippedDownloads,
                sendFailureBadge: sendFailureBadge,
                messageHasBodyAttachments: messageHasBodyAttachments,
                hasRenderableContent: hasRenderableContent,
                poll: poll,
                tellomiCaptionAboveMedia: bodyText != nil && bodyMedia != nil && viewOnce == nil && linkPreview == nil && tellomiLocation == nil
                    && TellomiCaptionAbove.isCaptionAboveMedia(messageUniqueId: interaction.uniqueId, tx: itemBuildingContext.transaction),
                tellomiLocation: tellomiLocation,
            )
        }

        /// Tellomi（L-11）：只有「一张图 + 地图链接结尾的正文」、别的什么都没有（一次性、贴纸、联系人、投票、链接预览、付款、
        /// 礼物）时才当位置消息。图还没下载也算：地图位置先画占位，名称 / 地址照常显示。
        private var tellomiLocation: TellomiLocationMessage? {
            guard
                let message = interaction as? TSMessage,
                !message.wasRemotelyDeleted,
                viewOnce == nil, sticker == nil, contactShare == nil, poll == nil, linkPreview == nil,
                paymentAttachment == nil, archivedPaymentAttachment == nil, giftBadge == nil,
                genericAttachment == nil, audioAttachment == nil, undownloadableAttachment == nil,
                let bodyMedia, bodyMedia.items.count == 1,
                case .image = bodyMedia.items[0].attachment.contentType,
                case .bodyText = bodyText,
                let body = message.body
            else {
                return nil
            }
            return TellomiLocationMessage.parse(body: body)
        }

        /// 地图按 宽 × 半宽 排（Telegram `ChatMessageMapBubbleContentNode`：`fitWidth * 0.5`）；图片按「填满」画，所以发来的
        /// 方图（上游 iOS 256×256、大头针尖在正中）被居中裁成 2:1，大头针还在中间。尺寸只用来排版，取大一点免得被当成小图不放大。
        fileprivate static func tellomiLocationMap(_ bodyMedia: BodyMedia) -> BodyMedia {
            BodyMedia(
                items: bodyMedia.items.map { item in
                    var mapItem = CVMediaAlbumItem(
                        attachment: item.attachment,
                        attachmentStream: item.attachmentStream,
                        hasCaption: item.hasCaption,
                        mediaSize: CGSize(width: 2000, height: 1000),
                        isBroken: item.isBroken,
                        threadHasPendingMessageRequest: item.threadHasPendingMessageRequest,
                    )
                    mapItem.isTellomiSpoilerCovered = item.isTellomiSpoilerCovered
                    return mapItem
                },
                mediaAlbumHasFailedAttachment: bodyMedia.mediaAlbumHasFailedAttachment,
                mediaAlbumHasSkippedAttachment: bodyMedia.mediaAlbumHasSkippedAttachment,
            )
        }

        // MARK: -

        var isIncoming: Bool {
            interaction is TSIncomingMessage
        }

        var isOutgoing: Bool {
            interaction is TSOutgoingMessage
        }

        var messageCellType: CVMessageCellType {
            if dateHeader != nil {
                return .dateHeader
            }
            if unreadIndicator != nil {
                return .unreadIndicator
            }
            if typingIndicator != nil {
                return .typingIndicator
            }
            if threadDetails != nil {
                return .threadDetails
            }
            if unknownThreadWarning != nil {
                return .unknownThreadWarning
            }
            if defaultDisappearingMessageTimer != nil {
                return .defaultDisappearingMessageTimer
            }
            if collapseSet != nil {
                return .collapseSet
            }
            if systemMessage != nil {
                return .systemMessage
            }
            if self.sticker != nil {
                return .stickerMessage
            }
            if self.undownloadableAttachment != nil {
                return .undownloadableAttachment
            }
            if viewOnce != nil {
                return .viewOnce
            }
            if contactShare != nil {
                return .contactShare
            }
            if audioAttachment != nil {
                return .audio
            }
            if genericAttachment != nil {
                return .genericAttachment
            }
            if paymentAttachment != nil {
                return .paymentAttachment
            }
            if archivedPaymentAttachment != nil {
                return .archivedPaymentAttachment
            }
            if giftBadge != nil {
                return .giftBadge
            }
            if bodyMedia != nil {
                return .bodyMedia
            }
            if bodyText != nil {
                return .textOnlyMessage
            }
            if quotedReply != nil {
                return .quoteOnlyMessage
            }
            if poll != nil {
                return .poll
            }

            owsFailDebug("Unknown state.")
            return .unknown
        }
    }

    // MARK: - Convenience

    var isBorderlessStickerMessage: Bool {
        sticker != nil && quotedReply == nil
    }

    var activeComponentStateKeys: Set<CVComponentKey> {
        var result = Set<CVComponentKey>()
        if senderName != nil {
            result.insert(.senderName)
        }
        if senderAvatar != nil {
            result.insert(.senderAvatar)
        }
        if bodyText != nil {
            result.insert(.bodyText)
        }
        if bodyMedia != nil {
            result.insert(.bodyMedia)
        }
        if genericAttachment != nil {
            result.insert(.genericAttachment)
        }
        if paymentAttachment != nil {
            result.insert(.paymentAttachment)
        }
        if archivedPaymentAttachment != nil {
            result.insert(.archivedPaymentAttachment)
        }
        if audioAttachment != nil {
            result.insert(.audioAttachment)
        }
        if viewOnce != nil {
            result.insert(.viewOnce)
        }
        if quotedReply != nil {
            result.insert(.quotedReply)
        }
        if sticker != nil {
            result.insert(.sticker)
        }
        if contactShare != nil {
            result.insert(.contactShare)
        }
        if linkPreview != nil {
            result.insert(.linkPreview)
        }
        if giftBadge != nil {
            result.insert(.giftBadge)
        }
        if systemMessage != nil {
            result.insert(.systemMessage)
        }
        if dateHeader != nil {
            result.insert(.dateHeader)
        }
        if unreadIndicator != nil {
            result.insert(.unreadIndicator)
        }
        if reactions != nil {
            result.insert(.reactions)
        }
        if typingIndicator != nil {
            result.insert(.typingIndicator)
        }
        if threadDetails != nil {
            result.insert(.threadDetails)
        }
        if unknownThreadWarning != nil {
            result.insert(.unknownThreadWarning)
        }
        if defaultDisappearingMessageTimer != nil {
            result.insert(.defaultDisappearingMessageTimer)
        }
        if collapseSet != nil {
            result.insert(.collapseSet)
        }
        if bottomButtons != nil {
            result.insert(.bottomButtons)
        }
        if bottomLabel != nil {
            result.insert(.bottomLabel)
        }
        if skippedDownloads != nil {
            result.insert(.skippedDownloads)
        }
        if sendFailureBadge != nil {
            result.insert(.sendFailureBadge)
        }
        if poll != nil {
            result.insert(.poll)
        }
        return result
    }

    var isTextOnlyMessage: Bool {
        let validKeys: [CVComponentKey] = [
            .senderName,
            .senderAvatar,
            .bodyText,
            .footer,
            .reactions,
            .sendFailureBadge,
        ]
        return activeComponentStateKeys.isSubset(of: Set(validKeys))
    }

    var isBorderlessJumbomojiMessage: Bool {
        isTextOnlyMessage && (bodyText?.isJumbomojiMessage == true)
    }

    var isBodyMediaOnlyMessage: Bool {
        var activeComponentStateKeys = activeComponentStateKeys
        // Tellomi（L-11）：普通位置（没有名称）只画地图，正文（地址 + 链接）不画，算「只有媒体」（没有小尾巴，同 Telegram 不画气泡底）。
        if tellomiLocation?.isPlace == false {
            activeComponentStateKeys.remove(.bodyText)
        }
        let validKeys: [CVComponentKey] = [
            .senderName,
            .senderAvatar,
            .bodyMedia,
            .footer,
            .reactions,
            .sendFailureBadge,
        ]
        return activeComponentStateKeys.isSubset(of: Set(validKeys))
    }

    var isBorderlessBodyMediaMessage: Bool {
        if
            isBodyMediaOnlyMessage,
            let bodyMedia,
            bodyMedia.items.count == 1,
            let firstItem = bodyMedia.items.first,
            firstItem.renderingFlag == .borderless
        {
            return true
        }
        return false
    }

    // MARK: -

    static func build(
        interaction: TSInteraction,
        itemBuildingContext: CVItemBuildingContext,
    ) throws -> CVComponentState {
        var builder = CVComponentState.Builder(
            interaction: interaction,
            itemBuildingContext: itemBuildingContext,
        )
        return try builder.populateAndBuild()
    }

    // MARK: -

    var hasPrimaryAndSecondaryContentForSelection: Bool {
        var hasPrimaryContent = false

        // Search for a component that qualifies as "non-body text primary".
        for key in activeComponentStateKeys {
            switch key {
            case .bodyText, .linkPreview:
                // "Primary" content is not body text.
                // A link preview is associated with the body text.
                break
            case .bodyMedia, .sticker, .audioAttachment, .genericAttachment, .contactShare:
                hasPrimaryContent = true
            case .senderName, .senderAvatar, .footer, .reactions, .bottomButtons, .bottomLabel, .sendFailureBadge, .dateHeader, .unreadIndicator, .typingIndicator, .threadDetails, .skippedDownloads, .unknownThreadWarning, .defaultDisappearingMessageTimer, .collapseSet, .messageRoot:
                // "Primary" content is not just metadata / UI.
                break
            case .giftBadge:
                // Gift badges can't be forwarded.
                break
            case .viewOnce:
                // We should never forward view-once messages.
                break
            case .systemMessage:
                // We should never forward system messages.
                break
            case .quotedReply:
                // Quoted replies are never forwarded.
                break
            case .paymentAttachment, .archivedPaymentAttachment:
                // Payments can't be forwarded.
                break
            case .poll:
                break
            case .undownloadableAttachment:
                break
            }
        }

        // Tellomi（L-11）：位置消息是一整块（地图和名称 / 地址），多选时不分成「图」和「文字」两半。
        let hasSecondaryContent = bodyText != nil && tellomiLocation == nil

        return hasPrimaryContent && hasSecondaryContent
    }

    // MARK: -

    static func displayableQuotedText(
        text: String,
        ranges: MessageBodyRanges?,
        interaction: TSInteraction,
        revealedSpoilerIdsSnapshot: Set<StyleId>,
        transaction: DBReadTransaction,
    ) -> DisplayableText {
        return DisplayableText.displayableText(
            withMessageBody: MessageBody(text: text, ranges: ranges ?? .empty),
            transaction: transaction,
        )
    }

    static func displayableCaption(
        text: String,
        transaction: DBReadTransaction,
    ) -> DisplayableText {
        return DisplayableText.displayableText(
            withMessageBody: MessageBody(text: text, ranges: .empty),
            transaction: transaction,
        )
    }

    // MARK: - DisplayableText

    static func displayableBodyText(
        text: String,
        ranges: MessageBodyRanges?,
        interaction: TSInteraction,
        transaction: DBReadTransaction,
    ) -> DisplayableText {
        return DisplayableText.displayableText(
            withMessageBody: MessageBody(text: text, ranges: ranges ?? .empty),
            transaction: transaction,
        )
    }

    static func displayableBodyText(
        oversizeTextAttachment attachmentStream: AttachmentStream,
        ranges: MessageBodyRanges?,
        interaction: TSInteraction,
        transaction: DBReadTransaction,
    ) -> DisplayableText {

        let text = { () -> String in
            do {
                return try attachmentStream.decryptedLongText()
            } catch {
                owsFailDebug("Couldn't load oversize text: \(error).")
                return ""
            }
        }()

        return DisplayableText.displayableText(
            withMessageBody: MessageBody(text: text, ranges: ranges ?? .empty),
            transaction: transaction,
        )
    }
}

// MARK: -

private extension CVComponentState.Builder {

    mutating func populateAndBuild() throws -> CVComponentState {

        if
            let reactionState = InteractionReactionState(
                interaction: interaction,
                transaction: transaction,
            ),
            reactionState.hasReactions
        {
            self.reactions = Reactions(
                reactionState: reactionState,
                viewState: CVReactionCountsView.buildState(with: reactionState),
            )
        }

        self.senderAvatar = tryToBuildSenderAvatar()

        self.skippedDownloads = tryToBuildSkippedDownloads()

        switch interaction.interactionType {
        case .threadDetails:
            self.threadDetails = buildThreadDetails()
            return build()
        case .unknownThreadWarning:
            // TODO: Remove this case entirely?
            return build()
        case .defaultDisappearingMessageTimer:
            self.defaultDisappearingMessageTimer = CVComponentSystemMessage.buildDefaultDisappearingMessageTimerState(
                interaction: interaction,
                threadViewModel: threadViewModel,
                transaction: transaction,
            )
            return build()
        case .typingIndicator:
            guard let typingIndicatorInteraction = interaction as? TypingIndicatorInteraction else {
                owsFailDebug("Invalid typingIndicator.")
                return build()
            }
            let avatarDataSource = { () -> ConversationAvatarDataSource? in
                guard thread.isGroupThread else {
                    return nil
                }
                return self.avatarBuilder.buildAvatarDataSource(
                    forAddress: typingIndicatorInteraction.address,
                    includingBadge: true,
                    localUserDisplayMode: .asUser,
                    diameterPoints: UInt(ConversationStyle.groupMessageAvatarSizeClass.diameter),
                )
            }()
            self.typingIndicator = TypingIndicator(
                address: typingIndicatorInteraction.address,
                avatarDataSource: avatarDataSource,
            )
            return build()
        case .info, .error, .call:
            let currentGroupThreadCallGroupId = viewStateSnapshot.currentGroupThreadCallGroupId
            self.systemMessage = CVComponentSystemMessage.buildComponentState(
                interaction: interaction,
                threadViewModel: threadViewModel,
                currentGroupThreadCallGroupId: currentGroupThreadCallGroupId,
                transaction: transaction,
            )
            return build()
        case .collapseSet:
            guard let collapseSetInteraction = interaction as? CollapseSetInteraction else {
                owsFailDebug("Invalid collapseSet interaction.")
                return build()
            }
            self.collapseSet = CVComponentState.CollapseSet(
                collapsedInteractions: collapseSetInteraction.collapsedInteractions,
                collapseSetType: collapseSetInteraction.collapseSetType,
                isExpanded: viewStateSnapshot.expandedCollapseSetIds.contains(collapseSetInteraction.uniqueId),
                finalTimerDescription: collapseSetInteraction.finalTimerDescription,
            )
            return build()
        case .unreadIndicator:
            unreadIndicator = CVComponentState.UnreadIndicator()
            return build()
        case .dateHeader:
            dateHeader = CVComponentState.DateHeader()
            return build()
        case .incomingMessage, .outgoingMessage, .releaseNotesMessage:
            guard let message = interaction as? TSMessage else {
                owsFailDebug("Invalid message.")
                return build()
            }
            return try populateAndBuild(message: message, revealedSpoilerIdsSnapshot: revealedSpoilerIdsSnapshot)
        case .unknown:
            owsFailDebug("Unknown interaction type.")
            return build()
        default:
            owsFailDebug("Invalid interaction type: \(NSStringFromOWSInteractionType(interaction.interactionType))")
            return build()
        }
    }

    private func tryToBuildSenderAvatar() -> SenderAvatar? {
        guard
            thread.isGroupThread,
            let incomingMessage = interaction as? TSIncomingMessage
        else {
            return nil
        }
        guard
            let avatarDataSource = self.avatarBuilder.buildAvatarDataSource(
                forAddress: incomingMessage.authorAddress,
                includingBadge: true,
                localUserDisplayMode: .asUser,
                diameterPoints: UInt(ConversationStyle.groupMessageAvatarSizeClass.diameter),
            )
        else {
            owsFailDebug("Could build avatar image")
            return nil
        }
        return SenderAvatar(avatarDataSource: avatarDataSource)
    }

    private func tryToBuildSkippedDownloads() -> SkippedDownloads? {
        guard let message = interaction as? TSMessage else {
            return nil
        }
        return SkippedDownloads(attachmentIds: message.skippedAttachmentIds(tx: transaction))
    }

    mutating func populateAndBuild(
        message: TSMessage,
        revealedSpoilerIdsSnapshot: Set<StyleId>,
    ) throws -> CVComponentState {

        if message.wasRemotelyDeleted {
            // If the message has been remotely deleted, suppress everything else.
            let remoteDeleteAuthor = message.displayNameForDeleteMessage(localAci: localAci, transaction: transaction)
            self.bodyText = .remotelyDeleted(deleteAuthor: remoteDeleteAuthor)
            return build()
        }

        if message.isViewOnceMessage {
            return try buildViewOnceMessage(message: message)
        }

        if let contact = message.contactShare {
            return try buildContact(message: message, contact: contact)
        }

        // Check for quoted replies _before_ media album handling,
        // since that logic may exit early.
        buildQuotedReply(message: message, revealedSpoilerIdsSnapshot: revealedSpoilerIdsSnapshot)

        if let messageSticker = message.messageSticker {
            return try buildSticker(message: message, messageSticker: messageSticker)
        }

        try buildBodyText(message: message)

        if let outgoingMessage = message as? TSOutgoingMessage {
            let messageStatus: MessageReceiptStatus
            if
                let paymentMessage = message as? OWSPaymentMessage,
                let receipt = paymentMessage.paymentNotification?.mcReceiptData,
                let model = PaymentFinder.paymentModels(
                    forMcReceiptData: receipt,
                    transaction: transaction,
                ).first
            {
                messageStatus = MessageRecipientStatusUtils.recipientStatus(
                    outgoingMessage: outgoingMessage,
                    paymentModel: model,
                )
            } else {
                messageStatus = MessageRecipientStatusUtils.recipientStatus(
                    outgoingMessage: outgoingMessage,
                    transaction: transaction,
                )
            }

            switch messageStatus {
            case .failed:
                sendFailureBadge = SendFailureBadge(color: .Signal.red)
            case .pending:
                sendFailureBadge = SendFailureBadge(color: .ows_gray60)
            default:
                break
            }
        }

        if let tsReleaseNotesMessage = message as? TSReleaseNotesMessage {
            addReleaseNotesBottomButtonIfNecessary(message: tsReleaseNotesMessage, transaction: transaction)
        }

        // Could be incoming or outgoing; protocol covers both
        if
            let paymentMessage = message as? OWSPaymentMessage,
            let paymentNotification = paymentMessage.paymentNotification
        {
            return buildPaymentAttachment(paymentNotification: paymentNotification)
        }

        if let archivedPaymentMessage = message as? OWSArchivedPaymentMessage {
            let archivedPayment = DependenciesBridge.shared.archivedPaymentStore.fetch(
                for: archivedPaymentMessage,
                interactionUniqueId: message.uniqueId,
                tx: transaction,
            )
            return buildArchivedPaymentAttachment(
                archivedPaymentMessage: archivedPaymentMessage,
                archivedPayment: archivedPayment,
            )
        }

        if let giftBadge = message.giftBadge {
            return try buildGiftBadge(messageUniqueId: message.uniqueId, giftBadge: giftBadge)
        }

        if message.isPoll {
            return try buildPoll(message: message, transaction: transaction)
        }

        do {
            let bodyAttachments = message.sqliteRowId.map {
                DependenciesBridge.shared.attachmentStore.fetchReferencedAttachments(
                    for: .messageBodyAttachment(messageRowId: $0),
                    tx: transaction,
                )
            } ?? []
            // Tellomi (ADR-0068 §4.1): an attachment sent as a file is a file row, never part of a media album.
            let tellomiAsFileAttachment = bodyAttachments.first(where: { $0.reference.renderingFlag == .tellomiAsFile })
            let mediaAlbumItems = tellomiAsFileAttachment != nil ? [] : buildMediaAlbumItems(for: bodyAttachments, message: message)
            if mediaAlbumItems.count > 0 {
                var mediaAlbumHasFailedAttachment = false
                var mediaAlbumHasSkippedAttachment = false
                // TODO
                for attachment in bodyAttachments {
                    guard
                        attachment.attachment.asStream() == nil,
                        let pointer = attachment.attachment.asAnyPointer()
                    else {
                        continue
                    }
                    switch pointer.downloadState(tx: transaction) {
                    case .enqueuedOrDownloading:
                        continue
                    case .failed:
                        mediaAlbumHasFailedAttachment = true
                    case .none:
                        // If optimize local storage is enabled, and the user has auto-downloads
                        // disabled, show the 'skipped attachment' download indicator. Otherwise
                        // render the attachment as normal, using the backup thumbnail for display.
                        let backupPlan = DependenciesBridge.shared.backupPlanManager.backupPlan(tx: transaction)
                        switch backupPlan {
                        case
                            .paid(let optimizeLocalStorage),
                            .paidAsTester(let optimizeLocalStorage),
                            .paidExpiringSoon(let optimizeLocalStorage):
                            if
                                optimizeLocalStorage,
                                canAutoDownloadAttachment(pointer: pointer, reference: attachment),
                                attachment.attachment.localRelativeFilePathThumbnail != nil
                            {
                                // If optimize storage is enabled, auto-downloads are enabled,
                                // and the backup thumbnail is present, show the backup thumbnail
                                // as a true attachment (don't show the download icon overlay).
                                mediaAlbumHasSkippedAttachment = false
                            } else {
                                mediaAlbumHasSkippedAttachment = true
                            }
                        case
                            .free,
                            .disabled,
                            .disabling:
                            mediaAlbumHasSkippedAttachment = true
                        }
                    }
                }

                self.bodyMedia = BodyMedia(
                    items: mediaAlbumItems,
                    mediaAlbumHasFailedAttachment: mediaAlbumHasFailedAttachment,
                    mediaAlbumHasSkippedAttachment: mediaAlbumHasSkippedAttachment,
                )
                return build()
            }

            // Only media galleries should have more than one attachment.
            owsAssertDebug(bodyAttachments.count <= 1 || tellomiAsFileAttachment != nil)
            if let bodyAttachment = tellomiAsFileAttachment ?? bodyAttachments.first {
                buildNonMediaAttachment(
                    referencedAttachment: bodyAttachment,
                    message: message,
                )
            }
        }

        if threadViewModel.hasPendingMessageRequest {
            // Tellomi（card-visual §3.3 / §7.3，ADR-0063 §8.1 第 6 行）：还没接受的会话里只画「域名卡」，接受以后才完整显示。
            buildTellomiMessageRequestDomainCard(message: message)
        } else if let linkPreview = message.linkPreview {
            try buildLinkPreview(message: message, linkPreview: linkPreview)
        } else {
            buildTellomiLocalLinkCard(message: message)
        }

        let result = build()
        if result.messageCellType == .unknown {
            owsFailDebug("Unknown message cell type.")
        }
        return result
    }

    private func canAutoDownloadAttachment(pointer: AttachmentPointer, reference: ReferencedAttachment) -> Bool {
        let mediaBandwidthPreferenceStore = DependenciesBridge.shared.mediaBandwidthPreferenceStore
        let reachabilityManager = SSKEnvironment.shared.reachabilityManagerRef

        let policy = AutoDownloadPolicy.build(
            context: .body,
            mimeType: reference.attachment.mimeType,
            renderingFlag: reference.reference.renderingFlag,
            plaintextSize: UInt64(safeCast: pointer.unencryptedByteCount),
        )
        switch policy {
        case .never:
            return false
        case .always:
            return true
        case .preference(let mediaType):
            return AutoDownloadPolicy.canAutoDownload(
                mediaType: mediaType,
                preferenceStore: mediaBandwidthPreferenceStore,
                isReachableViaWiFi: { reachabilityManager.isReachable(via: .wifi) },
                tx: transaction,
            )
        }
    }

    mutating func buildThreadDetails() -> ThreadDetails {
        owsAssertDebug(interaction is ThreadDetailsInteraction)

        return CVComponentThreadDetails.buildComponentState(
            thread: thread,
            transaction: transaction,
            avatarBuilder: avatarBuilder,
        )
    }

    // TODO: Should we throw more?
    mutating func buildViewOnceMessage(message: TSMessage) throws -> CVComponentState {
        owsAssertDebug(message.isViewOnceMessage)

        let tellomiSeconds = TellomiViewOnceTimer.seconds(messageUniqueId: message.uniqueId, tx: transaction)
        func buildViewOnce(viewOnceState: ViewOnceState) -> CVComponentState {
            self.viewOnce = ViewOnce(viewOnceState: viewOnceState, tellomiSeconds: tellomiSeconds)
            return self.build()
        }

        if let outgoingMessage = message as? TSOutgoingMessage {
            let viewOnceState: ViewOnceState
            if message.isViewOnceComplete {
                viewOnceState = .outgoingSentExpired
            } else {
                switch outgoingMessage.messageState {
                case .sending, .pending:
                    viewOnceState = .outgoingSending
                case .failed:
                    viewOnceState = .outgoingFailed
                default:
                    viewOnceState = .outgoingSentExpired
                }
            }
            return buildViewOnce(viewOnceState: viewOnceState)
        } else if message is TSIncomingMessage {
            if message.isViewOnceComplete {
                return buildViewOnce(viewOnceState: .incomingExpired)
            }
            let attachmentRefs = message.sqliteRowId.map {
                DependenciesBridge.shared.attachmentStore.fetchReferences(
                    owners: [
                        .messageOversizeText(messageRowId: $0),
                        .messageBodyAttachment(messageRowId: $0),
                    ],
                    tx: transaction,
                )
            } ?? []
            let hasMoreThanOneAttachment: Bool = attachmentRefs.count > 1
            let hasBodyText: Bool = !(message.body?.isEmpty ?? true)
            if hasMoreThanOneAttachment || hasBodyText {
                // Refuse to render incoming "view once" messages if they
                // have more than one attachment or any body text.
                owsFailDebug("Invalid content.")
                return buildViewOnce(viewOnceState: .incomingInvalidContent)
            }
            let mediaAttachments: [ReferencedAttachment] = message.sqliteRowId.map {
                DependenciesBridge.shared.attachmentStore
                    .fetchReferencedAttachments(
                        for: .messageBodyAttachment(messageRowId: $0),
                        tx: transaction,
                    )
            } ?? []
            // We currently only support single attachments for view-once messages.
            guard let mediaAttachment = mediaAttachments.first else {
                owsFailDebug("Missing attachment.")
                return buildViewOnce(viewOnceState: .incomingInvalidContent)
            }
            let renderingFlag = mediaAttachment.reference.renderingFlag
            if let attachmentStream = mediaAttachment.attachment.asStream() {
                if
                    attachmentStream.contentType.isVisualMedia,

                    MimeTypeUtil.isSupportedImageMimeType(attachmentStream.mimeType)
                    || MimeTypeUtil.isSupportedMaybeAnimatedMimeType(attachmentStream.mimeType)
                    || MimeTypeUtil.isSupportedVideoMimeType(attachmentStream.mimeType)

                {
                    return buildViewOnce(viewOnceState: .incomingAvailable(
                        attachmentStream: attachmentStream,
                        renderingFlag: renderingFlag,
                    ))
                }
            } else if let attachmentPointer = mediaAttachment.attachment.asAnyPointer() {
                switch attachmentPointer.downloadState(tx: transaction) {
                case .enqueuedOrDownloading:
                    return buildViewOnce(viewOnceState: .incomingDownloading(
                        attachmentPointer: attachmentPointer,
                        renderingFlag: renderingFlag,
                    ))
                case .failed:
                    return buildViewOnce(viewOnceState: .incomingFailed)
                case .none:
                    return buildViewOnce(viewOnceState: .incomingPending)
                }
            } else {
                return buildViewOnce(viewOnceState: .incomingUndownloadable)
            }

            owsFailDebug("Invalid content.")
            return buildViewOnce(viewOnceState: .incomingInvalidContent)
        } else {
            throw OWSAssertionError("Invalid message.")
        }
    }

    // TODO: Should we throw more?
    mutating func buildContact(message: TSMessage, contact: OWSContact) throws -> CVComponentState {
        let contactShare = ContactShareViewModel(
            contactShareRecord: contact,
            parentMessage: message,
            transaction: transaction,
        )
        let state = CVContactShareView.buildState(
            contactShare: contactShare,
            isIncoming: isIncoming,
            conversationStyle: conversationStyle,
            transaction: transaction,
        )
        self.contactShare = ContactShare(state: state)

        let phoneNumberPartition = contactShare.dbRecord.phoneNumberPartition(tx: transaction)
        let phoneNumberAction: CVMessageAction? = phoneNumberPartition.map(
            ifSendablePhoneNumbers: {
                // If system contacts are known/linkable, show a "Send" button.
                return CVMessageAction(
                    title: CommonStrings.sendMessage,
                    accessibilityIdentifier: "send_message_to_contact_share",
                    action: .didTapSendMessage(phoneNumbers: $0),
                )
            },
            elseIfInvitablePhoneNumbers: { _ in
                // If system contacts aren't registered, show an "Invite" button.
                return CVMessageAction(
                    title: OWSLocalizedString("ACTION_INVITE", comment: "Label for 'invite' button in contact view."),
                    accessibilityIdentifier: "invite_contact_share",
                    action: .didTapSendInvite(contactShare: contactShare),
                )
            },
            elseIfAddablePhoneNumbers: { _ in
                // Otherwise, offer to add the number(s) to your address book.
                return CVMessageAction(
                    title: OWSLocalizedString("CONVERSATION_VIEW_ADD_TO_CONTACTS_OFFER", comment: "Message shown in conversation view that offers to add an unknown user to your phone's contacts."),
                    accessibilityIdentifier: "add_to_contacts",
                    action: .didTapAddToContacts(contactShare: contactShare),
                )
            },
            elseIfNoPhoneNumbers: {
                return nil
            },
        )
        if let phoneNumberAction {
            bottomButtonsActions.append(phoneNumberAction)
        }

        return build()
    }

    // TODO: Should we throw more?
    mutating func buildSticker(message: TSMessage, messageSticker: MessageSticker) throws -> CVComponentState {

        guard
            let rowId = message.sqliteRowId,
            let referencedAttachment = DependenciesBridge.shared.attachmentStore.fetchAnyReferencedAttachment(
                for: .messageSticker(messageRowId: rowId),
                tx: transaction,
            )
        else {
            throw OWSAssertionError("Missing sticker attachment.")
        }

        let cvAttachment = CVAttachment.from(
            referencedAttachment: referencedAttachment,
            message: message,
            tx: transaction,
        )

        switch cvAttachment {
        case .stream(let referencedAttachmentStream, let isUploading, let imageMetadata):
            if let imageMetadata {
                let stickerMetadata = EncryptedStickerMetadata(
                    stickerInfo: messageSticker.info,
                    stickerType: StickerManager.stickerType(forContentType: referencedAttachmentStream.attachment.mimeType),
                    emojiString: messageSticker.emoji,
                    encryptedStickerDataUrl: referencedAttachmentStream.attachmentStream.fileURL,
                    encryptionKey: referencedAttachmentStream.attachmentStream.attachment.encryptionKey,
                    plaintextLength: referencedAttachmentStream.attachmentStream.unencryptedByteCount,
                )

                self.sticker = .available(
                    stickerMetadata: stickerMetadata,
                    attachmentStream: referencedAttachmentStream,
                    isUploading: isUploading,
                    imageMetadata: imageMetadata,
                )
            } else {
                self.sticker = .invalidImage(attachmentId: referencedAttachmentStream.attachment.id)
            }
        case .pointer(let referencedAttachmentPointer, let downloadState):
            switch downloadState {
            case .enqueuedOrDownloading:
                self.sticker = .downloading(attachmentPointer: referencedAttachmentPointer)
            case .failed, .none:
                self.sticker = .skipped(
                    attachmentPointer: referencedAttachmentPointer,
                    downloadState: downloadState,
                )
            }
        case .backupThumbnail, .undownloadable:
            self.undownloadableAttachment = .sticker
        }

        return build()
    }

    // TODO: Should we validate and throw errors?
    mutating func buildQuotedReply(
        message: TSMessage,
        revealedSpoilerIdsSnapshot: Set<StyleId>,
    ) {
        let quotedReplyModel: QuotedReplyModel? = {
            if
                message.isStoryReply,
                let storyAuthorAci = message.storyAuthorAci?.wrappedAciValue
            {
                return QuotedReplyModel.build(
                    storyReplyMessage: message,
                    storyTimestamp: message.storyTimestamp?.uint64Value,
                    storyAuthorAci: storyAuthorAci,
                    transaction: transaction,
                )
            } else if let quotedMessage = message.quotedMessage {
                var memberLabel: String?
                if
                    let groupThread = thread as? TSGroupThread,
                    !threadViewModel.hasPendingMessageRequest,
                    let originalMessageAuthor = quotedMessage.authorAddress.aci
                {
                    memberLabel = groupThread.groupModel.groupMembership.memberLabel(for: originalMessageAuthor)?.labelForRendering()
                    memberLabel = memberLabel?
                        .components(separatedBy: .whitespaces)
                        .joined(separator: SignalSymbol.LeadingCharacter.nonBreakingSpace.rawValue)
                }

                return QuotedReplyModel.build(replyMessage: message, quotedMessage: quotedMessage, memberLabel: memberLabel, transaction: transaction)
            } else {
                return nil
            }
        }()
        guard let quotedReplyModel else {
            return
        }
        var displayableQuotedText: DisplayableText?
        if
            let quotedBody = quotedReplyModel.originalMessageBody, !quotedBody.text.isEmpty,
            // Tellomi (spec attachment-files-location §3.3.1): a reply to a location shows the map and "Location"
            // (`CVQuotedMessageView.fileTypeForSnippet`), not the name / address / link, like Telegram's reply header.
            !TellomiLocationMessage.isQuotedLocation(
                body: quotedBody.text,
                attachmentMimeType: quotedReplyModel.originalContent.attachmentMimeType,
            )
        {
            displayableQuotedText = CVComponentState.displayableQuotedText(
                text: quotedBody.text,
                ranges: quotedBody.ranges,
                interaction: message,
                revealedSpoilerIdsSnapshot: revealedSpoilerIdsSnapshot,
                transaction: transaction,
            )
        }
        let viewState = CVQuotedMessageView.stateForConversation(
            quotedReplyModel: quotedReplyModel,
            displayableQuotedText: displayableQuotedText,
            conversationStyle: conversationStyle,
            isOutgoing: isOutgoing,
            transaction: transaction,
        )
        self.quotedReply = QuotedReply(viewState: viewState)
    }

    mutating func buildBodyText(message: TSMessage) throws {
        if message.isPoll {
            return
        }
        // Tellomi (ADR-0075 §4.4, as Telegram): with per-media captions the bubble shows one caption, or only the
        // whole message's (or none); the body is then the text for other clients, and its ranges belong to it.
        if let caption = TellomiCaptionAbove.bubbleCaption(message: message, tx: transaction), caption != message.body {
            let displayableText = CVComponentState.displayableBodyText(
                text: caption,
                ranges: nil,
                interaction: message,
                transaction: transaction,
            )
            guard !displayableText.fullTextValue.isEmpty else {
                bodyText = nil
                return
            }
            let hasTapForMore = displayableText.isTextTruncated
                && !viewStateSnapshot.textExpansion.isTextExpanded(interactionId: message.uniqueId)
            bodyText = .bodyText(displayableText: displayableText, hasTapForMore: hasTapForMore)
            return
        }
        bodyText = try CVComponentBodyText.buildComponentState(
            message: message,
            skippedAttachmentIds: skippedDownloads?.attachmentIds ?? [],
            viewStateSnapshot: viewStateSnapshot,
            transaction: transaction,
        )
    }

    // MARK: -

    func buildMediaAlbumItems(
        for mediaAttachments: [ReferencedAttachment],
        message: TSMessage,
    ) -> [CVMediaAlbumItem] {

        let threadHasPendingMessageRequest = message.thread(tx: transaction)?
            .hasPendingMessageRequest(transaction: transaction)
            ?? false

        var mediaAlbumItems = [CVMediaAlbumItem]()
        for referencedAttachment in mediaAttachments {
            guard
                // Use the validated content type and only fall back to the mime type.
                referencedAttachment.attachment.asStream()?.contentType.isVisualMedia
                ?? MimeTypeUtil.isSupportedVisualMediaMimeType(referencedAttachment.attachment.mimeType)
            else {
                // Well behaving clients should not send a mix of visual media (like JPG) and non-visual media (like PDF's)
                // Since we're not coped to handle a mix of media, return @[]
                owsAssertDebug(mediaAlbumItems.count == 0)
                return []
            }

            let cvAttachment = CVAttachment.from(
                referencedAttachment: referencedAttachment,
                message: message,
                tx: transaction,
            )

            let caption = referencedAttachment.reference.legacyMessageCaption
            let hasCaption = caption.map {
                return !CVComponentState.displayableCaption(
                    text: $0,
                    transaction: transaction,
                ).fullTextValue.isEmpty
            } ?? false

            switch cvAttachment {
            case .pointer:
                var mediaSize: CGSize = .zero
                if let sourceMediaSizePixels = referencedAttachment.reference.sourceMediaSizePixels {
                    mediaSize = sourceMediaSizePixels
                } else {
                    owsFailDebug("Invalid attachment.")
                }
                mediaAlbumItems.append(CVMediaAlbumItem(
                    attachment: cvAttachment,
                    attachmentStream: nil,
                    hasCaption: hasCaption,
                    mediaSize: mediaSize,
                    isBroken: false,
                    threadHasPendingMessageRequest: threadHasPendingMessageRequest,
                ))
            case .stream(let referencedAttachmentStream, isUploading: _, let imageMetadata):
                let attachmentStream = referencedAttachmentStream.attachmentStream
                let brokenAlbumItem = CVMediaAlbumItem(
                    attachment: cvAttachment,
                    attachmentStream: nil,
                    hasCaption: hasCaption,
                    mediaSize: .zero,
                    isBroken: true,
                    threadHasPendingMessageRequest: threadHasPendingMessageRequest,
                )

                switch attachmentStream.contentType {
                case .audio, .file:
                    owsFailDebug("Building media album, but have audio or file attachment?")
                    mediaAlbumItems.append(brokenAlbumItem)
                case .video:
                    if let mediaSizePixels = attachmentStream.cachedMediaSizePixels {
                        mediaAlbumItems.append(CVMediaAlbumItem(
                            attachment: cvAttachment,
                            attachmentStream: attachmentStream,
                            hasCaption: hasCaption,
                            mediaSize: mediaSizePixels,
                            isBroken: false,
                            threadHasPendingMessageRequest: threadHasPendingMessageRequest,
                        ))
                    } else {
                        mediaAlbumItems.append(brokenAlbumItem)
                    }
                case .image:
                    if
                        let mediaSizePixels = attachmentStream.cachedMediaSizePixels,
                        imageMetadata != nil
                    {
                        mediaAlbumItems.append(CVMediaAlbumItem(
                            attachment: cvAttachment,
                            attachmentStream: attachmentStream,
                            hasCaption: hasCaption,
                            mediaSize: mediaSizePixels,
                            isBroken: false,
                            threadHasPendingMessageRequest: threadHasPendingMessageRequest,
                        ))
                    } else {
                        mediaAlbumItems.append(brokenAlbumItem)
                    }
                }
            case .backupThumbnail(let thumbnail):
                // TODO: Need to make CVMediaAlbumItem take a thumbnail
                var mediaSize: CGSize = .zero
                // need to determine if a size is possible
                // TODO Cache this
                if let sourceMediaSizePixels = thumbnail.attachmentBackupThumbnail.image?.size {
                    mediaSize = sourceMediaSizePixels
                } else {
                    owsFailDebug("Invalid attachment.")
                }
                mediaAlbumItems.append(CVMediaAlbumItem(
                    attachment: cvAttachment,
                    attachmentStream: nil,
                    hasCaption: hasCaption,
                    mediaSize: mediaSize,
                    isBroken: false,
                    threadHasPendingMessageRequest: threadHasPendingMessageRequest,
                ))
            case .undownloadable(let attachment):
                var mediaSize: CGSize = .zero
                if let sourceMediaSizePixels = attachment.reference.sourceMediaSizePixels {
                    mediaSize = sourceMediaSizePixels
                } else {
                    owsFailDebug("Invalid attachment.")
                }
                mediaAlbumItems.append(CVMediaAlbumItem(
                    attachment: cvAttachment,
                    attachmentStream: nil,
                    hasCaption: hasCaption,
                    mediaSize: mediaSize,
                    isBroken: true,
                    threadHasPendingMessageRequest: threadHasPendingMessageRequest,
                ))
            }
        }
        // Tellomi (tellomi/tellomi#1263, spec R-1): covered (spoiler) images / videos. One album item per attachment, in order.
        for (index, referencedAttachment) in mediaAttachments.enumerated() where index < mediaAlbumItems.count {
            mediaAlbumItems[index].isTellomiSpoilerCovered = TellomiMediaSpoiler.isCovered(referencedAttachment.reference, tx: transaction)
            // spec R-2: live photos
            mediaAlbumItems[index].tellomiLiveVideo = TellomiLivePhoto.video(referencedAttachment.reference, tx: transaction)
        }
        return mediaAlbumItems
    }

    mutating func buildNonMediaAttachment(
        referencedAttachment: ReferencedAttachment,
        message: TSMessage,
    ) {
        guard
            // Tellomi (ADR-0068 §4.1): sent as a file is a file row whatever the content type, audio included.
            referencedAttachment.reference.renderingFlag != .tellomiAsFile,
            // Use the validated content type and only fall back to the mime type.
            referencedAttachment.attachment.asStream()?.contentType.isAudio
            ?? MimeTypeUtil.isSupportedAudioMimeType(referencedAttachment.attachment.mimeType)
        else {
            let cvAttachment = CVAttachment.from(
                referencedAttachment: referencedAttachment,
                message: message,
                tx: transaction,
            )
            self.genericAttachment = .init(attachment: cvAttachment)
            return
        }

        if
            let attachmentStream = referencedAttachment.asReferencedStream,
            let audioAttachment = AudioAttachment(
                attachmentStream: attachmentStream,
                owningMessage: interaction as? TSMessage,
                metadata: nil,
                receivedAtDate: interaction.receivedAtDate,
            )
        {
            self.audioAttachment = audioAttachment
        } else if let referencedAttachmentPointer = referencedAttachment.asReferencedAnyPointer {
            self.audioAttachment = AudioAttachment(
                attachmentPointer: referencedAttachmentPointer,
                owningMessage: interaction as? TSMessage,
                metadata: nil,
                receivedAtDate: interaction.receivedAtDate,
                downloadState: referencedAttachmentPointer.attachmentPointer.downloadState(tx: transaction),
            )
        } else {
            self.undownloadableAttachment = .audio
        }
    }

    mutating func buildPaymentAttachment(
        paymentNotification: TSPaymentNotification,
    ) -> CVComponentState {

        // Note: there should only ever be one payment model per receipt,
        // but this is unenforced.
        let paymentModel: TSPaymentModel? = PaymentFinder.paymentModels(
            forMcReceiptData: paymentNotification.mcReceiptData,
            transaction: itemBuildingContext.transaction,
        ).first

        self.paymentAttachment = PaymentAttachment(
            notification: paymentNotification,
            model: paymentModel,
            // Only used for 1:1 threads, but not enforced.
            otherUserShortName: threadViewModel.shortName ?? threadViewModel.name,
        )

        return build()
    }

    mutating func buildArchivedPaymentAttachment(
        archivedPaymentMessage: OWSArchivedPaymentMessage,
        archivedPayment: ArchivedPayment?,
    ) -> CVComponentState {

        self.archivedPaymentAttachment = ArchivedPaymentAttachment(
            amount: PaymentsFormat.formatFromArchive(amount: archivedPaymentMessage.archivedPaymentInfo.amount),
            fee: PaymentsFormat.formatFromArchive(amount: archivedPaymentMessage.archivedPaymentInfo.fee),
            note: archivedPaymentMessage.archivedPaymentInfo.note,
            // Only used for 1:1 threads, but not enforced.
            otherUserShortName: threadViewModel.shortName ?? threadViewModel.name,
            archivedPayment: archivedPayment,
        )

        return build()
    }

    private mutating func buildLinkPreview(message: TSMessage, linkPreview: OWSLinkPreview) throws {
        guard bodyText != nil else {
            owsFailDebug("Missing body text.")
            return
        }
        guard let urlString = linkPreview.urlString else {
            owsFailDebug("Missing urlString.")
            return
        }
        guard let url = URL(string: urlString) else {
            owsFailDebug("Invalid urlString.")
            return
        }
        if
            let groupInviteLinkUrl = PossibleGroupInviteLinkUrl.parseFrom(url),
            let groupInviteLink = try? GroupInviteLink.parseFrom(groupInviteLinkUrl)
        {
            // Tellomi（ADR-0063 §4.1，tellomi/tellomi#1423）：只用 snapshot 和本地库，渲染时不联网
            if
                let state = CVComponentState.localGroupInviteLinkPreviewState(
                    linkPreview: linkPreview,
                    messageRowId: message.sqliteRowId,
                    groupInviteLink: groupInviteLink,
                    linkType: isIncoming ? .incomingMessageGroupInviteLink : .outgoingMessageGroupInviteLink,
                    conversationStyle: conversationStyle,
                    transaction: transaction,
                )
            {
                // 群邀请卡按第一方卡画（头像 + 群名 + 人数 / 已加入 + 底部按钮，card-visual §5.2）；认不出就照 Signal 原样。
                let wrapped = tellomiFirstPartyState(
                    base: state,
                    message: message,
                    linkPreview: linkPreview,
                    urlString: urlString,
                    hasImage: state.hasLoadedImageOrBlurHash,
                    linkOnlyUrl: tellomiLinkOnlyUrl(message: message),
                )
                self.linkPreview = LinkPreview(
                    linkPreview: linkPreview,
                    state: wrapped ?? state,
                )
            }
        } else if let callLink = CallLink(url: url) {
            let callState = LinkPreviewCallLink(previewType: .sent(linkPreview, conversationStyle), callLink: callLink)
            // Tellomi（card-visual §5.2，审计 A14）：tell.cc 的通话链接按第一方卡画——通话图标 + 房间名或「Tellomi 通话」 + 底部「加入通话」，
            // 不带发送端的描述和域名行。点进入通话的行为不变：点卡片 → `handleUrl` → `CallLink(url:)` → `presentLobby`（和 Signal 通话卡同一条路）。
            // 第一方卡自带按钮，不再加 Signal 自己卡片外面的「加入」按钮。认不出来（注册表没装上、`signal.link` 的老形状）就照 Signal 原样。
            if
                let wrapped = tellomiFirstPartyState(
                    base: callState,
                    message: message,
                    linkPreview: linkPreview,
                    urlString: urlString,
                    hasImage: false,
                    linkOnlyUrl: tellomiLinkOnlyUrl(message: message),
                )
            {
                self.linkPreview = LinkPreview(linkPreview: linkPreview, state: wrapped)
            } else {
                let bottomButtonAction = CVMessageAction(
                    title: OWSLocalizedString(
                        "CONVERSATION_VIEW_JOIN_CALL",
                        comment: "Message shown in conversation view that offers to join a Call Link call.",
                    ),
                    accessibilityIdentifier: "join_call_link_call",
                    action: .didTapJoinCallLinkCall(callLink: callLink),
                )
                bottomButtonsActions.append(bottomButtonAction)
                self.linkPreview = LinkPreview(
                    linkPreview: linkPreview,
                    state: callState,
                )
            }
        } else {
            // Tellomi（ADR-0063 §5.3，审计 I9）：预览「有没有图」看附件引用在不在（`Preview.image` 有没有），
            // 不看下没下载完、也不看有没有 blurHash——否则图还没下完的时候，video / app 这类必须有图的卡会被临时判成品牌壳，
            // 下完又升回去，卡片跳来跳去。下面的 `linkPreviewAttachment` 只管「现在能画出什么」。
            let referencedLinkPreviewImage = message.sqliteRowId.flatMap { rowId in
                DependenciesBridge.shared.attachmentStore.fetchAnyReferencedAttachment(
                    for: .messageLinkPreview(messageRowId: rowId),
                    tx: transaction,
                )
            }

            let linkPreviewAttachment = { () -> ReferencedAttachment? in
                guard let linkPreviewAttachment = referencedLinkPreviewImage else {
                    return nil
                }

                guard MimeTypeUtil.isSupportedImageMimeType(linkPreviewAttachment.attachment.mimeType) else {
                    owsFailDebug("Link preview attachment isn't an image.")
                    return nil
                }
                if let attachmentStream = linkPreviewAttachment.asReferencedStream {
                    guard attachmentStream.attachmentStream.contentType.isImage else {
                        owsFailDebug("Link preview image attachment isn't valid.")
                        return nil
                    }
                    return attachmentStream
                } else if
                    let blurHash = linkPreviewAttachment.attachment.blurHash,
                    BlurHash.isValidBlurHash(blurHash)
                {
                    return linkPreviewAttachment
                } else {
                    return nil
                }
            }()

            let isFailedImageAttachmentDownload: Bool
            if linkPreviewAttachment?.attachment.asStream() == nil {
                switch linkPreviewAttachment?.attachment.asAnyPointer()?.downloadState(tx: transaction) ?? .none {
                case .none, .enqueuedOrDownloading:
                    isFailedImageAttachmentDownload = false
                case .failed:
                    isFailedImageAttachmentDownload = true
                }
            } else {
                isFailedImageAttachmentDownload = false
            }

            let sentState = LinkPreviewSent(
                linkPreview: linkPreview,
                imageAttachment: linkPreviewAttachment,
                isFailedImageAttachmentDownload: isFailedImageAttachmentDownload,
                conversationStyle: conversationStyle,
            )
            // Tellomi（ADR-0063 §5.1 第 4 条，tellomi/tellomi#1423）：卡片的级别由 rust/links 定，在这里（数据层）判，不在 view 绑定里。
            guard
                let state = tellomiLinkPreviewState(
                    sentState: sentState,
                    message: message,
                    linkPreview: linkPreview,
                    urlString: urlString,
                    imageAttachment: linkPreviewAttachment,
                    hasImage: referencedLinkPreviewImage != nil,
                    linkOnlyUrl: tellomiLinkOnlyUrl(message: message),
                )
            else {
                return
            }
            self.linkPreview = LinkPreview(
                linkPreview: linkPreview,
                state: state,
            )
        }
    }

    /// Tellomi（ADR-0063 §5.1，card-visual §3.5 / §3.7）：按 rust/links 定的级别改写这条预览显示的文字，发送端写的描述从不显示。
    ///
    /// - 没有注册表、没有判定：照 Signal 原样（返回 `sentState`）；
    /// - 群、通话、贴纸卡：等第一方卡版式，之前也照 Signal 原样；
    /// - 纯链接级：只有「消息就是这条链接」时画成无图卡（域名 + 链接图标），否则不显示这条预览（返回 nil）；
    /// - 消息就是这条链接、卡片有了判定：只画卡片（`isCardOnly`），不再画链接文字。
    private func tellomiLinkPreviewState(
        sentState: LinkPreviewSent,
        message: TSMessage,
        linkPreview: OWSLinkPreview,
        urlString: String,
        imageAttachment: ReferencedAttachment?,
        hasImage: Bool,
        linkOnlyUrl: String?,
    ) -> LinkPreviewState? {
        let classifier = TellomiLinkRegistry.classifier
        guard classifier.isAvailable else {
            return sentState
        }
        // `hasImage` 是「预览带不带图」，和 `imageAttachment`（现在画得出的那张）不是一回事，级别只看前者。
        let card = tellomiClassify(message: message, linkPreview: linkPreview, urlString: urlString, hasImage: hasImage)
        guard let card else {
            return sentState
        }
        let isCardOnly = TellomiLinkOnly.isLinkCardOnly(linkOnlyUrl: linkOnlyUrl, previewUrls: [urlString], card: card)
        if card.level == .plainLink {
            guard isCardOnly, let linkOnlyUrl, card.domain != nil else {
                return nil
            }
            return tellomiPlainLinkState(base: sentState, card: card, linkOnlyUrl: linkOnlyUrl)
        }
        if
            let firstParty = tellomiFirstPartyState(
                base: sentState,
                message: message,
                linkPreview: linkPreview,
                urlString: urlString,
                hasImage: hasImage,
                linkOnlyUrl: linkOnlyUrl,
                card: card,
            )
        {
            return firstParty
        }
        guard
            let display = TellomiLinkDisplay.make(
                snapshotTitle: sentState.title,
                card: card,
                locale: .current,
                strings: .localized(),
            )
        else {
            return sentState
        }
        // card-visual §3.2 / §3.3：版式（图标卡 / 大图卡 / 无图）和图的颜色由 rust/links 定，在数据层（工作线程）一起判。
        // 品牌壳的图是随包图标（card-visual §3.9），不看发送端的图：包里读得到才用，读不到就和以前一样只出平台名 + 域名。
        let icon = card.level == .brand ? card.icon.flatMap { TellomiLinkIcon.icon(named: $0) } : nil
        // 版式只看图的真实像素尺寸：图没下完、发送端又没写宽高时不知道多大，按「没有图」问（不能拿 blurHash 的默认尺寸去猜成图标卡，
        // 下完以后真实尺寸若是大图卡版式就跳一下）。
        let visual = TellomiLinkVisualReader.visual(
            card: card,
            attachment: imageAttachment,
            imagePixelSize: sentState.knownImagePixelSize ?? .zero,
            icon: icon,
        )
        return TellomiLinkPreviewCardState(
            base: sentState,
            display: display,
            showsImage: card.showImage,
            isCardOnly: isCardOnly,
            visual: visual,
            bundledIcon: visual.layout == .icon ? icon : nil,
        )
    }

    private func tellomiClassify(
        message: TSMessage,
        linkPreview: OWSLinkPreview,
        urlString: String,
        hasImage: Bool,
    ) -> TellomiLinkCard? {
        let attachmentContentTypes = message.sqliteRowId.map {
            DependenciesBridge.shared.attachmentStore.fetchReferencedAttachments(
                for: .messageBodyAttachment(messageRowId: $0),
                tx: transaction,
            ).map { $0.attachment.mimeType }
        } ?? []
        return TellomiLinkRegistry.classifier.classify(
            TellomiLinkClassifier.PreviewInput(
                url: urlString,
                title: linkPreview.title,
                description: linkPreview.previewDescription,
                hasImage: hasImage,
                date: linkPreview.date,
                rich: linkPreview.rich,
            ),
            body: message.body ?? "",
            isStory: false,
            attachmentContentTypes: attachmentContentTypes,
        )
    }

    /// Tellomi 自己对象的卡片（用户 / 群 / 通话 / 贴纸包 / 官网，card-visual §5.2）：文字来自 URL 和本机已有的东西，
    /// 发送端写的只用群名、包名和通话的房间名。不是第一方卡返回 nil。
    private func tellomiFirstPartyState(
        base: LinkPreviewState,
        message: TSMessage,
        linkPreview: OWSLinkPreview,
        urlString: String,
        hasImage: Bool,
        linkOnlyUrl: String?,
        card: TellomiLinkCard? = nil,
    ) -> LinkPreviewState? {
        guard TellomiLinkRegistry.classifier.isAvailable, let url = URL(string: urlString) else {
            return nil
        }
        let card = card ?? tellomiClassify(message: message, linkPreview: linkPreview, urlString: urlString, hasImage: hasImage)
        guard let card, card.level == .firstParty else {
            return nil
        }
        let local = TellomiFirstPartyLocalLookup.local(url: url, card: card, tx: transaction)
        guard let firstParty = TellomiFirstPartyCard.display(card: card, local: local, strings: .localized()) else {
            return nil
        }
        // 本机认识的用户：头像从本地库取（只读，不联网），在这里（有事务）取好交给界面；cell 配置阶段不许开事务。
        let userAvatar = firstParty.avatarAci.flatMap { aci in
            SSKEnvironment.shared.avatarBuilderRef.avatarImage(
                forAddress: SignalServiceAddress(aci),
                diameterPoints: 56,
                localUserDisplayMode: .asUser,
                transaction: transaction,
            )
        }
        return TellomiLinkPreviewCardState(
            base: base,
            display: TellomiLinkDisplay(
                title: firstParty.title,
                description: firstParty.subtitle,
                domain: nil,
                officialBadge: firstParty.officialBadge,
            ),
            showsImage: card.showImage,
            isCardOnly: TellomiLinkOnly.isLinkCardOnly(linkOnlyUrl: linkOnlyUrl, previewUrls: [urlString], card: card),
            visual: TellomiLinkVisual.Visual(layout: .firstParty, tint: nil),
            firstParty: firstParty,
            userAvatar: userAvatar,
        )
    }

    /// 只用 URL 画的无图卡：rust/links 算的可注册域名，以及它是否冒充知名域名；发送端写的一概不要。
    /// `isCardOnly`：气泡只画卡片、不画链接文字；`isInert`：卡片不响应点击（消息请求里的域名卡，二者取 false / true）。
    private func tellomiPlainLinkState(
        base: LinkPreviewState,
        card: TellomiLinkCard,
        linkOnlyUrl: String,
        isCardOnly: Bool = true,
        isInert: Bool = false,
    ) -> LinkPreviewState? {
        let plain = TellomiLinkOnly.toPlainLinkCard(card, lookalike: TellomiLinkRegistry.classifier.lookalike(forUrl: linkOnlyUrl))
        guard
            let display = TellomiLinkDisplay.make(snapshotTitle: nil, card: plain, locale: .current, strings: .localized())
        else {
            return nil
        }
        return TellomiLinkPreviewCardState(base: base, display: display, showsImage: false, isCardOnly: isCardOnly, isInert: isInert)
    }

    /// 消息请求里的域名卡（口径 S1，card-visual §3.3 / §7.3，ADR-0063 §8.1 第 6 行）：还没接受的会话里，收到的链接只画域名——
    /// 链接图标 + rust/links 从那条 URL 算的可注册域名（冒充知名域名照旧标红）。
    /// - 只把 URL 交给 rust/links，发送端写的标题 / 描述 / 日期 / rich / 有没有图一样都不给；不管它判成什么级别
    ///   （品牌壳、第一方卡、结构化……）都只留域名，所以没有标题、副行、图、品牌壳图标，也没有第一方卡的头像、群名和按钮；
    /// - 不染色（没有图可取色）；不响应点击（`isInert`，同 Telegram iOS 对可疑发件人的 `isSuspiciousPeer`）；
    /// - 正文里的链接文字不隐藏（`isCardOnly: false`）：消息请求里正文本来就不可点，完整地址靠它看；
    /// - 不读预览图附件，也不为它建下载：这条路径根本不去取 `.messageLinkPreview` 的附件。接受以后才按正常规则完整显示。
    /// URL 取预览里的那条（收到时 Signal 已经核过它在正文里）；没有预览时取「整条消息就是一条链接」的那条。只画收到的消息。
    private mutating func buildTellomiMessageRequestDomainCard(message: TSMessage) {
        guard
            isIncoming,
            let urlString = message.linkPreview?.urlString ?? tellomiLinkOnlyUrl(message: message),
            TellomiLinkRegistry.classifier.isAvailable
        else {
            return
        }
        let local = OWSLinkPreview(urlString: urlString)
        guard
            let card = tellomiClassify(message: message, linkPreview: local, urlString: urlString, hasImage: false),
            card.domain != nil
        else {
            return
        }
        let base = LinkPreviewSent(
            linkPreview: local,
            imageAttachment: nil,
            isFailedImageAttachmentDownload: false,
            conversationStyle: conversationStyle,
        )
        guard
            let state = tellomiPlainLinkState(base: base, card: card, linkOnlyUrl: urlString, isCardOnly: false, isInert: true)
        else {
            return
        }
        self.linkPreview = LinkPreview(linkPreview: local, state: state)
    }

    /// 消息就是一条链接、发出来时没有预览（预览关了，或没抓到）：接收端也画一张无图卡（card-visual §3.5，与 Android / Desktop 一样）。
    private mutating func buildTellomiLocalLinkCard(message: TSMessage) {
        let classifier = TellomiLinkRegistry.classifier
        guard
            classifier.isAvailable,
            let linkOnlyUrl = tellomiLinkOnlyUrl(message: message)
        else {
            return
        }
        let card = classifier.classify(
            TellomiLinkClassifier.PreviewInput(url: linkOnlyUrl),
            body: message.body ?? "",
            isStory: false,
            attachmentContentTypes: [],
        )
        guard let card, card.domain != nil else {
            return
        }
        let local = OWSLinkPreview(urlString: linkOnlyUrl)
        let base = LinkPreviewSent(
            linkPreview: local,
            imageAttachment: nil,
            isFailedImageAttachmentDownload: false,
            conversationStyle: conversationStyle,
        )
        guard let state = tellomiPlainLinkState(base: base, card: card, linkOnlyUrl: linkOnlyUrl) else {
            return
        }
        self.linkPreview = LinkPreview(linkPreview: local, state: state)
    }

    // NSDataDetector 建起来很贵，Signal 自己也是复用一个。
    private static let tellomiLinkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// 消息除了一条链接什么都没有（card-visual §3.5）时，那条链接；否则 nil。
    /// 「什么都没有」：没有格式 / 提及、附件、贴纸、联系人、支付、礼物、投票、阅后即焚、故事、已删除，
    /// 正文是普通文字，而且 Signal 自己的链接识别把整段认成一条链接（清单同 Android `TellomiLinkOnly.hasOtherContent`）。
    private func tellomiLinkOnlyUrl(message: TSMessage) -> String? {
        guard
            case .bodyText(let displayableText, let hasTapForMore) = bodyText,
            !hasTapForMore
        else {
            return nil
        }
        let hasOtherContent = messageHasBodyAttachments
            || bodyMedia != nil
            || genericAttachment != nil
            || audioAttachment != nil
            || paymentAttachment != nil
            || archivedPaymentAttachment != nil
            || viewOnce != nil
            || sticker != nil
            || contactShare != nil
            || giftBadge != nil
            || poll != nil
            || undownloadableAttachment != nil
            || message.isViewOnceMessage
            || message.wasRemotelyDeleted
            || message.isStoryReply
            || message.isPoll
            || message.messageSticker != nil
            || message.bodyRanges?.hasRanges == true
        return TellomiLinkOnly.linkOnlyUrl(
            body: message.body,
            hasOtherContent: hasOtherContent,
            linkRanges: { text in
                // 便宜的前缀检查过了才到这里；Signal 拒绝链接化的正文（可疑链接）不算「一条链接」。
                guard displayableText.shouldAllowLinkification, let detector = Self.tellomiLinkDetector else {
                    return []
                }
                return detector.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
                    .compactMap { Range($0.range, in: text) }
            },
        )
    }

    private mutating func buildGiftBadge(messageUniqueId: String, giftBadge: OWSGiftBadge) throws -> CVComponentState {
        let profileBadgeManager = DependenciesBridge.shared.profileBadgeManager

        let (_, expirationDate) = try giftBadge.getReceiptDetails()
        let giftProfileBadge = profileBadgeManager.fetchGiftBadge(id: .gift, tx: transaction)

        self.giftBadge = GiftBadge(
            messageUniqueId: messageUniqueId,
            otherUserShortName: threadViewModel.shortName ?? threadViewModel.name,
            profileBadge: giftProfileBadge,
            expirationDate: expirationDate,
            redemptionState: giftBadge.redemptionState,
        )
        return build()
    }

    mutating func buildPoll(message: TSMessage, transaction: DBReadTransaction) throws -> CVComponentState {
        guard let poll = try DependenciesBridge.shared.pollMessageManager.buildPoll(message: message, transaction: transaction) else {
            Logger.error("Failed to build poll")
            return build()
        }

        let state = CVPollView.buildState(
            poll: poll,
            isIncoming: isIncoming,
            conversationStyle: conversationStyle,
            localAci: self.localAci,
        )

        let prevPollState: CVComponentState.Poll?
        if
            let prevRenderState = itemBuildingContext.prevRenderState,
            let prevPollInteraction = prevRenderState.items.first(
                where: {
                    $0.interactionUniqueId == message.uniqueId
                },
            ),
            let _prevPollState = prevPollInteraction.componentState.poll
        {
            prevPollState = _prevPollState
        } else {
            prevPollState = nil
        }

        // Pass the previously rendered poll so we can animate.
        self.poll = Poll(state: state, prevPollState: prevPollState?.state)

        if poll.totalVoters() > 0 {
            let title = poll.isEnded ? OWSLocalizedString(
                "POLL_BUTTON_VIEW_RESULTS",
                comment: "Button to view poll results",
            ) : OWSLocalizedString(
                "POLL_BUTTON_VIEW_VOTES",
                comment: "Button to view poll votes",
            )
            let viewVotesAction = CVMessageAction(
                title: title,
                accessibilityIdentifier: "view_votes",
                action: .didTapViewVotes(poll: poll),
            )

            bottomButtonsActions.append(viewVotesAction)
        } else {
            bottomLabel = OWSLocalizedString(
                "POLL_NO_VOTES",
                comment: "String to display when a poll has no votes",
            )
        }

        return build()
    }

    mutating func addReleaseNotesBottomButtonIfNecessary(message: TSReleaseNotesMessage, transaction: DBReadTransaction) {
        let releaseNoteStore = ReleaseNoteStore()
        let releaseNote = releaseNoteStore.existingReleaseNoteForInteractionId(message.sqliteRowId!, tx: transaction)

        if
            let releaseNote,
            let callToActionId = releaseNote.ctaId,
            let ctaText = releaseNote.ctaText
        {
            let callToAction = RemoteAnnouncementModel.Manifest.Action(fromActionId: callToActionId)

            if case .unrecognized(let actionId) = callToAction {
                Logger.debug("Ignoring unrecognized actionId \(actionId)")
                return
            }

            let action = CVMessageAction(
                title: ctaText,
                accessibilityIdentifier: "announcement_action",
                action: .didTapReleaseNotesAnnouncementAction(action: callToAction),
            )
            bottomButtonsActions.append(action)
        }
    }
}
