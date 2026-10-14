//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import simd
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1592 E5-2、#1595 E5-5）：调色的渲染——每一项的方向、查找表和数学一致、预览和发出的图一致、全默认跳过整条管线。
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
        XCTAssertTrue(ImageEditorCanvasView.tellomiBlurredBaseImage(model: model, transform: model.currentTransform()) === blurred)

        model.replace(adjustments: adjustments(exposure: -80))
        let adjustedBlur = try XCTUnwrap(ImageEditorCanvasView.tellomiBlurredBaseImage(model: model, transform: model.currentTransform()))
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

    // MARK: - E5-5 sharpen, grain, vignette

    /// 两端同一套：噪声块的字节、「格」的大小、颗粒权重、暗角强度和压暗。按 `docs/product/specs/media-editor-adjustments-e5.md`
    /// 第 4 节 E5-5 的定义算出来，安卓 `ImageAdjustmentsDetailTest.matchesTheSharedReferenceValues` 用的是同一组。
    func testDetailMatchesTheSharedReferenceValues() {
        let noise = Renderer.noiseTile
        XCTAssertEqual(noise.count, 256 * 256)
        XCTAssertEqual(Array(noise.prefix(16)), [225, 139, 100, 0, 242, 254, 138, 18, 150, 70, 19, 157, 142, 158, 38, 231])
        XCTAssertEqual(noise.reduce(0) { $0 + Int($1) }, 8_380_824)
        XCTAssertEqual(noise[256], 185)
        XCTAssertEqual(noise[256 * 256 - 1], 198)

        XCTAssertEqual(Renderer.detailUnit(forLongSide: 1000), 1)
        XCTAssertEqual(Renderer.detailUnit(forLongSide: 2048), 1)
        XCTAssertEqual(Renderer.detailUnit(forLongSide: 4032), 1.96875)

        XCTAssertEqual(Renderer.grainWeight(0.5), 1, accuracy: 1e-6)
        XCTAssertEqual(Renderer.grainWeight(0.9), 0.488, accuracy: 1e-5)
        XCTAssertEqual(Renderer.grainWeight(0.25), 0.875, accuracy: 1e-6)
        XCTAssertEqual(Renderer.grainWeight(0), 0, accuracy: 1e-6)

        XCTAssertEqual(Renderer.vignetteStrength(1, at: CGPoint(x: 1, y: 1)), 1, accuracy: 1e-5)
        XCTAssertEqual(Renderer.vignetteStrength(1, at: CGPoint(x: 1, y: 0)), 0.35355, accuracy: 1e-5)
        XCTAssertEqual(Renderer.vignetteStrength(1, at: CGPoint(x: 0.5, y: 0.5)), 0.125, accuracy: 1e-5)
        XCTAssertEqual(Renderer.vignetteStrength(1, at: CGPoint(x: 2, y: 2)), 1, accuracy: 1e-5, "画框外不再加深")
        XCTAssertEqual(Renderer.vignette(0.5, strength: 1), 0.14146, accuracy: 1e-5)
        XCTAssertEqual(Renderer.vignette(1, strength: 1), 0.65, accuracy: 1e-5)
        XCTAssertEqual(Renderer.vignette(0.8, strength: 1), 0.39784, accuracy: 1e-5)
        XCTAssertEqual(Renderer.vignette(0.5, strength: 0.35355), 0.3265, accuracy: 1e-4)
        XCTAssertEqual(Renderer.vignette(0.2, strength: 0.5), 0.06282, accuracy: 1e-5)
    }

    /// 锐化：一条竖直的边两侧拉开（帐篷核、2.5 倍，参考值 0.275 / 0.725，同安卓），平的地方不动，图边不被外面拉暗。
    func testSharpenMatchesTheMath() throws {
        let image = try makeImage(width: 16, height: 6) { x, _ in SIMD3(repeating: x < 8 ? 0.4 : 0.6) }
        let output = try XCTUnwrap(Renderer.apply(detail(sharpen: 100), to: image))
        let sharpened = try pixels(of: output)
        func at(_ x: Int, _ y: Int) -> Float { sharpened[y * 16 + x].x }
        XCTAssertEqual(at(7, 3), 0.275, accuracy: 2.5 / 255)
        XCTAssertEqual(at(8, 3), 0.725, accuracy: 2.5 / 255)
        XCTAssertEqual(at(7, 3), at(7, 0), accuracy: 1 / 255, "上下边和中间一样")
        XCTAssertEqual(at(2, 3), 0.4, accuracy: 1.5 / 255)
        XCTAssertEqual(at(13, 3), 0.6, accuracy: 1.5 / 255)
        XCTAssertEqual(at(0, 0), 0.4, accuracy: 1.5 / 255, "图边不被外面拉暗")

        let half = try pixels(of: XCTUnwrap(Renderer.apply(detail(sharpen: 50), to: image)))
        XCTAssertEqual(half[3 * 16 + 7].x, 0.3375, accuracy: 2.5 / 255)
    }

    /// 颗粒：中灰上有起伏（标准差 0.01…0.04），平均不变，三个通道一样（单色）；纯黑不加；噪声固定，同一张图画两次一样。
    func testGrainAddsMonochromeMidtoneNoise() throws {
        let gray = try makeImage(width: 128, height: 128) { _, _ in SIMD3(repeating: 0.5) }
        let output = try pixels(of: XCTUnwrap(Renderer.apply(detail(grain: 100), to: gray)))
        let values = output.map(\.x)
        let mean = values.reduce(0, +) / Float(values.count)
        let deviation = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
        XCTAssertEqual(mean, 0.5, accuracy: 0.01)
        XCTAssertGreaterThan(deviation, 0.01)
        XCTAssertLessThan(deviation, 0.04)
        XCTAssertTrue(output.allSatisfy { abs($0.x - $0.y) <= 1 / 255 && abs($0.y - $0.z) <= 1 / 255 }, "单色颗粒")

        let again = try pixels(of: XCTUnwrap(Renderer.apply(detail(grain: 100), to: gray)))
        XCTAssertEqual(output, again)

        let black = try makeImage(width: 32, height: 32) { _, _ in SIMD3(repeating: 0) }
        XCTAssertTrue(try pixels(of: XCTUnwrap(Renderer.apply(detail(grain: 100), to: black))).allSatisfy { $0 == SIMD3(repeating: 0) })
    }

    /// 暗角：中心不动、四角最暗，和数学一致（角上的中灰 ≈ 0.14）。
    func testVignetteMatchesTheMath() throws {
        let gray = try makeImage(width: 200, height: 100) { _, _ in SIMD3(repeating: 0.5) }
        let output = try pixels(of: XCTUnwrap(Renderer.apply(detail(vignette: 100), to: gray)))
        func at(_ x: Int, _ y: Int) -> Float { output[y * 200 + x].x }
        let input = Float(128) / 255
        XCTAssertEqual(at(100, 50), input, accuracy: 1.5 / 255)
        for (x, y) in [(0, 0), (199, 0), (0, 99), (199, 99), (30, 70)] {
            let d = CGPoint(x: 2 * (CGFloat(x) + 0.5) / 200 - 1, y: 2 * (CGFloat(y) + 0.5) / 100 - 1)
            let expected = Renderer.vignette(input, strength: Renderer.vignetteStrength(1, at: d))
            XCTAssertEqual(at(x, y), expected, accuracy: 2.5 / 255, "(\(x), \(y))")
        }
        XCTAssertLessThan(at(0, 0), 0.16)
    }

    /// 暗角跟着画框（裁剪后的输出范围）走：放大 2 倍只看中间一半时，原图 (0.25, 0.25) 是画框的左上角；左右翻转时原图左上角是画框右上角。
    func testVignetteFrameFollowsTheCrop() {
        let size = CGSize(width: 200, height: 100)
        let full = ImageEditorCanvasView.tellomiVignetteFrame(imageSize: size, transform: .defaultTransform(srcImageSizePixels: size))
        assertMaps(full, CGPoint(x: 0, y: 0), to: CGPoint(x: -1, y: -1))
        assertMaps(full, CGPoint(x: 0.5, y: 0.5), to: .zero)
        assertMaps(full, CGPoint(x: 1, y: 1), to: CGPoint(x: 1, y: 1))

        let zoomed = ImageEditorCanvasView.tellomiVignetteFrame(
            imageSize: size,
            transform: ImageEditorTransform(outputSizePixels: size, unitTranslation: .zero, rotationRadians: 0, scaling: 2, isFlipped: false),
        )
        assertMaps(zoomed, CGPoint(x: 0.25, y: 0.25), to: CGPoint(x: -1, y: -1))
        assertMaps(zoomed, CGPoint(x: 0.75, y: 0.75), to: CGPoint(x: 1, y: 1))

        let flipped = ImageEditorCanvasView.tellomiVignetteFrame(
            imageSize: size,
            transform: ImageEditorTransform(outputSizePixels: size, unitTranslation: .zero, rotationRadians: 0, scaling: 1, isFlipped: true),
        )
        assertMaps(flipped, CGPoint(x: 0, y: 0), to: CGPoint(x: 1, y: -1))
    }

    /// 发出的图：裁剪（放大 2 倍）后暗角在裁剪后的四角，不在原图四角；画布上的预览跟着裁剪重画，暗角是 0 时裁剪变了不重画。
    func testOutputVignetteIsCenteredOnTheCrop() throws {
        let size = CGSize(width: 400, height: 200)
        let source = try makeImage(width: 400, height: 200) { _, _ in SIMD3(repeating: 0.5) }
        let model = try ImageEditorModel(normalizedImage: NormalizedImage.forImage(UIImage(cgImage: source)))
        model.replace(adjustments: detail(vignette: 100))
        let previewBefore = try XCTUnwrap(ImageEditorCanvasView.tellomiPreviewBaseImage(model: model))

        let zoomed = ImageEditorTransform(outputSizePixels: size, unitTranslation: .zero, rotationRadians: 0, scaling: 2, isFlipped: false)
        model.replace(transform: zoomed)
        let output = try XCTUnwrap(ImageEditorCanvasView.renderForOutput(model: model, transform: zoomed)?.cgImage)
        let outputPixels = try pixels(of: output)
        let corner = outputPixels[2 * output.width + 2].x
        let center = try centerPixel(of: output).x
        XCTAssertLessThan(corner, 0.2, "裁剪后的角上压得最暗")
        XCTAssertEqual(center, Float(128) / 255, accuracy: 2 / 255)

        let previewAfter = try XCTUnwrap(ImageEditorCanvasView.tellomiPreviewBaseImage(model: model))
        XCTAssertFalse(previewAfter === previewBefore, "裁剪变了，暗角重画")

        var noVignette = detail(grain: 30)
        noVignette.exposure = 10
        model.replace(adjustments: noVignette)
        let first = try XCTUnwrap(ImageEditorCanvasView.tellomiPreviewBaseImage(model: model))
        model.replace(transform: .defaultTransform(srcImageSizePixels: size))
        XCTAssertTrue(try XCTUnwrap(ImageEditorCanvasView.tellomiPreviewBaseImage(model: model)) === first, "没有暗角时裁剪变了不重画")
    }

    /// 打码的小模糊图：调色和暗角照加，锐化、颗粒不加。
    func testFaceBlurGetsVignetteButNoGrain() throws {
        let model = try ImageEditorModel(normalizedImage: NormalizedImage.forImage(UIImage.image(color: .gray, size: CGSize(square: 400))))
        let blurred = try makeImage(width: 60, height: 60) { _, _ in SIMD3(repeating: 0.5) }
        model.blurredSourceImage = blurred
        var adjustments = detail(grain: 100, vignette: 100)
        adjustments.sharpen = 100
        model.replace(adjustments: adjustments)
        let adjustedBlur = try XCTUnwrap(ImageEditorCanvasView.tellomiBlurredBaseImage(model: model, transform: model.currentTransform()))
        let blurPixels = try pixels(of: adjustedBlur)
        XCTAssertLessThan(blurPixels[0].x, 0.2, "角上有暗角")
        let middle = blurPixels[(30 * 60)..<(30 * 60 + 60)].map(\.x)[25..<35]
        XCTAssertLessThanOrEqual((middle.max() ?? 0) - (middle.min() ?? 0), 2 / 255, "中间没有颗粒")
    }

    /// 12MP 原尺寸烘焙，锐化 + 颗粒 + 暗角 + 调色都开：耗时记进 PR。
    func testTwelveMegapixelDetailBakeTime() throws {
        let image = try makeImage(width: 4032, height: 3024) { x, y in
            SIMD3(Float(x % 256) / 255, Float(y % 256) / 255, Float((x ^ y) % 256) / 255)
        }
        var adjusted = detail(sharpen: 60, grain: 50, vignette: 50)
        adjusted.exposure = 20
        _ = Renderer.apply(detail(sharpen: 1, grain: 1, vignette: 1), to: image) // 预热
        let start = CACurrentMediaTime()
        let output = Renderer.apply(adjusted, to: image)
        let elapsedMs = (CACurrentMediaTime() - start) * 1000
        XCTAssertNotNil(output)
        print("TELLOMI_E55_12MP_BAKE_MS=\(Int(elapsedMs))")
        XCTAssertLessThan(elapsedMs, 5000)
    }

    private func detail(sharpen: Float = 0, grain: Float = 0, vignette: Float = 0) -> TellomiImageAdjustments {
        var adjustments = TellomiImageAdjustments.default
        adjustments.sharpen = sharpen
        adjustments.grain = grain
        adjustments.vignette = vignette
        return adjustments
    }

    private func assertMaps(_ frame: CGAffineTransform, _ unit: CGPoint, to expected: CGPoint, line: UInt = #line) {
        let mapped = unit.applying(frame)
        XCTAssertEqual(mapped.x, expected.x, accuracy: 1e-6, line: line)
        XCTAssertEqual(mapped.y, expected.y, accuracy: 1e-6, line: line)
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
