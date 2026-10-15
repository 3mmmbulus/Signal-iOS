//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1518，V-1；照 Telegram `TGMediaPickerModernGalleryMixin` 的网格点开）：
/// 网格点照片打开整本相册的查看器，左右滑看整本相册，点开不自动选中；单击照片或右上角勾选即时增减（照 Telegram
/// `TGMediaPickerGalleryPhotoItemView` 单击切换）；选中计数点开切出已选；底部「裁剪」「绘制」「调色」就地打开上游对应的工具
/// （照 Telegram `TGPhotoToolbarView`：查看器底部只有一条工具栏，没有单独的「编辑」键，点工具就地进编辑器）。
/// 2026-10-16（owner 发来的方案第 6 节「方案 A」）：去掉「编辑」键——它进的上游预览 / 编辑页底栏也是这三个工具，功能完全重叠；
/// 工具不再先关查看器、整屏弹预览页、再盖工具页（三层转场），而是直接盖在查看器上（[onEdit] → 选图页就地打开）。
///
/// 给了 [FileMode] 时是「文件」页相册网格的预览（tellomi/tellomi#1263 F-3，owner 2026-10-13 照 Telegram）：不能编辑（Telegram iOS
/// 文件模式用 `TGMediaEditingContext contextForCaptionsOnly`，安卓 `PhotoViewer` 的 `isDocumentsPicker` 把编辑都藏起来），没有已选计数；
/// 底部换成文件名 +「尺寸 · 时长 · 大小」（同 Telegram 安卓 `docNameTextView` / `docInfoTextView`）、说明输入框和发送。
final class TellomiPhotoPickerAlbumViewer: UIViewController {

    struct FileMode {
        let fileName: (TellomiPhotoPickerItem) -> String?
        let fileDetails: (TellomiPhotoPickerItem) -> String
        let initialCaption: String
        let onCaptionChanged: (String) -> Void
        /// 发送：参数是正在看的这一张（一个都没勾时调用方发它）。
        let onSend: (TellomiPhotoPickerItem) -> Void
    }

    var selectionNumber: (String) -> Int? = { _ in nil }
    var selectedCount: () -> Int = { 0 }
    var onToggle: ((TellomiPhotoPickerItem) -> Void)?
    var onShowSelected: (() -> Void)?
    var onEdit: ((TellomiPhotoPickerItem, TellomiApprovalEditTool) -> Void)?
    /// 这张改过之后的样子（选图页给，没改过是 nil）：查看器里显示它，不显示原图。
    var editedImage: (String) -> UIImage? = { _ in nil }
    /// 选图页用：工具页还盖着时，改完的重画等它收起再做。
    var isWaitingForToolToClose = false
    var onClose: (() -> Void)?

    private let library: TellomiPhotoPickerLibrary
    private let items: [TellomiPhotoPickerItem]
    private var currentIndex: Int
    private var laidOutSize = CGSize.zero
    private let fileMode: FileMode?

    private enum DismissMetrics {
        static let velocityThreshold: CGFloat = 700
        static let distanceThreshold: CGFloat = 128
        static let progressDistance: CGFloat = 150
    }

