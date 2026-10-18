//
// Copyright 2025 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI

class PinnedMessagesDetailsViewController: OWSViewController, DatabaseChangeDelegate, PinnedMessageLongPressDelegate.ActionDelegate {
    private var pinnedMessages: [TSMessage]
    private let threadViewModel: ThreadViewModel
    private let db: DB
    private var messageLongPressDelegates: [PinnedMessageLongPressDelegate] = []
    private var pinnedMessageManager: PinnedMessageManager
    let spoilerState: SpoilerRenderState

    private weak var delegate: PinnedMessageInteractionManagerDelegate?

    private var lastKnownWidth: CGFloat = 0

    static let goToMessageButtonSize: CGFloat = 36

    /// Tellomi (pinned-messages.md 3.5): "N pinned messages"; the pins for me only (ADR-0081 §4.3); whether I may unpin everyone's
    /// pins here; the list opens at the newest, at the bottom.
    private let tellomiTitleLabel = UILabel()
    private var tellomiPinnedForMeIds = Set<Int64>()
    private var tellomiCanPinForEveryone = false
    private weak var tellomiScrollView: UIScrollView?
    private var tellomiScrollToNewestPending = false

    init(
        pinnedMessages: [TSMessage],
        threadViewModel: ThreadViewModel,
        database: DB,
        delegate: PinnedMessageInteractionManagerDelegate,
        databaseChangeObserver: DatabaseChangeObserver,
        pinnedMessageManager: PinnedMessageManager,
        spoilerState: SpoilerRenderState,
    ) {
        self.pinnedMessages = Self.tellomiInChatOrder(pinnedMessages)
        self.threadViewModel = threadViewModel
        self.db = database
        self.delegate = delegate
        self.pinnedMessageManager = pinnedMessageManager
        self.spoilerState = spoilerState

        super.init()

        view.backgroundColor = .Signal.groupedBackground

        databaseChangeObserver.appendDatabaseChangeDelegate(self)

        // Tellomi (pinned-messages.md 3.5): the title says how many — set with each layout.
        let titleLabel = tellomiTitleLabel
        titleLabel.font = .dynamicTypeHeadlineClamped.semibold()
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.textAlignment = .center

        let subtitleLabel = UILabel()
        subtitleLabel.text = threadViewModel.name
        subtitleLabel.font = .dynamicTypeSubheadlineClamped
        subtitleLabel.textColor = UIColor.Signal.secondaryLabel
        subtitleLabel.textAlignment = .center

        let titleStackView = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titleStackView.axis = .vertical
        titleStackView.alignment = .center
        titleStackView.spacing = 4

        navigationItem.titleView = titleStackView
        navigationItem.rightBarButtonItem = .doneButton(dismissingFrom: self)
    }

