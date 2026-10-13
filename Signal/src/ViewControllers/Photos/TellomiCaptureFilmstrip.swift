//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1520 C-7，owner 定 O1：照 Telegram 聊天路径）：拍下的留在相机时，快门上方的一条胶片条，按拍的先后排，
/// 新拍的一张自动滚进来；点一张到预览页里看它（在那里删掉、裁剪、加说明），发送键在相机右下角。
///
/// Telegram reference（只看机制，一行没搬）：iOS `TGCameraMainView` 点结果缩略图 `resultPressed(index)` 打开那一张；
/// Android `ChatAttachAlertPhotoLayout.cameraPhotoRecyclerView`（快门上方的横条）。Tellomi 点一下照 iOS 打开那一张——
/// 安卓那边点一下是切换勾选，可预览页里去掉一张就是删掉，不适合放在这么小的格子上。
final class TellomiCaptureFilmstrip: UIView, GalleryRailViewDelegate {

    static let itemSize: CGFloat = 56

    /// 点了哪一张。
    var onTapItem: ((AttachmentApprovalItem) -> Void)?

    private let railView = GalleryRailView()
    private var items = Items(railItems: [])

    override init(frame: CGRect) {
        super.init(frame: frame)

        // 上游的条不裁边（预览页里它本来就铺满宽度）；这里两边留了空，滚出去的格子不该画到外面。
        clipsToBounds = true

        railView.itemSize = Self.itemSize
        railView.scrollFocusMode = .keepWithinBounds
        railView.delegate = self
        railView.preservesSuperviewLayoutMargins = false
        railView.layoutMargins = .zero
        railView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(railView)
        NSLayoutConstraint.activate([
            railView.topAnchor.constraint(equalTo: topAnchor),
            railView.leadingAnchor.constraint(equalTo: leadingAnchor),
            railView.trailingAnchor.constraint(equalTo: trailingAnchor),
            railView.bottomAnchor.constraint(equalTo: bottomAnchor),
            railView.heightAnchor.constraint(equalToConstant: Self.itemSize),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 换成这几张（按拍的先后）；最后一张是新拍的，滚到它。没有就什么都不留。
    func update(captures: [AttachmentApprovalItem], animated: Bool) {
        let railItems: [GalleryRailItem] = captures
        guard let newest = captures.last else {
            items = Items(railItems: [])
            railView.configureCellViews(itemProvider: items, focusedItem: EmptyItem(), cellViewBuilder: { _ in GalleryRailCellView() }, animated: false)
            return
        }
        // 每次换一个新的 provider：上游按 provider 是不是同一个、条目是不是同一批来决定要不要重建格子。
        if !Self.isSame(railItems, items.railItems) {
            items = Items(railItems: railItems)
        }
        railView.configureCellViews(
            itemProvider: items,
            focusedItem: newest,
            cellViewBuilder: { item in Self.cellView(for: item) },
            animated: animated,
        )
    }

    /// 读屏、测试用：现在条里有几张。
    var itemCount: Int { items.railItems.count }

    private static func isSame(_ lhs: [GalleryRailItem], _ rhs: [GalleryRailItem]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.isEqualToGalleryRailItem($1) }
    }

    /// 每一格同一个样子：白描边圆角缩略图（新拍的那张不另外标，它只是滚到能看见），视频右下角一个播放标。
    private static func cellView(for item: GalleryRailItem) -> GalleryRailCellView {
        let border = UIColor.white.withAlphaComponent(0.6)
        let cell = GalleryRailCellView(configuration: GalleryRailCellConfiguration(
            cornerRadius: 8,
            itemBorderWidth: 1,
            itemBorderColor: border,
            focusedItemBorderWidth: 1,
            focusedItemBorderColor: border,
            focusedItemOverlayColor: nil,
        ))
        let isVideo = (item as? AttachmentApprovalItem)?.attachment.isVideo == true
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .button
        cell.accessibilityLabel = isVideo ? CommonStrings.attachmentTypeVideo : CommonStrings.attachmentTypePhoto
        if isVideo {
            let playIcon = UIImageView(image: UIImage(systemName: "play.fill"))
            playIcon.tintColor = .white
            playIcon.contentMode = .scaleAspectFit
            playIcon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(playIcon)
            NSLayoutConstraint.activate([
                playIcon.widthAnchor.constraint(equalToConstant: 14),
                playIcon.heightAnchor.constraint(equalToConstant: 14),
                playIcon.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                playIcon.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
        }
        return cell
    }

    // MARK: - GalleryRailViewDelegate

    func galleryRailView(_ galleryRailView: GalleryRailView, didTapItem imageRailItem: GalleryRailItem) {
        guard let item = imageRailItem as? AttachmentApprovalItem else {
            owsFailDebug("Unexpected rail item")
            return
        }
        onTapItem?(item)
    }

    /// 测试用：点第几张。
    func tapItemForTesting(at index: Int) {
        guard index < items.railItems.count else { return }
        galleryRailView(railView, didTapItem: items.railItems[index])
    }

    // MARK: -

    private final class Items: GalleryRailItemProvider {
        let railItems: [GalleryRailItem]

        init(railItems: [GalleryRailItem]) {
            self.railItems = railItems
        }
    }

    /// 没有拍下的时候给上游一个「焦点」占位：条里没有格子，它什么都不匹配。
    private struct EmptyItem: GalleryRailItem {
        func buildRailItemView() -> UIView { UIView() }
        func isEqualToGalleryRailItem(_ other: GalleryRailItem?) -> Bool { false }
    }
}
