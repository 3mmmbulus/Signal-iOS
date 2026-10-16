//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

// Tellomi（交互审计 A-08，iOS 半边）：跳到某条消息（点引用、@ 提及、聊天内搜索、置顶等）。
// - 滚过去：一屏以内直接滑过去；远的先瞬移到离目标一屏的地方，再滑完最后一屏。滑用 `TellomiMotion.scroll`（临界阻尼、不回弹），
//   手指一碰就停；减弱动态效果时直接定位。原来是系统固定时长的长途滚。
// - 高亮：淡入 0.2 s、停 0.7 s、ease-out 淡出 0.3 s（停留和淡出照 Telegram）；没有气泡的（贴纸、大表情）整条压暗一下，原来什么都没有。
// - 滚到底按钮记住来处：点引用跳上去以后，按钮第一下回到引用它的那条，再按才到底；手指滚过来处就不记了（同 Telegram iOS 的
//   `ChatHistoryNavigationStack`）。
// - 从搜索结果 / 通知 / 媒体「在聊天中显示」新开聊天：目标消息放在中间并高亮，原来贴在顶上、不高亮。

/// 跳转的滚动怎么走。
enum TellomiJumpScroll {

    /// 远的先瞬移到离目标一屏的地方（从哪边来就停在哪边）；一屏以内不瞬移，返回 nil。
    static func prepositionY(currentY: CGFloat, targetY: CGFloat, viewportHeight: CGFloat) -> CGFloat? {
        let distance = targetY - currentY
        guard viewportHeight > 0, abs(distance) > viewportHeight else {
            return nil
        }
        return distance > 0 ? targetY - viewportHeight : targetY + viewportHeight
    }

    /// 不回弹的弹簧（临界阻尼）走到第 `elapsed` 秒时走完的比例：1 − (1 + ωt)·e^(−ωt)，ω = 2π / 感知时长，
    /// 和 `TellomiMotion.timingParameters` 是同一条曲线。
    static func progress(elapsed: TimeInterval, spring: TellomiMotion.Spring = TellomiMotion.scroll) -> CGFloat {
        guard elapsed > 0 else {
            return 0
        }
        let omega = 2 * Double.pi / spring.duration
        let x = omega * elapsed
        return CGFloat(min(1, 1 - (1 + x) * exp(-x)))
    }

    /// 离终点不到这么多就直接落到终点。
    static let settleDistance: CGFloat = 0.5
    /// 保险：最多滑这么久（弹簧 0.45 s，走到不到 0.5 pt 约 0.7 s）。
    static let maxDuration: TimeInterval = 1.5
}

/// 逐帧设滚动偏移的弹簧动画：每一帧列表都按当时的位置排版（不像整段 UIView 动画那样中间露白），手指一碰就停。
@MainActor
final class TellomiJumpScrollAnimator {
    private weak var scrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var startY: CGFloat = 0
    private var targetY: CGFloat = 0
    private var startTime: CFTimeInterval?
    private var completion: ((_ finished: Bool) -> Void)?

    var isAnimating: Bool { displayLink != nil }

    func animate(_ scrollView: UIScrollView, toY targetY: CGFloat, completion: @escaping (_ finished: Bool) -> Void) {
        cancel()
        self.scrollView = scrollView
        self.startY = scrollView.contentOffset.y
        self.targetY = targetY
        self.startTime = nil
        self.completion = completion
        let link = CADisplayLink(target: TellomiJumpScrollDisplayLinkProxy(owner: self), selector: #selector(TellomiJumpScrollDisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = TellomiFrameRate.interactive
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// 又要跳到别处：停在当前位置，不回调（新的一次会接着管）。
    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        completion = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let scrollView else {
            finish(finished: false)
            return
        }
        if scrollView.isTracking {
            // 手指碰到列表：停在这里，交给手指
            finish(finished: false)
            return
        }
        let startTime = self.startTime ?? link.timestamp
        self.startTime = startTime
        let elapsed = link.targetTimestamp - startTime
        let minY = -scrollView.adjustedContentInset.top
        let maxY = max(minY, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        let target = targetY.clamp(minY, maxY)
        let y = startY + (target - startY) * TellomiJumpScroll.progress(elapsed: elapsed)
        if abs(target - y) < TellomiJumpScroll.settleDistance || elapsed >= TellomiJumpScroll.maxDuration {
            scrollView.contentOffset.y = target
            finish(finished: true)
        } else {
            scrollView.contentOffset.y = y
        }
    }

    private func finish(finished: Bool) {
        let completion = self.completion
        displayLink?.invalidate()
        displayLink = nil
        self.completion = nil
        completion?(finished)
    }
}

/// CADisplayLink 会强引用 target：中间隔一层弱引用。
private final class TellomiJumpScrollDisplayLinkProxy: NSObject {
    weak var owner: TellomiJumpScrollAnimator?

    init(owner: TellomiJumpScrollAnimator) {
        self.owner = owner
    }

    @objc
    func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.tick(link)
        }
    }
}

