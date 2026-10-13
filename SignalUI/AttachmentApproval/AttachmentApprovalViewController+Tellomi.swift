//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
import UIKit

extension AttachmentApprovalViewController {
    /// tellomi/tellomi#1261 P-10：打开时停在第 `index` 张。上游总从第一张开始；
    /// 选图面板里点的是哪张（网格里的照片、「只看已选」里的卡片），进来就先看到哪张（同 Telegram）。
    public func tellomiShowItem(at index: Int) {
        loadViewIfNeeded()
        let items = attachmentApprovalItems
        guard items.indices.contains(index), !items[index].isIdenticalTo(currentItem) else { return }
        setCurrentItem(items[index], direction: .forward, animated: false)
    }

    /// tellomi/tellomi#1518 E-6：网格里直接发送时，把编辑项里的改动画进附件，与预览页发送走同一段代码；没改过就是原附件。
    public static func tellomiOutputAttachment(
        for item: AttachmentApprovalItem,
        attachmentLimits: OutgoingAttachmentLimits,
    ) async throws -> PreviewableAttachment {
        try await prepareAttachment(attachmentApprovalItem: item, attachmentLimits: attachmentLimits)
    }

    /// tellomi/tellomi#1263：这张照片在预览 / 编辑页里改过（裁剪、涂鸦、模糊……）。按文件发送时改过的发编辑后的图，没改过的发原文件。
    @MainActor
    public static func tellomiHasImageEdits(_ item: AttachmentApprovalItem) -> Bool {
        item.imageEditorModel?.isDirty == true
    }

    /// tellomi/tellomi#1263（ADR-0068 §4.7 P3）、#1519 M-5：发送键长按交给打开这一页的选图页（它弹「发出去是什么样」的预览和菜单）；
    /// nil = 长按不弹。
    public func tellomiSetSendLongPress(_ handler: ((UIButton) -> Void)?) {
        loadViewIfNeeded()
        TellomiSendLongPressGestureRecognizer.install(on: mediaCaptionToolbar.proceedButton, handler: handler)
    }

    var tellomiSendLongPressEnabledForTesting: Bool {
        TellomiSendLongPressGestureRecognizer.installed(on: mediaCaptionToolbar.proceedButton)?.isEnabled == true
    }

    #if TESTABLE_BUILD
    /// 同手指按住这一页的发送键。
    func tellomiLongPressSendForTesting() {
        TellomiSendLongPressGestureRecognizer.installed(on: mediaCaptionToolbar.proceedButton)?.fireForTesting()
    }
    #endif

    public func tellomiActivateTool(_ tool: TellomiApprovalEditTool) {
        switch tool {
        case .pen:
            currentPageViewController?.activatePenTool()
        case .crop:
            currentPageViewController?.activateCropTool()
        }
    }
}

public enum TellomiApprovalEditTool {
    case pen
    case crop
}

/// tellomi/tellomi#1519 M-5：发送键的长按（照 Telegram：长按发送键弹预览和菜单，松手不发）。一个按钮上只挂一个，换处理就地换。
public final class TellomiSendLongPressGestureRecognizer: UILongPressGestureRecognizer {

    private var handler: ((UIButton) -> Void)?

    /// 挂到 `button` 上（已有就换处理）；`handler` 为 nil 时停用，长按照常是按下没松开。
    public static func install(on button: UIButton, handler: ((UIButton) -> Void)?) {
        let recognizer = installed(on: button) ?? {
            let recognizer = TellomiSendLongPressGestureRecognizer()
            recognizer.addTarget(recognizer, action: #selector(didRecognize))
            button.addGestureRecognizer(recognizer)
            return recognizer
        }()
        recognizer.handler = handler
        recognizer.isEnabled = handler != nil
    }

    public static func installed(on button: UIButton) -> TellomiSendLongPressGestureRecognizer? {
        button.gestureRecognizers?.lazy.compactMap { $0 as? TellomiSendLongPressGestureRecognizer }.first
    }

    @objc
    private func didRecognize() {
        guard state == .began, let button = view as? UIButton else { return }
        handler?(button)
    }

    #if TESTABLE_BUILD
    /// 测试里代替手指按住。
    public func fireForTesting() {
        guard isEnabled, let button = view as? UIButton else { return }
        handler?(button)
    }
    #endif
}
