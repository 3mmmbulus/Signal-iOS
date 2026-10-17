//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1261 P-3）：点「✓N」之后，选图网格换成「只看已选」。
///
/// 机制照 Telegram（iOS `MediaPickerSelectedListNode`、Android `ChatAttachAlertPhotoLayoutPreview`）：会话的聊天背景上，
/// ≥ 2 张时顶部小字「拖动可调整顺序」，下面一行卡片就是排序区（owner 2026-09-25 选 A：聊天里的相册改回 Signal 原来的宫格之后，
/// 这里不再冒充「发出去的样子」，只管排顺序）：行用 `AlbumCarouselGeometry` 的行高、按原比例的宽、间距 8、圆角 18、放得下时靠右，
/// 松手吸附也照它；有说明时下面再一个发出方向的气泡。
/// - 长按 0.3 秒（同 Telegram）拖动排序，排序 = 发出去的顺序：拿起的那张跟着手指走，其它卡片实时让位，贴近两端时整行自动滚。
/// - 每张右上角的编号勾：点了取消选择（「已取消选择 N 张 · 撤销」由选图页弹）；点卡片本身进上游预览 / 编辑页。
///
/// Telegram 的实现只读机制、一行都没搬（GPLv2）。
final class TellomiPhotoPickerSelectedView: UIView, UIScrollViewDelegate {

    private enum Metrics {
        static let topPadding: CGFloat = 16
        static let chipsToRow: CGFloat = 16
        static let rowToCaption: CGFloat = 6
        static let startInset: CGFloat = 16
        static let captionMaxWidthFraction: CGFloat = 0.75
        static let reorderPressDuration: TimeInterval = 0.3
        static let autoScrollZone: CGFloat = 56
        static let autoScrollMaxSpeed: CGFloat = 12
        static let liftScale: CGFloat = 1.05
    }

    var onDeselect: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    /// 拖动排序时每次换位都报一次新的顺序（id）。
    var onReorder: (([String]) -> Void)?

    private let library: TellomiPhotoPickerLibrary
    private let bubbleColor: ColorOrGradientValue?

    private let backgroundView: UIView
    private let contentScrollView = UIScrollView()
    private let dragHintChip = TellomiPhotoPickerChip()
    private let rowScrollView = UIScrollView()
    private let captionBubble = TellomiPhotoPickerCaptionBubble()

    private(set) var items = [TellomiPhotoPickerItem]()
    private var cards = [String: TellomiPhotoPickerSelectedCard]()
    private var caption: String?
    private var rowLayout: AlbumCarouselGeometry.Layout?