/// 滚到底按钮记住的来处（后进先出，同 Telegram iOS `ChatHistoryNavigationStack`）。
struct TellomiJumpBackStack {
    struct Entry: Equatable {
        let interactionId: String
        let sortId: UInt64
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    mutating func push(_ entry: Entry) {
        entries.removeAll { $0.interactionId == entry.interactionId }
        entries.append(entry)
    }

    mutating func popLast() -> Entry? {
        entries.popLast()
    }

    /// 已经滚到（或滚过）的来处不再记：屏幕上看得见的最下面那条是 `maxVisibleSortId`，比它早的都去掉。
    mutating func removeEntries(upTo maxVisibleSortId: UInt64) {
        entries.removeAll { $0.sortId <= maxVisibleSortId }
    }
}

/// 点引用时记下的来处，跳完了才放进 `TellomiJumpBackStack`（跳完来处还在屏幕上就不放）。
struct TellomiPendingJumpSource {
    /// 点了引用以后这么久还没开始跳（原消息找不到、被删了），就不算了。
    static let lifetime: TimeInterval = 3

    let entry: TellomiJumpBackStack.Entry
    let date: Date

    func isValid(now: Date = Date()) -> Bool {
        now.timeIntervalSince(date) < Self.lifetime
    }
}

/// 跳过去以后的高亮。
enum TellomiJumpHighlight {
    static let animationKey = "tellomiJumpHighlight"
    static let fadeInDuration: CFTimeInterval = TellomiMotion.fadeInDuration
    static let holdDuration: CFTimeInterval = 0.7
    static let fadeOutDuration: CFTimeInterval = 0.3
    static var totalDuration: CFTimeInterval { fadeInDuration + holdDuration + fadeOutDuration }
    /// 没有气泡的消息（贴纸、大表情）压暗到这个透明度。
    static let contentDimmedOpacity: Float = 0.55

    /// 气泡上那层遮罩的透明度：0 → 1（ease-out 淡入）→ 停 → 0（ease-out 淡出）。
    static func dimmerAnimation() -> CAKeyframeAnimation {
        keyframes(values: [0, 1, 1, 0])
    }

    /// 没有气泡的：整条内容 1 → 压暗 → 停 → 1。
    static func contentDimAnimation() -> CAKeyframeAnimation {
        keyframes(values: [1, contentDimmedOpacity, contentDimmedOpacity, 1])
    }

    private static func keyframes(values: [Float]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: #keyPath(CALayer.opacity))
        animation.values = values
        let total = totalDuration
        animation.keyTimes = [0, fadeInDuration / total, (fadeInDuration + holdDuration) / total, 1].map { NSNumber(value: $0) }
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeOut),
        ]
        animation.duration = total
        return animation
    }
}

extension CVDimmableView {

    /// Tellomi（交互审计 A-08）：气泡上盖一层遮罩，按 `TellomiJumpHighlight` 淡入、停、淡出，播完拿掉（遮罩的位置同上游
    /// `performDimmingAnimation`：不盖内容时放在背景层上面）。
    func tellomiPerformJumpHighlight() {
        let sublayers = layer.sublayers ?? []
        let index: UInt32
        if !dimsContent, let backgroundLayer, let backgroundIndex = sublayers.firstIndex(of: backgroundLayer) {
            index = UInt32(backgroundIndex) + 1
        } else {
            index = UInt32(sublayers.count)
        }
        let dimmerLayer = CALayer()
        dimmerLayer.opacity = 0
        dimmerLayer.backgroundColor = dimmerColor.resolvedColor(with: traitCollection).cgColor
        dimmerLayer.frame = layer.bounds
        layer.insertSublayer(dimmerLayer, at: index)

        let animation = TellomiJumpHighlight.dimmerAnimation()
        animation.delegate = TellomiRemoveLayerWhenAnimationStops(layer: dimmerLayer)
        dimmerLayer.add(animation, forKey: TellomiJumpHighlight.animationKey)
    }
}

private final class TellomiRemoveLayerWhenAnimationStops: NSObject, CAAnimationDelegate {
    private weak var layer: CALayer?

    init(layer: CALayer) {
        self.layer = layer
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        layer?.removeFromSuperlayer()
    }
}

// MARK: - 会话页

extension ConversationViewController {

    private var tellomiJumpScrollAnimator: TellomiJumpScrollAnimator {
        if let animator = viewState.tellomiJumpScrollAnimator {
            return animator
        }
        let animator = TellomiJumpScrollAnimator()
        viewState.tellomiJumpScrollAnimator = animator
        return animator
    }

