//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedAPI+Upload.swift (new file)
// Mirror of Android `FeedApi.startUpload / uploadChunk / uploadOffset` and `FeedUploadStart` (tus 1.0, engine docs/api.md「图片上传」).
// Needs patch I-2/01 (FeedAPI's request/send helpers are no longer private).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// `POST /v1/feed/media/uploads` 的回包：`key` 发帖时放进 `media_keys`。
struct FeedUploadStart: Decodable, Equatable {
    var id: String
    var key: String
}

extension FeedAPI {
    static let uploadsPath = ["v1", "feed", "media", "uploads"]
    static let tusVersion = "1.0.0"
    static let tusChunkContentType = "application/offset+octet-stream"

    /// 图片上传（tus 1.0）第一步：报总长度，拿上传 id 和最终的 media key。
    /// 413 `too_large`（超过 20 MB）、429 `too_many_uploads`（同时没传完的超过 20 个）。
    func startUpload(length: Int) async throws -> FeedUploadStart {
        let pending = request(
            path: Self.uploadsPath,
            method: "POST",
            headers: ["Tus-Resumable": Self.tusVersion, "Upload-Length": String(length)],
        )
        return try await send(FeedUploadStart.self, pending)
    }

    /// 从 `offset` 接着传一块，返回服务端的新偏移（响应头 `Upload-Offset`；没带就按 offset + 块长算，和 Android 一样）。
    /// 偏移对不上是 409 `offset_mismatch`；最后一块不是图片是 415。
    func uploadChunk(id: String, offset: Int, chunk: Data) async throws -> Int {
        let pending = request(
            path: Self.uploadsPath + [id],
            method: "PATCH",
            body: chunk,
            headers: ["Tus-Resumable": Self.tusVersion, "Upload-Offset": String(offset)],
            contentType: Self.tusChunkContentType,
        )
        let (_, response) = try await executeWithResponse(pending)
        return response.value(forHTTPHeaderField: "Upload-Offset").flatMap { Int($0) } ?? offset + chunk.count
    }

    /// 断线后问服务端收到了多少（没带头就当 0，和 Android 一样）。
    func uploadOffset(id: String) async throws -> Int {
        let pending = request(
            path: Self.uploadsPath + [id],
            method: "HEAD",
            headers: ["Tus-Resumable": Self.tusVersion],
        )
        let (_, response) = try await executeWithResponse(pending)
        return response.value(forHTTPHeaderField: "Upload-Offset").flatMap { Int($0) } ?? 0
    }
}
