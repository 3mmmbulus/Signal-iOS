//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1519 M-4）：会话输入框里写的字，长按发送键定时发送。
///
/// 照 Telegram 两端（只读，代码是自己写的）：长按发送键 → 发送键左边是「发出去是什么样」的文字气泡，下面一个菜单
/// （iOS `ChatSendMessageContextScreen` 的 `MessageItemView`，安卓 `MessageSendPreview`），里面「定时发送」，
/// 收藏里是「设置提醒」→ 选时间 → 排好，打开这个会话的定时消息。改消息时没有（TG 安卓 `editingMessageObject == null`）。
/// 「静音发送」「对方上线时发送」不做（spec D4）。
extension ConversationViewController {

    func tellomiPresentTextSendPreview(from button: UIButton) {
        // 同上游发送：先把键盘的自动更正接受了，预览、定时的是同一段字。
        inputToolbar?.acceptAutocorrectSuggestion()
        guard
            hasViewWillAppearEverBegun,
            let inputToolbar,
            inputToolbar.editTarget == nil,
            inputToolbar.canSendTextMessage,
            let messageBody = inputToolbar.messageBodyForSending,
            !messageBody.text.isEmpty
        else {
            return
        }
        let text = SSKEnvironment.shared.databaseStorageRef.read { tx in
            messageBody.hydrating(mentionHydrator: ContactsMentionHydrator.mentionHydrator(transaction: tx)).asPlaintext()
        }
        let schedule = TellomiSendPreviewViewController.Action(
            title: TellomiScheduleTimeSheet.title(isReminder: thread.isNoteToSelf),
            image: UIImage(systemName: "calendar.badge.clock"),
            keepsPresented: false,
        ) { [weak self] in
            self?.tellomiPresentTextScheduleSheet()
        }
        let preview = TellomiSendPreviewViewController(
            tiles: [],
            caption: text,
            captionAboveMedia: false,
            bubbleColor: viewState.conversationStyle.bubbleChatColorOutgoing,
            actions: [schedule],
            sourceButton: button,
            onSend: { [weak self] in self?.sendButtonPressed() },
        )
        present(preview, animated: false)
    }

    private func tellomiPresentTextScheduleSheet() {
        // 排满了（一个会话 100 条）就先说，不用选完时间才知道。
        guard tellomiScheduledMessageCapacity() > 0 else {
            OWSActionSheets.showActionSheet(message: TellomiScheduledMessageSender.ScheduleError.tooManyScheduled.localizedDescription)
            return
        }
        let sheet = TellomiScheduleTimeSheet(isReminder: thread.isNoteToSelf) { [weak self] date in
            Task { await self?.tellomiScheduleTextMessage(at: date) }
        }
        sheet.present(from: self)
    }

    /// 同 `tryToSendTextMessage` 的前半段（拉黑先解除、安全码先确认），然后排成定时消息：输入框、引用、草稿照发送一样清掉，
    /// 打开定时消息（同 TG 两端）。到点才建消息、才分享资料（执行器做）。
    @MainActor
    func tellomiScheduleTextMessage(at date: Date) async {
        guard
            hasViewWillAppearEverBegun,
            let inputToolbar,
            inputToolbar.editTarget == nil,
            let messageBody = inputToolbar.messageBodyForSending,
            !messageBody.text.isEmpty
        else {
            return
        }
        if isBlockedConversation() {
            let isBlocked = await showUnblockConversationUI()
            guard !isBlocked else { return }
        }
        let identityIsConfirmed = await showSafetyNumberConfirmationIfNecessary(
            from: self,
            confirmationText: SafetyNumberStrings.confirmSendButton,
            untrustedThreshold: Date().addingTimeInterval(-OWSIdentityManagerImpl.Constants.defaultUntrustedInterval),
        )
        guard identityIsConfirmed else { return }

        // 解除拉黑、确认安全码花的时间里已经过了点：照常发出去（同选图那条路）。
        guard date > Date() else {
            sendButtonPressed()
            return
        }

        do {
            try await TellomiScheduledMessageSender.shared.schedule(
                body: messageBody,
                attachments: [],
                isViewOnce: false,
                thread: thread,
                quotedReplyDraft: inputToolbar.quotedReplyDraft,
                linkPreviewDraft: inputToolbar.linkPreviewDraft,
                captionAboveMedia: false,
                at: date,
            )
        } catch TellomiScheduledMessageSender.ScheduleError.tooManyScheduled {
            OWSActionSheets.showActionSheet(message: TellomiScheduledMessageSender.ScheduleError.tooManyScheduled.localizedDescription)
            return
        } catch {
            Logger.warn("Couldn't schedule a text message: \(error)")
            OWSActionSheets.showErrorAlert(message: CommonStrings.somethingWentWrongError)
            return
        }

        inputToolbar.quotedReplyDraft = nil
        inputToolbar.clearTextMessage(animated: true)
        let thread = self.thread
        SSKEnvironment.shared.databaseStorageRef.asyncWrite { tx in
            guard let thread = TSThread.fetchViaCache(uniqueId: thread.uniqueId, transaction: tx) else { return }
            thread.updateWithDraft(draftMessageBody: nil, replyInfo: nil, editTargetTimestamp: nil, transaction: tx)
        }
        tellomiOpenScheduledMessages()
    }

    /// 这个会话还能排几条定时消息。
    func tellomiScheduledMessageCapacity() -> Int {
        let threadUniqueId = thread.uniqueId
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiScheduledMessageSender.remainingCapacity(threadUniqueId: threadUniqueId, tx: tx)
        }
    }

    /// 选图页这一次会排成几条（同 `sendAttachments` 的拆法：单独发送一张一条；静音视频各自一条）。
    static func tellomiScheduledMessageCount(for approvedAttachments: ApprovedAttachments, separately: Bool) -> Int {
        if separately {
            return approvedAttachments.attachments.count
        }
        return TellomiMutedVideoSending.messageGroups(approvedAttachments)?.groups.count ?? 1
    }

    // MARK: - 拍完 / 系统选择器选完的预览页（P-6d）

    /// Tellomi（两端对齐清单 P-6d，owner 2026-10-16）：聊天栏相机键、附件 Sheet 的相机格拍完、系统选择器选完的预览页，
    /// 发送键长按出「定时发送」「说明文字上移 / 下移」（`SendMediaNavigationController+Tellomi.swift`）；发出来时会话页在
    /// `sendMediaNav(_:didApproveAttachments:messageBody:)` 里按它带的时间排成定时消息。
    func tellomiInstallSendLongPress(on sendMediaNavigationController: SendMediaNavigationController) {
        sendMediaNavigationController.tellomiSendMenuContext = TellomiMediaSendMenuContext(
            isNoteToSelf: thread.isNoteToSelf,
            bubbleColor: viewState.conversationStyle.bubbleChatColorOutgoing,
            scheduledMessageCapacity: { [weak self] in self?.tellomiScheduledMessageCapacity() ?? 0 },
        )
    }
}
