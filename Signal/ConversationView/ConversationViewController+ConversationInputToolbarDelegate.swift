//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AudioToolbox
import CoreServices
import LibSignalClient
public import SignalServiceKit
public import SignalUI
import UniformTypeIdentifiers

extension ConversationViewController: ConversationInputToolbarDelegate {

    public func isBlockedConversation() -> Bool {
        threadViewModel.isBlocked
    }

    public func isGroup() -> Bool {
        isGroupConversation
    }

    public func viewForKeyboardLayoutGuide() -> UIView {
        return view
    }

    public func viewForSuggestedStickersPanel() -> UIView { view }

    public func sendButtonPressed() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard let inputToolbar else {
            return
        }

        inputToolbar.acceptAutocorrectSuggestion()

        // Guards against hardware-keyboard Return keys, which circumvent the Send button.
        guard inputToolbar.canSendTextMessage else {
            return
        }

        guard let messageBody = inputToolbar.messageBodyForSending else {
            return
        }

        tryToSendTextMessage(messageBody, updateKeyboardState: true)
    }

    public func messageWasSent() {
        AssertIsOnMainThread()

        self.lastMessageSentDate = Date()

        loadCoordinator.clearUnreadMessagesIndicator()
        inputToolbar?.quotedReplyDraft = nil

        let shouldPlayMessageSentSound = DependenciesBridge.shared.db.read { tx in
            let notificationPreferencesManager = DependenciesBridge.shared.notificationPreferencesManager
            return notificationPreferencesManager.playSoundInForeground(tx: tx)
                && notificationPreferencesManager.isMessageSentSoundEnabled(tx: tx)
        }
        if
            shouldPlayMessageSentSound,
            let soundId = Sounds.systemSoundIDForSound(.standard(.messageSent), quiet: true)
        {
            AudioServicesPlaySystemSound(soundId)
        }
        SSKEnvironment.shared.typingIndicatorsRef.didSendOutgoingMessage(inThread: thread)
    }

    private func tryToSendTextMessage(_ messageBody: MessageBody, updateKeyboardState: Bool) {
        tryToSendTextMessage(
            messageBody,
            updateKeyboardState: updateKeyboardState,
            untrustedThreshold: Date().addingTimeInterval(-OWSIdentityManagerImpl.Constants.defaultUntrustedInterval),
        )
    }

    private func tryToSendTextMessage(_ messageBody: MessageBody, updateKeyboardState: Bool, untrustedThreshold: Date) {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("View not yet ready.")
            return
        }
        guard let inputToolbar else {
            return
        }

        guard !isBlockedConversation() else {
            showUnblockConversationUI { [weak self] isBlocked in
                if !isBlocked {
                    self?.tryToSendTextMessage(messageBody, updateKeyboardState: false, untrustedThreshold: untrustedThreshold)
                }
            }
            return
        }

        let newUntrustedThreshold = Date()
        let didShowSNAlert = showSafetyNumberConfirmationIfNecessary(
            confirmationText: SafetyNumberStrings.confirmSendButton,
            untrustedThreshold: untrustedThreshold,
        ) { [weak self] didConfirmIdentity in
            guard let self else { return }
            if didConfirmIdentity {
                self.tryToSendTextMessage(messageBody, updateKeyboardState: false, untrustedThreshold: newUntrustedThreshold)
            }
        }
        if didShowSNAlert {
            return
        }

        guard !messageBody.text.isEmpty else {
            return
        }

        let didAddToProfileWhitelist = ThreadUtil.addThreadToProfileWhitelistIfEmptyOrPendingRequestAndSetDefaultTimerWithSneakyTransaction(thread)

        let editValidationError: EditSendValidationError? = SSKEnvironment.shared.databaseStorageRef.read { transaction in
            if let editTarget = inputToolbar.editTarget {
                return context.editManager.validateCanSendEdit(
                    targetMessageTimestamp: editTarget.timestamp,
                    thread: self.thread,
                    tx: transaction,
                )
            }
            return nil
        }

        if let error = editValidationError {
            OWSActionSheets.showActionSheet(message: error.localizedDescription)
            return
        }

        if let editTarget = inputToolbar.editTarget {
            ThreadUtil.enqueueEditMessage(
                body: messageBody,
                thread: self.thread,
                // If we have _any_ quoted reply populated, keep the existing quoted reply.
                // If its cleared, "change" it to nothing (clear it).
                quotedReplyEdit: inputToolbar.quotedReplyDraft == nil ? .change(()) : .keep,
                linkPreviewDraft: inputToolbar.linkPreviewDraft,
                editTarget: editTarget,
                persistenceCompletionHandler: {
                    AssertIsOnMainThread()
                    self.loadCoordinator.enqueueReload()
                },
            )
        } else {
            ThreadUtil.enqueueMessage(
                body: messageBody,
                thread: self.thread,
                quotedReplyDraft: inputToolbar.quotedReplyDraft,
                linkPreviewDraft: inputToolbar.linkPreviewDraft,
                persistenceCompletionHandler: {
                    AssertIsOnMainThread()
                    self.loadCoordinator.enqueueReload()
                },
            )
        }

        messageWasSent()

        // Clearing the text message is a key part of the send animation.
        // It takes 10-15ms, but we do it inline rather than dispatch async
        // since the send can't feel "complete" without it.
        inputToolbar.clearTextMessage(animated: true)

        let thread = self.thread
        SSKEnvironment.shared.databaseStorageRef.asyncWrite { transaction in
            // Reload a fresh instance of the thread model; our models are not
            // thread-safe, so it wouldn't be safe to update the model in an
            // async write.
            guard let thread = TSThread.fetchViaCache(uniqueId: thread.uniqueId, transaction: transaction) else {
                owsFailDebug("Missing thread.")
                return
            }
            thread.updateWithDraft(
                draftMessageBody: nil,
                replyInfo: nil,
                editTargetTimestamp: nil,
                transaction: transaction,
            )
        }

        if didAddToProfileWhitelist {
            ensureBannerState()
        }

        NotificationCenter.default.post(name: ChatListViewController.clearSearch, object: nil)
    }

    public func sendSticker(_ stickerInfo: StickerInfo) {
        AssertIsOnMainThread()

        ImpactHapticFeedback.impactOccurred(style: .light)

        ThreadUtil.enqueueMessage(withInstalledSticker: stickerInfo, thread: thread)
        messageWasSent()
    }

    public func presentManageStickersView() {
        AssertIsOnMainThread()

        let manageStickersView = ManageStickersViewController()
        let navigationController = OWSNavigationController(rootViewController: manageStickersView)
        presentFormSheet(navigationController, animated: true)
    }

    public func updateToolbarHeight() {
        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard inputToolbar != nil else {
            return
        }
        updateContentInsets()
    }

    public func voiceMemoGestureDidStart() {
        AssertIsOnMainThread()
        Logger.info("")

        let kIgnoreMessageSendDoubleTapDurationSeconds: TimeInterval = 2.0
        if
            let lastMessageSentDate = self.lastMessageSentDate,
            abs(lastMessageSentDate.timeIntervalSinceNow) < kIgnoreMessageSendDoubleTapDurationSeconds
        {
            // If users double-taps the message send button, the second tap can look like a
            // very short voice message gesture.  We want to ignore such gestures.
            cancelRecordingVoiceMessage()
            return
        }

        checkPermissionsAndStartRecordingVoiceMessage()
    }

    public func voiceMemoGestureDidComplete() {
        AssertIsOnMainThread()
        Logger.info("")

        finishRecordingVoiceMessage(sendImmediately: true)
    }

    public func voiceMemoGestureDidLock() {
        AssertIsOnMainThread()
        Logger.info("")

        inputToolbar?.lockVoiceMemoUI()
    }

    public func voiceMemoGestureDidCancel() {
        AssertIsOnMainThread()
        Logger.info("")

        cancelRecordingVoiceMessage()
    }

    public func voiceMemoGestureWasInterrupted() {
        AssertIsOnMainThread()
        Logger.info("")

        finishRecordingVoiceMessage(sendImmediately: false)
    }

    func sendVoiceMemoDraft(_ voiceMemoDraft: VoiceMessageInterruptedDraft) {
        AssertIsOnMainThread()

        sendVoiceMessageDraft(voiceMemoDraft)
    }

    public func saveDraft() {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard let inputToolbar else {
            return
        }

        if !inputToolbar.isHidden {
            let thread = self.thread
            let currentDraft = inputToolbar.messageBodyForSending
            let quotedReply = inputToolbar.quotedReplyDraft
            let editTarget = inputToolbar.editTarget
            SSKEnvironment.shared.databaseStorageRef.asyncWrite { transaction in
                // Reload a fresh instance of the thread model; our models are not
                // thread-safe, so it wouldn't be safe to update the model in an
                // async write.
                guard let thread = TSThread.fetchViaCache(uniqueId: thread.uniqueId, transaction: transaction) else {
                    owsFailDebug("Missing thread.")
                    return
                }

                let didChange = Self.draftHasChanged(
                    currentDraft: currentDraft,
                    quotedReply: quotedReply,
                    editTarget: editTarget,
                    thread: thread,
                    transaction: transaction,
                )

                // Persist the draft only if its changed. This avoids unnecessary model changes.
                guard didChange else {
                    return
                }

                let replyInfo: ThreadReplyInfo?
                if
                    let quotedReply,
                    let originalMessageTimestamp = quotedReply.originalMessageTimestamp,
                    let aci = quotedReply.originalMessageAuthorAddress.aci
                {
                    replyInfo = ThreadReplyInfo(
                        timestamp: originalMessageTimestamp,
                        author: aci,
                    )
                } else {
                    replyInfo = nil
                }

                let editTargetTimestamp: UInt64? = inputToolbar.editTarget?.timestamp

                thread.updateWithDraft(
                    draftMessageBody: currentDraft,
                    replyInfo: replyInfo,
                    editTargetTimestamp: editTargetTimestamp,
                    transaction: transaction,
                )
            }
        }
    }

    private static func draftHasChanged(
        currentDraft: MessageBody?,
        quotedReply: DraftQuotedReplyModel?,
        editTarget: TSOutgoingMessage?,
        thread: TSThread,
        transaction: DBReadTransaction,
    ) -> Bool {
        let currentText = currentDraft?.text ?? ""
        let persistedText = thread.messageDraft ?? ""
        if currentText != persistedText {
            return true
        }

        let currentRanges = currentDraft?.ranges.orderedMentions ?? []
        let persistedRanges = thread.messageDraftBodyRanges?.orderedMentions ?? []
        if currentRanges != persistedRanges {
            return true
        }

        if
            let threadTimestamp = thread.editTargetTimestamp,
            threadTimestamp != editTarget?.timestamp ?? 0
        {
            return true
        }

        let threadReplyInfoStore = DependenciesBridge.shared.threadReplyInfoStore
        let persistedQuotedReply = threadReplyInfoStore.fetch(for: thread.uniqueId, tx: transaction)
        if quotedReply?.originalMessageTimestamp != persistedQuotedReply?.timestamp {
            return true
        }
        if quotedReply?.originalMessageAuthorAddress.aci != persistedQuotedReply?.author {
            return true
        }
        return false
    }

    @MainActor
    fileprivate func tryToSendAttachments(
        _ approvedAttachments: ApprovedAttachments,
        from viewController: UIViewController,
        messageBody: MessageBody?,
        attachmentLimits: OutgoingAttachmentLimits,
        captionAboveMedia: Bool = false,
        tellomiScheduledAt: Date? = nil,
    ) async throws -> Bool {
        return try await tryToSendAttachments(
            approvedAttachments,
            messageBody: messageBody,
            from: viewController,
            attachmentLimits: attachmentLimits,
            untrustedThreshold: Date().addingTimeInterval(-OWSIdentityManagerImpl.Constants.defaultUntrustedInterval),
            captionAboveMedia: captionAboveMedia,
            tellomiScheduledAt: tellomiScheduledAt,
        )
    }

    enum SendAttachmentError: Error {
        case inputToolbarNotReady
        case inputToolbarMissing
        case conversationBlocked
        case untrustedContacts
    }

    @MainActor
    private func tryToSendAttachments(
        _ approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
        from viewController: UIViewController,
        attachmentLimits: OutgoingAttachmentLimits,
        untrustedThreshold: Date,
        captionAboveMedia: Bool = false,
        tellomiScheduledAt: Date? = nil,
    ) async throws -> Bool {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun, let inputToolbar else {
            return false
        }

        let imageQuality = approvedAttachments.imageQuality
        let imageQualityLevel = ImageQualityLevel.resolvedValue(
            imageQuality: imageQuality,
            standardQualityLevel: attachmentLimits.standardQualityLevel,
        )
        let sendableAttachments = try await approvedAttachments.attachments.mapAsync {
            return try await SendableAttachment.forPreviewableAttachment($0, imageQualityLevel: imageQualityLevel)
        }

        if self.isBlockedConversation() {
            let isBlocked = await self.showUnblockConversationUI()
            if isBlocked {
                // They're still blocked, so stop trying to send.
                return false
            }
        }

        let newUntrustedThreshold = Date()
        let identityIsConfirmed = await self.showSafetyNumberConfirmationIfNecessary(
            from: viewController,
            confirmationText: SafetyNumberStrings.confirmSendButton,
            untrustedThreshold: newUntrustedThreshold,
        )

        guard identityIsConfirmed else {
            // They're still untrusted, so stop trying to send.
            return false
        }

        let hasViewOnceAttachment = approvedAttachments.isViewOnce
        owsPrecondition(!hasViewOnceAttachment || messageBody == nil)
        owsPrecondition(!hasViewOnceAttachment || inputToolbar.quotedReplyDraft == nil)

        // Tellomi（tellomi/tellomi#1519 M-4）：长按发送里选了「定时发送」：排成定时消息，到点才进会话；不响发送音，引用草稿照样清掉。
        // 分享资料、默认阅后即焚这些「发了才算」的事留到真正发出时（执行器发之前做），删掉定时消息就什么都没发生过。
        // 准备附件（编辑、压视频）花的时间里已经过了点：直接照常发。
        if let tellomiScheduledAt, tellomiScheduledAt > Date() {
            try await TellomiScheduledMessageSender.shared.schedule(
                body: messageBody,
                attachments: sendableAttachments,
                isViewOnce: approvedAttachments.isViewOnce,
                thread: self.thread,
                quotedReplyDraft: inputToolbar.quotedReplyDraft,
                linkPreviewDraft: nil,
                captionAboveMedia: captionAboveMedia && messageBody != nil,
                at: tellomiScheduledAt,
            )
            inputToolbar.quotedReplyDraft = nil
            NotificationCenter.default.post(name: ChatListViewController.clearSearch, object: nil)
            return true
        }

        let didAddToProfileWhitelist = ThreadUtil.addThreadToProfileWhitelistIfEmptyOrPendingRequestAndSetDefaultTimerWithSneakyTransaction(self.thread)

        ThreadUtil.enqueueMessage(
            body: messageBody,
            attachments: (sendableAttachments, isViewOnce: approvedAttachments.isViewOnce),
            thread: self.thread,
            quotedReplyDraft: inputToolbar.quotedReplyDraft,
            // Tellomi（#1263，ADR-0068 §4.7）：说明文字在媒体上方（选图「···」里选的）。没有说明就没有意义，不记。
            tellomiCaptionAboveMedia: captionAboveMedia && messageBody != nil,
            persistenceCompletionHandler: {
                AssertIsOnMainThread()
                self.loadCoordinator.enqueueReload()
            },
        )

        self.messageWasSent()

        if didAddToProfileWhitelist {
            self.ensureBannerState()
        }

        NotificationCenter.default.post(name: ChatListViewController.clearSearch, object: nil)

        return true
    }

    // MARK: - Accessory View

    public func cameraButtonPressed() {
        AssertIsOnMainThread()

        takePictureOrVideo()
    }

    public func attachmentSheetButtonPressed() {
        AssertIsOnMainThread()

        presentTellomiAttachmentSheet()
    }

    public func gifButtonPressed() {
        AssertIsOnMainThread()

        showGifPicker()
    }

    public func contactButtonPressed() {
        AssertIsOnMainThread()

        chooseContactForSending()
    }

    public func locationButtonPressed() {
        AssertIsOnMainThread()

        let locationPicker = LocationPicker()
        locationPicker.delegate = self
        let navigationController = OWSNavigationController(rootViewController: locationPicker)
        navigationController.presentationController?.delegate = self
        dismissKeyBoard()
        presentFormSheet(navigationController, animated: true)
    }

    public func paymentButtonPressed() {
        AssertIsOnMainThread()

        guard let contactThread = thread as? TSContactThread else {
            owsFailDebug("Not a contact thread.")
            return
        }

        dismissKeyBoard()

        if SUIEnvironment.shared.paymentsRef.isKillSwitchActive {
            OWSActionSheets.showErrorAlert(message: OWSLocalizedString(
                "SETTINGS_PAYMENTS_CANNOT_SEND_PAYMENTS_KILL_SWITCH",
                comment: "Error message indicating that payments cannot be sent because the feature is not currently available.",
            ))
            return
        }

        if SSKEnvironment.shared.paymentsHelperRef.isPaymentsVersionOutdated {
            OWSActionSheets.showPaymentsOutdatedClientSheet(title: .cantSendPayment)
            return
        }

        SendPaymentViewController.presentFromConversationView(
            self,
            delegate: self,
            recipientAddress: contactThread.contactAddress,
            initialPaymentAmount: nil,
            isOutgoingTransfer: false,
        )
    }

    public func pollButtonPressed() {
        AssertIsOnMainThread()

        dismissKeyBoard()

        let newPollViewController = NewPollViewController2(
            maxOptionCount: RemoteConfig.current.maxPollOptionSendCount,
        )
        newPollViewController.sendDelegate = self
        present(OWSNavigationController(rootViewController: newPollViewController), animated: true)
    }

}

