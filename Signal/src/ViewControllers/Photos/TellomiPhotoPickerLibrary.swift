//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import ImageIO
import Photos
import SignalServiceKit
import SignalUI
import UniformTypeIdentifiers

/// Tellomi（tellomi/tellomi#1261）：选图网格里的一项。正式来自系统相册（`asset` 非空）；测试里是内存里的假图（`asset` 为空）。
struct TellomiPhotoPickerItem: Hashable {
    let id: String
    let isVideo: Bool
    let duration: TimeInterval
    /// 实况照片：格子左上角小图标（P-8）；开关与按实况发出是 #1263（P-4）。
    let isLivePhoto: Bool
    /// 动图（GIF 等）：上游预览页不支持裁剪 / 绘制（按通用附件处理），查看器里不给这两个快捷。
    let isAnimatedImage: Bool
    /// 原图像素尺寸：「只看已选」按原比例排卡片（P-3）。
    let pixelSize: CGSize
    let asset: PHAsset?
}

/// Tellomi（#1261 P-1）：顶栏「最近 ⌄」里的一个相册。第一个永远是「最近」。
struct TellomiPhotoPickerAlbum: Hashable {
    let id: String
    let title: String
    let count: Int
    let isRecents: Bool
}

/// Tellomi（#1261）：选图网格读的相册。第 0 项是最新的。
protocol TellomiPhotoPickerLibrary: AnyObject {
    /// 「照片」权限是「有限」时网格顶上出横幅（P-7）。
    var isAccessLimited: Bool { get }
    /// Tellomi（#1115）：用户拒绝了 / 系统限制了照片权限。附件 Sheet 照样打开（dock 里别的格子还要用），网格处显示去「设置」的说明。
    var isAccessDenied: Bool { get }

    func albums() -> [TellomiPhotoPickerAlbum]
    func itemCount(in album: TellomiPhotoPickerAlbum) -> Int
    func item(at index: Int, in album: TellomiPhotoPickerAlbum) -> TellomiPhotoPickerItem

    /// 缩略图；可能回调不止一次（先模糊后清楚）。返回的对象用来取消。
    func requestThumbnail(for item: TellomiPhotoPickerItem, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) -> TellomiPhotoPickerRequest

    func attachment(for item: TellomiPhotoPickerItem, attachmentLimits: OutgoingAttachmentLimits) async throws -> PreviewableAttachment

    /// Tellomi（tellomi/tellomi#1263 P-5「以文件发送」）：是不是 HEIC（已选里有就先问要不要转成 JPEG）。
    func isHeic(_ item: TellomiPhotoPickerItem) -> Bool

    /// Tellomi（#1263）：相册里的原文件名（IMG_1234.HEIC）。编辑过的照片按文件发时沿用它。
    func originalFileName(for item: TellomiPhotoPickerItem) -> String?

    /// Tellomi（#1263）：按文件发的那个文件——相册里的当前版本本身（不压缩、不转码），带原文件名；`convertHeicToJpeg` 时 HEIC 先转成 JPEG。
    /// 超过上限的不出附件，交回文件名，由调用方统一提示。
    func fileAttachment(for item: TellomiPhotoPickerItem, convertHeicToJpeg: Bool, attachmentLimits: OutgoingAttachmentLimits) async throws -> TellomiPhotoPickerFile

    /// Tellomi（#1263 F-3）：相册里当前版本的文件大小（「文件」页相册预览底部的「尺寸 · 时长 · 大小」）；不知道就 nil。
    func fileSize(for item: TellomiPhotoPickerItem) -> Int64?

    /// 相册内容变了（比如「选择更多照片…」之后），网格要重读。
    var onChange: (() -> Void)? { get set }
}

extension TellomiPhotoPickerLibrary {
    func fileSize(for item: TellomiPhotoPickerItem) -> Int64? { nil }
}

protocol TellomiPhotoPickerRequest {
    func cancel()
}

/// Tellomi（#1263）：一项按文件发的结果。
enum TellomiPhotoPickerFile {
    case attachment(PreviewableAttachment)
    /// 超过单个文件的上限，没发。
    case tooLarge(fileName: String)
}

/// 系统相册：「最近」是全部照片与视频按拍摄时间倒序；其余相册是收藏、视频、截屏与用户自己的相册（空的不列）。
final class TellomiSystemPhotoLibrary: NSObject, TellomiPhotoPickerLibrary, PHPhotoLibraryChangeObserver {

    private static let recentsId = "tellomi.recents"

    static var recentsTitle: String {
        OWSLocalizedString("IMAGE_PICKER_TELLOMI_RECENTS", comment: "Title of the album in the photo picker that shows all recent photos and videos.")
    }

    private let imageManager = PHCachingImageManager()
    private var fetchResults = [String: PHFetchResult<PHAsset>]()
    private var collections = [String: PHAssetCollection]()

