//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 两端对齐清单 P-6d：拍完（聊天栏相机键、附件 Sheet 的相机格）和系统选择器选完的上游预览页，发送键长按同选图页——
/// 「发出去是什么样」的预览，菜单里「说明文字上移 / 下移」（写了说明才有）、「定时发送」（收藏里「设置提醒」）。
/// 照 Telegram 两端相机拍完的预览页（iOS `TGCameraController` `doneLongPressed`，安卓 `PhotoViewer` 发送键长按）。
final class TellomiCameraSendLongPressTests: SignalBaseTest {

    /// 写了说明：菜单是「说明文字上移」「定时发送」；切说明位置菜单不收、气泡重排，发的时候带着；选时间后预览页照常发、带着时间；
    /// 之后在同一页普通发送不带时间。
    @MainActor
    func testCaptionToggleAndSchedulingFromTheCameraPreview() async throws {
        let hosted = try await host(caption: "Sunset")
        defer { hosted.tearDown() }

        hosted.approval.tellomiLongPressSendForTesting()
        let preview = try await presentedPreview(over: hosted.approval)
        XCTAssertEqual(preview.actionTitlesForTesting, ["Move Caption Up", "Schedule Message"])
        XCTAssertEqual(preview.captionTextForTesting, "Sunset")
        XCTAssertEqual(preview.captionIsAboveMediaForTesting, false)

        preview.performActionForTesting(at: 0)
        XCTAssertTrue(hosted.navigationController.tellomiCaptionAboveMedia)
        XCTAssertEqual(preview.actionTitlesForTesting, ["Move Caption Down", "Schedule Message"], "菜单不收、换字")
        preview.view.layoutIfNeeded()
        XCTAssertEqual(preview.captionIsAboveMediaForTesting, true, "气泡当场重排")

        preview.performActionForTesting(at: 1)
        let sheet = try await presentedScheduleSheet(over: hosted.approval)
        let at = TellomiScheduleTimeSheet.defaultDate(now: Date()).addingTimeInterval(7200)
        sheet.datePickerForTesting.date = at
        sheet.tapConfirmForTesting()

        let scheduled = try await nextSend(hosted, count: 1)
        XCTAssertEqual(scheduled.scheduledAt, at)
        XCTAssertTrue(scheduled.captionAboveMedia)
        XCTAssertEqual(scheduled.body?.text, "Sunset")
        XCTAssertEqual(scheduled.attachmentCount, 1)

        hosted.approval.tellomiTapSendForTesting()
        let next = try await nextSend(hosted, count: 2)
        XCTAssertNil(next.scheduledAt, "普通发送不带上一次的时间")
    }

    /// 没写说明只有「定时发送」；收藏（给自己）里叫「设置提醒」。
    @MainActor
    func testWithoutCaptionOnlySchedulingIsOfferedAndSavedMessagesSaysSetAReminder() async throws {
        let hosted = try await host(caption: nil, isNoteToSelf: true)
        defer { hosted.tearDown() }

        hosted.approval.tellomiLongPressSendForTesting()
        let preview = try await presentedPreview(over: hosted.approval)
        XCTAssertEqual(preview.actionTitlesForTesting, ["Set a Reminder"])
        XCTAssertNil(preview.captionTextForTesting)
    }

    /// 这个会话已经排满：选「定时发送」时就说，不弹选时间、什么都不发。
    @MainActor
    func testAFullChatIsToldBeforeChoosingATime() async throws {
        let hosted = try await host(caption: nil, scheduledMessageCapacity: 0)
        defer { hosted.tearDown() }

        hosted.approval.tellomiLongPressSendForTesting()
        let preview = try await presentedPreview(over: hosted.approval)
        preview.performActionForTesting(at: 0)
        let alerted = await waitUntil { topmost(over: hosted.approval) is ActionSheetController }
        XCTAssertTrue(alerted)
        XCTAssertTrue(hosted.delegate.sent.isEmpty)
    }

    /// 会话页没给（拍快拍等别的入口）就不挂长按。
    @MainActor
    func testNoLongPressWithoutAConversation() throws {
        let navigationController = SendMediaNavigationController.showingNativePicker(hasQuotedReplyDraft: false, attachmentLimits: .currentLimits())
        let approval = AttachmentApprovalViewController.loadWithSneakyTransaction(
            attachmentApprovalItems: [AttachmentApprovalItem(attachment: try makeAttachment(), canSave: false)],
            attachmentLimits: .currentLimits(),
            options: [],
        )
        navigationController.tellomiAttachSendLongPress(to: approval)
        XCTAssertFalse(approval.tellomiSendLongPressEnabledForTesting)
    }

    /// 预览气泡的格子按原图比例，图按要的大小缩。
    @MainActor
    func testPreviewTileKeepsTheAspectRatio() throws {
        let tile = SendMediaNavigationController.tellomiSendPreviewTile(for: AttachmentApprovalItem(attachment: try makeAttachment(), canSave: false))
        XCTAssertEqual(tile.aspectRatio, 64.0 / 48.0, accuracy: 0.01)
        var loaded: UIImage?
        _ = tile.loadImage(CGSize(width: 32, height: 32)) { loaded = $0 }
        let image = try XCTUnwrap(loaded)
        XCTAssertEqual(max(image.pixelSize.width, image.pixelSize.height), 32, accuracy: 1)
    }