// MARK: -

public extension ConversationViewController {

    func showErrorAlert(attachmentError: SignalAttachmentError?) {
        AssertIsOnMainThread()

        Logger.warn("\(attachmentError as Optional)")
        let errorMessage = (attachmentError ?? .missingData).localizedDescription

        OWSActionSheets.showActionSheet(
            title: OWSLocalizedString("ATTACHMENT_ERROR_ALERT_TITLE", comment: "The title of the 'attachment error' alert."),
            message: errorMessage,
        )
    }

    func showApprovalDialog(forAttachments attachments: [PreviewableAttachment], attachmentLimits: OutgoingAttachmentLimits) {
        AssertIsOnMainThread()

        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard let inputToolbar else {
            return
        }

        let modal = AttachmentApprovalViewController.wrappedInNavController(
            attachments: attachments,
            initialMessageBody: inputToolbar.messageBodyForSending,
            hasQuotedReplyDraft: inputToolbar.quotedReplyDraft != nil,
            attachmentLimits: attachmentLimits,
            approvalDelegate: self,
            approvalDataSource: self,
            stickerSheetDelegate: self,
        )
        modal.modalPresentationStyle = .overCurrentContext
        let presenter = self.splitViewController ?? self
        presenter.present(modal, animated: true)
    }
}

