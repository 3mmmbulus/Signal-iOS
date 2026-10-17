//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（M9 发送动画；需求 `bubbles-and-motion.md` 3.5，设计规范 `bubbles-and-motion-design.md` 第 4 节）：
/// 点发送后，新气泡从输入框里飞到会话里它的位置。
///
/// 照 Telegram 两端的做法（只读机制，GPLv2，一行不搬；iOS `TelegramUI/Sources/ChatMessageTransitionNode.swift` +
/// `ChatMessageBubbleItemNode.animateContentFromTextInputField` + `ChatMessageTextBubbleContentNode.animateFrom`，
/// Android `ui/TextMessageEnterTransition.java`）：
/// - **输入框的框变成气泡**：气泡的框从输入框那个圆角框插值到气泡最终的位置和大小，左右边跟横向进度、上下边跟纵向进度；
///   圆角和尾巴不变形，尾巴从头就画着（两端都一样）；
/// - **一道弧线**：横向前快（`TellomiMotion.SendFlight.horizontalCurve`）、纵向跟列表（`verticalCurve`），字的原点同样走；
/// - **字**：输入框里的字（点发送那一刻的快照）淡出、气泡里的字淡入，不做颜色插值；气泡底色连同尾巴、时间、送达状态在前
///   `bubbleFadeIn` 由透明到不透明；字号从输入框的缩放到气泡的（两边都是正文字号时不缩）；
/// - **输入框**：照旧点下就清空；新的一条进列表之前，输入框里的字（连同框里的按钮）透明，快照画在原处，看起来还是点发送
///   那一刻的样子；起飞后随飞行进度淡回。
///
/// 新的一条从第一次配置格子起就藏着（`CVCell.tellomiIsHeldForSendFlight`），落定后再露出；等不到它（写失败、不在屏幕上、
/// 页面走了）就不飞：快照原地淡掉，这一条照常出现。飞的东西放在窗口上（在输入框上面），每帧重新量落点。
/// 和 Android `TellomiSendTransition` 同一套规则和数。
@MainActor
final class TellomiSendFlight {

    /// 点发送那一刻输入框的样子（窗口坐标）。
    struct Source {
        /// 输入框里那几行字的快照（光标藏掉拍的）。
        let textSnapshot: UIView
        /// 快照在窗口里的位置。
        let textSnapshotFrame: CGRect
        /// 第一行字的左上角。
        let textOrigin: CGPoint
        let fontSize: CGFloat
        /// 输入框那个圆角框。
        let box: CGRect
    }

    /// 落点：真的那一格（会话列表里）的气泡和正文。
    struct Target {
        let bubbleView: CVColorOrGradientView
        let bodyTextView: UIView
        let renderItem: CVRenderItem
    }

    /// 一帧的几何（窗口坐标）：气泡本体的框（不含尾巴）、字的原点、字的缩放、底色的透明度。
    struct Frame: Equatable {
        let body: CGRect
        let textOrigin: CGPoint
        let scale: CGFloat
        let bubbleAlpha: CGFloat
    }

    enum Phase {
        case waiting
        case flying
        case fadingOut
        case done
    }

    /// 这一次发出的消息的时间戳（`ThreadUtil.enqueueMessage` 给的），用来认出插进列表的那一条。
    let messageTimestamp: UInt64
    private(set) var interactionUniqueId: String?
    private(set) var phase: Phase = .waiting
    /// 这一次想让输入框是多透明：等的时候 0，飞的时候随进度淡回，收尾 1。几次连着发时调用方取最小的。
    private(set) var fieldAlpha: CGFloat = 0

    private let source: Source
    private let overlayView = UIView()
    /// 气泡底色和尾巴（跟着框变形，渐变按会话页取，和真的气泡一样贴着屏幕）。
    private let background = CVColorOrGradientView()
    /// 气泡本体那一块：里面的内容和输入框的字都裁在这里面。
    private let clipView = UIView()
    private var content: CVCellView?
    /// 那份格子里的正文（和 `content` 一起建的）。
    private weak var contentText: UIView?
    private var tail: BubbleConfiguration.Tail?
    private var textScaleFrom: CGFloat = 1
    private var displayLink: CADisplayLink?
    private var createdAt: CFTimeInterval?
    private var flyStart: CFTimeInterval = 0
    private var fadeStart: CFTimeInterval = 0
    /// 飞行期间自己留住自己，直到窗口上那一层收走（同 `ReactionFlyIn`）。
    private var keepAlive: TellomiSendFlight?