    var onChange: (() -> Void)?

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    var isAccessDenied: Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .denied, .restricted: return true
        default: return false
        }
    }

    var isAccessLimited: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
    }

    func albums() -> [TellomiPhotoPickerAlbum] {
        var albums = [TellomiPhotoPickerAlbum(
            id: Self.recentsId,
            title: Self.recentsTitle,
            count: fetchResult(forAlbumId: Self.recentsId).count,
            isRecents: true,
        )]

        let smartAlbumSubtypes: [PHAssetCollectionSubtype] = [.smartAlbumFavorites, .smartAlbumVideos, .smartAlbumScreenshots]
        for subtype in smartAlbumSubtypes {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil).enumerateObjects { collection, _, _ in
                self.appendAlbum(for: collection, to: &albums)
            }
        }
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { collection, _, _ in
            self.appendAlbum(for: collection, to: &albums)
        }
        return albums
    }

    private func appendAlbum(for collection: PHAssetCollection, to albums: inout [TellomiPhotoPickerAlbum]) {
        collections[collection.localIdentifier] = collection
        let count = fetchResult(forAlbumId: collection.localIdentifier).count
        guard count > 0 else { return }
        albums.append(TellomiPhotoPickerAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? "", count: count, isRecents: false))
    }

    private func fetchResult(forAlbumId albumId: String) -> PHFetchResult<PHAsset> {
        if let cached = fetchResults[albumId] {
            return cached
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        let result: PHFetchResult<PHAsset>
        if albumId == Self.recentsId {
            result = PHAsset.fetchAssets(with: options)
        } else if let collection = collections[albumId] ?? PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil).firstObject {
            result = PHAsset.fetchAssets(in: collection, options: options)
        } else {
            result = PHFetchResult<PHAsset>()
        }
        fetchResults[albumId] = result
        return result
    }

    func itemCount(in album: TellomiPhotoPickerAlbum) -> Int {
        fetchResult(forAlbumId: album.id).count
    }

    func item(at index: Int, in album: TellomiPhotoPickerAlbum) -> TellomiPhotoPickerItem {
        let asset = fetchResult(forAlbumId: album.id).object(at: index)
        return TellomiPhotoPickerItem(
            id: asset.localIdentifier,
            isVideo: asset.mediaType == .video,
            duration: asset.duration,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            isAnimatedImage: asset.playbackStyle == .imageAnimated,
            pixelSize: CGSize(width: asset.pixelWidth, height: asset.pixelHeight),
            asset: asset,
        )
    }

    private struct ImageRequest: TellomiPhotoPickerRequest {
        let manager: PHImageManager
        let id: PHImageRequestID

        func cancel() {
            manager.cancelImageRequest(id)
        }
    }

    func requestThumbnail(for item: TellomiPhotoPickerItem, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) -> TellomiPhotoPickerRequest {
        guard let asset = item.asset else {
            completion(nil)
            return ImageRequest(manager: imageManager, id: PHInvalidImageRequestID)
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let id = imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: options) { image, _ in
            completion(image)
        }
        return ImageRequest(manager: imageManager, id: id)
    }

    func attachment(for item: TellomiPhotoPickerItem, attachmentLimits: OutgoingAttachmentLimits) async throws -> PreviewableAttachment {
        guard let asset = item.asset else {
            throw OWSAssertionError("Missing asset")
        }
        // 取原数据、视频压成 mp4 都沿用上游（和附件面板里「最近照片」同一段）。
        let contents = PhotoAlbumContents(fetchResult: PHFetchResult<PHAsset>(), limit: 0)
        return try await contents.outgoingAttachment(for: asset, attachmentLimits: attachmentLimits)
    }

    // MARK: - 按文件发送（#1263）

    /// 相册里的当前版本：在「照片」里编辑过的是 fullSize*（用户在网格里看到的就是它），否则是原件。实况照片只取静态图（spec F-3）。
    private static func currentResource(in resources: [PHAssetResource], isVideo: Bool) -> PHAssetResource? {
        let types: [PHAssetResourceType] = isVideo ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        return types.lazy.compactMap { type in resources.first { $0.type == type } }.first
    }

    private static func originalResource(in resources: [PHAssetResource], isVideo: Bool) -> PHAssetResource? {
        resources.first { $0.type == (isVideo ? .video : .photo) }
    }

    func isHeic(_ item: TellomiPhotoPickerItem) -> Bool {
        guard let asset = item.asset, !item.isVideo else { return false }
        let resource = Self.currentResource(in: PHAssetResource.assetResources(for: asset), isVideo: false)
        return resource.map { TellomiHeicConversion.isHeic(uti: $0.uniformTypeIdentifier) } ?? false
    }

    func originalFileName(for item: TellomiPhotoPickerItem) -> String? {
        guard let asset = item.asset else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        return (Self.originalResource(in: resources, isVideo: item.isVideo) ?? Self.currentResource(in: resources, isVideo: item.isVideo))?.originalFilename
    }

    /// `PHAssetResource` 没有公开的大小，系统相册自己记在 `fileSize` 里（KVC）；读不到（以后改名了）就不显示，不崩。
    func fileSize(for item: TellomiPhotoPickerItem) -> Int64? {
        guard let asset = item.asset,
              let resource = Self.currentResource(in: PHAssetResource.assetResources(for: asset), isVideo: item.isVideo),
              resource.responds(to: NSSelectorFromString("fileSize")),
              let size = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value,
              size > 0 else {
            return nil
        }
        return size
    }

    func fileAttachment(for item: TellomiPhotoPickerItem, convertHeicToJpeg: Bool, attachmentLimits: OutgoingAttachmentLimits) async throws -> TellomiPhotoPickerFile {
        guard let asset = item.asset else {
            throw OWSAssertionError("Missing asset")
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = Self.currentResource(in: resources, isVideo: item.isVideo) else {
            throw OWSAssertionError("Missing asset resource")
        }
        var dataUTI = resource.uniformTypeIdentifier
        // 文件名用原件的（IMG_1234.HEIC），后缀跟着当前版本的格式走（在「照片」里编辑过的可能是 JPEG）。
        var fileName = TellomiHeicConversion.fileName(
            Self.originalResource(in: resources, isVideo: item.isVideo)?.originalFilename ?? resource.originalFilename,
            matching: dataUTI,
        )

        var fileUrl = OWSFileSystem.temporaryFileUrl(fileExtension: (fileName as NSString).pathExtension, isAvailableWhileDeviceLocked: false)
        let options = PHAssetResourceRequestOptions()
        // iCloud 里没下到本机的，先下载（同上游取原图）。
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: fileUrl, options: options)

        if convertHeicToJpeg, TellomiHeicConversion.isHeic(uti: dataUTI) {
            if let jpeg = TellomiHeicConversion.convertToJpeg(at: fileUrl) {
                try? OWSFileSystem.deleteFileIfExists(url: fileUrl)
                fileUrl = jpeg
                dataUTI = UTType.jpeg.identifier
                fileName = TellomiHeicConversion.fileName(fileName, matching: dataUTI)
            } else {
                Logger.warn("Couldn't convert a HEIC to JPEG, sending it as it is")
            }
        }

        let dataSource = DataSourcePath(fileUrl: fileUrl, ownership: .owned)
        dataSource.sourceFilename = fileName
        do {
            return .attachment(try PreviewableAttachment.tellomiAsFileAttachment(dataSource: dataSource, dataUTI: dataUTI, attachmentLimits: attachmentLimits))
        } catch SignalAttachmentError.fileSizeTooLarge {
            return .tooLarge(fileName: fileName)
        }
    }

    // MARK: - PHPhotoLibraryChangeObserver

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            self.fetchResults.removeAll()
            self.onChange?()
        }
    }
}