    /// 替代 `setContentOffset(_:animated:)`：跳到一条消息时怎么滚过去。滚完（或手指接管）照旧走 `scrollingAnimationDidComplete`
    /// （高亮、读屏焦点、接着加载），并把点引用时记下的来处交给滚到底按钮。
    func tellomiJumpScroll(toY targetY: CGFloat, animated: Bool, jumpSource: TellomiJumpBackStack.Entry?) {
        let animator = tellomiJumpScrollAnimator
        animator.cancel()

        guard animated else {
            collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            tellomiRememberJumpSource(jumpSource)
            return
        }
        guard !TellomiMotion.isReduceMotionEnabled else {
            // 减弱动态效果：直接定位，高亮照常
            collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
            tellomiRememberJumpSource(jumpSource)
            DispatchQueue.main.async { [weak self] in
                self?.scrollingAnimationDidComplete()
            }
            return
        }

        let viewportHeight = collectionView.bounds.height - collectionView.adjustedContentInset.top - collectionView.adjustedContentInset.bottom
        if let y = TellomiJumpScroll.prepositionY(currentY: collectionView.contentOffset.y, targetY: targetY, viewportHeight: viewportHeight) {
            collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            collectionView.layoutIfNeeded()
        }

        scrollingAnimationDidStart()
        animator.animate(collectionView, toY: targetY) { [weak self] finished in
            guard let self else {
                return
            }
            if !finished {
                // 手指接管了：停在半路，不高亮
                self.viewState.highlightedMessageId = nil
            }
            self.updateLastKnownDistanceFromBottom()
            self.tellomiRememberJumpSource(jumpSource)
            self.scrollingAnimationDidComplete()
        }
    }

    /// 取出点引用时记下的来处（只用一次；点完太久没跳就不算）。
    func tellomiTakePendingJumpSource() -> TellomiJumpBackStack.Entry? {
        defer { viewState.tellomiPendingJumpSource = nil }
        guard let pending = viewState.tellomiPendingJumpSource, pending.isValid() else {
            return nil
        }
        return pending.entry
    }

    /// 跳完了：来处在屏幕下面（看不见）才记，滚到底按钮第一下回到这里。
    private func tellomiRememberJumpSource(_ source: TellomiJumpBackStack.Entry?) {
        guard let source else {
            return
        }
        if let maxVisibleSortId = tellomiMaxVisibleSortId(), source.sortId <= maxVisibleSortId {
            return
        }
        viewState.tellomiJumpBackStack.push(source)
    }

    /// 手指滚到（或滚过）来处，就不记了。跳转动画进行中不算（还没停下来）。
    func tellomiFilterJumpBackStack() {
        guard
            !viewState.tellomiJumpBackStack.isEmpty,
            !(viewState.tellomiJumpScrollAnimator?.isAnimating ?? false),
            let maxVisibleSortId = tellomiMaxVisibleSortId()
        else {
            return
        }
        viewState.tellomiJumpBackStack.removeEntries(upTo: maxVisibleSortId)
    }

    /// 滚到底按钮：有记着的来处就先回到那里（高亮），返回 true；没有就照旧滚到底。
    func tellomiJumpBackIfPossible() -> Bool {
        tellomiFilterJumpBackStack()
        while let entry = viewState.tellomiJumpBackStack.popLast() {
            let exists = SSKEnvironment.shared.databaseStorageRef.read { tx in
                TSInteraction.fetchViaCache(uniqueId: entry.interactionId, transaction: tx) != nil
            }
            guard exists else {
                // 来处那条被删了：跳过，看下一个
                continue
            }
            ensureInteractionLoadedThenScrollToInteraction(entry.interactionId, alignment: .centerIfNotEntirelyOnScreen, isAnimated: true)
            return true
        }
        return false
    }

    /// 可见区（不算被顶栏 / 底栏盖住的部分）里最下面那条消息的 sortId。日期、未读线这些不算。
    private func tellomiMaxVisibleSortId() -> UInt64? {
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        var maxSortId: UInt64?
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard
                let frame = layout.layoutAttributesForItem(at: indexPath)?.frame,
                frame.maxY > visibleTop,
                frame.minY < visibleBottom,
                let renderItem = renderItems[safe: indexPath.row],
                renderItem.interaction is TSMessage
            else {
                continue
            }
            maxSortId = max(maxSortId ?? 0, renderItem.interaction.sortId)
        }
        return maxSortId
    }

    // MARK: 新开聊天时定位到的那条

    /// 从搜索结果 / 通知 / 媒体「在聊天中显示」新开聊天：第一次能看见那条消息时高亮一下（只一次）。
    func tellomiHighlightInitialFocusMessageIfNeeded() {
        guard
            !viewState.tellomiDidHighlightInitialFocus,
            let focusMessageId = initialScrollState?.focusMessageId,
            indexPath(forInteractionUniqueId: focusMessageId) != nil
        else {
            return
        }
        viewState.tellomiDidHighlightInitialFocus = true
        viewState.highlightedMessageId = focusMessageId
        // 等这一轮排版落定、cell 上屏
        DispatchQueue.main.async { [weak self] in
            self?.performMessageHighlightAnimationIfNeeded()
        }
    }
}

// MARK: - 点引用

extension ConversationViewController {

    public func tellomiWillJumpFromQuotedReply(inInteractionId interactionId: String) {
        guard
            let indexPath = indexPath(forInteractionUniqueId: interactionId),
            let renderItem = renderItems[safe: indexPath.row]
        else {
            viewState.tellomiPendingJumpSource = nil
            return
        }
        viewState.tellomiPendingJumpSource = TellomiPendingJumpSource(
            entry: .init(interactionId: interactionId, sortId: renderItem.interaction.sortId),
            date: Date(),
        )
    }
}
