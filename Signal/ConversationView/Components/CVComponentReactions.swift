//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SignalUI

public class CVComponentReactions: CVComponentBase, CVComponent, CVAccessibilityComponent {

    public var componentKey: CVComponentKey { .reactions }

    private let reactions: CVComponentState.Reactions
    private var reactionState: InteractionReactionState {
        reactions.reactionState
    }

    private var viewState: CVReactionCountsView.State {
        reactions.viewState
    }

    init(
        itemModel: CVItemModel,
        reactions: CVComponentState.Reactions,
    ) {
        self.reactions = reactions

        super.init(itemModel: itemModel)
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewReactions()
    }

    public func configureForRendering(
        componentView componentViewParam: CVComponentView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) {
        guard let componentView = componentViewParam as? CVComponentViewReactions else {
            owsFailDebug("Unexpected componentView.")
            componentViewParam.reset()
            return
        }

        let reactionCountsView = componentView.reactionCountsView
        // Tellomi（交互审计 A-07）：同一条消息的回应变了才动；换行时各行朝屏幕中间那一侧对齐（和整排的摆法一样）。
        reactionCountsView.configure(
            state: viewState,
            cellMeasurement: cellMeasurement,
            messageId: interaction.uniqueId,
            alignRowsRight: (interaction is TSIncomingMessage) != CurrentAppContext().isRTL,
        )
    }

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        return CVReactionCountsView.measure(
            state: viewState,
            maxWidth: maxWidth,
            measurementBuilder: measurementBuilder,
        )
    }

    /// Tellomi（交互审计 A-07）：在 [maxWidth] 内换行后整排有多高。
    func measuredHeight(maxWidth: CGFloat) -> CGFloat {
        CVReactionCountsView.measuredHeight(state: viewState, maxWidth: maxWidth)
    }

    // MARK: - Events

    override public func handleTap(
        sender: UIGestureRecognizer,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem,
    ) -> Bool {

        guard let message = interaction as? TSMessage else {
            owsFailDebug("Invalid interaction.")
            return false
        }
        componentDelegate.didTapReactions(reactionState: reactionState, message: message)
        return true
    }

    // MARK: - Accessibility

    public var accessibilityDescription: String {
        var fullString = ""

        for pill in viewState.pills {
            let string = String.localizedStringWithFormat(
                OWSLocalizedString(
                    "MESSAGE_REACTIONS_ACCESSIBILITY_LABEL_%d",
                    tableName: "PluralAware",
                    comment: "Accessibility label reading out a reaction to a message and its count. Embeds {{ count }} and {{ emoji name }}.",
                ),
                pill.count,
                pill.emoji,
            )
            fullString.append(string)
            fullString.append(" ")
        }

        return fullString
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    public class CVComponentViewReactions: NSObject, CVComponentView {

        fileprivate let reactionCountsView = CVReactionCountsView()

        public var isDedicatedCellView = false

        public var rootView: UIView {
            reactionCountsView
        }

        public func setIsCellVisible(_ isCellVisible: Bool) {}

        public func reset() {
            reactionCountsView.reset()
        }

        /// Tellomi（交互审计 A-07）：回应飞入的落点。
        func emojiLabel(for emoji: String) -> UILabel? {
            reactionCountsView.emojiLabel(for: emoji)
        }

    }
}