    private lazy var dismissPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        pan.delegate = self
        return pan
    }()

    private lazy var layout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        return layout
    }()

    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TellomiAlbumViewerPageCell.self, forCellWithReuseIdentifier: TellomiAlbumViewerPageCell.reuseIdentifier)
        return collectionView
    }()

    private lazy var closeButton: UIButton = {
        var configuration = UIButton.Configuration.gray()
        configuration.image = Theme.iconImage(.buttonX)
        configuration.baseForegroundColor = .Signal.label
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onClose?() })
        button.accessibilityLabel = CommonStrings.dismissButton
        return button
    }()

    private let positionPill = UIView()
    private let positionLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        return label
    }()

    private lazy var checkButton: TellomiNumberedCheck = {
        let check = TellomiNumberedCheck()
        check.addAction(UIAction { [weak self] _ in self?.didTapCheck() }, for: .touchUpInside)
        return check
    }()

    private lazy var countButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = .Signal.accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.image = Theme.iconImage(.checkmark).withRenderingMode(.alwaysTemplate)
        configuration.imagePadding = 2
        configuration.contentInsets = .init(top: 0, leading: 10, bottom: 0, trailing: 16)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onShowSelected?() })
        button.isHidden = true
        return button
    }()

    private lazy var cropButton = makeToolButton(
        image: UIImage(imageLiteralResourceName: "crop-rotate"),
        accessibilityLabel: OWSLocalizedString(
            "ATTACHMENT_TOOL_BUTTON_CROP_SCALE_ACCESSIBILITY_LABEL",
            comment: "Accessibility label for the 'crop/scale image' dialog.",
        ),
        tool: .crop,
    )

    /// tellomi/tellomi#1593 E5-3：调色（照 Telegram iOS 编辑底栏 `TGPhotoToolbarView` 的次序：裁剪、画笔、调整）。
    private lazy var adjustButton = makeToolButton(
        image: TellomiImageAdjustViewController.toolIcon,
        accessibilityLabel: OWSLocalizedString(
            "IMAGE_EDITOR_TELLOMI_ADJUST",
            comment: "Image editor: name of the tool that adjusts exposure, contrast, colour and so on. Also its button's accessibility label.",
        ),
        tool: .adjust,
    )

    private lazy var penButton = makeToolButton(
        image: UIImage(imageLiteralResourceName: "brush-pen"),
        accessibilityLabel: OWSLocalizedString(
            "ATTACHMENT_TOOL_BUTTON_PEN_ACCESSIBILITY_LABEL",
            comment: "Accessibility label for the 'pen' dialog.",
        ),
        tool: .pen,
    )

    private lazy var toolsStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [cropButton, penButton, adjustButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        return stack
    }()

    // MARK: 文件模式（F-3）

    private let fileBar: UIView = {
        let bar = UIView()
        bar.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        return bar
    }()

    private let fileNameLabel: UILabel = {
        let label = UILabel()
        label.font = .dynamicTypeBodyClamped
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }()

    private let fileDetailsLabel: UILabel = {
        let label = UILabel()
        label.font = .dynamicTypeSubheadlineClamped
        label.textColor = UIColor.white.withAlphaComponent(0.7)
        return label
    }()

    private lazy var captionField: UITextField = {
        let field = UITextField()
        field.font = .dynamicTypeBodyClamped
        field.textColor = .white
        field.tintColor = .Signal.accent
        field.attributedPlaceholder = NSAttributedString(
            string: OWSLocalizedString("IMAGE_PICKER_TELLOMI_CAPTION_PLACEHOLDER", comment: "Placeholder of the caption field in the photo picker's send bar."),
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.5)],
        )
        field.returnKeyType = .default
        field.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.fileMode?.onCaptionChanged(self.captionField.text ?? "")
        }, for: .editingChanged)
        return field
    }()

    private lazy var fileSendButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.image = Theme.iconImage(.arrowUp)
        configuration.baseBackgroundColor = .Signal.accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.didTapFileSend() })
        button.accessibilityLabel = MessageStrings.sendButton
        return button
    }()

    /// 发送键右上角：勾了几个（照 Telegram 预览发送键上的计数）。
    private let sendBadge: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .black
        label.backgroundColor = .white
        label.textAlignment = .center
        label.layer.cornerRadius = 9
        label.layer.masksToBounds = true
        label.isHidden = true
        return label
    }()

    init(library: TellomiPhotoPickerLibrary, album: TellomiPhotoPickerAlbum, initialIndex: Int, fileMode: FileMode? = nil) {
        self.library = library
        self.items = (0..<library.itemCount(in: album)).map { library.item(at: $0, in: album) }
        self.currentIndex = min(max(initialIndex, 0), max(library.itemCount(in: album) - 1, 0))
        self.fileMode = fileMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .black
        view.addSubview(collectionView)

        positionPill.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        positionPill.layer.cornerRadius = 14
        positionPill.addSubview(positionLabel)
        positionLabel.translatesAutoresizingMaskIntoConstraints = false

        for subview in chromeViews {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        view.addGestureRecognizer(dismissPan)
        collectionView.panGestureRecognizer.require(toFail: dismissPan)

        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            positionPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            positionPill.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            positionPill.heightAnchor.constraint(equalToConstant: 28),

            positionLabel.leadingAnchor.constraint(equalTo: positionPill.leadingAnchor, constant: 12),
            positionLabel.trailingAnchor.constraint(equalTo: positionPill.trailingAnchor, constant: -12),
            positionLabel.topAnchor.constraint(equalTo: positionPill.topAnchor),
            positionLabel.bottomAnchor.constraint(equalTo: positionPill.bottomAnchor),

            checkButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -4),
            checkButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            checkButton.widthAnchor.constraint(equalToConstant: 44),
            checkButton.heightAnchor.constraint(equalToConstant: 44),

            countButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            countButton.topAnchor.constraint(equalTo: checkButton.bottomAnchor, constant: 4),
            countButton.heightAnchor.constraint(equalToConstant: 28),

            cropButton.widthAnchor.constraint(equalToConstant: 44),
            cropButton.heightAnchor.constraint(equalToConstant: 44),
            penButton.widthAnchor.constraint(equalToConstant: 44),
            penButton.heightAnchor.constraint(equalToConstant: 44),
            adjustButton.widthAnchor.constraint(equalToConstant: 44),
            adjustButton.heightAnchor.constraint(equalToConstant: 44),

            toolsStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toolsStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
        if let fileMode {
            setUpFileBar(initialCaption: fileMode.initialCaption)
        }
        refreshChrome(animatedCheck: false)
    }

    /// 文件模式的底栏：文件名、「尺寸 · 时长 · 大小」，再下面说明 + 发送；键盘弹起时整条跟着上来。
    private func setUpFileBar(initialCaption: String) {
        toolsStack.isHidden = true
        captionField.text = initialCaption

        let capsule = UIView()
        capsule.backgroundColor = UIColor.white.withAlphaComponent(0.15)
        capsule.layer.cornerRadius = 20
        capsule.addSubview(captionField)
        captionField.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(hMargin: 14, vMargin: 0))

        let sendContainer = UIView()
        sendContainer.addSubview(fileSendButton)
        sendContainer.addSubview(sendBadge)
        fileSendButton.autoPinEdgesToSuperviewEdges()

        let row = UIStackView(arrangedSubviews: [capsule, sendContainer])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8

        let stack = UIStackView(arrangedSubviews: [fileNameLabel, fileDetailsLabel, row])
        stack.axis = .vertical
        stack.spacing = 2
        stack.setCustomSpacing(10, after: fileDetailsLabel)

        fileBar.addSubview(stack)
        for subview in [stack, capsule, sendContainer, sendBadge] {
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            fileBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            fileBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            fileBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: fileBar.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            capsule.heightAnchor.constraint(equalToConstant: 40),
            sendContainer.widthAnchor.constraint(equalToConstant: 40),
            sendContainer.heightAnchor.constraint(equalToConstant: 40),
            sendBadge.heightAnchor.constraint(equalToConstant: 18),
            sendBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            sendBadge.centerXAnchor.constraint(equalTo: sendContainer.trailingAnchor, constant: -4),
            sendBadge.centerYAnchor.constraint(equalTo: sendContainer.topAnchor, constant: 4),
        ])
    }

    private func didTapFileSend() {
        guard items.indices.contains(currentIndex) else { return }
        fileMode?.onSend(items[currentIndex])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        collectionView.frame = view.bounds

        let size = view.bounds.size
        guard size != laidOutSize, size.width > 0 else { return }
        laidOutSize = size
        layout.itemSize = size
        layout.invalidateLayout()
        collectionView.scrollToItem(at: IndexPath(item: currentIndex, section: 0), at: .centeredHorizontally, animated: false)
    }

    private func didTapCheck() {
        guard items.indices.contains(currentIndex) else { return }
        toggleSelection(of: items[currentIndex])
    }

    private func toggleSelection(of item: TellomiPhotoPickerItem) {
        onToggle?(item)
        refreshChrome(animatedCheck: true)
    }

    private func didTapEdit(tool: TellomiApprovalEditTool) {
        guard items.indices.contains(currentIndex) else { return }
        onEdit?(items[currentIndex], tool)
    }

    private func makeToolButton(image: UIImage, accessibilityLabel: String, tool: TellomiApprovalEditTool) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.image = image.withRenderingMode(.alwaysTemplate)
        configuration.baseForegroundColor = .Signal.label
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.didTapEdit(tool: tool) })
        button.accessibilityLabel = accessibilityLabel
        return button
    }

    @objc private func handleDismissPan(_ gesture: UIPanGestureRecognizer) {
        let distance = gesture.translation(in: view).y
        switch gesture.state {
        case .changed:
            setDismissDrag(distance)
        case .ended:
            let velocity = gesture.velocity(in: view).y
            if Self.shouldDismiss(distance: distance, velocity: velocity) {
                animateDismiss(distance: distance, velocity: velocity)
            } else {
                animateSnapBack()
            }
        case .cancelled, .failed:
            animateSnapBack()
        default:
            break
        }
    }

    private func setDismissDrag(_ distance: CGFloat) {
        let progress = Self.dismissProgress(distance: distance)
        collectionView.transform = CGAffineTransform(translationX: 0, y: distance)
        view.backgroundColor = UIColor.black.withAlphaComponent(1 - progress)
        setChromeAlpha(1 - progress)
    }

    private func animateSnapBack() {
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.collectionView.transform = .identity
            self.view.backgroundColor = .black
            self.setChromeAlpha(1)
        }
    }

    private func animateDismiss(distance: CGFloat, velocity: CGFloat) {
        let driving = abs(velocity) >= DismissMetrics.velocityThreshold ? velocity : distance
        let direction: CGFloat = driving < 0 ? -1 : 1
        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
            self.collectionView.transform = CGAffineTransform(translationX: 0, y: direction * self.view.bounds.height)
            self.view.backgroundColor = .clear
            self.setChromeAlpha(0)
        } completion: { _ in
            self.onClose?()
        }
    }

    private func setChromeAlpha(_ alpha: CGFloat) {
        chromeViews.forEach { $0.alpha = alpha }
    }

    private var chromeViews: [UIView] {
        [closeButton, positionPill, checkButton, countButton, toolsStack] + (fileMode != nil ? [fileBar] : [])
    }

    private var currentPageIsZoomed: Bool {
        (collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? TellomiAlbumViewerPageCell)?.isZoomed ?? false
    }

    static func shouldDismiss(distance: CGFloat, velocity: CGFloat) -> Bool {
        abs(velocity) >= DismissMetrics.velocityThreshold || abs(distance) >= DismissMetrics.distanceThreshold
    }

    static func dismissProgress(distance: CGFloat) -> CGFloat {
        min(abs(distance) / DismissMetrics.progressDistance, 1)
    }

    /// 照 Telegram `TGModernGalleryZoomableItemView`：正常 = 放进屏幕；最大取宽高两个比例与正常的 3 倍里的大者。
    static func zoomLimits(bounds: CGSize, content: CGSize) -> (minimum: CGFloat, normal: CGFloat, maximum: CGFloat) {
        let scaleWidth = bounds.width / content.width
        let scaleHeight = bounds.height / content.height
        let normal = min(scaleWidth, scaleHeight)
        // 图比屏幕大得多时普通比例本身低于 0.05，下限取较小者，免得下限高于普通比例（Telegram 固定 0.05）。
        return (min(0.05, normal), normal, max(scaleWidth, scaleHeight, normal * 3))
    }

    private func refreshChrome(animatedCheck: Bool) {
        guard isViewLoaded else { return }
        positionLabel.text = "\(currentIndex + 1) / \(items.count)"
        if items.indices.contains(currentIndex) {
            let itemId = items[currentIndex].id
            checkButton.setNumber(selectionNumber(itemId), accentColor: .Signal.accent, animated: animatedCheck)
            let item = items[currentIndex]
            toolsStack.isHidden = fileMode != nil || item.isVideo || item.isAnimatedImage
            if let fileMode {
                let name = fileMode.fileName(item)
                fileNameLabel.text = name
                fileNameLabel.isHidden = name?.isEmpty ?? true
                fileDetailsLabel.text = fileMode.fileDetails(item)
            }
        }

        let count = selectedCount()
        sendBadge.text = " \(OWSFormat.formatInt(count)) "
        sendBadge.isHidden = fileMode == nil || count == 0
        countButton.isHidden = fileMode != nil || count == 0
        countButton.configuration?.attributedTitle = AttributedString(
            OWSFormat.formatInt(count),
            attributes: AttributeContainer([.font: UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium)]),
        )
        countButton.accessibilityLabel = String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_SELECTED_FORMAT", comment: "Accessibility label of the selected-count pill in the photo picker. Embeds {{ number selected }}."),
            OWSFormat.formatInt(count),
        )
    }

    /// 选图页在别处改了勾选（例如就地编辑时自动勾上）：勾选标和计数跟着变。
    func refreshSelection() {
        refreshChrome(animatedCheck: true)
    }

    /// 当前这张改过了：换成改过的样子。
    func reloadCurrentPage() {
        guard isViewLoaded, items.indices.contains(currentIndex) else { return }
        collectionView.reloadItems(at: [IndexPath(item: currentIndex, section: 0)])
    }

    private func pixelTargetSize(for item: TellomiPhotoPickerItem) -> CGSize {
        let scale = traitCollection.displayScale
        let box = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard item.pixelSize.width > 0, item.pixelSize.height > 0 else { return box }
        let fit = min(1, min(box.width / item.pixelSize.width, box.height / item.pixelSize.height))
        return CGSize(width: item.pixelSize.width * fit, height: item.pixelSize.height * fit)
    }
}

