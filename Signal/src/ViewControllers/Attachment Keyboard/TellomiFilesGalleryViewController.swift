//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol TellomiFilesGalleryDelegate: AnyObject {
    /// 左上返回、底栏「取消」：回聊天（附件 Sheet 在打开网格之前已经收起），已选的不要了。
    func filesGalleryDidCancel(_ gallery: TellomiFilesGalleryViewController)
    /// 「发送（N）」或预览里的发送：按勾选的顺序；[convertHeicToJpeg] 时其中的 HEIC 先转成 JPEG；[caption] 挂在最后一个文件上。
    func filesGallery(_ gallery: TellomiFilesGalleryViewController, send items: [TellomiPhotoPickerItem], convertHeicToJpeg: Bool, caption: String?)
}

/// Tellomi（tellomi/tellomi#1263 F-3，`attachment-files-location.md`）：「文件」页「从相册中选择」——全屏相册网格的文件模式。
///
/// 照 Telegram 的文件模式相册（iOS 老相册选择器 `TGMediaAssetsController` 的 SendFileIntent、Android
/// `PhotoPickerActivity.setDocumentsPicker`，只读机制）：会话页先收起附件 Sheet 再整屏推出它；顶栏左返回、中间相册标题（点开换相册），
/// 3 列正方形格子、右上编号勾，最多 [maxSelection]（同 Telegram 的 100），底栏「取消 / 发送（N）」，一个都没选时发送置灰。
/// 点照片打开预览（owner 2026-10-13 照 Telegram）：[TellomiPhotoPickerAlbumViewer] 的文件模式——不能编辑、底部文件信息 + 说明 + 发送，
/// 一个都没勾时发正在看的这一张。说明整批一个，挂在最后一个文件上（同「文件」页多选 F-8）。
/// 发出去的是相册里的原文件、原文件名（ADR-0068 `asFile`），一个一条；勾的里有 HEIC 先问要不要转成 JPEG
/// （同 Telegram iOS 文件模式 `asFile && hasHeic`，也同「···」以文件发送）。
final class TellomiFilesGalleryViewController: OWSViewController, UICollectionViewDataSource, UICollectionViewDelegate {

    static let maxSelection = 100

    private enum Metrics {
        static let topBarHeight: CGFloat = 56
        static let roundButtonSize: CGFloat = 44
        static let bottomBarHeight: CGFloat = 60
        static let gridSpacing: CGFloat = 1
    }

    weak var delegate: TellomiFilesGalleryDelegate?

    let library: TellomiPhotoPickerLibrary

    private var albums = [TellomiPhotoPickerAlbum]()
    private(set) var currentAlbum: TellomiPhotoPickerAlbum?
    /// 勾的顺序就是发出去的顺序。
    private(set) var selectedIds = [String]()
    private var selectedItems = [String: TellomiPhotoPickerItem]()
    /// 预览里写的说明（整批一个）。
    private(set) var caption = ""

    init(library: TellomiPhotoPickerLibrary) {
        self.library = library
        super.init()
    }

    // MARK: - Views

    private let topBar = UIView()

