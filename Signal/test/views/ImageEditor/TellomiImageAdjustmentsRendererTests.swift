//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import simd
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1592 E5-2）：调色的渲染——每一项的方向、查找表和数学一致、预览和发出的图一致、全默认跳过整条管线。
@MainActor
final class TellomiImageAdjustmentsRendererTests: SignalBaseTest {

    private typealias Renderer = TellomiImageAdjustmentsRenderer

    // MARK: - Per-pixel math

    func testDefaultLeavesColorsAlone() {
        for color in sampleColors {
            XCTAssertEqual(Renderer.adjust(color, .default), color)
        }
    }

    /// 曝光：调亮更亮、调暗更暗，越往两头越多；白仍是白、黑仍是黑（调亮不顶死亮部）。
    func testExposure() {
        let gray = SIMD3<Float>(repeating: 0.5)
        let up50 = Renderer.adjust(gray, adjustments(exposure: 50)).x
        let up100 = Renderer.adjust(gray, adjustments(exposure: 100)).x
        let down100 = Renderer.adjust(gray, adjustments(exposure: -100)).x
        XCTAssertGreaterThan(up50, 0.5)
        XCTAssertGreaterThan(up100, up50)
        XCTAssertLessThan(down100, 0.4)

        XCTAssertEqual(Renderer.adjust(SIMD3(repeating: 1), adjustments(exposure: 100)).x, 1, accuracy: 1e-4)
        XCTAssertEqual(Renderer.adjust(SIMD3(repeating: 0), adjustments(exposure: 100)).x, 0, accuracy: 1e-4)

        // 调亮后亮部还分得开（没有一片死白）。
        let light = Renderer.adjust(SIMD3(repeating: 0.8), adjustments(exposure: 100)).x
        let lighter = Renderer.adjust(SIMD3(repeating: 0.9), adjustments(exposure: 100)).x
        XCTAssertLessThan(light, lighter)
        XCTAssertLessThan(lighter, 1)
    }

    /// 对比度：中灰不动；加对比暗的更暗、亮的更亮，减对比反过来。
    func testContrast() {
        XCTAssertEqual(Renderer.adjust(SIMD3(repeating: 0.5), adjustments(contrast: 100)).x, 0.5, accuracy: 1e-5)
        XCTAssertLessThan(Renderer.adjust(SIMD3(repeating: 0.25), adjustments(contrast: 60)).x, 0.25)
        XCTAssertGreaterThan(Renderer.adjust(SIMD3(repeating: 0.75), adjustments(contrast: 60)).x, 0.75)
        XCTAssertGreaterThan(Renderer.adjust(SIMD3(repeating: 0.25), adjustments(contrast: -60)).x, 0.25)
        XCTAssertLessThan(Renderer.adjust(SIMD3(repeating: 0.75), adjustments(contrast: -60)).x, 0.75)
    }

    /// 饱和度：−100 是灰；加饱和颜色离灰更远。
    func testSaturation() {
        let reddish = SIMD3<Float>(0.6, 0.4, 0.4)
        let gray = Renderer.adjust(reddish, adjustments(saturation: -100))
        XCTAssertEqual(gray.x, gray.y, accuracy: 1e-5)
        XCTAssertEqual(gray.y, gray.z, accuracy: 1e-5)

        let vivid = Renderer.adjust(reddish, adjustments(saturation: 50))
        XCTAssertGreaterThan(vivid.x - vivid.y, reddish.x - reddish.y)
    }