extension TellomiPhotoPickerAlbumViewer: UICollectionViewDataSource, UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TellomiAlbumViewerPageCell.reuseIdentifier, for: indexPath)
        if let page = cell as? TellomiAlbumViewerPageCell {
            let item = items[indexPath.item]
            page.onZoomChanged = { [weak self] zoomed in self?.collectionView.isScrollEnabled = !zoomed }
            page.onSingleTap = { [weak self] in self?.toggleSelection(of: item) }
            page.configure(item: item, library: library, targetSize: pixelTargetSize(for: item), editedImage: editedImage(item.id))
        }
        return cell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDecelerating else { return }
        updateCurrentIndex(from: scrollView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateCurrentIndex(from: scrollView)
    }

    private func updateCurrentIndex(from scrollView: UIScrollView) {
        guard scrollView.bounds.width > 0, !items.isEmpty else { return }
        let page = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        let clamped = min(max(page, 0), items.count - 1)
        guard clamped != currentIndex else { return }
        currentIndex = clamped
        refreshChrome(animatedCheck: false)
    }
}

extension TellomiPhotoPickerAlbumViewer: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === dismissPan else { return true }
        guard !currentPageIsZoomed else { return false }
        let velocity = dismissPan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }
}

/// 查看器里的一页（照 Telegram `TGModernGalleryZoomableItemView`）：照片按像素尺寸放进滚动视图，正常比例 = 放进屏幕；
/// 可捏合、双击放大 / 还原；缩到正常以下松手回弹；放大后换成全分辨率图。
/// 照片在 iCloud、要下载时中间一个圆形进度，下完淡出（tellomi/tellomi#1521 G-3，照 Telegram 聊天选图查看器
/// `TGMediaPickerGalleryPhotoItemView` 的 `setProgressVisible`：50 pt、不能点取消）。
private final class TellomiAlbumViewerPageCell: UICollectionViewCell, UIScrollViewDelegate {

