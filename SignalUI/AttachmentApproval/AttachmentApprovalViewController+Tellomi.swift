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

    /// tellomi/tellomi#1263（ADR-0068 §4.7 P3）：发送键长按的菜单，由打开这一页的选图页给（「说明文字上移 / 下移」）；nil = 长按不弹。
    /// 菜单正开着时就地换成新的（iOS 16+：点了菜单不收、字跟着变，同 Telegram）。
    public func tellomiSetSendMenu(_ menu: UIMenu?) {
        loadViewIfNeeded()
        let button = mediaCaptionToolbar.proceedButton
        button.menu = menu
        if #available(iOS 16, *), let menu {
            button.contextMenuInteraction?.updateVisibleMenu { _ in menu }
        }
    }

    var tellomiSendMenuForTesting: UIMenu? { mediaCaptionToolbar.proceedButton.menu }

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
