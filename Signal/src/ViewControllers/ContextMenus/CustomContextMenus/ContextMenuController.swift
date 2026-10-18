//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol ContextMenuControllerDelegate: AnyObject {
    func contextMenuControllerRequestsDismissal(_ contextMenuController: ContextMenuController)
}

private protocol ContextMenuViewDelegate: AnyObject {
    func contextMenuViewPreviewSourceFrame(_ contextMenuView: ContextMenuHostView) -> CGRect
    func contextMenuViewAuxPreviewSourceFrame(_ contextMenuView: ContextMenuHostView) -> CGRect
    func contextMenuViewAnimationState(_ contextMenuView: ContextMenuHostView) -> ContextMenuAnimationState
    func contextMenuViewPreviewFrameForAccessoryLayout(_ contextMenuView: ContextMenuHostView) -> CGRect
}

private enum ContextMenuAnimationState {
    case none
    case animateIn
    case animateOut
}

private class ContextMenuHostView: UIView {

    weak var delegate: ContextMenuViewDelegate?
    var previewViewAlignment: ContextMenuTargetedPreview.Alignment = .center

    /// Tellomi（交互审计 A-06）：键盘盖住宿主底部多少。菜单内容排在键盘上面（展开后的表情面板里搜索时键盘会起来）。
    var keyboardOverlap: CGFloat = 0
    /// Tellomi（交互审计 A-06）：往下拉了多少（已按 Telegram 的 0.35 阻力折算）。消息预览和菜单跟着往下走，回应条不动、往下长。
    var pullDistance: CGFloat = 0
    /// Tellomi（交互审计 A-06）：展开时锁定的面板上沿（收起时的上沿往上提 `expansionLift`）。
    var expandedAccessoryTop: CGFloat?

    private var contentAreaInsets: UIEdgeInsets {
        let minPadding: CGFloat = 8
        return UIEdgeInsets(
            top: max(safeAreaInsets.top, minPadding),
            leading: max(safeAreaInsets.leading, minPadding),
            bottom: max(safeAreaInsets.bottom, minPadding, keyboardOverlap + minPadding),
            trailing: max(safeAreaInsets.trailing, minPadding),
        )
    }