// MARK: -

private extension ConversationViewController {

    // MARK: - Attachment Picking: Contacts

    func chooseContactForSending() {
        AssertIsOnMainThread()

        dismissKeyBoard()
        SUIEnvironment.shared.contactsViewHelperRef.checkReadAuthorization(
            purpose: .share,
            performWhenAllowed: {
                if BuildFlags.accountIdentifierSharing {
                    let contactsPicker = SelectContactForSharingViewController()
                    let sheet = OWSNavigationController(rootViewController: contactsPicker)
                    sheet.presentationController?.delegate = self
                    self.presentFormSheet(sheet, animated: true)
                } else {
                    let contactsPicker = ContactPickerViewController(allowsMultipleSelection: false, subtitleCellType: .none)
                    contactsPicker.delegate = self
                    contactsPicker.title = OWSLocalizedString(
                        "CONTACT_PICKER_TITLE",
                        comment: "navbar title for contact picker when sharing a contact",
                    )
                    let sheet = OWSNavigationController(rootViewController: contactsPicker)
                    sheet.presentationController?.delegate = self
                    self.presentFormSheet(sheet, animated: true)
                }
            },
            presentErrorFrom: self,
        )
    }

    // MARK: - Media Library

    /// Tellomi（#1261 P-8）：`presenter` / `sendMediaNavDelegate` 给选图面板的相机格用（见文件末尾 `tellomiTakePictureOrVideo`）；
    /// 其它入口照旧（都是 nil = 会话页自己）。
    func takePictureOrVideo(presenter: UIViewController? = nil, sendMediaNavDelegate: SendMediaNavDelegate? = nil) {
        AssertIsOnMainThread()

        let attachmentLimits = OutgoingAttachmentLimits.currentLimits()
        ows_askForCameraPermissions { [weak self] cameraGranted in
            guard let self else { return }
            guard cameraGranted else {
                Logger.warn("camera permission denied.")
                return
            }
            self.ows_askForMicrophonePermissions { [weak self] micGranted in
                guard let self else { return }
                if !micGranted {
                    Logger.warn("proceeding, though mic permission denied.")
                    // We can still continue without mic permissions, but any captured video will
                    // be silent.
                }

                let pickerModal = SendMediaNavigationController.showingCameraFirst(
                    hasQuotedReplyDraft: self.inputToolbar?.quotedReplyDraft != nil,
                    attachmentLimits: attachmentLimits,
                )
                pickerModal.sendMediaNavDelegate = sendMediaNavDelegate ?? self
                pickerModal.sendMediaNavDataSource = self
                pickerModal.modalPresentationStyle = .overFullScreen
                // Defer hiding status bar until modal is fully onscreen
                // to prevent unwanted shifting upwards of the entire presenter VC's view.
                let pickerHidesStatusBar = (pickerModal.topViewController?.prefersStatusBarHidden ?? false)
                if !pickerHidesStatusBar {
                    pickerModal.modalPresentationCapturesStatusBarAppearance = true
                }
                self.dismissKeyBoard()
                (presenter ?? self).present(pickerModal, animated: true) {
                    if pickerHidesStatusBar {
                        pickerModal.modalPresentationCapturesStatusBarAppearance = true
                        pickerModal.setNeedsStatusBarAppearanceUpdate()
                    }
                }
            }
        }
    }

