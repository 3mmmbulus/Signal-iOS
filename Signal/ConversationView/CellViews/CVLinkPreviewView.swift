//
// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit.UIGestureRecognizerSubclass

/// Component designed to show link preview in a message bubble.
class CVLinkPreviewView: ManualStackViewWithLayer {

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private var linkPreview: LinkPreviewState?
    private var configurationSize: CGSize?
    private var shouldReconfigureForBounds = false

    fileprivate let textStack = ManualStackView(name: "textStack")

    fileprivate let linkPreviewImageView = CVLinkPreviewImageView()

    /// 无图卡行尾的链接图标（Tellomi，card-visual §3.7）。
    fileprivate let linkIconView = CVImageView()

    /// 第一方卡（Tellomi，card-visual §5.2）：头部（头像 + 文字）、头部与按钮之间的细线、底部的动作按钮，以及没有真图时的占位头像。
    fileprivate let firstPartyHeaderStack = ManualStackView(name: "firstPartyHeaderStack")
    fileprivate let firstPartyDivider = UIView()
    fileprivate let firstPartyActionLabel = CVLabel()
    fileprivate let firstPartyPlaceholder = CVImageView()
    /// 本机认识的用户的真头像（56 pt 圆形，不带徽章）。
    fileprivate let firstPartyAvatar = ConversationAvatarView(sizeClass: .fiftySix, localUserDisplayMode: .asUser, badged: false, useAutolayout: false)

    init() {
        super.init(name: "CVLinkPreviewView")

        layer.masksToBounds = true
        layer.cornerRadius = 10
    }

    func configureForRendering(
        linkPreview: LinkPreviewState,
        isIncoming: Bool,
        isInteractive: Bool,
        cellMeasurement: CVCellMeasurement,
    ) {
        self.linkPreview = linkPreview

        guard let conversationStyle = linkPreview.conversationStyle else {
            owsFailDebug("ConversationStyle not set")
            return
        }

        // Background is always the same for all link previews, except Tellomi's tinted cards
        // (card-visual §3.3: the colours of the card's own image; light and dark sets follow the system appearance).
        if let tint = (linkPreview as? TellomiLinkPreviewCardState)?.tintColors {
            backgroundColor = tint.background
        } else {
            backgroundColor = switch (conversationStyle.hasWallpaper, isIncoming) {
            case (true, true): UIColor.Signal.MaterialBase.fillTertiary
            case (_, true): UIColor.Signal.LightBase.fillTertiary
            case (_, false): UIColor.Signal.ColorBase.fillTertiary
            }
        }

        // Layout varies based on link preview type.
        let adapter = Self.adapter(for: linkPreview, isIncoming: isIncoming)
        adapter.configureForRendering(
            linkPreviewView: self,
            cellMeasurement: cellMeasurement,
        )

        // 按下态 / 悬停态的叠层盖在所有内容上面，所以排完版再装。
        installHighlight(color: adapter.highlightOverlayColor, isInteractive: isInteractive)
    }

    private static func adapter(
        for linkPreview: LinkPreviewState,
        isIncoming: Bool,
    ) -> CVLinkPreviewViewAdapter {
        // Tellomi 自己对象的卡片（群邀请也在内）先于 Signal 自己的群邀请 / 通话版式。
        if let card = linkPreview as? TellomiLinkPreviewCardState, card.firstParty != nil {
            return CVLinkPreviewViewAdapterFirstParty(linkPreview: linkPreview, isIncoming: isIncoming)
        }
        if linkPreview.isGroupInviteLink || linkPreview.isCallLink {
            return CVLinkPreviewViewAdapterSignalLink(linkPreview: linkPreview, isIncoming: isIncoming)
        }
        if let card = linkPreview as? TellomiLinkPreviewCardState {
            if card.isPlainLink {
                return CVLinkPreviewViewAdapterPlainLink(linkPreview: linkPreview, isIncoming: isIncoming)
            }
            // card-visual §3.2：版式由 rust/links 按图的尺寸定（两端阈值不再各是各的），没有决定时照 Signal 原样。
            switch card.layout {
            case .noImage:
                // 没有图的卡（generic 无图、没有随包图标的品牌壳、支付壳、无图的位置卡……）：标题 + 副行 + 域名，右侧通用链接图标。
                return CVLinkPreviewViewAdapterNoImage(linkPreview: linkPreview, isIncoming: isIncoming)
            case .largeImage where linkPreview.hasLoadedImageOrBlurHash:
                return CVLinkPreviewViewAdapterLarge(linkPreview: linkPreview, isIncoming: isIncoming)
            case .icon where linkPreview.hasLoadedImageOrBlurHash:
                return CVLinkPreviewViewAdapterIcon(linkPreview: linkPreview, isIncoming: isIncoming)
            case .largeImage, .icon, .firstParty, nil:
                break
            }
        }
        if linkPreview.hasLoadedImageOrBlurHash, sentIsHero(linkPreview: linkPreview) {
            return CVLinkPreviewViewAdapterLarge(linkPreview: linkPreview, isIncoming: isIncoming)
        }
        return CVLinkPreviewViewAdapterCompact(linkPreview: linkPreview, isIncoming: isIncoming)
    }

    fileprivate static func sentIsHero(linkPreview: LinkPreviewState) -> Bool {
        if isSticker(linkPreview: linkPreview) || linkPreview.isGroupInviteLink {
            return false
        }
        guard let heroWidthPoints = linkPreview.conversationStyle?.maxMessageWidth else {
            return false
        }

        // On a 1x device, even tiny images like avatars can satisfy the max message width
        // On a 3x device, achieving a 3x pixel match on an og:image is rare
        // By fudging the required scaling a bit towards 2.0, we get more consistency at the
        // cost of slightly blurrier images on 3x devices.
        // These are totally made up numbers so feel free to adjust as necessary.
        let heroScalingFactors: [CGFloat: CGFloat] = [
            1.0: 2.0,
            2.0: 2.0,
            3.0: 2.3333,
        ]
        let scale = UITraitCollection.current.displayScale
        let scalingFactor = heroScalingFactors[scale] ?? {
            // Oh neat a new device! Might want to add it.
            owsFailDebug("Unrecognized device scale")
            return 2.0
        }()
        let minimumHeroWidth = heroWidthPoints * scalingFactor
        let minimumHeroHeight = minimumHeroWidth * 0.33

        let widthSatisfied = linkPreview.imagePixelSize.width >= minimumHeroWidth
        let heightSatisfied = linkPreview.imagePixelSize.height >= minimumHeroHeight
        return widthSatisfied && heightSatisfied
    }

    private static func isSticker(linkPreview: LinkPreviewState) -> Bool {
        guard let urlString = linkPreview.urlString else {
            owsFailDebug("Link preview is missing url.")
            return false
        }
        guard let url = URL(string: urlString) else {
            owsFailDebug("Could not parse URL.")
            return false
        }
        return StickerPackInfo.isStickerPackShare(url)
    }

