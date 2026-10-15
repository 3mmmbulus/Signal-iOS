//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Photos
import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1261）：会话「+」打开附件 Sheet，默认页是 Telegram 式的选图网格（`TellomiPhotoPickerViewController`）。
extension ConversationViewController {

    // MARK: - 附件 Sheet（#1115）

    /// 「+」：附件 Sheet = 选图网格 + 底部 dock（相册 · 文件 · 位置 · 投票 · 联系人，owner 2026-09-23 定；GIF 能用时最后再加一格 GIF，
    /// owner 2026-09-26 临时加回，见 `TellomiAttachmentDockItem`），两档高度，下滑关闭。
    /// 相册权限：没问过就先问；拒绝 / 受限制也照样打开（dock 里别的格子还要用），网格里显示去「设置」开权限的说明。
    func presentTellomiAttachmentSheet() {
        AssertIsOnMainThread()
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .notDetermined:
            Task { @MainActor in
                _ = await self.ows_askForMediaLibraryPermissions(for: .readWrite)
                self.presentTellomiAttachmentSheetNow()
            }
        default:
            presentTellomiAttachmentSheetNow()
        }
    }

    static let attachmentSheetHalfDetent = UISheetPresentationController.Detent.Identifier("tellomi.attachmentSheet.half")

    /// 附件 Sheet 的两档：收起（聊天露在上面、压暗）与全屏；网格滚到顶再往上拖就展开。
    /// 收起的高度照 Telegram iOS（`AttachmentContainer.attachmentDefaultTopInset`：顶边比全屏低屏幕高度的 0.2488，约为全屏高度的 73%）；
    /// 只有两档、没有中间档；顶上有抓手（glass 样式有，`hasPill`）。
    static func configureAttachmentSheet(_ sheet: UISheetPresentationController) {
        if #available(iOS 16, *) {
            sheet.detents = [
                .custom(identifier: attachmentSheetHalfDetent) { context in context.maximumDetentValue * 0.73 },
                .large(),
            ]
            sheet.selectedDetentIdentifier = attachmentSheetHalfDetent
        } else {
            // iOS 15 没有自定义高度：系统的半屏 / 全屏两档
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .medium
        }
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        sheet.prefersEdgeAttachedInCompactHeight = true
        sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
        sheet.largestUndimmedDetentIdentifier = nil
        sheet.prefersGrabberVisible = true
    }

    private func presentTellomiAttachmentSheetNow() {
        guard hasViewWillAppearEverBegun, let inputToolbar else { return }

        let picker = TellomiPhotoPickerViewController(
            library: TellomiSystemPhotoLibrary(),
            initialMessageBody: inputToolbar.messageBodyForSending,
            defaultImageQuality: SSKEnvironment.shared.databaseStorageRef.read(block: ImageQuality.fetchValue(tx:)),
            canSendSeparately: true,
            // #1263：「···」→ 以文件发送（会话里一个一条地发）。
            canSendAsFile: true,
            // M-4：收藏里「定时发送」叫「设置提醒」。
            isNoteToSelf: thread.isNoteToSelf,
            hasQuotedReplyDraft: inputToolbar.quotedReplyDraft != nil,
            attachmentLimits: .currentLimits(),
            approvalDataSource: self,
            stickerSheetDelegate: self,
            // 「只看已选」（P-3）铺会话的聊天背景、说明气泡用会话的颜色。
            chatBackground: viewState.wallpaperViewBuilder?.build().asPreviewView(),
            bubbleColor: viewState.conversationStyle.bubbleChatColorOutgoing,
            camera: TellomiSystemPickerCamera(),
            dockItems: TellomiAttachmentDockItem.attachmentSheetItems,
        )
        picker.delegate = self

        // #1121：附件 Sheet 是个容器，dock 的「相册」「文件」「投票」「联系人」「位置」在同一个 Sheet 里换页
        let container = TellomiAttachmentSheetController(photoPicker: picker) { [weak self] page in
            guard let self else { return nil }
            switch page {
            case .gallery: return nil
            case .files: return self.makeTellomiFilesPage()
            case .poll: return self.makeTellomiPollPage()
            case .contact: return self.makeTellomiContactPage()
            case .location: return self.makeTellomiLocationPage()
            }
        }
        // 新功能提示卡（docs/product/specs/whats-new-cards.md）：面板默认是相册页，两张都满足时先弹「附件面板」，下次再弹「选图」。
        container.onFirstAppear = { container in
            TellomiFeatureIntro.presentFirstDue([.attachmentSheet, .photoPicker], from: container)
        }
        container.modalPresentationStyle = .pageSheet
        if let sheet = container.sheetPresentationController {
            Self.configureAttachmentSheet(sheet)
        }

        dismissKeyBoard()
        let presenter = splitViewController ?? self
        presenter.present(container, animated: true)
    }
}

