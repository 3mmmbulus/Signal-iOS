//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 回应飞入（tellomi/tellomi 交互审计 A-07；owner 2026-09-26 定「两端都飞」）。
///
/// 长按菜单的回应条上选中一个表情后，表情先在原处轻轻「拿起来」；等聊天列表把这条回应画出来，
/// 再沿一道弧线落到消息下方回应胶囊里的同一个表情上，落定时回弹一下并给一次轻触感。
///
/// - 只在窗口上叠一个表情字，不改聊天列表的布局动画（胶囊本身的增减属于聊天体验 M9 那条管线）。
/// - 弧线来自两条弹簧：横向用 `snap` 去回弹，纵向用 `large` 并带一点向上的初速，横向先到、纵向后落。
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

    /// 选中后放大一点，表示「拿起来了」。
    static let liftScale: CGFloat = 1.15
    /// 落到胶囊上时比胶囊里的表情大这么多，再用 `emphasis` 弹回原大小。
    static let landingOvershoot: CGFloat = 1.25
    /// 纵向向上的初速（点 / 秒），让路线先轻轻抬起再落下。
    static let tossSpeed: CGFloat = 700
    /// 纵向距离小于这个值就不抬，免得原地上下抖。
    static let minimumTossDistance: CGFloat = 24
    /// 等落点的最长时间。
    static let landingTimeout: TimeInterval = 2
    /// 横向：临界阻尼，先到。
    static let horizontalSpring = TellomiMotion.snap.withoutBounce
    /// 纵向：比横向慢一点、带一点回弹，后落；和横向的时间差就是弧线。
    static let verticalSpring = TellomiMotion.large
    /// 起飞后多久在落点播「爆开」（交互审计 A-07）：飞行的 75%，和 Telegram 两端一样在快落下时就开始。
    static let burstDelay: TimeInterval = verticalSpring.duration * 0.75

    private let overlayView = UIView()
    /// 只管横向位置。
    private let horizontalView = UIView()
    /// 只管纵向位置（相对 horizontalView）。
    private let verticalView = UIView()
    private let emojiLabel = UILabel()
    private let sourceCenter: CGPoint
    private let sourceFontSize: CGFloat
    private var hasFinished = false
    private weak var targetView: UIView?
    private var landingScale: CGFloat = 1
    private var arrivalsRemaining = 0
    /// 飞行期间自己留住自己，直到叠在窗口上的那一层收走（[finish]）。
    /// 调用方什么时候放掉引用都行；不留住的话，落定的回弹动画收尾时对象已经没了，那一层会永远留在窗口上
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

        horizontalView.center = sourceCenter
        overlayView.addSubview(horizontalView)
        horizontalView.addSubview(verticalView)

        emojiLabel.text = emoji
        emojiLabel.font = .systemFont(ofSize: source.fontSize)
        emojiLabel.textAlignment = .center
        emojiLabel.sizeToFit()
        emojiLabel.center = .zero
        verticalView.addSubview(emojiLabel)

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

    /// 飞到 `targetView`（胶囊里显示这个表情的那个字）上。飞行期间它一直藏着，落定后再露出。
    func land(on targetView: UIView, targetFontSize: CGFloat) {
        guard !hasFinished, overlayView.superview != nil, targetView.window != nil else {
            cancel()
            return
        }
        hasFinished = true
        self.targetView = targetView

        let targetCenter = targetView.convert(CGPoint(x: targetView.bounds.midX, y: targetView.bounds.midY), to: overlayView)
        let landingScale = Self.landingScale(sourceFontSize: sourceFontSize, targetFontSize: targetFontSize)
        self.landingScale = landingScale
        targetView.alpha = 0

        stopLiftAnimation()

        let verticalDistance = targetCenter.y - sourceCenter.y
        let horizontal = TellomiMotion.animator(Self.horizontalSpring, reduceMotion: false) {
            self.horizontalView.center.x = targetCenter.x
        }
        let vertical = TellomiMotion.animator(
            Self.verticalSpring,
            initialVelocity: Self.verticalInitialVelocity(verticalDistance: verticalDistance),
            reduceMotion: false,
        ) {
            self.verticalView.center.y = verticalDistance
            self.emojiLabel.transform = CGAffineTransform(scaleX: landingScale, y: landingScale)
        }

        arrivalsRemaining = 2
        horizontal.addCompletion { [weak self] _ in self?.didArrive() }
        vertical.addCompletion { [weak self] _ in self?.didArrive() }
        horizontal.startAnimation()
        vertical.startAnimation()

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.burstDelay) { [weak self, weak targetView] in
            guard let self, let targetView, let window = targetView.window else { return }
            let center = targetView.convert(CGPoint(x: targetView.bounds.midX, y: targetView.bounds.midY), to: window)
            TellomiReactionBurst.play(emoji: self.emoji, at: center, in: window, emojiSize: targetFontSize)
        }
    }

    /// 横纵两条弹簧都到了才算落到胶囊上。
    private func didArrive() {
        arrivalsRemaining -= 1
        guard arrivalsRemaining == 0 else { return }
        settle()
    }

    /// 落定：比胶囊里的字大一点的飞行字用 `emphasis` 弹回原大小，然后换成真的那个字。
    private func settle() {
        guard let targetView, targetView.window != nil else {
            fadeOut()
            return
        }
        SelectionHapticFeedback().selectionChanged()
        let finalScale = landingScale / Self.landingOvershoot
        let animator = TellomiMotion.animator(TellomiMotion.emphasis, reduceMotion: false) {
            self.emojiLabel.transform = CGAffineTransform(scaleX: finalScale, y: finalScale)
        }
        animator.addCompletion { [weak self, weak targetView] _ in
            targetView?.alpha = 1
            self?.finish()
        }
        animator.startAnimation()
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

    /// 停在当前的放大比例上，接下来的动画从这里接着走。
    private func stopLiftAnimation() {
        guard let liftAnimator else { return }
        if liftAnimator.state == .active {
            liftAnimator.stopAnimation(false)
            liftAnimator.finishAnimation(at: .current)
        }
        self.liftAnimator = nil
    }

    /// 唯一的收尾：停掉还在跑的放大动画，把叠在窗口上的那一层收走，放开自己。
    private func finish() {
        stopLiftAnimation()
        overlayView.removeFromSuperview()
        keepAlive = nil
    }

    // MARK: - 数值（单测覆盖）

    /// 飞到胶囊时的缩放：先缩到胶囊里的字号，再多留 [landingOvershoot] 给落定的回弹。
    static func landingScale(sourceFontSize: CGFloat, targetFontSize: CGFloat) -> CGFloat {
        guard sourceFontSize > 0, targetFontSize > 0 else { return 1 }
        return targetFontSize / sourceFontSize * landingOvershoot
    }

    /// 纵向弹簧的初速（UIKit 的相对速度：每秒走完剩余路程的比例，正数朝目标）。
    /// 目标在下方且足够远时给一个向上的初速，让路线先抬起再落下；否则不抬。
    static func verticalInitialVelocity(verticalDistance: CGFloat) -> CGVector {
        guard verticalDistance >= minimumTossDistance else { return .zero }
        return CGVector(dx: 0, dy: -tossSpeed / verticalDistance)
    }
}