    func chooseFromLibraryWithNativePicker() {
        AssertIsOnMainThread()

        let pickerModal = SendMediaNavigationController.showingNativePicker(
            hasQuotedReplyDraft: inputToolbar?.quotedReplyDraft != nil,
            attachmentLimits: .currentLimits(),
        )
        pickerModal.sendMediaNavDelegate = self
        pickerModal.sendMediaNavDataSource = self

        self.dismissKeyBoard()
        let presenter = self.splitViewController ?? self
        presenter.present(pickerModal, animated: false)
    }
}

// MARK: - Attachment Picking: GIFs

public extension ConversationViewController {
    func showGifPicker() {
        let gifModal = GifPickerNavigationViewController(
            initialMessageBody: inputToolbar?.messageBodyForSending,
            hasQuotedReplyDraft: inputToolbar?.quotedReplyDraft != nil,
        )
        gifModal.approvalDelegate = self
        gifModal.approvalDataSource = self
        gifModal.presentationController?.delegate = self
        dismissKeyBoard()
        present(gifModal, animated: true)
    }
}

// MARK: -

extension ConversationViewController: LocationPickerDelegate {

    public func didPickLocation(_ locationPicker: LocationPicker, location: Location) {
        AssertIsOnMainThread()

        Task { @MainActor in
            let attachment: SendableAttachment
            do {
                attachment = try await location.prepareAttachment()
            } catch {
                owsFailDebug("Error: \(error).")
                return
            }

            // TODO: Can we move this off the main thread?

            let didAddToProfileWhitelist = ThreadUtil.addThreadToProfileWhitelistIfEmptyOrPendingRequestAndSetDefaultTimerWithSneakyTransaction(self.thread)

            ThreadUtil.enqueueMessage(
                body: MessageBody(text: location.messageText, ranges: .empty),
                attachments: ([attachment], isViewOnce: false),
                thread: self.thread,
                persistenceCompletionHandler: {
                    AssertIsOnMainThread()
                    self.loadCoordinator.enqueueReload()
                },
            )

            self.messageWasSent()

            if didAddToProfileWhitelist {
                self.ensureBannerState()
            }

            NotificationCenter.default.post(name: ChatListViewController.clearSearch, object: nil)
        }
    }

