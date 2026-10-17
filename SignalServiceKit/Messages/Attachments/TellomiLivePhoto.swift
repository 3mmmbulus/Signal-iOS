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
    private static let appearances = AtomicValue<[String: Appearance]>([:], lock: .init())

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

    /// The nested pointer kept for this still (backups export it). Nil when it is not a live photo.
    static func storedPointer(_ reference: AttachmentReference, tx: DBReadTransaction) -> SSKProtoAttachmentPointer? {
        guard
            case .message(.bodyAttachment) = reference.owner,
            let key = TellomiMediaSpoiler.key(for: reference.owner),
            let data = store.getData(key, transaction: tx)
        else {
            return nil
        }
        return try? SSKProtoAttachmentPointer(serializedData: data)
    }

    // MARK: - Sending (ADR-0068 §4.4, spec P-4)

    /// 要发的动态部分（已经转成 MP4）先放在这里：消息发出去之前要上传（可能重试、可能重启以后才发），发出去以后自己这边播放也用它，
    /// 不用再从 CDN 下一遍。文件名是消息里的位置（`b<行号>.<位置>.mp4`，同 `TellomiMediaSpoiler` 的键）。
    public static var outgoingDirectory: URL {
        OWSFileSystem.appSharedDataDirectoryURL().appendingPathComponent("TellomiLivePhotoOutgoing", isDirectory: true)
    }

    /// 还没传上去的：键 `m<消息行号>`，值 = { 位置: 文件名 }（JSON）。传上去以后指针写进 `store`，这一项留着（重发时看指针还新不新鲜）。
    private static let pendingStore = KeyValueStore(collection: "TellomiLivePhotoPending")

    /// 传上去的指针过了这么久就当已经过期、重传（同上游附件：`AttachmentUploadManagerImpl` 3 天内的复用）。
    static let reuploadAfter: TimeInterval = 3 * 24 * 60 * 60

    /// 选图准备好的 MP4 挪进 `outgoingDirectory`（消息还没落库，先用随机名）。
    public static func stageOutgoingVideo(_ url: URL) throws -> URL {
        let directory = outgoingDirectory
        guard OWSFileSystem.ensureDirectoryExists(directory.path) else {
            throw OWSAssertionError("Couldn't create the live photo directory.")
        }
        let staged = directory.appendingPathComponent("\(UUID().uuidString).mp4")
        try OWSFileSystem.copyFile(from: url, to: staged)
        return staged
    }

    /// 消息落库后（同一个写事务里，进发送队列之前）：这几个位置的静态图有动态部分，记下来等上传。文件改名成位置名。
    static func markOutgoing(messageRowId: Int64, videos: [UInt32: URL], tx: DBWriteTransaction) {
        guard !videos.isEmpty else { return }
        var pending = [String: String]()
        for (order, url) in videos {
            let key = TellomiMediaSpoiler.bodyKey(messageRowId: messageRowId, orderInMessage: order)
            let named = outgoingDirectory.appendingPathComponent("\(key).mp4")
            if url != named {
                try? FileManager.default.removeItem(at: named)
                do {
                    try FileManager.default.moveItem(at: url, to: named)
                } catch {
                    Logger.warn("Couldn't name the live photo video; sending the still only. \(error)")
                    continue
                }
            }
            pending["\(order)"] = named.lastPathComponent
        }
        guard !pending.isEmpty, let data = try? JSONEncoder().encode(pending) else { return }
        pendingStore.setData(data, key: pendingKey(messageRowId: messageRowId), transaction: tx)
    }

    private static func pendingKey(messageRowId: Int64) -> String {
        "m\(messageRowId)"
    }

    static func pendingVideos(messageRowId: Int64, tx: DBReadTransaction) -> [UInt32: URL] {
        guard
            let data = pendingStore.getData(pendingKey(messageRowId: messageRowId), transaction: tx),
            let pending = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: pending.compactMap { order, fileName in
            UInt32(order).map { ($0, outgoingDirectory.appendingPathComponent(fileName)) }
        })
    }

    /// 发送前的上传（`PreparedOutgoingMessage.attachmentUploadOperations`）：动态部分是第二段上传（§4.4「两段各自上传 CDN」），
    /// 传完把指针记在静态图的位置上，组 `AttachmentPointer.tellomi.livePhotoVideo` 时读。指针还新鲜（3 天内）的不重传；
    /// 本机文件没了的跳过（只发静态图，不让整条消息失败）。
    static func uploadOperations(
        messageRowId: Int64,
        now: Date = Date(),
        uploader: @escaping (DataSourcePath) async throws -> SSKProtoAttachmentPointer = TellomiLivePhoto.uploadTransient,
        tx: DBReadTransaction,
    ) -> [() async throws -> Void] {
        return pendingVideos(messageRowId: messageRowId, tx: tx).sorted { $0.key < $1.key }.compactMap { order, url in
            let key = TellomiMediaSpoiler.bodyKey(messageRowId: messageRowId, orderInMessage: order)
            if
                let existing = store.getData(key, transaction: tx).flatMap({ try? SSKProtoAttachmentPointer(serializedData: $0) }),
                existing.hasUploadTimestamp,
                now.timeIntervalSince(Date(millisecondsSince1970: existing.uploadTimestamp)) < reuploadAfter
            {
                return nil
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                Logger.warn("Live photo video is gone; sending the still only.")
                return nil
            }
            return {
                let pointer = try await uploader(DataSourcePath(fileUrl: url, ownership: .borrowed))
                let data = try pointer.serializedData()
                await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
                    store.setData(data, key: key, transaction: tx)
                    // 自己这边的气泡重画：出现实况角标、能播（播的是本机文件）。
                    if let message = InteractionFinder.fetch(rowId: messageRowId, transaction: tx) {
                        SSKEnvironment.shared.databaseStorageRef.touch(interaction: message, shouldReindex: false, tx: tx)
                    }
                }
            }
        }
    }

    /// 和联系人同步文件同一种上传（不落附件表）：加密、拿上传表单、传，交回去的是收方要的那个嵌套指针。
    static func uploadTransient(_ dataSource: DataSourcePath) async throws -> SSKProtoAttachmentPointer {
        let result = try await DependenciesBridge.shared.attachmentUploadManager.uploadTransientAttachment(dataSource: dataSource)
        return videoPointer(
            cdnNumber: result.cdnNumber,
            cdnKey: result.cdnKey,
            key: result.localUploadMetadata.key,
            digest: result.localUploadMetadata.digest,
            plaintextLength: result.localUploadMetadata.plaintextDataLength,
            uploadTimestamp: result.finishTimestamp,
        )
    }

    static func videoPointer(
        cdnNumber: UInt32,
        cdnKey: String,
        key: Data,
        digest: Data,
        plaintextLength: UInt32,
        uploadTimestamp: UInt64,
    ) -> SSKProtoAttachmentPointer {
        let builder = SSKProtoAttachmentPointer.builder()
        builder.setCdnNumber(cdnNumber)
        builder.setCdnKey(cdnKey)
        builder.setContentType("video/mp4")
        builder.setKey(key)
        builder.setDigest(digest)
        builder.setSize(plaintextLength)
        builder.setUploadTimestamp(uploadTimestamp)
        return builder.buildInfallibly()
    }

    /// 自己发的：本机还留着那个 MP4 就直接播，不去 CDN 下。
    static func localOutgoingFile(cacheKey: String) -> URL? {
        let url = outgoingDirectory.appendingPathComponent("\(cacheKey).mp4")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Download

    public struct Video {
        fileprivate let cacheKey: String
        fileprivate let downloadMetadata: AttachmentDownloads.DownloadMetadata
        fileprivate let decryptionMetadata: DecryptionMetadata
    }

    // MARK: - Autoplay

    /// 会话里每次出现都静音放一遍（owner 2026-10-13 照 Telegram：`ChatMessageInteractiveMediaNode` 每次从看不见变成看得见都放）。
    /// 消息更新时整格重建、下载完换成原图，是先 `disappeared` 再马上 `appeared`：离开不到这么久又回来，还算同一次出现，不再放。
    public static let reappearanceGrace: TimeInterval = 0.5

    private struct Appearance {
        var showing = 0
        var hiddenAt: Date?
        var played = false
    }

    /// 一个视图开始显示这张实况（会话里的格子出现了）。
    public static func appeared(_ video: Video, now: Date = Date()) {
        appearances.update { all in
            var appearance = all[video.cacheKey] ?? Appearance()
            if appearance.showing == 0, let hiddenAt = appearance.hiddenAt, now.timeIntervalSince(hiddenAt) >= reappearanceGrace {
                appearance.played = false
            }
            appearance.showing += 1
            all[video.cacheKey] = appearance
        }
    }

    /// 那个视图不再显示它了（滑出屏幕、整格重建、会话页收起）。
    public static func disappeared(_ video: Video, now: Date = Date()) {
        appearances.update { all in
            guard var appearance = all[video.cacheKey], appearance.showing > 0 else { return }
            appearance.showing -= 1
            if appearance.showing == 0 {
                appearance.hiddenAt = now
            }
            all[video.cacheKey] = appearance
        }
    }

    /// 这一次出现还没放过：返回 true 的那一次去放。罩着、原图还没到时先别问，等能放了再问。
    public static func claimAutoplay(_ video: Video) -> Bool {
        appearances.update { all in
            guard var appearance = all[video.cacheKey], appearance.showing > 0, !appearance.played else { return false }
            appearance.played = true
            all[video.cacheKey] = appearance
            return true
        }
    }

#if TESTABLE_BUILD
    public static func resetForTesting() {
        appearances.set([:])
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

    /// 本机现成的动态部分：自己发的那份，或者这次运行里下好的（转发时带上，§4.4「转发」）。没有就是 nil，不会去下。
    public static func localVideoFile(_ video: Video) -> URL? {
        cachedVideo(video) ?? localOutgoingFile(cacheKey: video.cacheKey)
    }

    /// 下载、解密动态部分，返回本机的临时文件；这次运行里下过就直接给。
    public static func fetchVideo(_ video: Video) async throws -> URL {
        if let url = cachedVideo(video) {
            return url
        }
        if let local = localOutgoingFile(cacheKey: video.cacheKey) {
            downloaded.update { $0[video.cacheKey] = local }
            return local
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