    /// 底部被说明栏盖住的高度，内容要能滚出来。
    var bottomInset: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    init(library: TellomiPhotoPickerLibrary, chatBackground: UIView?, bubbleColor: ColorOrGradientValue?) {
        self.library = library
        self.bubbleColor = bubbleColor
        self.backgroundView = chatBackground ?? UIView()
        super.init(frame: .zero)

        if chatBackground == nil {
            backgroundView.backgroundColor = Theme.backgroundColor
        }
        backgroundView.clipsToBounds = true
        addSubview(backgroundView)

        contentScrollView.alwaysBounceVertical = true
        contentScrollView.showsVerticalScrollIndicator = false
        addSubview(contentScrollView)

        dragHintChip.text = OWSLocalizedString("IMAGE_PICKER_TELLOMI_DRAG_TO_REORDER", comment: "Hint in the photo picker's selected-only view that the photos can be dragged to change their order.")
        contentScrollView.addSubview(dragHintChip)

        rowScrollView.delegate = self
        rowScrollView.showsHorizontalScrollIndicator = false
        rowScrollView.decelerationRate = .fast
        rowScrollView.clipsToBounds = false
        contentScrollView.addSubview(rowScrollView)

        captionBubble.configure(color: bubbleColor, referenceView: self)
        contentScrollView.addSubview(captionBubble)

        rowScrollView.addGestureRecognizer(reorderGesture)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    /// 已选（按发出去的顺序）与说明。拖动排序进行中时忽略（顺序以拖动为准，结束时会报出去）。
    /// `spoileredIds`（#1263 spec P-6）：罩住的那几张，卡片上同网格一样罩着（照 Telegram iOS `MediaPickerSelectedListNode`）。
    func update(items newItems: [TellomiPhotoPickerItem], caption newCaption: String?, spoileredIds: Set<String> = [], animated: Bool) {
        caption = newCaption?.nilIfEmpty
        for (id, card) in cards {
            card.setSpoiler(spoileredIds.contains(id), animated: animated)
        }
        guard reorder == nil else {
            setNeedsLayout()
            return
        }

        let newIds = Set(newItems.map(\.id))
        for (id, card) in cards where !newIds.contains(id) {
            cards[id] = nil
            if animated {
                UIView.animate(withDuration: 0.2, animations: {
                    card.alpha = 0
                    card.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
                }, completion: { _ in card.removeFromSuperview() })
            } else {
                card.removeFromSuperview()
            }
        }
        for item in newItems where cards[item.id] == nil {
            let card = TellomiPhotoPickerSelectedCard(item: item)
            card.setSpoiler(spoileredIds.contains(item.id), animated: false)
            card.onCheckTapped = { [weak self] in self?.onDeselect?(item.id) }
            card.onTapped = { [weak self] in self?.onOpen?(item.id) }
            rowScrollView.addSubview(card)
            cards[item.id] = card
        }
        let isNew = Set(newItems.map(\.id)).subtracting(items.map(\.id))
        items = newItems

        layoutContent()
        // 新来的卡片直接放到位（不从零尺寸长出来），再按真实尺寸取缩略图；原有的卡片再动画让位。
        if let rowLayout {
            for (index, item) in items.enumerated() where isNew.contains(item.id) {
                cards[item.id]?.frame = rowLayout.itemFrame(index)
                cards[item.id]?.loadThumbnail(from: library, scale: window?.screen.scale ?? UIScreen.main.scale)
            }
        }
        if animated {
            UIView.animate(withDuration: 0.25) { self.layoutRowCards() }
        } else {
            layoutRowCards()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundView.frame = bounds
        contentScrollView.frame = bounds
        layoutContent()
        layoutRowCards()
    }

    private func layoutContent() {
        let width = bounds.width
        guard width > 0 else { return }

        var y = Metrics.topPadding

        // 只有一张时没什么可排的，不提示。
        dragHintChip.isHidden = items.count < 2
        if !dragHintChip.isHidden {
            dragHintChip.sizeToFit()
            dragHintChip.center = CGPoint(x: width / 2, y: y + dragHintChip.bounds.height / 2)
            y += dragHintChip.bounds.height
        }
        y += Metrics.chipsToRow

        // 行高用 AlbumCarouselGeometry：按宽算，横屏与 iPad 再按屏高封顶。
        let screenSize = window?.bounds.size ?? UIScreen.main.bounds.size
        let capByScreenHeight = screenSize.width > screenSize.height || UIDevice.current.userInterfaceIdiom == .pad
        let rowHeight = AlbumCarouselGeometry.rowHeight(screenWidth: width, screenHeight: screenSize.height, capByScreenHeight: capByScreenHeight)
        if items.isEmpty {
            rowLayout = nil
        } else {
            rowLayout = AlbumCarouselGeometry.layout(
                viewportWidth: width,
                startInset: Metrics.startInset,
                endMargin: AlbumCarouselGeometry.endMargin,
                spacing: AlbumCarouselGeometry.itemSpacing,
                minNextPeek: AlbumCarouselGeometry.nextItemMinPeek,
                rowHeight: rowHeight,
                aspectRatios: items.map { AlbumCarouselGeometry.aspectRatio($0.pixelSize) },
                alignEndWhenFits: true,
            )
        }
        rowScrollView.frame = CGRect(x: 0, y: y, width: width, height: rowHeight)
        rowScrollView.contentSize = CGSize(width: rowLayout?.contentWidth ?? width, height: rowHeight)
        if let rowLayout, rowScrollView.contentOffset.x > rowLayout.maxScroll, reorder == nil {
            rowScrollView.contentOffset.x = rowLayout.maxScroll
        }
        y += rowHeight

        captionBubble.text = caption
        captionBubble.isHidden = caption == nil
        if !captionBubble.isHidden {
            y += Metrics.rowToCaption
            let maxWidth = (width * Metrics.captionMaxWidthFraction).rounded(.down)
            let size = captionBubble.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            captionBubble.frame = CGRect(x: width - AlbumCarouselGeometry.endMargin - size.width, y: y, width: size.width, height: size.height)
            y += size.height
        }

        contentScrollView.contentSize = CGSize(width: width, height: y + Metrics.topPadding)
        contentScrollView.contentInset.bottom = bottomInset
        contentScrollView.verticalScrollIndicatorInsets.bottom = bottomInset
    }

    /// 卡片放到当前顺序的位置上（拖着的那张也有位置，只是看不见，快照在它上面跟手）。
    private func layoutRowCards() {
        guard let rowLayout else { return }
        for (index, item) in items.enumerated() {
            guard let card = cards[item.id] else { continue }
            card.transform = .identity
            card.frame = rowLayout.itemFrame(index)
            card.setNumber(index + 1)
        }
    }

    // MARK: - UIScrollViewDelegate（这一行的吸附：AlbumCarouselGeometry）

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard scrollView === rowScrollView, let rowLayout else { return }
        let velocitySign = velocity.x > 0.2 ? 1 : (velocity.x < -0.2 ? -1 : 0)
        targetContentOffset.pointee.x = rowLayout.targetSnapOffset(
            currentOffset: scrollView.contentOffset.x,
            projectedOffset: targetContentOffset.pointee.x,
            velocitySign: velocitySign,
        )
    }

    // MARK: - Reorder

    private struct Reorder {
        let id: String
        let snapshot: UIView
        /// 手指相对快照中心的偏移。
        let touchOffset: CGPoint
    }

    private var reorder: Reorder?
    private var lastReorderPoint: CGPoint?
    private var autoScrollLink: CADisplayLink?

    private lazy var reorderGesture: UILongPressGestureRecognizer = {
        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleReorderGesture(_:)))
        gesture.minimumPressDuration = Metrics.reorderPressDuration
        return gesture
    }()

    @objc
    private func handleReorderGesture(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            if !beginReorder(at: point) {
                // 没落在卡片上（或只有一张）：取消这次长按。
                gesture.isEnabled = false
                gesture.isEnabled = true
            }
        case .changed:
            moveReorder(to: point)
        case .ended:
            endReorder()
        case .cancelled, .failed:
            endReorder()
        default:
            break
        }
    }

    /// 长按落在一张卡片上（至少两张才能排）：拿起它。`point` 是本视图坐标。
    @discardableResult
    func beginReorder(at point: CGPoint) -> Bool {
        guard reorder == nil, items.count >= 2 else { return false }
        let contentPoint = convert(point, to: rowScrollView)
        guard
            let item = items.first(where: { cards[$0.id]?.frame.contains(contentPoint) == true }),
            let card = cards[item.id]
        else {
            return false
        }

        let frame = rowScrollView.convert(card.frame, to: self)
        let snapshot = card.snapshotView(afterScreenUpdates: false) ?? UIView()
        snapshot.frame = frame
        snapshot.layer.shadowColor = UIColor.black.cgColor
        snapshot.layer.shadowOpacity = 0.3
        snapshot.layer.shadowRadius = 10
        snapshot.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(snapshot)
        card.alpha = 0

        reorder = Reorder(id: item.id, snapshot: snapshot, touchOffset: CGPoint(x: point.x - frame.midX, y: point.y - frame.midY))
        lastReorderPoint = point
        UIView.animate(withDuration: 0.2) {
            snapshot.transform = CGAffineTransform(scaleX: Metrics.liftScale, y: Metrics.liftScale)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        return true
    }

    /// 手指移到了 `point`（本视图坐标）：快照跟手，按快照中心换位，贴近两端就开始自动滚。
    func moveReorder(to point: CGPoint) {
        guard let reorder else { return }
        lastReorderPoint = point
        reorder.snapshot.center = CGPoint(x: point.x - reorder.touchOffset.x, y: point.y - reorder.touchOffset.y)
        moveDraggedItemTowardSnapshot()
        updateAutoScroll()
    }

    func endReorder() {
        stopAutoScroll()
        guard let reorder else { return }
        self.reorder = nil
        lastReorderPoint = nil
        guard let card = cards[reorder.id] else {
            reorder.snapshot.removeFromSuperview()
            return
        }
        let target = rowScrollView.convert(card.frame, to: self)
        UIView.animate(withDuration: 0.2, animations: {
            reorder.snapshot.transform = .identity
            reorder.snapshot.frame = target
        }, completion: { _ in
            card.alpha = 1
            reorder.snapshot.removeFromSuperview()
        })
    }

    /// 目标位置 = 其它卡片里中心在快照中心左边的有几张。
    private func moveDraggedItemTowardSnapshot() {
        guard let reorder, let rowLayout, let from = items.firstIndex(where: { $0.id == reorder.id }) else { return }
        let x = convert(reorder.snapshot.center, to: rowScrollView).x
        var target = 0
        for (index, item) in items.enumerated() where item.id != reorder.id && rowLayout.itemFrame(index).midX < x {
            target += 1
        }
        guard target != from else { return }

        let item = items.remove(at: from)
        items.insert(item, at: target)
        layoutContent()
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.layoutRowCards()
        }
        UISelectionFeedbackGenerator().selectionChanged()
        onReorder?(items.map(\.id))
    }

    /// 贴近这一行两端 56 以内：往那边滚，越靠边越快（每帧最多 12）。
    private func autoScrollStep(for point: CGPoint) -> CGFloat {
        guard let rowLayout, rowLayout.isScrollable else { return 0 }
        let row = rowScrollView.frame.offsetBy(dx: 0, dy: -contentScrollView.contentOffset.y)
        if point.x < row.minX + Metrics.autoScrollZone {
            return -Metrics.autoScrollMaxSpeed * min(1, (row.minX + Metrics.autoScrollZone - point.x) / Metrics.autoScrollZone)
        }
        if point.x > row.maxX - Metrics.autoScrollZone {
            return Metrics.autoScrollMaxSpeed * min(1, (point.x - (row.maxX - Metrics.autoScrollZone)) / Metrics.autoScrollZone)
        }
        return 0
    }

    private func updateAutoScroll() {
        guard let point = lastReorderPoint, autoScrollStep(for: point) != 0 else {
            stopAutoScroll()
            return
        }
        guard autoScrollLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
        link.preferredFrameRateRange = TellomiFrameRate.interactive
        link.add(to: .main, forMode: .common)
        autoScrollLink = link
    }

    private func stopAutoScroll() {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
    }

    /// 一帧：滚一步，再按快照（它不动，底下的卡片动了）重新换位。
    @objc
    func autoScrollTick() {
        guard let point = lastReorderPoint, let rowLayout else {
            stopAutoScroll()
            return
        }
        let step = autoScrollStep(for: point)
        guard step != 0 else {
            stopAutoScroll()
            return
        }
        let offset = min(max(rowScrollView.contentOffset.x + step, 0), rowLayout.maxScroll)
        rowScrollView.contentOffset.x = offset
        moveDraggedItemTowardSnapshot()
    }
}