/// Tellomi（tellomi/tellomi#1263 P-5）：按文件发送时的 HEIC 与文件名。电脑端不认 HEIC，用户选了「转成 JPEG」就转；
/// 照 Telegram iOS（`TGMediaAssetModernImageSignals`：写成 JPEG，`.heic` 改成 `.JPG`）的机制，代码是自己写的。
enum TellomiHeicConversion {

    static func isHeic(uti: String) -> Bool {
        guard let type = UTType(uti) else { return false }
        return type.conforms(to: .heic) || type.conforms(to: .heif)
    }

    /// 后缀跟着内容的格式走：IMG_1234.HEIC + JPEG → IMG_1234.JPG（原来是大写就大写）；已经对得上的不动，没有后缀的加上。
    static func fileName(_ fileName: String, matching uti: String) -> String {
        guard let type = UTType(uti), let preferred = type.preferredFilenameExtension else { return fileName }
        let currentExtension = (fileName as NSString).pathExtension
        if !currentExtension.isEmpty, let current = UTType(filenameExtension: currentExtension), current.conforms(to: type) {
            return fileName
        }
        var newExtension = type.conforms(to: .jpeg) ? "jpg" : preferred
        if !currentExtension.isEmpty, currentExtension == currentExtension.uppercased() {
            newExtension = newExtension.uppercased()
        }
        let base = currentExtension.isEmpty ? fileName : (fileName as NSString).deletingPathExtension
        return "\(base).\(newExtension)"
    }

    /// 整张转成 JPEG（质量 0.9），方向、EXIF 等元数据照原图带过去。转不了返回 nil（调用方原样发）。
    static func convertToJpeg(at url: URL) -> URL? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let output = OWSFileSystem.temporaryFileUrl(fileExtension: "jpg", isAvailableWhileDeviceLocked: false)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? OWSFileSystem.deleteFileIfExists(url: output)
            return nil
        }
        return output
    }
}
