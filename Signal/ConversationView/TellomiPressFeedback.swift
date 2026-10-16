//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（交互审计 A-09，iOS 半边）：会话页里可点的一块（引用、文件、联系人卡、回应胶囊），手指一按下就缩一下，松开弹回——
/// 原来要到抬手（`SingleOrDoubleTapGestureRecognizer` 在 `touchesEnded` 才处理）才有动静。
///
/// 和安卓（Signal-Android#297 `TellomiPressFeedback`）同一套规则：引用、文件、联系人卡缩到 0.97，回应胶囊 0.9，支点在手指处；
/// 松开、取消、手指挪出 10 pt（在滚动）都弹回；多选时不按；减弱动态效果时不缩、只压暗。整条纯文字气泡不缩（iMessage 也不缩），
/// 链接卡片有它自己的按下叠层（card-visual §3.6），这里不管。
///
/// 照 Telegram iOS 的机制（只读，代码是自己写的）：气泡里可点的子区域按下即有高亮 / 缩放，见 PR 里的 Telegram reference。
@MainActor
final class TellomiPressFeedback {

    /// 按下去缩的那一块。
    struct Target {
        let view: UIView
        let scale: CGFloat
    }

    /// 引用、文件、联系人卡（同安卓）。
    nonisolated static let contentScale: CGFloat = 0.97
    /// 回应胶囊（同安卓、Telegram）。
    nonisolated static let reactionScale: CGFloat = 0.9
    /// 减弱动态效果时不缩，压暗到这个透明度。
    nonisolated static let reducedMotionAlpha: CGFloat = 0.6
    /// 手指挪出这么远算在拖（滚动 / 滑动回复），弹回（同链接卡片 `CVLinkPreviewPressTracker.moveSlop`）。
    nonisolated static let moveSlop: CGFloat = 10

    private(set) weak var pressedView: UIView?
    private var pressedUsesAlpha = false
    private var startInWindow: CGPoint?
    private var animator: UIViewPropertyAnimator?

    var isPressed: Bool { pressedView != nil }

    /// 按着的正文链接 / 提及（高亮的是文字本身，不缩）。
    private(set) weak var pressedTextLabel: CVTextLabel?

    /// 按下正文里的链接 / 提及：马上高亮；松开、挪出 [moveSlop]、长按拿起时收回。
    func pressText(label: CVTextLabel, item: CVTextLabel.Item, pointInWindow: CGPoint) {
        cancel(animated: false)
        label.tellomiPress(item: item)
        pressedTextLabel = label
        startInWindow = pointInWindow
    }

    private func releaseText() {
        pressedTextLabel?.tellomiReleasePressedItem()
        pressedTextLabel = nil
    }

    /// 按下：`point` 是手指在 `target.view` 里的位置（支点），`pointInWindow` 用来算挪了多远。
    func press(_ target: Target, at point: CGPoint, pointInWindow: CGPoint, reduceMotion: Bool = TellomiMotion.isReduceMotionEnabled) {
        cancel(animated: false)
        let view = target.view
        pressedView = view
        pressedUsesAlpha = reduceMotion
        startInWindow = pointInWindow
        let animator = TellomiMotion.animator(TellomiMotion.press, reduceMotion: reduceMotion) {
            if reduceMotion {
                view.alpha = Self.reducedMotionAlpha
            } else {
                view.transform = Self.transform(scale: target.scale, pivot: point, bounds: view.bounds)
            }
        }
        self.animator = animator
        animator.startAnimation()
    }

    /// 手指挪动：挪出 [moveSlop] 就弹回（这次触摸之后不再按）。
    func moved(toWindowPoint point: CGPoint) {
        guard isPressed || pressedTextLabel != nil, let start = startInWindow else {
            return
        }
        if hypot(point.x - start.x, point.y - start.y) > Self.moveSlop {
            release()
        }
    }

    /// 松开 / 取消：弹回原样（`release` 弹簧，从当前的样子起步）。
    func release(reduceMotion: Bool = TellomiMotion.isReduceMotionEnabled) {
        releaseText()
        guard let view = pressedView else {
            startInWindow = nil
            return
        }
        let usesAlpha = pressedUsesAlpha
        clearPressState()
        animator?.stopAnimation(true)
        let animator = TellomiMotion.animator(TellomiMotion.release, reduceMotion: reduceMotion) {
            if usesAlpha {
                view.alpha = 1
            } else {
                view.transform = .identity
            }
        }
        self.animator = animator
        animator.startAnimation()
    }

    /// 立刻还原、不播动画：长按拿起整条消息时，菜单里的预览是此刻的快照，不能带着缩放。
    func cancel(animated: Bool) {
        releaseText()
        guard animated else {
            animator?.stopAnimation(true)
            animator = nil
            if let view = pressedView {
                view.transform = .identity
                view.alpha = 1
            }
            clearPressState()
            return
        }
        release()
    }

    private func clearPressState() {
        pressedView = nil
        startInWindow = nil
        pressedUsesAlpha = false
    }

    /// 以手指为支点缩放：不改 anchorPoint（手动排版的视图靠 frame 摆位置），先挪到支点、缩、再挪回去。
    static func transform(scale: CGFloat, pivot: CGPoint, bounds: CGRect) -> CGAffineTransform {
        let dx = pivot.x - bounds.midX
        let dy = pivot.y - bounds.midY
        return CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -dx, y: -dy)
    }
}

/// 只观察触摸、从不「识别」的手势（同链接卡片的 `CVLinkPreviewTouchObserver`）：触摸一按下就报（不像视图的 touchesBegan
/// 要等滚动视图确认不是滚动），不取消视图上的触摸、不和会话页的点击 / 长按 / 滑动抢事件（自己停在 `.possible`，触摸结束就
/// `.failed`；别的手势认出来时它被挤掉，`reset()` 里一样结束）。
final class TellomiPressTouchObserver: UIGestureRecognizer {
    var onBegan: ((UITouch) -> Void)?
    var onMoved: ((UITouch) -> Void)?
    var onEnded: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // 第二根手指（捏合、双指滚动）：不算按下
        guard touches.count == 1, (event.allTouches?.count ?? 1) == 1, let touch = touches.first else {
            onEnded?()
            return
        }
        onBegan?(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if let touch = touches.first {
            onMoved?(touch)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        onEnded?()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        onEnded?()
        state = .failed
    }

    override func reset() {
        super.reset()
        onEnded?()
    }
}
