//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

protocol MessageActionsDelegate: AnyObject {
    func messageActionsShowDetailsForItem(_ itemViewModel: CVItemViewModelImpl)
    func messageActionsReplyToItem(_ itemViewModel: CVItemViewModelImpl)
    func messageActionsForwardItem(_ itemViewModel: CVItemViewModelImpl)
    func messageActionsStartedSelect(initialItem itemViewModel: CVItemViewModelImpl)
    func messageActionsDeleteItem(_ itemViewModel: CVItemViewModelImpl)
    func messageActionsSpeakItem(_ itemViewModel: CVItemViewModelImpl)
    func messageActionsStopSpeakingItem(_ itemViewModel: CVItemViewModelImpl)
    func messageActionsEditItem(_ itemViewModel: CVItemViewModelImpl)
    func messageActionsShowPaymentDetails(_ itemViewModel: CVItemViewModelImpl)
    func messageActionsEndPoll(_ itemViewModel: CVItemViewModelImpl)
    func messageActionsChangePinStatus(_ itemViewModel: CVItemViewModelImpl, pin: Bool)
    func messageActionsTellomiSaveToSavedMessages(_ itemViewModel: CVItemViewModelImpl)
}

// MARK: -

enum MessageActionBuilder {
    static func reply(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        return MessageAction(
            .reply,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_REPLY", comment: "Action sheet button title"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "reply"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_REPLY", comment: "Context menu button title"),
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsReplyToItem(itemViewModel)

            },
        )
    }

    static func copyText(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        return MessageAction(
            .copy,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_COPY_TEXT", comment: "Action sheet button title"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "copy_text"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_COPY", comment: "Context menu button title"),
            contextMenuAttributes: [],
            block: { _ in
                itemViewModel.copyTextAction()
            },
        )
    }

    static func showDetails(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        return MessageAction(
            .info,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_DETAILS", comment: "Action sheet button title"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "show_details"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_DETAILS", comment: "Context menu button title"),
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsShowDetailsForItem(itemViewModel)
            },
        )
    }

    static func deleteMessage(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        return MessageAction(
            .delete,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_DELETE_MESSAGE", comment: "Action sheet button title"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "delete_message"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_DELETE_MESSAGE", comment: "Context menu button title"),
            contextMenuAttributes: [.destructive],
            block: { [weak delegate] _ in
                delegate?.messageActionsDeleteItem(itemViewModel)
            },
        )
    }

    static func shareMedia(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        return MessageAction(
            .share,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_SHARE_MEDIA", comment: "Action sheet button title"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "share_media"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_SHARE_MEDIA", comment: "Context menu button title"),
            contextMenuAttributes: [],
            block: { sender in
                itemViewModel.shareMediaAction(sender: sender)
            },
        )
    }

    static func saveMedia(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        return MessageAction(
            .save,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_SAVE_MEDIA", comment: "Action sheet button title"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "save_media"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_SAVE_MEDIA", comment: "Context menu button title"),
            contextMenuAttributes: [],
            block: { _ in
                itemViewModel.saveMediaAction()
            },
        )
    }

    static func forwardMessage(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        return MessageAction(
            .forward,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_FORWARD_MESSAGE", comment: "Action sheet button title"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "forward_message"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_FORWARD_MESSAGE", comment: "Context menu button title"),
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsForwardItem(itemViewModel)
            },
        )
    }

    /// Tellomi：长按「收藏」，不开转发面板、直接存进「我的收藏」（#1174）
    static func tellomiSaveToSavedMessages(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        return MessageAction(
            .tellomiSave,
            accessibilityLabel: TellomiSavedMessagesStrings.saveAccessibilityLabel,
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "tellomi_save_to_saved_messages"),
            contextMenuTitle: TellomiSavedMessagesStrings.save,
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsTellomiSaveToSavedMessages(itemViewModel)
            },
        )
    }

    static func selectMessage(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        return MessageAction(
            .select,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_SELECT_MESSAGE", comment: "Action sheet accessibility label"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "select_message"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_SELECT_MESSAGE", comment: "Context menu button title"),
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsStartedSelect(initialItem: itemViewModel)
            },
        )
    }

    static func editMessage(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        return MessageAction(
            .edit,
            accessibilityLabel: NSLocalizedString("MESSAGE_ACTION_EDIT_MESSAGE", comment: "Action sheet edit message accessibility label"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "edit_message"),
            contextMenuTitle: NSLocalizedString("CONTEXT_MENU_EDIT_MESSAGE", comment: "Context menu edit button title"),
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsEditItem(itemViewModel)
            },
        )
    }

    static func showPaymentDetails(
        itemViewModel: CVItemViewModelImpl,
        delegate: MessageActionsDelegate,
    ) -> MessageAction {
        return MessageAction(
            .showPaymentDetails,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_PAYMENT_DETAILS", comment: "Action sheet button title"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "payment_details"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_PAYMENT_DETAILS", comment: "Context menu button title"),
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsShowPaymentDetails(itemViewModel)
            },
        )
    }

    static func speakMessage(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        MessageAction(
            .speak,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_SPEAK_MESSAGE", comment: "Action sheet accessibility label"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "speak_message"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_SPEAK_MESSAGE", comment: "Context menu button title"),
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsSpeakItem(itemViewModel)
            },
        )
    }

    static func stopSpeakingMessage(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> MessageAction {
        MessageAction(
            .stopSpeaking,
            accessibilityLabel: OWSLocalizedString("MESSAGE_ACTION_STOP_SPEAKING_MESSAGE", comment: "Action sheet accessibility label"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "stop_speaking_message"),
            contextMenuTitle: OWSLocalizedString("CONTEXT_MENU_STOP_SPEAKING_MESSAGE", comment: "Context menu button title"),
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsStopSpeakingItem(itemViewModel)
            },
        )
    }

    static func endPoll(
        itemViewModel: CVItemViewModelImpl,
        delegate: MessageActionsDelegate,
    ) -> MessageAction {
        return MessageAction(
            .endPoll,
            accessibilityLabel: OWSLocalizedString("POLL_DETAILS_END_POLL", comment: "Label for button to end a poll"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "end_poll"),
            contextMenuTitle: OWSLocalizedString("POLL_DETAILS_END_POLL", comment: "Label for button to end a poll"),
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsEndPoll(itemViewModel)
            },
        )
    }

    static func changePinStatus(
        itemViewModel: CVItemViewModelImpl,
        footerState: CVComponentFooter.State,
        delegate: MessageActionsDelegate,
    ) -> MessageAction {

        if footerState.isPinnedMessage {
            return MessageAction(
                .unpin,
                accessibilityLabel: OWSLocalizedString("PINNED_MESSAGE_UNPIN_ACTION_TITLE", comment: "Label for button to unpin a message"),
                accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "pin"),
                contextMenuTitle: OWSLocalizedString("PINNED_MESSAGE_UNPIN_ACTION_TITLE", comment: "Label for button to unpin a message"),
                contextMenuAttributes: [],
                block: { [weak delegate] _ in
                    delegate?.messageActionsChangePinStatus(itemViewModel, pin: false)
                },
            )
        }
        return MessageAction(
            .pin,
            accessibilityLabel: OWSLocalizedString("PINNED_MESSAGE_PIN_ACTION_TITLE", comment: "Label for button to pin a message"),
            accessibilityIdentifier: UIView.accessibilityIdentifier(containerName: "message_action", name: "pin"),
            contextMenuTitle: OWSLocalizedString("PINNED_MESSAGE_PIN_ACTION_TITLE", comment: "Label for button to pin a message"),
            contextMenuAttributes: [],
            block: { [weak delegate] _ in
                delegate?.messageActionsChangePinStatus(itemViewModel, pin: true)
            },
        )
    }
}

