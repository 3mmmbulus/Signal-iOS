//
// DRAFT — NOT COMPILED. Parse-checked on Linux only (`swiftc -parse`); UIKit code, needs a Mac.
// Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedImageEncoder+UIKit.swift (new file)
// Mirror of Android `FeedImageUploader.prepare`: re-encode to JPEG, long edge ≤ 2560, quality 0.85.
// Re-drawing the bitmap drops all metadata (EXIF incl. GPS) and bakes in the orientation; that is the privacy requirement (第三节第 22 条).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import UIKit

struct FeedImageEncoder: FeedImageEncoding {
    struct EncodingFailed: Error {}

    /// UNVERIFIED on device: `UIGraphicsImageRenderer` with `format.scale = 1` draws in pixels (not points), `jpegData` strips metadata.
    func jpegData(for image: UIImage) async throws -> Data {
        return try await Task.detached(priority: .userInitiated) {
            let size = FeedImageSizing.targetSize(for: image.size)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let redrawn = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = redrawn.jpegData(compressionQuality: FeedImageSizing.jpegQuality) else {
                throw EncodingFailed()
            }
            return data
        }.value
    }
}
