//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1519 M-5，照 Telegram iOS `ChatSendMessageContextScreen`）：长按发送键，背景模糊压暗，
/// 发送键左边是「发出去是什么样」的气泡（相册排法同会话、说明在上 / 在下），气泡下面是菜单；菜单里切「说明文字上移 / 下移」，
/// 菜单不收、气泡当场重排。点发送键就发，点空白处收起。
///
/// 机制照 Telegram（只读，代码是自己写的）：气泡右边贴着发送键、底边比发送键底边高 6 pt；菜单在气泡下面、右边对齐；
/// 菜单超出底部安全区时气泡、菜单、发送键一起往上挪（`ChatSendMessageContextScreen` 的 `bottomOverflow`）。
/// 不同：Telegram 的气泡是聊天里真正的消息视图，这里是同样排法的简化气泡（会话气泡的视图要整条消息的数据，选图时还没有）；
/// 编辑过的照片（裁剪、涂鸦）这里显示原图，编辑要到发送时才画出来。
final class TellomiSendPreviewViewController: UIViewController {

    struct Action {
        let title: String
        let image: UIImage?
        /// 点了不收（「说明文字上移 / 下移」，同 Telegram）。
        let keepsPresented: Bool
        let handler: () -> Void
    }

    struct Tile {
        /// 宽 / 高；不知道就 1。
        let aspectRatio: CGFloat
        let loadImage: (CGSize, @escaping (UIImage?) -> Void) -> TellomiPhotoPickerRequest?
    }

    private enum Metrics {
        static let bubbleMaxWidth: CGFloat = 260
        static let bubbleCornerRadius: CGFloat = 18
        static let tileGap: CGFloat = 2
        static let captionInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        /// 气泡 / 菜单和发送键之间。
        static let buttonGap: CGFloat = 8
        /// 气泡底边比发送键底边高这么多（Telegram：6）。
        static let bubbleBottomOverButton: CGFloat = 6
        static let menuSpacing: CGFloat = 7
        static let screenMargin: CGFloat = 8
        static let menuMinWidth: CGFloat = 250
        static let menuCornerRadius: CGFloat = 14
        static let menuRowHeight: CGFloat = 44
        static let animationDuration: TimeInterval = 0.25
    }

    private let tiles: [Tile]
    private let caption: String?
    private var captionAboveMedia: Bool
    private var actions: [Action]
    private let bubbleColor: ColorOrGradientValue?
    private weak var sourceButton: UIView?
    private let onSend: () -> Void

    private let blurView = UIVisualEffectView(effect: nil)
    private let dimView = UIView()
    private let messageScrollView = UIScrollView()
    private let bubbleView = UIView()
    private let bubbleColorView = CVColorOrGradientView()
    private let captionLabel = UILabel()
    private var tileViews = [UIImageView]()
    private let moreLabel = UILabel()
    private let menuView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private var menuRows = [MenuRow]()
    private var sendButtonView: UIView?
    private var requests = [TellomiPhotoPickerRequest]()
    private var isDismissing = false

    init(
        tiles: [Tile],
        caption: String?,
        captionAboveMedia: Bool,
        bubbleColor: ColorOrGradientValue?,
        actions: [Action],
        sourceButton: UIView,
        onSend: @escaping () -> Void,
    ) {
        self.tiles = tiles
        self.caption = caption?.nilIfEmpty
        self.captionAboveMedia = captionAboveMedia
        self.bubbleColor = bubbleColor
        self.actions = actions
        self.sourceButton = sourceButton
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        requests.forEach { $0.cancel() }
    }