    public func locationPickerDidCancel() {
        // Tellomi（P-3）：取消停在聊天页，不再弹回附件 Sheet。
        self.dismiss(animated: true)
    }
}

// MARK: -

// MARK: -

extension ConversationViewController: SendMediaNavDelegate {
    func sendMediaNavDidCancel(_ sendMediaNavigationController: SendMediaNavigationController) {
        // Tellomi（P-3）：聊天栏的相机键、没有照片权限时的系统选择器，取消都停在聊天页——上游这里会弹回附件面板，
        // 附件面板改成 Sheet 后就变成「没开过 Sheet，取消相机却冒出 Sheet」。Sheet 里的相机格取消回 Sheet 走的是
        // `TellomiPickerCameraRoute`，不经过这里。
        self.dismiss(animated: true, completion: nil)
    }

    func sendMediaNav(
        _ sendMediaNavigationController: SendMediaNavigationController,
        didApproveAttachments approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
    ) {
        ModalActivityIndicatorViewController.present(
            fromViewController: sendMediaNavigationController,
            title: CommonStrings.preparingModal,
            asyncBlock: { modal in
                await self.sendAttachments(
                    approvedAttachments,
                    messageBody: messageBody,
                    from: sendMediaNavigationController,
                    attachmentLimits: sendMediaNavigationController.attachmentLimits,
                )
                modal.dismiss(completion: {
                    self.dismiss(animated: true)
                })
            },
        )
    }

