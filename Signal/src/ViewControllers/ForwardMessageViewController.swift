//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol ForwardMessageDelegate: AnyObject {
    func forwardMessageFlowDidComplete(items: [ForwardMessageItem], recipientThreads: [TSThread])
    func forwardMessageFlowDidCancel()
}

class ForwardMessageViewController: OWSNavigationController {

    private let pickerVC: ConversationPickerViewController

    weak var forwardMessageDelegate: ForwardMessageDelegate?

    private typealias Content = ForwardMessageContent

    private var content: Content
    private let attachmentLimits: OutgoingAttachmentLimits

    private var textMessage: String?

    private let selection = ConversationPickerSelection()
    var selectedConversations: [ConversationItem] { selection.conversations }

    private init(
        content: Content,
        attachmentLimits: OutgoingAttachmentLimits,
    ) {
        self.content = content
        self.attachmentLimits = attachmentLimits

        self.pickerVC = ConversationPickerViewController(
            selection: selection,
            overrideTitle: OWSLocalizedString(
                "FORWARD_MESSAGE_TITLE",
                comment: "Title for the 'forward message(s)' view.",
            ),
        )

        if #available(iOS 26, *) {
            self.pickerVC.backgroundStyle = .none
        }

        super.init()

        if self.content.canSendToStories {
            if self.content.canSendToNonStories {
                self.pickerVC.sectionOptions.insert(.stories)
            } else {
                self.pickerVC.sectionOptions = .storiesOnly
            }
        } else {
            self.pickerVC.shouldHideRecentConversationsTitle = true
        }

        pickerVC.pickerDelegate = self
        pickerVC.shouldBatchUpdateIdentityKeys = true

        viewControllers = [pickerVC]

        modalPresentationStyle = .formSheet
        sheetPresentationController?.detents = [.medium(), .large()]
        sheetPresentationController?.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    class func present(
        forItemViewModel itemViewModel: CVItemViewModelImpl,
        from fromViewController: UIViewController,
        delegate: ForwardMessageDelegate,
    ) {
        let attachmentLimits = OutgoingAttachmentLimits.currentLimits()
        do {
            let content: Content = try SSKEnvironment.shared.databaseStorageRef.read { tx in
                return try Content.build(itemViewModel: itemViewModel, attachmentLimits: attachmentLimits, tx: tx)
            }
            present(content: content, from: fromViewController, attachmentLimits: attachmentLimits, delegate: delegate)
        } catch {
            ForwardMessageViewController.showAlertForForwardError(error: error, forwardedInteractionCount: 1)
        }
    }

    class func present(
        forSelectionItems selectionItems: [CVSelectionItem],
        from fromViewController: UIViewController,
        delegate: ForwardMessageDelegate,
    ) {
        let attachmentLimits = OutgoingAttachmentLimits.currentLimits()
        do {
            let content: Content = try SSKEnvironment.shared.databaseStorageRef.read { tx in
                try Content.build(selectionItems: selectionItems, attachmentLimits: attachmentLimits, tx: tx)
            }
            present(content: content, from: fromViewController, attachmentLimits: attachmentLimits, delegate: delegate)
        } catch {
            ForwardMessageViewController.showAlertForForwardError(error: error, forwardedInteractionCount: selectionItems.count)
        }
    }

    class func present(
        forAttachmentStreams attachmentStreams: [ReferencedAttachmentStream],
        fromMessage message: TSMessage,
        from fromViewController: UIViewController,
        delegate: ForwardMessageDelegate,
    ) {
        let attachmentLimits = OutgoingAttachmentLimits.currentLimits()
        do {
            let attachments = try attachmentStreams.map { attachmentStream in
                try SignalAttachmentCloner.cloneAsSignalAttachment(attachment: attachmentStream, attachmentLimits: attachmentLimits)
            }
            present(
                content: ForwardMessageContent(allItems: [ForwardMessageItem(
                    interaction: message,
                    attachments: attachments,
                    tellomiShareStreams: attachmentStreams,
                )]),
                from: fromViewController,
                attachmentLimits: attachmentLimits,
                delegate: delegate,
                // Tellomi（#1259 F-2）：只有查看器用这个入口，从查看器打开的网格一律深色
                tellomiForceDarkTheme: true,
            )
        } catch let error {
            ForwardMessageViewController.showAlertForForwardError(
                error: error,
                forwardedInteractionCount: 1,
            )
        }
    }

    class func present(
        forStoryMessage storyMessage: StoryMessage,
        from fromViewController: UIViewController,
        delegate: ForwardMessageDelegate,
    ) {
        let attachmentLimits = OutgoingAttachmentLimits.currentLimits()
        var attachments: [PreviewableAttachment] = []
        var textAttachment: TextAttachment?
        switch storyMessage.attachment {
        case .media:
            let attachment: ReferencedAttachmentStream? = SSKEnvironment.shared.databaseStorageRef.read { tx in
                guard
                    let rowId = storyMessage.id,
                    let referencedStream = DependenciesBridge.shared.attachmentStore.fetchAnyReferencedAttachment(
                        for: .storyMessageMedia(storyMessageRowId: rowId),
                        tx: tx,
                    )?.asReferencedStream
                else {
                    return nil
                }
                return referencedStream
            }
            do {
                guard let attachment else {
                    throw OWSAssertionError("Missing attachment stream for forwarded story message")
                }
                let signalAttachment = try SignalAttachmentCloner.cloneAsSignalAttachment(attachment: attachment, attachmentLimits: attachmentLimits)
                attachments = [signalAttachment]
            } catch let error {
                ForwardMessageViewController.showAlertForForwardError(
                    error: error,
                    forwardedInteractionCount: 1,
                )
                return
            }
        case .text(let _textAttachment):
            textAttachment = _textAttachment
        }
        present(
            content: ForwardMessageContent(allItems: [ForwardMessageItem(attachments: attachments, textAttachment: textAttachment)]),
            from: fromViewController,
            attachmentLimits: attachmentLimits,
            delegate: delegate,
            tellomiUsesGrid: false,
        )
    }

