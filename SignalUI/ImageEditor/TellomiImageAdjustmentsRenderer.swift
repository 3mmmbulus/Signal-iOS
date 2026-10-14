//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreImage
import CoreImage.CIFilterBuiltins
import SignalServiceKit
import simd
import UIKit

/// Tellomi（tellomi/tellomi#1592 E5-2，Epic #1523）：把调色画进图里。
///
/// 逐像素的几项（这一刀：曝光、对比度、饱和度、色温）合成一张 3D 查找表，用 CoreImage 的 `CIColorCubeWithColorSpace`
/// 在图自己的颜色空间（sRGB / Display P3 的编码值）里查——预览图和发出的原尺寸图走同一张表，所以两边一致。
/// 后面的逐像素工具（褪色、高光 / 阴影、色调、曲线）往 `adjust(_:_:)` 里加；暗角、颗粒、锐化、模糊这些和位置有关的另走滤镜。
///
/// 每一项的数学是自己定的（Telegram 只用来对照工具、范围和方向，它的着色器一行不搬，见 `docs/product/specs/media-editor-adjustments-e5.md`）：
/// - 曝光：线性光里乘增益，+100 = +2 档、−100 = −1.5 档；调亮时用一个让原来的白仍落在白上的肩，亮部不会一下顶死。
/// - 对比度：绕中灰拉开 / 收拢，系数 1.4^(值/100)。
/// - 饱和度：和同亮度的灰按比例混（Rec. 709 亮度），0…2 倍。
/// - 色温：线性光里红、蓝反向增益（暖 = 红多蓝少），再把亮度拉回原来。
@MainActor
enum TellomiImageAdjustmentsRenderer {

    /// 查找表每边的格数。33 是 .cube 常用的大小，三线性插值下平滑曲线的误差在 1/255 量级。
    static let cubeDimension = 33

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static var cachedCube: (adjustments: TellomiImageAdjustments, data: Data)?

    // MARK: - Images

    /// 把调色画进 `image`。全在默认值时原样返回（整条管线跳过）；出错返回 nil。
    static func apply(_ adjustments: TellomiImageAdjustments, to image: CGImage) -> CGImage? {
        guard !adjustments.isDefault else { return image }

        let colorSpace = workingColorSpace(for: image)
        let input = CIImage(cgImage: image)
        let filter = CIFilter.colorCubeWithColorSpace()
        filter.inputImage = input
        filter.cubeDimension = Float(cubeDimension)
        filter.cubeData = cubeData(for: adjustments)
        filter.colorSpace = colorSpace
        guard let output = filter.outputImage else {
            owsFailDebug("Color cube produced no image.")
            return nil
        }
        return context.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: colorSpace)
    }

    /// 查表用图自己的 RGB 颜色空间（相册里的照片多是 Display P3，换到 sRGB 会把超出 sRGB 的颜色截掉）；
    /// 没有或不是 RGB 的用 sRGB。
    private static func workingColorSpace(for image: CGImage) -> CGColorSpace {
        if let colorSpace = image.colorSpace, colorSpace.model == .rgb {
            return colorSpace
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
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
        var index = 0
        for blue in 0..<n {
            for green in 0..<n {
                for red in 0..<n {
                    let color = adjust(SIMD3(Float(red) * scale, Float(green) * scale, Float(blue) * scale), adjustments)
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

    /// 一个编码值（0…1）的颜色调色后的样子。顺序：曝光 → 对比度 → 饱和度 → 色温，每一步后夹回 0…1。
    static func adjust(_ input: SIMD3<Float>, _ adjustments: TellomiImageAdjustments) -> SIMD3<Float> {
        var color = input

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

        return color
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
