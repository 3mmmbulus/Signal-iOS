//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI

// MARK: -

private struct ThreadContextualAction {
    let style: UIContextualAction.Style
    let color: UIColor
    let imageFilled: UIImage
    let imageStroked: UIImage
    let title: String
    let action: @MainActor () -> Void
    /// Tellomi（交互审计 A-39）：有值时，长按菜单里把这一项做成就地展开的子菜单；左滑按钮没有子菜单，仍走 [action]。
    var contextMenuChildren: [UIMenuElement]?
    /// Tellomi（交互审计 A-24）：左滑按钮点了以后这一行就离开列表（归档 / 取消归档）：告诉系统做完了（`completion(true)`），
    /// 行跟着滑走，不先弹回原位再消失。其余（置顶、静音、已读、要确认的删除）行还在，照旧弹回。
    var completesSwipe = false
}

// MARK: -

protocol ThreadContextualActionProvider: AnyObject {
    func threadContextualActionShouldCloseThreadIfActive(threadViewModel: ThreadViewModel)
    func threadContextualActionDidComplete()
    func deleteThreadWithConfirmation(threadViewModel: ThreadViewModel)
    func toggleThreadIsArchived(threadViewModel: ThreadViewModel)
}

extension ThreadContextualActionProvider where Self: UIViewController {

    func leadingSwipeActionsConfiguration(threadViewModel: ThreadViewModel) -> UISwipeActionsConfiguration? {
        AssertIsOnMainThread()

        let actions: [ThreadContextualAction] = [
            readStateContextualAction(threadViewModel: threadViewModel),
            pinnedStateContextualAction(threadViewModel: threadViewModel),
        ]

        return UISwipeActionsConfiguration(actions: actions.map { action in
            makeUIContextualAction(threadContextualAction: action)
        })
    }

    func trailingSwipeActionsConfiguration(threadViewModel: ThreadViewModel) -> UISwipeActionsConfiguration? {
        AssertIsOnMainThread()

        let actions: [ThreadContextualAction] = [
            archiveStateContextualAction(threadViewModel: threadViewModel),
            deleteContextualAction(threadViewModel: threadViewModel),
            muteStateContextualAction(threadViewModel: threadViewModel),
        ]

        return UISwipeActionsConfiguration(actions: actions.map { action in
            makeUIContextualAction(threadContextualAction: action)
        })
    }

    private func makeUIContextualAction(threadContextualAction action: ThreadContextualAction) -> UIContextualAction {
        return ContextualActionBuilder.makeContextualAction(
            style: action.style,
            color: action.color,
            image: action.imageFilled,
            title: action.title,
            handler: { completion in
                MainActor.assumeIsolated {
                    action.action()
                    completion(action.completesSwipe)
                }
            },
        )
    }

    // MARK: -

    func contextMenuActions(threadViewModel: ThreadViewModel) -> [UIMenuElement] {
        AssertIsOnMainThread()

        var actions: [ThreadContextualAction] = [
            readStateContextualAction(threadViewModel: threadViewModel),
            muteStateContextualAction(threadViewModel: threadViewModel),
            pinnedStateContextualAction(threadViewModel: threadViewModel),
            archiveStateContextualAction(threadViewModel: threadViewModel),
        ]

        let tsAccountManager = DependenciesBridge.shared.tsAccountManager
        if
            let groupThread = threadViewModel.threadRecord as? TSGroupThread,
            let groupModel = groupThread.groupModel as? TSGroupModelV2,
            let localAci = tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aci,
            groupModel.groupMembership.isLocalUserFullOrInvitedMember
        {
            actions.append(leaveGroupContextualAction(
                threadViewModel: threadViewModel,
                groupModel: groupModel,
                groupThread: groupThread,
                localAci: localAci,
            ))
        }

        actions.append(deleteContextualAction(threadViewModel: threadViewModel))

        return actions.map { action in
            makeMenuElement(threadContextualAction: action)
        }
    }

    private func makeMenuElement(
        threadContextualAction action: ThreadContextualAction,
    ) -> UIMenuElement {
        if let children = action.contextMenuChildren {
            return UIMenu(title: action.title, image: action.imageStroked, children: children)
        }

        let attributes: UIMenuElement.Attributes = switch action.style {
        case .normal: []
        case .destructive: [.destructive]
        @unknown default: []
        }

        return UIAction(
            title: action.title,
            image: action.imageStroked,
            attributes: attributes,
            handler: { _ in
                MainActor.assumeIsolated {
                    action.action()
                }
            },
        )
    }

    // MARK: -