    var blurView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let view = blurView {
                addSubview(view)
            }
        }
    }

    var previewView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let view = previewView {
                addSubview(view)
            }
        }
    }

    var auxiliaryPreviewView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let view = auxiliaryPreviewView {
                addSubview(view)
            }
        }
    }

    var accessoryViews: [ContextMenuTargetedPreviewAccessory]? {
        didSet {
            if let oldAccessoryViews = oldValue {
                for oldAccessory in oldAccessoryViews {
                    oldAccessory.accessoryView.removeFromSuperview()
                }
            }

            if let newAccessoryViews = accessoryViews {
                for accessory in newAccessoryViews {
                    addSubview(accessory.accessoryView)
                }
            }
        }
    }

    var dismissButton: UIButton? {
        didSet {
            oldValue?.removeFromSuperview()
            if let dismissButton {
                addSubview(dismissButton)
            }
        }
    }

    lazy var previewSourceFrame: CGRect = delegate?.contextMenuViewPreviewSourceFrame(self) ?? CGRect.zero
    lazy var auxPreviewSourceFrame: CGRect = delegate?.contextMenuViewAuxPreviewSourceFrame(self) ?? CGRect.zero

    private let minPreviewScaleFactor: CGFloat = 0.1

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView?.frame = bounds
        dismissButton?.frame = bounds

        let animationState = delegate?.contextMenuViewAnimationState(self) ?? .none
        if let expandedAccessory = accessoryViews?.first(where: \.isExpandedInPlace) {
            layoutExpanded(expandedAccessory, animationState: animationState)
            return
        }
        var auxVerticalOffset: CGFloat = 0
        if let previewView = self.previewView {
            // Let the controller manage the preview's frame if animating
            if animationState != .animateOut {
                previewView.frame = targetPreviewFrame().offsetBy(dx: 0, dy: pullDistance)
            }

            if let auxView = auxiliaryPreviewView {
                auxView.sizeToFit()
                auxView.frame = targetAuxiliaryPreviewFrame(previewFrame: previewView.frame)
                auxVerticalOffset = max(auxView.frame.maxY - previewView.frame.maxY, 0)
            }
        }

        if let accessories = accessoryViews {
            var accessoryFrames: [CGRect] = []
            for accessory in accessories {

                let animationState = delegate?.contextMenuViewAnimationState(self) ?? .none
                guard !(accessory.animateAccessoryPresentationAlongsidePreview && animationState == .animateOut) else {
                    if let targetFrame = accessory.targetAnimateOutFrame, accessory.accessoryView.frame.size == CGSize.zero {
                        accessory.accessoryView.frame = targetFrame
                    }
                    continue
                }

                layoutAccessoryView(accessory, auxVerticalOffset: auxVerticalOffset)

                var frame = accessory.accessoryView.frame

                // Check for accessory view intersects
                for accessoryFrame in accessoryFrames {
                    if accessoryFrame != frame, frame.intersects(accessoryFrame) {
                        // We have an intersect! Only handling vertical intersects for now
                        if frame.y < accessoryFrame.maxY {
                            frame.y += accessoryFrame.maxY - frame.y + 12
                        }

                        // Shrink accessory view if needed
                        let contentBounds = bounds.inset(by: contentAreaInsets)
                        if frame.maxY > contentBounds.maxY {
                            frame.size.height -= frame.maxY - contentBounds.maxY
                        }

                        accessory.accessoryView.frame = frame
                        break
                    }
                }

                accessoryFrames.append(frame)
                accessory.accessoryDidLayout(previewFrame: delegate?.contextMenuViewPreviewFrameForAccessoryLayout(self) ?? .zero)
            }
        }

    }

    /// Tellomi（交互审计 A-06）：回应条原地展开成全部表情之后的摆法（照 Telegram）：面板锁在收起时的上沿往上提一段，
    /// 高 ≤ 300、夹在内容区里；消息预览原大接在面板下面 7 pt（放不下就出到屏幕外）；别的附件跟着预览走、由控制器藏起来。
    private func layoutExpanded(_ expandedAccessory: ContextMenuTargetedPreviewAccessory, animationState: ContextMenuAnimationState) {
        // 收起时由控制器接管预览；面板原地淡出，不再排。
        guard animationState != .animateOut else { return }

        let contentRect = bounds.inset(by: contentAreaInsets)
        let panelHeight = min(expandedAccessory.expandedHeight(availableHeight: contentRect.height), contentRect.height)
        var panelFrame = expandedAccessory.accessoryView.frame
        let lockedTop = expandedAccessoryTop ?? panelFrame.minY
        panelFrame.origin.y = min(max(lockedTop, contentRect.minY), contentRect.maxY - panelHeight)
        panelFrame.size.height = panelHeight
        expandedAccessory.accessoryView.frame = panelFrame

        var auxVerticalOffset: CGFloat = 0
        if let previewView {
            var previewFrame = previewView.frame
            previewFrame.origin.y = panelFrame.maxY + TellomiReactionBarLayout.gapAboveMessage
            previewView.frame = previewFrame
            if let auxView = auxiliaryPreviewView {
                auxView.frame = targetAuxiliaryPreviewFrame(previewFrame: previewFrame)
                auxVerticalOffset = max(auxView.frame.maxY - previewFrame.maxY, 0)
            }
        }
        for accessory in accessoryViews ?? [] where accessory !== expandedAccessory {
            layoutAccessoryView(accessory, auxVerticalOffset: auxVerticalOffset)
        }
    }

    private func targetPreviewFrame() -> CGRect {
        var previewFrame = previewSourceFrame
        let auxPreviewFrame = auxPreviewSourceFrame
        let auxVerticalOffset = max(auxPreviewFrame.maxY - previewSourceFrame.maxY, 0)
        let contentRect = bounds.inset(by: contentAreaInsets)

        // Check for Y-offset shift first, aligning to bottom accessory
        let horizontallyFittedAccessories = accessoryViews?.filter(\.shrinksPreviewToFitHorizontally)
        let minX: CGFloat = horizontallyFittedAccessories?.map { accessoryFrame($0, previewFrame: previewFrame, auxVerticalOffset: auxVerticalOffset).x }.min() ?? 0
        let maxX: CGFloat = horizontallyFittedAccessories?.map { accessoryFrame($0, previewFrame: previewFrame, auxVerticalOffset: auxVerticalOffset).maxX }.max() ?? 0
        var minY: CGFloat = accessoryViews?.map { accessoryFrame($0, previewFrame: previewFrame, auxVerticalOffset: auxVerticalOffset).y }.min() ?? 0
        var maxY: CGFloat = accessoryViews?.map { accessoryFrame($0, previewFrame: previewFrame, auxVerticalOffset: auxVerticalOffset).maxY }.max() ?? 0
        minY = min(minY, previewFrame.minY)
        maxY = max(maxY, previewFrame.maxY)

        // Vertically shift if necessary
        if maxY > contentRect.maxY {
            let adjust = maxY - contentRect.maxY
            previewFrame.y -= adjust
            minY -= adjust
            maxY -= adjust
        }

        if minY < contentRect.minY {
            let adjust = contentRect.minY - minY
            previewFrame.y += adjust
            minY += adjust
            maxY += adjust
        }

        // Check if preview needs to be shrunk to to fit vertical accessories
        let contentHeight = maxY - minY
        var previewWidthAdjustment: CGFloat = 0
        if contentHeight > contentRect.height {
            let delta = contentHeight - contentRect.height
            let targetHeight = previewFrame.height - delta
            let scaleFactor = max(targetHeight / previewFrame.height, minPreviewScaleFactor)
            if previewViewAlignment == .right {
                let oldWidth = previewFrame.width
                previewFrame.size = CGSize.scale(previewFrame.size, factor: scaleFactor)
                previewFrame.origin.x += oldWidth - previewFrame.width
                previewWidthAdjustment = oldWidth - previewFrame.width
            } else {
                previewFrame.size = CGSize.scale(previewFrame.size, factor: scaleFactor)
            }
        }

        // Check if preview needs to be shrunk to fit horizontal accessories
        let contentWidth = maxX - minX - previewWidthAdjustment
        if contentWidth > contentRect.width {
            let delta = contentWidth - contentRect.width
            let targetWidth = previewFrame.width - delta
            let scaleFactor = max(targetWidth / previewFrame.width, minPreviewScaleFactor)
            if previewViewAlignment == .right {
                let oldWidth = previewFrame.width
                previewFrame.size = CGSize.scale(previewFrame.size, factor: scaleFactor)
                previewFrame.origin.x += oldWidth - previewFrame.width
            } else {
                previewFrame.size = CGSize.scale(previewFrame.size, factor: scaleFactor)
            }
        }

        return previewFrame
    }

    private func targetAuxiliaryPreviewFrame(previewFrame: CGRect) -> CGRect {
        guard let auxView = auxiliaryPreviewView else {
            return CGRect.zero
        }

        let auxSourceFrame = auxPreviewSourceFrame
        let previewSourceFrame = previewSourceFrame
        let scaleFactor = previewFrame.width / previewSourceFrame.width
        let originOffset = CGPoint.scale(CGPoint.subtract(auxSourceFrame.origin, previewSourceFrame.origin), factor: scaleFactor)
        var frame = auxView.frame
        frame.origin = CGPoint.add(originOffset, previewFrame.origin)
        frame.size = CGSize.scale(auxSourceFrame.size, factor: scaleFactor)
        return frame
    }

    private func accessoryFrame(_ accessory: ContextMenuTargetedPreviewAccessory, previewFrame: CGRect, auxVerticalOffset: CGFloat) -> CGRect {
        var accessoryFrame = CGRect.zero
        accessory.accessoryView.sizeToFit()
        accessoryFrame.size = accessory.accessoryView.frame.size

        let isLandscape = UIDevice.current.isIPad ? false : bounds.size.width > bounds.size.height

        let defaultAlignments = accessory.accessoryAlignment.alignments
        let alignments = isLandscape ? accessory.landscapeAccessoryAlignment?.alignments ?? defaultAlignments : defaultAlignments

        let defaultOffset = accessory.accessoryAlignment.alignmentOffset
        let offset = isLandscape ? accessory.landscapeAccessoryAlignment?.alignmentOffset ?? defaultOffset : defaultOffset

        let offsetPreviewFrame: CGRect = {
            let offsetFrame = previewFrame.insetBy(dx: -offset.x, dy: -offset.y)

            guard !offsetFrame.isNull else {
                owsFailBeta("Had null offset preview frame! Would insetting the preview frame by the offset produce a rectangle with negative size? \(previewFrame), \(offset)")
                return previewFrame
            }

            return offsetFrame
        }()

        for (edgeAlignment, originAlignment) in alignments {
            switch (edgeAlignment, originAlignment) {
            case (.top, .exterior):
                accessoryFrame.y = offsetPreviewFrame.y - accessoryFrame.height
            case (.top, .interior):
                accessoryFrame.y = offsetPreviewFrame.y
            case (.trailing, .exterior):
                accessoryFrame.x = offsetPreviewFrame.maxX
            case (.trailing, .interior):
                accessoryFrame.x = offsetPreviewFrame.maxX - accessoryFrame.width
            case (.leading, .exterior):
                accessoryFrame.x = offsetPreviewFrame.x - accessoryFrame.width
            case (.leading, .interior):
                accessoryFrame.x = offsetPreviewFrame.x
            case (.bottom, .exterior):
                accessoryFrame.y = offsetPreviewFrame.maxY
                accessoryFrame.y += auxVerticalOffset
            case (.bottom, .interior):
                accessoryFrame.y = offsetPreviewFrame.maxY - accessoryFrame.height
            }
        }

        if previewViewAlignment == .center {
            accessoryFrame.x = offsetPreviewFrame.midX - (accessoryFrame.width / 2)
        }

        return accessoryFrame
    }

    private func adjustAccessoryFrameForContentRect(_ accessoryFrame: CGRect, extraHorizontalInset: CGFloat) -> CGRect {
        var updatedFrame = accessoryFrame
        // Adjust accessory horizontal/vertical overlap if needed
        let contentRect = bounds.inset(by: contentAreaInsets).insetBy(dx: extraHorizontalInset, dy: 0)
        if accessoryFrame.maxY > contentRect.maxY {
            let adjust = accessoryFrame.maxY - contentRect.maxY
            updatedFrame.y -= adjust
        }

        if accessoryFrame.maxX > contentRect.maxX {
            let adjust = contentRect.maxX - accessoryFrame.maxX
            updatedFrame.x += adjust
        }
        if accessoryFrame.minX < contentRect.minX {
            let adjust = contentRect.minX - accessoryFrame.minX
            updatedFrame.x += adjust
        }

        return updatedFrame
    }

    private func layoutAccessoryView(_ accessory: ContextMenuTargetedPreviewAccessory, auxVerticalOffset: CGFloat) {
        var previewFrame = delegate?.contextMenuViewPreviewFrameForAccessoryLayout(self) ?? CGRect.zero
        // Tellomi（A-06）：往下拉的时候回应条不跟着走（它自己往下长）。
        if accessory.canExpandInPlace {
            previewFrame.origin.y -= pullDistance
        }

        let accessoryFrame = accessoryFrame(accessory, previewFrame: previewFrame, auxVerticalOffset: auxVerticalOffset)
        let adjustedAccessoryFrame = adjustAccessoryFrameForContentRect(accessoryFrame, extraHorizontalInset: accessory.extraHorizontalInset)

        accessory.accessoryView.frame = adjustedAccessoryFrame
    }
}