    class func present(
        forMessageBody messageBody: MessageBody,
        from fromViewController: UIViewController,
        delegate: ForwardMessageDelegate,
    ) {
        present(
            content: ForwardMessageContent(allItems: [ForwardMessageItem(messageBody: messageBody)]),
            from: fromViewController,
            attachmentLimits: .currentLimits(),
            delegate: delegate,
        )
    }

    private class func present(
        content: Content,
        from fromViewController: UIViewController,
        attachmentLimits: OutgoingAttachmentLimits,
        delegate: ForwardMessageDelegate,
        tellomiUsesGrid: Bool = true,
        tellomiForceDarkTheme: Bool = false,
    ) {
        // Tellomi（#1259 F-1）：长按 / 多选 / 查看器 / 长文的「转发」都打开头像网格；
        // 转发「动态」仍用上游选择器（网格里没有「动态」，owner D6）。
        if tellomiUsesGrid, content.canSendToNonStories {
            presentTellomiGrid(
                content: content,
                from: fromViewController,
                attachmentLimits: attachmentLimits,
                delegate: delegate,
                forceDarkTheme: tellomiForceDarkTheme,
            )
            return
        }

        let sheet = ForwardMessageViewController(content: content, attachmentLimits: attachmentLimits)
        sheet.forwardMessageDelegate = delegate
        fromViewController.present(sheet, animated: true) {
            UIApplication.shared.hideKeyboard()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        ensureBottomFooterVisibility()

        DispatchQueue.main.async {
            self.pickerVC.updateTableMargins()
        }
    }

    private func ensureBottomFooterVisibility() {
        AssertIsOnMainThread()

        if selectedConversations.allSatisfy({ $0.outgoingMessageType == .storyMessage }) {
            pickerVC.approvalTextMode = .none
        } else {
            let placeholderText = OWSLocalizedString(
                "FORWARD_MESSAGE_TEXT_PLACEHOLDER",
                comment: "Indicates that the user can add a text message to forwarded messages.",
            )
            pickerVC.approvalTextMode = .active(placeholderText: placeholderText)
        }
    }

    private func maximizeHeight() {
        sheetPresentationController?.animateChanges {
            sheetPresentationController?.selectedDetentIdentifier = .large
        }
    }
}

extension ForwardMessageViewController: UISheetPresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        forwardMessageDelegate?.forwardMessageFlowDidCancel()
    }

    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(_ sheetPresentationController: UISheetPresentationController) {
        // Alleviates an issue where the keyboard layout guide gets positioned
        // wrong after swiping between detents.
        DispatchQueue.main.async {
            sheetPresentationController.animateChanges {
                self.pickerVC.view.setNeedsLayout()
                self.pickerVC.view.layoutIfNeeded()
            }
        }
    }
}

// MARK: - Sending

extension ForwardMessageViewController {
    func sendStep() {
        AssertIsOnMainThread()

        Task {
            await _tryToSend()
        }
    }

    private func _tryToSend() async {
        let content = self.content
        let textMessage = self.textMessage?.strippedOrNil

        let recipientConversations = self.selectedConversations
        do {
            let outgoingMessageRecipientThreads = try await self.outgoingMessageRecipientThreads(for: recipientConversations)
            try SSKEnvironment.shared.databaseStorageRef.write { transaction in
                for recipientThread in outgoingMessageRecipientThreads {
                    // We're sending a message to this thread, approve any pending message request
                    ThreadUtil.addThreadToProfileWhitelistIfEmptyOrPendingRequest(
                        recipientThread,
                        setDefaultTimerIfNecessary: true,
                        tx: transaction,
                    )
                }

                func hasRenderableContent(interaction: TSInteraction, tx: DBReadTransaction) -> Bool {
                    guard let message = interaction as? TSMessage else {
                        return false
                    }
                    return message.hasRenderableContent(tx: tx)
                }

                // Make sure the message and its content haven't been deleted (view-once
                // messages, remove delete, disappearing messages, manual deletion, etc.).
                for item in content.allItems where item.interaction != nil {
                    guard
                        let interactionId = item.interaction?.uniqueId,
                        let latestInteraction = TSInteraction.anyFetch(
                            uniqueId: interactionId,
                            transaction: transaction,
                        ),
                        hasRenderableContent(interaction: latestInteraction, tx: transaction)
                    else {
                        throw ForwardError.missingInteraction
                    }
                }
            }

            // TODO: Ideally we would enqueue all with a single write transaction.

            // Maintain order of interactions.
            let sortedItems = content.allItems.sorted { lhs, rhs in
                lhs.interaction?.sortId ?? 0 < rhs.interaction?.sortId ?? 0
            }
            // The user may have added an additional text message to the forward.
            // Tellomi（#1259 F-7）：它作为单独一条文字先于转发内容发出（同 Telegram Android；上游放在最后）。
            for step in Self.tellomiForwardSteps(items: sortedItems, comment: textMessage) {
                switch step {
                case .comment(let text):
                    let messageBody = MessageBody(text: text, ranges: .empty)
                    await enqueueMessageViaThreadUtil(toRecipientThreads: outgoingMessageRecipientThreads) { recipientThread in
                        self.send(body: messageBody, recipientThread: recipientThread)
                    }
                case .item(let item):
                    // _Enqueue_ each item serially.
                    try await self.send(item: item, toOutgoingMessageRecipientThreads: outgoingMessageRecipientThreads)
                }
            }

            self.forwardMessageDelegate?.forwardMessageFlowDidComplete(
                items: content.allItems,
                recipientThreads: outgoingMessageRecipientThreads,
            )
        } catch {
            owsFailDebug("Error: \(error)")

            Self.showAlertForForwardError(error: error, forwardedInteractionCount: content.allItems.count)
        }
    }

