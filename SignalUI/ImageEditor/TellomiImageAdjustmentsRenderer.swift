//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SignalServiceKit
import simd
import UIKit

/// Tellomi（tellomi/tellomi#1592 E5-2、#1594 E5-4、#1595 E5-5、#1596 E5-6、#1597 E5-7，Epic #1523）：把调色画进图里。
///
/// 逐像素的几项（曲线、曝光、对比度、高光、阴影、饱和度、色温、色调、褪色）合成一张 3D 查找表，用 CoreImage 的 `CIColorCubeWithColorSpace`
/// 在图自己的颜色空间（sRGB / Display P3 的编码值）里查——预览图和发出的原尺寸图走同一张表，所以两边一致。
/// 和位置有关的三项（锐化、颗粒、暗角）是自己写的 CoreImage 内核
/// （`TellomiImageAdjustments.metal`），也在编码值上算；顺序照两端 Telegram：锐化 → 查找表 → 颗粒 → 暗角。
///
/// 每一项的数学是自己定的（Telegram 只用来对照工具、范围和方向，它的着色器一行不搬，见 `docs/product/specs/media-editor-adjustments-e5.md`）：
/// - 曲线：每条 5 个点（输入 0 / 0.25 / 0.5 / 0.75 / 1，输出 = 值/100），单调三次插值（Fritsch–Carlson，不会冲过相邻两点）；
///   「全部」三个通道各过一遍，然后红、绿、蓝各过自己那条。最先做（照两端 TG，曲线在工具着色器的最前面）。
/// - 曝光：线性光里乘增益，+100 = +2 档、−100 = −1.5 档；调亮时用一个让原来的白仍落在白上的肩，亮部不会一下顶死。
/// - 对比度：绕中灰拉开 / 收拢，系数 1.4^(值/100)。
/// - 饱和度：和同亮度的灰按比例混（Rec. 709 亮度），0…2 倍。
/// - 色温：线性光里红、蓝反向增益（暖 = 红多蓝少），再把亮度拉回原来。
/// - 高光 / 阴影：只改亮度（按比例缩放三个通道，色相不变）；阴影在亮度 0.25 附近、高光在 0.75 附近各一个鼓包，
///   y' = y + k·(值/100)·b(y)，b_阴影(y) = y(1−y)³·256/27，b_高光(y) = b_阴影(1−y)；k = 0.08，提亮高光时 0.14（TG 提亮高光推向白更狠）。
/// - 色调：暗部 / 亮部各一个颜色，往那个颜色的色相偏（加上「颜色 − 它自己的亮度」，亮度不变），暗部按 (1−y)²、亮部按 y² 加权，
///   强度固定 50%（O8），c' = c + (T − luma(T))·0.6·(强度/100)·w。
/// - 褪色：往一条「哑光」曲线 t(c) = 0.24 + 0.42c + 0.24c² 混（黑抬到 0.24、白压到 0.9、中灰几乎不动），混的比例 = 值/100。
///
/// 和位置有关的三项用一个「格」u = max(1, 长边 / 2048) 像素量尺寸：预览图（长边 ≤ 2048）上 u = 1，原尺寸图上按比例放大，
/// 所以预览和发出的图看起来一样（发出的图只是同一个样子的更高分辨率版本）。
/// - 锐化：c' = c + 2.5·(值/100)·(c − 模糊)，模糊是以 u 为一格的 3×3 帐篷核；在查找表之前（照 TG，锐化在调色之前）。
/// - 颗粒：一块 256 × 256 的固定噪声（xorshift32，种子 0x2545F491，两端字节一样），按 2u 像素一格双线性插值、四边循环；
///   c' = c + 0.06·(值/100)·w(y)·n，w(y) = 1 − |2y − 1|³（中间调最多，纯黑纯白不加），单色。只用于照片。
/// - 暗角：跟着画框（裁剪后的输出范围）走，不跟着整张原图；d 是画框坐标（中心 0，四边 ±1），ρ = min(|d|/√2, 1)，
///   k = (值/100)·ρ³，c' = c^(1 + 1.2k)·(1 − 0.35k)：角上中灰 0.5 → 0.141、白 → 0.65（TG ≈ 0.141 / 0.685，暗部比亮部压得多）。
@MainActor
enum TellomiImageAdjustmentsRenderer {

