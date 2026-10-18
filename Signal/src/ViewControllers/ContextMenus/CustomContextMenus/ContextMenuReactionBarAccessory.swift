//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
import SignalUI
import UIKit

public class ContextMenuReactionBarAccessory: ContextMenuTargetedPreviewAccessory, MessageReactionPickerDelegate {
    public let thread: TSThread
    public let itemViewModel: CVItemViewModelImpl?
    /// (message, reaction, isRemoving, flyInSource)。Tellomi（交互审计 A-07）加了第四个参数：回应飞入的起点，不飞时是 nil。
    var didSelectReactionHandler: ((TSMessage, String, Bool, ReactionFlyIn.Source?) -> Void)?

    /// Tellomi（交互审计 A-06，owner 2026-10-17）：长按消息用照 Telegram 做的回应条；上游 `MessageReactionPicker`
    /// 还留给「回应设置」和通话。
    private var reactionPicker: TellomiReactionBar
    private let selectedEmoji: String?
    private var highlightHoverGestureRecognizer: UIGestureRecognizer?
    private var highlightClickGestureRecognizer: UIGestureRecognizer?

    /// 悬停后点击（触控板 / 鼠标）才走 `hoverClickGestureRecognized`；手指点按由表情的 UIControl 自己接。
    static let pointerClickTouchTypes: [NSNumber] = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]

    public init(
        thread: TSThread,
        itemViewModel: CVItemViewModelImpl?,
    ) {
        self.thread = thread
        self.itemViewModel = itemViewModel

        // 条上的表情都是规范化过的写法，我的回应也换成同一种写法再比。
        let selectedEmoji = itemViewModel?.reactionState?.localUserEmoji.flatMap { EmojiWithSkinTones(rawValue: $0)?.rawValue }
        self.selectedEmoji = selectedEmoji
        reactionPicker = TellomiReactionBar(
            emojis: Self.reactionBarEmojis(selectedEmoji: selectedEmoji),
            selectedEmoji: selectedEmoji,
            delegate: nil,
        )
        // Telegram 的摆法：消息在左半边，条的右边缘 = 消息右边缘 + 22；在右半边，条的左边缘 = 消息左边缘 − 26；
        // 条的下沿离消息上沿 7 pt（尾巴挂在这 7 pt 里，贴着消息朝外的那个角）。
        let isRTL = CurrentAppContext().isRTL
        let isIncomingMessage = itemViewModel?.interaction.interactionType == .incomingMessage
        let isMessageOnLeft = isIncomingMessage != isRTL
        let horizontalEdgeAlignment: ContextMenuTargetedPreviewAccessory.AccessoryAlignment.Edge = isMessageOnLeft ? .trailing : .leading
        let alignment = ContextMenuTargetedPreviewAccessory.AccessoryAlignment(
            alignments: [(.top, .exterior), (horizontalEdgeAlignment, .interior)],
            alignmentOffset: CGPoint(
                x: isMessageOnLeft ? TellomiReactionBarLayout.overhangWhenMessageOnLeft : TellomiReactionBarLayout.overhangWhenMessageOnRight,
                y: TellomiReactionBarLayout.gapAboveMessage,
            ),
        )
        super.init(accessoryView: reactionPicker, accessoryAlignment: alignment)
        extraHorizontalInset = TellomiReactionBarLayout.screenEdgeInset - 8
        shrinksPreviewToFitHorizontally = false
        reactionPicker.delegate = self
        reactionPicker.isHidden = true

        let highlightHoverGestureRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(hoverGestureRecognized(sender:)))
        reactionPicker.addGestureRecognizer(highlightHoverGestureRecognizer)
        self.highlightHoverGestureRecognizer = highlightHoverGestureRecognizer

        let highlightClickGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(hoverClickGestureRecognized(sender:)))
        highlightClickGestureRecognizer.buttonMaskRequired = [.primary]
        // Tellomi：这个手势只接触控板 / 鼠标的点击（点下悬停选中的那个表情）。手指点按交给条上的表情自己处理：上游的表情是
        // UIButton，系统让按钮优先于父视图的单击手势；回应条照 Telegram 重做以后（Signal-iOS#276）表情是自定义 UIControl，
        // 没有这个优先，于是这个手势把每一下手指点按都吃掉，而手指点按没有悬停选中的表情，什么也不做——表情和展开键都点不动
        // （owner 2026-10-18 真机）。
        highlightClickGestureRecognizer.allowedTouchTypes = Self.pointerClickTouchTypes
        reactionPicker.addGestureRecognizer(highlightClickGestureRecognizer)
        self.highlightClickGestureRecognizer = highlightClickGestureRecognizer
    }

    /// 用户选的 6 个（缺的用 Signal 默认补，和上游一样）+ 显示时补的第 7 个（`TellomiReactionBarSlots`）。
    private static func reactionBarEmojis(selectedEmoji: String?) -> [String] {
        func normalized(_ emoji: String) -> String? {
            EmojiWithSkinTones(rawValue: emoji)?.rawValue
        }
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            let customSet = ReactionManager.customEmojiSet(transaction: tx) ?? []
            let saved = ReactionManager.defaultEmojiSet.enumerated().compactMap { index, defaultEmoji in
                customSet[safe: index].flatMap(normalized) ?? normalized(defaultEmoji)
            }
            return TellomiReactionBarSlots.make(
                saved: saved,
                selected: selectedEmoji,
                signalDefaults: ReactionManager.defaultEmojiSet.compactMap(normalized),
                recents: EmojiPickerCollectionView.getRecentEmoji(tx: tx).map(\.rawValue),
            )
        }
    }

    override func animateIn(
        duration: TimeInterval,
        previewWillShift: Bool,
        completion: @escaping () -> Void,
    ) {
        let animateIn = {
            self.reactionPicker.isHidden = false
            self.reactionPicker.playPresentationAnimation()
            completion()

        }
        if previewWillShift {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { animateIn() }
        } else {
            animateIn()
        }

    }

    override func animateOut(
        duration: TimeInterval,
        previewWillShift: Bool,
        completion: @escaping () -> Void,
    ) {
        // Telegram 的回应条收起是 0.2 s 淡出，比菜单的 0.25 s 收起略快。
        reactionPicker.playDismissalAnimation(duration: TellomiReactionBarLayout.dismissDuration, completion: completion)
    }

    override func accessoryDidLayout(previewFrame: CGRect) {
        reactionPicker.updateAnchor(messageFrameInSuperview: previewFrame)
    }

    // MARK: 原地展开（交互审计 A-06，照 Telegram：点 ⌄ 或往下拉，条就地长成全部表情）

    private var message: TSMessage? { itemViewModel?.interaction as? TSMessage }

    /// 展开不需要消息（面板里「这条消息」那一组是空的）；只有选中写回应时才要。
    override var canExpandInPlace: Bool { true }

    override var expansionLift: CGFloat { TellomiReactionBarLayout.expandedPanelLift }

    override func expandedHeight(availableHeight: CGFloat) -> CGFloat {
        min(TellomiReactionBarLayout.expandedPanelMaxHeight, availableHeight)
    }

    override func updatePullDistance(_ distance: CGFloat) {
        reactionPicker.setPullDistance(distance)
    }

    override func willExpandInPlace() {
        let panel = TellomiReactionPanel(message: message)
        panel.onSelect = { [weak self] emoji, source in
            self?.didSelectExpandedReaction(emoji.rawValue, flyInSource: source)
        }
        panel.onConfigure = { [weak self] in
            guard let self else { return }
            self.delegate?.contextMenuTargetedPreviewAccessoryRequestsReactionConfiguration(self)
        }
        reactionPicker.prepareExpansion(panel: panel)
    }

    override func didStartExpansionAnimation() {
        reactionPicker.playExpansionFades()
    }

    /// 在展开的面板里选了一个：和条上一样，先写回应（表情从网格那一格飞进胶囊），再收起。
    private func didSelectExpandedReaction(_ emoji: String, flyInSource: ReactionFlyIn.Source?) {
        guard let message else {
            owsFailDebug("Not sending reaction for unexpected interaction type")
            return
        }
        let isRemoving = emoji == selectedEmoji
        let reduceMotion = MainActor.assumeIsolated { TellomiMotion.isReduceMotionEnabled }
        didSelectReactionHandler?(message, emoji, isRemoving, isRemoving || reduceMotion ? nil : flyInSource)
        reactionPicker.playDismissalAnimation(duration: TellomiReactionBarLayout.dismissDuration) {
            self.delegate?.contextMenuTargetedPreviewAccessoryRequestsDismissal(self, completion: { })
        }
    }

    @objc
    private func hoverGestureRecognized(sender: UIGestureRecognizer) {
        reactionPicker.updateFocusPosition(sender.location(in: reactionPicker), animated: true)
    }

    @objc
    private func hoverClickGestureRecognized(sender: UIGestureRecognizer) {
        touchLocationInViewDidEnd(locationInView: sender.location(in: reactionPicker))
    }

    override func touchLocationInViewDidChange(locationInView: CGPoint) {
        reactionPicker.updateFocusPosition(locationInView, animated: true)
    }

    @discardableResult
    override func touchLocationInViewDidEnd(locationInView: CGPoint) -> Bool {
        // Send focused emoji if needed
        if let focusedEmoji = reactionPicker.focusedSlot {
            switch focusedEmoji {
            case .expand:
                didSelectShowFullEmojiPicker()
            case .emoji(let emoji):
                let isRemoving = emoji == selectedEmoji
                if let index = reactionPicker.currentEmojiSet().firstIndex(of: emoji) {
                    // Tellomi（交互审计 A-07）：按住滑到表情上松手，和点按一样给一下触感。
                    ImpactHapticFeedback.impactOccurred(style: .light)
                    didSelectReaction(reaction: emoji, isRemoving: isRemoving, inPosition: index)
                }
            }
            return true
        }

        return false
    }

    // MARK: MessageReactionPickerDelegate

    func didSelectReaction(
        reaction: String,
        isRemoving: Bool,
        inPosition position: Int,
    ) {
        guard let message = itemViewModel?.interaction as? TSMessage else {
            owsFailDebug("Not sending reaction for unexpected interaction type")
            return
        }

        // Tellomi（交互审计 A-07）：选中的表情从条上飞到消息的回应胶囊上；撤回回应、减弱动态效果时不飞。
        let reduceMotion = MainActor.assumeIsolated { TellomiMotion.isReduceMotionEnabled }
        let flyInSource = isRemoving || reduceMotion ? nil : reactionPicker.takeEmojiForFlyIn(at: position)

        // Tellomi（交互审计 A-07）：先写回应、再收起，不等回应条的 0.2 s 淡出播完。
        didSelectReactionHandler?(message, reaction, isRemoving, flyInSource)
        reactionPicker.playDismissalAnimation(duration: TellomiReactionBarLayout.dismissDuration) {
            self.delegate?.contextMenuTargetedPreviewAccessoryRequestsDismissal(self, completion: { })
        }
    }

    func didSelectShowFullEmojiPicker() {
        // Tellomi（交互审计 A-06）：不再另弹表情 Sheet，条原地展开。
        delegate?.contextMenuTargetedPreviewAccessoryRequestsExpansion(self)
    }
}