    private func send(item: ForwardMessageItem, toOutgoingMessageRecipientThreads outgoingMessageRecipientThreads: [TSThread]) async throws {
        if let stickerMetadata = item.stickerMetadata {
            let stickerInfo = stickerMetadata.stickerInfo
            if StickerManager.isStickerInstalled(stickerInfo: stickerInfo) {
                await enqueueMessageViaThreadUtil(toRecipientThreads: outgoingMessageRecipientThreads) { recipientThread in
                    self.send(installedSticker: stickerInfo, thread: recipientThread)
                }
            } else {
                guard let stickerAttachment = item.stickerAttachment else {
                    throw OWSAssertionError("Missing stickerAttachment.")
                }
                let stickerData = try stickerAttachment.decryptedRawData()
                await enqueueMessageViaThreadUtil(toRecipientThreads: outgoingMessageRecipientThreads) { recipientThread in
                    self.send(uninstalledSticker: stickerMetadata, stickerData: stickerData, thread: recipientThread)
                }
            }
        } else if let contactShare = item.contactShare {
            await enqueueMessageViaThreadUtil(toRecipientThreads: outgoingMessageRecipientThreads) { recipientThread in
                self.send(contactShare: contactShare.copyForResending(), thread: recipientThread)
            }
        } else if !item.attachments.isEmpty {
            // TODO: What about link previews in this case?
            let conversations = selectedConversations
            _ = try await AttachmentMultisend.enqueueApprovedMedia(
                conversations: conversations,
                approvedMessageBody: item.messageBody,
                approvedAttachments: ApprovedAttachments(nonViewOnceAttachments: item.attachments, imageQuality: .high),
                attachmentLimits: attachmentLimits,
            )
        } else if let textAttachment = item.textAttachment {
            // TODO: we want to reuse the uploaded link preview image attachment instead of re-uploading
            // if the original was sent recently (if not the image could be stale)
            _ = try await AttachmentMultisend.enqueueTextAttachment(
                textAttachment.asUnsentAttachment(),
                to: selectedConversations,
            )
        } else if let messageBody = item.messageBody {
            let linkPreviewDraft = item.linkPreviewDraft
            await enqueueMessageViaThreadUtil(toRecipientThreads: outgoingMessageRecipientThreads) { recipientThread in
                self.send(body: messageBody, linkPreviewDraft: linkPreviewDraft, recipientThread: recipientThread)
            }

            // Send the text message to any selected story recipients as a text story
            // with default styling.
            _ = try await StorySharing.enqueueTextStory(with: messageBody, linkPreviewDraft: linkPreviewDraft, to: selectedConversations)
        } else {
            throw ForwardError.invalidInteraction
        }
    }

    private func send(body: MessageBody, linkPreviewDraft: OWSLinkPreviewDraft? = nil, recipientThread: TSThread) {
        let body = SSKEnvironment.shared.databaseStorageRef.read { transaction in
            return body.forForwarding(to: recipientThread, transaction: transaction).asMessageBodyForForwarding()
        }
        ThreadUtil.enqueueMessage(
            body: body,
            thread: recipientThread,
            linkPreviewDraft: linkPreviewDraft,
        )
    }

    private func send(contactShare: ContactShareDraft, thread: TSThread) {
        ThreadUtil.enqueueMessage(withContactShare: contactShare, thread: thread)
    }

    private func send(installedSticker stickerInfo: StickerInfo, thread: TSThread) {
        ThreadUtil.enqueueMessage(withInstalledSticker: stickerInfo, thread: thread)
    }

    private func send(uninstalledSticker stickerMetadata: any StickerMetadata, stickerData: Data, thread: TSThread) {
        ThreadUtil.enqueueMessage(withUninstalledSticker: stickerMetadata, stickerData: stickerData, thread: thread)
    }

