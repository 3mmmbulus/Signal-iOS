//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 回应条上放哪几个表情（tellomi/tellomi 交互审计 A-06，owner 2026-10-17「和 Telegram 还不一样」）。
///
/// Telegram 两端都是 7 个表情 + 1 个展开键。Tellomi 用户自己选的那 6 个（「回应设置」）会同步到别的设备和备份，
/// 这里**不改那一组**，只在显示时补第 7 个：
/// 1. 我这次已经回应、但不在那 6 个里的表情（不显示就没法点它撤回）；
/// 2. Signal 默认 6 个里，用户换掉的那个（按默认顺序）；
/// 3. 最近用过的表情；
/// 4. 固定候补（Telegram 默认回应里 Signal 默认没有的几个）。
enum TellomiReactionBarSlots {
    static let reactionCount = 7
    static let fallback = ["🔥", "🙏", "🎉", "👏"]

    static func make(
        saved: [String],
        selected: String?,
        signalDefaults: [String],
        recents: [String],
        fallback: [String] = fallback,
    ) -> [String] {
        var slots = saved
        let candidates = [selected].compactMap { $0 } + signalDefaults + recents + fallback
        for candidate in candidates where slots.count < reactionCount && !slots.contains(candidate) {
            slots.append(candidate)
        }
        return slots
    }
}

/// 回应条的几何（Telegram iOS `ReactionContextNode.updateLayout` / `calculateBackgroundFrame`、
/// `ReactionContextBackgroundNode.update` 的数；只取数，不搬代码）。
struct TellomiReactionBarLayout: Equatable {
    static let height: CGFloat = 46
    static let cornerRadius: CGFloat = 23
    static let maxItemSize: CGFloat = 36
    static let itemSpacing: CGFloat = 8
    static let sideInset: CGFloat = 6
    static let externalSideInset: CGFloat = 4
    /// 7 个表情 + 展开键。
    static let maxSlotCount = 8
    static let expandButtonSize: CGFloat = 30
    static let expandButtonEndInset: CGFloat = 9
    /// 「思考泡泡」尾巴：大圆圆心骑在条的下沿，小圆在大圆外侧斜下方 2 pt。
    static let largeTailCircleSize: CGFloat = 16
    static let smallTailCircleSize: CGFloat = 8
    /// 条的下沿离消息上沿。
    static let gapAboveMessage: CGFloat = 7
    /// 消息在左半边：条的右边缘 = 消息右边缘 + 22；在右半边：条的左边缘 = 消息左边缘 − 26。
    static let overhangWhenMessageOnLeft: CGFloat = 22
    static let overhangWhenMessageOnRight: CGFloat = 26
    /// 条夹进屏幕时离屏幕边（安全区内）至少 17 pt（Telegram：11 + 两头的 6）。
    static let screenEdgeInset: CGFloat = 17
    /// 底板先从锚点处这么宽的一个圆长出来，再拉到全宽。
    static let growthOriginSize: CGFloat = 46
    /// 已选中的表情缩到 0.8，背后垫一个和条目一样大的圆。
    static let selectedEmojiScale: CGFloat = 0.8
    /// 按住滑到某个表情上：放大到 2 倍，下沿比原位置低 4 pt。
    static let focusedScale: CGFloat = 2
    static let focusedBottomOffset: CGFloat = 4
    /// 原地展开成全部表情：面板最高 300（Telegram `emojiContentHeight`）。
    static let expandedPanelMaxHeight: CGFloat = 300
    /// 展开时面板上沿比收起时的条往上提 96（Telegram：46 + 54 − 4），消息接在面板下面 7 pt。
    static let expandedPanelLift: CGFloat = 96
    /// 收起：内容和玻璃 0.2 s 淡出（Telegram iOS `ReactionContextNode.animateOut`）。
    static let dismissDuration: TimeInterval = 0.2

    let itemSize: CGFloat
    let slotCount: Int
    let width: CGFloat

