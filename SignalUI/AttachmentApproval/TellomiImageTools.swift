//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Tellomi（2026-10-16，owner 发来的方案第 6 节「方案 A」）：Tellomi 相册查看器就地打开上游的裁剪 / 绘制 / 调色工具。
///
/// 原来点查看器底部的工具键要先关掉查看器、整屏弹上游的预览 / 编辑页、再在那一页里淡出缩放、最后盖上工具页——三层转场，
/// 像跳到了另一个界面。这里直接用这张图的编辑模型建同一个工具页（和 `ImageAttachmentPrepViewController.activate…Tool`
/// 建的一样），查看器自己盖上去；改动留在 [AttachmentApprovalItem] 的编辑模型里，发送时照旧按改过的样子出附件。
/// 照 Telegram iOS：查看器底部只有一条工具栏（`TGPhotoToolbarView`），点工具就地进编辑器（`presentPhotoEditorForItem:tab:`）。
@MainActor
public enum TellomiImageTools {

    /// 这张图的工具页；不是图片（视频、动图）或者原图读不出来时是 nil。
    public static func makeToolViewController(
        _ tool: TellomiApprovalEditTool,
        for item: AttachmentApprovalItem,
        stickerSheetDelegate: StickerPickerSheetDelegate?,
        contentInsets: UIEdgeInsets,
    ) -> UIViewController? {
        guard let model = item.imageEditorModel else { return nil }
        switch tool {
        case .pen:
            let viewController = ImageEditorViewController(model: model, stickerSheetDelegate: stickerSheetDelegate)
            viewController.initialContentInsets = contentInsets
            return viewController
        case .crop:
            guard let srcImage = ImageEditorCanvasView.loadSrcImage(model: model) else {
                owsFailDebug("Couldn't load src image.")
                return nil
            }
            // 同上游 activateCropTool：预览图把涂鸦、文字都压进去，但不带旋转等变换
            let previewTransform = ImageEditorTransform.defaultTransform(srcImageSizePixels: model.srcImageSizePixels)
            guard let previewImage = ImageEditorCanvasView.renderForOutput(model: model, transform: previewTransform) else {
                owsFailDebug("Couldn't generate preview image.")
                return nil
            }
            let cropTool = ImageEditorCropViewController(model: model, srcImage: srcImage, previewImage: previewImage)
            cropTool.initialContentInsets = contentInsets
            return cropTool
        case .adjust:
            return TellomiImageAdjustViewController(model: model)
        }
    }

    /// 改过之后的样子（裁剪、涂鸦、调色都算上）；没改过或者不是图片时是 nil，查看器照旧显示原图。
    public static func editedImage(for item: AttachmentApprovalItem) -> UIImage? {
        guard let model = item.imageEditorModel, model.isDirty else { return nil }
        return ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform())
    }

    /// 这张图每改一次就调一次 [onChange]。返回的对象要拿着：编辑模型只弱引用观察者，放掉就不再通知。
    public static func observeEdits(of item: AttachmentApprovalItem, onChange: @escaping () -> Void) -> AnyObject? {
        guard let model = item.imageEditorModel else { return nil }
        let observer = EditObserver(onChange: onChange)
        model.add(observer: observer)
        return observer
    }

    private final class EditObserver: ImageEditorModelObserver {
        private let onChange: () -> Void

        init(onChange: @escaping () -> Void) {
            self.onChange = onChange
        }

        func imageEditorModelDidChange(before: ImageEditorContents, after: ImageEditorContents) {
            onChange()
        }

        func imageEditorModelDidChange(changedItemIds: [String]) {
            onChange()
        }
    }
}
