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
        guard let message = itemViewModel?.interaction as? TSMessage else {
            owsFailDebug("Not sending reaction for unexpected interaction type")
            return
        }

        reactionPicker.playDismissalAnimation(duration: TellomiReactionBarLayout.dismissDuration) { }

        self.delegate?.contextMenuTargetedPreviewAccessoryRequestsEmojiPicker(for: message, accessory: self) { emojiString in
            let isRemoving = emojiString == self.itemViewModel?.reactionState?.localUserEmoji
            self.didSelectReactionHandler?(message, emojiString, isRemoving, nil)
            self.delegate?.contextMenuTargetedPreviewAccessoryRequestsDismissal(self, completion: { })
        }
    }
}
