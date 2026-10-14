//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import Foundation

/// Tellomi（tellomi/tellomi#1518 V-7 ②）：相册视频的原件——选了画质档的视频发送时从它重新导出（选图时上游已经压成 360p，
/// 再从压过的版本放大没有意义）。`pixelSize` 是原件的像素尺寸，决定能选哪些档。
public struct TellomiVideoSource: Equatable {
    public let assetIdentifier: String
    public let pixelSize: CGSize

    public init(assetIdentifier: String, pixelSize: CGSize) {
        self.assetIdentifier = assetIdentifier
        self.pixelSize = pixelSize
    }
}

/// Tellomi（tellomi/tellomi#1518 V-7 ②，照 Telegram 两端「每个视频各选画质」）：视频的画质档。
///
/// 用系统的导出预设（它们按框缩放、不放大、码率由系统定）：360p 就是上游现在所有相册视频都用的 640×480 框，
/// 其余是 960×540、1280×720、1920×1080。TG iOS 是 240p…1080p 五档（`TGPhotoQualityController`），TG 安卓按长边
/// 480 / 854 / 1280 / 1920（安卓 Tellomi 照它做了 270 / 480 / 720 / 1080）；两端 TG 的档本来就不一样，iOS 这边用
/// 系统有的预设，不自己写编码器。
///
/// 只给框不比原片大的档（再大也只是原样，没有意义），另外按导出会话估的大小去掉超过上传上限的档。
public enum TellomiVideoLevel: Int, CaseIterable, Comparable {
    case p360
    case p540
    case p720
    case p1080

    /// 上游选图时就按这一档压（`PreviewableAttachment.compressVideoAsMp4`），没选过档的视频就是它。
    public static let upstreamDefault: TellomiVideoLevel = .p360

    public var exportPreset: String {
        switch self {
        case .p360: return AVAssetExportPreset640x480
        case .p540: return AVAssetExportPreset960x540
        case .p720: return AVAssetExportPreset1280x720
        case .p1080: return AVAssetExportPreset1920x1080
        }
    }

    /// 预设的框（长边 × 短边）。
    public var box: CGSize {
        switch self {
        case .p360: return CGSize(width: 640, height: 480)
        case .p540: return CGSize(width: 960, height: 540)
        case .p720: return CGSize(width: 1280, height: 720)
        case .p1080: return CGSize(width: 1920, height: 1080)
        }
    }

    public var label: String {
        switch self {
        case .p360: return "360p"
        case .p540: return "540p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        }
    }

    public var isHighDefinition: Bool { self >= .p720 }

    public static func < (lhs: TellomiVideoLevel, rhs: TellomiVideoLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 原片（显示尺寸）放得下的档：比 360p 大的档要原片两边都不小于它的框（横竖都算），360p 总在。
    public static func available(forDisplaySize displaySize: CGSize) -> [TellomiVideoLevel] {
        let longSide = max(displaySize.width, displaySize.height)
        let shortSide = min(displaySize.width, displaySize.height)
        guard longSide > 0, shortSide > 0 else { return [] }
        return allCases.filter { level in
            level == .p360 || (longSide >= level.box.width && shortSide >= level.box.height)
        }
    }
}