    static let reuseIdentifier = "TellomiAlbumViewerPageCell"

    var onZoomChanged: ((Bool) -> Void)?
    var onSingleTap: (() -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var item: TellomiPhotoPickerItem?
    private var library: TellomiPhotoPickerLibrary?
    private var thumbnailRequest: TellomiPhotoPickerRequest?
    private var needsFit = true
    private var fittedBoundsSize = CGSize.zero
    private var normalZoomScale: CGFloat = 1
    private var isFullResolution = false
    private let downloadProgress = TellomiAlbumViewerDownloadProgress()

    var isZoomed: Bool { scrollView.zoomScale > normalZoomScale + 0.0001 }

    override init(frame: CGRect) {
        super.init(frame: frame)

        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.bouncesZoom = true
        contentView.addSubview(scrollView)

        imageView.contentMode = .scaleToFill
        scrollView.addSubview(imageView)

        downloadProgress.isHidden = true
        contentView.addSubview(downloadProgress)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = contentView.bounds
        downloadProgress.frame = CGRect(
            x: (contentView.bounds.width - TellomiAlbumViewerDownloadProgress.size) / 2,
            y: (contentView.bounds.height - TellomiAlbumViewerDownloadProgress.size) / 2,
            width: TellomiAlbumViewerDownloadProgress.size,
            height: TellomiAlbumViewerDownloadProgress.size,
        )
        if needsFit || scrollView.bounds.size != fittedBoundsSize {
            applyFit()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailRequest?.cancel()
        thumbnailRequest = nil
        imageView.image = nil
        item = nil
        library = nil
        editedImage = nil
        isFullResolution = false
        needsFit = true
        downloadProgress.hide(animated: false)
    }

    func configure(item: TellomiPhotoPickerItem, library: TellomiPhotoPickerLibrary, targetSize: CGSize, editedImage: UIImage? = nil) {
        self.item = item
        self.library = library
        self.editedImage = editedImage
        isFullResolution = editedImage != nil
        needsFit = true
        downloadProgress.hide(animated: false)
        if let editedImage {
            thumbnailRequest?.cancel()
            thumbnailRequest = nil
            imageView.image = editedImage
        } else {
            request(item, from: library, targetSize: targetSize)
        }
        setNeedsLayout()
    }

    /// 改过之后的样子（裁剪过尺寸就不同了）：有它就不再向相册要图。
    private var editedImage: UIImage?

    private func request(_ item: TellomiPhotoPickerItem, from library: TellomiPhotoPickerLibrary, targetSize: CGSize) {
        thumbnailRequest?.cancel()
        thumbnailRequest = library.requestViewerImage(
            for: item,
            targetSize: targetSize,
            progress: { [weak self] value in
                self?.showDownloadProgress(value, for: item.id)
            },
            completion: { [weak self] image in
                self?.show(image, for: item.id)
            },
        )
    }

    private func showDownloadProgress(_ value: Double, for itemId: String) {
        guard self.item?.id == itemId else { return }
        if value < 1 {
            downloadProgress.show(progress: value)
        } else {
            downloadProgress.hide(animated: true)
        }
    }

    var isShowingDownloadProgress: Bool { downloadProgress.isShowing }

    private var contentSize: CGSize {
        if let editedImage, editedImage.size.width > 0, editedImage.size.height > 0 {
            return CGSize(width: editedImage.size.width * editedImage.scale, height: editedImage.size.height * editedImage.scale)
        }
        guard let item, item.pixelSize.width > 0, item.pixelSize.height > 0 else { return scrollView.bounds.size }
        return item.pixelSize
    }

    private func applyFit() {
        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }
        let content = contentSize
        let limits = TellomiPhotoPickerAlbumViewer.zoomLimits(bounds: boundsSize, content: content)
        needsFit = false
        fittedBoundsSize = boundsSize
        normalZoomScale = limits.normal
        imageView.frame = CGRect(origin: .zero, size: content)
        scrollView.contentSize = content
        scrollView.minimumZoomScale = limits.minimum
        scrollView.maximumZoomScale = limits.maximum
        scrollView.zoomScale = limits.normal
        scrollView.isScrollEnabled = false
        centerImage()
    }

    private func centerImage() {
        let boundsSize = scrollView.bounds.size
        var frame = imageView.frame
        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
        imageView.frame = frame
    }

    private func show(_ image: UIImage?, for itemId: String) {
        guard self.item?.id == itemId, let image else { return }
        imageView.image = image
    }

    private func upgradeToFullResolution() {
        guard !isFullResolution, let item, let library else { return }
        isFullResolution = true
        request(item, from: library, targetSize: item.pixelSize)
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if isZoomed {
            scrollView.setZoomScale(normalZoomScale, animated: true)
            return
        }
        let target = scrollView.maximumZoomScale
        let center = gesture.location(in: imageView)
        let size = CGSize(width: scrollView.bounds.width / target, height: scrollView.bounds.height / target)
        scrollView.zoom(
            to: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height),
            animated: true,
        )
        upgradeToFullResolution()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        scrollView.isScrollEnabled = isZoomed
        onZoomChanged?(isZoomed)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale < normalZoomScale - 0.0001 {
            scrollView.setZoomScale(normalZoomScale, animated: true)
        }
        if isZoomed {
            upgradeToFullResolution()
        }
    }
}

