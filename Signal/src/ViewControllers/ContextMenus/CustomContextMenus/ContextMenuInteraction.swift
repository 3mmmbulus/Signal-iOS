//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
public import UIKit
import SignalUI

/// UIContextMenuInteractionDelegate analog
public protocol ContextMenuInteractionDelegate: AnyObject {
    func contextMenuInteraction(
        _ interaction: ContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint,
    ) -> ContextMenuConfiguration?
    func contextMenuInteraction(
        _ interaction: ContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: ContextMenuConfiguration,
    ) -> ContextMenuTargetedPreview?
    func contextMenuInteraction(
        _ interaction: ContextMenuInteraction,
        willDisplayMenuForConfiguration: ContextMenuConfiguration,
    )
    func contextMenuInteraction(
        _ interaction: ContextMenuInteraction,
        willEndForConfiguration: ContextMenuConfiguration,
    )
    func contextMenuInteraction(
        _ interaction: ContextMenuInteraction,
        didEndForConfiguration: ContextMenuConfiguration,
    )

}

/// UIContextMenuInteraction analog
public class ContextMenuInteraction: NSObject, UIInteraction {

    weak var delegate: ContextMenuInteractionDelegate?
    // Tellomi：测试要拿到菜单控制器（模拟往下拉），读权限放开到模块内。
    fileprivate(set) var contextMenuController: ContextMenuController?

    private let sourceViewBounceDuration = 0.2
    fileprivate var gestureEligibleForMenuPresentation: Bool {
        didSet {
            if !gestureEligibleForMenuPresentation {
                // Animate back out
                UIView.animate(
                    withDuration: sourceViewBounceDuration,
                    delay: 0,
                    options: [.curveEaseOut, .beginFromCurrentState],
                    animations: {
                        self.targetedPreview?.view.transform = CGAffineTransform.identity
                    },
                    completion: nil,
                )
            }
        }
    }

    /// Tellomi（交互审计 A-06）：Telegram 从按下 0.12 s 起用 0.2 s 缩完、0.32 s 激活；这里从 0.2 s 的长按识别起缩剩下的 0.12 s。
    static let pressShrinkDuration: TimeInterval = 0.12