// MARK: - Card

/// 「只看已选」里的一张：圆角 18 的卡片，右上角编号勾，视频右下角时长。
private final class TellomiPhotoPickerSelectedCard: UIView {

    let item: TellomiPhotoPickerItem
    var onCheckTapped: (() -> Void)?
    var onTapped: (() -> Void)?

    private let imageView = UIImageView()
    private let check = TellomiNumberedCheck()
    private let durationLabel = UILabel()
    private var thumbnailRequest: TellomiPhotoPickerRequest?
    private var spoilerCover: TellomiSpoilerCoverView?
    private(set) var isSpoilerShown = false

    init(item: TellomiPhotoPickerItem) {
        self.item = item
        super.init(frame: .zero)

        backgroundColor = .Signal.secondaryBackground
        layer.cornerRadius = AlbumCarouselGeometry.itemCornerRadius
        clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)

        durationLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.layer.shadowColor = UIColor.black.cgColor
        durationLabel.layer.shadowOpacity = 0.5
        durationLabel.layer.shadowRadius = 2
        durationLabel.layer.shadowOffset = .zero
        durationLabel.text = item.isVideo ? TellomiPhotoPickerCell.formatDuration(item.duration) : nil
        durationLabel.isHidden = !item.isVideo
        addSubview(durationLabel)

