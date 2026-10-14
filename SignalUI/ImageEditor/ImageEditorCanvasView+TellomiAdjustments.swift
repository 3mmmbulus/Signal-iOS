//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Tellomi（tellomi/tellomi#1592 E5-2）：调色后的底图，放在 `ImageEditorModel` 上按调色参数缓存。调色在默认值时什么都不存。
struct TellomiAdjustedImageCache {
    /// 原图缩到预览尺寸；拖滑杆时调色在它上面实时算。
    var previewSource: CGImage?
    /// 画布上的底图。
    var preview: (adjustments: TellomiImageAdjustments, image: CGImage)?
    /// 打码用的小模糊图调色后的样子；`source` 是它从哪张模糊图来的（模糊图异步生成，换了要重算）。
    var blurred: (adjustments: TellomiImageAdjustments, source: CGImage, image: CGImage)?
    /// 只在 `renderForOutput` 里有：原尺寸的调色图，同一次渲染里橡皮也用它；渲染完就丢，不长期占内存。
    var full: (adjustments: TellomiImageAdjustments, image: CGImage)?

    /// 调回默认值后放掉占内存的图。
    mutating func releaseImages() {
        previewSource = nil
        preview = nil
        blurred = nil
        full = nil
    }
}

extension ImageEditorCanvasView {

    /// 预览底图的长边上限：全屏显示时看不出比原图糊（最大的 iPhone 屏幕长边 2868 px，照片在编辑区里显示不到 2048）。
    static let tellomiPreviewMaxPixelDimension: CGFloat = 2048

    /// 画布上的底图：调过色时是调色后的预览图；没调色返回 nil（用原图，和以前一样）。
    class func tellomiPreviewBaseImage(model: ImageEditorModel) -> CGImage? {
        let adjustments = model.adjustments
        guard !adjustments.isDefault else {
            model.tellomiAdjustedImages.releaseImages()
            return nil
        }
        if let preview = model.tellomiAdjustedImages.preview, preview.adjustments == adjustments {
            return preview.image
        }
        guard let source = tellomiPreviewSource(model: model) else { return nil }
        guard let image = TellomiImageAdjustmentsRenderer.apply(adjustments, to: source) else { return nil }
        model.tellomiAdjustedImages.preview = (adjustments, image)
        return image
    }

    /// 发出时的底图：原尺寸的调色图；没调色返回 nil。`renderForOutput` 渲染期间缓存（橡皮也用），渲染完由它清掉。
    class func tellomiFullBaseImage(model: ImageEditorModel, srcImage: UIImage) -> CGImage? {
        let adjustments = model.adjustments
        guard !adjustments.isDefault, let cgImage = srcImage.cgImage else { return nil }
        if let full = model.tellomiAdjustedImages.full, full.adjustments == adjustments {
            return full.image
        }
        guard let image = TellomiImageAdjustmentsRenderer.apply(adjustments, to: cgImage) else { return nil }
        model.tellomiAdjustedImages.full = (adjustments, image)
        return image
    }

    /// 橡皮露出来的底图：发出时（`renderForOutput` 里）用原尺寸的调色图，画布上用预览的；没调色返回 nil。
    class func tellomiEraserBaseImage(model: ImageEditorModel) -> CGImage? {
        let adjustments = model.adjustments
        guard !adjustments.isDefault else { return nil }
        if let full = model.tellomiAdjustedImages.full, full.adjustments == adjustments {
            return full.image
        }
        return tellomiPreviewBaseImage(model: model)
    }

    /// 打码的模糊图从调色后的样子取：调色是逐像素的，先模糊再调色和先调色再模糊看起来一样，而小模糊图上算只要一下，
    /// 也不用等异步。没调色返回原来的模糊图。
    class func tellomiBlurredBaseImage(model: ImageEditorModel) -> CGImage? {
        guard let blurred = model.blurredSourceImage else { return nil }
        let adjustments = model.adjustments
        guard !adjustments.isDefault else { return blurred }
        if let cached = model.tellomiAdjustedImages.blurred, cached.adjustments == adjustments, cached.source === blurred {
            return cached.image
        }
        guard let image = TellomiImageAdjustmentsRenderer.apply(adjustments, to: blurred) else { return blurred }
        model.tellomiAdjustedImages.blurred = (adjustments, blurred, image)
        return image
    }

    private class func tellomiPreviewSource(model: ImageEditorModel) -> CGImage? {
        if let previewSource = model.tellomiAdjustedImages.previewSource {
            return previewSource
        }
        let decoded = model.tellomiDecodedSrcImage ?? loadSrcImage(model: model)
        guard let decoded else { return nil }
        // 本来就不比上限大的不缩（`resized` 原样返回）。
        guard let previewSource = decoded.resized(maxDimensionPixels: tellomiPreviewMaxPixelDimension)?.cgImage else { return nil }
        model.tellomiAdjustedImages.previewSource = previewSource
        return previewSource
    }
}