    /// Attempts to send attachments. Handles prompting to unblock or un-verify safety numbers, as well as showing failure states.
    /// Tellomi（#1261）：返回是否发出去了（「单独发送」上一条没发出就停）。
    /// Tellomi（#1121）：`clearsDraft` = 发完清不清聊天输入框；附件 Sheet「文件」页传 false（见 `tellomiClearsInputAfterSending`）。
    @MainActor
    @discardableResult
    func sendAttachments(
        _ approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
        from viewController: UIViewController,
        attachmentLimits: OutgoingAttachmentLimits,
        clearsDraft: Bool = true,
        captionAboveMedia: Bool = false,
        tellomiScheduledAt: Date? = nil,
    ) async -> Bool {
        // Tellomi（tellomi/tellomi#1518 V-6，owner 2026-10-14 照 TG）：静音当 GIF 发的视频单独成一条，其余照常成组；
        // 说明跟着其余那组（全是静音视频时跟着最后一条）。上一条没发出去就不再发后面的。
        if let split = TellomiMutedVideoSending.messageGroups(approvedAttachments) {
            for (index, group) in split.groups.enumerated() {
                let hasBody = index == split.bodyIndex
                let sent = await sendAttachments(
                    group,
                    messageBody: hasBody ? messageBody : nil,
                    from: viewController,
                    attachmentLimits: attachmentLimits,
                    clearsDraft: clearsDraft,
                    captionAboveMedia: hasBody && captionAboveMedia,
                    tellomiScheduledAt: tellomiScheduledAt,
                )
                guard sent else { return false }
            }
            return true
        }

        let didSend: Bool
        do {
            didSend = try await tryToSendAttachments(
                approvedAttachments,
                from: viewController,
                messageBody: messageBody,
                attachmentLimits: attachmentLimits,
                captionAboveMedia: captionAboveMedia,
                tellomiScheduledAt: tellomiScheduledAt,
            )
        } catch TellomiScheduledMessageSender.ScheduleError.tooManyScheduled {
            // Tellomi（#1519 M-4）：一个会话最多 100 条定时消息。选图页发之前已经查过、在那里提示了（`photoPicker(_:send:…)`）；
            // 这里只是两处同时排时的兜底：停下，不再排后面的。
            Logger.warn("Hit the scheduled message limit while scheduling.")
            return false
        } catch {
            self.showErrorAlert(attachmentError: error as? SignalAttachmentError)
            return false
        }
        guard didSend else {
            return false
        }
        if Self.tellomiClearsInputAfterSending(approvedAttachments, clearsDraft: clearsDraft) {
            inputToolbar?.clearTextMessage(animated: false)
        }

        // we want to already be at the bottom when the user returns, rather than have to watch
        // the new message scroll into view.
        scrollToBottomOfConversation(animated: true)
        return true
    }