    /// [availableWidth]：容器宽度（去掉左右安全区）。放不下 8 格时缩小条目，保证 8 格都在。
    init(availableWidth: CGFloat, slotCount: Int = maxSlotCount) {
        let fixedWidth = Self.sideInset * 2 + Self.externalSideInset * 2 + Self.itemSpacing
        var itemSize = Self.maxItemSize
        var maxRowCount = Int(floor((availableWidth - fixedWidth) / (itemSize + Self.itemSpacing)))
        if maxRowCount < Self.maxSlotCount {
            let slots = CGFloat(Self.maxSlotCount)
            itemSize = floor((availableWidth - fixedWidth - slots * Self.itemSpacing) / slots)
            maxRowCount = Int(floor((availableWidth - fixedWidth) / (itemSize + Self.itemSpacing)))
        }
        let count = max(1, min(slotCount, maxRowCount, Self.maxSlotCount))
        let contentWidth = floor(CGFloat(count) * itemSize + CGFloat(count - 1) * Self.itemSpacing + Self.sideInset * 2)
        self.itemSize = itemSize
        self.slotCount = count
        self.width = max(Self.growthOriginSize, min(contentWidth, availableWidth - Self.sideInset * 2))
    }

    func itemFrame(at index: Int, isRTL: Bool) -> CGRect {
        let x = Self.sideInset + CGFloat(index) * (itemSize + Self.itemSpacing)
        let frame = CGRect(x: x, y: floor((Self.height - itemSize) / 2), width: itemSize, height: itemSize)
        return isRTL ? mirrored(frame) : frame
    }

    /// 展开键占最后一格。
    func expandButtonFrame(isRTL: Bool) -> CGRect {
        let size = Self.expandButtonSize
        let frame = CGRect(x: width - size - Self.expandButtonEndInset, y: floor((Self.height - size) / 2), width: size, height: size)
        return isRTL ? mirrored(frame) : frame
    }

    private func mirrored(_ frame: CGRect) -> CGRect {
        CGRect(x: width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height)
    }

    /// 消息在不在左半边（Telegram 按离哪边近定）。
    static func isMessageOnLeft(messageFrame: CGRect, containerWidth: CGFloat) -> Bool {
        messageFrame.minX < containerWidth - messageFrame.maxX
    }

    /// 尾巴两个圆在容器坐标里的位置。大圆横向贴着消息朝外的那个角，但不出条的两头。
    static func tailFrames(barFrame: CGRect, messageFrame: CGRect, containerWidth: CGFloat) -> (large: CGRect, small: CGRect) {
        let large = largeTailCircleSize
        let small = smallTailCircleSize
        let onLeft = isMessageOnLeft(messageFrame: messageFrame, containerWidth: containerWidth)
        let centerX = onLeft
            ? min(barFrame.maxX - growthOriginSize / 2, messageFrame.maxX - 4)
            : max(barFrame.minX + growthOriginSize / 2, messageFrame.minX)
        let largeFrame = CGRect(x: centerX - floor(large / 2), y: barFrame.maxY - large / 2, width: large, height: large)
        let smallX = onLeft ? largeFrame.maxX - 3 : largeFrame.minX + 3 - small
        let smallFrame = CGRect(x: smallX, y: largeFrame.maxY + 2, width: small, height: small)
        return (largeFrame, smallFrame)
    }

    /// 底板长出来的起点：一个 46 宽的圆，按条自己的对齐规则贴着消息放，再夹在条里（条坐标）。
    static func growthOriginFrame(barFrame: CGRect, messageFrame: CGRect, containerWidth: CGFloat) -> CGRect {
        let size = growthOriginSize
        let onLeft = isMessageOnLeft(messageFrame: messageFrame, containerWidth: containerWidth)
        let x = onLeft
            ? messageFrame.maxX + overhangWhenMessageOnLeft - size
            : messageFrame.minX - overhangWhenMessageOnRight
        let clampedX = min(max(x - barFrame.minX, 0), max(barFrame.width - size, 0))
        return CGRect(x: clampedX, y: 0, width: size, height: size)
    }

    /// 条目按离起点的距离错峰出现：0.01 + 距离 / 条宽 × 0.3 秒（Telegram iOS `ReactionContextNode.animateIn`，
    /// 距离量的是条目中心到起点圆的左边缘）。
    static func appearDelay(itemMidX: CGFloat, originMinX: CGFloat, barWidth: CGFloat) -> TimeInterval {
        guard barWidth > 0 else { return 0.01 }
        return 0.01 + TimeInterval(abs(itemMidX - originMinX) / barWidth) * 0.3
    }