    // MARK: - Highlight (card-visual §3.6 / §3.8)

    /// 按下、指针悬停时整张卡叠一层半透明的黑 / 白（和卡上的字同一个黑 / 白），不换底色；染色卡与中性卡、浅色与深色都一样。
    enum Highlight: Equatable {
        case idle
        case hover
        case pressed

        /// 叠层的不透明度：叠层本身是纯黑或纯白，透明度在这里。
        var overlayAlpha: CGFloat {
            switch self {
            case .idle: 0
            case .hover: 0.06
            case .pressed: 0.12
            }
        }
    }

    /// 按住超过这么久叠层自己退掉。会话页按住 0.2 秒会拿起整条消息（长按菜单），菜单里的预览是这张卡此刻的快照，不能带着叠层。
    static var pressedMaxDuration: TimeInterval = 0.14

    /// 叠层：纯黑或纯白的一块，透明度随 `highlight` 变。
    let highlightOverlayView = UIView()

    /// 这张卡点了会有反应吗（不响应点击的域名卡、选择模式里的卡没有按下态 / 悬停态）。
    private(set) var isHighlightInteractive = false

    private var pressTracker = CVLinkPreviewPressTracker()
    private var isHoveringPointer = false
    private var pressTimeout: DispatchWorkItem?
    private var hasHighlightLayoutBlock = false

    var highlight: Highlight {
        if pressTracker.isPressed {
            return .pressed
        }
        return isHoveringPointer ? .hover : .idle
    }

    private func installHighlight(color: UIColor, isInteractive: Bool) {
        clearHighlightState()
        highlightOverlayView.removeFromSuperview()
        for recognizer in gestureRecognizers ?? [] where recognizer is CVLinkPreviewTouchObserver || recognizer is UIHoverGestureRecognizer {
            removeGestureRecognizer(recognizer)
        }
        isHighlightInteractive = isInteractive
        highlightOverlayView.alpha = 0
        guard isInteractive else {
            return
        }
        highlightOverlayView.backgroundColor = color
        highlightOverlayView.isUserInteractionEnabled = false
        highlightOverlayView.frame = bounds
        addSubview(highlightOverlayView)
        // 叠层跟着卡片的大小走（排版块在 reset() 里清掉，所以每轮只加一次）
        if !hasHighlightLayoutBlock {
            hasHighlightLayoutBlock = true
            addLayoutBlock { [weak self] view in
                guard let self, self.highlightOverlayView.superview === view else {
                    return
                }
                self.highlightOverlayView.frame = view.bounds
            }
        }
        // 只观察触摸的手势：一按下就知道（视图自己的 touchesBegan 要等滚动视图确认不是滚动，晚 ~150 ms），又不和会话页的点击、长按、滑动抢事件。
        addGestureRecognizer(CVLinkPreviewTouchObserver(card: self))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))
    }

    private func clearHighlightState() {
        pressTimeout?.cancel()
        pressTimeout = nil
        pressTracker.end()
        isHoveringPointer = false
        highlightOverlayView.layer.removeAllAnimations()
        highlightOverlayView.alpha = 0
    }

    func pressBegan(at point: CGPoint) {
        guard isHighlightInteractive else {
            return
        }
        pressTracker.begin(at: point)
        pressTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            self?.pressTimedOut()
        }
        pressTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pressedMaxDuration, execute: timeout)
        updateHighlightOverlay()
    }

    func pressMoved(to point: CGPoint) {
        guard isHighlightInteractive else {
            return
        }
        pressTracker.move(to: point)
        updateHighlightOverlay()
    }

    func pressEnded() {
        pressTimeout?.cancel()
        pressTimeout = nil
        pressTracker.end()
        updateHighlightOverlay()
    }

    private func pressTimedOut() {
        pressTimeout = nil
        pressTracker.end()
        updateHighlightOverlay()
    }

    func setHovering(_ isHovering: Bool) {
        guard isHighlightInteractive else {
            return
        }
        isHoveringPointer = isHovering
        updateHighlightOverlay()
    }

    @objc
    private func handleHover(_ sender: UIHoverGestureRecognizer) {
        switch sender.state {
        case .began, .changed:
            setHovering(true)
        case .ended, .cancelled, .failed:
            setHovering(false)
        default:
            break
        }
    }

    private func updateHighlightOverlay() {
        let highlight = self.highlight
        let alpha = highlight.overlayAlpha
        guard highlightOverlayView.alpha != alpha else {
            return
        }
        UIView.animate(
            withDuration: highlight == .pressed ? 0.06 : 0.15,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
        ) {
            self.highlightOverlayView.alpha = alpha
        }
    }

    // MARK: Accessibility

    /// 第一方卡底部的动作按钮：一个独立的无障碍按钮元素（`CVComponentMessage` 把它和整条消息的元素并列放进容器里）；没有这个按钮是 nil。
    var accessibilityActionElement: UIView? {
        firstPartyActionLabel.superview != nil ? firstPartyActionLabel : nil
    }

    // MARK: Measurement

    static func measure(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
        linkPreview: LinkPreviewState,
    ) -> CGSize {
        // `isIncoming` doesn't matter for size measurement
        let adapter = Self.adapter(for: linkPreview, isIncoming: false)
        let size = adapter.measure(
            maxWidth: maxWidth,
            measurementBuilder: measurementBuilder,
        )
        if size.width > maxWidth {
            owsFailDebug("size.width: \(size.width) > maxWidth: \(maxWidth)")
        }
        return size
    }

    /// 测试用：每条用例都是一份新的内存库，附件 id 从头数起，上一条用例解出来的缩略图会被缓存键撞上（生产里 id 不会重复）。
    static func resetImageCacheForTests() {
        CVLinkPreviewImageView.mediaCache.clear()
    }

    override func reset() {
        super.reset()

        clearHighlightState()
        isHighlightInteractive = false
        hasHighlightLayoutBlock = false
        textStack.reset()
        textStack.removeFromSuperview()

        linkPreviewImageView.reset()
        linkPreviewImageView.removeFromSuperview()

        linkIconView.image = nil
        linkIconView.removeFromSuperview()

        firstPartyHeaderStack.reset()
        firstPartyHeaderStack.removeFromSuperview()
        firstPartyDivider.removeFromSuperview()
        firstPartyActionLabel.text = nil
        firstPartyActionLabel.accessibilityLabel = nil
        firstPartyActionLabel.accessibilityTraits = .staticText
        firstPartyActionLabel.removeFromSuperview()
        firstPartyPlaceholder.image = nil
        firstPartyPlaceholder.removeFromSuperview()
        firstPartyAvatar.reset()
        firstPartyAvatar.removeFromSuperview()
    }
}