    private func pinnedStateContextualAction(threadViewModel: ThreadViewModel) -> ThreadContextualAction {
        if threadViewModel.isPinned {
            return ThreadContextualAction(
                style: .normal,
                color: UIColor(rgbHex: 0xff990a),
                imageFilled: .pinSlashFill,
                imageStroked: .pinSlash,
                title: CommonStrings.unpinAction,
            ) { [weak self] in
                self?.unpinThread(threadViewModel: threadViewModel)
            }
        } else {
            return ThreadContextualAction(
                style: .normal,
                color: UIColor(rgbHex: 0xff990a),
                imageFilled: .pinFill,
                imageStroked: .pin,
                title: CommonStrings.pinAction,
            ) { [weak self] in
                self?.pinThread(threadViewModel: threadViewModel)
            }
        }
    }

    private func readStateContextualAction(threadViewModel: ThreadViewModel) -> ThreadContextualAction {
        if threadViewModel.hasUnreadMessages {
            return ThreadContextualAction(
                style: .normal,
                color: UIColor.Signal.ultramarine,
                imageFilled: .chatCheckFill,
                imageStroked: .chatCheck,
                title: CommonStrings.readAction,
            ) { [weak self] in
                self?.markThreadAsRead(threadViewModel: threadViewModel)
            }
        } else {
            return ThreadContextualAction(
                style: .normal,
                color: UIColor.Signal.ultramarine,
                imageFilled: .chatBadgeFill,
                imageStroked: .chatBadge,
                title: CommonStrings.unreadAction,
            ) { [weak self] in
                self?.markThreadAsUnread(threadViewModel: threadViewModel)
            }
        }
    }

    private func muteStateContextualAction(threadViewModel: ThreadViewModel) -> ThreadContextualAction {
        if threadViewModel.isMuted {
            return ThreadContextualAction(
                style: .normal,
                color: UIColor.Signal.indigo,
                imageFilled: .bellFill,
                imageStroked: .bell,
                title: CommonStrings.unmuteButton,
                action: { [weak self] in
                    self?.unmuteThread(threadViewModel: threadViewModel)
                },
            )
        } else {
            return ThreadContextualAction(
                style: .normal,
                color: UIColor.Signal.indigo,
                imageFilled: .bellSlashFill,
                imageStroked: .bellSlash,
                title: CommonStrings.muteButton,
                action: {
                    // Tellomi（owner 2026-10-16 定，照 Telegram iOS 会话列表左滑 `setPeerMuted` → `togglePeerMuted`）：
                    // 左滑「静音」直接静音（一直静音），不再从屏幕底部弹时长选择；要选时长用长按菜单（就地展开的子菜单）。
                    ConversationMuteManager().mute(threadViewModel, choice: .forever)
                },
                contextMenuChildren: muteDurationMenuChildren(threadViewModel: threadViewModel),
            )
        }
    }

    private func deleteContextualAction(threadViewModel: ThreadViewModel) -> ThreadContextualAction {
        return ThreadContextualAction(
            style: .destructive,
            color: .Signal.red,
            imageFilled: .trashFill,
            imageStroked: .trash,
            title: CommonStrings.deleteButton,
        ) { [weak self] in
            self?.deleteThreadWithConfirmation(threadViewModel: threadViewModel)
        }
    }

    private func archiveStateContextualAction(threadViewModel: ThreadViewModel) -> ThreadContextualAction {
        if threadViewModel.isArchived {
            return ThreadContextualAction(
                style: .normal,
                color: Theme.isDarkThemeEnabled ? .ows_gray45 : .ows_gray25,
                imageFilled: .archiveUpFill,
                imageStroked: .archiveUp,
                title: CommonStrings.unarchiveAction,
                action: { [weak self] in
                    self?.toggleThreadIsArchived(threadViewModel: threadViewModel)
                },
                completesSwipe: true,
            )
        } else {
            return ThreadContextualAction(
                style: .normal,
                color: Theme.isDarkThemeEnabled ? .ows_gray45 : .ows_gray25,
                imageFilled: .archiveFill,
                imageStroked: .archive,
                title: CommonStrings.archiveAction,
                action: { [weak self] in
                    self?.toggleThreadIsArchived(threadViewModel: threadViewModel)
                },
                completesSwipe: true,
            )
        }
    }

    private func leaveGroupContextualAction(
        threadViewModel: ThreadViewModel,
        groupModel: TSGroupModelV2,
        groupThread: TSGroupThread,
        localAci: Aci,
    ) -> ThreadContextualAction {
        return ThreadContextualAction(
            style: .destructive,
            color: .Signal.label, // Not used: only relevant for swipe action
            imageFilled: .leave, // Not used: only relevant for swipe action
            imageStroked: .leave,
            title: CommonStrings.leaveButton,
            action: {
                LeaveGroupCoordinator(
                    groupThread: groupThread,
                    groupModel: groupModel,
                    localAci: localAci,
                    onSuccess: {},
                ).startLeaveGroupFlow(rootViewController: self)
            },
        )
    }