    private func layoutPinnedMessages(tx: DBReadTransaction) {
        messageLongPressDelegates = []
        view.subviews.forEach { $0.removeFromSuperview() }
        tellomiRefresh(tx: tx)

        let scrollView = UIScrollView()
        let paddedContainerView = UIView()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 12

        var currentDaysBefore = -1
        // Tellomi (pinned-messages.md 3.5): in chat order, oldest at the top (`tellomiInChatOrder`).
        for (index, message) in pinnedMessages.enumerated() {
            guard let renderItem = buildRenderItem(thread: threadViewModel.threadRecord, message: message, tx: tx)
            else {
                continue
            }

            let longPressDelegate = PinnedMessageLongPressDelegate(itemViewModel: CVItemViewModelImpl(renderItem: renderItem))
            longPressDelegate.actionDelegate = self
            messageLongPressDelegates.append(longPressDelegate)

            let itemDate = Date(millisecondsSince1970: message.timestamp)
            let daysPrior = DateUtil.daysFrom(firstDate: itemDate, toSecondDate: Date())

            if daysPrior != currentDaysBefore {
                currentDaysBefore = daysPrior
                let dateInteraction = DateHeaderInteraction(threadUniqueId: threadViewModel.threadUniqueId, timestamp: message.timestamp)
                if let dateItem = buildDateRenderItem(dateInteraction: dateInteraction, tx: tx) {
                    let cellView = CVCellView()
                    cellView.configure(renderItem: dateItem, componentDelegate: self)
                    cellView.isCellVisible = true
                    cellView.autoSetDimension(.height, toSize: dateItem.cellSize.height)
                    stack.addArrangedSubview(cellView)
                }
            }
            let cellRow = buildButtonAndCellStack(
                renderItem: renderItem,
                message: message,
                reversedIndex: index,
            )
            stack.addArrangedSubview(cellRow)
            if let rowId = message.sqliteRowId, tellomiPinnedForMeIds.contains(rowId) {
                stack.setCustomSpacing(4, after: cellRow)
                stack.addArrangedSubview(tellomiOnlyVisibleToYouRow(isOutgoing: message.isOutgoing))
            }
        }

        paddedContainerView.addSubview(stack)
        scrollView.addSubview(paddedContainerView)
        view.addSubview(scrollView)

        scrollView.autoPinEdgesToSuperviewSafeArea()
        paddedContainerView.autoPinEdgesToSuperviewEdges()

        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 16, left: 16, bottom: 64, right: 16))
        paddedContainerView.autoMatch(.width, to: .width, of: scrollView)
        tellomiScrollView = scrollView
        tellomiScrollToNewestPending = true

        // Tellomi (pinned-messages.md 3.5, as in both Telegram apps): no question and no spinner — the list closes and the chat
        // shows "N messages unpinned · Undo" before the unpins go out. Someone who may not unpin them all hides them here instead
        // (also in a group that has ended).
        let canUnpinAll = tellomiCanUnpinAll
        let unpinAllButton = UIButton(
            configuration: .largeSecondary(title: canUnpinAll
                ? OWSLocalizedString(
                    "TELLOMI_PINNED_LIST_UNPIN_ALL",
                    comment: "Tellomi (pinned-messages.md 3.5): button at the bottom of the pinned list that unpins every message, with Undo.",
                )
                : OWSLocalizedString(
                    "TELLOMI_PINNED_BAR_HIDE",
                    comment: "Tellomi (pinned-messages.md 3.4): accessibility label of × on the pinned bar when you may not unpin; it hides the bar on this device until there is a newer pin.",
                )),
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
                if canUnpinAll {
                    self?.delegate?.unpinAllMessages()
                } else {
                    self?.delegate?.tellomiHidePinnedMessages()
                }
            },
        )
        view.addSubview(unpinAllButton)
        unpinAllButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            unpinAllButton.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor, constant: -16),
            unpinAllButton.centerXAnchor.constraint(equalTo: contentLayoutGuide.centerXAnchor),
        ])
    }

    // MARK: - Tellomi (pinned-messages.md 3.5)

    /// In the order the messages are in the chat (newest at the bottom) — the order of the pinned bar, not of pinning.
    private static func tellomiInChatOrder(_ messages: [TSMessage]) -> [TSMessage] {
        return messages.sorted { $0.sortId < $1.sortId }
    }

    private func tellomiRefresh(tx: DBReadTransaction) {
        let thread = threadViewModel.threadRecord
        tellomiPinnedForMeIds = thread.sqliteRowId.map { TellomiPinsForMe.pinnedForMeInteractionIds(threadId: $0, tx: tx) } ?? []
        let localAci = DependenciesBridge.shared.tsAccountManager.localIdentifiers(tx: tx)?.aci
        tellomiCanPinForEveryone = localAci.map { thread.canUserEditPinnedMessages(aci: $0, tx: tx) } ?? false
        let format = OWSLocalizedString(
            "TELLOMI_PINNED_LIST_TITLE_%ld",
            tableName: "PluralAware",
            comment: "Tellomi (pinned-messages.md 3.5): title of the pinned messages list. Embeds {{ number of pinned messages }}.",
        )
        tellomiTitleLabel.text = String.localizedStringWithFormat(format, pinnedMessages.count)
    }

    /// Every pin here can be unpinned (`TellomiPinChoice.canUnpinAll`) — otherwise the button hides them on this device.
    private var tellomiCanUnpinAll: Bool {
        return TellomiPinChoice.canUnpinAll(
            pinnedForMe: pinnedMessages.map { $0.sqliteRowId.map { tellomiPinnedForMeIds.contains($0) } ?? false },
            canPinForEveryone: tellomiCanPinForEveryone,
            isTerminatedGroup: threadViewModel.threadRecord.isTerminatedGroup,
        )
    }

    /// "Only visible to you" under a pin for me only (ADR-0081 §4.3), on the bubble's side — the cell is as wide as the bubble here.
    /// The same as Android's `TellomiPinnedForMeLabelDecoration`.
    private func tellomiOnlyVisibleToYouRow(isOutgoing: Bool) -> UIView {
        let label = UILabel()
        label.text = OWSLocalizedString(
            "TELLOMI_PINNED_LIST_ONLY_YOU_CAN_SEE",
            comment: "Tellomi (ADR-0081 §4.3, pinned-messages.md 3.5): under a message pinned for me only, in the pinned list.",
        )
        label.font = .dynamicTypeCaption1Clamped
        label.textColor = UIColor.Signal.secondaryLabel
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: isOutgoing ? [spacer, label] : [label, spacer])
        row.axis = .horizontal
        return row
    }

    /// The list opens at the newest pin, at the bottom (Android's list is the same; the chat itself ends there too).
    private func tellomiScrollToNewestIfPending() {
        guard tellomiScrollToNewestPending, let scrollView = tellomiScrollView, scrollView.bounds.height > 0 else {
            return
        }
        tellomiScrollToNewestPending = false
        let bottom = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        scrollView.contentOffset.y = max(-scrollView.adjustedContentInset.top, bottom)
    }

    private func updatePinnedMessageState() {
        guard let threadId = threadViewModel.threadRecord.sqliteRowId else {
            return
        }
        db.read { tx in
            pinnedMessages = Self.tellomiInChatOrder(pinnedMessageManager.fetchPinnedMessagesForThread(threadId: threadId, tx: tx))
            layoutPinnedMessages(tx: tx)
        }
        view.layoutIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let currentWidth = view.bounds.width
        guard currentWidth != lastKnownWidth else {
            tellomiScrollToNewestIfPending()
            return
        }
        lastKnownWidth = currentWidth
        db.read { tx in
            layoutPinnedMessages(tx: tx)
        }
    }

    private func buildButtonAndCellStack(renderItem: CVRenderItem, message: TSMessage, reversedIndex: Int) -> UIStackView {
        let cellHStack = UIStackView()
        cellHStack.axis = .horizontal
        cellHStack.alignment = .trailing
        cellHStack.distribution = .fill

        let goToMessageButton = UIButton()
        goToMessageButton.setImage(.arrowRightCircle, for: .normal)
        goToMessageButton.tintColor = UIColor.Signal.secondaryLabel
        goToMessageButton.backgroundColor = UIColor.Signal.tertiaryFill
        goToMessageButton.translatesAutoresizingMaskIntoConstraints = false
        goToMessageButton.layer.cornerRadius = 18
        goToMessageButton.clipsToBounds = true
        goToMessageButton.addAction(
            UIAction { [weak self] _ in self?.goToMessage(reversedIndex) },
            for: .primaryActionTriggered,
        )

        let cellView = CVCellView()
        cellView.configure(renderItem: renderItem, componentDelegate: self)
        cellView.isCellVisible = true
        cellView.autoSetDimension(.height, toSize: renderItem.cellSize.height)
        cellView.autoSetDimension(.width, toSize: renderItem.cellSize.width)
        let uiContextMenuInteraction = UIContextMenuInteraction(delegate: messageLongPressDelegates[reversedIndex])
        cellView.addInteraction(uiContextMenuInteraction)

        if let contentMenuContextView = cellView.componentView?.contextMenuContentView?() {
            let uiContextMenuInteraction = UIContextMenuInteraction(delegate: messageLongPressDelegates[reversedIndex])
            contentMenuContextView.addInteraction(uiContextMenuInteraction)
        }

        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        if message.isOutgoing {
            cellHStack.addArrangedSubview(spacer)
            cellHStack.addArrangedSubview(goToMessageButton)
            cellHStack.addArrangedSubview(cellView)
        } else {
            cellHStack.addArrangedSubview(cellView)
            cellHStack.addArrangedSubview(goToMessageButton)
            cellHStack.addArrangedSubview(spacer)
        }
        NSLayoutConstraint.activate([
            goToMessageButton.heightAnchor.constraint(equalToConstant: Self.goToMessageButtonSize),
            goToMessageButton.widthAnchor.constraint(equalToConstant: Self.goToMessageButtonSize),
        ])

        return cellHStack
    }

    private func buildDateRenderItem(dateInteraction: DateHeaderInteraction, tx: DBReadTransaction) -> CVRenderItem? {
        let conversationStyle = ConversationStyle(
            type: .messageDetails,
            thread: threadViewModel.threadRecord,
            viewWidth: view.safeAreaLayoutGuide.layoutFrame.width,
            hasWallpaper: false,
            shouldDimWallpaperInDarkMode: false,
            chatColor: DependenciesBridge.shared.chatColorSettingStore.resolvedChatColor(
                for: threadViewModel.threadRecord,
                tx: tx,
            ),
            isStandaloneRenderItem: true,
        )

        let groupNameColors = GroupNameColors.forThread(threadViewModel.threadRecord)

        return CVLoader.buildStandaloneRenderItem(
            interaction: dateInteraction,
            thread: threadViewModel.threadRecord,
            conversationStyle: conversationStyle,
            spoilerState: self.spoilerState,
            groupNameColors: groupNameColors,
            transaction: tx,
        )
    }

    private func buildRenderItem(
        thread: TSThread,
        message: TSMessage,
        forceDateHeader: Bool = false,
        tx: DBReadTransaction,
    ) -> CVRenderItem? {
        let conversationStyle = ConversationStyle(
            type: .messageDetails,
            thread: thread,
            viewWidth: view.safeAreaLayoutGuide.layoutFrame.width - Self.goToMessageButtonSize,
            hasWallpaper: false,
            shouldDimWallpaperInDarkMode: false,
            chatColor: DependenciesBridge.shared.chatColorSettingStore.resolvedChatColor(
                for: thread,
                tx: tx,
            ),
        )

        let groupNameColors = GroupNameColors.forThread(threadViewModel.threadRecord)

        return CVLoader.buildStandaloneRenderItem(
            interaction: message,
            thread: thread,
            conversationStyle: conversationStyle,
            spoilerState: self.spoilerState,
            groupNameColors: groupNameColors,
            transaction: tx,
        )
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.db.read { tx in
                self?.layoutPinnedMessages(tx: tx)
            }
        }
    }

    // MARK: - Interactions

    private func goToMessage(_ messageIndex: Int) {
        // Tellomi (pinned-messages.md 3.5): `pinnedMessages` is in chat order, the order they're laid out in.
        guard pinnedMessages.indices.contains(messageIndex) else {
            return
        }
        let message = pinnedMessages[messageIndex]
        delegate?.goToMessage(message: message)
        dismiss(animated: true)
    }

    // MARK: - DatabaseChangeDelegate

    func databaseChangesDidUpdate(databaseChanges: SignalServiceKit.DatabaseChanges) {
        let pinnedMessagesSet = Set(pinnedMessages.map(\.uniqueId))
        guard Set(databaseChanges.interactionUniqueIds).isDisjoint(with: pinnedMessagesSet) == false else {
            return
        }
        updatePinnedMessageState()
    }

    func databaseChangesDidUpdateExternally() {
        updatePinnedMessageState()
    }

    func databaseChangesDidReset() {
        updatePinnedMessageState()
    }

    // MARK: - PinnedMessageLongPressActionDelegate

    func deleteMessage(itemViewModel: CVItemViewModelImpl) {
        itemViewModel.interaction.presentDeletionActionSheet(from: self)
    }

    func unpinMessage(itemViewModel: CVItemViewModelImpl) {
        // Tellomi (pinned-messages.md 3.6): close the list, then the chat unpins with "Message unpinned · Undo" for 5 s, the same as
        // from the bar or the message menu (Android's `PinnedMessagesBottomSheet` does the same).
        guard let message = itemViewModel.interaction as? TSMessage else { return }
        dismiss(animated: true)
        delegate?.unpinMessage(message: message, modalDelegate: nil)
    }
}