    /// 按住时缩到多小：宽度少 15 pt，最小 0.7（Telegram `ContextControllerSourceNode`）。
    static func pressedScale(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1 }
        return max(0.7, (width - 15) / width)
    }

    /// 这一次按压缩到的比例；菜单的预览从这个大小接着放回原大。
    fileprivate var pressedScale: CGFloat = 1

    fileprivate var locationInView = CGPoint.zero
    fileprivate var configuration: ContextMenuConfiguration?
    fileprivate var targetedPreview: ContextMenuTargetedPreview?

    private lazy var longPressGestureRecognizer: UIGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(longPressRecognized(sender:)))
        recognizer.minimumPressDuration = 0.2
        return recognizer
    }()

    // MARK: UIInteraction

    public var view: UIView?

    public func willMove(to view: UIView?) {
        if view != self.view {
            self.view?.removeGestureRecognizer(longPressGestureRecognizer)
        }
    }

    public func didMove(to view: UIView?) {
        if view != self.view {
            self.view = view
            self.view?.addGestureRecognizer(longPressGestureRecognizer)
        }
    }

    public init(
        delegate: ContextMenuInteractionDelegate,
    ) {
        self.delegate = delegate
        gestureEligibleForMenuPresentation = false
        super.init()
    }

    public func initiateContextMenuGesture(locationInView: CGPoint, presentImmediately: Bool) {
        self.locationInView = locationInView
        gestureEligibleForMenuPresentation = true

        guard let delegate = self.delegate else {
            owsFailDebug("Missing ContextMenuInteractionDelegate")
            return
        }

        guard let view = self.view else {
            owsFailDebug("Missing view")
            return
        }

        guard let contextMenuConfiguration = delegate.contextMenuInteraction(self, configurationForMenuAtLocation: locationInView) else {
            return
        }

        configuration = contextMenuConfiguration

        guard let targetedPreview = delegate.contextMenuInteraction(self, previewForHighlightingMenuWithConfiguration: contextMenuConfiguration) ?? ContextMenuTargetedPreview(view: view, alignment: .center, accessoryViews: nil) else { return }

        for accessory in targetedPreview.accessoryViews {
            accessory.delegate = self
        }

        self.targetedPreview = targetedPreview

        let reduceMotion = MainActor.assumeIsolated { TellomiMotion.isReduceMotionEnabled }
        if presentImmediately || reduceMotion {
            self.presentMenu(locationInView: self.locationInView, presentImmediately: true)
        } else {
            // Tellomi（交互审计 A-06）：照 Telegram 的按压——按住时消息按「宽度 − 15 pt」线性缩小，按下后 0.32 s 弹菜单。
            // 聊天的长按识别保持 0.2 s（审计 Q-06），所以从识别起用剩下的 0.12 s 缩完。原来是 0.2 s 缩到 0.95、0.4 s 才弹。
            pressedScale = Self.pressedScale(forWidth: targetedPreview.view.bounds.width)
            UIView.animate(
                withDuration: Self.pressShrinkDuration,
                delay: 0,
                options: [.curveLinear, .beginFromCurrentState],
                animations: {
                    targetedPreview.view.transform = .scale(self.pressedScale)
                },
                completion: { finished in
                    let shouldPresent = finished && self.gestureEligibleForMenuPresentation

                    if shouldPresent {
                        self.presentMenu(locationInView: self.locationInView, presentImmediately: false)
                        // Animate back out
                        self.gestureEligibleForMenuPresentation = false
                    }
                },
            )
        }
    }

    public func presentMenu(locationInView: CGPoint, presentImmediately: Bool) {
        guard let view = self.view else {
            owsFailDebug("Missing view")
            return
        }

        guard let window = view.window else {
            owsFailDebug("View must be in a window!")
            return
        }

        guard let configuration = self.configuration else {
            owsFailDebug("Missing context menu configuration")
            return
        }

        guard let targetedPreview = self.targetedPreview else {
            owsFailDebug("Missing targeted preview")
            return
        }

        presentMenu(window: window, contextMenuConfiguration: configuration, targetedPreview: targetedPreview, presentImmediately: presentImmediately)
    }

    public func presentMenu(window: UIWindow, contextMenuConfiguration: ContextMenuConfiguration, targetedPreview: ContextMenuTargetedPreview, presentImmediately: Bool) {

        let menuAccessory = menuAccessory(configuration: contextMenuConfiguration, targetedPreview: targetedPreview)
        let contextMenuController = ContextMenuController(configuration: contextMenuConfiguration, preview: targetedPreview, initiatingGestureRecognizer: initiatingGestureRecognizer(), menuAccessory: menuAccessory, presentImmediately: presentImmediately, pressedScale: pressedScale)
        contextMenuController.initialKeyboardFrameInWindow = keyboardFrameInWindowAtPresentation()
        contextMenuController.delegate = self
        self.contextMenuController = contextMenuController

        delegate?.contextMenuInteraction(self, willDisplayMenuForConfiguration: contextMenuConfiguration)
        ImpactHapticFeedback.impactOccurred(style: .medium, intensity: 0.8)

        window.addSubview(contextMenuController.view)
        contextMenuController.view.frame = window.bounds
        contextMenuController.applyInitialKeyboardFrame()
    }

    public func initiatingGestureRecognizer() -> UIGestureRecognizer? {
        return longPressGestureRecognizer
    }

    /// Tellomi（交互审计 A-06，Q-05 = A）：菜单弹出时键盘在哪（窗口坐标）；键盘不动，菜单排在它上面。默认没有键盘。
    public func keyboardFrameInWindowAtPresentation() -> CGRect? {
        nil
    }

    public func menuAccessory(configuration: ContextMenuConfiguration, targetedPreview: ContextMenuTargetedPreview) -> ContextMenuActionsAccessory {

        var alignments: [(ContextMenuTargetedPreviewAccessory.AccessoryAlignment.Edge, ContextMenuTargetedPreviewAccessory.AccessoryAlignment.Origin)] = [(.bottom, .exterior)]

        switch targetedPreview.alignment {
        case .left:
            alignments.append((.leading, .interior))
        case .right:
            alignments.append((.trailing, .interior))
        case .center:
            break
        }

        let menu = configuration.actionProvider?([]) ?? ContextMenu([])
        let alignment = ContextMenuTargetedPreviewAccessory.AccessoryAlignment(alignments: alignments, alignmentOffset: targetedPreview.alignmentOffset ?? CGPoint(x: 0, y: 12))
        let accessory = ContextMenuActionsAccessory(menu: menu, accessoryAlignment: alignment, forceDarkTheme: configuration.forceDarkTheme)
        accessory.delegate = self
        return accessory
    }

    /// Tellomi（交互审计 A-06）：收起动画正在播。选项改在收起开始时执行之后，推新页面的选项（「详情」等）会让聊天页
    /// 在 `viewWillDisappear` 里马上再要一次不带动画的收起：那一次就地收尾，动画播完时不再重复 `didEnd`。
    private var isAnimatingOut = false
    private var pendingDismissalCompletions: [() -> Void] = []

    public func dismissMenu(animated: Bool, completion: @escaping () -> Void) {
        guard let configuration = self.configuration else {
            return
        }

        if isAnimatingOut {
            // 已经在收了：带动画的就等那一次收完；不带动画的就地收尾。
            pendingDismissalCompletions.append(completion)
            if !animated {
                finishAnimatedDismissal(configuration: configuration)
            }
            return
        }

        delegate?.contextMenuInteraction(self, willEndForConfiguration: configuration)

        if animated {
            guard let contextMenuController else {
                return
            }
            isAnimatingOut = true
            pendingDismissalCompletions.append(completion)
            contextMenuController.animateOut({ [weak contextMenuController] in
                // 已经被一次不带动画的收起提前收尾了。
                guard self.isAnimatingOut, self.contextMenuController === contextMenuController else {
                    return
                }
                self.finishAnimatedDismissal(configuration: configuration)
            })
        } else {
            targetedPreview?.view.isHidden = false
            targetedPreview?.auxiliaryView?.isHidden = false
            delegate?.contextMenuInteraction(self, didEndForConfiguration: configuration)
            self.contextMenuController?.view.removeFromSuperview()
            self.contextMenuController = nil
            completion()
        }
    }

    private func finishAnimatedDismissal(configuration: ContextMenuConfiguration) {
        isAnimatingOut = false
        targetedPreview?.view.isHidden = false
        targetedPreview?.auxiliaryView?.isHidden = false
        delegate?.contextMenuInteraction(self, didEndForConfiguration: configuration)
        contextMenuController?.view.removeFromSuperview()
        contextMenuController = nil
        let completions = pendingDismissalCompletions
        pendingDismissalCompletions = []
        completions.forEach { $0() }
    }

    // MARK: Private

    @objc
    private func longPressRecognized(sender: UIGestureRecognizer) {
        let locationInView = sender.location(in: self.view)
        switch sender.state {
        case .began:
            initiateContextMenuGesture(locationInView: locationInView, presentImmediately: false)
        case .changed:
            contextMenuController?.gestureDidChange()
        case .ended, .cancelled:
            contextMenuController?.gestureDidEnd()
            gestureEligibleForMenuPresentation = false
        default:
            break
        }
    }
}