        check.addAction(UIAction { [weak self] _ in self?.onCheckTapped?() }, for: .touchUpInside)
        addSubview(check)

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTap)))
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        thumbnailRequest?.cancel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        spoilerCover?.frame = bounds
        check.frame = CGRect(
            x: bounds.width - TellomiNumberedCheck.touchSize - 6,
            y: 6,
            width: TellomiNumberedCheck.touchSize,
            height: TellomiNumberedCheck.touchSize,
        )
        durationLabel.sizeToFit()
        durationLabel.frame.origin = CGPoint(x: bounds.width - durationLabel.frame.width - 10, y: bounds.height - durationLabel.frame.height - 8)
    }

    func loadThumbnail(from library: TellomiPhotoPickerLibrary, scale: CGFloat) {
        let size = CGSize(width: max(bounds.width, 120) * scale, height: max(bounds.height, 120) * scale)
        thumbnailRequest?.cancel()
        thumbnailRequest = library.requestThumbnail(for: item, targetSize: size) { [weak self] image in
            guard let self, let image else { return }
            self.imageView.image = image
            if self.isSpoilerShown {
                self.spoilerCover?.cover(image: image, key: self.item.id)
            }
        }
    }

    /// 同网格的格子（`TellomiPhotoPickerCell.setSpoiler`）：0.2 秒淡入淡出，不能揭示。
    func setSpoiler(_ shown: Bool, animated: Bool) {
        guard shown != isSpoilerShown else { return }
        isSpoilerShown = shown
        if shown {
            let cover = spoilerCover ?? {
                let cover = TellomiSpoilerCoverView()
                insertSubview(cover, aboveSubview: imageView)
                spoilerCover = cover
                return cover
            }()
            cover.frame = bounds
            cover.layer.removeAllAnimations()
            cover.cover(image: imageView.image, key: item.id)
            cover.alpha = animated ? 0 : 1
            if animated {
                UIView.animate(withDuration: TellomiPhotoPickerCell.spoilerFadeDuration) { cover.alpha = 1 }
            }
        } else if let cover = spoilerCover {
            UIView.animate(withDuration: animated ? TellomiPhotoPickerCell.spoilerFadeDuration : 0, animations: { cover.alpha = 0 }, completion: { [weak self] _ in
                guard self?.isSpoilerShown == false else { return }
                cover.uncover()
                cover.alpha = 1
            })
        }
    }

    func setNumber(_ number: Int) {
        check.setNumber(number, accentColor: .Signal.accent, animated: false)
    }

    @objc
    private func didTap() {
        onTapped?()
    }

    var numberTextForTesting: String? { check.numberTextForTesting }

    func tapCheckForTesting() {
        onCheckTapped?()
    }
}