class MessageActions {

    private class func canLocalUserEditGroupAttributes(itemViewModel: CVItemViewModelImpl) -> Bool {
        // Tellomi (ADR-0081 §4.6, spec 3.1): this only gates pin / unpin. Anyone may pin — without permission the sheet offers only
        // "pin for me" — and a pin for me only can always be taken back; other pins still need the permission to unpin.
        if itemViewModel.renderItem.itemViewState.footerState?.isPinnedMessage == false {
            return true
        }
        if let rowId = itemViewModel.renderItem.interaction.sqliteRowId {
            let isPinnedForMe = SSKEnvironment.shared.databaseStorageRef.read { tx in
                TellomiPinsForMe.isPinnedForMe(interactionId: rowId, tx: tx)
            }
            if isPinnedForMe {
                return true
            }
        }

        guard let groupModel = itemViewModel.thread.groupModelIfGroupThread as? TSGroupModelV2 else {
            return true
        }

        if groupModel.groupMembership.isLocalUserFullMemberAndAdministrator {
            return true
        }

        return groupModel.access.attributes != .administrator && !groupModel.isAnnouncementsOnly
    }

    class func textActions(itemViewModel: CVItemViewModelImpl, shouldAllowMessageSendActions: Bool, delegate: MessageActionsDelegate) -> [MessageAction] {
        var actions: [MessageAction] = []

