//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

/// Tellomi（tellomi/tellomi#1257，owner 2026-09-25）：查看器底部「本组缩略条 + k / N」，抖音式：
///
/// - 当前那张展开成方块、略大，其余是窄竖条；手指按住拖动，指到哪张就切到哪张，每换一张轻触感一次；靠近两端自动往那边滚（32 张也拖得到）。
/// - 拖动时条本身不跟着居中（否则指下的那张会被挪走），松手后才把当前那张滚到中间。
/// - 只有一张时不显示（由 MediaControlPanelView 的 showThumbnailStrip 决定）。
///
/// 替换上游只能点、不能拖的 GalleryRailView（那个仍给发送前的选图页用）。尺寸与 Android 的 AlbumScrubberView 相同。
final class MediaAlbumScrubberView: UIView {

    /// 用户点或拖选中某一张时回调（下标是本组里的位置）；程序里 `setSelected` 不回调。
    var onItemSelected: ((Int) -> Void)?

    private enum Metrics {
        static let collapsedWidth: CGFloat = 30
        static let expandedWidth: CGFloat = 44
        static let height: CGFloat = 44
        static let gap: CGFloat = 4
        static let cornerRadius: CGFloat = 6
        static let sidePadding: CGFloat = 16
        static let counterSpacing: CGFloat = 10
        static let edgeZone: CGFloat = 40
        static let maxAutoScrollPerFrame: CGFloat = 14
        static let resizeDuration: TimeInterval = 0.16
    }

    private let scrollView = UIScrollView()
    private let counterLabel = UILabel()
    private var thumbnailViews = [UIImageView]()
    private var itemIds = [Attachment.IDType]()
    private(set) var selectedIndex = -1

    private var isScrubbing = false
    private var lastTouchX: CGFloat = 0
    private var displayLink: CADisplayLink?
    private let feedback = UISelectionFeedbackGenerator()

