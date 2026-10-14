//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import UIKit

/// Tellomi（tellomi/tellomi#1592 E5-2）：调色后的底图，放在 `ImageEditorModel` 上按调色参数缓存。调色在默认值时什么都不存。
struct TellomiAdjustedImageCache {
    /// 一张调色图是按什么画的：调色参数，加上暗角跟着的画框（E5-5；暗角是 0 时为 nil，裁剪变了也不用重画）。
    struct Key: Equatable {
        var adjustments: TellomiImageAdjustments
        var frame: CGAffineTransform?
    }

    /// 原图缩到预览尺寸；拖滑杆时调色在它上面实时算。
    var previewSource: CGImage?
    /// 画布上的底图。
    var preview: (key: Key, image: CGImage)?
    /// 打码用的小模糊图调色后的样子；`source` 是它从哪张模糊图来的（模糊图异步生成，换了要重算）。
    var blurred: (key: Key, source: CGImage, image: CGImage)?
    /// 只在 `renderForOutput` 里有：原尺寸的调色图，同一次渲染里橡皮也用它；渲染完就丢，不长期占内存。
    var full: (key: Key, image: CGImage)?

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
        let key = tellomiRenderKey(model: model, transform: model.currentTransform())
        if let preview = model.tellomiAdjustedImages.preview, preview.key == key {
            return preview.image
        }
        guard let source = tellomiPreviewSource(model: model) else { return nil }
        guard let image = TellomiImageAdjustmentsRenderer.apply(adjustments, to: source, frame: key.frame ?? TellomiImageAdjustmentsRenderer.fullImageFrame) else { return nil }
        model.tellomiAdjustedImages.preview = (key, image)
        return image
    }

    /// 发出时的底图：原尺寸的调色图；没调色返回 nil。`renderForOutput` 渲染期间缓存（橡皮也用），渲染完由它清掉。
    /// `transform` 是这次渲染用的（裁剪工具的预览用的是不裁剪的那个），暗角跟着它的画框。
    class func tellomiFullBaseImage(model: ImageEditorModel, srcImage: UIImage, transform: ImageEditorTransform) -> CGImage? {
        let adjustments = model.adjustments
        guard !adjustments.isDefault, let cgImage = srcImage.cgImage else { return nil }
        let key = tellomiRenderKey(model: model, transform: transform)
        if let full = model.tellomiAdjustedImages.full, full.key == key {
            return full.image
        }
        guard let image = TellomiImageAdjustmentsRenderer.apply(adjustments, to: cgImage, frame: key.frame ?? TellomiImageAdjustmentsRenderer.fullImageFrame) else { return nil }
        model.tellomiAdjustedImages.full = (key, image)
        return image
    }

    /// 橡皮露出来的底图：发出时（`renderForOutput` 里）用原尺寸的调色图，画布上用预览的；没调色返回 nil。
    class func tellomiEraserBaseImage(model: ImageEditorModel, transform: ImageEditorTransform) -> CGImage? {
        let adjustments = model.adjustments
        guard !adjustments.isDefault else { return nil }
        if let full = model.tellomiAdjustedImages.full, full.key == tellomiRenderKey(model: model, transform: transform) {
            return full.image
        }
        return tellomiPreviewBaseImage(model: model)
    }

    /// 打码的模糊图从调色后的样子取：调色是逐像素的，先模糊再调色和先调色再模糊看起来一样，而小模糊图上算只要一下，
    /// 也不用等异步。暗角是大范围的明暗，也一样；锐化、颗粒不加（`detail: false`）。没调色返回原来的模糊图。
    class func tellomiBlurredBaseImage(model: ImageEditorModel, transform: ImageEditorTransform) -> CGImage? {
        guard let blurred = model.blurredSourceImage else { return nil }
        let adjustments = model.adjustments
        guard !adjustments.isDefault else { return blurred }
        let key = tellomiRenderKey(model: model, transform: transform)
        if let cached = model.tellomiAdjustedImages.blurred, cached.key == key, cached.source === blurred {
            return cached.image
        }
        guard
            let image = TellomiImageAdjustmentsRenderer.apply(
                adjustments,
                to: blurred,
                frame: key.frame ?? TellomiImageAdjustmentsRenderer.fullImageFrame,
                detail: false,
            )
        else { return blurred }
        model.tellomiAdjustedImages.blurred = (key, blurred, image)
        return image
    }

    private class func tellomiRenderKey(model: ImageEditorModel, transform: ImageEditorTransform) -> TellomiAdjustedImageCache.Key {
        let adjustments = model.adjustments
        return TellomiAdjustedImageCache.Key(
            adjustments: adjustments,
            frame: adjustments.vignette > 0 ? tellomiVignetteFrame(imageSize: model.srcImageSizePixels, transform: transform) : nil,
        )
    }

    /// Tellomi（tellomi/tellomi#1595 E5-5）：暗角跟着画框（裁剪后的输出范围）走：把图上的单位坐标（左上为原点，0…1）
    /// 映到画框坐标（中心 0，四边 ±1）。照画布摆底图的算法（`imageFrame`、`ImageEditorTransform.affineTransform`、
    /// 只作用在底图上的左右翻转）算三个点，拼成一个仿射变换。
    class func tellomiVignetteFrame(imageSize: CGSize, transform: ImageEditorTransform) -> CGAffineTransform {
        let viewSize = transform.outputSizePixels
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return TellomiImageAdjustmentsRenderer.fullImageFrame
        }
        let frame = imageFrame(forViewSize: viewSize, imageSize: imageSize, transform: transform)
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let affine = transform.affineTransform(viewSize: viewSize)
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let unitX = transform.isFlipped ? 1 - x : x
            let inLayer = CGPoint(x: frame.minX + unitX * frame.width, y: frame.minY + y * frame.height)
            let inView = inLayer.minus(center).applying(affine).plus(center)
            return CGPoint(x: (inView.x - center.x) / center.x, y: (inView.y - center.y) / center.y)
        }
        let origin = map(0, 0)
        let right = map(1, 0)
        let down = map(0, 1)
        return CGAffineTransform(
            a: right.x - origin.x,
            b: right.y - origin.y,
            c: down.x - origin.x,
            d: down.y - origin.y,
            tx: origin.x,
            ty: origin.y,
        )
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