/// iCloud 下载进度：半透明黑底圆、白色进度弧（照 Telegram `TGMessageImageViewOverlayView` 的大小与配色；画法是 Signal 的 `CircularProgressView`）。
private final class TellomiAlbumViewerDownloadProgress: UIView {

    static let size: CGFloat = 50

    private let ring = CircularProgressView(frame: .zero)
    private(set) var isShowing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = UIColor.black.withAlphaComponent(0.5)
        layer.cornerRadius = Self.size / 2
        ring.lineWidth = 2.5
        ring.progressTintColor = .white
        ring.trackTintColor = UIColor.white.withAlphaComponent(0.25)
        addSubview(ring)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds.insetBy(dx: 8, dy: 8)
    }

    /// 刚开始下时进度是 0，留一点弧，看得出是进度圈（同 Telegram 网格的 0.027 下限）。
    func show(progress: Double) {
        let wasShowing = isShowing
        isShowing = true
        layer.removeAllAnimations()
        isHidden = false
        alpha = 1
        ring.setProgress(Float(max(progress, 0.03)), animated: wasShowing)
    }

    func hide(animated: Bool) {
        guard isShowing || !isHidden else { return }
        isShowing = false
        guard animated else {
            layer.removeAllAnimations()
            isHidden = true
            ring.progress = 0
            return
        }
        UIView.animate(withDuration: 0.3, delay: 0, options: .beginFromCurrentState) {
            self.alpha = 0
        } completion: { _ in
            guard !self.isShowing else { return }
            self.isHidden = true
            self.ring.progress = 0
        }
    }
}