        let showDetailsAction = MessageActionBuilder.showDetails(itemViewModel: itemViewModel, delegate: delegate)
        actions.append(showDetailsAction)

        let deleteAction = MessageActionBuilder.deleteMessage(itemViewModel: itemViewModel, delegate: delegate)
        actions.append(deleteAction)

        if itemViewModel.canCopyOrShareOrSpeakText {
            let copyTextAction = MessageActionBuilder.copyText(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(copyTextAction)
        }

        if shouldAllowMessageSendActions {
            let replyAction = MessageActionBuilder.reply(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(replyAction)
        }

        if itemViewModel.canForwardMessage {
            actions.append(MessageActionBuilder.forwardMessage(itemViewModel: itemViewModel, delegate: delegate))
            // Tellomi：「收藏」（#1174），「我的收藏」自己的会话里不显示
            if !itemViewModel.thread.isNoteToSelf {
                actions.append(MessageActionBuilder.tellomiSaveToSavedMessages(itemViewModel: itemViewModel, delegate: delegate))
            }
        }

        let selectAction = MessageActionBuilder.selectMessage(itemViewModel: itemViewModel, delegate: delegate)
        actions.append(selectAction)

        if itemViewModel.canEditMessage, shouldAllowMessageSendActions {
            let editAction = MessageActionBuilder.editMessage(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(editAction)
        }

        if itemViewModel.canCopyOrShareOrSpeakText {
            // If the user started speaking a message and then turns of the "speak selection" OS setting,
            // we still want to let them turn it off.
            if AppEnvironment.shared.speechManagerRef.isSpeaking {
                let stopSpeakingAction = MessageActionBuilder.stopSpeakingMessage(itemViewModel: itemViewModel, delegate: delegate)
                actions.append(stopSpeakingAction)
            } else if UIAccessibility.isSpeakSelectionEnabled {
                let speakAction = MessageActionBuilder.speakMessage(itemViewModel: itemViewModel, delegate: delegate)
                actions.append(speakAction)
            }
        }

        if
            shouldAllowMessageSendActions,
            itemViewModel.componentState.giftBadge == nil,
            let footerState = itemViewModel.renderItem.itemViewState.footerState,
            canLocalUserEditGroupAttributes(itemViewModel: itemViewModel)
        {
            // Check can change pin
            let pinAction = MessageActionBuilder.changePinStatus(
                itemViewModel: itemViewModel,
                footerState: footerState,
                delegate: delegate,
            )
            actions.append(pinAction)
        }

        return actions
    }

    class func mediaActions(itemViewModel: CVItemViewModelImpl, shouldAllowMessageSendActions: Bool, delegate: MessageActionsDelegate) -> [MessageAction] {
        var actions: [MessageAction] = []

        let showDetailsAction = MessageActionBuilder.showDetails(itemViewModel: itemViewModel, delegate: delegate)
        actions.append(showDetailsAction)

        let deleteAction = MessageActionBuilder.deleteMessage(itemViewModel: itemViewModel, delegate: delegate)
        actions.append(deleteAction)

        if itemViewModel.canShareMedia {
            let shareMediaAction = MessageActionBuilder.shareMedia(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(shareMediaAction)
        }

        if itemViewModel.canSaveMedia {
            let saveMediaAction = MessageActionBuilder.saveMedia(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(saveMediaAction)
        }

        if shouldAllowMessageSendActions {
            let replyAction = MessageActionBuilder.reply(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(replyAction)
        }

        if itemViewModel.canForwardMessage {
            actions.append(MessageActionBuilder.forwardMessage(itemViewModel: itemViewModel, delegate: delegate))
            // Tellomi：「收藏」（#1174），「我的收藏」自己的会话里不显示
            if !itemViewModel.thread.isNoteToSelf {
                actions.append(MessageActionBuilder.tellomiSaveToSavedMessages(itemViewModel: itemViewModel, delegate: delegate))
            }
        }

        if itemViewModel.canEditMessage, shouldAllowMessageSendActions {
            let editAction = MessageActionBuilder.editMessage(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(editAction)
        }

        let selectAction = MessageActionBuilder.selectMessage(itemViewModel: itemViewModel, delegate: delegate)
        actions.append(selectAction)

        if
            shouldAllowMessageSendActions,
            itemViewModel.componentState.giftBadge == nil,
            let footerState = itemViewModel.renderItem.itemViewState.footerState,
            canLocalUserEditGroupAttributes(itemViewModel: itemViewModel)
        {
            let pinAction = MessageActionBuilder.changePinStatus(
                itemViewModel: itemViewModel,
                footerState: footerState,
                delegate: delegate,
            )
            actions.append(pinAction)
        }

        return actions
    }

    class func quotedMessageActions(itemViewModel: CVItemViewModelImpl, shouldAllowMessageSendActions: Bool, delegate: MessageActionsDelegate) -> [MessageAction] {
        var actions: [MessageAction] = []

        let showDetailsAction = MessageActionBuilder.showDetails(itemViewModel: itemViewModel, delegate: delegate)
        actions.append(showDetailsAction)

        let deleteAction = MessageActionBuilder.deleteMessage(itemViewModel: itemViewModel, delegate: delegate)
        actions.append(deleteAction)

        if itemViewModel.canCopyOrShareOrSpeakText {
            let copyTextAction = MessageActionBuilder.copyText(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(copyTextAction)
        }

        if shouldAllowMessageSendActions {
            let replyAction = MessageActionBuilder.reply(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(replyAction)
        }

        if itemViewModel.canForwardMessage {
            actions.append(MessageActionBuilder.forwardMessage(itemViewModel: itemViewModel, delegate: delegate))
            // Tellomi：「收藏」（#1174），「我的收藏」自己的会话里不显示
            if !itemViewModel.thread.isNoteToSelf {
                actions.append(MessageActionBuilder.tellomiSaveToSavedMessages(itemViewModel: itemViewModel, delegate: delegate))
            }
        }

        if itemViewModel.canEditMessage, shouldAllowMessageSendActions {
            let editAction = MessageActionBuilder.editMessage(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(editAction)
        }

        let selectAction = MessageActionBuilder.selectMessage(itemViewModel: itemViewModel, delegate: delegate)
        actions.append(selectAction)

        if
            shouldAllowMessageSendActions,
            itemViewModel.componentState.giftBadge == nil,
            let footerState = itemViewModel.renderItem.itemViewState.footerState,
            canLocalUserEditGroupAttributes(itemViewModel: itemViewModel)
        {
            let pinAction = MessageActionBuilder.changePinStatus(
                itemViewModel: itemViewModel,
                footerState: footerState,
                delegate: delegate,
            )
            actions.append(pinAction)
        }

        return actions
    }

    class func paymentActions(
        itemViewModel: CVItemViewModelImpl,
        shouldAllowMessageSendActions: Bool,
        delegate: MessageActionsDelegate,
    ) -> [MessageAction] {
        var actions: [MessageAction] = []

        let showDetailsAction = MessageActionBuilder.showDetails(
            itemViewModel: itemViewModel,
            delegate: delegate,
        )
        actions.append(showDetailsAction)

        let deleteAction = MessageActionBuilder.deleteMessage(
            itemViewModel: itemViewModel,
            delegate: delegate,
        )
        actions.append(deleteAction)

        let showPaymentDetailsAction = MessageActionBuilder.showPaymentDetails(
            itemViewModel: itemViewModel,
            delegate: delegate,
        )
        actions.append(showPaymentDetailsAction)

        if shouldAllowMessageSendActions {
            let replyAction = MessageActionBuilder.reply(
                itemViewModel: itemViewModel,
                delegate: delegate,
            )
            actions.append(replyAction)
        }

        let selectAction = MessageActionBuilder.selectMessage(
            itemViewModel: itemViewModel,
            delegate: delegate,
        )
        actions.append(selectAction)

        if
            shouldAllowMessageSendActions,
            itemViewModel.componentState.giftBadge == nil,
            let footerState = itemViewModel.renderItem.itemViewState.footerState,
            canLocalUserEditGroupAttributes(itemViewModel: itemViewModel)
        {
            let pinAction = MessageActionBuilder.changePinStatus(
                itemViewModel: itemViewModel,
                footerState: footerState,
                delegate: delegate,
            )
            actions.append(pinAction)
        }
        return actions
    }

    class func pollActions(
        itemViewModel: CVItemViewModelImpl,
        shouldAllowMessageSendActions: Bool,
        delegate: MessageActionsDelegate,
    ) -> [MessageAction] {
        var actions: [MessageAction] = []

        let showDetailsAction = MessageActionBuilder.showDetails(
            itemViewModel: itemViewModel,
            delegate: delegate,
        )
        actions.append(showDetailsAction)

        let deleteAction = MessageActionBuilder.deleteMessage(
            itemViewModel: itemViewModel,
            delegate: delegate,
        )
        actions.append(deleteAction)

        if shouldAllowMessageSendActions {
            let replyAction = MessageActionBuilder.reply(itemViewModel: itemViewModel, delegate: delegate)
            actions.append(replyAction)
        }

        let selectAction = MessageActionBuilder.selectMessage(
            itemViewModel: itemViewModel,
            delegate: delegate,
        )
        actions.append(selectAction)

        if
            let poll = itemViewModel.componentState.poll?.state.poll,
            poll.ownerIsLocalUser,
            !poll.isEnded,
            shouldAllowMessageSendActions
        {
            let endPollAction = MessageActionBuilder.endPoll(
                itemViewModel: itemViewModel,
                delegate: delegate,
            )
            actions.append(endPollAction)
        }

        if
            shouldAllowMessageSendActions,
            itemViewModel.componentState.giftBadge == nil,
            let footerState = itemViewModel.renderItem.itemViewState.footerState,
            canLocalUserEditGroupAttributes(itemViewModel: itemViewModel)
        {
            let pinAction = MessageActionBuilder.changePinStatus(
                itemViewModel: itemViewModel,
                footerState: footerState,
                delegate: delegate,
            )
            actions.append(pinAction)
        }

        return actions
    }

    class func infoMessageActions(itemViewModel: CVItemViewModelImpl, delegate: MessageActionsDelegate) -> [MessageAction] {
        let deleteAction = MessageActionBuilder.deleteMessage(itemViewModel: itemViewModel, delegate: delegate)
        let selectAction = MessageActionBuilder.selectMessage(itemViewModel: itemViewModel, delegate: delegate)
        return [deleteAction, selectAction]
    }
}

// MARK: - Tellomi（tellomi/tellomi#1174）

/// 「收藏」相关文案（47 种语言都有，照常走 `OWSLocalizedString`，`auto-genstrings` 才认得这些键）。
enum TellomiSavedMessagesStrings {
    static var save: String {
        OWSLocalizedString(
            "CONTEXT_MENU_FORWARD_MESSAGE_TELLOMI_SAVE",
            value: "Save",
            comment: "Tellomi (#1174): context menu button that saves a message into Saved Messages",
        )
    }

    static var saveAccessibilityLabel: String {
        OWSLocalizedString(
            "MESSAGE_ACTION_FORWARD_MESSAGE_TELLOMI_SAVE",
            value: "Save to Saved Messages",
            comment: "Tellomi (#1174): accessibility label for saving a message into Saved Messages",
        )
    }

    static var savedToast: String {
        OWSLocalizedString(
            "FORWARD_MESSAGE_TELLOMI_SAVED_TOAST",
            value: "Saved to Saved Messages. Tap to view.",
            comment: "Tellomi (#1174): toast after saving a message into Saved Messages; tapping it opens Saved Messages",
        )
    }

    /// 删除确认：只删「我的收藏」时说清楚删的是什么、已关联设备上的会不会一起删（需求 §3.2「删除」）。
    /// 选了别的会话（或不止一个）返回 nil，照上游的文案。
    static func deleteConfirmation(for threads: [TSThread], hasLinkedDevices: Bool) -> (title: String, message: String)? {
        guard threads.count == 1, threads[0].isNoteToSelf else {
            return nil
        }
        let title = OWSLocalizedString(
            "CONVERSATION_DELETE_CONFIRMATION_ALERT_TITLE_TELLOMI_SAVED_MESSAGES",
            value: "Delete Saved Messages?",
            comment: "Tellomi (#1174): title of the confirmation shown before deleting Saved Messages (the chat with yourself)",
        )
        let message = hasLinkedDevices
            ? OWSLocalizedString(
                "CONVERSATION_DELETE_CONFIRMATION_ALERT_MESSAGE_TELLOMI_SAVED_MESSAGES_LINKED_DEVICES",
                value: "Everything in Saved Messages will be deleted from this device and your linked devices. This can't be undone.",
                comment: "Tellomi (#1174): message of the confirmation shown before deleting Saved Messages, when the account has linked devices",
            )
            : OWSLocalizedString(
                "CONVERSATION_DELETE_CONFIRMATION_ALERT_MESSAGE_TELLOMI_SAVED_MESSAGES",
                value: "Everything in Saved Messages will be deleted from this device. This can't be undone.",
                comment: "Tellomi (#1174): message of the confirmation shown before deleting Saved Messages, when there are no linked devices",
            )
        return (title, message)
    }
}