class ContextMenuController: OWSViewController, ContextMenuViewDelegate, UIGestureRecognizerDelegate {
    weak var delegate: ContextMenuControllerDelegate?

    let contextMenuPreview: ContextMenuTargetedPreview
    let contextMenuConfiguration: ContextMenuConfiguration
    let menuAccessory: ContextMenuActionsAccessory?

    var previewView: UIView? {
        if let hostView = view as? ContextMenuHostView {
            return hostView.previewView
        }

        return nil
    }

    var auxiliaryPreviewView: UIView? {
        if let hostView = view as? ContextMenuHostView {
            return hostView.auxiliaryPreviewView
        }

        return nil
    }

    var gestureRecognizer: UIGestureRecognizer?
    var localPanGestureRecoginzer: UIPanGestureRecognizer?

    private let presentImmediately: Bool
    /// Tellomi（交互审计 A-06）：按压时消息缩到的比例；预览从这个大小放回原大。
    private let pressedScale: CGFloat
    /// Tellomi（交互审计 A-06，Q-05 = A）：弹出时键盘的位置（窗口坐标），菜单内容排在它上面。
    var initialKeyboardFrameInWindow: CGRect?
    private let renderBackgroundBlur: Bool

    enum PreviewRenderMode {
        case shadow
        case fade
    }