    private func enqueueMessageViaThreadUtil(
        toRecipientThreads recipientThreads: [TSThread],
        enqueueBlock: (TSThread) -> Void,
    ) async {
        for recipientThread in recipientThreads {
            enqueueBlock(recipientThread)
        }
        // This should be changed in the future, but waiting on this queue will
        // ensure that `enqueueBlock` (the prior line) has finished its work.
        try? await ThreadUtil.enqueueSendQueue.enqueue(operation: {}).value
    }

    private func outgoingMessageRecipientThreads(for conversationItems: [ConversationItem]) async throws -> [TSThread] {
        guard conversationItems.count > 0 else {
            throw OWSAssertionError("No recipients.")
        }

        let databaseStorage = SSKEnvironment.shared.databaseStorageRef
        return try await databaseStorage.awaitableWrite { transaction in
            try conversationItems.lazy.filter { $0.outgoingMessageType == .message }.map {
                guard let thread = $0.getOrCreateThread(transaction: transaction) else {
                    throw ForwardError.missingThread
                }
                return thread
            }
        }
    }
}

// MARK: -

extension ForwardMessageViewController: ConversationPickerDelegate {
    func conversationPickerSelectionDidChange(_ conversationPickerViewController: ConversationPickerViewController) {
        ensureBottomFooterVisibility()
    }

    func conversationPickerDidCompleteSelection(_ conversationPickerViewController: ConversationPickerViewController) {
        self.textMessage = conversationPickerViewController.textInput?.strippedOrNil

        sendStep()
    }

    func conversationPickerCanCancel(_ conversationPickerViewController: ConversationPickerViewController) -> Bool {
        true
    }

    func conversationPickerDidCancel(_ conversationPickerViewController: ConversationPickerViewController) {
        forwardMessageDelegate?.forwardMessageFlowDidCancel()
    }

    func approvalMode(_ conversationPickerViewController: ConversationPickerViewController) -> ApprovalMode {
        .send
    }

    func conversationPickerDidBeginEditingText() {
        AssertIsOnMainThread()

        maximizeHeight()
    }

    func conversationPickerSearchBarActiveDidChange(_ conversationPickerViewController: ConversationPickerViewController) {
        maximizeHeight()
    }
}

// MARK: -

extension ForwardMessageViewController {
    static func finalizeForward(
        items: [ForwardMessageItem],
        recipientThreads: [TSThread],
        fromViewController: UIViewController,
    ) {
        // Tellomi（#1259 F-8）：成功轻震一下，提示写明转给了谁；只转到「我的收藏」时点提示条打开它
        if tellomiFinalizeForward(recipientThreads: recipientThreads, fromViewController: fromViewController) {
            return
        }

        let toast: String
        if items.count > 1 {
            toast = OWSLocalizedString(
                "FORWARD_MESSAGE_MESSAGES_SENT_N",
                comment: "Indicates that multiple messages were forwarded.",
            )
        } else {
            toast = OWSLocalizedString(
                "FORWARD_MESSAGE_MESSAGES_SENT_1",
                comment: "Indicates that a single message was forwarded.",
            )
        }
        if let cvc = fromViewController as? ConversationViewController {
            cvc.presentToastCVC(toast, image: .check)
        } else {
            fromViewController.presentToast(text: toast, image: .check)
        }
    }
}

// MARK: -

enum ForwardError: Error {
    case missingInteraction
    case missingThread
    case invalidInteraction
}

// MARK: -

extension ForwardMessageViewController {

    static func showAlertForForwardError(
        error: Error,
        forwardedInteractionCount: Int,
    ) {
        let genericErrorMessage = (
            forwardedInteractionCount > 1
                ? OWSLocalizedString(
                    "ERROR_COULD_NOT_FORWARD_MESSAGES_N",
                    comment: "Error indicating that messages could not be forwarded.",
                )
                : OWSLocalizedString(
                    "ERROR_COULD_NOT_FORWARD_MESSAGES_1",
                    comment: "Error indicating that a message could not be forwarded.",
                ),
        )

        guard let forwardError = error as? ForwardError else {
            owsFailDebug("Error: \(error).")
            OWSActionSheets.showErrorAlert(message: genericErrorMessage)
            return
        }

        switch forwardError {
        case .missingInteraction:
            let message = (
                forwardedInteractionCount > 1
                    ? OWSLocalizedString(
                        "ERROR_COULD_NOT_FORWARD_MESSAGES_MISSING_N",
                        comment: "Error indicating that messages could not be forwarded.",
                    )
                    : OWSLocalizedString(
                        "ERROR_COULD_NOT_FORWARD_MESSAGES_MISSING_1",
                        comment: "Error indicating that a message could not be forwarded.",
                    ),
            )
            OWSActionSheets.showErrorAlert(message: message)
        case .missingThread, .invalidInteraction:
            owsFailDebug("Error: \(error).")

            OWSActionSheets.showErrorAlert(message: genericErrorMessage)
        }
    }
}

// MARK: -

struct ForwardMessageItem {
    let interaction: TSInteraction?

    let attachments: [PreviewableAttachment]
    let contactShare: ContactShareViewModel?
    let messageBody: MessageBody?
    let linkPreviewDraft: OWSLinkPreviewDraft?
    let stickerMetadata: (any StickerMetadata)?
    let stickerAttachment: AttachmentStream?
    let textAttachment: TextAttachment?
    /// Tellomi（#1259 F-10）：本机的原附件，「分享到其他 App」按原图 / 原文件交给系统分享面板
    let tellomiShareStreams: [ReferencedAttachmentStream]