// MARK: - UIContextMenuInteractionDelegate

private class PinnedMessageLongPressDelegate: NSObject, UIContextMenuInteractionDelegate {
    fileprivate protocol ActionDelegate: AnyObject {
        func deleteMessage(itemViewModel: CVItemViewModelImpl)
        func unpinMessage(itemViewModel: CVItemViewModelImpl)
    }

    let itemViewModel: CVItemViewModelImpl

    weak var actionDelegate: ActionDelegate?

    init(itemViewModel: CVItemViewModelImpl) {
        self.itemViewModel = itemViewModel
    }

    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint,
    ) -> UIContextMenuConfiguration? {

        return UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: nil,
            actionProvider: { [weak self] _ in
                guard let self else { return UIMenu(children: []) }
                var actions: [UIAction] = []
                if itemViewModel.canCopyOrShareOrSpeakText {
                    actions.append(
                        UIAction(
                            title: OWSLocalizedString(
                                "CONTEXT_MENU_COPY",
                                comment: "Context menu button title",
                            ),
                            image: .copyLight,
                        ) { [weak self] _ in
                            self?.itemViewModel.copyTextAction()
                        },
                    )
                }

                if itemViewModel.canSaveMedia {
                    actions.append(
                        UIAction(
                            title: OWSLocalizedString(
                                "CONTEXT_MENU_SAVE_MEDIA",
                                comment: "Context menu button title",
                            ),
                            image: .saveLight,
                        ) { [weak self] _ in
                            self?.itemViewModel.saveMediaAction()
                        },
                    )
                }

                if !itemViewModel.thread.isTerminatedGroup {
                    actions.append(UIAction(
                        title: OWSLocalizedString(
                            "PINNED_MESSAGES_UNPIN",
                            comment: "Action menu item to unpin a message",
                        ),
                        image: .pinSlash,
                    ) { [weak self] _ in
                        guard let self else { return }
                        actionDelegate?.unpinMessage(itemViewModel: itemViewModel)
                    })
                }
                actions.append(
                    contentsOf: [
                        UIAction(
                            title: OWSLocalizedString(
                                "CONTEXT_MENU_DELETE_MESSAGE",
                                comment: "Context menu button title",
                            ),
                            image: .trashLight,
                        ) { [weak self] _ in
                            guard let self else { return }
                            actionDelegate?.deleteMessage(itemViewModel: itemViewModel)
                        },
                    ],
                )

                return UIMenu(children: actions)
            },
        )
    }
}