    private let previewRenderMode: PreviewRenderMode

    private var gestureExitedDeadZone: Bool = false
    private let deadZoneRadius: CGFloat = 40
    private var initialTouchLocation: CGPoint?

    private var animationState: ContextMenuAnimationState = .none
    private var animateOutPreviewFrame = CGRect.zero
    /// Tellomi（交互审计 A-07 起飞时机）：收起开始的时刻，和收起时预览该飞向的真气泡（见 [tellomiRetargetDismissal]）。
    private var tellomiAnimateOutStart: CFTimeInterval?
    private weak var tellomiPreviewTarget: UIView?
    private let animationDuration = 0.4
    private let springDamping: CGFloat = 0.8
    // Tellomi（tellomi/tellomi 交互审计 A-06）：收起从 0.4 s 缩到 0.25 s——菜单项要等收起播完才执行，
    // 0.4 s 的等待在手感上就是「点了半天才动」。减弱动态效果时不缩放、不回弹。
    private let animateOutDuration: TimeInterval = 0.25
    private var reduceMotion: Bool { TellomiMotion.isReduceMotionEnabled }
    private var effectiveSpringDamping: CGFloat { reduceMotion ? 1 : springDamping }
    private let springInitialVelocity: CGFloat = 1.0

    private let dismissButton = UIButton(type: .custom)

