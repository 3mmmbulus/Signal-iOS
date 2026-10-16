//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 会话页交给相机 / 系统选择器的：长按发送要用到的会话信息（`ConversationViewController.tellomiInstallSendLongPress(on:)`）。
struct TellomiMediaSendMenuContext {
    /// 收藏（给自己）里「定时发送」叫「设置提醒」。
    let isNoteToSelf: Bool
    /// 预览气泡的颜色（会话里自己发的气泡色）。
    let bubbleColor: ColorOrGradientValue?
    /// 这个会话还能排几条定时消息（一个会话最多 100 条，同 TG）。
    let scheduledMessageCapacity: () -> Int
}

/// Tellomi（两端对齐清单 P-6d，owner 2026-10-16）：聊天栏相机键、附件 Sheet 的相机格拍完，以及没有照片权限时系统选择器选完，
/// 都进上游的预览页；它的发送键也能长按，和选图页一样：「发出去是什么样」的气泡，菜单里「说明文字上移 / 下移」（写了说明才有）、
/// 「定时发送」（收藏里「设置提醒」）。选好时间让预览页照常发（编辑画进去、选的画质、一次性查看），由会话页排成定时消息。
///
/// 照 Telegram 两端相机拍完的预览页（只读，代码是自己写的）：iOS `TGCameraController` 的 `doneLongPressed`，
/// 安卓 `PhotoViewer` 的 `pickerViewSendButton.setOnLongClickListener`，长按发送都出菜单、里面有定时发送 / 设置提醒。
/// 「静音发送」「对方上线时发送」不做（spec D4）。
extension SendMediaNavigationController {

    /// 预览页建好时挂上；会话页没给 `tellomiSendMenuContext` 就不挂（长按和普通点一样）。
    func tellomiAttachSendLongPress(to approval: AttachmentApprovalViewController) {
        guard tellomiSendMenuContext != nil else { return }
        approval.tellomiSetSendLongPress { [weak self, weak approval] button in
            guard let approval else { return }
            self?.tellomiPresentSendPreview(for: approval, from: button)
        }
    }

    @discardableResult
    func tellomiPresentSendPreview(for approval: AttachmentApprovalViewController, from button: UIButton) -> TellomiSendPreviewViewController? {
        guard let context = tellomiSendMenuContext else { return nil }
        let items = approval.tellomiApprovalItems
        // 弹在预览页上（它在这个导航里时由导航来弹）；已经弹着别的（预览、选时间）就不再弹。
        guard !items.isEmpty, approval.presentedViewController == nil, presentedViewController == nil else { return nil }
        // 说明照发出去的样子（@ 的是名字）；一次性查看没有说明。
        let caption: String? = approval.messageBodyForSending.map { body in
            SSKEnvironment.shared.databaseStorageRef.read { tx in
                body.hydrating(mentionHydrator: ContactsMentionHydrator.mentionHydrator(transaction: tx)).asPlaintext()
            }
        }?.nilIfEmpty

        weak var presented: TellomiSendPreviewViewController?
        func makeActions() -> [TellomiSendPreviewViewController.Action] {
            var actions = [TellomiSendPreviewViewController.Action]()
            if caption != nil {
                let item: TellomiPhotoPickerViewController.MoreMenuItem = tellomiCaptionAboveMedia ? .moveCaptionDown : .moveCaptionUp
                actions.append(TellomiSendPreviewViewController.Action(
                    title: TellomiPhotoPickerViewController.title(for: item, selectedCount: items.count),
                    image: TellomiPhotoPickerViewController.image(for: item),
                    keepsPresented: true,
                ) { [weak self] in
                    // 同选图页：菜单不收，气泡当场重排、菜单换字。
                    guard let self else { return }
                    self.tellomiCaptionAboveMedia.toggle()
                    presented?.update(captionAboveMedia: self.tellomiCaptionAboveMedia, actions: makeActions())
                })
            }
            actions.append(TellomiSendPreviewViewController.Action(
                title: TellomiPhotoPickerViewController.title(for: .scheduleSend, selectedCount: items.count, isNoteToSelf: context.isNoteToSelf),
                image: TellomiPhotoPickerViewController.image(for: .scheduleSend),
                keepsPresented: false,
            ) { [weak self, weak approval] in
                guard let self, let approval else { return }
                self.tellomiPresentScheduleSheet(for: approval, context: context)
            })
            return actions
        }

        let preview = TellomiSendPreviewViewController(
            tiles: items.map(Self.tellomiSendPreviewTile(for:)),
            caption: caption,
            captionAboveMedia: tellomiCaptionAboveMedia,
            bubbleColor: context.bubbleColor,
            actions: makeActions(),
            sourceButton: button,
            onSend: { [weak button] in button?.sendActions(for: .primaryActionTriggered) },
        )
        presented = preview
        approval.present(preview, animated: false)
        return preview
    }

    /// 选时间；选好了让预览页照常发，交回来时带着时间（`tellomiApprovedScheduledAt`）。
    private func tellomiPresentScheduleSheet(for approval: AttachmentApprovalViewController, context: TellomiMediaSendMenuContext) {
        // 排满了就先说，不用选完时间、准备完附件才知道。
        guard context.scheduledMessageCapacity() > 0 else {
            OWSActionSheets.showActionSheet(
                message: TellomiScheduledMessageSender.ScheduleError.tooManyScheduled.localizedDescription,
                fromViewController: approval,
            )
            return
        }
        let sheet = TellomiScheduleTimeSheet(isReminder: context.isNoteToSelf) { [weak approval] date in
            approval?.tellomiProceed(scheduledAt: date)
        }
        sheet.present(from: approval)
    }

    /// 预览气泡里的一格：拍的 / 选的原图（视频取一帧）。和选图页一样，预览页里的裁剪、涂鸦要到发送时才画进去，这里是原图。
    static func tellomiSendPreviewTile(for item: AttachmentApprovalItem) -> TellomiSendPreviewViewController.Tile {
        let attachment = item.attachment.rawValue
        let image = attachment.isVideo ? attachment.videoPreview() : attachment.image()
        let size = image?.size ?? .zero
        return TellomiSendPreviewViewController.Tile(aspectRatio: size.height > 0 ? size.width / size.height : 1) { pixels, completion in
            completion(image.flatMap { $0.resized(maxDimensionPixels: max(pixels.width, pixels.height)) } ?? image)
            return nil
        }
    }
}
