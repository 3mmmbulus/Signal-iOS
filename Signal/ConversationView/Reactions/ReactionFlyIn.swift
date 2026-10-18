//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 回应飞入（tellomi/tellomi 交互审计 A-07；owner 2026-09-26 定「两端都飞」，10-18「一比一复刻 Telegram 的这个动效」）。
///
/// 长按菜单的回应条上选中一个表情后，表情先在原处轻轻「拿起来」；等聊天列表把这条回应画出来，再飞到消息下方
/// 回应胶囊里的同一个表情上。飞法照 Telegram iOS `ReactionContextNode.animateOutToReaction`（只取数，没搬代码）：
/// - 0.2 s、时间线性，走一条抛物线：过起点、（横向中点，起点往上 30 pt）、落点，横向匀速
///   （Telegram `generateParabollicMotionKeyframes(… elevation: 30)`；离得很近时走直线）；
/// - 大小同样线性地从条上的字号变到胶囊里的字号，落地不回弹；
/// - 0.15 s 起在落点播「爆开」（Telegram 这时开始播回应周围的效果）；
/// - 落到胶囊上时换成真的那个字，再过 0.1 s 给一下 selection 触感（Telegram 落点后 0.1 s `HapticFeedback.tap()`）。
///
/// - 只在窗口上叠一个表情字，不改聊天列表的布局动画（胶囊本身的增减属于聊天体验 M9 那条管线）。
/// - 每一帧重新量落点，列表还在挪也跟得上。
/// - 减弱动态效果时调用方不创建它；等不到落点（写失败、消息被滚走、页面关了）就原地淡出。
@MainActor
final class ReactionFlyIn {

    /// 回应条上被选中的那个表情：窗口坐标里的位置和字号。
    struct Source {
        let frameInWindow: CGRect
        let fontSize: CGFloat
    }

    let messageUniqueId: String
    let emoji: String

    /// 选中后放大一点，表示「拿起来了」（等菜单收完、胶囊画出来的那一会儿）。
    static let liftScale: CGFloat = 1.15
    /// 等落点的最长时间。
    static let landingTimeout: TimeInterval = 2
    /// 飞行时长（Telegram iOS：`.animated(duration: 0.2, curve: .linear)`）。
    static let flightDuration: TimeInterval = 0.2
    /// 抛物线中点比起点高这么多（Telegram `elevation: 30`）。
    static let flightElevation: CGFloat = 30
    /// 起点和落点横纵都不到这么远时走直线（Telegram 同一个门槛）。
    static let straightFlightDistance: CGFloat = 5
    /// 起飞后多久在落点播「爆开」（Telegram 0.15 s 起播回应周围的效果，即飞行的 75%）。
    static let burstDelay: TimeInterval = 0.15
    /// 落到胶囊上以后多久给触感（Telegram 落点后 0.1 s）。
    static let landingHapticDelay: TimeInterval = 0.1

    private let overlayView = UIView()
    private let flierView = UIView()
    private let emojiLabel = UILabel()
    private let sourceCenter: CGPoint
    private let sourceFontSize: CGFloat
    private var hasFinished = false
    private weak var targetView: UIView?
    private var targetFontSize: CGFloat = 0
    private var flightStartTime: CFTimeInterval = 0
    private var flightStartScale: CGFloat = 1
    private var burstPlayed = false
    /// 落地那一刻要做的事（会话页：菜单还在收的话先露出回应区）。只在真落地时调，取消、等不到落点时不调。
    private var onHit: (() -> Void)?
    private var displayLink: CADisplayLink?
    /// 飞行期间自己留住自己，直到叠在窗口上的那一层收走（[finish]）。
    /// 调用方什么时候放掉引用都行；不留住的话，飞行收尾时对象已经没了，那一层会永远留在窗口上
    /// （走查模拟器上撤回回应后，胶囊没了、一个小表情还悬在原处，就是这么来的）。
    private var keepAlive: ReactionFlyIn?
    /// 选中时「拿起来」的放大动画。起飞或收尾时停掉：那一层离开窗口后它可能永远等不到结束，
    /// 留着就会一直握着它的闭包。
    private var liftAnimator: UIViewPropertyAnimator?

