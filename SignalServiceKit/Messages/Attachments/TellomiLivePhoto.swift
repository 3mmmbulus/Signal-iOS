//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1263，ADR-0068 §4.1，spec R-2）：收到的实况照片的动态部分。
///
/// 静态图照常是一个附件；动态部分的 `AttachmentPointer`（`AttachmentPointer.tellomi.livePhotoVideo`）按静态图在消息里的位置
/// 存进一个 KeyValueStore（键同 `TellomiMediaSpoiler`），不另建附件、不加附件引用的新 owner 类型（不进相册、媒体页、
/// 备份、转发那些查询）。第一次要播时临时下载、解密（`downloadTransientAttachment`，同联系人同步），这次运行里留着；
/// 下载不了就只显示静态图。
public enum TellomiLivePhoto {

    private static let store = KeyValueStore(collection: "TellomiLivePhotoVideo")

    /// 动态部分最多这么大，超了不下。
    private static let maxVideoBytes: UInt32 = 30 * 1024 * 1024

    private static let downloaded = AtomicValue<[String: URL]>([:], lock: .init())
    private static let autoplayed = AtomicSet<String>(lock: .init())

    // MARK: - Wire

    /// 收到的指针上的动态部分（ADR-0068 §4.1）：只在静态图上；同时 asFile 的按文件；嵌套的那个是视频、有 CDN 位置和密钥、
    /// 只能一层。别的情况忽略这个字段，静态图照常显示。
    public static func videoPointer(_ proto: SSKProtoAttachmentPointer, mimeType: String) -> SSKProtoAttachmentPointer? {
        guard
            let tellomi = proto.tellomi,
            !tellomi.asFile,
            let video = tellomi.livePhotoVideo,
            mimeType.lowercased().hasPrefix("image/"),
            (video.contentType ?? "").lowercased().hasPrefix("video/"),
            video.tellomi?.livePhotoVideo == nil,
            video.cdnKey?.nilIfEmpty != nil,
            video.key?.nilIfEmpty != nil,
            video.digest?.nilIfEmpty != nil,
            video.hasSize, video.size > 0, video.size <= maxVideoBytes
        else {
            return nil
        }
        return video
    }

    /// 收到 / 同步来的正文附件落库时调：是实况就把动态部分的指针记下来。
    static func markReceived(
        _ proto: SSKProtoAttachmentPointer,
        mimeType: String,
        owner: AttachmentReference.OwnerBuilder,
        tx: DBWriteTransaction,
    ) {
        guard
            case .messageBodyAttachment = owner,
            let video = videoPointer(proto, mimeType: mimeType),
            let key = TellomiMediaSpoiler.key(for: owner),
            let data = try? video.serializedData()
        else {
            return
        }
        store.setData(data, key: key, transaction: tx)
    }

    // MARK: - Local state

    public static func isLivePhoto(_ reference: AttachmentReference, tx: DBReadTransaction) -> Bool {
        return storedPointer(reference, tx: tx) != nil
    }

    /// 动态部分的下载信息；不是实况、或者存的东西读不出来就是 nil。
    public static func video(_ reference: AttachmentReference, tx: DBReadTransaction) -> Video? {
        guard
            let pointer = storedPointer(reference, tx: tx),
            let cdnKey = pointer.cdnKey?.nilIfEmpty,
            let combinedKey = pointer.key,
            let attachmentKey = try? AttachmentKey(combinedKey: combinedKey),
            let digest = pointer.digest,
            let key = TellomiMediaSpoiler.key(for: reference.owner)
        else {
            return nil
        }
        return Video(
            cacheKey: key,
            downloadMetadata: AttachmentDownloads.DownloadMetadata(cdnNumber: pointer.cdnNumber, source: .transitTier(cdnKey: cdnKey)),
            decryptionMetadata: DecryptionMetadata(
                key: attachmentKey,
                integrityCheck: .ciphertextDigest(digest),
                plaintextLength: UInt64(pointer.size),
            ),
        )
    }

    /// 编辑消息时旧版本另起一行、附件复制过去：动态部分跟过去。
    static func copyForPastRevision(
        latestRevisionRowId: Int64,
        priorRevisionRowId: Int64,
        orderInMessage: UInt32,
        tx: DBWriteTransaction,
    ) {
        let from = TellomiMediaSpoiler.bodyKey(messageRowId: latestRevisionRowId, orderInMessage: orderInMessage)
        guard let data = store.getData(from, transaction: tx) else { return }
        store.setData(data, key: TellomiMediaSpoiler.bodyKey(messageRowId: priorRevisionRowId, orderInMessage: orderInMessage), transaction: tx)
    }

    private static func storedPointer(_ reference: AttachmentReference, tx: DBReadTransaction) -> SSKProtoAttachmentPointer? {
        guard
            case .message(.bodyAttachment) = reference.owner,
            let key = TellomiMediaSpoiler.key(for: reference.owner),
            let data = store.getData(key, transaction: tx)
        else {
            return nil
        }
        return try? SSKProtoAttachmentPointer(serializedData: data)
    }

    // MARK: - Download

    public struct Video {
        fileprivate let cacheKey: String
        fileprivate let downloadMetadata: AttachmentDownloads.DownloadMetadata
        fileprivate let decryptionMetadata: DecryptionMetadata
    }

    /// 会话里第一次出现时自动静音放一遍（spec R-2）：这次运行里每张只放一次，返回 true 的那一次去放。
    /// Telegram iOS 是每次出现都放；spec 写的是「第一次出现时」。
    public static func claimAutoplay(_ video: Video) -> Bool {
        guard !autoplayed.contains(video.cacheKey) else { return false }
        autoplayed.insert(video.cacheKey)
        return true
    }

#if TESTABLE_BUILD
    public static func resetForTesting() {
        autoplayed.removeAllValues()
        downloaded.set([:])
    }

    /// Tests have nothing to download from: the moving half is this local file.
    public static func cacheVideoForTesting(_ video: Video, url: URL) {
        downloaded.update { $0[video.cacheKey] = url }
    }
#endif

    /// 这次运行里已经下好的动态部分（没有就是 nil，不会去下）。
    public static func cachedVideo(_ video: Video) -> URL? {
        return downloaded.get()[video.cacheKey]
    }

    /// 下载、解密动态部分，返回本机的临时文件；这次运行里下过就直接给。
    public static func fetchVideo(_ video: Video) async throws -> URL {
        if let url = cachedVideo(video) {
            return url
        }
        let decrypted = try await DependenciesBridge.shared.attachmentDownloadManager.downloadTransientAttachment(
            downloadMetadata: video.downloadMetadata,
            decryptionMetadata: video.decryptionMetadata,
            progressBlock: { _ in },
        )
        // AVPlayer 认扩展名：放成 .mp4
        let playable = decrypted.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: playable)
        try FileManager.default.moveItem(at: decrypted, to: playable)
        downloaded.update { $0[video.cacheKey] = playable }
        return playable
    }
}
