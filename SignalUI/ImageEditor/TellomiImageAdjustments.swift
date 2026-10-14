//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreGraphics
import Foundation

/// Tellomi（tellomi/tellomi#1591 E5-1，Epic #1523）：一张照片的调色参数（照 Telegram 的「调整」15 项）。
///
/// 只是参数，不带渲染（渲染是 E5-2）。发出去的是烘焙后的普通图片，参数不进协议。
/// 放进 `ImageEditorContents`，跟着撤销 / 重做走；不在默认值就算「编辑过」（`ImageEditorModel.isDirty`：高清项、发出时重新渲染）。
///
/// 范围、默认值照 Telegram iOS 的「调整」（只读，代码是自己写的；`docs/product/specs/media-editor-adjustments-e5.md` 第 1 节）：
/// - 双极 −100…100（0 不变）：曝光 `PGExposureTool`、对比度 `PGContrastTool`、饱和度 `PGSaturationTool`、色温 `PGWarmthTool`、
///   高光 `PGHighlightsTool`、阴影 `PGShadowsTool`；
/// - 单极 0…100（0 不变）：美肤 `PGSkinTool`、增强 `PGEnhanceTool`、褪色 `PGFadeTool`、暗角 `PGVignetteTool`、颗粒 `PGGrainTool`、
///   锐化 `PGSharpenTool`；
/// - 色调 `PGTintTool`：暗部、亮部各一个颜色（没选 = 不加），强度两端都固定 50%（TG 安卓写死，iOS 能调的那条按 O8 不做）；
/// - 曲线 `PGCurvesTool`：全部 / 红 / 绿 / 蓝 4 条，每条 5 个点（黑 0、暗 25、中 50、亮 75、白 100）；
/// - 模糊 `PGBlurTool`：关 / 径向 / 线性，中心 (0.5, 0.5)、大小 0.24、过渡 0.12、角度 0（iOS 的默认；强度按 O8 不做）。
public struct TellomiImageAdjustments: Equatable, Codable {

    // MARK: Scalars

    /// 美肤 0…100（只在检测到人脸时出现，E5-9）。
    public var skin: Float = 0
    /// 增强 0…100。
    public var enhance: Float = 0
    /// 曝光 −100…100。
    public var exposure: Float = 0
    /// 对比度 −100…100。
    public var contrast: Float = 0
    /// 饱和度 −100…100。
    public var saturation: Float = 0
    /// 色温 −100…100。
    public var warmth: Float = 0
    /// 褪色 0…100。
    public var fade: Float = 0
    /// 高光 −100…100。
    public var highlights: Float = 0
    /// 阴影 −100…100。
    public var shadows: Float = 0
    /// 暗角 0…100。
    public var vignette: Float = 0
    /// 颗粒 0…100（只用于照片）。
    public var grain: Float = 0
    /// 锐化 0…100。
    public var sharpen: Float = 0

    // MARK: Tint

    /// 暗部色调；nil = 不加。
    public var tintShadows: TintColor?
    /// 亮部色调；nil = 不加。
    public var tintHighlights: TintColor?

    /// 色调强度：两端固定 50%（O8）。
    public static let tintIntensity: Float = 50

    // MARK: Curves and blur

    public var curves = Curves()
    public var blur = Blur()

    public init() {}

    public static let `default` = TellomiImageAdjustments()

    /// 全在默认值：渲染整条跳过，也不算编辑过（同 TG 两端各工具的 `isDefault` / `shouldBeSkipped`）。
    /// 模糊关着时它的中心、大小等不算（拖过再关掉，仍是没调过）。
    public var isDefault: Bool {
        scalars.allSatisfy { $0 == 0 }
            && tintShadows == nil
            && tintHighlights == nil
            && curves.isDefault
            && blur.isDefault
    }

    /// 12 个标量（顺序同上面的声明）。
    var scalars: [Float] {
        [skin, enhance, exposure, contrast, saturation, warmth, fade, highlights, shadows, vignette, grain, sharpen]
    }

    // MARK: - Ranges

    public enum Tool: CaseIterable {
        case skin, enhance, exposure, contrast, saturation, warmth, fade, highlights, shadows, vignette, grain, sharpen

        /// 双极（−100…100）还是单极（0…100）。
        public var isBipolar: Bool {
            switch self {
            case .exposure, .contrast, .saturation, .warmth, .highlights, .shadows:
                return true
            case .skin, .enhance, .fade, .vignette, .grain, .sharpen:
                return false
            }
        }