extension ContextMenuInteraction: ContextMenuControllerDelegate, ContextMenuTargetedPreviewAccessoryInteractionDelegate {

    func contextMenuTargetedPreviewAccessoryRequestsDismissal(_ accessory: ContextMenuTargetedPreviewAccessory, completion: @escaping () -> Void) {
        dismissMenu(animated: true, completion: completion)
    }

    func contextMenuTargetedPreviewAccessoryPreviewAlignment(_ accessory: ContextMenuTargetedPreviewAccessory) -> ContextMenuTargetedPreview.Alignment {
        return contextMenuController?.contextMenuPreview.alignment ?? .center
    }

    func contextMenuControllerRequestsDismissal(_ contextMenuController: ContextMenuController) {
        dismissMenu(animated: true, completion: { })
    }

    func contextMenuTargetedPreviewAccessoryRequestsExpansion(_ accessory: ContextMenuTargetedPreviewAccessory) {
        contextMenuController?.expandAccessoryInPlace(accessory)
    }

    func contextMenuTargetedPreviewAccessoryRequestsReactionConfiguration(_ accessory: ContextMenuTargetedPreviewAccessory) {
        contextMenuController?.showReactionConfiguration()
    }

    func contextMenuTargetedPreviewAccessoryRequestsEmojiPicker(
        for message: TSMessage,
        accessory: ContextMenuTargetedPreviewAccessory,
        completion: @escaping (String) -> Void,
    ) {
        contextMenuController?.showEmojiSheet(message: message, completion: { emojiString in
            self.contextMenuController?.dismissEmojiSheet(animated: true, completion: {
                completion(emojiString)
            })
        })
    }

}