    /// 菜单里的开关点了之后：说明换位置、菜单换字，不收。
    func update(captionAboveMedia: Bool, actions: [Action]) {
        self.actions = actions
        rebuildMenu()
        guard captionAboveMedia != self.captionAboveMedia else {
            view.setNeedsLayout()
            return
        }
        self.captionAboveMedia = captionAboveMedia
        UIView.animate(withDuration: Metrics.animationDuration, delay: 0, options: [.beginFromCurrentState]) {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true

        blurView.frame = view.bounds
        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(blurView)
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        dimView.frame = view.bounds
        dimView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimView.alpha = 0
        view.addSubview(dimView)
        let backgroundTap = UITapGestureRecognizer(target: self, action: #selector(didTapBackground))
        dimView.addGestureRecognizer(backgroundTap)

        messageScrollView.showsVerticalScrollIndicator = false
        messageScrollView.alwaysBounceVertical = false
        messageScrollView.clipsToBounds = false
        view.addSubview(messageScrollView)

        bubbleView.layer.cornerRadius = Metrics.bubbleCornerRadius
        bubbleView.clipsToBounds = true
        bubbleView.isAccessibilityElement = true
        bubbleView.accessibilityLabel = caption
        bubbleView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapBackground)))
        messageScrollView.addSubview(bubbleView)
        // 会话的发出气泡颜色（可能是渐变）；没有就用强调色（同发送键）
        if let bubbleColor {
            bubbleColorView.configure(value: bubbleColor, referenceView: bubbleView)
            // 它是手动布局的视图（不跟着父视图的 autoresizing），不放开的话下一轮布局会被压成 0
            bubbleColorView.translatesAutoresizingMaskIntoConstraints = true
            bubbleColorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            bubbleView.addSubview(bubbleColorView)
        } else {
            bubbleView.backgroundColor = .Signal.accent
        }

        for (index, tile) in tiles.prefix(5).enumerated() {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.backgroundColor = .Signal.secondaryFill
            bubbleView.addSubview(imageView)
            tileViews.append(imageView)
            let pixels = CGSize(width: 260 * UIScreen.main.scale, height: 260 * UIScreen.main.scale)
            if
                let request = tile.loadImage(pixels, { [weak imageView] image in
                    imageView?.image = image
                })
            {
                requests.append(request)
            }
            if index == 4, tiles.count > 5 {
                moreLabel.text = "+\(tiles.count - 5)"
                moreLabel.font = .dynamicTypeTitle2.semibold()
                moreLabel.textColor = .white
                moreLabel.textAlignment = .center
                moreLabel.backgroundColor = UIColor.black.withAlphaComponent(0.4)
                imageView.addSubview(moreLabel)
            }
        }

        captionLabel.text = caption
        captionLabel.font = .dynamicTypeBody
        captionLabel.textColor = .white
        captionLabel.numberOfLines = 0
        captionLabel.isHidden = caption == nil
        bubbleView.addSubview(captionLabel)

        menuView.layer.cornerRadius = Metrics.menuCornerRadius
        menuView.clipsToBounds = true
        view.addSubview(menuView)
        rebuildMenu()