    fileprivate init(
        interaction: TSInteraction? = nil,
        attachments: [PreviewableAttachment] = [],
        contactShare: ContactShareViewModel? = nil,
        messageBody: MessageBody? = nil,
        linkPreviewDraft: OWSLinkPreviewDraft? = nil,
        stickerMetadata: (any StickerMetadata)? = nil,
        stickerAttachment: AttachmentStream? = nil,
        textAttachment: TextAttachment? = nil,
        tellomiShareStreams: [ReferencedAttachmentStream] = [],
    ) {
        self.interaction = interaction
        self.attachments = attachments
        self.contactShare = contactShare
        self.messageBody = messageBody
        self.linkPreviewDraft = linkPreviewDraft
        self.stickerMetadata = stickerMetadata
        self.stickerAttachment = stickerAttachment
        self.textAttachment = textAttachment
        self.tellomiShareStreams = tellomiShareStreams
    }

    fileprivate static func build(
        interaction: TSInteraction,
        componentState: CVComponentState,
        selectionType: CVSelectionType,
        attachmentLimits: OutgoingAttachmentLimits,
        transaction: DBReadTransaction,
    ) throws -> Self {
        let shouldHaveText = (selectionType == .allContent || selectionType == .secondaryContent)
        let shouldHaveAttachments = (selectionType == .allContent || selectionType == .primaryContent)

        guard shouldHaveText || shouldHaveAttachments else {
            throw ForwardError.invalidInteraction
        }

        var messageBody: MessageBody?
        var linkPreviewDraft: OWSLinkPreviewDraft?
        if
            shouldHaveText,
            let displayableBodyText = componentState.displayableBodyText,
            !displayableBodyText.fullTextValue.isEmpty
        {
            switch displayableBodyText.fullTextValue {
            case .text(let text):
                messageBody = MessageBody(text: text, ranges: .empty)
            case .attributedText(let text):
                messageBody = MessageBody(text: text.string, ranges: .empty)
            case .messageBody(let hydratedBody):
                messageBody = hydratedBody.asMessageBodyForForwarding(preservingAllMentions: true)
            }

            if let linkPreview = componentState.linkPreviewModel, let message = interaction as? TSMessage {
                linkPreviewDraft = Self.tryToCloneLinkPreview(
                    linkPreview: linkPreview,
                    parentMessage: message,
                    transaction: transaction,
                )
            }
        }

        var attachments: [PreviewableAttachment] = []
        var contactShare: ContactShareViewModel?
        var stickerMetadata: (any StickerMetadata)?
        var stickerAttachment: AttachmentStream?
        var tellomiShareStreams: [ReferencedAttachmentStream] = []
        if shouldHaveAttachments {
            if let oldContactShare = componentState.contactShareModel {
                contactShare = oldContactShare.copyForRendering()
            }

            var attachmentStreams = [ReferencedAttachmentStream]()
            attachmentStreams.append(contentsOf: componentState.bodyMediaAttachmentStreams)
            if let attachmentStream = componentState.audioAttachmentStream {
                attachmentStreams.append(attachmentStream)
            }
            if let attachmentStream = componentState.genericAttachmentStream {
                attachmentStreams.append(attachmentStream)
            }

            attachments = try attachmentStreams.map { attachmentStream in
                try SignalAttachmentCloner.cloneAsSignalAttachment(attachment: attachmentStream, attachmentLimits: attachmentLimits)
            }
            tellomiShareStreams = attachmentStreams

            stickerMetadata = componentState.stickerMetadata
            stickerAttachment = (stickerMetadata != nil) ? componentState.stickerAttachment : nil
        }

        let isEmpty: Bool = (
            attachments.isEmpty
                && contactShare == nil
                && messageBody == nil
                && stickerMetadata == nil,
        )
        guard !isEmpty else {
            throw ForwardError.invalidInteraction
        }

        return Self(
            interaction: interaction,
            attachments: attachments,
            contactShare: contactShare,
            messageBody: messageBody,
            linkPreviewDraft: linkPreviewDraft,
            stickerMetadata: stickerMetadata,
            stickerAttachment: stickerAttachment,
            tellomiShareStreams: tellomiShareStreams,
        )
    }