    /// 色温：暖 = 红多蓝少，冷反过来；亮度大致不变。
    func testWarmth() {
        let gray = SIMD3<Float>(repeating: 0.5)
        let warm = Renderer.adjust(gray, adjustments(warmth: 100))
        let cool = Renderer.adjust(gray, adjustments(warmth: -100))
        XCTAssertGreaterThan(warm.x, warm.z)
        XCTAssertGreaterThan(cool.z, cool.x)
        let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)
        XCTAssertEqual(simd_dot(warm, luma), 0.5, accuracy: 0.03)
        XCTAssertEqual(simd_dot(cool, luma), 0.5, accuracy: 0.03)
    }

    /// 两端同一套数学：这几个值按 `docs/product/specs/media-editor-adjustments-e5.md` 第 4 节 E5-2 写下的公式算出来，
    /// 安卓 `ImageAdjustmentsColorTest.matchesTheSharedReferenceValues` 用的是同一组。
    func testMatchesTheSharedReferenceValues() {
        let cases: [(SIMD3<Float>, TellomiImageAdjustments, SIMD3<Float>)] = [
            (SIMD3(0.5, 0.5, 0.5), adjustments(exposure: 100), SIMD3(0.72602, 0.72602, 0.72602)),
            (SIMD3(0.5, 0.5, 0.5), adjustments(exposure: -100), SIMD3(0.30487, 0.30487, 0.30487)),
            (SIMD3(0.25, 0.25, 0.25), adjustments(contrast: 60), SIMD3(0.19407, 0.19407, 0.19407)),
            (SIMD3(0.6, 0.4, 0.4), adjustments(saturation: 50), SIMD3(0.67874, 0.37874, 0.37874)),
            (SIMD3(0.5, 0.5, 0.5), adjustments(warmth: 100), SIMD3(0.55356, 0.49054, 0.4152)),
            (SIMD3(0.2, 0.5, 0.8), adjustments(exposure: 35, contrast: 25, saturation: -30, warmth: 40), SIMD3(0.34061, 0.5699, 0.73056)),
            // E5-4
            (SIMD3(0, 0, 0), adjustments(fade: 100), SIMD3(0.24, 0.24, 0.24)),
            (SIMD3(1, 1, 1), adjustments(fade: 100), SIMD3(0.9, 0.9, 0.9)),
            (SIMD3(0.2, 0.2, 0.2), adjustments(shadows: 100), SIMD3(0.27767, 0.27767, 0.27767)),
            (SIMD3(0.2, 0.2, 0.2), adjustments(shadows: -100), SIMD3(0.12233, 0.12233, 0.12233)),
            (SIMD3(0.8, 0.8, 0.8), adjustments(highlights: 100), SIMD3(0.93593, 0.93593, 0.93593)),
            (SIMD3(0.8, 0.8, 0.8), adjustments(highlights: -100), SIMD3(0.72233, 0.72233, 0.72233)),
            (SIMD3(0.3, 0.5, 0.7), adjustments(exposure: 10, fade: 40, highlights: -50, shadows: 60), SIMD3(0.35348, 0.52817, 0.70425)),
            // E5-6
            (SIMD3(0.2, 0.2, 0.2), adjustments(tintShadows: 0xD14B3F), SIMD3(0.2801, 0.1792, 0.17017)),
            (SIMD3(0.8, 0.8, 0.8), adjustments(tintHighlights: 0x8CB4FF), SIMD3(0.77221, 0.80233, 0.8588)),
            (SIMD3(0.3, 0.5, 0.7), adjustments(warmth: 20, tintShadows: 0x2E8FA8, tintHighlights: 0xFFB870), SIMD3(0.3001, 0.50469, 0.67501)),
        ]
        for (input, adjustments, expected) in cases {
            let output = Renderer.adjust(input, adjustments)
            XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(output - expected)), 1e-4, "\(input) → \(output)")
        }
    }

    /// 褪色抬黑压白、中灰几乎不动；阴影只动暗部、高光只动亮部，方向照 TG（正 = 提亮）；色相不变；亮度单调。
    func testFadeHighlightsShadows() {
        XCTAssertEqual(Renderer.adjust(SIMD3(repeating: 0.5), adjustments(fade: 100)).x, 0.51, accuracy: 0.01)
        XCTAssertGreaterThan(Renderer.adjust(SIMD3(repeating: 0.2), adjustments(shadows: 60)).x, 0.2)
        XCTAssertEqual(Renderer.adjust(SIMD3(repeating: 0.9), adjustments(shadows: 100)).x, 0.9, accuracy: 0.02, "阴影不动亮部")
        XCTAssertLessThan(Renderer.adjust(SIMD3(repeating: 0.8), adjustments(highlights: -60)).x, 0.8)
        XCTAssertEqual(Renderer.adjust(SIMD3(repeating: 0.1), adjustments(highlights: 100)).x, 0.1, accuracy: 0.02, "高光不动暗部")

        let reddish = Renderer.adjust(SIMD3(0.3, 0.15, 0.1), adjustments(shadows: 80))
        XCTAssertEqual(reddish.x / reddish.y, 2, accuracy: 0.01, "按比例缩放，色相不变")

        var previous: Float = 0
        for step in 0...100 {
            let output = Renderer.adjust(SIMD3(repeating: Float(step) / 100), adjustments(highlights: 100, shadows: -100)).x
            XCTAssertGreaterThanOrEqual(output, previous - 1e-6, "step \(step)")
            previous = output
        }
    }

    /// 色调：暗部色只动暗部、亮部色只动亮部，往那个颜色的色相偏；两个色板各 8 个，第一个是「不加」，色值和安卓一样。
    func testTint() {
        XCTAssertEqual(TellomiImageAdjustments.TintColor.shadowsPalette.count, 8)
        XCTAssertEqual(TellomiImageAdjustments.TintColor.highlightsPalette.count, 8)
        XCTAssertNil(TellomiImageAdjustments.TintColor.shadowsPalette[0])
        XCTAssertEqual(TellomiImageAdjustments.TintColor.shadowsPalette[1], TellomiImageAdjustments.TintColor(rgb: 0xD14B3F))

        let darkened = Renderer.adjust(SIMD3(repeating: 0.15), adjustments(tintShadows: 0xD14B3F))
        XCTAssertGreaterThan(darkened.x, darkened.z, "暗部偏红")
        XCTAssertEqual(Renderer.adjust(SIMD3(repeating: 1), adjustments(tintShadows: 0xD14B3F)), SIMD3(repeating: 1))

        let brightened = Renderer.adjust(SIMD3(repeating: 0.85), adjustments(tintHighlights: 0x8CB4FF))
        XCTAssertGreaterThan(brightened.z, brightened.x, "亮部偏蓝")
        XCTAssertEqual(Renderer.adjust(SIMD3(repeating: 0), adjustments(tintHighlights: 0x8CB4FF)), SIMD3(repeating: 0))
    }

    // MARK: - Image pipeline

    /// 全默认：原图原样返回，整条管线不走。
    func testDefaultAdjustmentsSkipThePipeline() throws {
        let image = try makeImage(width: 8, height: 8) { _, _ in SIMD3(0.3, 0.6, 0.9) }
        XCTAssertTrue(Renderer.apply(.default, to: image) === image)
    }

    /// 查找表（33³，三线性插值）出来的图和直接算的数学差不过 2/255。
    func testLookupTableMatchesTheMath() throws {
        let size = 32
        let image = try makeImage(width: size, height: size) { x, y in
            SIMD3(Float(x) / Float(size - 1), Float(y) / Float(size - 1), Float((x + y) % size) / Float(size - 1))
        }
        let adjusted = adjustments(exposure: 35, contrast: 25, saturation: -30, warmth: 40)
        let output = try XCTUnwrap(Renderer.apply(adjusted, to: image))
        let inputPixels = try pixels(of: image)
        let outputPixels = try pixels(of: output)

        var worst: Float = 0
        for (input, output) in zip(inputPixels, outputPixels) {
            let expected = Renderer.adjust(input, adjusted)
            worst = max(worst, simd_reduce_max(simd_abs(expected - output)))
        }
        XCTAssertLessThanOrEqual(worst, 2 / 255, "最大误差 \(worst * 255)/255")
    }

    /// 发出的图把调色烘焙进去，和画布上的预览图同一个颜色；调回默认后发出的图和原来一样。
    func testOutputBakesTheAdjustmentsAndMatchesThePreview() throws {
        let gray = SIMD3<Float>(repeating: 0.5)
        let source = try makeImage(width: 3000, height: 2000) { _, _ in gray }
        let model = try ImageEditorModel(normalizedImage: NormalizedImage.forImage(UIImage(cgImage: source)))
        let originalOutput = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform())?.cgImage)
        let originalCenter = try centerPixel(of: originalOutput)

        let adjusted = adjustments(exposure: 60, warmth: 30)
        model.replace(adjustments: adjusted)
        let output = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform())?.cgImage)
        XCTAssertEqual(output.width, 3000)
        XCTAssertEqual(output.height, 2000)
        let center = try centerPixel(of: output)
        let expected = Renderer.adjust(originalCenter, adjusted)
        XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(center - expected)), 3 / 255)
        XCTAssertNil(model.tellomiAdjustedImages.full, "原尺寸调色图渲染完就放掉")

        let preview = try XCTUnwrap(ImageEditorCanvasView.tellomiPreviewBaseImage(model: model))
        XCTAssertEqual(max(preview.width, preview.height), 2048, "画布上用缩小的预览图")
        XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(try centerPixel(of: preview) - center)), 2 / 255)

        model.replace(adjustments: .default)
        XCTAssertNil(ImageEditorCanvasView.tellomiPreviewBaseImage(model: model))
        XCTAssertNil(model.tellomiAdjustedImages.previewSource, "调回默认放掉缓存")
        let restored = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: model.currentTransform())?.cgImage)
        XCTAssertEqual(try centerPixel(of: restored), originalCenter)
    }

    /// 打码的模糊图跟着调色。
    func testFaceBlurSamplesTheAdjustedImage() throws {
        let model = try ImageEditorModel(normalizedImage: NormalizedImage.forImage(UIImage.image(color: .gray, size: CGSize(square: 400))))
        let blurred = try makeImage(width: 30, height: 20) { _, _ in SIMD3(repeating: 0.5) }
        model.blurredSourceImage = blurred
        XCTAssertTrue(ImageEditorCanvasView.tellomiBlurredBaseImage(model: model) === blurred)

        model.replace(adjustments: adjustments(exposure: -80))
        let adjustedBlur = try XCTUnwrap(ImageEditorCanvasView.tellomiBlurredBaseImage(model: model))
        XCTAssertLessThan(try centerPixel(of: adjustedBlur).x, 0.4)
    }

    /// 12MP（4032 × 3024）原尺寸烘焙的耗时：记进 PR（模拟器跑在 Mac 的 GPU 上，真机另测）。
    func testTwelveMegapixelBakeTime() throws {
        let image = try makeImage(width: 4032, height: 3024) { x, y in
            SIMD3(Float(x % 256) / 255, Float(y % 256) / 255, Float((x ^ y) % 256) / 255)
        }
        let adjusted = adjustments(exposure: 20, contrast: 20, saturation: 20, warmth: 20)
        _ = Renderer.apply(adjustments(exposure: 1), to: image) // 预热 CIContext
        let start = CACurrentMediaTime()
        let output = Renderer.apply(adjusted, to: image)
        let elapsedMs = (CACurrentMediaTime() - start) * 1000
        XCTAssertNotNil(output)
        print("TELLOMI_E52_12MP_BAKE_MS=\(Int(elapsedMs))")
        XCTAssertLessThan(elapsedMs, 5000)
    }

    // MARK: - Helpers

    private let sampleColors: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(1, 1, 1), SIMD3(0.5, 0.5, 0.5), SIMD3(0.9, 0.2, 0.1), SIMD3(0.1, 0.7, 0.3), SIMD3(0.2, 0.3, 0.95),
    ]

    private func adjustments(
        exposure: Float = 0,
        contrast: Float = 0,
        saturation: Float = 0,
        warmth: Float = 0,
        fade: Float = 0,
        highlights: Float = 0,
        shadows: Float = 0,
        tintShadows: UInt32? = nil,
        tintHighlights: UInt32? = nil,
    ) -> TellomiImageAdjustments {
        var adjustments = TellomiImageAdjustments.default
        adjustments.exposure = exposure
        adjustments.contrast = contrast
        adjustments.saturation = saturation
        adjustments.warmth = warmth
        adjustments.fade = fade
        adjustments.highlights = highlights
        adjustments.shadows = shadows
        adjustments.tintShadows = tintShadows.map { TellomiImageAdjustments.TintColor(rgb: $0) }
        adjustments.tintHighlights = tintHighlights.map { TellomiImageAdjustments.TintColor(rgb: $0) }
        return adjustments
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func makeImage(width: Int, height: Int, color: (Int, Int) -> SIMD3<Float>) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = color(x, y)
                let i = (y * width + x) * 4
                bytes[i] = UInt8((c.x * 255).rounded())
                bytes[i + 1] = UInt8((c.y * 255).rounded())
                bytes[i + 2] = UInt8((c.z * 255).rounded())
            }
        }
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: Self.sRGB,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
        ))
        return try XCTUnwrap(context.makeImage())
    }

    /// 画进 sRGB RGBA8 的画布读出来（0…1）。
    private func pixels(of image: CGImage) throws -> [SIMD3<Float>] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: Self.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 0, to: bytes.count, by: 4).map {
            SIMD3(Float(bytes[$0]), Float(bytes[$0 + 1]), Float(bytes[$0 + 2])) / 255
        }
    }

    private func centerPixel(of image: CGImage) throws -> SIMD3<Float> {
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
        return try XCTUnwrap(pixels(of: cropped).first)
    }
}