    /// 按住滑选的命中区：比条目宽出半个间距，从条目上方 20 pt 起往下 136 pt（手指从消息上滑上来）。
    func focusArea(forItemFrame frame: CGRect) -> CGRect {
        CGRect(x: frame.minX - Self.itemSpacing / 2, y: frame.minY - 20, width: frame.width + Self.itemSpacing, height: 136)
    }

    /// 被按住滑到的那一格的变换：放大 2 倍，下沿落在原位置下沿往下 4 pt。
    func focusedTransform() -> CGAffineTransform {
        let scaledHeight = itemSize * Self.focusedScale
        let lift = (itemSize / 2 + Self.focusedBottomOffset) - scaledHeight / 2
        return CGAffineTransform(translationX: 0, y: lift).scaledBy(x: Self.focusedScale, y: Self.focusedScale)
    }
}

/// 长按消息时气泡上方的回应条（交互审计 A-06 / A-07）。照 Telegram 两端：
/// - 玻璃（iOS 26）/ 模糊（更早）胶囊，高 46、圆角 23，下面挂两个圆的「思考泡泡」尾巴；
/// - 7 个表情 + 展开键，条目 36、间距 8、两头 6，屏幕窄时条目缩小；
/// - 出现：底板从锚点处一个小圆弹出来再拉到全宽，尾巴两个圆弹出来，条目从 0.01 按离锚点的距离错峰弹到原大，
///   内容 0.15 s 淡入；收起 0.2 s 淡出。减弱动态效果时只淡入淡出。
///
/// 上游的 `MessageReactionPicker` 还给「回应设置」和通话里的回应用，那两处不动。
final class TellomiReactionBar: UIView {

    enum Slot: Equatable {
        case emoji(String)
        case expand
    }

    weak var delegate: MessageReactionPickerDelegate?

    private let emojis: [String]
    private let selectedEmoji: String?
    private let isRTL: Bool

    /// iOS 26 把条和尾巴放进同一个玻璃容器，重叠的地方合成一块（Telegram 的条和尾巴是同一层遮罩画出来的）。
    private let materialContainer: UIVisualEffectView
    private let barBackground: UIVisualEffectView
    private let largeTailCircle: UIVisualEffectView
    private let smallTailCircle: UIVisualEffectView
    /// iOS 26 以前模糊底板没有阴影就和压暗的背景糊在一起。
    private let shadowView = UIView()
    private let contentView = UIView()
    /// 底板拉宽时，条目只在已经长出来的那一段里露出来。
    private let contentMaskView = UIView()
    private var itemViews: [ItemView] = []
    private let expandButton = ExpandButton()

    /// 往下拉（还没到展开）：底板、展开键和尾巴跟着往下长这么多。
    private var pullDistance: CGFloat = 0
    /// 已经原地展开成全部表情。
    private(set) var isExpanded = false
    private var panel: TellomiReactionPanel?

    private var messageFrameInSuperview: CGRect?
    private var tailFrames: (large: CGRect, small: CGRect)?
    private var growthOrigin: CGRect?
    private var isAnimatingIn = false

    init(emojis: [String], selectedEmoji: String?, delegate: MessageReactionPickerDelegate?) {
        self.emojis = emojis
        self.selectedEmoji = selectedEmoji
        self.delegate = delegate
        self.isRTL = CurrentAppContext().isRTL

        if #available(iOS 26, *) {
            let container = UIGlassContainerEffect()
            container.spacing = 0
            materialContainer = UIVisualEffectView(effect: container)
        } else {
            materialContainer = UIVisualEffectView(effect: nil)
        }
        barBackground = UIVisualEffectView(effect: Self.material())
        largeTailCircle = UIVisualEffectView(effect: Self.material())
        smallTailCircle = UIVisualEffectView(effect: Self.material())

        super.init(frame: .zero)