// MARK: - CVComponentDelegate

extension PinnedMessagesDetailsViewController: CVComponentDelegate {
    func enqueueReload() {}

    func enqueueReloadWithoutCaches() {}

    func didTapBodyTextItem(_ item: CVTextLabel.Item) {}

    func didLongPressBodyTextItem(_ item: CVTextLabel.Item) {}

    func didTapSystemMessageItem(_ item: CVTextLabel.Item) {}

    func didTapCollapseSet(collapseSetId: String) {}

    func didDoubleTapTextViewItem(_ itemViewModel: CVItemViewModelImpl) {}

    func didLongPressTextViewItem(
        _ cell: CVCell,
        itemViewModel: CVItemViewModelImpl,
        shouldAllowMessageSendActions: Bool,
    ) {}

    func didLongPressMediaViewItem(
        _ cell: CVCell,
        itemViewModel: CVItemViewModelImpl,
        shouldAllowMessageSendActions: Bool,
    ) {}

    func didLongPressQuote(
        _ cell: CVCell,
        itemViewModel: CVItemViewModelImpl,
        shouldAllowMessageSendActions: Bool,
    ) {}

    func didLongPressSystemMessage(
        _ cell: CVCell,
        itemViewModel: CVItemViewModelImpl,
    ) {}

    func didLongPressSticker(
        _ cell: CVCell,
        itemViewModel: CVItemViewModelImpl,
        shouldAllowMessageSendActions: Bool,
    ) {}

