//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
import UIKit

extension ConversationViewController {

    /// Tellomi（A-07）：菜单收起（0.25 s）之后再念回应公告。
    static let tellomiReactionAnnouncementDelay: TimeInterval = 0.5

    /// Tellomi（A-07）：读屏念的那句——加回应「已回应 ❤️」，收回自己的回应「已取消回应」。
    static func tellomiReactionAnnouncement(emoji: String, isRemoving: Bool) -> String {
        if isRemoving {
            return OWSLocalizedString(
                "TELLOMI_REACTION_REMOVED_ANNOUNCEMENT",
                comment: "Tellomi (interaction audit A-07): read out by VoiceOver after taking a reaction back.",
            )
        }
        let format = OWSLocalizedString(
            "TELLOMI_REACTED_WITH_ANNOUNCEMENT_FORMAT",
            comment: "Tellomi (interaction audit A-07): read out by VoiceOver after choosing a reaction. Embeds {{the emoji}}.",
        )
        return String(format: format, emoji)
    }

    func presentContextMenu(
        with messageActions: [MessageAction],
        focusedOn cell: UICollectionViewCell,
        andModel model: CVItemViewModelImpl,
    ) {
        let keyboardActive = inputToolbar?.isInputViewFirstResponder ?? false
        let interaction = ChatHistoryContextMenuInteraction(delegate: self, itemViewModel: model, thread: thread, messageActions: messageActions, initiatingGestureRecognizer: collectionViewContextMenuGestureRecognizer, keyboardWasActive: keyboardActive)
        // Tellomi（交互审计 A-06，owner 2026-09-26 Q-05 = A）：长按不收键盘，菜单排在键盘上面。
        if keyboardActive {
            interaction.keyboardFrameInWindow = view.convert(keyboardLayoutGuide.layoutFrame, to: nil)
        }
        collectionViewActiveContextMenuInteraction = interaction
        cell.addInteraction(interaction)
        let cellCenterPoint = cell.frame.center
        let screenPoint = self.collectionView.convert(cellCenterPoint, from: cell)
        var presentImmediately = false
        if collectionViewContextMenuSecondaryClickRecognizer.state == .ended {
            presentImmediately = true
        }
        interaction.initiateContextMenuGesture(locationInView: screenPoint, presentImmediately: presentImmediately)
    }

    public var isPresentingContextMenu: Bool {
        if let interaction = viewState.collectionViewActiveContextMenuInteraction, interaction.contextMenuVisible {
            return true
        }

        return false
    }

    public func dismissMessageContextMenu(animated: Bool) {
        if let collectionViewActiveContextMenuInteraction = self.collectionViewActiveContextMenuInteraction {
            collectionViewActiveContextMenuInteraction.dismissMenu(animated: animated, completion: { })
        }
    }

    func dismissMessageContextMenuIfNecessary() {
        if shouldDismissMessageContextMenu {
            dismissMessageContextMenu(animated: true)
        }
    }

    var shouldDismissMessageContextMenu: Bool {
        guard let collectionViewActiveContextMenuInteraction = self.collectionViewActiveContextMenuInteraction else {
            return false
        }

        let messageActionInteractionId = collectionViewActiveContextMenuInteraction.itemViewModel.interaction.uniqueId
        // Check whether there is still a view item for this interaction.
        return self.indexPath(forInteractionUniqueId: messageActionInteractionId) == nil
    }

    public func reloadReactionsDetailSheetWithSneakyTransaction() {
        AssertIsOnMainThread()

        guard let reactionsDetailSheet = self.reactionsDetailSheet else {
            return
        }

        let messageId = reactionsDetailSheet.messageId

        guard
            let indexPath = self.indexPath(forInteractionUniqueId: messageId),
            let renderItem = self.renderItem(forIndex: indexPath.row)
        else {
            // The message no longer exists, dismiss the sheet.
            dismissReactionsDetailSheet(animated: true)
            return
        }
        guard
            let reactionState = renderItem.reactionState,
            reactionState.hasReactions
        else {
            // There are no longer reactions on this message, dismiss the sheet.
            dismissReactionsDetailSheet(animated: true)
            return
        }

        // Update the detail sheet with the latest reaction
        // state, in case the reactions have changed.
        SSKEnvironment.shared.databaseStorageRef.read { tx in
            reactionsDetailSheet.setReactionState(reactionState, transaction: tx)
        }
    }

