//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SignalUI
import UIKit

public class CVAccessibilityCustomAction: UIAccessibilityCustomAction {
    public var messageAction: MessageAction?
}

extension ConversationViewController: UIGestureRecognizerDelegate {
    func configureGestureRecognizersIfNeeded() {
        guard !collectionViewGestureRecongnizersConfigured else { return }

        collectionViewTapGestureRecognizer.setTapDelegate(self)
        collectionViewTapGestureRecognizer.delegate = self
        collectionView.addGestureRecognizer(collectionViewTapGestureRecognizer)

        collectionViewLongPressGestureRecognizer.addTarget(self, action: #selector(handleLongPressGesture))
        collectionViewLongPressGestureRecognizer.delegate = self
        collectionView.addGestureRecognizer(collectionViewLongPressGestureRecognizer)

        collectionViewContextMenuGestureRecognizer.addTarget(self, action: #selector(handleLongPressGesture))
        collectionViewContextMenuGestureRecognizer.minimumPressDuration = 0.2
        collectionViewContextMenuGestureRecognizer.delegate = self
        collectionView.addGestureRecognizer(collectionViewContextMenuGestureRecognizer)

        collectionViewContextMenuSecondaryClickRecognizer.addTarget(self, action: #selector(handleSecondaryClickGesture))
        collectionViewContextMenuSecondaryClickRecognizer.buttonMaskRequired = [.secondary]
        collectionViewContextMenuSecondaryClickRecognizer.delegate = self
        collectionView.addGestureRecognizer(collectionViewContextMenuSecondaryClickRecognizer)

        collectionViewPanGestureRecognizer.addTarget(self, action: #selector(handlePanGesture))
        collectionViewPanGestureRecognizer.delegate = self
        collectionView.addGestureRecognizer(collectionViewPanGestureRecognizer)

        collectionViewTapGestureRecognizer.require(toFail: collectionViewPanGestureRecognizer)
        collectionViewTapGestureRecognizer.require(toFail: collectionViewLongPressGestureRecognizer)

        tellomiConfigurePressFeedback()
        tellomiConfigureDragSelect()

        // Allow panning with trackpad
        collectionViewPanGestureRecognizer.allowedScrollTypesMask = .continuous

        // There are cases where we don't have a navigation controller, such as if we got here through 3d touch.
        // Make sure we only register the gesture interaction if it actually exists. This helps the swipe back
        // gesture work reliably without conflict with audio scrubbing or swipe-to-repy.
        if let interactivePopGestureRecognizer = navigationController?.interactivePopGestureRecognizer {
            collectionViewPanGestureRecognizer.require(toFail: interactivePopGestureRecognizer)
        }

        collectionViewGestureRecongnizersConfigured = true
    }

    // TODO: Revisit
    private func cellAtPoint(_ point: CGPoint) -> CVCell? {
        guard
            let indexPath = collectionView.indexPathForItem(at: point),
            let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        return cell as? CVCell
    }

    private func cellForInteractionId(_ interactionId: String) -> CVCell? {
        // TODO: Won't this build a new cell in some cases?
        guard
            let indexPath = indexPath(forInteractionUniqueId: interactionId),
            let cell = collectionView.cellForItem(at: indexPath) else { return nil }
        return cell as? CVCell
    }

    // MARK: - UIGestureRecognizerDelegate

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !isShowingSelectionUI else {
            return gestureRecognizer == collectionViewTapGestureRecognizer
        }

        if gestureRecognizer == collectionViewPanGestureRecognizer {
            // Only allow the pan gesture to recognize horizontal panning,
            // to avoid conflicts with the conversation view scroll view.
            let translation = collectionViewPanGestureRecognizer.translation(in: view)
            return Self.tellomiShouldBeginMessagePan(
                translation: translation,
                isRTL: CurrentAppContext().isRTL,
                isScrubbingAudio: findPanHandler(sender: collectionViewPanGestureRecognizer)?.panType == .scrubAudio,
            )
        } else {
            return true
        }
    }

    /// Tellomi（tellomi/tellomi#1109）：回复改成手指从右往左滑（RTL 镜像）。往右的横滑除了拖语音进度，一律不接，
    /// 让给系统返回（iOS 26 在内容上右滑也是返回；owner 2026-09-25 否掉过一版挡住右滑返回的横滑）。
    static func tellomiShouldBeginMessagePan(translation: CGPoint, isRTL: Bool, isScrubbingAudio: Bool) -> Bool {
        guard abs(translation.x) > abs(translation.y) else {
            return false
        }
        if isScrubbingAudio {
            return true
        }
        return isRTL ? translation.x > 0 : translation.x < 0
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if
            #available(iOS 26, *),
            otherGestureRecognizer == navigationController?.interactiveContentPopGestureRecognizer,
            let panGestureRecognizer = gestureRecognizer as? UIPanGestureRecognizer,
            self.findPanHandler(sender: panGestureRecognizer) == nil
        {
            // Allow content pop gesture if there is no pan handler
            return true
        }

        // Support standard long press recognizing for body text cases, and context menu long press recognizing for everything else
        let currentIsLongPressOrTap = (gestureRecognizer == collectionViewLongPressGestureRecognizer || gestureRecognizer == collectionViewContextMenuGestureRecognizer || gestureRecognizer == collectionViewTapGestureRecognizer)
        let otherIsLongPressOrTap = (otherGestureRecognizer == collectionViewLongPressGestureRecognizer || otherGestureRecognizer == collectionViewContextMenuGestureRecognizer || otherGestureRecognizer == collectionViewTapGestureRecognizer)
        return currentIsLongPressOrTap && otherIsLongPressOrTap
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive event: UIEvent) -> Bool {
        if collectionViewContextMenuSecondaryClickRecognizer == gestureRecognizer {
            return event.buttonMask == .secondary
        }

        return true
    }

    // MARK: -

    private func findCell(forGesture sender: UIGestureRecognizer) -> CVCell? {
        // Collection view is a scroll view; we want to ignore
        // cells that are scrolled offscreen.  So we first check
        // that the collection view contains the gesture location.
        guard collectionView.containsGestureLocation(sender) else {
            return nil
        }

        for cell in collectionView.visibleCells {
            guard let cell = cell as? CVCell else {
                owsFailDebug("Invalid cell")
                continue
            }
            guard cell.containsGestureLocation(sender) else {
                continue
            }
            return cell
        }
        return nil
    }
}

extension ConversationViewController: SingleOrDoubleTapGestureDelegate {

    // MARK: - Tap

    public func handleSingleTap(_ sender: SingleOrDoubleTapGestureRecognizer) -> Bool {
        // Stop any recording voice memos.
        finishRecordingVoiceMessage(sendImmediately: false)

        guard let cell = findCell(forGesture: sender) else {
            return false
        }

        if let interaction = collectionViewActiveContextMenuInteraction, interaction.contextMenuVisible {
            return false
        }

        return cell.handleTap(sender: sender, componentDelegate: self)
    }

    public func handleDoubleTap(_ sender: SingleOrDoubleTapGestureRecognizer) -> Bool {
        guard let cell = findCell(forGesture: sender) else {
            return false
        }
        guard cell.canHandleDoubleTap(sender: sender, componentDelegate: self) else {
            return false
        }

        return cell.handleDoubleTap(sender: sender, componentDelegate: self)
    }

    public func didEndGesture(_ sender: SingleOrDoubleTapGestureRecognizer, wasHandled: Bool) {
        if !wasHandled {
            dismissKeyBoard()
        }
    }
}

extension ConversationViewController {

    // MARK: - Long Press

    @objc
    func handleLongPressGesture(_ sender: UILongPressGestureRecognizer) {
        // Tellomi（交互审计 A-09）：长按拿起整条消息，菜单里的预览是此刻的快照，按下的缩放立刻还原、不带进去
        if sender.state == .began {
            viewState.tellomiPressFeedback?.cancel(animated: false)
        }

        let resetLongPress = {
            self.longPressHandler = nil
            sender.isEnabled = false
            sender.isEnabled = true
        }

        switch sender.state {
        case .began:
            guard let longPressHandler = findLongPressHandler(sender: sender) else {
                resetLongPress()
                return
            }
            self.longPressHandler = longPressHandler
        case .changed:
            self.longPressHandler?.handleLongPress(sender)
        case .ended, .failed, .cancelled, .possible:
            self.longPressHandler?.handleLongPress(sender)
            resetLongPress()
        @unknown default:
            owsFailDebug("Invalid state.")
        }
    }

    @objc
    func handleSecondaryClickGesture(_ sender: UITapGestureRecognizer) {
        guard let cell = findCell(forGesture: sender) else {
            return
        }
        guard
            let longPressHandler = cell.findLongPressHandler(
                sender: sender,
                componentDelegate: self,
            )
        else {
            return
        }

        longPressHandler.startContextMenuGesture(cell: cell)
    }

    private func findLongPressHandler(sender: UILongPressGestureRecognizer) -> CVLongPressHandler? {
        guard let cell = findCell(forGesture: sender) else {
            return nil
        }
        guard
            let longPressHandler = cell.findLongPressHandler(
                sender: sender,
                componentDelegate: self,
            )
        else {
            return nil
        }
        if sender == collectionViewContextMenuGestureRecognizer {
            longPressHandler.startContextMenuGesture(cell: cell)
        } else {
            longPressHandler.startGesture(cell: cell)
        }
        return longPressHandler
    }

    // MARK: - Pan

    @objc
    func handlePanGesture(_ sender: UIPanGestureRecognizer) {
        let resetPan = {
            self.panHandler = nil
            sender.isEnabled = false
            sender.isEnabled = true
        }

        let updatePanGesture = {
            guard let panHandler = self.panHandler else {
                return
            }
            // The pan needs to operate on the current cell for this interaction.
            guard let cell = self.cellForInteractionId(panHandler.interactionId) else {
                owsFailDebug("No cell for pan.")
                resetPan()
                return
            }
            let messageSwipeActionState = self.viewState.messageSwipeActionState
            panHandler.handlePan(
                sender: sender,
                cell: cell,
                messageSwipeActionState: messageSwipeActionState,
            )
        }

        switch sender.state {
        case .began:
            guard let panHandler = findPanHandler(sender: sender) else {
                resetPan()
                return
            }
            self.panHandler = panHandler
            startPanHandler(sender: sender)
        case .changed:
            updatePanGesture()
        case .ended, .failed, .cancelled, .possible:
            updatePanGesture()
            resetPan()
        @unknown default:
            owsFailDebug("Invalid state.")
        }
    }

    private func findPanHandler(sender: UIPanGestureRecognizer) -> CVPanHandler? {
        guard let cell = findCell(forGesture: sender) else {
            return nil
        }
        let messageSwipeActionState = viewState.messageSwipeActionState
        guard
            let panHandler = cell.findPanHandler(
                sender: sender,
                componentDelegate: self,
                messageSwipeActionState: messageSwipeActionState,
            )
        else {
            return nil
        }
        return panHandler
    }

    private func startPanHandler(sender: UIPanGestureRecognizer) {
        guard let panHandler else { return }
        guard let cell = findCell(forGesture: sender) else { return }
        panHandler.startGesture(sender: sender, cell: cell, messageSwipeActionState: viewState.messageSwipeActionState)
    }
}

// MARK: -

public struct CVLongPressHandler {
    private weak var delegate: CVComponentDelegate?
    let renderItem: CVRenderItem
    let itemViewModel: CVItemViewModelImpl

    enum GestureLocation {
        case `default`
        case media
        case sticker
        case quotedReply
        case systemMessage
        case paymentMessage
        case poll
        case bodyText(item: CVTextLabel.Item)
        case associatedSubcomponent
    }

    let gestureLocation: GestureLocation

    init(
        delegate: CVComponentDelegate,
        renderItem: CVRenderItem,
        gestureLocation: GestureLocation,
    ) {
        self.delegate = delegate
        self.renderItem = renderItem
        self.gestureLocation = gestureLocation

        // TODO: shouldAutoUpdate?
        self.itemViewModel = CVItemViewModelImpl(renderItem: renderItem)
    }

    func startContextMenuGesture(cell: CVCell) {
        guard let delegate = self.delegate else {
            owsFailDebug("Missing delegate.")
            return
        }

        let shouldAllowMessageSendActions = delegate.shouldAllowMessageSendActionsForItem(itemViewModel)

        switch gestureLocation {
        case .`default`:
            delegate.didLongPressTextViewItem(
                cell,
                itemViewModel: itemViewModel,
                shouldAllowMessageSendActions: shouldAllowMessageSendActions,
            )
        case .media:
            delegate.didLongPressMediaViewItem(
                cell,
                itemViewModel: itemViewModel,
                shouldAllowMessageSendActions: shouldAllowMessageSendActions,
            )
        case .sticker:
            delegate.didLongPressSticker(
                cell,
                itemViewModel: itemViewModel,
                shouldAllowMessageSendActions: shouldAllowMessageSendActions,
            )
        case .quotedReply:
            delegate.didLongPressQuote(
                cell,
                itemViewModel: itemViewModel,
                shouldAllowMessageSendActions: shouldAllowMessageSendActions,
            )
        case .systemMessage:
            delegate.didLongPressSystemMessage(cell, itemViewModel: itemViewModel)
        case .paymentMessage:
            delegate.didLongPressPaymentMessage(cell, itemViewModel: itemViewModel, shouldAllowMessageSendActions: shouldAllowMessageSendActions)
        case .poll:
            delegate.didLongPressPoll(cell, itemViewModel: itemViewModel, shouldAllowMessageSendActions: shouldAllowMessageSendActions)
        case .bodyText:
            break
        case .associatedSubcomponent:
            // Bottom buttons, labels, and footers are considered separate subcomponents,
            // but may be associated with another subcomponent type.
            if let message = itemViewModel.interaction as? TSMessage, message.isPoll {
                delegate.didLongPressPoll(cell, itemViewModel: itemViewModel, shouldAllowMessageSendActions: shouldAllowMessageSendActions)
                return
            }
            // Default
            delegate.didLongPressTextViewItem(
                cell,
                itemViewModel: itemViewModel,
                shouldAllowMessageSendActions: shouldAllowMessageSendActions,
            )
        }
    }

    func startGesture(cell: CVCell) {
        guard let delegate = self.delegate else {
            owsFailDebug("Missing delegate.")
            return
        }

        switch gestureLocation {
        case .bodyText(let item):
            delegate.didLongPressBodyTextItem(item)
        default:
            // Case will be handled by context menu gesture recognizer
            break
        }
    }

    func handleLongPress(_ sender: UILongPressGestureRecognizer) {
        guard let delegate = self.delegate else {
            owsFailDebug("Missing delegate.")
            return
        }

        switch sender.state {
        case .began:
            // We use startGesture(cell:) to start handling the gesture.
            owsFailDebug("Unexpected state.")
        case .changed:
            delegate.didChangeLongPress(itemViewModel)
        case .ended:
            delegate.didEndLongPress(itemViewModel)
        case .failed, .cancelled:
            delegate.didCancelLongPress(itemViewModel)
        case .possible:
            owsFailDebug("Unexpected state.")
        @unknown default:
            owsFailDebug("Invalid state.")
        }
    }
}

// MARK: -

public class CVPanHandler {
    public enum PanType {
        case messageSwipeAction
        case scrubAudio
    }

    public let panType: PanType

    private weak var delegate: CVComponentDelegate?
    private let renderItem: CVRenderItem

    public var interactionId: String { renderItem.interactionUniqueId }

    // If the gesture ended now, would we perform a reply?
    public enum ActiveDirection {
        case left
        case right
        case none
    }

    public var activeDirection: ActiveDirection = .none
    var messageDetailViewController: MessageDetailViewController?

    public var percentDrivenTransition: UIPercentDrivenInteractiveTransition?

    init(delegate: CVComponentDelegate, panType: PanType, renderItem: CVRenderItem) {
        self.delegate = delegate
        self.panType = panType
        self.renderItem = renderItem
    }

    func startGesture(
        sender: UIPanGestureRecognizer,
        cell: CVCell,
        messageSwipeActionState: CVMessageSwipeActionState,
    ) {
        guard let delegate = self.delegate else {
            owsFailDebug("Missing delegate.")
            return
        }

        // When the gesture starts, the "reference" of the initial
        // view positions should already be set, but the progress
        // should not yet be set.
        owsAssertDebug(messageSwipeActionState.getProgress(interactionId: interactionId) == nil)

        cell.startPanGesture(
            sender: sender,
            panHandler: self,
            componentDelegate: delegate,
            messageSwipeActionState: messageSwipeActionState,
        )

        if panType == .messageSwipeAction {
            owsAssertDebug(messageSwipeActionState.getProgress(interactionId: interactionId) != nil)
        }
    }

    func handlePan(
        sender: UIPanGestureRecognizer,
        cell: CVCell,
        messageSwipeActionState: CVMessageSwipeActionState,
    ) {
        guard let delegate = self.delegate else {
            owsFailDebug("Missing delegate.")
            return
        }

        if panType == .messageSwipeAction {
            owsAssertDebug(messageSwipeActionState.getProgress(interactionId: interactionId) != nil)
        }
        cell.handlePanGesture(
            sender: sender,
            panHandler: self,
            componentDelegate: delegate,
            messageSwipeActionState: messageSwipeActionState,
        )
    }
}

// MARK: - Tellomi：按下即缩（交互审计 A-09）

extension ConversationViewController {

    /// 引用、文件、联系人卡、回应胶囊一按下就缩一下（`TellomiPressFeedback`），不用等抬手。只观察触摸的手势挂在列表上，
    /// 不和点击 / 长按 / 滑动 / 滚动抢：别的手势一认出来它就被挤掉、弹回。
    func tellomiConfigurePressFeedback() {
        let feedback = viewState.tellomiPressFeedback ?? TellomiPressFeedback()
        viewState.tellomiPressFeedback = feedback
        let observer = viewState.tellomiPressTouchObserver
        observer.onBegan = { [weak self, weak observer] touch in
            guard let self, let observer, !self.isShowingSelectionUI else {
                return
            }
            let point = observer.location(in: self.collectionView)
            guard let cell = self.collectionView.indexPathForItem(at: point).flatMap({ self.collectionView.cellForItem(at: $0) }) as? CVCell else {
                return
            }
            if let target = cell.tellomiPressTarget(sender: observer) {
                feedback.press(target, at: touch.location(in: target.view), pointInWindow: touch.location(in: nil))
            } else if let pressed = cell.tellomiPressedTextItem(sender: observer) {
                // 正文里的链接 / 提及：按下即高亮（原来点完才闪 0.25 s）
                feedback.pressText(label: pressed.label, item: pressed.item, pointInWindow: touch.location(in: nil))
            }
        }
        observer.onMoved = { touch in
            feedback.moved(toWindowPoint: touch.location(in: nil))
        }
        observer.onEnded = {
            feedback.release()
        }
        collectionView.addGestureRecognizer(observer)
    }
}