    func didLongPressPaymentMessage(
        _ cell: CVCell,
        itemViewModel: CVItemViewModelImpl,
        shouldAllowMessageSendActions: Bool,
    ) {}

    func didLongPressPoll(
        _ cell: CVCell,
        itemViewModel: CVItemViewModelImpl,
        shouldAllowMessageSendActions: Bool,
    ) {}

    func didTapPayment(_ payment: PaymentsHistoryItem) {}

    func didChangeLongPress(_ itemViewModel: CVItemViewModelImpl) {}

    func didEndLongPress(_ itemViewModel: CVItemViewModelImpl) {}

    func didCancelLongPress(_ itemViewModel: CVItemViewModelImpl) {}

    // MARK: -

    func willBecomeVisibleWithSkippedDownloads(_ message: TSMessage) {}

    func didTapSkippedDownloads(_ message: TSMessage) {}

    func didCancelDownload(_ message: TSMessage, attachmentId: Attachment.IDType) {}

    // MARK: -

    func didTapReplyToItem(_ itemViewModel: CVItemViewModelImpl) {}

    func didTapSenderAvatar(_ interaction: TSInteraction) {}

    func shouldAllowMessageSendActionsForItem(_ itemViewModel: CVItemViewModelImpl) -> Bool { false }

    func didTapReactions(
        reactionState: InteractionReactionState,
        message: TSMessage,
    ) {}