// Custom subclass for chat history CVC interactions
public class ChatHistoryContextMenuInteraction: ContextMenuInteraction {

    public let itemViewModel: CVItemViewModelImpl
    public let thread: TSThread
    public let messageActions: [MessageAction]
    public let keyboardWasActive: Bool
    /// Tellomi（交互审计 A-06，Q-05 = A）：长按时键盘在窗口里的位置；键盘不收，菜单排在它上面。
    public var keyboardFrameInWindow: CGRect?
    public let chatHistoryLongPressGesture: UIGestureRecognizer?
    public var contextMenuVisible: Bool {
        return contextMenuController != nil
    }

    /// Default initializer
    /// - Parameters:
    ///   - delegate: ContextMenuInteraction delegate
    ///   - itemViewModel: CVItemViewModelImpl related to context menu item
    ///   - messageActions: Message actions related to context menu item
    public init(
        delegate: ContextMenuInteractionDelegate,
        itemViewModel: CVItemViewModelImpl,
        thread: TSThread,
        messageActions: [MessageAction],
        initiatingGestureRecognizer: UIGestureRecognizer?,
        keyboardWasActive: Bool,
    ) {
        self.itemViewModel = itemViewModel
        self.thread = thread
        self.messageActions = messageActions
        self.keyboardWasActive = keyboardWasActive
        self.chatHistoryLongPressGesture = initiatingGestureRecognizer
        super.init(delegate: delegate)
    }

    override public func willMove(to view: UIView?) { }

    override public func didMove(to view: UIView?) {
        self.view = view
    }

    public func initiatingGestureRecognizerDidChange() {
        contextMenuController?.gestureDidChange()
    }

    public func initiatingGestureRecognizerDidEnd() {

        if contextMenuController == nil {
            cancelPresentationGesture()
        } else {
            contextMenuController?.gestureDidEnd()
        }

    }

    public func cancelPresentationGesture() {
        gestureEligibleForMenuPresentation = false

        if contextMenuController == nil, let configuration = self.configuration {
            delegate?.contextMenuInteraction(self, willEndForConfiguration: configuration)
            delegate?.contextMenuInteraction(self, didEndForConfiguration: configuration)
        }
    }

    override public func initiatingGestureRecognizer() -> UIGestureRecognizer? {
        return chatHistoryLongPressGesture
    }

    override public func keyboardFrameInWindowAtPresentation() -> CGRect? {
        keyboardFrameInWindow
    }

    override public func menuAccessory(configuration: ContextMenuConfiguration, targetedPreview: ContextMenuTargetedPreview) -> ContextMenuActionsAccessory {
        let isRTL = CurrentAppContext().isRTL
        let menu = configuration.actionProvider?([]) ?? ContextMenu([])
        let isIncomingMessage = itemViewModel.interaction.interactionType == .incomingMessage
        let isMessageType = itemViewModel.interaction.interactionType == .outgoingMessage || isIncomingMessage
        let horizontalEdgeAlignment: ContextMenuTargetedPreviewAccessory.AccessoryAlignment.Edge = isIncomingMessage ? (isRTL ? .trailing : .leading) : (isRTL ? .leading : .trailing)
        let alignment = ContextMenuTargetedPreviewAccessory.AccessoryAlignment(alignments: [(.bottom, .exterior), (horizontalEdgeAlignment, .interior)], alignmentOffset: CGPoint(x: 0, y: 12))
        let accessory = ContextMenuActionsAccessory(menu: menu, accessoryAlignment: alignment)
        let landscapeAlignmentOffset = isMessageType ? CGPoint(x: 12, y: 0) : alignment.alignmentOffset
        let horizontalLandscapeEdgeAlignment: ContextMenuTargetedPreviewAccessory.AccessoryAlignment.Edge = isIncomingMessage ? (isRTL ? .leading : .trailing) : (isRTL ? .trailing : .leading)
        accessory.landscapeAccessoryAlignment = ContextMenuTargetedPreviewAccessory.AccessoryAlignment(alignments: [isMessageType ? (.top, .interior) : (.bottom, .exterior), (horizontalLandscapeEdgeAlignment, .exterior)], alignmentOffset: landscapeAlignmentOffset)
        accessory.delegate = self
        return accessory
    }
}