    func sendMediaNav(
        _ sendMediaNavifationController: SendMediaNavigationController,
        didFinishWithTextAttachment textAttachment: UnsentTextAttachment,
    ) {
        owsFailDebug("Can not post text stories to chat.")
    }

    func sendMediaNav(
        _ sendMediaNavigationController: SendMediaNavigationController,
        didChangeMessageBody newMessageBody: MessageBody?,
    ) {
        guard hasViewWillAppearEverBegun else {
            owsFailDebug("InputToolbar not yet ready.")
            return
        }
        guard let inputToolbar else {
            return
        }

        inputToolbar.setMessageBody(newMessageBody, animated: false)
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didChangeViewOnceState isViewOnce: Bool) {
        // We can ignore this event.
    }
}

// MARK: -

extension ConversationViewController: SendMediaNavDataSource {

    func sendMediaNavInitialMessageBody(_ sendMediaNavigationController: SendMediaNavigationController) -> MessageBody? {
        inputToolbar?.messageBodyForSending
    }

    var sendMediaNavTextInputContextIdentifier: String? { textInputContextIdentifier }

    var sendMediaNavRecipientNames: [String] {
        let displayName = SSKEnvironment.shared.databaseStorageRef.read { tx in SSKEnvironment.shared.contactManagerRef.displayName(for: thread, transaction: tx) }
        return [displayName]
    }