    private static func tryToCloneLinkPreview(
        linkPreview: OWSLinkPreview,
        parentMessage: TSMessage,
        transaction: DBReadTransaction,
    ) -> OWSLinkPreviewDraft? {
        guard
            let urlString = linkPreview.urlString,
            let url = URL(string: urlString)
        else {
            owsFailDebug("Missing or invalid urlString.")
            return nil
        }
        struct LinkPreviewImage {
            let imageData: Data
            let mimetype: String

            static func load(
                attachmentId: Attachment.IDType,
                transaction: DBReadTransaction,
            ) -> LinkPreviewImage? {
                guard
                    let attachment = DependenciesBridge.shared.attachmentStore
                        .fetch(id: attachmentId, tx: transaction)?
                        .asStream()
                else {
                    owsFailDebug("Missing attachment.")
                    return nil
                }
                guard let mimeType = attachment.mimeType.nilIfEmpty else {
                    owsFailDebug("Missing mimeType.")
                    return nil
                }
                do {
                    let imageData = try attachment.decryptedRawData()
                    return LinkPreviewImage(imageData: imageData, mimetype: mimeType)
                } catch {
                    owsFailDebug("Error: \(error).")
                    return nil
                }
            }
        }
        var linkPreviewImage: LinkPreviewImage?
        if
            let parentMessageRowId = parentMessage.sqliteRowId,
            let imageAttachmentId = DependenciesBridge.shared.attachmentStore.fetchAnyReference(
                owner: .messageLinkPreview(messageRowId: parentMessageRowId),
                tx: transaction,
            )?.attachmentRowId,
            let image = LinkPreviewImage.load(
                attachmentId: imageAttachmentId,
                transaction: transaction,
            )
        {
            linkPreviewImage = image
        }
        return OWSLinkPreviewDraft(
            url: url,
            title: linkPreview.title,
            imageData: linkPreviewImage?.imageData,
            imageMimeType: linkPreviewImage?.mimetype,
            previewDescription: linkPreview.previewDescription,
            date: linkPreview.date,
            isForwarded: true,
            rich: linkPreview.rich, // Tellomi（ADR-0063 §7.4）：转发时 rich 原样带过去
        )
    }
}

// MARK: -

private struct ForwardMessageContent {
    let allItems: [ForwardMessageItem]

    var canSendToStories: Bool {
        return allItems.allSatisfy { item in
            if !item.attachments.isEmpty {
                return item.attachments.allSatisfy({ $0.isImage || $0.isVideo })
            } else if item.textAttachment != nil {
                return true
            } else if item.messageBody != nil {
                return true
            } else {
                return false
            }
        }
    }

    var canSendToNonStories: Bool {
        return allItems.allSatisfy { $0.textAttachment == nil }
    }

    static func build(
        itemViewModel: CVItemViewModelImpl,
        attachmentLimits: OutgoingAttachmentLimits,
        tx: DBReadTransaction,
    ) throws -> Self {
        return Self(allItems: [try ForwardMessageItem.build(
            interaction: itemViewModel.interaction,
            componentState: itemViewModel.renderItem.componentState,
            selectionType: .allContent,
            attachmentLimits: attachmentLimits,
            transaction: tx,
        )])
    }

    static func build(
        selectionItems: [CVSelectionItem],
        attachmentLimits: OutgoingAttachmentLimits,
        tx: DBReadTransaction,
    ) throws -> Self {
        let items = try selectionItems.map { selectionItem throws -> ForwardMessageItem in
            let interactionId = selectionItem.interactionId
            guard let interaction = TSInteraction.fetchViaCache(uniqueId: interactionId, transaction: tx) else {
                throw ForwardError.missingInteraction
            }
            let componentState = try buildComponentState(interaction: interaction, tx: tx)
            return try ForwardMessageItem.build(
                interaction: interaction,
                componentState: componentState,
                selectionType: selectionItem.selectionType,
                attachmentLimits: attachmentLimits,
                transaction: tx,
            )
        }
        return Self(allItems: items)
    }

    private static func buildComponentState(
        interaction: TSInteraction,
        tx: DBReadTransaction,
    ) throws(ForwardError) -> CVComponentState {
        guard
            let componentState = CVLoader.buildStandaloneComponentState(
                interaction: interaction,
                spoilerState: SpoilerRenderState(), // Nothing revealed, doesn't matter.
                transaction: tx,
            )
        else {
            throw .invalidInteraction
        }
        return componentState
    }
}

// MARK: - Tellomi（tellomi/tellomi#1174）

extension ForwardMessageViewController {

    /// 长按「收藏」：不开转发面板，照转发的内容（同一套检查与发送）直接发到「我的收藏」。发出去了回调 true。
    static func tellomiSaveToSavedMessages(
        itemViewModel: CVItemViewModelImpl,
        completion: @escaping @MainActor (Bool) -> Void,
    ) {
        AssertIsOnMainThread()

        let attachmentLimits = OutgoingAttachmentLimits.currentLimits()
        let content: Content
        let savedMessages: ConversationItem
        do {
            let built: (Content, ConversationItem?) = try SSKEnvironment.shared.databaseStorageRef.read { tx in
                return (
                    try Content.build(itemViewModel: itemViewModel, attachmentLimits: attachmentLimits, tx: tx),
                    TellomiSavedMessagesConversationItem.build(tx: tx),
                )
            }
            guard let item = built.1 else {
                completion(false)
                return
            }
            content = built.0
            savedMessages = item
        } catch {
            ForwardMessageViewController.showAlertForForwardError(error: error, forwardedInteractionCount: 1)
            completion(false)
            return
        }

        let forwardController = ForwardMessageViewController(content: content, attachmentLimits: attachmentLimits)
        forwardController.selection.add(savedMessages)
        let delegate = TellomiSaveToSavedMessagesDelegate()
        forwardController.forwardMessageDelegate = delegate

        Task { @MainActor in
            await forwardController._tryToSend()
            // forwardMessageDelegate 是 weak，发完之前靠这里留住代理
            completion(delegate.didComplete)
        }
    }
}