extension ConversationViewController: TellomiPhotoPickerDelegate {

    func photoPickerDidCancel(_ picker: TellomiPhotoPickerViewController) {
        // #1115：面板本身就是附件 Sheet，✕ 就是关掉、回到聊天（不再「回到附件面板」，不然关不掉）。
        dismiss(animated: true)
    }

    /// dock 的「文件」「投票」「联系人」「位置」：同一个 Sheet 里换页（#1121；后三个 2026-10-16，照 Telegram iOS）。
    /// 「GIF」：先收起 Sheet，再走上游原来的流程；取消停在聊天页（P-3，同 Telegram 附件菜单先 dismiss 再整屏打开的页面）。
    func photoPicker(_ picker: TellomiPhotoPickerViewController, didSelectDockItem item: TellomiAttachmentDockItem) {
        if let container = picker.parent as? TellomiAttachmentSheetController, tellomiOpenInSheet(item, container: container) {
            return
        }
        dismiss(animated: true) { [weak self] in
            guard let self else { return }
            switch item {
            case .gallery, .file, .poll, .location:
                // 都在 Sheet 里换页（tellomiOpenInSheet 总会接走），走不到这里（清单 C-6）。
                break
            case .contact:
                // 只有 BuildFlags.accountIdentifierSharing 打开时走这里：上游换成 RecipientPicker，那条还没搬进 Sheet。
                self.contactButtonPressed()
            case .gif:
                // owner 2026-09-26 临时加回：上游附件面板 GIF 键的同一个处理（didTapGif → gifButtonPressed → showGifPicker）。
                self.gifButtonPressed()
            }
        }
    }

    /// 没有照片权限时占位里的「照片」：收起 Sheet，再弹上游的系统选择器（不要照片权限就能选、能发）——
    /// 已发布的《系统权限调用清单》TLM-LEGAL-PERMISSIONS-CN 1.0.2 §7.2 承诺的「全部相册」入口。
    /// 系统选择器取消了停在聊天页（`sendMediaNavDidCancel`，P-3）；发了照常发（`sendMediaNav(_:didApproveAttachments:)`）。
    func photoPickerDidRequestSystemPicker(_ picker: TellomiPhotoPickerViewController) {
        dismiss(animated: true) { [weak self] in
            self?.tellomiChooseFromLibraryWithNativePicker()
        }
    }

    /// 相机格：走上游「+ → 相机」同一条路（自己问相机 / 麦克风权限，拍完在它自己的预览页里发），但盖在选图面板上面——
    /// 同 Telegram（`ChatControllerOpenAttachmentMenu.openCamera` 把相机叠在附件菜单上）：取消只关相机、回到面板，已选都还在；
    /// 在相机里发了照常发，发完会话页整个收起（面板里的已选不发，同 Telegram）。
    func photoPickerDidRequestCamera(_ picker: TellomiPhotoPickerViewController) {
        let route = TellomiPickerCameraRoute(picker: picker, conversation: self)
        picker.cameraRoute = route
        tellomiTakePictureOrVideo(presenter: picker, sendMediaNavDelegate: route)
    }