    // MARK: -

    private struct Hosted {
        let window: UIWindow
        let navigationController: SendMediaNavigationController
        let approval: AttachmentApprovalViewController
        let delegate: RecordingSendMediaNavDelegate

        func tearDown() {
            window.isHidden = true
        }
    }

    /// 预览页挂在一个普通导航里放进窗口（`SendMediaNavigationController` 一出现就弹系统选择器，不放进窗口），
    /// 发送照真机交给 `SendMediaNavigationController`，再交给会话页（这里是记录用的 delegate）。
    @MainActor
    private func host(caption: String?, isNoteToSelf: Bool = false, scheduledMessageCapacity: Int = 100) async throws -> Hosted {
        let navigationController = SendMediaNavigationController.showingNativePicker(hasQuotedReplyDraft: false, attachmentLimits: .currentLimits())
        let delegate = RecordingSendMediaNavDelegate()
        navigationController.sendMediaNavDelegate = delegate
        navigationController.tellomiSendMenuContext = TellomiMediaSendMenuContext(
            isNoteToSelf: isNoteToSelf,
            bubbleColor: nil,
            scheduledMessageCapacity: { scheduledMessageCapacity },
        )

        let approval = AttachmentApprovalViewController.loadWithSneakyTransaction(
            attachmentApprovalItems: [AttachmentApprovalItem(attachment: try makeAttachment(), canSave: false)],
            attachmentLimits: .currentLimits(),
            options: [.canAddMore],
        )
        approval.approvalDelegate = navigationController
        approval.approvalDataSource = navigationController
        if let caption {
            approval.setMessageBody(MessageBody(text: caption, ranges: .empty), txProvider: DependenciesBridge.shared.db.readTxProvider)
        }
        navigationController.tellomiAttachSendLongPress(to: approval)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = OWSNavigationController(rootViewController: approval)
        window.isHidden = false
        let shown = await waitUntil { approval.viewIfLoaded?.window != nil }
        XCTAssertTrue(shown)
        XCTAssertTrue(approval.tellomiSendLongPressEnabledForTesting, "会话页给了就挂长按")
        return Hosted(window: window, navigationController: navigationController, approval: approval, delegate: delegate)
    }

    private func makeAttachment() throws -> PreviewableAttachment {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }()).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".jpg")
        try data.write(to: url)
        return try PreviewableAttachment.imageAttachment(
            dataSource: DataSourcePath(fileUrl: url, ownership: .owned),
            dataUTI: UTType.jpeg.identifier,
        )
    }

    @MainActor
    private func presentedPreview(over approval: AttachmentApprovalViewController) async throws -> TellomiSendPreviewViewController {
        let shown = await waitUntil {
            (topmost(over: approval) as? TellomiSendPreviewViewController)?.viewIfLoaded?.window != nil
        }
        XCTAssertTrue(shown, "长按发送弹出预览")
        let preview = try XCTUnwrap(topmost(over: approval) as? TellomiSendPreviewViewController)
        preview.view.layoutIfNeeded()
        return preview
    }

    @MainActor
    private func presentedScheduleSheet(over approval: AttachmentApprovalViewController) async throws -> TellomiScheduleTimeSheet {
        let shown = await waitUntil {
            guard let sheet = topmost(over: approval) as? TellomiScheduleTimeSheet else { return false }
            return sheet.viewIfLoaded?.window != nil && !sheet.isBeingPresented
        }
        XCTAssertTrue(shown, "预览收起，换成选时间")
        return try XCTUnwrap(topmost(over: approval) as? TellomiScheduleTimeSheet)
    }

    @MainActor
    private func nextSend(_ hosted: Hosted, count: Int) async throws -> RecordingSendMediaNavDelegate.Sent {
        let arrived = await waitUntil { hosted.delegate.sent.count >= count }
        XCTAssertTrue(arrived, "发送交给了会话页")
        return try XCTUnwrap(hosted.delegate.sent.last)
    }

    @MainActor
    private func topmost(over viewController: UIViewController) -> UIViewController {
        var top = viewController
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
}

/// 记下会话页收到了什么（和真的会话页一样，从 `SendMediaNavigationController` 上读说明位置、定时时间）。
private final class RecordingSendMediaNavDelegate: SendMediaNavDelegate {
    struct Sent {
        let attachmentCount: Int
        let body: MessageBody?
        let captionAboveMedia: Bool
        let scheduledAt: Date?
    }

    private(set) var sent = [Sent]()

    func sendMediaNavDidCancel(_ sendMediaNavigationController: SendMediaNavigationController) {}

    func sendMediaNav(
        _ sendMediaNavigationController: SendMediaNavigationController,
        didApproveAttachments approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
    ) {
        sent.append(Sent(
            attachmentCount: approvedAttachments.attachments.count,
            body: messageBody,
            captionAboveMedia: sendMediaNavigationController.tellomiCaptionAboveMedia,
            scheduledAt: sendMediaNavigationController.tellomiApprovedScheduledAt,
        ))
    }

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didFinishWithTextAttachment textAttachment: UnsentTextAttachment) {}

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didChangeMessageBody newMessageBody: MessageBody?) {}

    func sendMediaNav(_ sendMediaNavigationController: SendMediaNavigationController, didChangeViewOnceState isViewOnce: Bool) {}
}