private final class TellomiSaveToSavedMessagesDelegate: ForwardMessageDelegate {
    private(set) var didComplete = false

    func forwardMessageFlowDidComplete(items: [ForwardMessageItem], recipientThreads: [TSThread]) {
        didComplete = true
    }

    func forwardMessageFlowDidCancel() {}
}

// MARK: - Tellomi（tellomi/tellomi#1259）转发网格

extension ForwardMessageViewController {

    /// 打开转发网格。网格只管选聊天和写附言；点「发送」后照上游同一套发送（`_tryToSend`：检查消息还在、建会话、按原顺序发），
    /// 发完仍回调原来的 `ForwardMessageDelegate`（由它收起面板、调 `finalizeForward` 提示）。
    private static func presentTellomiGrid(
        content: Content,
        from fromViewController: UIViewController,
        attachmentLimits: OutgoingAttachmentLimits,
        delegate: ForwardMessageDelegate,
        forceDarkTheme: Bool,
    ) {
        weak let weakDelegate = delegate
        // 打开网格的页面可能先不在了（例如长文页：消息被删，会话页把它弹出去，它一释放，delegate 就空了）。
        // 没人来收，网格就得自己关：它全屏透明、盖在最上面，不关就吞掉所有触摸。
        let gridReference = TellomiForwardGridReference()
        let send: @MainActor ([ConversationItem], String?) async -> Bool = { items, comment in
            let didSend = await tellomiSend(content: content, attachmentLimits: attachmentLimits, items: items, comment: comment, delegate: weakDelegate)
            if didSend, weakDelegate == nil {
                gridReference.grid?.dismiss(animated: true)
            }
            return didSend
        }
        let shareItems = TellomiForwardShareItems(content: content)
        var share: (@MainActor (UIView) -> Void)?
        if !shareItems.isEmpty {
            share = { sourceView in
                shareItems.present(sender: sourceView)
            }
        }
        let cancel: @MainActor () -> Void = {
            if let delegate = weakDelegate {
                delegate.forwardMessageFlowDidCancel()
            } else {
                gridReference.grid?.dismiss(animated: true)
            }
        }
        let grid = TellomiForwardGridViewController(
            forceDarkTheme: forceDarkTheme,
            actions: TellomiForwardGridViewController.Actions(send: send, share: share, cancel: cancel),
        )
        gridReference.grid = grid
        // 新功能提示卡「转发给多个聊天」（docs/product/specs/whats-new-cards.md），只在第一次打开时弹。
        grid.onFirstAppear = { grid in
            TellomiFeatureIntro.presentFirstDue([.forwardGrid], from: grid)
        }
        fromViewController.present(grid, animated: true) {
            UIApplication.shared.hideKeyboard()
        }
    }

    /// 网格点「发送」：不展示，只借一个转发页的发送流程（同 #1174 长按「收藏」）。发出去了返回 true。
    @MainActor
    private static func tellomiSend(
        content: Content,
        attachmentLimits: OutgoingAttachmentLimits,
        items: [ConversationItem],
        comment: String?,
        delegate: ForwardMessageDelegate?,
    ) async -> Bool {
        let engine = ForwardMessageViewController(content: content, attachmentLimits: attachmentLimits)
        for item in items {
            engine.selection.add(item)
        }
        engine.textMessage = comment
        let relay = TellomiForwardGridRelay(delegate: delegate)
        engine.forwardMessageDelegate = relay
        await engine._tryToSend()
        // forwardMessageDelegate 是 weak，发完之前靠这里留住 relay
        return relay.didComplete
    }

    /// 发送的先后（F-7）：附言（有的话）作为单独一条文字在最前，之后是按原顺序排好的转发内容。
    enum TellomiForwardStep<Item> {
        case comment(String)
        case item(Item)
    }

    static func tellomiForwardSteps<Item>(items: [Item], comment: String?) -> [TellomiForwardStep<Item>] {
        var steps: [TellomiForwardStep<Item>] = []
        if let comment {
            steps.append(.comment(comment))
        }
        steps.append(contentsOf: items.map { .item($0) })
        return steps
    }

    /// 发完的提示（F-8）。能按收件会话写出名字就提示并返回 true；否则（例如只转给了「动态」）走上游的提示。
    fileprivate static func tellomiFinalizeForward(
        recipientThreads: [TSThread],
        fromViewController: UIViewController,
    ) -> Bool {
        let recipients: [TellomiForwardedRecipient] = SSKEnvironment.shared.databaseStorageRef.read { tx in
            recipientThreads.map { TellomiForwardedRecipient(thread: $0, tx: tx) }
        }
        guard let toast = TellomiForwardedToast(recipients: recipients) else {
            return false
        }

        UINotificationFeedbackGenerator().notificationOccurred(.success)

        let toastController = ToastController(text: toast.text)
        toastController.tellomiBoldTexts = toast.boldTexts
        if toast.opensSavedMessages {
            toastController.tellomiOnTap = {
                let thread = SSKEnvironment.shared.databaseStorageRef.write { tx in
                    TellomiSavedMessages.list(tx: tx)
                }
                guard let thread else {
                    return
                }
                SignalApp.shared.presentConversationForThread(threadUniqueId: thread.uniqueId, animated: true)
            }
        }
        let bottomInset: CGFloat
        if let cvc = fromViewController as? ConversationViewController {
            bottomInset = 10 + cvc.collectionView.contentInset.bottom + cvc.view.layoutMargins.bottom
        } else {
            bottomInset = fromViewController.view.safeAreaInsets.bottom + 8
        }
        toastController.presentToastView(from: .bottom, of: fromViewController.view, inset: bottomInset, dismissAfter: .seconds(3))
        return true
    }
}