        if let snapshot = sourceButton?.snapshotView(afterScreenUpdates: false) {
            snapshot.isUserInteractionEnabled = true
            snapshot.isAccessibilityElement = true
            snapshot.accessibilityLabel = MessageStrings.sendButton
            snapshot.accessibilityTraits = .button
            snapshot.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapSend)))
            view.addSubview(snapshot)
            sendButtonView = snapshot
        }

        setContentVisible(false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 发送键画在预览里（放不下时挪上去），原处的先藏起来
        sourceButton?.alpha = 0
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sourceButton?.alpha = 1
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIView.animate(withDuration: Metrics.animationDuration, delay: 0, options: [.curveEaseOut]) {
            self.setContentVisible(true)
        }
        UIAccessibility.post(notification: .screenChanged, argument: menuRows.first)
    }

    override func accessibilityPerformEscape() -> Bool {
        dismissPreview()
        return true
    }

    private func setContentVisible(_ visible: Bool) {
        blurView.effect = visible ? UIBlurEffect(style: .systemUltraThinMaterial) : nil
        dimView.alpha = visible ? 1 : 0
        for view in [messageScrollView, menuView] {
            view.alpha = visible ? 1 : 0
            view.transform = visible ? .identity : CGAffineTransform(scaleX: 0.9, y: 0.9)
        }
    }

    // MARK: - Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let layout = computeLayout()

        // transform 不是 identity 时设 frame 会错位：先还原再放，动画状态再套回去。
        let messageTransform = messageScrollView.transform
        let menuTransform = menuView.transform
        messageScrollView.transform = .identity
        menuView.transform = .identity

        messageScrollView.frame = layout.message
        messageScrollView.contentSize = layout.bubble.size
        bubbleView.frame = layout.bubble
        bubbleColorView.frame = bubbleView.bounds
        for (view, frame) in zip(tileViews, layout.tiles) {
            view.frame = frame
        }
        moreLabel.frame = tileViews.last?.bounds ?? .zero
        captionLabel.frame = layout.caption
        let bottomOffset = max(0, layout.bubble.height - layout.message.height)
        messageScrollView.contentOffset = CGPoint(x: 0, y: bottomOffset)

        menuView.frame = layout.menu
        var y: CGFloat = 0
        for (index, row) in menuRows.enumerated() {
            row.frame = CGRect(x: 0, y: y, width: layout.menu.width, height: Metrics.menuRowHeight)
            row.showsSeparator = index < menuRows.count - 1
            y += Metrics.menuRowHeight
        }
        sendButtonView?.frame = layout.sendButton

        setAnchorPoint(CGPoint(x: 1, y: 1), of: messageScrollView)
        setAnchorPoint(CGPoint(x: 1, y: 0), of: menuView)
        messageScrollView.transform = messageTransform
        menuView.transform = menuTransform
    }

    private func setAnchorPoint(_ anchor: CGPoint, of view: UIView) {
        let frame = view.frame
        view.layer.anchorPoint = anchor
        view.frame = frame
    }

    struct Layout {
        var message: CGRect
        var bubble: CGRect
        var tiles: [CGRect]
        var caption: CGRect
        var menu: CGRect
        var sendButton: CGRect
    }

    private func computeLayout() -> Layout {
        let bounds = view.bounds
        let safe = bounds.inset(by: view.safeAreaInsets)
        let source: CGRect = {
            guard let sourceButton, sourceButton.window != nil else {
                return CGRect(x: safe.maxX - 44, y: safe.maxY - 44, width: 44, height: 44)
            }
            return sourceButton.convert(sourceButton.bounds, to: view)
        }()

        let bubbleWidth = max(120, min(Metrics.bubbleMaxWidth, source.minX - Metrics.buttonGap - safe.minX - Metrics.screenMargin))
        let tileFrames = Self.mosaicFrames(count: tiles.count, width: bubbleWidth, firstAspectRatio: tiles.first?.aspectRatio ?? 1)
        let mosaicHeight = tileFrames.map(\.maxY).max() ?? 0
        let captionSize: CGSize = caption == nil ? .zero : {
            let insets = Metrics.captionInsets
            let fits = captionLabel.sizeThatFits(CGSize(width: bubbleWidth - insets.left - insets.right, height: .greatestFiniteMagnitude))
            return CGSize(width: bubbleWidth, height: ceil(fits.height) + insets.top + insets.bottom)
        }()
        let mosaicY = captionAboveMedia ? captionSize.height : 0
        let tiles = tileFrames.map { $0.offsetBy(dx: 0, dy: mosaicY) }
        let caption: CGRect = {
            guard self.caption != nil else { return .zero }
            let y = captionAboveMedia ? 0 : mosaicHeight
            return CGRect(x: 0, y: y, width: bubbleWidth, height: captionSize.height).inset(by: Metrics.captionInsets)
        }()
        let bubbleSize = CGSize(width: bubbleWidth, height: mosaicHeight + captionSize.height)

        let menuWidth = max(Metrics.menuMinWidth, menuRows.map { $0.fittingWidth }.max() ?? 0)
        let menuHeight = CGFloat(menuRows.count) * Metrics.menuRowHeight

        var sendButton = source
        var message = CGRect(
            x: sendButton.minX - Metrics.buttonGap - bubbleSize.width,
            y: sendButton.maxY - Metrics.bubbleBottomOverButton - bubbleSize.height,
            width: bubbleSize.width,
            height: bubbleSize.height,
        )
        var menu = CGRect(
            x: sendButton.minX - Metrics.buttonGap - menuWidth,
            y: message.maxY + Metrics.menuSpacing,
            width: menuWidth,
            height: menuHeight,
        )
        menu.origin.x = max(menu.minX, safe.minX + Metrics.screenMargin)

        // 同 Telegram：菜单超出底部安全区，三样一起往上挪。
        let bottomOverflow = menu.maxY - (safe.maxY - Metrics.screenMargin)
        if bottomOverflow > 0 {
            message.origin.y -= bottomOverflow
            menu.origin.y -= bottomOverflow
            sendButton.origin.y -= bottomOverflow
        }
        // 上面放不下：气泡限高，能滚，先看到底部（离发送键最近的那部分）。
        let topLimit = safe.minY + Metrics.screenMargin
        if message.minY < topLimit {
            message.size.height = max(0, message.maxY - topLimit)
            message.origin.y = topLimit
        }

        return Layout(
            message: message,
            bubble: CGRect(origin: .zero, size: bubbleSize),
            tiles: tiles,
            caption: caption,
            menu: menu,
            sendButton: sendButton,
        )
    }

    /// 和会话里的相册同一种排法：1 张按比例（0.6–1.8），2 张左右，3 张左大右二，4 张 2 × 2，5 张及以上上 2 下 3（多的写在第 5 格）。
    static func mosaicFrames(count: Int, width: CGFloat, firstAspectRatio: CGFloat) -> [CGRect] {
        let gap = Metrics.tileGap
        let half = ((width - gap) / 2).rounded(.down)
        let right = width - half - gap
        switch count {
        case 0:
            return []
        case 1:
            let aspect = min(max(firstAspectRatio, 0.6), 1.8)
            return [CGRect(x: 0, y: 0, width: width, height: (width / aspect).rounded())]
        case 2:
            return [
                CGRect(x: 0, y: 0, width: half, height: half),
                CGRect(x: half + gap, y: 0, width: right, height: half),
            ]
        case 3:
            return [
                CGRect(x: 0, y: 0, width: half, height: half * 2 + gap),
                CGRect(x: half + gap, y: 0, width: right, height: half),
                CGRect(x: half + gap, y: half + gap, width: right, height: half),
            ]
        case 4:
            return [
                CGRect(x: 0, y: 0, width: half, height: half),
                CGRect(x: half + gap, y: 0, width: right, height: half),
                CGRect(x: 0, y: half + gap, width: half, height: half),
                CGRect(x: half + gap, y: half + gap, width: right, height: half),
            ]
        default:
            let third = ((width - gap * 2) / 3).rounded(.down)
            let last = width - third * 2 - gap * 2
            let y = half + gap
            return [
                CGRect(x: 0, y: 0, width: half, height: half),
                CGRect(x: half + gap, y: 0, width: right, height: half),
                CGRect(x: 0, y: y, width: third, height: third),
                CGRect(x: third + gap, y: y, width: third, height: third),
                CGRect(x: (third + gap) * 2, y: y, width: last, height: third),
            ]
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        menuRows.forEach { $0.removeFromSuperview() }
        menuRows = actions.enumerated().map { index, action in
            let row = MenuRow(title: action.title, image: action.image)
            row.addAction(UIAction { [weak self] _ in self?.perform(actionAt: index) }, for: .primaryActionTriggered)
            menuView.contentView.addSubview(row)
            return row
        }
    }

    private func perform(actionAt index: Int) {
        guard actions.indices.contains(index), !isDismissing else { return }
        let action = actions[index]
        if action.keepsPresented {
            action.handler()
        } else {
            dismissPreview(then: action.handler)
        }
    }

    // MARK: - Actions

    @objc
    private func didTapBackground() {
        dismissPreview()
    }

    @objc
    private func didTapSend() {
        guard !isDismissing else { return }
        // 发送不等收起的动画（同 Telegram：点了就发）。
        isDismissing = true
        let onSend = self.onSend
        dismiss(animated: false) { onSend() }
    }

    func dismissPreview(then completion: (() -> Void)? = nil) {
        guard !isDismissing else { return }
        isDismissing = true
        UIView.animate(withDuration: Metrics.animationDuration * 0.8, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.setContentVisible(false)
        } completion: { _ in
            self.dismiss(animated: false, completion: completion)
        }
    }
}