    public func dismissReactionsDetailSheet(animated: Bool) {
        AssertIsOnMainThread()

        guard let reactionsDetailSheet = self.reactionsDetailSheet else {
            return
        }

        reactionsDetailSheet.dismiss(animated: animated) {
            self.reactionsDetailSheet = nil
        }
    }
}

extension ConversationViewController: ContextMenuInteractionDelegate {

    public func contextMenuInteraction(
        _ interaction: ContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint,
    ) -> ContextMenuConfiguration? {

        return ContextMenuConfiguration(identifier: UUID() as NSCopying, actionProvider: { [weak self] _ in

            guard let self else {
                owsFailDebug("conversationViewController was unexpectedly nil")
                return ContextMenu([])
            }

            var contextMenuActions: [ContextMenuAction] = []
            if let actions = self.collectionViewActiveContextMenuInteraction?.messageActions {

                let actionOrder = MessageAction.MessageActionType.allCases
                    .sorted { $0.priority < $1.priority }

                for type in actionOrder {
                    let actionWithType = actions.first { $0.actionType == type }
                    if let messageAction = actionWithType {
                        contextMenuActions.append(ContextMenuAction(
                            title: messageAction.contextMenuTitle,
                            image: messageAction.contextMenuIcon,
                            attributes: messageAction.contextMenuAttributes,
                            handler: { _ in
                                messageAction.block(nil)
                            },
                        ))
                    }
                }
            }

            return ContextMenu(contextMenuActions)
        })
    }

    public func contextMenuInteraction(
        _ interaction: ContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: ContextMenuConfiguration,
    ) -> ContextMenuTargetedPreview? {

        guard let contextInteraction = interaction as? ChatHistoryContextMenuInteraction else {
            owsFailDebug("Expected ChatHistoryContextMenuInteraction.")
            return nil
        }

        guard let cell = contextInteraction.view as? CVCell else {
            owsFailDebug("Expected context interaction view to be of CVCell type")
            return nil
        }

        guard let componentView = cell.componentView else {
            owsFailDebug("Expected cell to have component view")
            return nil
        }

        var accessories = cell.rootComponent?.contextMenuAccessoryViews(componentView: componentView) ?? []

        // Add reaction bar if necessary
        if thread.canSendReactionToThread, shouldShowReactionPickerForInteraction(contextInteraction.itemViewModel.interaction) {
            let reactionBarAccessory = ContextMenuReactionBarAccessory(thread: self.thread, itemViewModel: contextInteraction.itemViewModel)
            reactionBarAccessory.didSelectReactionHandler = { [weak self] (message: TSMessage, reaction: String, isRemoving: Bool, flyInSource: ReactionFlyIn.Source?) in

                guard let self else {
                    owsFailDebug("conversationViewController was unexpectedly nil")
                    return
                }

                // Tellomi（交互审计 A-07）：表情先在原处拿起来，等回应画出来再飞过去。
                if let flyInSource {
                    self.beginReactionFlyIn(messageUniqueId: message.uniqueId, emoji: reaction, source: flyInSource)
                }

                SSKEnvironment.shared.databaseStorageRef.asyncWrite { transaction in
                    ReactionManager.localUserReacted(
                        to: message.uniqueId,
                        emoji: reaction,
                        isRemoving: isRemoving,
                        tx: transaction,
                    )
                }

                // Tellomi（交互审计 A-07，「读屏公告『已回应 ❤️』」）：胶囊变化本身读屏听不到，念出这次回应做了什么。
                // 菜单收起会让 VoiceOver 的焦点跳回，紧跟着的公告会被打断，所以等菜单收完再念。
                if UIAccessibility.isVoiceOverRunning {
                    let announcement = Self.tellomiReactionAnnouncement(emoji: reaction, isRemoving: isRemoving)
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.tellomiReactionAnnouncementDelay) {
                        UIAccessibility.post(notification: .announcement, argument: announcement)
                    }
                }
            }
            accessories.append(reactionBarAccessory)
        }