/// 发完提示里的一个收件会话
struct TellomiForwardedRecipient: Equatable {
    let name: String
    let isSavedMessages: Bool

    init(name: String, isSavedMessages: Bool) {
        self.name = name
        self.isSavedMessages = isSavedMessages
    }

    init(thread: TSThread, tx: DBReadTransaction) {
        switch thread {
        case let contactThread as TSContactThread where contactThread.contactAddress.isLocalAddress:
            self.init(name: MessageStrings.noteToSelf, isSavedMessages: true)
        case let contactThread as TSContactThread:
            let name = SSKEnvironment.shared.contactManagerRef.displayName(for: contactThread.contactAddress, tx: tx).resolvedValue()
            self.init(name: name, isSavedMessages: false)
        case let groupThread as TSGroupThread:
            self.init(name: groupThread.groupNameOrDefault, isSavedMessages: false)
        default:
            self.init(name: "", isSavedMessages: false)
        }
    }
}

/// 「已转发给 **小林**」/「已转发给 **小林** 和 **小王**」/「已转发给 **小林** 等 3 个聊天」/「已转发到 **我的收藏**」（F-8）
struct TellomiForwardedToast: Equatable {
    let text: String
    let boldTexts: [String]
    let opensSavedMessages: Bool

    init?(recipients: [TellomiForwardedRecipient]) {
        guard let first = recipients.first else {
            return nil
        }
        switch recipients.count {
        case 1 where first.isSavedMessages:
            text = String(format: Self.savedFormat, first.name)
            boldTexts = [first.name]
            opensSavedMessages = true
        case 1:
            text = String(format: Self.oneFormat, first.name)
            boldTexts = [first.name]
            opensSavedMessages = false
        case 2:
            let second = recipients[1]
            text = String(format: Self.twoFormat, first.name, second.name)
            boldTexts = [first.name, second.name]
            opensSavedMessages = false
        default:
            text = String(format: Self.manyFormat, first.name, recipients.count)
            boldTexts = [first.name]
            opensSavedMessages = false
        }
    }

    private static var oneFormat: String {
        OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SENT_TO_ONE_%@", comment: "Tellomi: toast after forwarding to one chat. Embeds {{chat name}}.")
    }

    private static var twoFormat: String {
        OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SENT_TO_TWO_%@_%@", comment: "Tellomi: toast after forwarding to two chats. Embeds {{first chat name}} and {{second chat name}}.")
    }

    private static var manyFormat: String {
        OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SENT_TO_MANY_%@_%d", comment: "Tellomi: toast after forwarding to three or more chats. Embeds {{first chat name}} and {{total number of chats}}.")
    }

    private static var savedFormat: String {
        OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SENT_TO_SAVED_%@", comment: "Tellomi: toast after forwarding to Saved Messages only. Embeds {{Saved Messages}}.")
    }
}

/// 「分享到其他 App」（F-10）：图片 / 视频 / 文件 / 语音按本机原文件，文字消息按文字，交给系统分享面板。
private struct TellomiForwardShareItems {
    let streams: [ReferencedAttachmentStream]
    let texts: [String]

    init(content: ForwardMessageContent) {
        streams = content.allItems.flatMap(\.tellomiShareStreams)
        texts = content.allItems
            .filter { $0.tellomiShareStreams.isEmpty && $0.attachments.isEmpty }
            .compactMap { $0.messageBody?.text.nilIfEmpty }
    }

    var isEmpty: Bool { streams.isEmpty && texts.isEmpty }

    func present(sender: UIView) {
        var activityItems: [Any] = []
        if !streams.isEmpty {
            do {
                activityItems.append(contentsOf: try streams.asShareableAttachments())
            } catch {
                owsFailDebug("Could not share attachments: \(error)")
            }
        }
        activityItems.append(contentsOf: texts)
        guard !activityItems.isEmpty else {
            return
        }
        AttachmentSharing.showShareUIForActivityItems(activityItems, sender: sender)
    }
}

/// 网格的弱引用，给它自己的几个回调用：回调要先有，网格才建得出来。
@MainActor
private final class TellomiForwardGridReference {
    weak var grid: UIViewController?
}

/// 把借来的发送流程的回调转给原来的代理，同时记下有没有发出去
private final class TellomiForwardGridRelay: ForwardMessageDelegate {
    private weak var delegate: ForwardMessageDelegate?
    private(set) var didComplete = false

    init(delegate: ForwardMessageDelegate?) {
        self.delegate = delegate
    }

    func forwardMessageFlowDidComplete(items: [ForwardMessageItem], recipientThreads: [TSThread]) {
        didComplete = true
        delegate?.forwardMessageFlowDidComplete(items: items, recipientThreads: recipientThreads)
    }

    func forwardMessageFlowDidCancel() {
        delegate?.forwardMessageFlowDidCancel()
    }
}