        clipsToBounds = false
        materialContainer.isUserInteractionEnabled = false
        for view in [barBackground, largeTailCircle, smallTailCircle] {
            if #available(iOS 26, *) {
                // 收起时是胶囊；往下拉长、展开成面板时圆角停在 23（Telegram `min(23, h / 2)`）。
                view.cornerConfiguration = .capsule(maximumRadius: TellomiReactionBarLayout.cornerRadius)
            } else {
                view.clipsToBounds = true
                view.layer.cornerCurve = .continuous
            }
        }

        if #unavailable(iOS 26) {
            shadowView.isUserInteractionEnabled = false
            shadowView.layer.shadowColor = UIColor.black.cgColor
            shadowView.layer.shadowOpacity = 0.15
            shadowView.layer.shadowRadius = 12
            shadowView.layer.shadowOffset = CGSize(width: 0, height: 4)
            addSubview(shadowView)
        }

        addSubview(materialContainer)
        // 尾巴在条的下面：重叠那一半被条盖住，看起来是一块。
        materialContainer.contentView.addSubview(smallTailCircle)
        materialContainer.contentView.addSubview(largeTailCircle)
        materialContainer.contentView.addSubview(barBackground)

        addSubview(contentView)
        contentMaskView.backgroundColor = .black
        contentMaskView.layer.cornerRadius = TellomiReactionBarLayout.cornerRadius
        contentMaskView.layer.cornerCurve = .continuous

        for (index, emoji) in emojis.enumerated() {
            let itemView = ItemView(emoji: emoji, isSelected: emoji == selectedEmoji)
            itemView.addAction(
                UIAction { [weak self] _ in
                    guard let self, let delegate = self.delegate else { return }
                    ImpactHapticFeedback.impactOccurred(style: .light)
                    delegate.didSelectReaction(reaction: emoji, isRemoving: emoji == self.selectedEmoji, inPosition: index)
                },
                for: .primaryActionTriggered,
            )
            itemViews.append(itemView)
            contentView.addSubview(itemView)
        }

        expandButton.addAction(
            UIAction { [weak self] _ in self?.delegate?.didSelectShowFullEmojiPicker() },
            for: .primaryActionTriggered,
        )
        contentView.addSubview(expandButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func material() -> UIVisualEffect {
        if #available(iOS 26, *) {
            return UIGlassEffect(style: .regular)
        }
        return UIBlurEffect(style: .systemMaterial)
    }

    // MARK: - Layout

    private var availableWidth: CGFloat {
        guard let superview else { return UIScreen.main.bounds.width }
        return superview.bounds.width - superview.safeAreaInsets.left - superview.safeAreaInsets.right
    }

    private var barLayout: TellomiReactionBarLayout {
        TellomiReactionBarLayout(availableWidth: availableWidth, slotCount: emojis.count + 1)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: barLayout.width, height: isExpanded ? bounds.height : TellomiReactionBarLayout.height)
    }

    // MARK: - 往下拉 / 原地展开（交互审计 A-06）

    func setPullDistance(_ distance: CGFloat) {
        pullDistance = distance
        setNeedsLayout()
    }

    /// 宿主开始把条展开成面板：面板先透明地铺进来，尺寸由宿主的布局在弹簧里带着走。
    func prepareExpansion(panel: TellomiReactionPanel) {
        guard !isExpanded else { return }
        isExpanded = true
        isAnimatingIn = false
        contentView.mask = nil
        focusedSlot = nil
        pullDistance = 0
        panel.alpha = 0
        panel.frame = bounds
        addSubview(panel)
        self.panel = panel
        panel.layoutIfNeeded()
    }

    /// 展开的淡入淡出：7 个表情 0.15 s 淡出，尾巴缩回去，面板内容 0.1 s 后 0.2 s 淡入。
    func playExpansionFades() {
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseIn, .beginFromCurrentState]) {
            self.contentView.alpha = 0
            self.largeTailCircle.transform = .scale(0.01)
            self.smallTailCircle.transform = .scale(0.01)
        } completion: { _ in
            self.contentView.isHidden = true
            self.largeTailCircle.isHidden = true
            self.smallTailCircle.isHidden = true
        }
        UIView.animate(withDuration: 0.2, delay: 0.1, options: [.curveEaseOut, .allowUserInteraction]) {
            self.panel?.alpha = 1
        }
    }

    /// 消息（预览）在父视图里的位置变了：重算尾巴和底板长出来的起点。
    func updateAnchor(messageFrameInSuperview: CGRect) {
        self.messageFrameInSuperview = messageFrameInSuperview
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let layout = barLayout
        // 收起时的条（46 高）；往下拉时底板往下长，展开后底板就是整个面板。
        let collapsedBounds = CGRect(x: 0, y: 0, width: bounds.width, height: TellomiReactionBarLayout.height)
        let backgroundRect = isExpanded ? bounds : CGRect(x: 0, y: 0, width: bounds.width, height: TellomiReactionBarLayout.height + pullDistance)
        contentView.frame = collapsedBounds
        panel?.frame = bounds
        // 尾巴最低到条下沿往下 18 pt；四周多留一点给玻璃的高光。
        materialContainer.frame = backgroundRect.inset(by: UIEdgeInsets(top: -10, left: -10, bottom: -28, right: -10))
        let containerOffset = materialContainer.frame.origin

        if !isAnimatingIn {
            barBackground.bounds = CGRect(origin: .zero, size: backgroundRect.size)
            barBackground.center = CGPoint(x: backgroundRect.midX - containerOffset.x, y: backgroundRect.midY - containerOffset.y)
        }
        if #unavailable(iOS 26) {
            barBackground.layer.cornerRadius = TellomiReactionBarLayout.cornerRadius
            shadowView.frame = backgroundRect
            shadowView.layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: backgroundRect.size), cornerRadius: TellomiReactionBarLayout.cornerRadius).cgPath
        }

        if !isExpanded, let superview, let messageFrame = messageFrameInSuperview {
            let barFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: TellomiReactionBarLayout.height)
            let tail = TellomiReactionBarLayout.tailFrames(barFrame: barFrame, messageFrame: messageFrame, containerWidth: superview.bounds.width)
            tailFrames = (tail.large.offsetBy(dx: -frame.minX, dy: -frame.minY), tail.small.offsetBy(dx: -frame.minX, dy: -frame.minY))
            growthOrigin = TellomiReactionBarLayout.growthOriginFrame(barFrame: barFrame, messageFrame: messageFrame, containerWidth: superview.bounds.width)
        }
        let restingTail = tailFrames ?? Self.defaultTail(bounds: collapsedBounds, isRTL: isRTL)
        // 尾巴挂在底板下沿：往下拉时跟着往下走。
        let tail = (restingTail.large.offsetBy(dx: 0, dy: pullDistance), restingTail.small.offsetBy(dx: 0, dy: pullDistance))
        for (circle, frame) in [(largeTailCircle, tail.0), (smallTailCircle, tail.1)] {
            circle.bounds = CGRect(origin: .zero, size: frame.size)
            circle.center = CGPoint(x: frame.midX - containerOffset.x, y: frame.midY - containerOffset.y)
            if #unavailable(iOS 26) {
                circle.layer.cornerRadius = frame.width / 2
            }
        }

        for (index, itemView) in itemViews.enumerated() where index < layout.slotCount - 1 {
            itemView.bounds = CGRect(origin: .zero, size: CGSize(square: layout.itemSize))
            let frame = layout.itemFrame(at: index, isRTL: isRTL)
            itemView.center = CGPoint(x: frame.midX, y: frame.midY)
        }
        for (index, itemView) in itemViews.enumerated() {
            itemView.isHidden = index >= layout.slotCount - 1
        }
        // 往下拉时展开键拉长成竖着的胶囊（Telegram：高 = 30 + 拉的距离）。
        var expandFrame = layout.expandButtonFrame(isRTL: isRTL)
        expandFrame.size.height += isExpanded ? 0 : pullDistance
        expandButton.bounds = CGRect(origin: .zero, size: expandFrame.size)
        expandButton.center = CGPoint(x: expandFrame.midX, y: expandFrame.midY)
    }

    /// 还不知道消息在哪（没收到 `updateAnchor`）时，尾巴挂在条靠消息那一头。
    private static func defaultTail(bounds: CGRect, isRTL: Bool) -> (large: CGRect, small: CGRect) {
        let fakeMessage = CGRect(x: isRTL ? bounds.maxX : bounds.minX, y: bounds.maxY + TellomiReactionBarLayout.gapAboveMessage, width: 0, height: 0)
        let tail = TellomiReactionBarLayout.tailFrames(barFrame: bounds, messageFrame: fakeMessage, containerWidth: bounds.width * 3)
        return tail
    }

    // MARK: - Presentation

    func playPresentationAnimation() {
        layoutIfNeeded()

        let materials: [UIVisualEffectView] = [barBackground, largeTailCircle, smallTailCircle]
        materials.forEach { $0.effect = nil }
        contentView.alpha = 0
        shadowView.alpha = 0

        // 玻璃不能动 alpha（会画错、到 1 时跳一下），只动 effect。
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            materials.forEach { $0.effect = Self.material() }
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.contentView.alpha = 1
        }
        UIView.animate(withDuration: 0.2, delay: 0.3, options: [.curveEaseOut, .allowUserInteraction]) {
            self.shadowView.alpha = 1
        }

        guard !TellomiMotion.isReduceMotionEnabled else { return }

        isAnimatingIn = true
        let layout = barLayout
        let origin = growthOrigin ?? CGRect(x: 0, y: 0, width: TellomiReactionBarLayout.growthOriginSize, height: TellomiReactionBarLayout.growthOriginSize)
        let finalBounds = barBackground.bounds
        let finalCenter = barBackground.center
        let containerOffset = materialContainer.frame.origin

        // 底板：先在锚点处从一个点弹成小圆（0.3 s），0.11 s 后拉到全宽（阻尼 104、0.5 s）。
        barBackground.bounds = CGRect(origin: .zero, size: origin.size)
        barBackground.center = CGPoint(x: origin.midX - containerOffset.x, y: origin.midY - containerOffset.y)
        barBackground.transform = .scale(0.01)
        contentMaskView.frame = origin
        contentView.mask = contentMaskView

        animate(TellomiMotion.reactionBarScaleIn) {
            self.barBackground.transform = .identity
        }
        animate(TellomiMotion.reactionBarWiden, delay: 0.11, animations: {
            self.barBackground.bounds = finalBounds
            self.barBackground.center = finalCenter
            self.contentMaskView.frame = self.bounds
        }, completion: {
            self.isAnimatingIn = false
            self.contentView.mask = nil
            self.setNeedsLayout()
        })

        // 尾巴两个圆和条同时弹出来。
        for circle in [smallTailCircle, largeTailCircle] {
            circle.transform = .scale(0.01)
            animate(TellomiMotion.reactionItemAppear) { circle.transform = .identity }
        }

        // 条目和展开键按离起点的距离错峰弹出来。
        var appearingViews: [UIView] = itemViews.enumerated().compactMap { index, view in
            index < layout.slotCount - 1 ? view : nil
        }
        appearingViews.append(expandButton)
        for view in appearingViews {
            let delay = TellomiReactionBarLayout.appearDelay(itemMidX: view.center.x, originMinX: origin.minX, barWidth: bounds.width)
            view.transform = .scale(0.01)
            animate(TellomiMotion.reactionItemAppear, delay: delay) { view.transform = .identity }
        }
    }

    func playDismissalAnimation(duration: TimeInterval, completion: @escaping () -> Void) {
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState]) {
            [self.barBackground, self.largeTailCircle, self.smallTailCircle].forEach { $0.effect = nil }
            self.contentView.alpha = 0
            self.panel?.alpha = 0
            self.shadowView.alpha = 0
        } completion: { _ in
            completion()
        }
    }

    private func animate(
        _ spring: TellomiMotion.FixedDurationSpring,
        delay: TimeInterval = 0,
        animations: @escaping () -> Void,
        completion: (() -> Void)? = nil,
    ) {
        let animator = UIViewPropertyAnimator(duration: spring.duration, timingParameters: spring.timingParameters())
        animator.isUserInteractionEnabled = true
        animator.addAnimations(animations)
        if let completion {
            animator.addCompletion { _ in completion() }
        }
        animator.startAnimation(afterDelay: delay)
    }

    // MARK: - Selection

    func currentEmojiSet() -> [String] {
        emojis
    }

    /// 给「回应飞入」：返回选中表情在窗口里的位置和字号，并把条上这一个藏起来，由飞的那个接着走。
    func takeEmojiForFlyIn(at position: Int) -> ReactionFlyIn.Source? {
        guard itemViews.indices.contains(position), let window = itemViews[position].window else { return nil }
        let itemView = itemViews[position]
        let frameInWindow = itemView.convert(itemView.bounds, to: window)
        itemView.hideEmojiForFlyIn()
        return ReactionFlyIn.Source(frameInWindow: frameInWindow, fontSize: itemView.visibleFontSize)
    }

    private(set) var focusedSlot: Slot?

    func updateFocusPosition(_ position: CGPoint, animated: Bool) {
        let layout = barLayout
        let previous = focusedSlot
        var focused: Slot?

        for (index, emoji) in emojis.enumerated() where index < layout.slotCount - 1 {
            if layout.focusArea(forItemFrame: layout.itemFrame(at: index, isRTL: isRTL)).contains(position) {
                focused = .emoji(emoji)
                break
            }
        }
        if focused == nil, layout.focusArea(forItemFrame: layout.expandButtonFrame(isRTL: isRTL)).contains(position) {
            focused = .expand
        }

        guard focused != previous else { return }
        focusedSlot = focused
        SelectionHapticFeedback().selectionChanged()

        let previousView = previous.flatMap(view(for:))
        let focusedView = focused.flatMap(view(for:))
        if let focusedView {
            contentView.bringSubviewToFront(focusedView)
        }
        UIView.animate(withDuration: animated ? 0.15 : 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            previousView?.transform = .identity
            focusedView?.transform = focused == .expand ? .identity : layout.focusedTransform()
        }
    }

    private func view(for slot: Slot) -> UIView? {
        switch slot {
        case .expand:
            return expandButton
        case .emoji(let emoji):
            return emojis.firstIndex(of: emoji).map { itemViews[$0] }
        }
    }

    // MARK: - Views

    private final class ItemView: UIControl {
        private let label = UILabel()
        private let selectionCircle = UIView()
        private let isSelectedReaction: Bool

        init(emoji: String, isSelected: Bool) {
            self.isSelectedReaction = isSelected
            super.init(frame: .zero)

            if isSelected {
                selectionCircle.backgroundColor = .Signal.secondaryFill
                selectionCircle.isUserInteractionEnabled = false
                addSubview(selectionCircle)
            }
            label.text = emoji
            label.textAlignment = .center
            label.isUserInteractionEnabled = false
            addSubview(label)

            isAccessibilityElement = true
            accessibilityLabel = emoji
            accessibilityTraits = isSelected ? [.button, .selected] : .button
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// 条目 36 pt 时字号 28：表情字形比字号略大，正好占满条目。
        private var fontSize: CGFloat { floor(bounds.width * 0.78) }

        var visibleFontSize: CGFloat {
            fontSize * (isSelectedReaction ? TellomiReactionBarLayout.selectedEmojiScale : 1)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            selectionCircle.frame = bounds
            selectionCircle.layer.cornerRadius = bounds.width / 2
            if label.font.pointSize != fontSize {
                label.font = .systemFont(ofSize: fontSize)
            }
            label.transform = .identity
            label.frame = bounds
            if isSelectedReaction {
                label.transform = .scale(TellomiReactionBarLayout.selectedEmojiScale)
            }
        }

        override var isHighlighted: Bool {
            didSet { label.alpha = isHighlighted ? 0.7 : 1 }
        }

        // 用 isHidden 而不是 alpha，免得高亮状态变化又把它显示出来。
        func hideEmojiForFlyIn() {
            label.isHidden = true
        }
    }

    /// 最后一格：圆底上一个向下的箭头，点开全部表情。
    private final class ExpandButton: UIControl {
        private let circle = UIView()
        private let arrow = UIImageView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            circle.backgroundColor = .Signal.secondaryFill
            circle.isUserInteractionEnabled = false
            addSubview(circle)

            let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            arrow.image = UIImage(systemName: "chevron.down", withConfiguration: configuration)
            arrow.tintColor = .Signal.secondaryLabel
            arrow.contentMode = .center
            arrow.isUserInteractionEnabled = false
            addSubview(arrow)

            isAccessibilityElement = true
            // 借用通话「更多」按钮的读屏文字，各语言都已有翻译。
            accessibilityLabel = OWSLocalizedString("CALL_VIEW_MORE_LABEL", comment: "Accessibility label for the More button in the Call Controls row.")
            accessibilityTraits = .button
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            circle.frame = bounds
            circle.layer.cornerRadius = bounds.width / 2
            arrow.frame = bounds.offsetBy(dx: 0, dy: 1)
        }

        override var isHighlighted: Bool {
            didSet { alpha = isHighlighted ? 0.7 : 1 }
        }

        /// 命中区放大 20 pt（Telegram 展开键同样）。
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.insetBy(dx: -10, dy: -10).contains(point)
        }
    }
}