#if TESTABLE_BUILD

extension TellomiPhotoPickerAlbumViewer {
    var pageIndexForTesting: Int { currentIndex }
    var positionTextForTesting: String? { positionLabel.text }
    var checkNumberTextForTesting: String? { checkButton.numberTextForTesting }
    var isCountShownForTesting: Bool { !countButton.isHidden }

    func tapCheckForTesting() {
        didTapCheck()
    }

    func tapPhotoForTesting() {
        view.layoutIfNeeded()
        (collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? TellomiAlbumViewerPageCell)?.onSingleTap?()
    }

    func tapCountForTesting() {
        countButton.sendActions(for: .primaryActionTriggered)
    }

    func tapToolForTesting(_ tool: TellomiApprovalEditTool) {
        didTapEdit(tool: tool)
    }

    /// 正在看的这一页有没有 iCloud 下载进度圈。
    var isDownloadProgressShownForTesting: Bool {
        view.layoutIfNeeded()
        return (collectionView.cellForItem(at: IndexPath(item: currentIndex, section: 0)) as? TellomiAlbumViewerPageCell)?.isShowingDownloadProgress ?? false
    }

    var isCropShownForTesting: Bool { !toolsStack.isHidden && !cropButton.isHidden }
    var isPenShownForTesting: Bool { !toolsStack.isHidden && !penButton.isHidden }
    var isAdjustShownForTesting: Bool { !toolsStack.isHidden && !adjustButton.isHidden }
    /// 2026-10-16 起没有「编辑」键（工具就地打开）。
    var isEditShownForTesting: Bool { false }
    var isFileBarShownForTesting: Bool { fileBar.superview != nil }
    var fileNameTextForTesting: String? { fileNameLabel.isHidden ? nil : fileNameLabel.text }
    var fileDetailsTextForTesting: String? { fileDetailsLabel.text }
    var captionTextForTesting: String? { captionField.text }
    var sendBadgeTextForTesting: String? { sendBadge.isHidden ? nil : sendBadge.text?.trimmingCharacters(in: .whitespaces) }

    func typeCaptionForTesting(_ text: String) {
        captionField.text = text
        captionField.sendActions(for: .editingChanged)
    }

    func tapFileSendForTesting() {
        didTapFileSend()
    }
}

#endif