    func photoPicker(
        _ picker: TellomiPhotoPickerViewController,
        send approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
        separately: Bool,
        captionAboveMedia: Bool,
        scheduledAt: Date?,
    ) {
        // 从上游预览页发的时候它盖在网格上面，提示与安全码确认都从最上面那一层弹。
        let fromViewController = picker.presentedViewController ?? picker
        // M-4：排不排得下（一个会话最多 100 条，同 TG）。选时间之前已经粗查过（一条都排不下就不弹选时间）；这里按拆成几条精确查，
        // 排不下就在选图页上说、一条都不排。
        if scheduledAt != nil {
            let needed = Self.tellomiScheduledMessageCount(for: approvedAttachments, separately: separately)
            if needed > tellomiScheduledMessageCapacity() {
                OWSActionSheets.showActionSheet(
                    message: TellomiScheduledMessageSender.ScheduleError.tooManyScheduled.localizedDescription,
                    fromViewController: fromViewController,
                )
                return
            }
        }
        let attachmentLimits = picker.attachmentLimits
        ModalActivityIndicatorViewController.present(
            fromViewController: fromViewController,
            title: CommonStrings.preparingModal,
            asyncBlock: { modal in
                // M-4：拆成几条时可能排进去一部分就出错了：按「这次排进去了没有」决定打不打开定时消息，不按全部成没成。
                let startedAt = Date()
                if separately {
                    // 说明只挂最后一条，「说明在上方」也只对它（没有说明的那几条不记）。
                    await TellomiPhotoPickerSending.sendSeparately(approvedAttachments, messageBody: messageBody) { part, body in
                        await self.sendAttachments(part, messageBody: body, from: fromViewController, attachmentLimits: attachmentLimits, captionAboveMedia: captionAboveMedia, tellomiScheduledAt: scheduledAt)
                    }
                } else {
                    await self.sendAttachments(approvedAttachments, messageBody: messageBody, from: fromViewController, attachmentLimits: attachmentLimits, captionAboveMedia: captionAboveMedia, tellomiScheduledAt: scheduledAt)
                }
                let scheduledSome = scheduledAt != nil && self.tellomiHasScheduledMessages(since: startedAt)
                modal.dismiss(completion: {
                    self.dismiss(animated: true) {
                        // 同 Telegram 两端：排好了就打开这个会话的定时消息。
                        if scheduledSome {
                            self.tellomiOpenScheduledMessages()
                        }
                    }
                })
            },
        )
    }

    /// Tellomi（tellomi/tellomi#1519 M-4）：这个会话从 `date` 起排进去过定时消息没有。
    func tellomiHasScheduledMessages(since date: Date) -> Bool {
        let threadUniqueId = thread.uniqueId
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiScheduledMessageStore.fetchAll(threadUniqueId: threadUniqueId, tx: tx).contains { $0.createdAt >= date }
        }
    }

    /// Tellomi（#1519 M-4）：这个会话的定时消息（输入框日历键、排好之后）。
    func tellomiOpenScheduledMessages() {
        dismissKeyBoard()
        TellomiScheduledMessagesViewController.present(
            thread: thread,
            bubbleColor: viewState.conversationStyle.bubbleChatColorOutgoing,
            from: self,
        )
    }

    func photoPickerScheduledMessageCapacity(_ picker: TellomiPhotoPickerViewController) -> Int {
        tellomiScheduledMessageCapacity()
    }

    func tellomiScheduledMessagesButtonPressed() {
        tellomiOpenScheduledMessages()
    }

    @objc
    func tellomiScheduledMessagesDidChange(_ notification: Notification) {
        guard SSKEnvironment.hasShared, TellomiScheduledMessageStore.didChange(notification, affect: thread.uniqueId) else { return }
        tellomiRefreshScheduledMessagesButton(animated: true)
    }

    /// 打开会话时（建输入框）不带动画，之后带。
    func tellomiRefreshScheduledMessagesButton(animated: Bool = false) {
        guard let inputToolbar else { return }
        let threadUniqueId = thread.uniqueId
        let hasScheduledMessages = SSKEnvironment.shared.databaseStorageRef.read { tx in
            !TellomiScheduledMessageStore.fetchAll(threadUniqueId: threadUniqueId, tx: tx).isEmpty
        }
        inputToolbar.tellomiSetHasScheduledMessages(hasScheduledMessages, animated: animated)
    }

    func photoPicker(_ picker: TellomiPhotoPickerViewController, didChangeMessageBody messageBody: MessageBody?) {
        guard hasViewWillAppearEverBegun, let inputToolbar else { return }
        inputToolbar.setMessageBody(messageBody, animated: false)
    }
}

