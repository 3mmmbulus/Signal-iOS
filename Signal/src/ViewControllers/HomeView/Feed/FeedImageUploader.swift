//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedImageUploader.swift (new file)
// Mirror of Android `feed/net/FeedImageUploader.kt` (upload loop) — the byte preparation (`prepare`) is in `FeedImageEncoder+UIKit.swift`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import UIKit

/// 把一张图传到内容引擎（tus 1.0，引擎 `docs/api.md`「图片上传」），返回发帖用的 media key。
///
/// 一块 `chunkSize` 字节；断线或偏移对不上时用 HEAD 问服务端收到了多少，从那里接着传，最多接 `maxResumes` 次。
/// 和 Android 的差别：服务端回的偏移没有往前走（卡住）也算一次续传，不会无限循环；`CancellationError` 不续传；5xx 续传（见 `isResumable`）。
struct FeedImageUploader {
    static let chunkSize = 512 * 1024
    static let maxResumes = 3
    static let offsetMismatchCode = "offset_mismatch"

    let api: FeedAPI
    var chunkSize = FeedImageUploader.chunkSize
    var maxResumes = FeedImageUploader.maxResumes
    /// 被限速（429 / 带 `Retry-After` 的 503）时等多久再续传；测试里换成不真等的。
    var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    func upload(_ bytes: Data) async throws -> String {
        let start = try await api.startUpload(length: bytes.count)
        var offset = 0
        var resumes = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            do {
                let next = try await api.uploadChunk(id: start.id, offset: offset, chunk: bytes.subdata(in: (bytes.startIndex + offset)..<(bytes.startIndex + end)))
                guard next > offset else {
                    // 服务端说收到了，偏移却没动：当作一次中断，问一下它现在在哪
                    throw StuckUpload()
                }
                offset = min(next, bytes.count)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.isResumable(error) else { throw error }
                resumes += 1
                if resumes > maxResumes { throw error }
                // 服务端（或 `FeedAPI` 的限速门）说要等：等够了再问偏移，不然 HEAD 也会被拒（I-21）
                if let apiError = error as? FeedAPIError, apiError.isThrottle, let wait = apiError.retryAfterSeconds {
                    try await sleep(TimeInterval(FeedRetryAfter.clamp(wait)))
                }
                Logger.warn("feed upload interrupted at \(offset), asking the server where to resume: \(error)")
                offset = min(try await api.uploadOffset(id: start.id), bytes.count)
            }
        }
        return start.key
    }

    private struct StuckUpload: Error {}

    /// 引擎答了错（`FeedAPIError`）的：409 `offset_mismatch` 能续；5xx 也能续——引擎存储（本机盘 / R2，#53）出错时 `PATCH` 回 500 `internal`，
    /// 上传的偏移不动（数据库里的偏移为准，桶里多出的尾巴下次被截掉），所以用 HEAD 问偏移后同一块可以重发；反代的 502 / 503 / 504 同理。
    /// 其余（400、404、413、415、429……）直接抛；没拿到答复的（断线、超时：`URLError` 等）能续。
    /// 持续的 5xx 由 `maxResumes` 兜底（最多再问、再传 `maxResumes` 次）。和 Android 的差别：Android 的 `FeedImageUploader` 把 5xx 直接抛出（2026-10-16 对账记录 D-1）。
    static func isResumable(_ error: Error) -> Bool {
        if error is StuckUpload { return true }
        if (error as? URLError)?.code == .cancelled { return false }
        guard let apiError = error as? FeedAPIError else { return true }
        if (500...599).contains(apiError.status) { return true }
        return apiError.status == 409 && apiError.code == offsetMismatchCode
    }
}

/// 把选中的图变成要上传的字节：一律重新编码成 JPEG，顺带去掉 EXIF（包括拍摄位置，第三节第 22 条），
/// HEIC 也转成 JPEG（引擎只收 JPEG / PNG / WebP）。真正的实现是 `FeedImageEncoder+UIKit.swift`；测试换成假的。
protocol FeedImageEncoding {
    func jpegData(for image: UIImage) async throws -> Data
}

/// 长边上限和质量：够在手机上看清，远低于引擎的 20 MB / 12000 像素（Android `FeedImageUploader.MAX_DIMENSION` / `JPEG_QUALITY`）。
enum FeedImageSizing {
    static let maxDimension: CGFloat = 2560
    static let jpegQuality: CGFloat = 0.85

    /// 长边超过 `maxDimension` 就等比缩小；不放大。
    static func targetSize(for size: CGSize) -> CGSize {
        let longEdge = max(size.width, size.height)
        guard longEdge > maxDimension, longEdge > 0 else { return size }
        let scale = maxDimension / longEdge
        return CGSize(width: max((size.width * scale).rounded(), 1), height: max((size.height * scale).rounded(), 1))
    }
}
