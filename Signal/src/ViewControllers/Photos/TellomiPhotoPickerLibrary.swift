//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Photos
import SignalServiceKit
import SignalUI

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

    /// 相册内容变了（比如「选择更多照片…」之后），网格要重读。
    var onChange: (() -> Void)? { get set }
}

protocol TellomiPhotoPickerRequest {
    func cancel()
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

    // MARK: - PHPhotoLibraryChangeObserver

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            self.fetchResults.removeAll()
            self.onChange?()
        }
    }
}