        var alignment: ContextMenuTargetedPreview.Alignment = .center
        let interactionType = contextInteraction.itemViewModel.interaction.interactionType
        let isRTL = CurrentAppContext().isRTL
        if interactionType == .incomingMessage {
            alignment = isRTL ? .right : .left
        } else if interactionType == .outgoingMessage {
            alignment = isRTL ? .left : .right
        }

        if let componentView = cell.componentView, let contentView = componentView.contextMenuContentView?() {
            let preview = ContextMenuTargetedPreview(view: contentView, alignment: alignment, accessoryViews: accessories)
            preview?.auxiliaryView = componentView.contextMenuAuxiliaryContentView?()
            return preview
        } else {
            return ContextMenuTargetedPreview(view: cell, alignment: alignment, accessoryViews: accessories)

        }
    }

    public func contextMenuInteraction(_ interaction: ContextMenuInteraction, willDisplayMenuForConfiguration: ContextMenuConfiguration) {
        // Reset scroll view pan gesture recognizer, so CV does not scroll behind context menu post presentation on user swipe
        collectionView.panGestureRecognizer.isEnabled = false
        collectionView.panGestureRecognizer.isEnabled = true

        if let contextInteraction = interaction as? ChatHistoryContextMenuInteraction, let cell = contextInteraction.view as? CVCell, let componentView = cell.componentView {
            componentView.contextMenuPresentationWillBegin?()
        }

        // Tellomi（交互审计 A-06，Q-05 = A）：不再收键盘。原来先收、关菜单再弹回，底部来回跳两次。
    }

    public func contextMenuInteraction(_ interaction: ContextMenuInteraction, willEndForConfiguration: ContextMenuConfiguration) {

    }

    public func contextMenuInteraction(_ interaction: ContextMenuInteraction, didEndForConfiguration: ContextMenuConfiguration) {
        if let contextInteraction = interaction as? ChatHistoryContextMenuInteraction, let cell = contextInteraction.view as? CVCell, let componentView = cell.componentView {
            componentView.contextMenuPresentationDidEnd?()

            // Tellomi（交互审计 A-06，Q-05 = A）：键盘一直在。菜单项弹出了新页面才收键盘（和上游收起后的结果一样）；
            // 键盘被别的输入框拿走了（展开的表情面板里搜索过）就弹回输入框。
            if contextInteraction.keyboardWasActive {
                if self.presentedViewController == nil {
                    if !(inputToolbar?.isInputViewFirstResponder ?? false) {
                        popKeyBoard()
                    }
                } else {
                    dismissKeyBoard()
                    // If we're not going to restore the keyboard, update
                    // chat history layout.
                    self.loadCoordinator.enqueueReload()
                }
            }
        }

        collectionViewActiveContextMenuInteraction = nil

        // Tellomi（交互审计 A-07）：菜单收完了；回应要是已经画出来，就在这里起飞。
        landPendingReactionFlyInIfPossible()
    }

    public func shouldShowReactionPickerForInteraction(_ interaction: TSInteraction) -> Bool {
        if threadViewModel.hasPendingMessageRequest {
            return false
        }

        guard threadViewModel.isLocalUserFullMemberOfThread else {
            return false
        }

        guard !threadViewModel.threadRecord.isTerminatedGroup else {
            return false
        }

        switch interaction {
        case let outgoingMessage as TSOutgoingMessage:
            if outgoingMessage.wasRemotelyDeleted { return false }

            switch outgoingMessage.messageState {
            case .failed, .sending, .pending:
                return false
            default:
                return true
            }
        case let incomingMessage as TSIncomingMessage:
            if incomingMessage.wasRemotelyDeleted { return false }

            return true
        default:
            return false
        }
    }

}