    init(messageUniqueId: String, emoji: String, source: Source, window: UIWindow) {
        self.messageUniqueId = messageUniqueId
        self.emoji = emoji
        self.sourceCenter = CGPoint(x: source.frameInWindow.midX, y: source.frameInWindow.midY)
        self.sourceFontSize = source.fontSize

        overlayView.frame = window.bounds
        overlayView.isUserInteractionEnabled = false
        overlayView.backgroundColor = .clear
        overlayView.accessibilityElementsHidden = true
        window.addSubview(overlayView)

        flierView.center = sourceCenter
        overlayView.addSubview(flierView)

        emojiLabel.text = emoji
        emojiLabel.font = .systemFont(ofSize: source.fontSize)
        emojiLabel.textAlignment = .center
        emojiLabel.sizeToFit()
        emojiLabel.center = .zero
        flierView.addSubview(emojiLabel)

        let lifted = CGAffineTransform(scaleX: ReactionFlyIn.liftScale, y: ReactionFlyIn.liftScale)
        let liftAnimator = TellomiMotion.animator(TellomiMotion.snap, reduceMotion: false) { [emojiLabel] in
            emojiLabel.transform = lifted
        }
        liftAnimator.startAnimation()
        self.liftAnimator = liftAnimator

        keepAlive = self
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.landingTimeout) { [weak self] in
            self?.cancel()
        }
    }

    /// 找到落点的那一刻就把它藏起来：聊天列表是在同一轮 runloop 里配置好新格子、再通知落地的，
    /// 这时藏，新表情一帧都不会先露出来；要是之后取消了，[cancel] 会把它放回来。
    func claim(_ targetView: UIView) {
        guard !hasFinished else { return }
        self.targetView = targetView
        targetView.alpha = 0
    }

    /// 飞到 `targetView`（胶囊里显示这个表情的那个字）上。飞行期间它一直藏着，落地时再露出、调 [onHit]
    /// （Telegram `animateOutToReaction(onHit:)`）。
    func land(on targetView: UIView, targetFontSize: CGFloat, onHit: (() -> Void)? = nil) {
        guard !hasFinished, overlayView.superview != nil, targetView.window != nil else {
            cancel()
            return
        }
        hasFinished = true
        self.targetView = targetView
        self.targetFontSize = targetFontSize
        self.onHit = onHit
        targetView.alpha = 0

        stopLiftAnimation()
        flightStartScale = emojiLabel.transform.a
        flightStartTime = CACurrentMediaTime()

        let clock = FlightClock { [weak self] in self?.step() }
        let displayLink = CADisplayLink(target: clock, selector: #selector(FlightClock.tick))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
        step()
    }

    /// 每一帧：量一次落点，按时间进度放到抛物线上、缩到对应大小；到 0.15 s 爆开，到 0.2 s 落地。
    private func step() {
        guard let targetView, targetView.window != nil, overlayView.superview != nil else {
            stopClock()
            targetView?.alpha = 1
            fadeOut()
            return
        }

        let elapsed = CACurrentMediaTime() - flightStartTime
        let progress = CGFloat(min(1, max(0, elapsed / Self.flightDuration)))
        let targetCenter = targetView.convert(CGPoint(x: targetView.bounds.midX, y: targetView.bounds.midY), to: overlayView)

        flierView.center = Self.flightPosition(from: sourceCenter, to: targetCenter, progress: progress)
        let landingScale = Self.landingScale(sourceFontSize: sourceFontSize, targetFontSize: targetFontSize)
        let scale = flightStartScale + (landingScale - flightStartScale) * progress
        emojiLabel.transform = CGAffineTransform(scaleX: scale, y: scale)

        if !burstPlayed, elapsed >= Self.burstDelay {
            playBurst(on: targetView)
        }
        if progress >= 1 {
            hit()
        }
    }

    /// 落地：换成胶囊里真的那个字，叠的那一层收走；0.1 s 后给触感。
    private func hit() {
        stopClock()
        if !burstPlayed, let targetView {
            playBurst(on: targetView)
        }
        targetView?.alpha = 1
        let onHit = self.onHit
        finish()
        onHit?()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.landingHapticDelay) {
            SelectionHapticFeedback().selectionChanged()
        }
    }

    private func playBurst(on targetView: UIView) {
        burstPlayed = true
        guard let window = targetView.window else { return }
        let center = targetView.convert(CGPoint(x: targetView.bounds.midX, y: targetView.bounds.midY), to: window)
        TellomiReactionBurst.play(emoji: emoji, at: center, in: window, emojiSize: targetFontSize)
    }

    /// 等不到落点：原地淡出，已经藏起来的落点放回来。可以重复调用。
    func cancel() {
        guard !hasFinished else { return }
        hasFinished = true
        targetView?.alpha = 1
        fadeOut()
    }

    private func fadeOut() {
        UIView.animate(
            withDuration: TellomiMotion.fadeOutDuration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState],
            animations: { self.overlayView.alpha = 0 },
            completion: { _ in self.finish() },
        )
    }

    /// 停在当前的放大比例上，接下来的飞行从这里接着走。
    private func stopLiftAnimation() {
        guard let liftAnimator else { return }
        if liftAnimator.state == .active {
            liftAnimator.stopAnimation(false)
            liftAnimator.finishAnimation(at: .current)
        }
        self.liftAnimator = nil
    }

    private func stopClock() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// 唯一的收尾：停掉还在跑的动画和时钟，把叠在窗口上的那一层收走，放开自己。
    private func finish() {
        stopLiftAnimation()
        stopClock()
        overlayView.removeFromSuperview()
        onHit = nil
        keepAlive = nil
    }

    // MARK: - 数值（单测覆盖）

    /// 落到胶囊时的缩放：缩到胶囊里的字号，不留回弹（Telegram 落地不回弹）。
    static func landingScale(sourceFontSize: CGFloat, targetFontSize: CGFloat) -> CGFloat {
        guard sourceFontSize > 0, targetFontSize > 0 else { return 1 }
        return targetFontSize / sourceFontSize
    }

    /// 飞到 [progress]（0–1，时间线性）时的位置。横向匀速；纵向是过起点、（横向中点，起点往上 [elevation]）、落点的
    /// 抛物线——横向匀速时，它就是按时间的二次插值（0、0.5、1 三个时刻），落点在起点正下方时也有定义。
    /// 起点和落点横纵都不到 [straightFlightDistance] 时走直线。
    static func flightPosition(
        from source: CGPoint,
        to target: CGPoint,
        progress: CGFloat,
        elevation: CGFloat = flightElevation,
    ) -> CGPoint {
        let t = min(1, max(0, progress))
        let x = source.x + (target.x - source.x) * t
        if abs(target.x - source.x) < straightFlightDistance, abs(target.y - source.y) < straightFlightDistance {
            return CGPoint(x: x, y: source.y + (target.y - source.y) * t)
        }
        let peak = source.y - elevation
        let y = source.y * (2 * t - 1) * (t - 1) + peak * 4 * t * (1 - t) + target.y * t * (2 * t - 1)
        return CGPoint(x: x, y: y)
    }
}

/// `CADisplayLink` 要一个 Objective-C 的 target，而且会一直强引用它；用这个小对象转一下。
private final class FlightClock: NSObject {
    private let onTick: () -> Void

    init(_ onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    @objc
    func tick() {
        onTick()
    }
}