    private var previewShadowVisible = false {
        didSet {
            if #available(iOS 26, *) {
                return
            }
            self.previewView?.layer.shadowOpacity = previewShadowVisible ? 0.3 : 0
        }
    }

    var accessoryViews: [ContextMenuTargetedPreviewAccessory] {
        var accessories = contextMenuPreview.accessoryViews
        if let menuAccessory = self.menuAccessory {
            accessories.append(menuAccessory)
        }
        return accessories
    }

    lazy var blurView: UIVisualEffectView = {
        return UIVisualEffectView(effect: nil)
    }()

    private var emojiPickerSheet: EmojiPickerSheet?

    init(
        configuration: ContextMenuConfiguration,
        preview: ContextMenuTargetedPreview,
        initiatingGestureRecognizer: UIGestureRecognizer?,
        menuAccessory: ContextMenuActionsAccessory?,
        presentImmediately: Bool = true,
        pressedScale: CGFloat = 0.95,
        renderBackgroundBlur: Bool = true,
        previewRenderMode: PreviewRenderMode = .shadow,
    ) {
        self.contextMenuConfiguration = configuration
        self.contextMenuPreview = preview
        self.gestureRecognizer = initiatingGestureRecognizer
        self.menuAccessory = menuAccessory
        self.presentImmediately = presentImmediately
        self.pressedScale = pressedScale
        self.renderBackgroundBlur = renderBackgroundBlur
        self.previewRenderMode = previewRenderMode
        super.init()
        if configuration.forceDarkTheme { overrideUserInterfaceStyle = .dark }
    }

    // MARK: UIViewController

    override func loadView() {
        let contextMenuView = ContextMenuHostView(frame: CGRect.zero)
        contextMenuView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contextMenuView.delegate = self
        contextMenuView.previewViewAlignment = contextMenuPreview.alignment
        view = contextMenuView

        view.accessibilityViewIsModal = true

        dismissButton.isAccessibilityElement = true
        dismissButton.accessibilityLabel = OWSLocalizedString("DISMISS_CONTEXT_MENU", comment: "Dismiss context menu accessibility label")
        dismissButton.addAction(
            UIAction { [weak self] _ in self?.dismissButtonTapped() },
            for: .primaryActionTriggered,
        )
        contextMenuView.blurView = blurView
        contextMenuView.dismissButton = dismissButton
        contextMenuView.previewView = contextMenuPreview.previewView
        contextMenuView.previewView?.isAccessibilityElement = true
        contextMenuView.previewView?.accessibilityLabel = OWSLocalizedString("MESSAGE_PREVIEW", comment: "Context menu message preview accessibility label")
        contextMenuView.auxiliaryPreviewView = contextMenuPreview.auxiliarySnapshot
        contextMenuView.auxiliaryPreviewView?.isAccessibilityElement = false
        contextMenuView.accessoryViews = accessoryViews

        self.previewView?.isUserInteractionEnabled = false
        self.previewView?.isHidden = true
        self.previewView?.layer.shadowRadius = 12
        self.previewView?.layer.shadowOffset = CGSize(width: 0, height: 4)
        self.previewView?.layer.shadowColor = UIColor.black.cgColor
        self.previewView?.layer.shadowOpacity = 0

        self.auxiliaryPreviewView?.isHidden = true

        for accessory in accessoryViews {
            if accessory.animateAccessoryPresentationAlongsidePreview {
                accessory.accessoryView.isHidden = true
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
        )
    }

    private func dismissButtonTapped() {
        delegate?.contextMenuControllerRequestsDismissal(self)
    }

    private lazy var presentedSize = view.bounds.size
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()

        guard let superview = view.superview, presentedSize != superview.bounds.size else { return }

        emojiPickerSheet?.dismiss(animated: true)
        delegate?.contextMenuControllerRequestsDismissal(self)

        // TODO: Support orientation changes.
        // We can't use `viewWillTransition(to:with:)` here because we're added directly to the window
    }

    override func themeDidChange() {
        super.themeDidChange()
        delegate?.contextMenuControllerRequestsDismissal(self)

        // TODO: Support theme changes
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard let previewView else {
            owsFailDebug("Cannot animate without preview view!")
            return
        }

        animationState = .animateIn

        UIView.animate(withDuration: animationDuration / 2.0) {
            if self.renderBackgroundBlur {
                if !UIDevice.current.isIPad {
                    self.blurView.effect = UIBlurEffect(style: UIBlurEffect.Style.regular)
                    self.blurView.backgroundColor = UIColor(
                        light: UIColor(white: 0, alpha: 0.2),
                        dark: UIColor(white: 1, alpha: 0.2),
                    )
                } else {
                    self.blurView.backgroundColor = UIColor.black.withAlphaComponent(0.4)
                }
            }

            switch self.previewRenderMode {
            case .shadow:
                self.previewShadowVisible = true
            case .fade:
                self.previewView?.alpha = 0.5
            }
        }

        let finalFrame = previewView.frame
        let initialFrame = previewSourceFrame()
        let shiftPreview = finalFrame != initialFrame

        // Match initial transform
        if !presentImmediately, !reduceMotion {
            previewView.transform = CGAffineTransform.scale(pressedScale)
        }

        previewView.isHidden = false
        auxiliaryPreviewView?.isHidden = false

        for accessory in accessoryViews {
            if accessory.animateAccessoryPresentationAlongsidePreview {
                accessory.accessoryView.isHidden = false
            }
        }
        contextMenuPreview.view.isHidden = true
        contextMenuPreview.auxiliaryView?.isHidden = true

        if shiftPreview {
            previewView.frame = initialFrame

            let finalAuxFrame = auxiliaryPreviewView?.frame ?? CGRect.zero
            auxiliaryPreviewView?.frame = auxPreviewSourceFrame()

            let yDelta = finalFrame.y - initialFrame.y
            let heightDelta = finalFrame.height - initialFrame.height
            for accessory in accessoryViews {
                if accessory.animateAccessoryPresentationAlongsidePreview {
                    accessory.accessoryView.frame.y -= (yDelta + heightDelta)
                }
            }

            UIView.animate(
                withDuration: animationDuration,
                delay: 0,
                usingSpringWithDamping: effectiveSpringDamping,
                initialSpringVelocity: springInitialVelocity,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: {
                    for accessory in self.accessoryViews {
                        if accessory.animateAccessoryPresentationAlongsidePreview {
                            accessory.accessoryView.frame.y += (yDelta + heightDelta)
                        }
                    }
                    self.previewView?.frame = finalFrame
                    self.previewView?.transform = CGAffineTransform.identity

                    self.auxiliaryPreviewView?.frame = finalAuxFrame
                },
            ) { _ in
                self.animationState = .none
                UIAccessibility.post(notification: .layoutChanged, argument: self.dismissButton)
            }
        } else {
            // Re-scale to match original size, on the original scaling curve
            UIView.animate(
                withDuration: 0.3,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: {
                    self.previewView?.transform = CGAffineTransform.identity
                },
                completion: nil,
            )
        }

        // Animate in accessories
        for accessory in accessoryViews {
            accessory.animateIn(duration: animationDuration, previewWillShift: shiftPreview) { }
        }
    }

    // MARK: Public

    func animateOut(_ completion: @escaping () -> Void) {

        guard let previewView else {
            owsFailDebug("Cannot animate without preview view!")
            completion()
            return
        }

        let dispatchGroup = DispatchGroup()
        animationState = .animateOut
        tellomiAnimateOutStart = CACurrentMediaTime()

        dispatchGroup.enter()
        UIView.animate(withDuration: animateOutDuration) {
            if self.renderBackgroundBlur {
                self.blurView.effect = nil
                self.blurView.backgroundColor = nil
            }

            switch self.previewRenderMode {
            case .shadow:
                self.previewShadowVisible = false
            case .fade:
                self.previewView?.alpha = 1
            }
        } completion: { _ in
            dispatchGroup.leave()
        }

        let tellomiFrames = tellomiDismissalFrames()
        let finalFrame = tellomiFrames?.preview ?? previewSourceFrame()
        let initialFrame = previewView.frame
        animateOutPreviewFrame = initialFrame
        let shiftPreview = finalFrame != initialFrame
        if shiftPreview {

            let yDelta = finalFrame.y - initialFrame.y
            let heightDelta = finalFrame.height - initialFrame.height
            dispatchGroup.enter()
            UIView.animate(
                withDuration: animateOutDuration,
                delay: 0,
                usingSpringWithDamping: 1,
                initialSpringVelocity: springInitialVelocity,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: {
                    for accessory in self.accessoryViews {
                        if accessory.animateAccessoryPresentationAlongsidePreview {
                            var frame = accessory.accessoryView.frame
                            frame.y += (yDelta + heightDelta)
                            accessory.accessoryView.frame = frame
                            accessory.targetAnimateOutFrame = frame
                        }
                    }
                    self.previewView?.frame = finalFrame
                    self.auxiliaryPreviewView?.frame = tellomiFrames?.auxiliary ?? self.auxPreviewSourceFrame()
                },
                completion: { _ in
                    dispatchGroup.leave()
                },
            )
        }

        // Animate in accessories
        for accessory in accessoryViews {
            dispatchGroup.enter()
            accessory.animateOut(duration: animateOutDuration, previewWillShift: shiftPreview) {
                dispatchGroup.leave()
            }
        }

        dispatchGroup.notify(queue: .main) {
            self.contextMenuPreview.view.isHidden = false
            self.contextMenuPreview.auxiliaryView?.isHidden = false
            self.animationState = .none
            completion()
        }
    }

    /// Tellomi（交互审计 A-07 起飞时机，Telegram 两端一选回应就飞、和菜单收起同时）：选了回应以后，菜单收起期间聊天列表就落了
    /// 这条回应，真消息可能被新胶囊挤到了别处，或者换了一个格子（`reloadItems` 会给它新的 cell，原来那格的位置就不算数了）。
    /// 预览改飞向 [previewTarget]（这条消息此刻的气泡）：正在收的，再叠一段动画到新位置、和收起同时结束（UIKit 的动画是叠加的，
    /// 原来那段照常跑完、照常收尾）；还没开始收的，开始时直接用它。回应区快照跟着气泡走（见 [tellomiDismissalFrames]）。
    func tellomiRetargetDismissal(previewTo previewTarget: UIView) {
        tellomiPreviewTarget = previewTarget
        guard animationState == .animateOut, let start = tellomiAnimateOutStart, let frames = tellomiDismissalFrames() else {
            return
        }
        let remaining = max(0.05, animateOutDuration - (CACurrentMediaTime() - start))
        UIView.animate(withDuration: remaining, delay: 0, options: [.curveEaseOut]) {
            if self.previewView?.frame != frames.preview {
                self.previewView?.frame = frames.preview
            }
            if let auxiliary = frames.auxiliary, self.auxiliaryPreviewView?.frame != auxiliary {
                self.auxiliaryPreviewView?.frame = auxiliary
            }
        }
    }

    /// 收起时预览和回应区快照该落到哪（菜单坐标）：预览落在 [tellomiPreviewTarget] 上、原大（菜单里缩小过的也放回原大）；
    /// 回应区快照和气泡的相对位置照长按那一刻（回应区排在气泡下方，对方的消息靠气泡右边、自己的靠左边，跟着气泡走）。
    /// 目标不在视图树里就没有，照原来的位置收。
    private func tellomiDismissalFrames() -> (preview: CGRect, auxiliary: CGRect?)? {
        guard let target = tellomiPreviewTarget, let superview = target.superview, target.window != nil else {
            return nil
        }
        let preview = view.convert(target.frame, from: superview)
        guard auxiliaryPreviewView != nil, let hostView = view as? ContextMenuHostView else {
            return (preview, nil)
        }
        let offset = CGPoint.subtract(hostView.auxPreviewSourceFrame.origin, hostView.previewSourceFrame.origin)
        return (preview, CGRect(origin: CGPoint.add(preview.origin, offset), size: hostView.auxPreviewSourceFrame.size))
    }

    // MARK: Gesture Recognizer Support

    func gestureDidChange() {
        guard !UIAccessibility.isVoiceOverRunning else {
            return
        }

        if let locationInView = gestureRecognizer?.location(in: view) {

            if !gestureExitedDeadZone {
                guard let initialTouchLocation = self.initialTouchLocation else {
                    self.initialTouchLocation = locationInView
                    return
                }

                let distanceFromInitialLocation = abs(hypot(
                    locationInView.x - initialTouchLocation.x,
                    locationInView.y - initialTouchLocation.y,
                ))
                gestureExitedDeadZone = distanceFromInitialLocation >= deadZoneRadius

                if !gestureExitedDeadZone { return }
            }

            for accessory in accessoryViews {
                let locationInAccessory = view.convert(locationInView, to: accessory.accessoryView)
                accessory.touchLocationInViewDidChange(locationInView: locationInAccessory)
            }
        }

    }

    func gestureDidEnd() {
        guard !UIAccessibility.isVoiceOverRunning else {
            return
        }

        handleGestureEnd()
    }

    private func handleGestureEnd() {
        if localPanGestureRecoginzer == nil {
            if let gestureRecognizer = self.gestureRecognizer {
                view.removeGestureRecognizer(gestureRecognizer)
            }

            let newPanGesture = UIPanGestureRecognizer(target: self, action: #selector(panGestureRecognized(sender:)))
            view.addGestureRecognizer(newPanGesture)
            gestureRecognizer = newPanGesture
            localPanGestureRecoginzer = newPanGesture
        }

        if !gestureExitedDeadZone { return }

        var accessoryHandledTouch = false
        if let locationInView = gestureRecognizer?.location(in: view) {
            for accessory in accessoryViews {
                let locationInAccessory = view.convert(locationInView, to: accessory.accessoryView)
                let handled = accessory.touchLocationInViewDidEnd(locationInView: locationInAccessory)
                if !accessoryHandledTouch {
                    accessoryHandledTouch = handled
                }
            }
        }

        if !accessoryHandledTouch {
            delegate?.contextMenuControllerRequestsDismissal(self)
            return
        }
    }

    // MARK: Emoji Sheet

    func showEmojiSheet(message: TSMessage, completion: @escaping (String) -> Void) {
        let picker = EmojiPickerSheet(message: message) { [weak self] emoji in
            guard let self else { return }

            guard let emojiString = emoji?.rawValue else {
                self.delegate?.contextMenuControllerRequestsDismissal(self)
                return
            }

            completion(emojiString)
        }
        emojiPickerSheet = picker
        present(picker, animated: true)
    }

    func dismissEmojiSheet(animated: Bool, completion: @escaping () -> Void) {
        emojiPickerSheet?.dismiss(animated: true, completion: completion)
    }

    // MARK: ContextMenuViewDelegate

    fileprivate func contextMenuViewPreviewSourceFrame(_ contextMenuView: ContextMenuHostView) -> CGRect {
        return previewSourceFrame()
    }

    fileprivate func contextMenuViewAuxPreviewSourceFrame(_ contextMenuView: ContextMenuHostView) -> CGRect {
        return auxPreviewSourceFrame()
    }

    fileprivate func contextMenuViewAnimationState(_ contextMenuView: ContextMenuHostView) -> ContextMenuAnimationState {
        return animationState
    }

    fileprivate func contextMenuViewPreviewFrameForAccessoryLayout(_ contextMenuView: ContextMenuHostView) -> CGRect {
        if animationState == .animateOut {
            return animateOutPreviewFrame
        }

        return previewView?.frame ?? CGRect.zero
    }

    // MARK: Private

    private func previewSourceFrame() -> CGRect {
        return view.convert(contextMenuPreview.previewViewSourceFrame, from: contextMenuPreview.view.superview)
    }

    private func auxPreviewSourceFrame() -> CGRect {
        guard let auxPreview = contextMenuPreview.auxiliaryView else {
            return CGRect.zero
        }

        return view.convert(auxPreview.frame, from: auxPreview.superview)
    }

    @objc
    private func panGestureRecognized(sender: UIGestureRecognizer) {
        if sender.state == .began, let pan = sender as? UIPanGestureRecognizer, shouldBeginPull(at: pan.location(in: view)) {
            isPulling = true
        }
        if isPulling, let pan = sender as? UIPanGestureRecognizer {
            handlePull(pan)
            return
        }

        if sender.state == .began || sender.state == .changed {
            gestureDidChange()
        } else if sender.state == .ended {
            handleGestureEnd()
        }
    }

    // MARK: Tellomi（交互审计 A-06）：往下拉 / 点 ⌄ 原地展开成全部表情

    /// 往下拉多远（折算后）就展开：Telegram 是 30。
    static let pullToExpandThreshold: CGFloat = 30
    /// 手指位移折算成内容位移：Telegram 顶部过度滚动的阻力 0.35。
    static let pullResistance: CGFloat = 0.35

    private var isPulling = false

    private var expandableAccessory: ContextMenuTargetedPreviewAccessory? {
        accessoryViews.first { $0.canExpandInPlace && !$0.isExpandedInPlace }
    }

    /// 从空白处、消息预览上起手才算「往下拉」；从回应条、菜单上起手还是按住滑选。
    private func shouldBeginPull(at location: CGPoint) -> Bool {
        guard expandableAccessory != nil, animationState != .animateOut else { return false }
        return !accessoryViews.contains { accessory in
            !accessory.accessoryView.isHidden && accessory.accessoryView.alpha > 0 && accessory.accessoryView.frame.contains(location)
        }
    }

    private func handlePull(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began, .changed:
            let distance = Self.pulledDistance(fingerTranslation: pan.translation(in: view).y)
            if distance > Self.pullToExpandThreshold, let accessory = expandableAccessory {
                isPulling = false
                // 停掉这次拖动；展开动画从拉长的样子接着走。
                pan.isEnabled = false
                pan.isEnabled = true
                expandAccessoryInPlace(accessory)
            } else {
                setPullDistance(distance, animated: false)
            }
        default:
            // 没拉到：弹回去，菜单不收。
            isPulling = false
            setPullDistance(0, animated: true)
        }
    }

    /// 手指往下 [fingerTranslation] 点时内容往下多少；往上不算。
    static func pulledDistance(fingerTranslation: CGFloat) -> CGFloat {
        max(0, fingerTranslation) * pullResistance
    }

    func setPullDistance(_ distance: CGFloat, animated: Bool) {
        guard let hostView = view as? ContextMenuHostView else { return }
        let apply = {
            hostView.pullDistance = distance
            self.expandableAccessory?.updatePullDistance(distance)
            hostView.setNeedsLayout()
            hostView.layoutIfNeeded()
        }
        if animated {
            TellomiMotion.animator(TellomiMotion.release, animations: apply).startAnimation()
        } else {
            apply()
        }
    }

    func expandAccessoryInPlace(_ accessory: ContextMenuTargetedPreviewAccessory) {
        guard
            accessory.canExpandInPlace,
            !accessory.isExpandedInPlace,
            animationState != .animateOut,
            let hostView = view as? ContextMenuHostView
        else {
            return
        }

        hostView.expandedAccessoryTop = accessory.accessoryView.frame.minY - accessory.expansionLift
        accessory.willExpandInPlace()
        accessory.isExpandedInPlace = true
        // 展开后菜单里的拖动交给表情网格滚动。
        localPanGestureRecoginzer?.isEnabled = false
        ImpactHapticFeedback.impactOccurred(style: .light)

        let otherAccessories = accessoryViews.filter { $0 !== accessory }
        for other in otherAccessories {
            other.accessoryView.isUserInteractionEnabled = false
        }
        let changes = {
            hostView.pullDistance = 0
            accessory.updatePullDistance(0)
            hostView.setNeedsLayout()
            hostView.layoutIfNeeded()
            for other in otherAccessories {
                other.accessoryView.alpha = 0
            }
        }
        if reduceMotion {
            UIView.transition(with: hostView, duration: TellomiMotion.reducedMotionCrossfadeDuration, options: [.transitionCrossDissolve, .allowUserInteraction], animations: changes)
        } else {
            TellomiMotion.animator(TellomiMotion.reactionPanelExpand, animations: changes).startAnimation()
        }
        accessory.didStartExpansionAnimation()
        UIAccessibility.post(notification: .layoutChanged, argument: accessory.accessoryView)
    }

    func showReactionConfiguration() {
        let configVC = EmojiReactionPickerConfigViewController(reactionPickerConfigurationListener: nil)
        let navController = UINavigationController(rootViewController: configVC)
        if contextMenuConfiguration.forceDarkTheme {
            navController.overrideUserInterfaceStyle = .dark
        }
        present(navController, animated: true)
    }

    /// 菜单铺满窗口之后由 `ContextMenuInteraction` 调：长按时键盘就在（Q-05 = A，不收键盘），内容先排在它上面。
    func applyInitialKeyboardFrame() {
        guard let hostView = view as? ContextMenuHostView, let keyboardFrame = initialKeyboardFrameInWindow else { return }
        hostView.keyboardOverlap = Self.keyboardOverlap(keyboardFrame: view.convert(keyboardFrame, from: nil), in: view.bounds)
        hostView.setNeedsLayout()
    }

    /// 键盘盖住 [bounds] 底部多少；键盘不在屏幕上（落到底下）就是 0。
    static func keyboardOverlap(keyboardFrame: CGRect, in bounds: CGRect) -> CGFloat {
        guard !keyboardFrame.isEmpty, keyboardFrame.minY < bounds.maxY else { return 0 }
        return max(0, bounds.maxY - keyboardFrame.minY)
    }

    /// 键盘起落（展开面板里搜索）：内容区底边让到键盘上面，跟键盘同一条曲线。
    @objc
    private func keyboardWillChangeFrame(_ notification: Notification) {
        guard
            let hostView = view as? ContextMenuHostView,
            let window = view.window,
            let endFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else {
            return
        }
        let endFrameInView = view.convert(endFrame, from: window.screen.coordinateSpace)
        let overlap = Self.keyboardOverlap(keyboardFrame: endFrameInView, in: view.bounds)
        guard overlap != hostView.keyboardOverlap else { return }
        hostView.keyboardOverlap = overlap

        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, UIView.AnimationOptions(rawValue: curve << 16)]) {
            hostView.setNeedsLayout()
            hostView.layoutIfNeeded()
        }
    }

}