    // MARK: -

    func toggleThreadIsArchived(threadViewModel: ThreadViewModel) {
        AssertIsOnMainThread()

        let wasPinned = threadViewModel.isPinned
        let didArchive = tellomiSetArchived(threadViewModel: threadViewModel)
        if didArchive {
            tellomiPresentArchivedUndo(
                threadUniqueIds: [threadViewModel.threadUniqueId],
                pinnedThreadUniqueIds: wasPinned ? [threadViewModel.threadUniqueId] : [],
            )
        }
    }

    /// 归档或取消归档（原来的 `toggleThreadIsArchived` 本体）；返回 true 表示这次是归档。多选一次归档好几个时，
    /// 由多选那边统一出一条「N 个聊天已存档 · 撤销」，不一个一个出。
    @discardableResult
    func tellomiSetArchived(threadViewModel: ThreadViewModel) -> Bool {
        AssertIsOnMainThread()

        let databaseStorage = SSKEnvironment.shared.databaseStorageRef
        let pinnedThreadManager = DependenciesBridge.shared.pinnedThreadManager

        threadContextualActionShouldCloseThreadIfActive(threadViewModel: threadViewModel)

        let isArchived = !threadViewModel.isArchived

        databaseStorage.write { transaction in
            if isArchived {
                pinnedThreadManager.unpinThread(
                    threadViewModel.threadRecord,
                    updateStorageService: true,
                    tx: transaction,
                )
            }
            threadViewModel.threadRecord.updateWith(
                isArchived: isArchived,
                updateStorageService: true,
                transaction: transaction,
            )
        }

        threadContextualActionDidComplete()
        return isArchived
    }