    func didTapTruncatedTextMessage(_ itemViewModel: CVItemViewModelImpl) {}

    func didTapShowEditHistory(_ itemViewModel: CVItemViewModelImpl) {}

    var hasPendingMessageRequest: Bool { false }

    func didTapUndownloadableMedia() {}

    func didTapUndownloadableGenericFile() {}

    func didTapUndownloadableOversizeText() {}

    func didTapUndownloadableAudio() {}

    func didTapUndownloadableSticker() {}

    func didTapBrokenVideo() {}

    func didTapBodyMedia(
        itemViewModel: CVItemViewModelImpl,
        attachment: ReferencedAttachment,
        imageView: UIView,
    ) {}

    func didTapGenericAttachment(
        _ attachment: CVComponentGenericAttachment,
    ) -> CVAttachmentTapAction { .default }

    func didTapQuotedReply(_ quotedReply: QuotedReplyModel) {}

    func didTapLinkPreview(url: URL) {}

    func didTapContactShare(_ contactShare: ContactShareViewModel) {}

    func didTapSendMessage(to phoneNumbers: [String]) {}

    func didTapSendInvite(toContactShare contactShare: ContactShareViewModel) {}

    func didTapAddToContacts(contactShare: ContactShareViewModel) {}

    func didTapStickerPack(_ stickerPackInfo: StickerPackInfo) {}