    /// 查找表每边的格数。33 是 .cube 常用的大小，三线性插值下平滑曲线的误差在 1/255 量级。
    static let cubeDimension = 33

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static var cachedCube: (adjustments: TellomiImageAdjustments, data: Data)?

    // MARK: - Images

    /// 把调色画进 `image`。全在默认值时原样返回（整条管线跳过）；出错返回 nil。
    ///
    /// - `frame`：暗角跟着的画框，见 `fullImageFrame`；只在暗角不是 0 时有用。
    /// - `detail`：要不要锐化和颗粒。打码用的小模糊图不要（锐化一张模糊图没意义，颗粒在小图上放大会成斑块），只调色和暗角。
    static func apply(
        _ adjustments: TellomiImageAdjustments,
        to image: CGImage,
        frame: CGAffineTransform = fullImageFrame,
        detail: Bool = true,
    ) -> CGImage? {
        guard !adjustments.isDefault else { return image }

        let colorSpace = workingColorSpace(for: image)
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let unit = detailUnit(forLongSide: max(image.width, image.height))
        var output = input

        if detail, adjustments.sharpen > 0 {
            guard let sharpened = sharpen(output, amount: 2.5 * adjustments.sharpen / 100, unit: unit, colorSpace: colorSpace) else { return nil }
            output = sharpened
        }

        let colorTools = colorOnly(adjustments)
        if colorTools != .default {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = output
            filter.cubeDimension = Float(cubeDimension)
            filter.cubeData = cubeData(for: colorTools)
            filter.colorSpace = colorSpace
            guard let cubed = filter.outputImage else {
                owsFailDebug("Color cube produced no image.")
                return nil
            }
            output = cubed
        }

        let grain = detail ? adjustments.grain : 0
        if grain > 0 || adjustments.vignette > 0 {
            guard
                let finished = grainAndVignette(
                    output,
                    grain: 0.06 * grain / 100,
                    grainCell: 2 * unit,
                    vignette: adjustments.vignette / 100,
                    frame: frame,
                    colorSpace: colorSpace,
                )
            else { return nil }
            output = finished
        }

        return context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// 查找表只管逐像素的几项：把和位置有关的几项放回默认，只动了它们时不用查表，拖它们的滑杆也不用重算表。
    private static func colorOnly(_ adjustments: TellomiImageAdjustments) -> TellomiImageAdjustments {
        var colorOnly = adjustments
        colorOnly.sharpen = 0
        colorOnly.grain = 0
        colorOnly.vignette = 0
        colorOnly.blur = TellomiImageAdjustments.default.blur
        return colorOnly
    }

    /// 查表用图自己的 RGB 颜色空间（相册里的照片多是 Display P3，换到 sRGB 会把超出 sRGB 的颜色截掉）；
    /// 没有或不是 RGB 的用 sRGB。
    private static func workingColorSpace(for image: CGImage) -> CGColorSpace {
        if let colorSpace = image.colorSpace, colorSpace.model == .rgb {
            return colorSpace
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    // MARK: - Position-dependent tools (E5-5)

    /// 整张图就是画框（没裁剪）：单位坐标 0…1 → 画框坐标 −1…1。
    static let fullImageFrame = CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: -1, ty: -1)

    /// 锐化、颗粒量尺寸的「格」：预览图（长边 ≤ 2048）是 1 像素，更大的图按长边 / 2048 放大。
    static func detailUnit(forLongSide longSide: Int) -> CGFloat {
        max(1, CGFloat(longSide) / 2048)
    }

    /// 颗粒加的量按亮度的权重：中间调 1，纯黑纯白 0。
    static func grainWeight(_ luma: Float) -> Float {
        let t = abs(2 * luma - 1)
        return 1 - t * t * t
    }

    /// 画框坐标 `d` 处的暗角强度 k（`vignette` 是 值/100）。
    static func vignetteStrength(_ vignette: Float, at d: CGPoint) -> Float {
        let rho = min(Float(hypot(d.x, d.y)) / Float(2).squareRoot(), 1)
        return vignette * rho * rho * rho
    }

    /// 暗角压一个编码值：c^(1 + 1.2k)·(1 − 0.35k)。
    static func vignette(_ value: Float, strength k: Float) -> Float {
        pow(value, 1 + 1.2 * k) * (1 - 0.35 * k)
    }

    /// 颗粒的噪声块：xorshift32（种子 0x2545F491），每步取高 8 位，256 × 256，第 0 行在上。安卓 `ImageAdjustmentsDetail.NOISE` 同一组字节。
    static let noiseTile: [UInt8] = {
        var state: UInt32 = 0x2545_F491
        return (0..<(256 * 256)).map { _ in
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            return UInt8(state >> 24)
        }
    }()

    /// 不做颜色管理（`colorSpace: nil`），内核读到的就是字节 / 255。
    private static let noiseImage = CIImage(
        bitmapData: Data(noiseTile),
        bytesPerRow: 256,
        size: CGSize(width: 256, height: 256),
        format: .L8,
        colorSpace: nil,
    )

    private static let kernels: (sharpen: CIKernel, grainVignette: CIKernel)? = {
        // `TellomiImageAdjustments.metal` 编进 SignalUI.framework 自己的 default.metallib（主 App 和分享扩展都带着它）。
        guard
            let url = Bundle(for: ImageEditorModel.self).url(forResource: "default", withExtension: "metallib"),
            let data = try? Data(contentsOf: url)
        else {
            owsFailDebug("SignalUI has no Metal library.")
            return nil
        }
        do {
            return (
                try CIKernel(functionName: "tellomiSharpen", fromMetalLibraryData: data),
                try CIKernel(functionName: "tellomiGrainVignette", fromMetalLibraryData: data),
            )
        } catch {
            owsFailDebug("Could not load the adjustment kernels: \(error)")
            return nil
        }
    }()

    private static func sharpen(_ image: CIImage, amount: Float, unit: CGFloat, colorSpace: CGColorSpace) -> CIImage? {
        guard let kernel = kernels?.sharpen, let encoded = image.matchedFromWorkingSpace(to: colorSpace) else { return nil }
        let extent = image.extent
        // 边上的像素往外取时拿最靠边的那一圈（不然图边会被透明的外面拉暗）。
        let output = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -unit - 1, dy: -unit - 1) },
            arguments: [encoded.clampedToExtent(), Float(unit), amount],
        )
        return output?.cropped(to: extent).matchedToWorkingSpace(from: colorSpace)
    }

    private static func grainAndVignette(
        _ image: CIImage,
        grain: Float,
        grainCell: CGFloat,
        vignette: Float,
        frame: CGAffineTransform,
        colorSpace: CGColorSpace,
    ) -> CIImage? {
        guard let kernel = kernels?.grainVignette, let encoded = image.matchedFromWorkingSpace(to: colorSpace) else { return nil }
        let extent = image.extent
        let noise = noiseImage
        let output = kernel.apply(
            extent: extent,
            roiCallback: { index, rect in index == 0 ? rect : noise.extent },
            arguments: [
                encoded,
                noise,
                grain,
                Float(grainCell),
                vignette,
                CIVector(x: extent.width, y: extent.height),
                CIVector(x: frame.a, y: frame.c, z: frame.tx),
                CIVector(x: frame.b, y: frame.d, z: frame.ty),
            ],
        )
        return output?.matchedToWorkingSpace(from: colorSpace)
    }

    // MARK: - Lookup table

    /// `CIColorCube` 要的数据：RGBA Float32，红变得最快、其次绿、最后蓝。同一组调色只算一次。
    static func cubeData(for adjustments: TellomiImageAdjustments) -> Data {
        if let cachedCube, cachedCube.adjustments == adjustments {
            return cachedCube.data
        }
        let n = cubeDimension
        var values = [Float](repeating: 0, count: n * n * n * 4)
        let scale = 1 / Float(n - 1)
        let splines = CurveSplines(adjustments.curves)
        var index = 0
        for blue in 0..<n {
            for green in 0..<n {
                for red in 0..<n {
                    let color = adjust(SIMD3(Float(red) * scale, Float(green) * scale, Float(blue) * scale), adjustments, splines: splines)
                    values[index] = color.x
                    values[index + 1] = color.y
                    values[index + 2] = color.z
                    values[index + 3] = 1
                    index += 4
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cachedCube = (adjustments, data)
        return data
    }

    // MARK: - Per-pixel math

    /// Rec. 709 / sRGB 的亮度权重。
    private static let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)

    /// 一个编码值（0…1）的颜色调色后的样子。顺序：曲线 → 曝光 → 对比度 → 高光 / 阴影 → 饱和度 → 色温 → 色调 → 褪色，每一步后夹回 0…1。
    /// `splines` 是建查找表时先算好的四条曲线（不传就当场算）。
    static func adjust(_ input: SIMD3<Float>, _ adjustments: TellomiImageAdjustments, splines: CurveSplines? = nil) -> SIMD3<Float> {
        var color = input

        if !adjustments.curves.isDefault {
            let splines = splines ?? CurveSplines(adjustments.curves)
            if let all = splines.all {
                color = SIMD3(all.value(at: color.x), all.value(at: color.y), all.value(at: color.z))
            }
            if let red = splines.red {
                color.x = red.value(at: color.x)
            }
            if let green = splines.green {
                color.y = green.value(at: color.y)
            }
            if let blue = splines.blue {
                color.z = blue.value(at: color.z)
            }
        }

        if adjustments.exposure != 0 {
            let amount = adjustments.exposure / 100
            var linear = toLinear(color)
            if amount > 0 {
                let gain = exp2(2 * amount)
                let boosted = linear * gain
                // 原来的白（1）乘上增益后正好压回 1：x · (1 + x / gain²) / (1 + x)
                linear = boosted * (1 + boosted / (gain * gain)) / (1 + boosted)
            } else {
                linear *= exp2(1.5 * amount)
            }
            color = clamp01(toEncoded(clamp01(linear)))
        }

        if adjustments.contrast != 0 {
            let factor = pow(Float(1.4), adjustments.contrast / 100)
            color = clamp01((color - 0.5) * factor + 0.5)
        }

        if adjustments.highlights != 0 || adjustments.shadows != 0 {
            let y = simd_dot(color, luma)
            let shadows = adjustments.shadows / 100
            let highlights = adjustments.highlights / 100
            let highlightsStrength: Float = highlights > 0 ? 0.14 : 0.08
            let target = min(max(y + 0.08 * shadows * shadowBump(y) + highlightsStrength * highlights * shadowBump(1 - y), 0), 1)
            color = clamp01(y > 1e-4 ? color * (target / y) : color + (target - y))
        }

        if adjustments.saturation != 0 {
            let factor = 1 + adjustments.saturation / 100
            let gray = simd_dot(color, luma)
            color = clamp01(gray + (color - gray) * factor)
        }

        if adjustments.warmth != 0 {
            let amount = adjustments.warmth / 100
            var linear = toLinear(color)
            let before = simd_dot(linear, luma)
            linear *= SIMD3(1 + 0.3 * amount, 1, 1 - 0.3 * amount)
            let after = simd_dot(linear, luma)
            if after > 0 {
                linear *= before / after
            }
            color = clamp01(toEncoded(clamp01(linear)))
        }

        if adjustments.tintShadows != nil || adjustments.tintHighlights != nil {
            let y = simd_dot(color, luma)
            let strength = TellomiImageAdjustments.tintIntensity / 100 * 0.6
            if let shadows = adjustments.tintShadows {
                color = tint(color, toward: shadows, weight: strength * (1 - y) * (1 - y))
            }
            if let highlights = adjustments.tintHighlights {
                color = tint(color, toward: highlights, weight: strength * y * y)
            }
        }

        if adjustments.fade != 0 {
            let amount = adjustments.fade / 100
            let matte = 0.24 + 0.42 * color + 0.24 * color * color
            color = clamp01(color + (matte - color) * amount)
        }

        return color
    }

    /// 一条曲线在 `x`（0…1）处的值，见 `CurveSpline`。
    static func curveValue(_ points: TellomiImageAdjustments.CurvePoints, at x: Float) -> Float {
        CurveSpline(points).value(at: x)
    }

    /// 一条曲线：5 个点之间单调三次插值（Fritsch–Carlson：切线先取两边斜率的平均、两边异号或有一边平就取 0，
    /// 再按 α² + β² ≤ 9 缩小，曲线不会冲过相邻两点），结果夹在 0…1。安卓 `ImageAdjustmentsColor.CurveSpline` 一样。
    /// 建查找表时每条曲线只算一次切线（`CurveSplines`）。
    struct CurveSpline {
        private var y = [Float](repeating: 0, count: 5)
        private var tangents = [Float](repeating: 0, count: 5)

        init(_ points: TellomiImageAdjustments.CurvePoints) {
            y = points.values.map { $0 / 100 }
            var slopes = [Float](repeating: 0, count: 4)
            for k in 0..<4 {
                slopes[k] = (y[k + 1] - y[k]) / Self.step
            }
            tangents[0] = slopes[0]
            tangents[4] = slopes[3]
            for k in 1..<4 {
                tangents[k] = slopes[k - 1] * slopes[k] <= 0 ? 0 : (slopes[k - 1] + slopes[k]) / 2
            }
            for k in 0..<4 {
                if slopes[k] == 0 {
                    tangents[k] = 0
                    tangents[k + 1] = 0
                } else {
                    let alpha = tangents[k] / slopes[k]
                    let beta = tangents[k + 1] / slopes[k]
                    let sum = alpha * alpha + beta * beta
                    if sum > 9 {
                        let tau = 3 / sum.squareRoot()
                        tangents[k] = tau * alpha * slopes[k]
                        tangents[k + 1] = tau * beta * slopes[k]
                    }
                }
            }
        }

        private static let step: Float = 0.25

        func value(at x: Float) -> Float {
            let h = Self.step
            let clampedX = min(max(x, 0), 1)
            let k = min(Int(clampedX / h), 3)
            let t = (clampedX - Float(k) * h) / h
            let t2 = t * t
            let t3 = t2 * t
            let value = (2 * t3 - 3 * t2 + 1) * y[k] + (t3 - 2 * t2 + t) * h * tangents[k]
                + (-2 * t3 + 3 * t2) * y[k + 1] + (t3 - t2) * h * tangents[k + 1]
            return min(max(value, 0), 1)
        }
    }

    /// 四条曲线（在默认值的为 nil，不过）。
    struct CurveSplines {
        let all: CurveSpline?
        let red: CurveSpline?
        let green: CurveSpline?
        let blue: CurveSpline?

        init(_ curves: TellomiImageAdjustments.Curves) {
            all = curves.all.isDefault ? nil : CurveSpline(curves.all)
            red = curves.red.isDefault ? nil : CurveSpline(curves.red)
            green = curves.green.isDefault ? nil : CurveSpline(curves.green)
            blue = curves.blue.isDefault ? nil : CurveSpline(curves.blue)
        }
    }

    /// 往 `tintColor` 的色相偏 `weight`：加上「颜色 − 它自己的亮度」，所以亮度基本不变。
    private static func tint(_ color: SIMD3<Float>, toward tintColor: TellomiImageAdjustments.TintColor, weight: Float) -> SIMD3<Float> {
        let target = SIMD3(tintColor.red, tintColor.green, tintColor.blue)
        return clamp01(color + (target - simd_dot(target, luma)) * weight)
    }

    /// 在亮度 0.25 处最高（= 1）的鼓包，0 和 1 处为 0。
    private static func shadowBump(_ y: Float) -> Float {
        let inverse = 1 - y
        return y * inverse * inverse * inverse * (256 / 27)
    }

    /// sRGB（Display P3 用同一条传递曲线）编码值 → 线性光。
    private static func toLinear(_ color: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(toLinear(color.x), toLinear(color.y), toLinear(color.z))
    }

    private static func toLinear(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private static func toEncoded(_ color: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(toEncoded(color.x), toEncoded(color.y), toEncoded(color.z))
    }

    private static func toEncoded(_ value: Float) -> Float {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private static func clamp01(_ color: SIMD3<Float>) -> SIMD3<Float> {
        simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }
}