// MARK: - Menu row

private final class MenuRow: UIControl {

    private let titleLabel = UILabel()
    private let iconView = UIImageView()
    private let separator = UIView()
    private static let insets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
    private static let iconSize: CGFloat = 22

    var showsSeparator = false {
        didSet { separator.isHidden = !showsSeparator }
    }

    init(title: String, image: UIImage?) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = .dynamicTypeBody
        titleLabel.textColor = .Signal.label
        titleLabel.adjustsFontForContentSizeCategory = true
        addSubview(titleLabel)
        iconView.image = image?.withRenderingMode(.alwaysTemplate)
        iconView.tintColor = .Signal.label
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)
        separator.backgroundColor = .Signal.opaqueSeparator
        separator.isHidden = true
        addSubview(separator)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var title: String? { titleLabel.text }

    var fittingWidth: CGFloat {
        Self.insets.left + ceil(titleLabel.intrinsicContentSize.width) + 16 + Self.iconSize + Self.insets.right
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? .Signal.secondaryFill : .clear }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = bounds.inset(by: Self.insets)
        iconView.frame = CGRect(x: content.maxX - Self.iconSize, y: content.midY - Self.iconSize / 2, width: Self.iconSize, height: Self.iconSize)
        titleLabel.frame = CGRect(x: content.minX, y: content.minY, width: iconView.frame.minX - 16 - content.minX, height: content.height)
        let hairline = 1 / max(traitCollection.displayScale, 1)
        separator.frame = CGRect(x: 0, y: bounds.maxY - hairline, width: bounds.width, height: hairline)
    }
}