// MARK: -

private class CVLinkPreviewViewAdapter {

    let linkPreview: LinkPreviewState
    let isIncoming: Bool

    init(linkPreview: LinkPreviewState, isIncoming: Bool) {
        self.linkPreview = linkPreview
        self.isIncoming = isIncoming
    }

    // MARK: Root Stack

    private static var measurementKey_rootStack: String { "LinkPreviewView.measurementKey_rootStack" }

    final func configureForRendering(
        linkPreviewView: CVLinkPreviewView,
        cellMeasurement: CVCellMeasurement,
    ) {
        let rootStackSubviews = rootStackSubviews(
            linkPreviewView: linkPreviewView,
            cellMeasurement: cellMeasurement,
        )
        linkPreviewView.configure(
            config: rootStackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_rootStack,
            subviews: rootStackSubviews,
        )
    }

    final func measure(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> CGSize {
        ManualStackView.measure(
            config: rootStackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_rootStack,
            subviewInfos: rootStackSubviewInfos(maxWidth: maxWidth, measurementBuilder: measurementBuilder),
            maxWidth: maxWidth,
        ).measuredSize
    }

    fileprivate static let sentNonHeroImageSize: CGFloat = 64

    // Default config is a horizontal stack designed to show a small image followed by vertical stack of text.
    //
    // Subclasses can override for different link layout.
    var rootStackConfig: ManualStackView.Config {
        ManualStackView.Config(
            axis: .horizontal,
            alignment: .top,
            spacing: 12,
            layoutMargins: UIEdgeInsets(margin: 10),
        )
    }

    // Subclasses must override to return measured size for root stack's subviews.
    func rootStackSubviewInfos(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> [ManualStackSubviewInfo] { [] }

    // Subclasses must override to return configured root stack's subviews.
    func rootStackSubviews(
        linkPreviewView: CVLinkPreviewView,
        cellMeasurement: CVCellMeasurement,
    ) -> [UIView] { [] }

    // MARK: Text stack

    private static var measurementKey_textStack: String { "LinkPreviewView.measurementKey_textStack" }

    // Default is a simple vertical text stack.
    //
    // Subclasses can override for a different text stack layout.
    var textStackConfig: ManualStackView.Config {
        ManualStackView.Config(
            axis: .vertical,
            alignment: .leading,
            spacing: 4,
            layoutMargins: .zero,
        )
    }

    // Measures total size of text stack in the link preview
    // based on measurements provided by subclasses via `textStackSubviewInfos(maxWidth:)`.
    final func measureTextStack(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> CGSize {
        let subviewInfos = textStackSubviewInfos(maxWidth: maxWidth)
        let measurement = ManualStackView.measure(
            config: textStackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_textStack,
            subviewInfos: subviewInfos,
        )
        return measurement.measuredSize
    }

    // Configures text stack using configured subviews (text labels)
    // provided by subclasses via `textStackSubviews()`.
    final func configureTextStack(
        linkPreviewView: CVLinkPreviewView,
        cellMeasurement: CVCellMeasurement,
    ) -> UIView {
        let textStack = linkPreviewView.textStack
        textStack.configure(
            config: textStackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_textStack,
            subviews: textStackSubviews(),
        )
        return textStack
    }

    // Customization point for subclasses.
    //
    // Default implementation measures for all three possible labels:
    // Title, Description, Domain name.
    func textStackSubviewInfos(maxWidth: CGFloat) -> [ManualStackSubviewInfo] {
        var subviewInfos = [ManualStackSubviewInfo]()

        if let labelConfig = sentTitleLabelConfig() {
            let labelSize = CVText.measureLabel(config: labelConfig, maxWidth: maxWidth)
            subviewInfos.append(labelSize.asManualSubviewInfo)
        }
        if let labelConfig = sentDescriptionLabelConfig() {
            let labelSize = CVText.measureLabel(config: labelConfig, maxWidth: maxWidth)
            subviewInfos.append(labelSize.asManualSubviewInfo)
        }
        let labelConfig = sentDomainLabelConfig()
        let labelSize = CVText.measureLabel(config: labelConfig, maxWidth: maxWidth)
        subviewInfos.append(labelSize.asManualSubviewInfo)

        return subviewInfos
    }

    // Customization point for subclasses.
    //
    // Default implementation returns all three possible labels:
    // Title, Description, Domain name.
    func textStackSubviews() -> [CVLabel] {
        var subviews = [CVLabel]()

        if let titleLabel = sentTitleLabel() {
            subviews.append(titleLabel)
        }
        if let descriptionLabel = sentDescriptionLabel() {
            subviews.append(descriptionLabel)
        }
        let domainLabel = sentDomainLabel()
        subviews.append(domainLabel)

        return subviews
    }

    // MARK: Text styling

    /// 染色卡的字色（card-visual §3.3：黑 / 白里对比度高的那个，rust/links 保证标题 ≥ 4.5:1）。
    private var tintTextColor: UIColor? {
        (linkPreview as? TellomiLinkPreviewCardState)?.tintColors?.text
    }

    /// 标题的颜色；无图卡的域名冒充知名域名时覆盖成危险色。
    var titleTextColor: UIColor {
        tintTextColor ?? (isIncoming ? .Signal.label : .Signal.ColorBase.labelInverted)
    }

    /// 按下态 / 悬停态叠层的颜色（card-visual §3.6）：卡上的字色，也就是和底色对比度高的那个纯黑或纯白；不随「冒充域名标红」变。
    var highlightOverlayColor: UIColor {
        tintTextColor ?? (isIncoming ? .Signal.label : .Signal.ColorBase.labelInverted)
    }

    /// 域名行、副行的颜色。
    var secondaryTextColor: UIColor {
        tintTextColor?.withAlphaComponent(0.72) ?? (isIncoming ? .Signal.secondaryLabel : .Signal.ColorBase.labelInvertedSecondary)
    }

    final func sentTitleLabel() -> CVLabel? {
        guard let config = sentTitleLabelConfig() else {
            return nil
        }
        let label = CVLabel()
        config.applyForRendering(label: label)
        return label
    }

    /// 标题后面跟的东西（官网卡的「官方」徽标）；默认没有。
    var titleAttributedSuffix: NSAttributedString? { nil }

    final func sentTitleLabelConfig() -> CVLabelConfig? {
        guard let text = linkPreview.title else {
            return nil
        }
        let font = UIFont.dynamicTypeSubheadline.semibold()
        if let suffix = titleAttributedSuffix {
            let attributed = NSMutableAttributedString(
                string: text + " ",
                attributes: [.font: font, .foregroundColor: titleTextColor],
            )
            attributed.append(suffix)
            return CVLabelConfig(
                text: .attributedText(attributed),
                displayConfig: .forUnstyledText(font: font, textColor: titleTextColor),
                font: font,
                textColor: titleTextColor,
                numberOfLines: 2,
                lineBreakMode: .byTruncatingTail,
            )
        }
        return CVLabelConfig.unstyledText(
            text,
            font: font,
            textColor: titleTextColor,
            numberOfLines: 2,
            lineBreakMode: .byTruncatingTail,
        )
    }

    final func sentDescriptionLabel() -> CVLabel? {
        guard let config = sentDescriptionLabelConfig() else {
            return nil
        }
        let label = CVLabel()
        config.applyForRendering(label: label)
        return label
    }

    final func sentDescriptionLabelConfig() -> CVLabelConfig? {
        guard let text = linkPreview.previewDescription else { return nil }
        let textColor: UIColor = secondaryTextColor
        return CVLabelConfig.unstyledText(
            text,
            font: UIFont.dynamicTypeFootnote,
            textColor: textColor,
            // Tellomi 卡片的副行 1 行，放不下截断在末尾（card-visual §3.7）；Signal 原来的预览卡（通话卡、回落）仍是 3 行。
            numberOfLines: linkPreview is TellomiLinkPreviewCardState ? 1 : 3,
            lineBreakMode: .byTruncatingTail,
        )
    }

    final func sentDomainLabel() -> CVLabel {
        let config = sentDomainLabelConfig()
        let label = CVLabel()
        config.applyForRendering(label: label)
        return label
    }

    final func sentDomainLabelConfig() -> CVLabelConfig {
        var labelText: String
        if let displayDomain = linkPreview.displayDomain?.nilIfEmpty {
            // Tellomi：卡片的域名行已经定稿（视频的发布日期就在上面），不再转小写。
            labelText = linkPreview is TellomiLinkPreviewCardState ? displayDomain : displayDomain.lowercased()
        } else {
            labelText = OWSLocalizedString(
                "LINK_PREVIEW_UNKNOWN_DOMAIN",
                comment: "Label for link previews with an unknown host.",
            ).uppercased()
        }
        if let date = linkPreview.date {
            labelText.append(" ⋅ \(CVLinkPreviewView.dateFormatter.string(from: date))")
        }
        let textColor: UIColor = secondaryTextColor
        return CVLabelConfig.unstyledText(
            labelText,
            font: UIFont.dynamicTypeCaption1,
            textColor: textColor,
            lineBreakMode: .byTruncatingTail,
        )
    }
}

// MARK: -

// Does not have domain name. Image is round.
private class CVLinkPreviewViewAdapterSignalLink: CVLinkPreviewViewAdapter {

    override func rootStackSubviewInfos(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> [ManualStackSubviewInfo] {
        var rootStackSubviewInfos = [ManualStackSubviewInfo]()

        var maxLabelWidth = (maxWidth - (
            textStackConfig.layoutMargins.totalWidth + rootStackConfig.layoutMargins.totalWidth
        ))

        if linkPreview.hasLoadedImageOrBlurHash {
            let imageSize = Self.sentNonHeroImageSize
            rootStackSubviewInfos.append(CGSize.square(imageSize).asManualSubviewInfo(hasFixedSize: true))
            maxLabelWidth -= imageSize + rootStackConfig.spacing
        }

        maxLabelWidth = max(0, maxLabelWidth)

        let textStackSize = measureTextStack(
            maxWidth: maxLabelWidth,
            measurementBuilder: measurementBuilder,
        )
        rootStackSubviewInfos.append(textStackSize.asManualSubviewInfo)

        return rootStackSubviewInfos
    }

    override func rootStackSubviews(
        linkPreviewView: CVLinkPreviewView,
        cellMeasurement: CVCellMeasurement,
    ) -> [UIView] {
        var rootStackSubviews = [UIView]()

        if linkPreview.hasLoadedImageOrBlurHash {
            let linkPreviewImageView = linkPreviewView.linkPreviewImageView
            if let imageView = linkPreviewImageView.configure(linkPreview: linkPreview, cornerStyle: .capsule) {
                imageView.clipsToBounds = true
                rootStackSubviews.append(imageView)
            } else {
                owsFailDebug("Could not load image.")
                rootStackSubviews.append(UIView.transparentSpacer())
            }
        }

        let textStack = configureTextStack(
            linkPreviewView: linkPreviewView,
            cellMeasurement: cellMeasurement,
        )
        rootStackSubviews.append(textStack)

        return rootStackSubviews
    }
}

// MARK: -

// Large full-width image with vertical text stack below.
private class CVLinkPreviewViewAdapterLarge: CVLinkPreviewViewAdapter {

    // Vertical stack.
    override var rootStackConfig: ManualStackView.Config {
        ManualStackView.Config(
            axis: .vertical,
            alignment: .fill,
            spacing: 0,
            layoutMargins: .zero,
        )
    }

    // Increased margins around text over default implementation.
    override var textStackConfig: ManualStackView.Config {
        let config = super.textStackConfig
        let insets = UIEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 4)
        return ManualStackView.Config(
            axis: config.axis,
            alignment: config.alignment,
            spacing: config.spacing,
            layoutMargins: insets,
        )
    }

    override func rootStackSubviewInfos(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> [ManualStackSubviewInfo] {
        var rootStackSubviewInfos = [ManualStackSubviewInfo]()

        let heroImageSize = sentHeroImageSize(maxWidth: maxWidth)
        rootStackSubviewInfos.append(heroImageSize.asManualSubviewInfo)

        var maxLabelWidth = (maxWidth - (
            textStackConfig.layoutMargins.totalWidth + rootStackConfig.layoutMargins.totalWidth
        ))
        maxLabelWidth = max(0, maxLabelWidth)

        let textStackSize = measureTextStack(
            maxWidth: maxLabelWidth,
            measurementBuilder: measurementBuilder,
        )
        rootStackSubviewInfos.append(textStackSize.asManualSubviewInfo)

        return rootStackSubviewInfos
    }

    override func rootStackSubviews(
        linkPreviewView: CVLinkPreviewView,
        cellMeasurement: CVCellMeasurement,
    ) -> [UIView] {
        var rootStackSubviews = [UIView]()

        let linkPreviewImageView = linkPreviewView.linkPreviewImageView
        if let imageView = linkPreviewImageView.configure(linkPreview: linkPreview, cornerStyle: .square) {
            imageView.clipsToBounds = true
            rootStackSubviews.append(imageView)
        } else {
            owsFailDebug("Could not load image.")
            rootStackSubviews.append(UIView.transparentSpacer())
        }

        let textStack = configureTextStack(
            linkPreviewView: linkPreviewView,
            cellMeasurement: cellMeasurement,
        )
        rootStackSubviews.append(textStack)

        return rootStackSubviews
    }

    private func sentHeroImageSize(maxWidth: CGFloat) -> CGSize {
        guard let conversationStyle = linkPreview.conversationStyle else {
            owsFailDebug("Missing conversationStyle.")
            return .zero
        }

        let imageHeightWidthRatio = (linkPreview.imagePixelSize.height / linkPreview.imagePixelSize.width)
        let maxMessageWidth = min(maxWidth, conversationStyle.maxMessageWidth)

        // Tellomi 卡片的图宽高比夹在 1.91:1–1:1（card-visual §3.2）；Signal 原样是 2:1–1:1。
        let minImageHeight: CGFloat = linkPreview is TellomiLinkPreviewCardState ? maxMessageWidth / 1.91 : maxMessageWidth * 0.5
        let maxImageHeight: CGFloat = maxMessageWidth
        let rawImageHeight = maxMessageWidth * imageHeightWidthRatio

        let normalizedHeight: CGFloat = min(maxImageHeight, max(minImageHeight, rawImageHeight))
        return CGSize.ceil(CGSize(width: maxMessageWidth, height: normalizedHeight))
    }
}

// MARK: -

// Tellomi（card-visual §5.2）：Tellomi 自己对象的卡片——头像或封面 56 pt + 标题 + 一行副行，下面一条细线，再是 36 pt 高的动作按钮
// （学 Telegram 展示自家对象的方式）。没有域名行。整张卡可点；按钮只是这张卡点下去会做的事。
private class CVLinkPreviewViewAdapterFirstParty: CVLinkPreviewViewAdapter {

    private static let avatarSize: CGFloat = 56
    private static let actionHeight: CGFloat = 36
    private static var measurementKey_header: String { "CVLinkPreviewViewAdapterFirstParty.measurementKey_header" }

    private var firstParty: TellomiFirstPartyCard.Display? {
        (linkPreview as? TellomiLinkPreviewCardState)?.firstParty
    }

    private var actionText: String? {
        firstParty?.action
    }

    private var dividerHeight: CGFloat { 1 / UIScreen.main.scale }

    override var rootStackConfig: ManualStackView.Config {
        ManualStackView.Config(axis: .vertical, alignment: .fill, spacing: 0, layoutMargins: .zero)
    }

    private var headerStackConfig: ManualStackView.Config {
        ManualStackView.Config(axis: .horizontal, alignment: .center, spacing: 12, layoutMargins: UIEdgeInsets(margin: 10))
    }

    override func textStackSubviewInfos(maxWidth: CGFloat) -> [ManualStackSubviewInfo] {
        var infos = [ManualStackSubviewInfo]()
        if let config = sentTitleLabelConfig() {
            infos.append(CVText.measureLabel(config: config, maxWidth: maxWidth).asManualSubviewInfo)
        }
        if let config = sentDescriptionLabelConfig() {
            infos.append(CVText.measureLabel(config: config, maxWidth: maxWidth).asManualSubviewInfo)
        }
        return infos
    }

    override func textStackSubviews() -> [CVLabel] {
        [sentTitleLabel(), sentDescriptionLabel()].compactMap { $0 }
    }

    /// 官网卡的标题后面跟一个「官方」小徽标（只有官网卡带）。
    override var titleAttributedSuffix: NSAttributedString? {
        guard firstParty?.officialBadge == true else {
            return nil
        }
        return TellomiOfficialBadge.attributedString(text: TellomiFirstPartyCard.Strings.officialBadge(), height: UIFont.dynamicTypeSubheadline.lineHeight)
    }

    override func rootStackSubviewInfos(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> [ManualStackSubviewInfo] {
        let avatarSize = CGSize.square(Self.avatarSize)
        let maxLabelWidth = max(
            0,
            maxWidth - (
                textStackConfig.layoutMargins.totalWidth + headerStackConfig.layoutMargins.totalWidth
                    + avatarSize.width + headerStackConfig.spacing
            ),
        )
        let textStackSize = measureTextStack(maxWidth: maxLabelWidth, measurementBuilder: measurementBuilder)
        let header = ManualStackView.measure(
            config: headerStackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_header,
            subviewInfos: [
                avatarSize.asManualSubviewInfo(hasFixedSize: true),
                textStackSize.asManualSubviewInfo,
            ],
            maxWidth: maxWidth,
        )
        var infos = [header.measuredSize.asManualSubviewInfo]
        if actionText != nil {
            infos.append(CGSize(width: 0, height: dividerHeight).asManualSubviewInfo(hasFixedHeight: true))
            infos.append(CGSize(width: 0, height: Self.actionHeight).asManualSubviewInfo(hasFixedHeight: true))
        }
        return infos
    }

    override func rootStackSubviews(
        linkPreviewView: CVLinkPreviewView,
        cellMeasurement: CVCellMeasurement,
    ) -> [UIView] {
        let textStack = configureTextStack(linkPreviewView: linkPreviewView, cellMeasurement: cellMeasurement)
        linkPreviewView.firstPartyHeaderStack.configure(
            config: headerStackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_header,
            subviews: [avatarView(linkPreviewView: linkPreviewView), textStack],
        )
        var subviews: [UIView] = [linkPreviewView.firstPartyHeaderStack]
        if let actionText {
            let divider = linkPreviewView.firstPartyDivider
            divider.backgroundColor = tintTextColorOrSeparator.withAlphaComponent(0.25)
            subviews.append(divider)

            let label = linkPreviewView.firstPartyActionLabel
            CVLabelConfig.unstyledText(
                actionText,
                font: UIFont.dynamicTypeSubheadline.semibold(),
                textColor: actionTextColor,
                textAlignment: .center,
            ).applyForRendering(label: label)
            // 底部动作按钮是一个独立的无障碍按钮（card-visual §3.6）：button 角色、读它上面的字；
            // 激活它等于点这张卡（整张卡可点，按钮只是点下去会做的事）。
            label.isAccessibilityElement = true
            label.accessibilityTraits = .button
            label.accessibilityLabel = actionText
            subviews.append(label)
        }
        return subviews
    }

    private var actionTextColor: UIColor {
        (linkPreview as? TellomiLinkPreviewCardState)?.tintColors?.text ?? .tellomiCardAccent
    }

    private var tintTextColorOrSeparator: UIColor {
        (linkPreview as? TellomiLinkPreviewCardState)?.tintColors?.text ?? .Signal.label
    }

    /// 头像 / 封面：群和贴纸包用消息带来的图；本机认识的用户用本地库里的头像（联系人照片 / 对方的资料头像 / 默认头像）；
    /// 不认识的用户、通话、官网和没有图时用占位。
    private func avatarView(linkPreviewView: CVLinkPreviewView) -> UIView {
        let kind = firstParty?.kind
        if kind == .user, let image = (linkPreview as? TellomiLinkPreviewCardState)?.userAvatar {
            // 本地库里的头像（只读、不联网，card-visual §5.2，ADR-0063 §4.1），数据层已经取好；
            // 头像视图拿现成的图（`.asset`），不在 cell 配置阶段开数据库事务。
            let avatar = linkPreviewView.firstPartyAvatar
            avatar.updateWithSneakyTransactionIfNecessary { config in
                config.dataSource = .asset(avatar: image, badge: nil)
            }
            return avatar
        }
        if
            kind == .group || kind == .sticker,
            linkPreview.hasLoadedImageOrBlurHash,
            let imageView = linkPreviewView.linkPreviewImageView.configure(
                linkPreview: linkPreview,
                cornerStyle: kind == .group ? .capsule : .rounded(radius: 10),
            )
        {
            imageView.clipsToBounds = true
            return imageView
        }
        let placeholder = linkPreviewView.firstPartyPlaceholder
        placeholder.contentMode = .center
        placeholder.clipsToBounds = true
        placeholder.layer.cornerRadius = kind == .sticker || kind == .official ? 12 : Self.avatarSize / 2
        switch kind {
        case .call:
            placeholder.image = UIImage(named: "video-compact")?.withRenderingMode(.alwaysTemplate)
            placeholder.tintColor = .Signal.secondaryLabel
            placeholder.backgroundColor = .Signal.secondaryFill
        case .official:
            placeholder.contentMode = .scaleAspectFill
            placeholder.image = UIImage(resource: .AppIconPreview.default)
            placeholder.backgroundColor = .clear
        case .group:
            placeholder.image = UIImage(named: "group-fill")?.withRenderingMode(.alwaysTemplate)
            placeholder.tintColor = .Signal.secondaryLabel
            placeholder.backgroundColor = .Signal.secondaryFill
        case .sticker:
            placeholder.image = UIImage(named: "sticker")?.withRenderingMode(.alwaysTemplate)
            placeholder.tintColor = .Signal.secondaryLabel
            placeholder.backgroundColor = .Signal.secondaryFill
        default:
            placeholder.image = UIImage(named: "person-resizable")?.withRenderingMode(.alwaysTemplate)
            placeholder.tintColor = .Signal.secondaryLabel
            placeholder.backgroundColor = .Signal.secondaryFill
        }
        return placeholder
    }
}

// MARK: -

private extension UIColor {
    /// 第一方卡底部按钮字的颜色（card-visual：文字对比度 ≥ 4.5:1）。
    /// 浅色：强调蓝再深一成（原色落在浅灰卡上是 4.49:1）；深色：Signal 的强调蓝落在灰色卡片上只有 1.9:1，换成浅蓝。
    static var tellomiCardAccent: UIColor {
        UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 0.84, green: 0.90, blue: 1.0, alpha: 1)
            }
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            UIColor.Signal.accent.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return UIColor(red: red * 0.9, green: green * 0.9, blue: blue * 0.9, alpha: alpha)
        }
    }

    /// 「官方」徽标的底色（card-visual §5.2：防冒充的标记，必须读得清，字和底 ≥ 4.5:1）。
    /// 底是**不透明**的，不透出下面的卡片：卡片底是半透明的（收到的消息是灰，自己发的是聊天色上盖一层白），
    /// 透出来的颜色会让字和底的对比度跟着变（自己发的官网卡上，原来的半透明底实测浅色 2.53:1 / 深色 1.75:1）。
    /// 取值 = 原来的效果落在收到的灰卡上的样子（浅 #D6DFF2 / 深 #626469），看起来和以前一样。
    static var tellomiOfficialBadgeFill: UIColor {
        UIColor.byRGBHex(light: 0xD6DFF2, dark: 0x626469)
    }

    /// 「官方」徽标的字色：浅色 #1B52C4（5.15:1；原来的 #1F5DDD 只有 4.28:1）、深色 #E3EEFF（5.06:1；原来的 #D6E6FF 是 4.69:1）；
    /// 系统的「增大对比度」打开时再深 / 再亮一档。
    static var tellomiOfficialBadgeText: UIColor {
        UIColor.byRGBHex(light: 0x1B52C4, lightHighContrast: 0x143FA0, dark: 0xE3EEFF, darkHighContrast: 0xFFFFFF)
    }
}

/// 「官方」小徽标：一个圆角小药丸，当作一个文字附件放在标题文字的最后（这样标题换行、测量都还是一段文字）。
///
/// 药丸的图不在配置卡片时画好，而是文字每次要画的时候才画（`image(forBounds:textContainer:characterIndex:)`）：那一刻的
/// `UITraitCollection.current` 是标签自己的外观（窗口的 `overrideUserInterfaceStyle`、增大对比度都算上），所以
/// - App 主题和系统外观不一样时（设置 > 外观允许）不会取成系统的那一套颜色；
/// - 卡片配好以后主题才切换，徽标跟着变，不用重新配置。
/// 提前画成图塞进 `image` 的话，取色只看配置那一刻的 `UITraitCollection.current`：系统浅色 + App 主题深色时字和底只有 1.41:1，
/// 系统深色 + App 主题浅色时 1.14:1，切主题后也不更新。把明暗两张图挂在 `UIImageAsset` 上也不行（文字附件不按外观挑变体，iOS 26.5 实测）。
private enum TellomiOfficialBadge {
    static func attributedString(text: String, height: CGFloat) -> NSAttributedString {
        NSAttributedString(attachment: Attachment(text: text))
    }

    private final class Attachment: NSTextAttachment {
        private static let padding: CGFloat = 6

        private let text: String
        private let font = UIFont.dynamicTypeCaption2.semibold()

        init(text: String) {
            self.text = text
            super.init(data: nil, ofType: nil)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let size = CGSize(width: ceil(textSize.width) + Self.padding * 2, height: ceil(font.lineHeight) + 2)
            bounds = CGRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func image(forBounds imageBounds: CGRect, textContainer: NSTextContainer?, characterIndex charIndex: Int) -> UIImage? {
            let size = bounds.size
            return UIGraphicsImageRenderer(size: size).image { _ in
                UIColor.tellomiOfficialBadgeFill.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2).fill()
                (text as NSString).draw(
                    at: CGPoint(x: Self.padding, y: (size.height - font.lineHeight) / 2),
                    withAttributes: [.font: font, .foregroundColor: UIColor.tellomiOfficialBadgeText],
                )
            }
        }
    }
}

// MARK: -

// Tellomi（card-visual §3.2，owner 2026-09-30：几何照 Telegram）：图标卡——文字在左（标题 ≤ 2 行 + 域名行），右侧方形小图贴右上角；整卡按图标主色染色。
// Telegram reference：iOS `ChatMessageAttachedContentNode.swift` 小图 54 × 54（`inlineMediaAndSize`）、距上 6（`inlineMediaEdgeInset`）、
// 右边缘与文字左边缘同一个内缩（`x = width - insets.right - size`，`insets.right` = 文字气泡内缩 10–11）、圆角 4（`ImageCorners(radius: 4.0)`），
// 文字绕开小图：`TextNodeCutout(topRight:)` 的宽 = 图宽 + `inlineMediaEdgeInset`（54 + 6），所以文字与图的水平间距是 6（card-visual §3.2：iOS 6、Android 10）；
// 卡片最矮 = 小图 + 上下各 6。这里文字整列让出小图的宽度加 6（没有做逐行绕排：Telegram 里图下方的行回到全宽）。
private class CVLinkPreviewViewAdapterIcon: CVLinkPreviewViewAdapter {

    private static let iconSize: CGFloat = 54
    private static let iconCornerRadius: CGFloat = 4
    private static let iconEdgeInset: CGFloat = 6
    /// 文字列右边缘到图的左边缘。
    private static let iconTextSpacing: CGFloat = 6

    override var rootStackConfig: ManualStackView.Config {
        // 图贴右上：离上 / 下各 6，离右 10（和文字离左一样，Telegram 左右内缩对称）；文字整体比图缩进 4，所以文字离上下是 10。
        ManualStackView.Config(
            axis: .horizontal,
            alignment: .top,
            spacing: Self.iconTextSpacing,
            layoutMargins: UIEdgeInsets(top: Self.iconEdgeInset, leading: 10, bottom: Self.iconEdgeInset, trailing: 10),
        )
    }

    override var textStackConfig: ManualStackView.Config {
        let config = super.textStackConfig
        return ManualStackView.Config(
            axis: config.axis,
            alignment: config.alignment,
            spacing: config.spacing,
            layoutMargins: UIEdgeInsets(top: 10 - Self.iconEdgeInset, leading: 0, bottom: 10 - Self.iconEdgeInset, trailing: 0),
        )
    }

    override func rootStackSubviewInfos(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> [ManualStackSubviewInfo] {
        let iconSize = CGSize.square(Self.iconSize)
        let maxLabelWidth = max(
            0,
            maxWidth - (
                textStackConfig.layoutMargins.totalWidth + rootStackConfig.layoutMargins.totalWidth
                    + iconSize.width + rootStackConfig.spacing
            ),
        )
        let textStackSize = measureTextStack(maxWidth: maxLabelWidth, measurementBuilder: measurementBuilder)
        return [
            textStackSize.asManualSubviewInfo,
            iconSize.asManualSubviewInfo(hasFixedSize: true),
        ]
    }

    override func rootStackSubviews(
        linkPreviewView: CVLinkPreviewView,
        cellMeasurement: CVCellMeasurement,
    ) -> [UIView] {
        let textStack = configureTextStack(linkPreviewView: linkPreviewView, cellMeasurement: cellMeasurement)
        let imageView: UIView
        if let configured = linkPreviewView.linkPreviewImageView.configure(linkPreview: linkPreview, cornerStyle: .rounded(radius: Self.iconCornerRadius)) {
            configured.clipsToBounds = true
            imageView = configured
        } else {
            owsFailDebug("Could not load image.")
            imageView = UIView.transparentSpacer()
        }
        return [textStack, imageView]
    }
}

// MARK: -

// Tellomi（card-visual §3.2 / §3.7）：无图卡——标题（有的话）+ 副行 + 域名行，行尾一个通用链接图标（自己画，不用 Safari 的指南针），垂直居中。
// 没有图的卡都是它：generic 无图、没有随包图标的品牌壳、支付壳、无图的位置卡……；只用 URL 画的纯链接卡是它的特例（只有域名一行，见下）。
private class CVLinkPreviewViewAdapterNoImage: CVLinkPreviewViewAdapter {

    private static let linkIconSize: CGFloat = 20

    override var rootStackConfig: ManualStackView.Config {
        ManualStackView.Config(
            axis: .horizontal,
            alignment: .center,
            spacing: 12,
            layoutMargins: UIEdgeInsets(margin: 10),
        )
    }

    override func rootStackSubviewInfos(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> [ManualStackSubviewInfo] {
        let iconSize = CGSize.square(Self.linkIconSize)
        let maxLabelWidth = max(
            0,
            maxWidth - (
                textStackConfig.layoutMargins.totalWidth + rootStackConfig.layoutMargins.totalWidth
                    + iconSize.width + rootStackConfig.spacing
            ),
        )
        let textStackSize = measureTextStack(maxWidth: maxLabelWidth, measurementBuilder: measurementBuilder)
        return [
            textStackSize.asManualSubviewInfo,
            iconSize.asManualSubviewInfo(hasFixedSize: true),
        ]
    }

    override func rootStackSubviews(
        linkPreviewView: CVLinkPreviewView,
        cellMeasurement: CVCellMeasurement,
    ) -> [UIView] {
        let textStack = configureTextStack(linkPreviewView: linkPreviewView, cellMeasurement: cellMeasurement)
        let iconView = linkPreviewView.linkIconView
        iconView.image = UIImage(named: "link")?.withRenderingMode(.alwaysTemplate)
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = secondaryTextColor
        return [textStack, iconView]
    }
}

// MARK: -

// Tellomi（card-visual §3.5 / §3.7）：只用 URL 画的无图卡——域名当标题（冒充知名域名时用危险色），行尾一个链接图标，没有别的行。
private class CVLinkPreviewViewAdapterPlainLink: CVLinkPreviewViewAdapterNoImage {

    override var titleTextColor: UIColor {
        if (linkPreview as? TellomiLinkPreviewCardState)?.isLookalike == true {
            return .Signal.red
        }
        return super.titleTextColor
    }

    override func textStackSubviewInfos(maxWidth: CGFloat) -> [ManualStackSubviewInfo] {
        guard let labelConfig = sentTitleLabelConfig() else {
            return []
        }
        return [CVText.measureLabel(config: labelConfig, maxWidth: maxWidth).asManualSubviewInfo]
    }

    override func textStackSubviews() -> [CVLabel] {
        return [sentTitleLabel()].compactMap { $0 }
    }
}

// MARK: -

// Compact thumbnail along the leading edge followed by default vertical text stack.
private class CVLinkPreviewViewAdapterCompact: CVLinkPreviewViewAdapter {

    override func rootStackSubviewInfos(
        maxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> [ManualStackSubviewInfo] {
        var rootStackSubviewInfos = [ManualStackSubviewInfo]()

        var maxLabelWidth = (maxWidth - (
            textStackConfig.layoutMargins.totalWidth + rootStackConfig.layoutMargins.totalWidth
        ))

        if linkPreview.hasLoadedImageOrBlurHash {
            let imageSize = Self.sentNonHeroImageSize
            rootStackSubviewInfos.append(CGSize.square(imageSize).asManualSubviewInfo(hasFixedSize: true))
            maxLabelWidth -= imageSize + rootStackConfig.spacing
        }

        maxLabelWidth = max(0, maxLabelWidth)

        let textStackSize = measureTextStack(
            maxWidth: maxLabelWidth,
            measurementBuilder: measurementBuilder,
        )
        rootStackSubviewInfos.append(textStackSize.asManualSubviewInfo)

        return rootStackSubviewInfos
    }

    override func rootStackSubviews(
        linkPreviewView: CVLinkPreviewView,
        cellMeasurement: CVCellMeasurement,
    ) -> [UIView] {
        var rootStackSubviews = [UIView]()

        if linkPreview.hasLoadedImageOrBlurHash {
            let linkPreviewImageView = linkPreviewView.linkPreviewImageView
            if let imageView = linkPreviewImageView.configure(linkPreview: linkPreview, cornerStyle: .rounded(radius: 6)) {
                imageView.clipsToBounds = true
                rootStackSubviews.append(imageView)
            } else {
                owsFailDebug("Could not load image.")
                rootStackSubviews.append(UIView.transparentSpacer())
            }
        }

        let textStack = configureTextStack(
            linkPreviewView: linkPreviewView,
            cellMeasurement: cellMeasurement,
        )
        rootStackSubviews.append(textStack)

        return rootStackSubviews
    }
}

// MARK: -

/// 一次按下的来龙去脉（纯逻辑，好测）：按下时开始；手指挪出 10 pt 算在拖动（滚动），这次触摸之后不再叠；抬起 / 取消结束。
struct CVLinkPreviewPressTracker {
    static let moveSlop: CGFloat = 10

    private(set) var isPressed = false
    private var start: CGPoint?

    mutating func begin(at point: CGPoint) {
        start = point
        isPressed = true
    }

    mutating func move(to point: CGPoint) {
        guard isPressed, let start else {
            return
        }
        if hypot(point.x - start.x, point.y - start.y) > Self.moveSlop {
            isPressed = false
        }
    }

    mutating func end() {
        isPressed = false
        start = nil
    }
}

/// 只观察触摸、从不「识别」的手势：触摸一按下就报给卡片（不像视图的 touchesBegan 要等滚动视图确认不是滚动），
/// 又不取消视图上的触摸、不和会话页的点击 / 长按 / 滑动抢事件（自己始终停在 `.possible`，触摸结束就 `.failed`）。
private final class CVLinkPreviewTouchObserver: UIGestureRecognizer {
    private weak var card: CVLinkPreviewView?

    init(card: CVLinkPreviewView) {
        self.card = card
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard touches.count == 1, let touch = touches.first else {
            return
        }
        // 窗口坐标：手指在屏幕上挪了多远，与卡片随列表滚动无关。
        card?.pressBegan(at: touch.location(in: nil))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else {
            return
        }
        card?.pressMoved(to: touch.location(in: nil))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        card?.pressEnded()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        card?.pressEnded()
        state = .failed
    }

    override func reset() {
        super.reset()
        card?.pressEnded()
    }
}

// MARK: -

private class CVLinkPreviewImageView: ManualLayoutViewWithLayer {

    enum CornerStyle {
        case square
        case rounded(radius: CGFloat)
        case capsule
    }

    var cornerStyle: CornerStyle = .square {
        didSet {
            updateCornerRounding()
        }
    }

    var isHero = false

    private let imageView = CVImageView()
    private let iconView = CVImageView()

    private static let configurationIdCounter = AtomicUInt(0, lock: .sharedGlobal)
    private var configurationId: UInt = 0

    init() {
        super.init(name: "LinkPreviewImageView")

        addSubviewToFillSuperviewEdges(imageView)
        addSubviewToCenterOnSuperview(iconView, size: .square(36))
        addDefaultLayoutBlock()
    }

    @available(*, unavailable, message: "use other constructor instead.")
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func addDefaultLayoutBlock() {
        addLayoutBlock { view in
            guard let view = view as? CVLinkPreviewImageView else { return }
            view.updateCornerRounding()
        }
    }

    override func reset() {
        super.reset()

        imageView.reset()
        iconView.reset()

        cornerStyle = .square
        isHero = false
        configurationId = 0
    }

    private func updateCornerRounding() {
        switch cornerStyle {
        case .square:
            layer.cornerRadius = 0

        case .rounded(let radius):
            layer.cornerRadius = radius

        case .capsule:
            layer.cornerRadius = bounds.size.smallerAxis / 2
        }
    }

    static let mediaCache = LRUCache<LinkPreviewImageCacheKey, UIImage>(
        maxSize: 2,
        shouldEvacuateInBackground: true,
    )

    func configure(linkPreview: LinkPreviewState, cornerStyle: CornerStyle) -> UIView? {
        switch linkPreview.imageState {
        case .loaded:
            break
        case let .loading(blurHash) where blurHash != nil:
            break
        case let .failed(blurHash) where blurHash != nil:
            if let icon = UIImage(named: "photo-slash-36") {
                iconView.tintColor = Theme.primaryTextColor.withAlphaComponent(0.6)
                iconView.image = icon
            }
        default:
            return nil
        }
        imageView.contentMode = .scaleAspectFill
        if imageView.superview == nil {
            addSubviewToFillSuperviewEdges(imageView)
            addSubviewToCenterOnSuperview(iconView, size: .square(36))
        }
        self.cornerStyle = cornerStyle
        isHero = CVLinkPreviewView.sentIsHero(linkPreview: linkPreview)
        let configurationId = Self.configurationIdCounter.increment()
        self.configurationId = configurationId
        // Tellomi 的大图卡（短边 ≥ 300、长边 ≥ 600，由 rust/links 定）图是铺满卡宽的，不能再按 Signal 旧的「宽 ≥ 气泡最大宽 × 2」挑档：
        // 竖图、偏窄的图达不到旧阈值，会拿 `.small`（长边 200 pt）的缩略图拉到卡宽，发糊。
        let isLargeImageCard = (linkPreview as? TellomiLinkPreviewCardState)?.layout == .largeImage
        let thumbnailQuality: AttachmentThumbnailQuality = isHero || isLargeImageCard ? .medium : .small

        if
            let cacheKey = linkPreview.imageCacheKey(thumbnailQuality: thumbnailQuality),
            let image = Self.mediaCache.get(key: cacheKey)
        {
            imageView.image = image
        } else {
            linkPreview.imageAsync(thumbnailQuality: thumbnailQuality) { [weak self] image in
                DispatchMainThreadSafe {
                    guard let self else { return }
                    guard self.configurationId == configurationId else { return }
                    self.imageView.image = image
                    if let cacheKey = linkPreview.imageCacheKey(thumbnailQuality: thumbnailQuality) {
                        Self.mediaCache.set(key: cacheKey, value: image)
                    }
                }
            }
        }
        return self
    }
}