    func sendMediaNavMentionableAcis(tx: DBReadTransaction) -> [Aci] {
        supportsMentions ? thread.recipientAddresses(with: tx).compactMap(\.aci) : []
    }

    func sendMediaNavMentionCacheInvalidationKey() -> String {
        return thread.uniqueId
    }
}

// MARK: - StickerPickerSheetDelegate

extension ConversationViewController: StickerPickerSheetDelegate {
    public func makeManageStickersViewController(for stickerPickerSheet: StickerPickerSheet) -> UIViewController {
        let manageStickersView = ManageStickersViewController()
        let navigationController = OWSNavigationController(rootViewController: manageStickersView)
        return navigationController
    }
}

// MARK: - PollSendDelegate

extension ConversationViewController: PollSendDelegate {
    public func sendPoll(question: String, options: [String], allowMultipleVotes: Bool) {
        ThreadUtil.enqueueMessage(
            withPoll:
            CreatePollMessage(
                question: question,
                options: options,
                allowMultiple: allowMultipleVotes,
            ),
            thread: self.thread,
        )
    }
}

// MARK: - Tellomi

extension ConversationViewController {
    /// Tellomi（tellomi/tellomi#1261 P-8）：选图面板的相机格从面板上面打开相机（上面的 `takePictureOrVideo` 在 private 扩展里）。
    func tellomiTakePictureOrVideo(presenter: UIViewController, sendMediaNavDelegate: SendMediaNavDelegate) {
        takePictureOrVideo(presenter: presenter, sendMediaNavDelegate: sendMediaNavDelegate)
    }

    /// Tellomi（tellomi/tellomi#1115）：没有照片权限时附件 Sheet 占位里的「照片」走上游的系统选择器
    /// （上面的 `chooseFromLibraryWithNativePicker` 在 private 扩展里）。
    func tellomiChooseFromLibraryWithNativePicker() {
        chooseFromLibraryWithNativePicker()
    }

    /// Tellomi（tellomi/tellomi#1121）：附件发出去之后要不要清掉聊天输入框（`sendAttachments` 用；上游的判断原来直接写在那里面，
    /// 抽出来是为了能单测——会话页没法在单测里整个建出来）。
    /// - 调用方说不清（`clearsDraft == false`）就不清：附件 Sheet「文件」页发的东西从来不带输入框里的草稿（点一行 / 系统选择器 /
    ///   扫描都没有说明，多选的说明是文件页自己的输入框），清了那段字就既没发出去也没了。Android 同一功能
    ///   （`ConversationFragment.sendSlidesInOrder`）传的也是 `clearCompose = false`。
    /// - 其余照上游：贴纸样子的单个无边框附件不清，别的都清（草稿当说明一起发出去了）。
    static func tellomiClearsInputAfterSending(_ approvedAttachments: ApprovedAttachments, clearsDraft: Bool) -> Bool {
        guard clearsDraft else {
            return false
        }
        if
            approvedAttachments.attachments.count == 1,
            let attachment = approvedAttachments.attachments.first,
            attachment.rawValue.isBorderless
        {
            // This looks like a sticker, we shouldn't clear the input toolbar.
            return false
        }
        return true
    }
}