        public var range: ClosedRange<Float> {
            isBipolar ? -100...100 : 0...100
        }
    }

    public subscript(tool: Tool) -> Float {
        get {
            switch tool {
            case .skin: return skin
            case .enhance: return enhance
            case .exposure: return exposure
            case .contrast: return contrast
            case .saturation: return saturation
            case .warmth: return warmth
            case .fade: return fade
            case .highlights: return highlights
            case .shadows: return shadows
            case .vignette: return vignette
            case .grain: return grain
            case .sharpen: return sharpen
            }
        }
        set {
            let value = min(max(newValue, tool.range.lowerBound), tool.range.upperBound)
            switch tool {
            case .skin: skin = value
            case .enhance: enhance = value
            case .exposure: exposure = value
            case .contrast: contrast = value
            case .saturation: saturation = value
            case .warmth: warmth = value
            case .fade: fade = value
            case .highlights: highlights = value
            case .shadows: shadows = value
            case .vignette: vignette = value
            case .grain: grain = value
            case .sharpen: sharpen = value
            }
        }
    }

    // MARK: - Types

    /// 色调颜色（sRGB，0…1）。色板在 E5-6 定。
    public struct TintColor: Equatable, Codable {
        public var red: Float
        public var green: Float
        public var blue: Float

        public init(red: Float, green: Float, blue: Float) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// 0xRRGGBB。
        public init(rgb: UInt32) {
            self.init(red: Float((rgb >> 16) & 0xFF) / 255, green: Float((rgb >> 8) & 0xFF) / 255, blue: Float(rgb & 0xFF) / 255)
        }

        /// Tellomi（tellomi/tellomi#1596 E5-6）：暗部色调的色板，第一个（nil）是「不加」。颜色是自己挑的（偏深），个数和 Telegram 两端一样
        /// （8 个）；安卓 `ImageAdjustments.TINT_SHADOWS_PALETTE` 是同一组。
        public static let shadowsPalette: [TintColor?] = [nil] + [0xD14B3F, 0xD9822B, 0xC9A227, 0x3F9E5B, 0x2E8FA8, 0x2F5FD0, 0x7A45C2].map { TintColor(rgb: $0) }

        /// 亮部色调的色板（偏浅），同上。
        public static let highlightsPalette: [TintColor?] = [nil] + [0xFF8A80, 0xFFB870, 0xFFE27A, 0x9EE6A8, 0x8EDDF0, 0x8CB4FF, 0xC9A2FF].map { TintColor(rgb: $0) }
    }

    /// 一条曲线的 5 个控制点（输出值 0…100；输入固定在 0 / 25 / 50 / 75 / 100）。
    public struct CurvePoints: Equatable, Codable {
        public var blacks: Float = 0
        public var shadows: Float = 25
        public var midtones: Float = 50
        public var highlights: Float = 75
        public var whites: Float = 100

        public init() {}

        public static let identity = CurvePoints()

        public var isDefault: Bool { self == .identity }

        public var values: [Float] { [blacks, shadows, midtones, highlights, whites] }
    }

    /// 全部 / 红 / 绿 / 蓝 4 条曲线。
    public struct Curves: Equatable, Codable {
        public var all = CurvePoints()
        public var red = CurvePoints()
        public var green = CurvePoints()
        public var blue = CurvePoints()

        public init() {}

        public var isDefault: Bool {
            all.isDefault && red.isDefault && green.isDefault && blue.isDefault
        }
    }

    /// 模糊（移轴）：关 / 径向 / 线性。中心是相对图宽高的 0…1 坐标；大小、过渡是相对图的比例（怎么换算成像素在 E5-8 定）；角度是弧度。
    /// 默认值照 TG iOS `PGBlurTool` 的 `defaultValue`（安卓那边照 TG 安卓是 0.35 / 0.15 / π/2，两端各照各的）。
    public struct Blur: Equatable, Codable {
        public enum Kind: String, Codable {
            case off
            case radial
            case linear
        }

        public var kind: Kind = .off
        public var centerX: Float = 0.5
        public var centerY: Float = 0.5
        public var size: Float = 0.24
        public var falloff: Float = 0.12
        public var angle: Float = 0

        public init() {}

        /// 关着就不算调过，别的参数（上次拖过的中心等）不管。
        public var isDefault: Bool { kind == .off }
    }
}