#if TESTABLE_BUILD

extension TellomiSendPreviewViewController {
    var actionTitlesForTesting: [String] { menuRows.compactMap(\.title) }

    func performActionForTesting(at index: Int) {
        menuRows[index].sendActions(for: .primaryActionTriggered)
    }

    func tapBackgroundForTesting() {
        didTapBackground()
    }

    func tapSendForTesting() {
        didTapSend()
    }

    /// 说明在图上面：true；在下面：false；没有说明：nil。
    var captionIsAboveMediaForTesting: Bool? {
        guard !captionLabel.isHidden, let firstTile = tileViews.first else { return nil }
        return captionLabel.frame.maxY <= firstTile.frame.minY
    }

    var captionTextForTesting: String? { captionLabel.isHidden ? nil : captionLabel.text }

    /// 都在本视图坐标里（不含出场动画的缩放）。
    var layoutForTesting: Layout { computeLayout() }

    var moreTextForTesting: String? { moreLabel.superview == nil ? nil : moreLabel.text }

    /// 气泡底色那一层铺满了气泡（会话颜色时）。
    var bubbleColorFillsTheBubbleForTesting: Bool {
        bubbleColorView.superview == nil ? bubbleView.backgroundColor != nil : bubbleColorView.frame == bubbleView.bounds
    }
}

#endif