    private lazy var backButton: UIButton = {
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(named: "chevron-left-26")
        configuration.baseForegroundColor = .Signal.label
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.cancel() })
        button.accessibilityLabel = CommonStrings.backButton
        return button
    }()

    private lazy var titleButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .Signal.label
        configuration.image = Theme.iconImage(.chevronDown)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.titleLineBreakMode = .byTruncatingTail
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.albumMenuActions() ?? [])
        }])
        return button
    }()

    private lazy var layout: TellomiPhotoPickerGridLayout = {
        let layout = TellomiPhotoPickerGridLayout()
        layout.spacing = Metrics.gridSpacing
        return layout
    }()

    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .Signal.background
        collectionView.register(TellomiPhotoPickerCell.self, forCellWithReuseIdentifier: TellomiPhotoPickerCell.reuseIdentifier)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        return collectionView
    }()

    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.text = OWSLocalizedString("ATTACHMENT_KEYBOARD_NO_MEDIA_TITLE", comment: "First block of text in chat attachment panel when there's no recent photos to show.")
        label.font = .dynamicTypeBody
        label.textColor = .Signal.secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isHidden = true
        return label
    }()

    private let bottomBar = UIView()

    private lazy var cancelButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.title = CommonStrings.cancelButton
        configuration.baseForegroundColor = .Signal.accent
        return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.cancel() })
    }()

    private lazy var sendButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = .Signal.accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .init(top: 10, leading: 20, bottom: 10, trailing: 20)
        return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.send() })
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background

        for subview in [collectionView, emptyLabel, topBar, bottomBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        topBar.backgroundColor = .Signal.background
        bottomBar.backgroundColor = .Signal.background
        for subview in [backButton, titleButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(subview)
        }
        for subview in [cancelButton, sendButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            bottomBar.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Metrics.topBarHeight),
            backButton.leadingAnchor.constraint(equalTo: topBar.layoutMarginsGuide.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            backButton.heightAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            titleButton.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleButton.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),

            collectionView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Metrics.bottomBarHeight),
            cancelButton.leadingAnchor.constraint(equalTo: bottomBar.layoutMarginsGuide.leadingAnchor),
            cancelButton.centerYAnchor.constraint(equalTo: bottomBar.topAnchor, constant: Metrics.bottomBarHeight / 2),
            sendButton.trailingAnchor.constraint(equalTo: bottomBar.layoutMarginsGuide.trailingAnchor),
            sendButton.centerYAnchor.constraint(equalTo: cancelButton.centerYAnchor),
        ])

        library.onChange = { [weak self] in self?.reloadAlbums() }
        reloadAlbums()
        updateSendButton()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        layout.columns = view.bounds.width > view.bounds.height ? 5 : 3
    }

    // MARK: - Albums

    /// 相册变了（或者刚打开）：重读相册列表；当前相册还在就留在它上面，不在了回「最近」。已选的不动。
    private func reloadAlbums() {
        albums = library.albums()
        let album = albums.first { $0.id == currentAlbum?.id } ?? albums.first
        currentAlbum = album
        titleButton.configuration?.title = album?.title
        collectionView.reloadData()
        updateEmptyState()
    }

    private func switchAlbum(to album: TellomiPhotoPickerAlbum) {
        guard album.id != currentAlbum?.id else { return }
        currentAlbum = album
        titleButton.configuration?.title = album.title
        collectionView.reloadData()
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        updateEmptyState()
    }

    private func albumMenuActions() -> [UIMenuElement] {
        albums.map { album in
            let action = UIAction(title: album.title, state: album.id == currentAlbum?.id ? .on : .off) { [weak self] _ in
                self?.switchAlbum(to: album)
            }
            if #available(iOS 16, *) {
                action.subtitle = OWSFormat.formatInt(album.count)
            }
            return action
        }
    }

    private var itemCount: Int {
        currentAlbum.map { library.itemCount(in: $0) } ?? 0
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = itemCount > 0
    }

    // MARK: - Selection

    private func selectionNumber(for itemId: String) -> Int? {
        selectedIds.firstIndex(of: itemId).map { $0 + 1 }
    }

    /// 再点一次取消；满了提示一句，不再加。
    private func toggle(_ item: TellomiPhotoPickerItem) {
        if let index = selectedIds.firstIndex(of: item.id) {
            selectedIds.remove(at: index)
            selectedItems[item.id] = nil
        } else {
            guard selectedIds.count < Self.maxSelection else {
                showSelectionLimitToast()
                return
            }
            selectedIds.append(item.id)
            selectedItems[item.id] = item
        }
        for case let cell as TellomiPhotoPickerCell in collectionView.visibleCells {
            guard let itemId = cell.itemId else { continue }
            cell.setSelectionNumber(selectionNumber(for: itemId), accentColor: .Signal.accent, animated: itemId == item.id)
        }
        updateSendButton()
    }

    private func showSelectionLimitToast() {
        let text = String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_AT_MOST_FORMAT", comment: "Toast when trying to select more photos than allowed. Embeds {{ the maximum }}."),
            OWSFormat.formatInt(Self.maxSelection),
        )
        ToastController(text: text).presentToastView(from: .bottom, of: view, inset: view.safeAreaInsets.bottom + Metrics.bottomBarHeight + 16)
    }

    private func updateSendButton() {
        let count = selectedIds.count
        sendButton.isEnabled = count > 0
        sendButton.configuration?.title = count > 0
            ? String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_GALLERY_SEND_FORMAT", comment: "Send button of the gallery opened from the files page, which sends the ticked photos and videos as files. Embeds {{number of ticked items}}."),
                OWSFormat.formatInt(count),
            )
            : MessageStrings.sendButton
    }

    // MARK: - Actions

    private func cancel() {
        delegate?.filesGalleryDidCancel(self)
    }

    /// 「是否把照片转成 JPEG？」等着用户选（测试里直接选）。
    private var heicChoice: ((Bool) -> Void)?

    private func send() {
        let items = selectedIds.compactMap { selectedItems[$0] }
        guard !items.isEmpty else { return }
        let caption = caption.strippedOrNil
        guard items.contains(where: library.isHeic) else {
            delegate?.filesGallery(self, send: items, convertHeicToJpeg: false, caption: caption)
            return
        }
        let choose: (Bool) -> Void = { [weak self] convert in
            guard let self else { return }
            self.heicChoice = nil
            self.delegate?.filesGallery(self, send: items, convertHeicToJpeg: convert, caption: caption)
        }
        heicChoice = choose
        let actionSheet = ActionSheetController(message: OWSLocalizedString(
            "IMAGE_PICKER_TELLOMI_CONVERT_TO_JPEG_QUESTION",
            comment: "Asked before sending photos as files when some of them are HEIC: whether to convert them to JPEG first.",
        ))
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("IMAGE_PICKER_TELLOMI_KEEP_HEIC", comment: "Option when sending photos as files: send the HEIC photos as they are."),
            handler: { _ in choose(false) },
        ))
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("IMAGE_PICKER_TELLOMI_CONVERT_TO_JPEG", comment: "Option when sending photos as files: convert the HEIC photos to JPEG first."),
            handler: { _ in choose(true) },
        ))
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.cancelButton, style: .cancel, handler: { [weak self] _ in
            self?.heicChoice = nil
        }))
        presentActionSheet(actionSheet)
    }

    // MARK: - Preview

    /// 点格子：从这一张开始的预览（整本相册左右滑），盖在网格上。
    private func openPreview(at index: Int) {
        guard let album = currentAlbum else { return }
        let library = self.library
        let viewer = TellomiPhotoPickerAlbumViewer(library: library, album: album, initialIndex: index, fileMode: .init(
            fileName: { item in library.originalFileName(for: item) },
            fileDetails: { item in Self.fileDetails(for: item, byteCount: library.fileSize(for: item)) },
            initialCaption: caption,
            onCaptionChanged: { [weak self] text in self?.caption = text },
            onSend: { [weak self] item in
                // 同 Telegram：预览先收起，再发（HEIC 提问从网格上弹）。
                self?.dismiss(animated: true) { self?.sendFromPreview(item) }
            },
        ))
        viewer.selectionNumber = { [weak self] itemId in self?.selectionNumber(for: itemId) }
        viewer.selectedCount = { [weak self] in self?.selectedIds.count ?? 0 }
        viewer.onToggle = { [weak self] item in self?.toggle(item) }
        viewer.onClose = { [weak viewer] in viewer?.dismiss(animated: true) }
        viewer.modalPresentationStyle = .overFullScreen
        present(viewer, animated: true)
    }

    /// 预览里的发送：一个都没勾时发正在看的这一张（照 Telegram `completeWithCurrentItem`）。
    private func sendFromPreview(_ item: TellomiPhotoPickerItem) {
        if selectedIds.isEmpty {
            toggle(item)
        }
        send()
    }

    /// 「4032×3024 · 0:42 · 2.4 MB」：知道的才写。
    static func fileDetails(for item: TellomiPhotoPickerItem, byteCount: Int64?) -> String {
        var parts = [String]()
        if item.pixelSize.width > 0, item.pixelSize.height > 0 {
            parts.append("\(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))")
        }
        if item.isVideo, item.duration > 0 {
            parts.append(TellomiPhotoPickerCell.formatDuration(item.duration))
        }
        if let byteCount, byteCount > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        itemCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TellomiPhotoPickerCell.reuseIdentifier, for: indexPath) as! TellomiPhotoPickerCell
        guard let album = currentAlbum else { return cell }
        let item = library.item(at: indexPath.item, in: album)
        let scale = view.window?.windowScene?.screen.scale ?? UIScreen.main.scale
        cell.configure(
            item: item,
            selectionNumber: selectionNumber(for: item.id),
            accentColor: .Signal.accent,
            library: library,
            thumbnailSize: CGSize(square: layout.itemSide * scale),
        )
        cell.onCheckTapped = { [weak self] in self?.toggle(item) }
        return cell
    }

    // MARK: - UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        openPreview(at: indexPath.item)
    }

    // MARK: - Testing

    var titleForTesting: String? { titleButton.configuration?.title }
    var sendTitleForTesting: String? { sendButton.configuration?.title }
    var isSendEnabledForTesting: Bool { sendButton.isEnabled }
    var isEmptyStateShownForTesting: Bool { !emptyLabel.isHidden }
    var collectionViewForTesting: UICollectionView { collectionView }

    var presentedPreviewForTesting: TellomiPhotoPickerAlbumViewer? { presentedViewController as? TellomiPhotoPickerAlbumViewer }

    /// 点照片本身：打开预览。
    func tapItemForTesting(_ index: Int) {
        collectionView(collectionView, didSelectItemAt: IndexPath(item: index, section: 0))
    }

    /// 点格子右上的勾。
    func tapCheckForTesting(_ index: Int) {
        guard let album = currentAlbum else { return }
        toggle(library.item(at: index, in: album))
    }

    func sendFromPreviewForTesting(_ index: Int, caption: String) {
        guard let album = currentAlbum else { return }
        self.caption = caption
        sendFromPreview(library.item(at: index, in: album))
    }

    func switchAlbumForTesting(_ album: TellomiPhotoPickerAlbum) {
        switchAlbum(to: album)
    }

    func tapSendForTesting() {
        send()
    }

    func tapCancelForTesting() {
        cancel()
    }

    var isAskingAboutHeicForTesting: Bool { heicChoice != nil }

    func chooseHeicForTesting(convert: Bool) {
        heicChoice?(convert)
    }
}