    private let findTarget: (String) -> Target?
    private let makeContent: (CVRenderItem) -> CVCellView?
    private let onChange: (TellomiSendFlight) -> Void
    private let onReveal: (TellomiSendFlight, String) -> Void
    private let onFinish: (TellomiSendFlight) -> Void

    /// - Parameters:
    ///   - findTarget: 这一条现在在会话列表里的格子（不在屏幕上为 nil），每帧问一次。
    ///   - makeContent: 用同一个 render item 再画一份格子（飞的就是它；底色由这里另画）。
    ///   - onChange: 输入框该变透明度了（`fieldAlpha`）。
    ///   - onReveal: 把藏着的那一条放出来（落定、或者不飞了）。
    ///   - onFinish: 收尾了，从列表里拿掉。
    init(
        messageTimestamp: UInt64,
        source: Source,
        window: UIWindow,
        findTarget: @escaping (String) -> Target?,
        makeContent: @escaping (CVRenderItem) -> CVCellView?,
        onChange: @escaping (TellomiSendFlight) -> Void,
        onReveal: @escaping (TellomiSendFlight, String) -> Void,
        onFinish: @escaping (TellomiSendFlight) -> Void,
    ) {
        self.messageTimestamp = messageTimestamp
        self.source = source
        self.findTarget = findTarget
        self.makeContent = makeContent
        self.onChange = onChange
        self.onReveal = onReveal
        self.onFinish = onFinish

        overlayView.frame = window.bounds
        overlayView.isUserInteractionEnabled = false
        overlayView.backgroundColor = .clear
        overlayView.accessibilityElementsHidden = true
        window.addSubview(overlayView)

        // 手动排版的视图默认关了 autoresizing 转约束：放进普通视图里一走自动布局就被压成 0（模拟器录屏里实测）。
        background.translatesAutoresizingMaskIntoConstraints = true
        background.alpha = 0
        overlayView.addSubview(background)
        clipView.clipsToBounds = true
        overlayView.addSubview(clipView)

        source.textSnapshot.frame = source.textSnapshotFrame
        overlayView.addSubview(source.textSnapshot)

        keepAlive = self
        let link = CADisplayLink(target: TellomiSendFlightDisplayLinkProxy(owner: self), selector: #selector(TellomiSendFlightDisplayLinkProxy.tick(_:)))
        link.preferredFrameRateRange = TellomiFrameRate.interactive
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// 插进列表的那一条就是这一次发的：从现在起它的格子一直藏着，直到落定或不飞。
    func claim(interactionUniqueId: String) {
        guard phase == .waiting, self.interactionUniqueId == nil else {
            return
        }
        self.interactionUniqueId = interactionUniqueId
    }

    /// 这一条的格子现在该不该藏着。
    func isHoldingRow(interactionUniqueId: String) -> Bool {
        (phase == .waiting || phase == .flying) && self.interactionUniqueId == interactionUniqueId
    }

    /// 发送出错、页面要走：还没起飞就原地淡掉，飞到一半就直接收掉。
    func cancel() {
        switch phase {
        case .waiting:
            fadeOut(at: CACurrentMediaTime())
        case .flying:
            finish()
        case .fadingOut, .done:
            break
        }
    }

    /// 页面马上就没了：不淡，直接收掉。
    func cancelImmediately() {
        finish()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard phase != .done else {
            return
        }
        guard overlayView.window != nil else {
            finish()
            return
        }
        let now = link.targetTimestamp
        let createdAt = self.createdAt ?? now
        self.createdAt = createdAt

        switch phase {
        case .waiting:
            if let interactionUniqueId, let target = findTarget(interactionUniqueId) {
                if isOnScreen(target) {
                    takeOff(target, at: now)
                } else {
                    fadeOut(at: now)
                }
            } else if now - createdAt > TellomiMotion.SendFlight.waitForRow {
                fadeOut(at: now)
            }

        case .flying:
            guard let interactionUniqueId, let target = findTarget(interactionUniqueId) else {
                // 那一格没了（滚走、被删）：没地方落，收掉。
                finish()
                return
            }
            let t = min(1, max(0, (now - flyStart) / TellomiMotion.SendFlight.duration))
            layOut(target, t: t)
            fieldAlpha = CGFloat(t)
            onChange(self)
            if t >= 1 {
                finish()
            }

        case .fadingOut:
            let t = min(1, max(0, (now - fadeStart) / TellomiMotion.SendFlight.cancelFade))
            source.textSnapshot.alpha = CGFloat(1 - t)
            fieldAlpha = CGFloat(t)
            onChange(self)
            if t >= 1 {
                finish()
            }

        case .done:
            break
        }
    }

    // MARK: -

    /// 落点那一格整块看得见（在输入框上面、窗口里）才飞。
    private func isOnScreen(_ target: Target) -> Bool {
        guard target.bubbleView.window != nil, target.bubbleView.bounds.width > 0 else {
            return false
        }
        let bubble = target.bubbleView.convert(target.bubbleView.bounds, to: nil)
        return bubble.minY >= 0 && bubble.maxY <= source.box.maxY
    }

    private func takeOff(_ target: Target, at now: CFTimeInterval) {
        let appearance = target.bubbleView.tellomiAppearance
        let hasFill: Bool = {
            guard let appearance else {
                return false
            }
            if case .transparent = appearance.value {
                return false
            }
            return true
        }()
        guard
            hasFill,
            let appearance,
            let content = makeContent(target.renderItem),
            let messageView = content.componentView as? CVComponentMessage.CVComponentViewMessage,
            let copyBubble = messageView.tellomiSendFlightBubbleView,
            let copyText = messageView.tellomiSendFlightBodyTextView
        else {
            // 没有气泡底色（大号表情等）、或者不是那种格子：不飞。
            fadeOut(at: now)
            return
        }

        background.configure(value: appearance.value, referenceView: appearance.referenceView, bubbleConfig: appearance.bubbleConfig)
        tail = appearance.bubbleConfig?.tail

        // 再画一份格子，底色透明（底色由 `background` 跟着框变形画），只留字、时间和送达状态。
        copyBubble.configure(value: .transparent, referenceView: appearance.referenceView, bubbleConfig: appearance.bubbleConfig)
        content.bounds = CGRect(origin: .zero, size: target.renderItem.cellSize)
        clipView.addSubview(content)
        content.setNeedsLayout()
        content.layoutIfNeeded()
        content.alpha = 0
        self.content = content
        self.contentText = copyText

        // 输入框的字跟着气泡的字走：锚点放在第一行字的左上角。
        let snapshot = source.textSnapshot
        clipView.addSubview(snapshot)
        let snapshotSize = source.textSnapshotFrame.size
        snapshot.bounds = CGRect(origin: .zero, size: snapshotSize)
        snapshot.layer.anchorPoint = CGPoint(
            x: snapshotSize.width > 0 ? (source.textOrigin.x - source.textSnapshotFrame.minX) / snapshotSize.width : 0,
            y: snapshotSize.height > 0 ? (source.textOrigin.y - source.textSnapshotFrame.minY) / snapshotSize.height : 0,
        )

        let bubbleFontSize = UIFont.dynamicTypeBody.pointSize
        textScaleFrom = bubbleFontSize > 0 ? source.fontSize / bubbleFontSize : 1

        phase = .flying
        flyStart = now
        layOut(target, t: 0)
    }

    private func layOut(_ target: Target, t: Double) {
        let bubble = target.bubbleView.convert(target.bubbleView.bounds, to: nil)
        let toBody = tail?.bodyRect(in: bubble) ?? bubble
        let toText = target.bodyTextView.convert(CGPoint.zero, to: nil)
        let frame = Self.frame(
            at: t,
            fromBox: source.box,
            fromText: source.textOrigin,
            textScaleFrom: textScaleFrom,
            toBody: toBody,
            toText: toText,
        )

        // 窗口坐标就是这一层的坐标（铺满窗口）。
        var backgroundFrame = frame.body
        if let tail {
            backgroundFrame.size.width += BubbleConfiguration.Tail.extent
            if !tail.isOnRight {
                backgroundFrame.origin.x -= BubbleConfiguration.Tail.extent
            }
        }
        background.frame = backgroundFrame
        background.layoutIfNeeded()
        background.alpha = frame.bubbleAlpha

        clipView.frame = frame.body
        let originInClip = CGPoint(x: frame.textOrigin.x - frame.body.minX, y: frame.textOrigin.y - frame.body.minY)
        if let content, let contentText {
            // 那份格子的正文在它自己坐标里的位置每帧量（格子是按需排版的，刚放进来时还没排好）；锚点放在第一行字的左上角，
            // 这样缩放、移动都绕着字走。
            let size = content.bounds.size
            let textInContent = contentText.convert(CGPoint.zero, to: content)
            content.layer.anchorPoint = CGPoint(
                x: size.width > 0 ? textInContent.x / size.width : 0,
                y: size.height > 0 ? textInContent.y / size.height : 0,
            )
            content.transform = CGAffineTransform(scaleX: frame.scale, y: frame.scale)
            content.layer.position = originInClip
            content.alpha = frame.bubbleAlpha
        }
        let snapshotScale = textScaleFrom > 0 ? frame.scale / textScaleFrom : 1
        source.textSnapshot.transform = CGAffineTransform(scaleX: snapshotScale, y: snapshotScale)
        source.textSnapshot.layer.position = originInClip
        source.textSnapshot.alpha = 1 - frame.bubbleAlpha
    }

    private func fadeOut(at now: CFTimeInterval) {
        phase = .fadingOut
        fadeStart = now
        revealRow()
    }

    private func revealRow() {
        if let interactionUniqueId {
            onReveal(self, interactionUniqueId)
        }
    }

    private func finish() {
        guard phase != .done else {
            return
        }
        // 先放出那一格、再收掉这一层：同一帧里换过去，不闪。
        revealRow()
        phase = .done
        fieldAlpha = 1
        displayLink?.invalidate()
        displayLink = nil
        overlayView.removeFromSuperview()
        content = nil
        onChange(self)
        onFinish(self)
        keepAlive = nil
    }

    // MARK: - Geometry

    /// 第 [t]（0…1，线性时间）帧：字的原点横向按 `horizontalCurve`、纵向按 `verticalCurve` 从输入框走到气泡；字号同横向进度缩放；
    /// 气泡本体的框左右边跟横向进度、上下边跟纵向进度，从输入框的框变到气泡；底色在前 `bubbleFadeIn` 淡入。
    static func frame(
        at t: Double,
        fromBox: CGRect,
        fromText: CGPoint,
        textScaleFrom: CGFloat,
        toBody: CGRect,
        toText: CGPoint,
    ) -> Frame {
        let time = min(1, max(0, t))
        let px = CGFloat(TellomiMotion.SendFlight.horizontalCurve.value(at: time))
        let py = CGFloat(TellomiMotion.SendFlight.verticalCurve.value(at: time))
        func lerp(_ from: CGFloat, _ to: CGFloat, _ progress: CGFloat) -> CGFloat {
            from + (to - from) * progress
        }
        let minX = lerp(fromBox.minX, toBody.minX, px)
        let maxX = lerp(fromBox.maxX, toBody.maxX, px)
        let minY = lerp(fromBox.minY, toBody.minY, py)
        let maxY = lerp(fromBox.maxY, toBody.maxY, py)
        let fadeIn = TellomiMotion.SendFlight.bubbleFadeIn / TellomiMotion.SendFlight.duration
        return Frame(
            body: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
            textOrigin: CGPoint(x: lerp(fromText.x, toText.x, px), y: lerp(fromText.y, toText.y, py)),
            scale: lerp(textScaleFrom, 1, px),
            bubbleAlpha: CGFloat(min(1, max(0, time / fadeIn))),
        )
    }
}

/// CADisplayLink 会强引用 target：中间隔一层弱引用（同 `TellomiJumpScrollAnimator`）。
private final class TellomiSendFlightDisplayLinkProxy: NSObject {
    weak var owner: TellomiSendFlight?

    init(owner: TellomiSendFlight) {
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