// MARK: - Chip / caption bubble

/// 「拖动可调整顺序」那样的小字胶囊（同会话里的日期标签，盖在聊天背景上）。
final class TellomiPhotoPickerChip: UIView {

    private let label = UILabel()
    private static let insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.Signal.secondaryBackground.withAlphaComponent(0.85)
        label.font = .dynamicTypeFootnoteClamped.medium()
        label.textColor = .Signal.secondaryLabel
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let labelSize = label.sizeThatFits(CGSize(width: size.width - Self.insets.left - Self.insets.right, height: .greatestFiniteMagnitude))
        return CGSize(
            width: ceil(labelSize.width) + Self.insets.left + Self.insets.right,
            height: ceil(labelSize.height) + Self.insets.top + Self.insets.bottom,
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        label.frame = bounds.inset(by: Self.insets)
    }
}

/// 说明：发出方向的气泡，颜色同会话（没有就用强调色）。
private final class TellomiPhotoPickerCaptionBubble: UIView {

    private let colorView = CVColorOrGradientView()
    private let label = UILabel()
    private static let insets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    var text: String? {
        get { label.text }
        set { label.text = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 18
        clipsToBounds = true
        addSubview(colorView)
        label.font = .dynamicTypeBody
        label.textColor = .white
        label.numberOfLines = 0
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(color: ColorOrGradientValue?, referenceView: UIView) {
        if let color {
            colorView.configure(value: color, referenceView: referenceView)
        } else {
            colorView.backgroundColor = .Signal.accent
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let labelSize = label.sizeThatFits(CGSize(width: size.width - Self.insets.left - Self.insets.right, height: .greatestFiniteMagnitude))
        return CGSize(
            width: ceil(labelSize.width) + Self.insets.left + Self.insets.right,
            height: ceil(labelSize.height) + Self.insets.top + Self.insets.bottom,
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        colorView.frame = bounds
        label.frame = bounds.inset(by: Self.insets)
    }
}

#if TESTABLE_BUILD

extension TellomiPhotoPickerSelectedView {
    var chipTextsForTesting: [String] {
        [dragHintChip].filter { !$0.isHidden }.compactMap(\.text)
    }

    var cardIdsForTesting: [String] { items.map(\.id) }

    var backgroundViewForTesting: UIView { backgroundView }

    var cardNumbersForTesting: [String?] { items.map { cards[$0.id]?.numberTextForTesting } }

    var spoileredCardIdsForTesting: [String] { items.map(\.id).filter { cards[$0]?.isSpoilerShown == true } }

    /// 每张卡片在这一行里的位置（内容坐标）。
    var cardFramesForTesting: [CGRect] { items.compactMap { cards[$0.id]?.frame } }

    var rowFrameForTesting: CGRect { rowScrollView.frame }

    var rowContentOffsetForTesting: CGFloat {
        get { rowScrollView.contentOffset.x }
        set { rowScrollView.contentOffset.x = newValue }
    }

    var rowLayoutForTesting: AlbumCarouselGeometry.Layout? { rowLayout }

    var captionBubbleTextForTesting: String? { captionBubble.isHidden ? nil : captionBubble.text }

    var captionBubbleFrameForTesting: CGRect { captionBubble.frame }

    var reorderPressDurationForTesting: TimeInterval { reorderGesture.minimumPressDuration }

    var isReorderingForTesting: Bool { reorder != nil }

    /// 某张卡片中心在本视图里的位置。
    func cardCenterForTesting(_ id: String) -> CGPoint? {
        guard let card = cards[id] else { return nil }
        let frame = rowScrollView.convert(card.frame, to: self)
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func tapCheckForTesting(_ id: String) {
        cards[id]?.tapCheckForTesting()
    }

    func tapCardForTesting(_ id: String) {
        cards[id]?.onTapped?()
    }

    func scrollViewWillEndDraggingForTesting(projectedOffset: CGFloat, velocity: CGFloat) -> CGFloat {
        var target = CGPoint(x: projectedOffset, y: 0)
        scrollViewWillEndDragging(rowScrollView, withVelocity: CGPoint(x: velocity, y: 0), targetContentOffset: &target)
        return target.x
    }
}

#endif