    func didTapGroupInviteLink(url: PossibleGroupInviteLinkUrl) {}

    func didTapProxyLink(url: URL) {}

    func didTapShowMessageDetail(_ itemViewModel: CVItemViewModelImpl) {}

    func willWrapGift(_ messageUniqueId: String) -> Bool { false }

    func willShakeGift(_ messageUniqueId: String) -> Bool { false }

    func willUnwrapGift(_ itemViewModel: CVItemViewModelImpl) {}

    func didTapGiftBadge(
        _ itemViewModel: CVItemViewModelImpl,
        profileBadge: ProfileBadge,
        isExpired: Bool,
        isRedeemed: Bool,
    ) {}

    func prepareMessageDetailForInteractivePresentation(_ itemViewModel: CVItemViewModelImpl) {}

    func beginCellAnimation(maximumDuration: TimeInterval) -> EndCellAnimation {
        return {}
    }

    var wallpaperBlurProvider: WallpaperBlurProvider? { nil }

    var selectionState: CVSelectionState { CVSelectionState() }

    func didTapPreviouslyVerifiedIdentityChange(_ address: SignalServiceAddress) {}

    func didTapUnverifiedIdentityChange(_ address: SignalServiceAddress) {}

    func didTapSessionRefreshMessage(_ message: TSErrorMessage) {}

    func didTapResendGroupUpdateForErrorMessage(_ errorMessage: TSErrorMessage) {}

    func didTapIndividualCall(_ call: TSCall) {}

    func didTapLearnMoreMissedCallFromBlockedContact(_ call: TSCall) {}

    func didTapGroupCall() {}

    func didTapPendingOutgoingMessage(_ message: TSOutgoingMessage) {}

    func didTapFailedMessage(_ message: TSMessage) {}

    func didTapGroupMigrationLearnMore() {}

    func didTapGroupInviteLinkPromotion() {}

    func didTapViewGroupDescription(newGroupDescription: String) {}

    func didTapNameEducation(type: SafetyTipsType) {}

    func didTapShowConversationSettings() {}

    func didTapShowConversationSettingsAndShowMemberRequests() {}

    func didTapBlockRequest(
        secretParams: GroupSecretParams,
        requesterName: String,
        requesterAci: Aci,
    ) {}

    func didTapShowUpgradeAppUI() {}

    func didTapUpdateSystemContact(
        _ address: SignalServiceAddress,
        newNameComponents: PersonNameComponents,
    ) {}

    func didTapPhoneNumberChange(aci: Aci, phoneNumberOld: String, phoneNumberNew: String) {}

    func didTapViewOnceAttachment(_ interaction: TSInteraction) {}

    func didTapViewOnceExpired(_ interaction: TSInteraction) {}

    func didTapContactName(thread: TSContactThread) {}

    func didTapUnknownThreadWarningGroup() {}
    func didTapUnknownThreadWarningContact() {}
    func didTapDeliveryIssueWarning(_ message: TSErrorMessage) {}

    func didTapActivatePayments() {}
    func didTapSendPayment() {}

    func didTapThreadMergeLearnMore(phoneNumber: String) {}

    func didTapReportSpamLearnMore() {}

    func didTapMessageRequestAcceptedOptions() {}

    func didTapJoinCallLinkCall(callLink: CallLink) {}

    func didTapViewVotes(poll: OWSPoll) {}

    func didTapViewPoll(pollInteractionUniqueId: String) {}

    func didTapVoteOnPoll(poll: OWSPoll, optionIndex: UInt32, isUnvote: Bool) {}

    func didTapViewPinnedMessage(pinnedMessageUniqueId: String) {}

    func didTapSafetyTips() {}

    func didTapReleaseNotesAnnouncementAction(action: RemoteAnnouncementModel.Manifest.Action) {}
}