/// Tellomi（#1261 P-8）：从选图面板的相机格打开的相机，事件怎么走。
/// 取消只关相机这一层、回到面板（面板接着取景）；发送、改说明、一次性查看都照会话页自己打开相机时的路子走（发完由会话页整个收起）。
final class TellomiPickerCameraRoute: SendMediaNavDelegate {
    private weak var picker: TellomiPhotoPickerViewController?
    private weak var conversation: ConversationViewController?

    init(picker: TellomiPhotoPickerViewController, conversation: ConversationViewController?) {
        self.picker = picker
        self.conversation = conversation
    }

    /// 只关相机（它自己 dismiss），面板留着；关完面板接着取景。
    func closeCamera(_ camera: UIViewController) {
        camera.dismiss(animated: true) { [weak picker] in
            picker?.cameraDidClose()
        }
    }

    func sendMediaNavDidCancel(_ sendMediaNavigationController: SendMediaNavigationController) {
        closeCamera(sendMediaNavigationController)
    }

    func sendMediaNav(
        _ sendMediaNavigationController: SendMediaNavigationController,
        didApproveAttachments approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
    ) {
        conversation?.sendMediaNav(sendMediaNavigationController, didApproveAttachments: approvedAttachments, messageBody: messageBody)
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didFinishWithTextAttachment textAttachment: UnsentTextAttachment) {
        conversation?.sendMediaNav(sendMediaNavigationController, didFinishWithTextAttachment: textAttachment)
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didChangeMessageBody newMessageBody: MessageBody?) {
        conversation?.sendMediaNav(sendMediaNavigationController, didChangeMessageBody: newMessageBody)
        picker?.updateCaptionFromCamera(newMessageBody)
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didChangeViewOnceState isViewOnce: Bool) {
        conversation?.sendMediaNav(sendMediaNavigationController, didChangeViewOnceState: isViewOnce)
    }
}

/// Tellomi（tellomi/tellomi#1518 V-6，owner 2026-10-14 照 Telegram 两端）：静音的视频当 GIF 发，单独成一条（照 TG 安卓 `SendMessagesHelper`
/// 静音那一项不进相册组；Signal Desktop 也只在整条消息只有一个附件时按 GIF 画），其余的保持顺序成一组在前。
enum TellomiMutedVideoSending {
    static func isMutedGif(_ attachment: PreviewableAttachment) -> Bool {
        attachment.isVideo && attachment.rawValue.isLoopingVideo
    }

    /// 不用拆（一次性查看、只有一项、没有静音视频）时是 nil；`bodyIndex` 是带说明的那一组。
    static func messageGroups(_ approved: ApprovedAttachments) -> (groups: [ApprovedAttachments], bodyIndex: Int)? {
        guard !approved.isViewOnce, approved.attachments.count > 1 else { return nil }
        let muted = approved.attachments.filter(isMutedGif)
        guard !muted.isEmpty else { return nil }
        let rest = approved.attachments.filter { !isMutedGif($0) }

        var groups = [ApprovedAttachments]()
        if !rest.isEmpty {
            groups.append(ApprovedAttachments(nonViewOnceAttachments: rest, imageQuality: approved.imageQuality))
        }
        groups += muted.map { ApprovedAttachments(nonViewOnceAttachments: [$0], imageQuality: approved.imageQuality) }
        return (groups, rest.isEmpty ? groups.count - 1 : 0)
    }
}

/// Tellomi（#1261 P-5「单独发送」）：一张一条，说明（连同 @ 与样式）挂最后一条；上一条没发出去（被拦下 / 取消）就不再发后面的。
/// 引用只挂第一条：会话页每发出一条就清掉引用草稿（上游 `messageWasSent`）。
/// 时间戳不重复、落库顺序与勾的顺序一致：上游 `MessageTimestampGenerator` 连发时逐个 +1，`ThreadUtil.enqueueSendQueue` 串行。
enum TellomiPhotoPickerSending {
    @MainActor
    static func sendSeparately(
        _ approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
        send: (ApprovedAttachments, MessageBody?) async -> Bool,
    ) async {
        let attachments = approvedAttachments.attachments
        for (index, attachment) in attachments.enumerated() {
            let isLast = index == attachments.count - 1
            let part = ApprovedAttachments(nonViewOnceAttachments: [attachment], imageQuality: approvedAttachments.imageQuality)
            guard await send(part, isLast ? messageBody : nil) else {
                return
            }
        }
    }
}
