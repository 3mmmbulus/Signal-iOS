//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1518，V-1；照 Telegram `TGMediaPickerModernGalleryMixin` 的网格点开）：
/// 网格点照片打开整本相册的查看器，左右滑看整本相册，点开不自动选中；单击照片或右上角勾选即时增减（照 Telegram
/// `TGMediaPickerGalleryPhotoItemView` 单击切换）；选中计数点开切出已选；底部「裁剪」「绘制」直接打开上游对应的工具，
/// 「编辑」进上游的预览 / 编辑页，都先看到当前这张（照 Telegram `TGMediaPickerGalleryPhotoItem` 底部工具栏的 Crop / Paint）。
final class TellomiPhotoPickerAlbumViewer: UIViewController {

    var selectionNumber: (String) -> Int? = { _ in nil }
    var selectedCount: () -> Int = { 0 }
    var onToggle: ((TellomiPhotoPickerItem) -> Void)?
    var onShowSelected: (() -> Void)?
    var onEdit: ((TellomiPhotoPickerItem, TellomiApprovalEditTool?) -> Void)?
    var onClose: (() -> Void)?

    private let library: TellomiPhotoPickerLibrary
    private let items: [TellomiPhotoPickerItem]
    private var currentIndex: Int
    private var laidOutSize = CGSize.zero

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

    private lazy var penButton = makeToolButton(
        image: UIImage(imageLiteralResourceName: "brush-pen"),
        accessibilityLabel: OWSLocalizedString(
            "ATTACHMENT_TOOL_BUTTON_PEN_ACCESSIBILITY_LABEL",
            comment: "Accessibility label for the 'pen' dialog.",
        ),
        tool: .pen,
    )

    private lazy var editButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = .Signal.accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.title = OWSLocalizedString("IMAGE_PICKER_TELLOMI_EDIT", comment: "Button in the album viewer of the photo picker that opens the preview and editing screen for the photo being viewed.")
        configuration.contentInsets = .init(top: 10, leading: 24, bottom: 10, trailing: 24)
        return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.didTapEdit() })
    }()

    private lazy var toolsStack: UIStackView = {
        let stack = UIStackView(arrangedSubviews: [cropButton, penButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        return stack
    }()

    init(library: TellomiPhotoPickerLibrary, album: TellomiPhotoPickerAlbum, initialIndex: Int) {
        self.library = library
        self.items = (0..<library.itemCount(in: album)).map { library.item(at: $0, in: album) }
        self.currentIndex = min(max(initialIndex, 0), max(library.itemCount(in: album) - 1, 0))
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

            editButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            editButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            toolsStack.trailingAnchor.constraint(equalTo: editButton.leadingAnchor, constant: -12),
            toolsStack.centerYAnchor.constraint(equalTo: editButton.centerYAnchor),
        ])
        refreshChrome(animatedCheck: false)
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

    private func didTapEdit() {
        didTapEdit(tool: nil)
    }

    private func didTapEdit(tool: TellomiApprovalEditTool?) {
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
        [closeButton, positionPill, checkButton, countButton, toolsStack, editButton]
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
            toolsStack.isHidden = item.isVideo || item.isAnimatedImage
        }

        let count = selectedCount()
        countButton.isHidden = count == 0
        countButton.configuration?.attributedTitle = AttributedString(
            OWSFormat.formatInt(count),
            attributes: AttributeContainer([.font: UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium)]),
        )
        countButton.accessibilityLabel = String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_SELECTED_FORMAT", comment: "Accessibility label of the selected-count pill in the photo picker. Embeds {{ number selected }}."),
            OWSFormat.formatInt(count),
        )
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
            page.configure(item: item, library: library, targetSize: pixelTargetSize(for: item))
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
        isFullResolution = false
        needsFit = true
    }

    func configure(item: TellomiPhotoPickerItem, library: TellomiPhotoPickerLibrary, targetSize: CGSize) {
        self.item = item
        self.library = library
        isFullResolution = false
        needsFit = true
        thumbnailRequest?.cancel()
        thumbnailRequest = library.requestThumbnail(for: item, targetSize: targetSize) { [weak self] image in
            self?.show(image, for: item.id)
        }
        setNeedsLayout()
    }

    private var contentSize: CGSize {
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
        thumbnailRequest?.cancel()
        thumbnailRequest = library.requestThumbnail(for: item, targetSize: item.pixelSize) { [weak self] image in
            self?.show(image, for: item.id)
        }
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

    func tapEditForTesting() {
        didTapEdit()
    }

    func tapToolForTesting(_ tool: TellomiApprovalEditTool) {
        didTapEdit(tool: tool)
    }

    var isCropShownForTesting: Bool { !toolsStack.isHidden && !cropButton.isHidden }
    var isPenShownForTesting: Bool { !toolsStack.isHidden && !penButton.isHidden }
}

#endif