    /// Tellomi（交互审计 A-24，照 Telegram iOS 归档后的 `UndoOverlayController(.archivedChat, undo: true)`、安卓的 Snackbar）：
    /// 归档后在底栏上方出「聊天已存档 · 撤销」，5 秒后自己收起；点「撤销」移回原处（原来置顶的重新置顶）。
    func tellomiPresentArchivedUndo(threadUniqueIds: [String], pinnedThreadUniqueIds: [String]) {
        guard !threadUniqueIds.isEmpty, isViewLoaded else { return }
        let text: String
        if threadUniqueIds.count == 1 {
            text = OWSLocalizedString("TELLOMI_CHAT_LIST_ARCHIVED_TOAST", comment: "Toast shown above the tab bar after a chat is archived from the chat list. Has an Undo button.")
        } else {
            text = String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("TELLOMI_CHAT_LIST_ARCHIVED_TOAST_MULTIPLE_FORMAT", comment: "Toast shown above the tab bar after several chats are archived at once. Embeds {{number of chats}}. Has an Undo button."),
                OWSFormat.formatInt(threadUniqueIds.count),
            )
        }
        let toast = ToastController(text: text)
        toast.tellomiAction = (
            title: OWSLocalizedString("TELLOMI_CHAT_LIST_ARCHIVED_UNDO", comment: "Button on the 'chat archived' toast that moves the chat back out of the archive."),
            handler: { [weak self] in
                self?.tellomiUndoArchive(threadUniqueIds: threadUniqueIds, pinnedThreadUniqueIds: pinnedThreadUniqueIds)
            },
        )
        toast.presentToastView(from: .bottom, of: view, inset: view.safeAreaInsets.bottom + 8, dismissAfter: .seconds(5))
    }

    private func tellomiUndoArchive(threadUniqueIds: [String], pinnedThreadUniqueIds: [String]) {
        let threadStore = DependenciesBridge.shared.threadStore
        let pinnedThreadManager = DependenciesBridge.shared.pinnedThreadManager
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            for threadUniqueId in threadUniqueIds {
                guard let thread = threadStore.fetchThread(uniqueId: threadUniqueId, tx: tx) else { continue }
                thread.updateWith(isArchived: false, updateStorageService: true, transaction: tx)
                if pinnedThreadUniqueIds.contains(threadUniqueId) {
                    // 置顶满了就算了：撤销只是把它移回聊天列表
                    try? pinnedThreadManager.pinThread(thread, updateStorageService: true, tx: tx)
                }
            }
        }
        threadContextualActionDidComplete()
    }

    func deleteThreadWithConfirmation(threadViewModel: ThreadViewModel) {
        AssertIsOnMainThread()
        let db = DependenciesBridge.shared.db
        let threadDeletionManager = DependenciesBridge.shared.threadDeletionManager
        let tsAccountManager = DependenciesBridge.shared.tsAccountManager

        // Tellomi：删「我的收藏」时换成说清楚的文案（#1174）
        let savedMessagesConfirmation = db.read { tx in
            TellomiSavedMessagesStrings.deleteConfirmation(
                for: [threadViewModel.threadRecord],
                hasLinkedDevices: DependenciesBridge.shared.deviceStore.hasLinkedDevices(tx: tx),
            )
        }
        let alert = ActionSheetController(
            title: savedMessagesConfirmation?.title ?? OWSLocalizedString(
                "CONVERSATION_DELETE_CONFIRMATION_ALERT_TITLE",
                comment: "Title for the 'conversation delete confirmation' alert.",
            ),
            message: savedMessagesConfirmation?.message ?? OWSLocalizedString(
                "CONVERSATION_DELETE_CONFIRMATION_ALERT_MESSAGE",
                comment: "Message for the 'conversation delete confirmation' alert.",
            ),
        )
        alert.addAction(ActionSheetAction(
            title: CommonStrings.deleteButton,
            style: .destructive,
        ) { [weak self] _ in
            guard let self else { return }

            threadContextualActionShouldCloseThreadIfActive(threadViewModel: threadViewModel)

            ModalActivityIndicatorViewController.present(
                fromViewController: self,
                title: CommonStrings.deletingModal,
            ) { [weak self] modal in
                guard let self else { return }

                await db.awaitableWrite { tx in
                    let localIdentifiers = tsAccountManager.localIdentifiers(tx: tx).owsFailUnwrap("never registered")
                    threadDeletionManager.deleteThreads(
                        [threadViewModel.threadRecord],
                        sendDeleteForMeSyncMessage: true,
                        updateStorageService: true,
                        localIdentifiers: localIdentifiers,
                        tx: tx,
                    )
                }

                modal.dismiss {
                    self.threadContextualActionDidComplete()
                }
            }
        })
        alert.addAction(OWSActionSheets.cancelAction)

        presentActionSheet(alert)
    }

    func markThreadAsRead(threadViewModel: ThreadViewModel) {
        AssertIsOnMainThread()

        SSKEnvironment.shared.databaseStorageRef.write { transaction in
            threadViewModel.threadRecord.markAllAsRead(updateStorageService: true, transaction: transaction)
        }
    }

    private func markThreadAsUnread(threadViewModel: ThreadViewModel) {
        AssertIsOnMainThread()

        SSKEnvironment.shared.databaseStorageRef.write { transaction in
            threadViewModel.threadRecord.updateWith(isMarkedUnread: true, updateStorageService: true, transaction: transaction)
        }
    }

    /// Tellomi（交互审计 A-39）：长按菜单里的「静音」就地展开时长，不再先收起菜单、再从屏幕底部另弹一个选择面板。
    /// 左滑的「静音」按钮没有子菜单，直接一直静音（owner 2026-10-16 定，照 Telegram）。
    private func muteDurationMenuChildren(threadViewModel: ThreadViewModel) -> [UIMenuElement] {
        let muteManager = ConversationMuteManager()
        return ConversationMuteChoice.Option.all.compactMap { option -> UIMenuElement? in
            let choice: ConversationMuteChoice
            switch option {
            case .preset(let preset):
                choice = .preset(preset)
            case .forever:
                choice = .forever
            case .custom:
                return nil
            }
            return UIAction(title: option.title) { _ in
                MainActor.assumeIsolated {
                    muteManager.mute(threadViewModel, choice: choice)
                }
            }
        }
    }

    private func unmuteThread(threadViewModel: ThreadViewModel) {
        AssertIsOnMainThread()
        ConversationMuteManager().unmute(threadViewModel)
    }

    private func pinThread(threadViewModel: ThreadViewModel) {
        AssertIsOnMainThread()

        do throws(TooManyPinnedThreadsError) {
            try SSKEnvironment.shared.databaseStorageRef.write { (tx) throws(TooManyPinnedThreadsError) in
                try DependenciesBridge.shared.pinnedThreadManager.pinThread(
                    threadViewModel.threadRecord,
                    updateStorageService: true,
                    tx: tx,
                )
            }
        } catch {
            let format = OWSLocalizedString(
                "PINNED_CONVERSATION_LIMIT",
                tableName: "PluralAware",
                comment: "An explanation that you have already pinned the maximum number of conversations. Embeds {{ the maximum number of pinned conversations }}.",
            )
            OWSActionSheets.showActionSheet(title: String.localizedStringWithFormat(
                format,
                Int(clamping: PinnedThreads.maxPinnedThreads),
            ))
        }
    }

    private func unpinThread(threadViewModel: ThreadViewModel) {
        AssertIsOnMainThread()

        SSKEnvironment.shared.databaseStorageRef.write { transaction in
            DependenciesBridge.shared.pinnedThreadManager.unpinThread(
                threadViewModel.threadRecord,
                updateStorageService: true,
                tx: transaction,
            )
        }
    }
}