    override init(frame: CGRect) {
        super.init(frame: frame)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        // 偏移由拖动 / 居中逻辑自己管，不让用户直接滑（滑动会和「指到哪张是哪张」冲突）
        scrollView.isScrollEnabled = false
        scrollView.clipsToBounds = false
        addSubview(scrollView)

        counterLabel.textAlignment = .center
        counterLabel.font = .systemFont(ofSize: 15)
        counterLabel.textColor = .Signal.label
        counterLabel.isAccessibilityElement = false
        addSubview(counterLabel)

        let scrubGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleScrub(_:)))
        scrubGesture.minimumPressDuration = 0
        scrubGesture.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(scrubGesture)
    }

    @available(*, unavailable, message: "use other constructor instead.")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.height + Metrics.counterSpacing + counterLabel.font.lineHeight.rounded(.up))
    }

    // MARK: - Items

    /// 换一组（或同一组里换了当前那张）。
    func setItems(_ items: [MediaGalleryItem], selected: Int, animated: Bool) {
        let ids = items.map { $0.referencedAttachment.attachment.id }
        let sameGroup = ids == itemIds
        if !sameGroup {
            itemIds = ids
            selectedIndex = -1
            thumbnailViews.forEach { $0.removeFromSuperview() }
            thumbnailViews = items.enumerated().map { index, item in
                let imageView = UIImageView()
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                imageView.layer.cornerRadius = Metrics.cornerRadius
                imageView.layer.cornerCurve = .continuous
                imageView.backgroundColor = .Signal.secondaryFill
                imageView.image = item.thumbnailImageSync()
                imageView.isAccessibilityElement = true
                imageView.accessibilityTraits = .button
                imageView.accessibilityLabel = String.nonPluralLocalizedStringWithFormat(
                    OWSLocalizedString(
                        "ACCESSIBILITY_LABEL_MEDIA_TELLOMI_ALBUM_ITEM_FORMAT",
                        comment: "Accessibility value for the current item of a horizontally scrolling album in a chat. Embeds {{ %1$@ the position of the item, %2$@ the number of items }}.",
                    ),
                    OWSFormat.formatInt(index + 1),
                    OWSFormat.formatInt(items.count),
                )
                scrollView.addSubview(imageView)
                return imageView
            }
            accessibilityElements = thumbnailViews
        }
        setSelected(selected, animated: sameGroup && animated)
    }

    /// 查看器翻页时同步（不回调、不震动）。
    func setSelected(_ index: Int, animated: Bool) {
        guard thumbnailViews.indices.contains(index) else {
            updateCounter()
            return
        }
        guard index != selectedIndex else {
            updateCounter()
            return
        }
        selectedIndex = index
        for (i, view) in thumbnailViews.enumerated() {
            view.accessibilityTraits = i == index ? [.button, .selected] : .button
        }
        updateCounter()

        let shouldAnimate = animated && !UIAccessibility.isReduceMotionEnabled
        if shouldAnimate {
            UIView.animate(withDuration: Metrics.resizeDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                self.layoutThumbnails(centerSelected: !self.isScrubbing)
            }
        } else {
            layoutThumbnails(centerSelected: !isScrubbing)
        }
    }

    private func select(_ index: Int) {
        guard index != selectedIndex, thumbnailViews.indices.contains(index) else {
            return
        }
        setSelected(index, animated: true)
        feedback.selectionChanged()
        onItemSelected?(index)
    }

    private func updateCounter() {
        guard selectedIndex >= 0, !thumbnailViews.isEmpty else {
            counterLabel.attributedText = nil
            return
        }
        let current = OWSFormat.formatInt(selectedIndex + 1)
        // 跟查看器的深 / 浅背景走（上游查看器浅色模式是白底）
        let text = NSMutableAttributedString(string: current, attributes: [.foregroundColor: UIColor.Signal.label])
        text.append(NSAttributedString(
            string: "  /  " + OWSFormat.formatInt(thumbnailViews.count),
            attributes: [.foregroundColor: UIColor.Signal.secondaryLabel],
        ))
        counterLabel.attributedText = text
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Metrics.height)
        let counterHeight = counterLabel.font.lineHeight.rounded(.up)
        counterLabel.frame = CGRect(x: 0, y: Metrics.height + Metrics.counterSpacing, width: bounds.width, height: counterHeight)
        layoutThumbnails(centerSelected: !isScrubbing)
    }

    private func layoutThumbnails(centerSelected: Bool) {
        let widths = thumbnailViews.indices.map { $0 == selectedIndex ? Metrics.expandedWidth : Metrics.collapsedWidth }
        let span = widths.reduce(0, +) + Metrics.gap * CGFloat(max(0, widths.count - 1))
        let contentWidth = max(bounds.width, span + Metrics.sidePadding * 2)
        // 放得下时整条居中
        var x = (contentWidth - span) / 2
        let isRTL = CurrentAppContext().isRTL
        for (index, view) in thumbnailViews.enumerated() {
            let width = widths[index]
            let left = isRTL ? contentWidth - x - width : x
            view.frame = CGRect(x: left, y: 0, width: width, height: Metrics.height)
            x += width + Metrics.gap
        }
        scrollView.contentSize = CGSize(width: contentWidth, height: Metrics.height)
        if centerSelected {
            centerOnSelected()
        } else {
            clampContentOffset()
        }
    }

    private func centerOnSelected() {
        guard thumbnailViews.indices.contains(selectedIndex) else {
            return
        }
        let view = thumbnailViews[selectedIndex]
        let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let target = min(max(view.frame.midX - scrollView.bounds.width / 2, 0), maxOffset)
        scrollView.contentOffset = CGPoint(x: target, y: 0)
    }

    private func clampContentOffset() {
        let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        scrollView.contentOffset.x = min(max(scrollView.contentOffset.x, 0), maxOffset)
    }

    /// 指下那一张（按条里的实际位置算，含两侧间隙）；在条外取最近的一端。
    private func index(atScrollViewX x: CGFloat) -> Int? {
        guard !thumbnailViews.isEmpty else {
            return nil
        }
        for (index, view) in thumbnailViews.enumerated() where x >= view.frame.minX - Metrics.gap / 2 && x < view.frame.maxX + Metrics.gap / 2 {
            return index
        }
        let first = thumbnailViews[0].frame
        let last = thumbnailViews[thumbnailViews.count - 1].frame
        if CurrentAppContext().isRTL {
            return x > first.maxX ? 0 : thumbnailViews.count - 1
        }
        return x < first.minX ? 0 : (x > last.maxX ? thumbnailViews.count - 1 : nil)
    }

    // MARK: - Scrubbing

    @objc
    private func handleScrub(_ gesture: UILongPressGestureRecognizer) {
        guard thumbnailViews.count > 1 else {
            return
        }
        lastTouchX = gesture.location(in: self).x
        switch gesture.state {
        case .began:
            isScrubbing = true
            feedback.prepare()
            selectUnderFinger(gesture)
            startAutoScroll()
        case .changed:
            selectUnderFinger(gesture)
        case .ended, .cancelled, .failed:
            isScrubbing = false
            stopAutoScroll()
            let shouldAnimate = !UIAccessibility.isReduceMotionEnabled
            UIView.animate(withDuration: shouldAnimate ? 0.25 : 0) {
                self.centerOnSelected()
            }
        default:
            break
        }
    }

    private func selectUnderFinger(_ gesture: UIGestureRecognizer) {
        let x = gesture.location(in: scrollView).x
        if let index = index(atScrollViewX: x) {
            select(index)
        }
    }

    private func startAutoScroll() {
        stopAutoScroll()
        let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
        // Tellomi（交互审计 A-04）：拖到边上自动滚，跟手，按需升到 120 Hz
        link.preferredFrameRateRange = TellomiFrameRate.interactive
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopAutoScroll() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc
    private func autoScrollTick() {
        guard isScrubbing else {
            stopAutoScroll()
            return
        }
        let width = bounds.width
        var speed: CGFloat = 0
        if lastTouchX < Metrics.edgeZone {
            speed = -((Metrics.edgeZone - lastTouchX) / Metrics.edgeZone) * Metrics.maxAutoScrollPerFrame
        } else if lastTouchX > width - Metrics.edgeZone {
            speed = ((lastTouchX - (width - Metrics.edgeZone)) / Metrics.edgeZone) * Metrics.maxAutoScrollPerFrame
        }
        guard abs(speed) >= 1 else {
            return
        }
        let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
        let newOffset = min(max(scrollView.contentOffset.x + speed, 0), maxOffset)
        guard newOffset != scrollView.contentOffset.x else {
            return
        }
        scrollView.contentOffset.x = newOffset
        if let index = index(atScrollViewX: lastTouchX + newOffset) {
            select(index)
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            isScrubbing = false
            stopAutoScroll()
        }
    }

    // MARK: - Testing

    var thumbnailFramesForTesting: [CGRect] {
        thumbnailViews.map { convert($0.bounds, from: $0) }
    }

    var counterTextForTesting: String? { counterLabel.attributedText?.string }

    /// 模拟手指按住在 [points]（本视图坐标）上依次划过，再松手。
    func scrubForTesting(through points: [CGPoint]) {
        guard thumbnailViews.count > 1, !points.isEmpty else {
            return
        }
        isScrubbing = true
        for point in points {
            lastTouchX = point.x
            if let index = index(atScrollViewX: point.x + scrollView.contentOffset.x) {
                select(index)
            }
        }
        isScrubbing = false
        centerOnSelected()
    }
}
