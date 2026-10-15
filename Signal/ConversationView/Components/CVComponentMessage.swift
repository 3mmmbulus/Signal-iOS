//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import Foundation
public import SignalServiceKit
public import SignalUI
import UIKit

public class CVComponentMessage: CVComponentBase, CVRootComponent {

    public var componentKey: CVComponentKey { .messageRoot }

    public static let selectionAnimationDuration: TimeInterval = 0.2

    public var cellReuseIdentifier: CVCellReuseIdentifier {
        .`default`
    }

    public var isDedicatedCell: Bool { false }

    private var bodyText: CVComponent?

    private var bodyMedia: CVComponent?

    private var senderName: CVComponent?

    private var senderAvatar: CVComponentState.SenderAvatar?
    private var hasSenderAvatarLayout: Bool {
        // Return true if space for a sender avatar appears in the layout.
        // Avatar itself might not appear due to de-duplication.
        isIncoming && isGroupThread && senderAvatar != nil && conversationStyle.type != .messageDetails
    }

    private var hasSenderAvatar: Bool {
        // Return true if a sender avatar appears.
        hasSenderAvatarLayout && itemViewState.shouldShowSenderAvatar
    }

    // This is the "standalone" footer, as opposed to
    // a footer overlaid over body media.
    private var standaloneFooter: CVComponentFooter?

    private var sticker: CVComponent?

    private var viewOnce: CVComponent?

    private var quotedReply: CVComponent?

    private var linkPreview: CVComponent?

    private var giftBadge: CVComponent?

    private var reactions: CVComponent?

    private var audioAttachment: CVComponent?

    private var genericAttachment: CVComponent?

    private var paymentAttachment: CVComponent?

    private var archivedPaymentAttachment: CVComponent?

    private var undownloadableAttachment: CVComponent?

    private var contactShare: CVComponent?

    private var bottomButtons: CVComponent?

    private var poll: CVComponent?

    private var bottomLabel: CVComponent?

    private var swipeActionProgress: CVMessageSwipeActionState.Progress?

    private var hasSendFailureBadge = false

    override init(itemModel: CVItemModel) {
        super.init(itemModel: itemModel)

        buildComponentStates()
    }

    var sharpCorners: OWSDirectionalRectCorner {
        var result: OWSDirectionalRectCorner = []

        if !itemViewState.isFirstInCluster {
            result.insert(isIncoming ? .topLeading : .topTrailing)
        }

        if !itemViewState.isLastInCluster {
            result.insert(isIncoming ? .bottomLeading : .bottomTrailing)
        }

        return result
    }

    /// Tellomi（#1205）：这一条画不画小尾巴、画在哪边。
    private var tellomiBubbleTail: BubbleConfiguration.Tail? {
        let hasBubbleBackground = !isBubbleTransparent
            && !componentState.isBodyMediaOnlyMessage
            && !wasRemotelyDeleted
            && componentState.giftBadge == nil
        guard
            Self.tellomiShouldDrawTail(
                isLastInCluster: itemViewState.isLastInCluster,
                hasReactions: componentState.reactions != nil,
                hasBubbleBackground: hasBubbleBackground,
                styleType: conversationStyle.type,
            )
        else {
            return nil
        }
        let isRTL = CurrentAppContext().isRTL
        return BubbleConfiguration.Tail(isOnRight: isIncoming ? isRTL : !isRTL)
    }

    /// Tellomi（#1205，设计规范 `bubbles-and-motion-design.md` 第 2 节；和 Android `TellomiBubbleTail.shouldDraw` 同一规则）：
    /// - 是一组的最后一条或单独一条；
    /// - 下面没挂表情回应（视为「下面还连着」，Telegram 同样）；
    /// - 有气泡底色：贴纸、大号表情、没文字的图片或视频、已删除的消息、礼物都不算；
    /// - 只在会话里画：消息详情、编辑记录、置顶消息详情（都用 `.messageDetails` 样式）不画。
    ///   会话页渲染时样式常是 `.placeholder`、不一定是 `.default`，所以照上游（本文件开头的头像判断）判断「不是消息详情」。
    static func tellomiShouldDrawTail(
        isLastInCluster: Bool,
        hasReactions: Bool,
        hasBubbleBackground: Bool,
        styleType: ConversationStyle.`Type`,
    ) -> Bool {
        isLastInCluster && !hasReactions && hasBubbleBackground && styleType != .messageDetails
    }

    /// Tellomi（#1205）：把内容放进气泡视图。内容先放进 `tailContentView`，由它按 `insets` 缩回：有尾巴时气泡视图在尾巴那一侧
    /// 外扩了 `Tail.extent`，内容缩回原来的位置；没有尾巴内缩为零。
    ///
    /// 没有尾巴也放进这一层：壁纸模糊视图（`CVWallpaperBlurView`）一个 cell 只建一次、从不 reset，每次配置
    /// `addSubviewToFillSuperviewEdges` 加的布局块都留在它身上，块里排的是当时加进去的子视图。子视图永远是这一层，
    /// 旧的块就不会去排一个已经不在任何视图里的视图（Debug 下 owsFailDebug 直接崩，Release 每次布局都写错误日志）。
    /// chatColorView 会把自己所有子视图铺满整块（ensureSubviewsFillBounds），所以缩回只能在中间这一层做。
    static func tellomiHostContent(
        _ contentView: UIView,
        in bubbleView: ManualLayoutView,
        tailContentView: ManualLayoutView,
        insets: UIEdgeInsets,
    ) {
        tailContentView.addSubview(contentView)
        tailContentView.addLayoutBlock { view in
            ManualLayoutView.setSubviewFrame(subview: contentView, frame: view.bounds.inset(by: insets))
        }
        bubbleView.addSubviewToFillSuperviewEdges(tailContentView)
    }

    private var sharpCornersForQuotedMessage: OWSDirectionalRectCorner {
        var sharpCorners = sharpCorners

        if itemViewState.senderNameState != nil || componentState.quotedReply?.quotedReplyModel.storyReactionEmoji != nil {
            sharpCorners.insert(.topLeading)
            sharpCorners.insert(.topTrailing)
        }

        if componentState.bodyText != nil || !itemViewState.shouldHideFooter {
            sharpCorners.insert(.bottomLeading)
            sharpCorners.insert(.bottomTrailing)
        }

        return sharpCorners
    }

    private func subcomponent(forKey key: CVComponentKey) -> CVComponent? {
        switch key {
        case .senderName:
            return self.senderName
        case .bodyText:
            return self.bodyText
        case .bodyMedia:
            return self.bodyMedia
        case .footer:
            return self.standaloneFooter
        case .sticker:
            return self.sticker
        case .viewOnce:
            return self.viewOnce
        case .audioAttachment:
            return self.audioAttachment
        case .genericAttachment:
            return self.genericAttachment
        case .paymentAttachment:
            return self.paymentAttachment
        case .archivedPaymentAttachment:
            return self.archivedPaymentAttachment
        case .undownloadableAttachment:
            return self.undownloadableAttachment
        case .quotedReply:
            return self.quotedReply
        case .linkPreview:
            return self.linkPreview
        case .giftBadge:
            return self.giftBadge
        case .reactions:
            return self.reactions
        case .contactShare:
            return self.contactShare
        case .bottomButtons:
            return self.bottomButtons
        case .poll:
            return self.poll
        case .bottomLabel:
            return self.bottomLabel
        // We don't render sender avatars with a subcomponent.
        case .senderAvatar:
            return nil
        case .systemMessage, .dateHeader, .unreadIndicator, .typingIndicator, .threadDetails, .skippedDownloads, .sendFailureBadge, .unknownThreadWarning, .defaultDisappearingMessageTimer, .collapseSet, .messageRoot:
            return nil
        }
    }

    private var hasBodyMedia: Bool {
        bodyMedia != nil
    }

    // TODO: We might want to render the "remotely deleted" indicator using a dedicated component.
    private var hasBodyText: Bool {
        if wasRemotelyDeleted {
            return true
        }

        return componentState.bodyText != nil
    }

    private var hasSecondaryContentForSelection: Bool {
        componentState.hasPrimaryAndSecondaryContentForSelection
    }

    private var isBubbleTransparent: Bool {
        if wasRemotelyDeleted {
            return false
        }
        if componentState.isBorderlessStickerMessage {
            return true
        }
        return isBorderless
    }

    private var tapForMoreState: CVComponentFooter.TapForMoreState {
        standaloneFooter?.tapForMoreState ?? .none
    }

    private func footerOverlayIfItShouldShow() -> CVComponentFooter? {
        let footerShouldOverlay = (bodyText == nil && !itemViewState.shouldHideFooter && !tapForMoreState.shouldShowFooter)

        guard footerShouldOverlay else { return nil }

        if let footerState = itemViewState.footerState {
            return CVComponentFooter(
                itemModel: itemModel,
                footerState: footerState,
                isOverlayingMedia: false,
                isOutsideBubble: false,
            )
        } else {
            owsFailDebug("Missing footerState.")
        }

        return nil
    }

    private func buildComponentStates() {

        hasSendFailureBadge = componentState.sendFailureBadge != nil

        var footerOverlay: CVComponentFooter?

        if let senderNameState = itemViewState.senderNameState {
            self.senderName = CVComponentSenderName(itemModel: itemModel, senderNameState: senderNameState)
        }
        if let senderAvatar = componentState.senderAvatar {
            self.senderAvatar = senderAvatar
        }
        if let undownloadableAttachment = componentState.undownloadableAttachment {
            footerOverlay = self.footerOverlayIfItShouldShow()
            self.undownloadableAttachment = CVComponentUndownloadableAttachment(
                itemModel: itemModel,
                attachmentType: undownloadableAttachment,
                footerOverlay: footerOverlay,
            )
        }
        if let stickerState = componentState.sticker {
            self.sticker = CVComponentSticker(itemModel: itemModel, sticker: stickerState)
        }
        if let viewOnceState = componentState.viewOnce {
            self.viewOnce = CVComponentViewOnce(itemModel: itemModel, viewOnce: viewOnceState)
        }
        if let genericAttachmentState = componentState.genericAttachment {
            self.genericAttachment = CVComponentGenericAttachment(
                itemModel: itemModel,
                genericAttachment: genericAttachmentState,
            )
        }
        // Payments can have body text too; only render a vanilla body text if a payment
        // isn't present.
        // Tellomi（card-visual §3.5）：消息除了一条链接什么都没有时只画卡片，不画链接文字（完整链接在长按菜单里能复制）。
        let isLinkCardOnly = (componentState.linkPreview?.state as? TellomiLinkPreviewCardState)?.isCardOnly == true
        if let bodyTextState = itemViewState.bodyTextState, componentState.paymentAttachment == nil, !isLinkCardOnly {
            bodyText = CVComponentBodyText(itemModel: itemModel, bodyTextState: bodyTextState)
        }
        if let contactShareState = componentState.contactShare {
            contactShare = CVComponentContactShare(
                itemModel: itemModel,
                contactShareState: contactShareState,
            )
        }

        if let pollState = componentState.poll {
            poll = CVComponentPoll(itemModel: itemModel, poll: pollState)
        }

        if let bottomButtonsState = componentState.bottomButtons {
            bottomButtons = CVComponentBottomButtons(
                itemModel: itemModel,
                bottomButtonsState: bottomButtonsState,
            )
        }

        if let bottomLabelState = componentState.bottomLabel {
            bottomLabel = CVComponentBottomLabel(itemModel: itemModel, bottomLabelState: bottomLabelState)
        }

        if let paymentAttachment = componentState.paymentAttachment {
            let paymentAmount: UInt64? = {
                let receipt = paymentAttachment.notification.mcReceiptData
                guard let decryptedAmount = SUIEnvironment.shared.paymentsImplRef.unmaskReceiptAmount(data: receipt) else {
                    // Valid path for sender
                    return paymentAttachment.model?.paymentAmount?.picoMob
                }

                // Valid path for recipient
                return decryptedAmount.value
            }()

            let messageStatus: MessageReceiptStatus? = {
                guard
                    let outgoingMessage = itemModel.interaction as? OWSOutgoingPaymentMessage,
                    let model = paymentAttachment.model
                else {
                    return nil
                }
                return MessageRecipientStatusUtils.recipientStatus(
                    outgoingMessage: outgoingMessage,
                    paymentModel: model,
                )
            }()

            if let footerState = itemViewState.footerState {
                self.standaloneFooter = CVComponentFooter(
                    itemModel: itemModel,
                    footerState: footerState,
                    isOverlayingMedia: false,
                    isOutsideBubble: false,
                )
            }

            self.paymentAttachment = CVComponentPaymentAttachment(
                itemModel: itemModel,
                paymentAttachment: paymentAttachment,
                paymentModel: paymentAttachment.model,
                contactName: paymentAttachment.otherUserShortName,
                paymentAmount: paymentAmount,
                messageStatus: messageStatus,
            )

        }

        if let archivedPaymentAttachment = componentState.archivedPaymentAttachment {
            let messageStatus: MessageReceiptStatus? = {
                guard let outgoingMessage = self.itemModel.interaction as? TSOutgoingMessage else {
                    return nil
                }
                return MessageRecipientStatusUtils.recipientStatus(
                    outgoingMessage: outgoingMessage,
                    hasBodyAttachments: false,
                )
            }()

            if let footerState = itemViewState.footerState {
                self.standaloneFooter = CVComponentFooter(
                    itemModel: itemModel,
                    footerState: footerState,
                    isOverlayingMedia: false,
                    isOutsideBubble: false,
                )
            }

            self.archivedPaymentAttachment = CVComponentArchivedPayment(
                itemModel: itemModel,
                archivedPaymentAttachment: archivedPaymentAttachment,
                messageStatus: messageStatus,
            )
        }

        if let audioAttachmentState = componentState.audioAttachment {
            footerOverlay = self.footerOverlayIfItShouldShow()
            self.audioAttachment = CVComponentAudioAttachment(
                itemModel: itemModel,
                audioAttachment: audioAttachmentState,
                nextAudioAttachment: itemViewState.nextAudioAttachment,
                footerOverlay: footerOverlay,
            )
        }

        if let bodyMediaState = componentState.bodyMedia {
            // Tellomi（ADR-0068 §4.7）：说明文字在上方时，图是气泡最下面一块，时间压在图上（同 Telegram 说明在上方时的样子）。
            let shouldFooterOverlayMedia = ((bodyText == nil || componentState.tellomiCaptionAboveMedia) && !isBorderless && !itemViewState.shouldHideFooter && !tapForMoreState.shouldShowFooter)
            if shouldFooterOverlayMedia {
                owsAssertDebug(footerOverlay == nil)
                if let footerState = itemViewState.footerState {
                    footerOverlay = CVComponentFooter(
                        itemModel: itemModel,
                        footerState: footerState,
                        isOverlayingMedia: true,
                        isOutsideBubble: false,
                    )
                } else {
                    owsFailDebug("Missing footerState.")
                }
            }

            bodyMedia = CVComponentBodyMedia(itemModel: itemModel, bodyMedia: bodyMediaState, footerOverlay: footerOverlay)
        }

        let hasStandaloneFooter = (footerOverlay == nil && !itemViewState.shouldHideFooter)
        if hasStandaloneFooter {
            if let footerState = itemViewState.footerState {
                self.standaloneFooter = CVComponentFooter(
                    itemModel: itemModel,
                    footerState: footerState,
                    isOverlayingMedia: false,
                    isOutsideBubble: isBubbleTransparent,
                )
            } else {
                owsFailDebug("Missing footerState.")
            }
        }

        if let quotedReplyState = componentState.quotedReply {
            self.quotedReply = CVComponentQuotedReply(
                itemModel: itemModel,
                quotedReply: quotedReplyState,
                sharpCornersForQuotedMessage: sharpCornersForQuotedMessage,
            )
        }

        if let linkPreviewState = componentState.linkPreview {
            self.linkPreview = CVComponentLinkPreview(
                itemModel: itemModel,
                linkPreview: linkPreviewState.state,
            )
        }

        if let giftBadge = componentState.giftBadge, let viewState = itemViewState.giftBadgeState {
            self.giftBadge = CVComponentGiftBadge(itemModel: itemModel, giftBadge: giftBadge, viewState: viewState)
        }

        if let reactionsState = componentState.reactions {
            self.reactions = CVComponentReactions(itemModel: itemModel, reactions: reactionsState)
        }
    }

    public func configureCellRootComponent(
        cellView: UIView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
        messageSwipeActionState: CVMessageSwipeActionState,
        componentView: CVComponentView,
    ) {

        Self.configureCellRootComponent(
            rootComponent: self,
            cellView: cellView,
            cellMeasurement: cellMeasurement,
            componentDelegate: componentDelegate,
            componentView: componentView,
        )

        self.swipeActionProgress = messageSwipeActionState.getProgress(interactionId: interaction.uniqueId)
    }

    public func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewMessage()
    }

    override public func wallpaperBlurView(componentView: CVComponentView) -> CVWallpaperBlurView? {
        guard let componentView = componentView as? CVComponentViewMessage else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }
        return componentView.wallpaperBlurView
    }

    override public func updateScrollingContent(componentView: CVComponentView) {
        super.updateScrollingContent(componentView: componentView)

        guard let componentView = componentView as? CVComponentViewMessage else {
            owsFailDebug("Unexpected componentView.")
            return
        }
        componentView.chatColorView.updateAppearance()

        // We propagate this event to all subcomponents that use the CVColorOrGradientView.
        let keys: [CVComponentKey] = [.senderName, .footer]
        for key in keys {
            if
                let subcomponentAndView = findActiveComponentAndView(
                    key: key,
                    messageView: componentView,
                    ignoreMissing: true,
                )
            {
                let subcomponent = subcomponentAndView.component
                let subcomponentView = subcomponentAndView.componentView
                subcomponent.updateScrollingContent(componentView: subcomponentView)
            }
        }
    }

    public static let textViewVSpacing: CGFloat = 3

    private var sendFailureBadgeSize: CGFloat { conversationStyle.hasWallpaper ? 40 : 24 }

    public static let bubbleSharpCornerRadius: CGFloat = 4
    public static let bubbleWideCornerRadius: CGFloat = 18

    public func configureForRendering(
        componentView: CVComponentView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) {
        guard let componentView = componentView as? CVComponentViewMessage else {
            owsFailDebug("Unexpected componentView.")
            return
        }

        let outerContentView = configureContentStack(
            componentView: componentView,
            cellMeasurement: cellMeasurement,
            componentDelegate: componentDelegate,
        )

        // No bubbles for borderless stickers.
        var outerBubbleView: (CVDimmableView & OWSBubbleViewHost)?
        let tellomiTail = componentState.isBorderlessStickerMessage ? nil : tellomiBubbleTail
        if !componentState.isBorderlessStickerMessage {
            let bubbleConfiguration = BubbleConfiguration(
                corners: .segmented(
                    sharpCorners: sharpCorners,
                    sharpCornerRadius: Self.bubbleSharpCornerRadius,
                    wideCornerRadius: Self.bubbleWideCornerRadius,
                ),
                stroke: bubbleStroke,
                tail: tellomiTail,
            )
            if case .blur = bubbleChatColor {
                let wallpaperBlurView = componentView.ensureWallpaperBlurView()
                configureWallpaperBlurView(
                    wallpaperBlurView: wallpaperBlurView,
                    componentDelegate: componentDelegate,
                    bubbleConfig: bubbleConfiguration,
                )
                outerBubbleView = wallpaperBlurView
            } else {
                let chatColorView = componentView.chatColorView
                chatColorView.configure(
                    value: bubbleChatColor,
                    referenceView: componentDelegate.view,
                    bubbleConfig: bubbleConfiguration,
                )
                outerBubbleView = chatColorView
            }
        }

        // hInnerStack

        let hInnerStack = componentView.hInnerStack
        hInnerStack.reset()
        var hInnerStackSubviews = [UIView]()

        if hasSenderAvatarLayout, let senderAvatar = self.senderAvatar {
            if hasSenderAvatar {
                componentView.avatarView.updateWithSneakyTransactionIfNecessary { config in
                    config.dataSource = senderAvatar.avatarDataSource
                }
            }
            // Add the view wrapper, not the view.
            hInnerStackSubviews.append(componentView.avatarViewSwipeToReplyWrapper)
        }

        let contentViewSwipeToReplyWrapper = componentView.contentViewSwipeToReplyWrapper
        if let bubbleView = outerBubbleView {
            // Tellomi（#1205）：气泡视图在尾巴那一侧外扩 `Tail.extent`，尾巴画在这一条里；内容缩回原来的位置，排版不变。
            let tellomiInsets = tellomiTail?.contentInsets ?? .zero
            Self.tellomiHostContent(
                outerContentView,
                in: bubbleView,
                tailContentView: componentView.tellomiTailContentView,
                insets: tellomiInsets,
            )
            // 每次都重设：有的包装在复用时不 reset，不重设会带着上一条的外扩。
            contentViewSwipeToReplyWrapper.tellomiSubviewOutsets = tellomiInsets

            if let (giftWrapView, bubbleViewPartner) = self.configureGiftWrapIfNeeded(messageView: componentView) {
                let wrapper = ManualLayoutView(name: "containerForOverlay")
                wrapper.addSubviewToFillSuperviewEdges(bubbleView)
                wrapper.addSubviewToFillSuperviewEdges(giftWrapView)
                contentViewSwipeToReplyWrapper.subview = wrapper

                bubbleViewPartner.setBubbleViewHost(bubbleView)
            } else {
                contentViewSwipeToReplyWrapper.subview = bubbleView
            }

            if
                let componentAndView = findActiveComponentAndView(
                    key: .bodyMedia,
                    messageView: componentView,
                )
            {
                if let bodyMediaComponent = componentAndView.component as? CVComponentBodyMedia {
                    if let bubbleViewPartner = bodyMediaComponent.bubbleViewPartner(componentView: componentAndView.componentView) {
                        bubbleViewPartner.setBubbleViewHost(bubbleView)
                        contentViewSwipeToReplyWrapper.addLayoutBlock { _ in
                            // The "bubble view partner" must update it's layers
                            // to reflect the bubble view state.
                            bubbleViewPartner.updateLayers()
                        }
                        hInnerStack.addLayoutBlock { _ in
                            // The "bubble view partner" must update it's layers
                            // to reflect the bubble view state.
                            bubbleViewPartner.updateLayers()
                        }
                        outerBubbleView?.dimsContent = true
                    }
                } else {
                    owsFailDebug("Invalid component.")
                }
            }
        } else {
            contentViewSwipeToReplyWrapper.subview = outerContentView
        }
        // Use the view wrapper, not the view.
        let contentRootView = contentViewSwipeToReplyWrapper
        hInnerStackSubviews.append(contentRootView)

        hInnerStack.configure(
            config: hInnerStackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_hInnerStack,
            subviews: hInnerStackSubviews,
        )

        // hOuterStack

        var hOuterStackSubviews = [UIView]()
        if isShowingSelectionUI || wasShowingSelectionUI {
            let primarySelectionView = componentView.primarySelectionView
            primarySelectionView.isSelected = componentDelegate.selectionState.isSelected(
                interaction.uniqueId,
                selectionType: .primaryContent,
            )
            primarySelectionView.updateStyle(conversationStyle: conversationStyle)

            let selectionWrapper = componentView.selectionWrapper
            if
                hasSecondaryContentForSelection,
                let bodyTextRootView = CVComponentBodyText.findBodyTextRootView(outerContentView)
            {

                struct SelectionLayoutHelper {
                    let outerContentView: UIView
                    let bodyTextRootView: UIView
                    /// Tellomi（ADR-0068 §4.7）：说明文字在媒体上方——文字那个勾对着说明，附件那个勾对着下面的图。
                    let tellomiCaptionAboveMedia: Bool

                    func applyLayout(bottomSelectionView: UIView, topSelectionView: UIView?) {
                        let size = MessageSelectionView.preferredSize
                        guard let superview = bottomSelectionView.superview else {
                            owsFailDebug("Missing superview.")
                            return
                        }

                        // Determine the frame of the body text view in the local
                        // coordinate system.
                        let bodyTextFrame = superview.convert(bodyTextRootView.bounds, from: bodyTextRootView)
                        let outerContentFrame = superview.convert(outerContentView.bounds, from: outerContentView)

                        if tellomiCaptionAboveMedia {
                            // bottomSelectionView 是文字那部分，topSelectionView 是附件那部分。
                            let textY = bodyTextFrame.midY - size.height * 0.5
                            bottomSelectionView.frame = CGRect(origin: CGPoint(x: 0, y: textY), size: size)
                            if let topSelectionView {
                                let mediaMidY = bodyTextFrame.maxY.average(outerContentFrame.maxY)
                                topSelectionView.frame = CGRect(origin: CGPoint(x: 0, y: mediaMidY - size.height * 0.5), size: size)
                            }
                            return
                        }

                        if let topSelectionView {
                            // "Top" should center-align with the area above the body text.
                            let topY = bodyTextFrame.y * 0.5 - size.height * 0.5
                            topSelectionView.frame = CGRect(origin: CGPoint(x: 0, y: topY), size: size)
                        }

                        // "Bottom" should center-align with the body text and the content below it.
                        //
                        // This bakes in the assumption that the group sender avatar will
                        // be bottom-aligned with the bottom of the message bubble.
                        let bottomMidY = bodyTextFrame.minY.average(outerContentFrame.maxY)
                        let bottomY = bottomMidY - size.height * 0.5
                        bottomSelectionView.frame = CGRect(origin: CGPoint(x: 0, y: bottomY), size: size)
                    }
                }
                let selectionLayoutHelper = SelectionLayoutHelper(
                    outerContentView: outerContentView,
                    bodyTextRootView: bodyTextRootView,
                    tellomiCaptionAboveMedia: componentState.tellomiCaptionAboveMedia,
                )

                let secondarySelectionView = componentView.secondarySelectionView
                secondarySelectionView.isSelected = componentDelegate.selectionState.isSelected(
                    interaction.uniqueId,
                    selectionType: .secondaryContent,
                )
                secondarySelectionView.updateStyle(conversationStyle: conversationStyle)

                let selectionLayoutBlock = { (_: UIView) -> Void in
                    selectionLayoutHelper.applyLayout(
                        bottomSelectionView: secondarySelectionView,
                        topSelectionView: primarySelectionView,
                    )
                }

                // When doing "partial" selection, the selection UI needs to
                // align with the corresponding content views.
                //
                // Coordinating layout of "distant cousin" views in a view hierarchy
                // is trivial with iOS Auto Layout, but hard with manual layout, since
                // changes to any "intermediary" relative can affect the coordination,
                // and for a rich view hierarchy it's not practical to observe all of
                // the "intermediaries".  It's also impractical to calculate their
                // relative positions using the "measurement/layout" state.
                //
                // Therefore, we coordinate their layouts by:
                //
                // * Using layout blocks that use the actual final layouts.
                // * Adding the layout block (selectionLayoutBlock) to both
                //   the immediate parent (as usual) and to the "oldest common
                //   ancestor" (unusual).  The latter ensures that we re-layout
                //   whenever the cell changes size, for example.
                selectionWrapper.addSubview(primarySelectionView, withLayoutBlock: { _ in })
                selectionWrapper.addSubview(secondarySelectionView, withLayoutBlock: { _ in })
                selectionWrapper.addLayoutBlock(selectionLayoutBlock)
                outerContentView.addLayoutBlock(selectionLayoutBlock)
                outerContentView.setNeedsLayout()
            } else {
                selectionWrapper.addSubviewToCenterOnSuperview(
                    primarySelectionView,
                    size: MessageSelectionView.preferredSize,
                )
            }
            hOuterStackSubviews.append(selectionWrapper)
        }

        if isOutgoing || isReleaseNotesMessage {
            hOuterStackSubviews.append(componentView.cellSpacerLeading)
        }
        hOuterStackSubviews.append(hInnerStack)
        if isIncoming || isReleaseNotesMessage {
            hOuterStackSubviews.append(componentView.cellSpacerTrailing)
        }
        if let badgeConfig = componentState.sendFailureBadge {
            // Send failures are rare, so it's cheaper to only build these views when we need them.
            let badgeImageView = CVImageView()
            badgeImageView.contentMode = .center
            badgeImageView.setTemplateImageName("error-circle", tintColor: badgeConfig.color)
            let sendFailureBadge: UIView
            if let visualEffect = conversationStyle.bubbleBackgroundBlurEffect {
                let circleView = ManualLayoutView.circleView(name: "SendFailureBadge")
                circleView.layer.masksToBounds = true
                circleView.addSubviewToFillSuperviewEdges(UIVisualEffectView(effect: visualEffect))
                circleView.addSubviewToFillSuperviewEdges(badgeImageView)

                sendFailureBadge = circleView
            } else {
                sendFailureBadge = badgeImageView
            }

            let sendFailureWrapper = ManualLayoutView(name: "sendFailureWrapper")
            hOuterStackSubviews.append(sendFailureWrapper)
            sendFailureWrapper.addSubview(sendFailureBadge)
            let sendFailureBadgeSize = self.sendFailureBadgeSize
            let conversationStyle = self.conversationStyle
            sendFailureWrapper.addLayoutBlock { view in
                var sendFailureFrame = CGRect(
                    origin: .zero,
                    size: CGSize(square: sendFailureBadgeSize),
                )
                // Bottom align.
                sendFailureFrame.y = view.bounds.height - sendFailureFrame.height
                if !conversationStyle.hasWallpaper {
                    let sendFailureBadgeBottomMargin = round(conversationStyle.lastTextLineAxis - sendFailureBadgeSize * 0.5)
                    sendFailureFrame.y -= sendFailureBadgeBottomMargin
                }
                sendFailureBadge.frame = sendFailureFrame
            }
        }

        let hOuterStack = componentView.hOuterStack
        hOuterStack.reset()
        hOuterStack.configure(
            config: hOuterStackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_hOuterStack,
            subviews: hOuterStackSubviews,
        )

        let swipeToReplyIconView = componentView.swipeToReplyIconView
        swipeToReplyIconView.backgroundEffect = conversationStyle.bubbleBackgroundBlurEffect
        swipeToReplyIconView.alpha = 0
        let swipeToReplyIconSwipeToReplyWrapper = componentView.swipeToReplyIconSwipeToReplyWrapper
        // Add the view wrapper, not the view.
        let swipeToReplyView = swipeToReplyIconSwipeToReplyWrapper
        hInnerStack.addSubview(swipeToReplyView)
        hInnerStack.sendSubviewToBack(swipeToReplyView)

        hInnerStack.addLayoutBlock { _ in
            guard let superview = swipeToReplyView.superview else {
                return
            }
            let contentFrame = superview.convert(contentRootView.bounds, from: contentRootView)
            let swipeToReplySize = swipeToReplyIconView.intrinsicContentSize
            var swipeToReplyFrame = CGRect(origin: .zero, size: swipeToReplySize)
            // Tellomi（tellomi/tellomi#1109）：回复改成手指从右往左滑，气泡往左让开，图标从气泡右侧露出来（RTL 镜像）。
            if CurrentAppContext().isRTL {
                swipeToReplyFrame.x = contentFrame.x + 8
            } else {
                swipeToReplyFrame.x = contentFrame.maxX - (swipeToReplySize.width + 8)
            }
            // swipeToReplyIconView.autoAlignAxis(.horizontal, toSameAxisOf: swipeActionContentView)
            swipeToReplyFrame.y = contentFrame.y + (contentFrame.height - swipeToReplyFrame.height) * 0.5
            swipeToReplyView.frame = swipeToReplyFrame
        }

        if
            let reactions = self.reactions,
            let reactionsSize = cellMeasurement.size(key: Self.measurementKey_reactions)
        {
            let reactionsView = configureSubcomponentView(
                messageView: componentView,
                subcomponent: reactions,
                cellMeasurement: cellMeasurement,
                componentDelegate: componentDelegate,
                key: .reactions,
            )

            // Use the view wrapper, not the view.
            let reactionsSwipeToReplyWrapper = componentView.reactionsSwipeToReplyWrapper
            reactionsSwipeToReplyWrapper.subview = reactionsView.rootView
            let reactionsRootView = reactionsSwipeToReplyWrapper

            hInnerStack.addSubview(reactionsRootView)
            let reactionsVOverlap = self.reactionsVOverlap
            let reactionsHInset = self.reactionsHInset
            let isIncoming = self.isIncoming
            // We want the reaction bubbles to stick to the middle of the screen inset from
            // the edge of the bubble with a small amount of padding unless the bubble is smaller
            // than the reactions view in which case it will break these constraints and extend
            // further into the middle of the screen than the message itself.
            hInnerStack.addLayoutBlock { _ in
                guard let superview = reactionsRootView.superview else {
                    return
                }
                let contentFrame = superview.convert(outerContentView.bounds, from: outerContentView)
                var reactionsFrame = CGRect(origin: .zero, size: reactionsSize)
                reactionsFrame.y = contentFrame.maxY - reactionsVOverlap
                let leftAlignX = contentFrame.minX + reactionsHInset
                let rightAlignX = contentFrame.maxX - (reactionsSize.width + reactionsHInset)
                if isIncoming != CurrentAppContext().isRTL {
                    reactionsFrame.x = max(leftAlignX, rightAlignX)
                } else {
                    reactionsFrame.x = min(leftAlignX, rightAlignX)
                }
                reactionsRootView.frame = reactionsFrame
            }
        }

        if poll == nil {
            // Polls manage accessibility manually.
            configureAccessibility(componentView: componentView)
        }

        var selectionViews: [ManualLayoutView] = [componentView.primarySelectionView]
        if hasSecondaryContentForSelection {
            selectionViews.append(componentView.secondarySelectionView)
        }

        // Configure hOuterStack/hInnerStack animations
        if isShowingSelectionUI || wasShowingSelectionUI {
            // Configure selection animations
            let selectionViewWidth = ConversationStyle.selectionViewWidth
            let layoutMargins = CurrentAppContext().isRTL ? hOuterStackConfig.layoutMargins.right : hOuterStackConfig.layoutMargins.left
            let selectionOffset = -(layoutMargins + selectionViewWidth)
            let hInnerStackOffset = -(hOuterStackConfig.spacing + selectionViewWidth)
            if isShowingSelectionUI, !wasShowingSelectionUI { // Animate in
                for selectionView in selectionViews {
                    selectionView.addTransformBlock { view in
                        let animation = CABasicAnimation(keyPath: "transform.translation.x")
                        animation.fromValue = selectionOffset
                        animation.toValue = 0
                        animation.duration = CVComponentMessage.selectionAnimationDuration
                        animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
                        view.layer.add(animation, forKey: "insert")
                    }
                }

                if isIncoming {
                    hInnerStack.addTransformBlock { view in
                        let animation = CABasicAnimation(keyPath: "transform.translation.x")
                        animation.fromValue = hInnerStackOffset
                        animation.toValue = 0
                        animation.duration = CVComponentMessage.selectionAnimationDuration
                        animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
                        view.layer.add(animation, forKey: "insert")
                    }
                }
            } else if !isShowingSelectionUI, wasShowingSelectionUI { // Animate out
                for selectionView in selectionViews {
                    selectionView.addTransformBlock { view in
                        let animation = CABasicAnimation(keyPath: "transform.translation.x")
                        animation.fromValue = 0
                        animation.toValue = selectionOffset
                        animation.duration = CVComponentMessage.selectionAnimationDuration
                        animation.isRemovedOnCompletion = false
                        animation.repeatCount = 0
                        animation.fillMode = CAMediaTimingFillMode.forwards
                        animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
                        view.layer.add(animation, forKey: "remove")
                    }
                }

                if isIncoming {
                    hInnerStack.addTransformBlock { view in
                        let animation = CABasicAnimation(keyPath: "transform.translation.x")
                        animation.fromValue = 0
                        animation.toValue = hInnerStackOffset
                        animation.duration = CVComponentMessage.selectionAnimationDuration
                        animation.isRemovedOnCompletion = false
                        animation.repeatCount = 0
                        animation.fillMode = CAMediaTimingFillMode.forwards
                        animation.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
                        view.layer.add(animation, forKey: "remove")
                    }
                }
            }
        } else {
            // Remove outstanding animations if needed
            for selectionView in selectionViews {
                selectionView.invalidateTransformBlocks()
            }
            hInnerStack.invalidateTransformBlocks()
        }

        hOuterStack.applyTransformBlocks()
    }

    // The behavior of this method has to align exactly with that of measureContentStack().
    private func configureContentStack(
        componentView: CVComponentViewMessage,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) -> ManualLayoutView {

        func configureStackView(
            _ stackView: ManualStackView,
            stackConfig: CVStackViewConfig,
            measurementKey: String,
            componentKeys keys: [CVComponentKey],
        ) -> ManualStackView {
            self.configureSubcomponentStack(
                messageView: componentView,
                stackView: stackView,
                stackConfig: stackConfig,
                cellMeasurement: cellMeasurement,
                measurementKey: measurementKey,
                componentDelegate: componentDelegate,
                keys: keys,
            )
            return stackView
        }

        if componentState.isBorderlessStickerMessage {
            // Borderless sticker message.
            //
            // Stack is borderless.
            //
            // Optional senderName and footer.
            return configureStackView(
                componentView.contentStack,
                stackConfig: buildBorderlessStackConfig(),
                measurementKey: Self.measurementKey_contentStack,
                componentKeys: [.senderName, .sticker, .footer],
            )
        } else {
            // The non-sticker case.
            // Use multiple stacks.

            let contentSections = buildContentSections()

            var contentSubviews = [UIView]()
            enumerate(contentSections: contentSections) { (contentSection: ContentSection, stackConfig: CVStackViewConfig) in
                guard
                    let stackView = contentSection.stackView(componentView: componentView),
                    let stackMeasurementKey = contentSection.stackMeasurementKey
                else {
                    owsFailDebug("Missing stackView or stackMeasurementKey.")
                    return
                }
                let componentKeys = contentSection.components.map { $0.componentKey }

                var stackConfig = stackConfig
                if
                    contentSection.sectionType == .bottomNestedText,
                    let bottomNestedTextSpacing = cellMeasurement.value(key: Self.measurementKey_bottomNestedTextSpacing)
                {
                    stackConfig = stackConfig.withSpacing(bottomNestedTextSpacing)
                }

                _ = configureStackView(
                    stackView,
                    stackConfig: stackConfig,
                    measurementKey: stackMeasurementKey,
                    componentKeys: componentKeys,
                )
                contentSubviews.append(stackView)
            }
            // Append the bottom buttons if necessary.
            if nil != bottomButtons {
                if
                    let componentAndView = configureSubcomponent(
                        messageView: componentView,
                        cellMeasurement: cellMeasurement,
                        componentDelegate: componentDelegate,
                        key: .bottomButtons,
                    )
                {
                    let subview = componentAndView.componentView.rootView
                    contentSubviews.append(subview)
                } else {
                    owsFailDebug("Couldn't configure bottomButtons.")
                }
            }

            if nil != bottomLabel {
                if
                    let componentAndView = configureSubcomponent(
                        messageView: componentView,
                        cellMeasurement: cellMeasurement,
                        componentDelegate: componentDelegate,
                        key: .bottomLabel,
                    )
                {
                    let subview = componentAndView.componentView.rootView
                    contentSubviews.append(subview)
                } else {
                    owsFailDebug("Couldn't configure bottomLabel.")
                }
            }

            let contentStack = componentView.contentStack
            contentStack.reset()
            contentStack.configure(
                config: buildContentStackConfig(),
                cellMeasurement: cellMeasurement,
                measurementKey: Self.measurementKey_contentStack,
                subviews: contentSubviews,
            )
            return contentStack
        }
    }

    private func configureGiftWrapIfNeeded(
        messageView componentView: CVComponentViewMessage,
    ) -> (ManualLayoutView, OWSBubbleViewPartner)? {
        guard
            let componentAndView = self.findActiveComponentAndView(key: .giftBadge, messageView: componentView),
            let giftBadgeComponent = componentAndView.component as? CVComponentGiftBadge
        else {
            return nil
        }
        return giftBadgeComponent.configureGiftWrapIfNeeded(componentView: componentAndView.componentView)
    }

    // The "message" contents of this component are vertically
    // stacked in four sections.  Ordering of the keys in each
    // section determines the ordering of the subcomponents.
    private static var topFullWidthCVComponentKeys: [CVComponentKey] { [] }
    private static var topNestedCVComponentKeys: [CVComponentKey] { [.senderName] }
    private static var bottomFullWidthCVComponentKeys: [CVComponentKey] { [
        .quotedReply,
        .linkPreview,
        .bodyMedia,
        .sticker,
    ] }
    private static var bottomNestedShareCVComponentKeys: [CVComponentKey] { [
        .viewOnce,
        .audioAttachment,
        .genericAttachment,
        .paymentAttachment,
        .archivedPaymentAttachment,
        .contactShare,
        .giftBadge,
        .poll,
    ] }
    private static var bottomNestedTextCVComponentKeys: [CVComponentKey] { [.bodyText, .footer, .undownloadableAttachment] }

    // The "message" contents of this component for most messages are vertically
    // stacked in four sections.
    fileprivate enum SectionType: CaseIterable {
        case topFullWidth
        case topNested
        case bottomFullWidth
        /// Tellomi（tellomi/tellomi#1263，ADR-0068 §4.7）：说明文字在媒体上方时，正文在引用 / 链接预览之后、媒体之前单独一节，
        /// 媒体接着单独一节（全宽）；时间留在最下面的 bottomNestedText。别的消息这两节都是空的，不出现。
        case tellomiCaptionAboveText
        case tellomiCaptionAboveMedia
        case bottomNestedShare
        case bottomNestedText
        case bottomButtons
        case bottomLabel

        // Ordering of the keys in each section determines the ordering of the subcomponents.
        var hasStack: Bool {
            switch self {
            case .topFullWidth, .topNested, .bottomFullWidth, .tellomiCaptionAboveText, .tellomiCaptionAboveMedia, .bottomNestedShare, .bottomNestedText:
                return true
            case .bottomButtons, .bottomLabel:
                return false
            }
        }

        var isNestedSection: Bool {
            switch self {
            case .topNested, .tellomiCaptionAboveText, .bottomNestedShare, .bottomNestedText:
                return true
            case .topFullWidth, .bottomFullWidth, .tellomiCaptionAboveMedia, .bottomButtons, .bottomLabel:
                return false
            }
        }

        // Ordering of the keys in each section determines the ordering of the subcomponents.
        var possibleComponentKeys: [CVComponentKey] {
            switch self {
            case .topFullWidth:
                return CVComponentMessage.topFullWidthCVComponentKeys
            case .topNested:
                return CVComponentMessage.topNestedCVComponentKeys
            case .bottomFullWidth:
                return CVComponentMessage.bottomFullWidthCVComponentKeys
            case .tellomiCaptionAboveText:
                return [.bodyText]
            case .tellomiCaptionAboveMedia:
                return [.bodyMedia]
            case .bottomNestedShare:
                return CVComponentMessage.bottomNestedShareCVComponentKeys
            case .bottomNestedText:
                return CVComponentMessage.bottomNestedTextCVComponentKeys
            case .bottomButtons:
                return [.bottomButtons]
            case .bottomLabel:
                return [.bottomLabel]
            }
        }

        var stackMeasurementKey: String? {
            switch self {
            case .topFullWidth:
                return CVComponentMessage.measurementKey_topFullWidthStackView
            case .topNested:
                return CVComponentMessage.measurementKey_topNestedStackView
            case .bottomFullWidth:
                return CVComponentMessage.measurementKey_bottomFullWidthStackView
            case .tellomiCaptionAboveText:
                return CVComponentMessage.measurementKey_tellomiCaptionAboveTextStackView
            case .tellomiCaptionAboveMedia:
                return CVComponentMessage.measurementKey_tellomiCaptionAboveMediaStackView
            case .bottomNestedShare:
                return CVComponentMessage.measurementKey_bottomNestedShareStackView
            case .bottomNestedText:
                return CVComponentMessage.measurementKey_bottomNestedTextStackView
            case .bottomButtons, .bottomLabel:
                owsFailDebug("Invalid section")
                return nil
            }
        }

        func stackView(componentView: CVComponentViewMessage) -> ManualStackView? {
            switch self {
            case .topFullWidth:
                return componentView.topFullWidthStackView
            case .topNested:
                return componentView.topNestedStackView
            case .bottomFullWidth:
                return componentView.bottomFullWidthStackView
            case .tellomiCaptionAboveText:
                return componentView.tellomiCaptionAboveTextStackView
            case .tellomiCaptionAboveMedia:
                return componentView.tellomiCaptionAboveMediaStackView
            case .bottomNestedShare:
                return componentView.bottomNestedShareStackView
            case .bottomNestedText:
                return componentView.bottomNestedTextStackView
            case .bottomButtons, .bottomLabel:
                return nil
            }
        }
    }

    fileprivate struct ContentSection {
        let sectionType: SectionType
        let components: [CVComponent]

        var stackMeasurementKey: String? { sectionType.stackMeasurementKey }

        func stackView(componentView: CVComponentViewMessage) -> ManualStackView? {
            sectionType.stackView(componentView: componentView)
        }
    }

    fileprivate func buildContentSections() -> [ContentSection] {
        var contentSections = [ContentSection]()
        for sectionType in SectionType.allCases {
            let subcomponents = subcomponents(forKeys: componentKeys(for: sectionType))
            if !subcomponents.isEmpty {
                contentSections.append(ContentSection(
                    sectionType: sectionType,
                    components: subcomponents,
                ))
            }
        }
        return contentSections
    }

    /// Tellomi（ADR-0068 §4.7）：说明文字在媒体上方时，正文和媒体从原来的节挪到 Tellomi 的两节里；别的消息照上游。
    fileprivate func componentKeys(for sectionType: SectionType) -> [CVComponentKey] {
        let captionAbove = componentState.tellomiCaptionAboveMedia
        switch sectionType {
        case .tellomiCaptionAboveText, .tellomiCaptionAboveMedia:
            return captionAbove ? sectionType.possibleComponentKeys : []
        case .bottomFullWidth:
            return captionAbove ? sectionType.possibleComponentKeys.filter { $0 != .bodyMedia } : sectionType.possibleComponentKeys
        case .bottomNestedText:
            return captionAbove ? sectionType.possibleComponentKeys.filter { $0 != .bodyText } : sectionType.possibleComponentKeys
        case .topFullWidth, .topNested, .bottomNestedShare, .bottomButtons, .bottomLabel:
            return sectionType.possibleComponentKeys
        }
    }

    fileprivate func enumerate(
        contentSections: [ContentSection],
        block: (ContentSection, CVStackViewConfig) -> Void,
    ) {
        for (currentSectionIndex, contentSection) in contentSections.enumerated() {
            guard
                !contentSection.components.isEmpty,
                let firstComponent = contentSection.components.first,
                let lastComponent = contentSection.components.last
            else {
                owsFailDebug("Empty content section.")
                continue
            }

            let sectionType = contentSection.sectionType
            // Only enumate the sections that use stacks.
            guard sectionType.hasStack else {
                continue
            }

            let previousSections = contentSections.enumerated().compactMap { sectionIndex, section in
                sectionIndex < currentSectionIndex ? section : nil
            }
            let previousSectionItems = Array(previousSections.map { section in
                section.components.map { component in
                    SectionItem(sectionType: section.sectionType, component: component)
                }
            }.joined())

            let nextSections = contentSections.enumerated().compactMap { sectionIndex, section in
                sectionIndex > currentSectionIndex ? section : nil
            }
            let nextSectionItems = Array(nextSections.map { section in
                section.components.map { component in
                    SectionItem(sectionType: section.sectionType, component: component)
                }
            }.joined())

            let firstSectionItem = SectionItem(sectionType: sectionType, component: firstComponent)
            let lastSectionItem = SectionItem(sectionType: sectionType, component: lastComponent)
            let stackConfig = contentSectionStackConfig(
                sectionType: sectionType,
                firstSectionItem: firstSectionItem,
                lastSectionItem: lastSectionItem,
                previousSectionItems: previousSectionItems,
                nextSectionItems: nextSectionItems,
            )
            block(contentSection, stackConfig)
        }
    }

    fileprivate func contentSectionStackConfig(
        sectionType: SectionType,
        firstSectionItem: SectionItem,
        lastSectionItem: SectionItem,
        previousSectionItems: [SectionItem],
        nextSectionItems: [SectionItem],
    ) -> CVStackViewConfig {

        switch sectionType {
        case .topFullWidth, .tellomiCaptionAboveMedia:
            return buildFullWidthStackConfig(includeTopMargin: false, includeBottomMargin: false)
        case .bottomFullWidth:
            var applyTopMargin = false
            var applyBottomMargin = false
            if
                previousSectionItems.isEmpty,
                quotedReply != nil || linkPreview != nil
            {
                applyTopMargin = true
                applyBottomMargin = bodyText == nil && standaloneFooter == nil && bodyMedia == nil
            } else if
                let previousSectionItem = previousSectionItems.last,
                previousSectionItem.componentKey == .linkPreview,
                quotedReply != nil
            {
                applyTopMargin = true
            }
            return buildFullWidthStackConfig(includeTopMargin: applyTopMargin, includeBottomMargin: applyBottomMargin)
        case .topNested, .tellomiCaptionAboveText, .bottomNestedShare, .bottomNestedText:
            let topMargin: ContentStackMargin
            if let previousSectionItem = previousSectionItems.last {
                // The top margin of a section's stack reflects the first item
                // in the section and the previous item (if any) before the stack.
                topMargin = contentStackMarginBetweenComponents(
                    marginType: .top,
                    topSectionItem: previousSectionItem,
                    bottomSectionItem: firstSectionItem,
                )
            } else {
                // If this is the first section stack, it should use the outer margin.
                topMargin = .topMargin
            }

            var bottomMargin: ContentStackMargin = .none
            if let nextSectionItem = nextSectionItems.first {
                // The bottom margin of a section's stack reflects the last item
                // in the section and the next item (if any) after the stack.
                bottomMargin = contentStackMarginBetweenComponents(
                    marginType: .bottom,
                    topSectionItem: lastSectionItem,
                    bottomSectionItem: nextSectionItem,
                )
            } else {
                // If this is the last section stack, it should use the outer margin.
                bottomMargin = .bottomMargin
            }

            return buildNestedStackConfig(
                topMargin: topMargin,
                bottomMargin: bottomMargin,
            )
        case .bottomButtons, .bottomLabel:
            owsFailDebug("Section does not use a stack.")
            return CVStackViewConfig(axis: .vertical, alignment: .center, spacing: 0, layoutMargins: .zero)
        }
    }

    fileprivate enum ContentStackMarginType {
        case top
        case bottom
    }

    fileprivate struct SectionItem {
        let sectionType: SectionType
        let component: CVComponent

        var componentKey: CVComponentKey { component.componentKey }
    }

    private func contentStackMarginBetweenComponents(
        marginType: ContentStackMarginType,
        topSectionItem: SectionItem,
        bottomSectionItem: SectionItem,
    ) -> ContentStackMargin {

        let topComponentKey = topSectionItem.componentKey
        let bottomComponentKey = bottomSectionItem.componentKey

        // Special case: Bottom buttons and labels are not in a stack.
        if bottomComponentKey == .bottomButtons || bottomComponentKey == .bottomLabel {
            return .bottomMargin
        }

        // We use stack margins to create spacing between content sections.
        //
        // We only place the spacing on "nested" stacks.
        // So one of the two sections should be nested.
        owsAssertDebug(
            topSectionItem.sectionType.isNestedSection ||
                bottomSectionItem.sectionType.isNestedSection,
        )
        // If two "nested" sections are adjacent, we don't want to create the
        // margin on both stacks, that would double the spacing.
        if
            topSectionItem.sectionType.isNestedSection,
            bottomSectionItem.sectionType.isNestedSection
        {
            // If both sections are "nested", arbitrarily chose one.
            if marginType == .bottom {
                return .none
            }
        }

        func isLargeComponent(_ componentKey: CVComponentKey) -> Bool {
            switch componentKey {
            case .bodyText:
                return false
            case .bodyMedia, .sticker, .quotedReply, .linkPreview, .viewOnce, .audioAttachment, .genericAttachment, .paymentAttachment, .archivedPaymentAttachment, .contactShare:
                return true
            case .undownloadableAttachment:
                return false
            case .giftBadge:
                // TODO: (GB) Confirm that Gift Badges should use large component spacing.
                return true
            case .senderName:
                return false
            case .senderAvatar, .reactions, .systemMessage, .dateHeader, .unreadIndicator, .typingIndicator, .threadDetails, .unknownThreadWarning, .skippedDownloads, .sendFailureBadge, .defaultDisappearingMessageTimer, .collapseSet, .messageRoot:
                owsFailDebug("Unexpected component.")
                return false
            case .footer:
                return false
            case .bottomButtons, .bottomLabel:
                return true
            case .poll:
                return true
            }
        }

        // Special case: Sender name and body text.
        if
            topComponentKey == .senderName,
            bottomComponentKey == .bodyText
        {
            return .spacingCustom(spacing: 1)
        }

        // Special case: Sender name and quoted reply.
        if
            topComponentKey == .senderName,
            bottomComponentKey == .quotedReply
        {
            return .spacingCustom(spacing: 5)
        }

        // Special case: Quoted reply and "large" components.
        if
            topComponentKey == .quotedReply,
            isLargeComponent(bottomComponentKey)
        {
            return .spacingCustom(spacing: 8)
        }

        // Special case: Contact share and footer.
        if
            topComponentKey == .contactShare,
            bottomComponentKey == .footer
        {
            return .spacingCustom(spacing: 5)
        }

        // Use extra-large spacing after "large" components.
        if isLargeComponent(topComponentKey) {
            if bottomComponentKey == .footer {
                return .spacingCustom(spacing: 5)
            } else {
                return .spacingCustom(spacing: 7)
            }
        }
        // Use large spacing before "large" components.
        if isLargeComponent(bottomComponentKey) {
            return .spacingCustom(spacing: 5)
        }

        return .spacingDefault
    }

    /// 整条消息一个无障碍元素（上游的做法）；第一方卡底部有动作按钮时，多一个独立的无障碍按钮（card-visual §3.6 / `a11y-strings`）：
    /// 消息不能再是「这个视图 = 一个元素」——视图成为元素以后它里面的子视图读屏都看不见，按钮就读不到、也聚焦不到。
    /// 所以这时 `hInnerStack` 变成容器，里面列两个元素：整条消息（读整句，末尾是「按钮：加入群聊」）和按钮（button 角色，读它上面的字；
    /// 激活它 = 读屏在按钮中心点一下，落在这张卡上，走的就是点卡片那条路）。按钮排在后面：点触探索时后面的盖在前面的上面。
    private func configureAccessibility(componentView: CVComponentViewMessage) {
        let hInnerStack = componentView.hInnerStack
        let label = buildAccessibilityLabel(componentView: componentView)
        if
            let linkPreview = self.linkPreview as? CVComponentLinkPreview,
            let linkPreviewView = componentView.linkPreviewView,
            let actionElement = linkPreview.accessibilityActionElement(componentView: linkPreviewView)
        {
            let messageElement = CVMessageAccessibilityElement(accessibilityContainer: hInnerStack)
            messageElement.isAccessibilityElement = true
            messageElement.accessibilityLabel = label
            hInnerStack.isAccessibilityElement = false
            hInnerStack.accessibilityLabel = nil
            hInnerStack.accessibilityElements = [messageElement, actionElement]
        } else {
            hInnerStack.accessibilityElements = nil
            hInnerStack.accessibilityLabel = label
            hInnerStack.isAccessibilityElement = true
        }
    }

    // Builds an accessibility label for the entire message.
    // This label uses basic punctuation which might be used by
    // VoiceOver for pauses/timing.
    //
    // Example: Lilia sent: a picture, check out my selfie.
    // Example: You sent: great shot!
    private func buildAccessibilityLabel(componentView: CVComponentViewMessage) -> String {
        var elements = [String]()

        if isIncoming {
            if let accessibilityAuthorName = itemViewState.accessibilityAuthorName {
                let format = OWSLocalizedString(
                    "CONVERSATION_VIEW_CELL_ACCESSIBILITY_SENDER_FORMAT",
                    comment: "Format for sender info for accessibility label for message. Embeds {{ the sender name }}.",
                )
                elements.append(String.nonPluralLocalizedStringWithFormat(format, accessibilityAuthorName))
            } else {
                owsFailDebug("Missing accessibilityAuthorName.")
            }
        } else if isOutgoing {
            elements.append(OWSLocalizedString(
                "CONVERSATION_VIEW_CELL_ACCESSIBILITY_SENDER_LOCAL_USER",
                comment: "Format for sender info for outgoing messages.",
            ))
        }

        // Order matters. For example, body media should be before body text.
        let accessibilityComponentKeys: [CVComponentKey] = [
            .bodyMedia,
            .bodyText,
            // Tellomi（card-visual §3.6）：「只显示卡片」时正文组件被拿掉，读屏得从卡片上读到链接。
            .linkPreview,
            .quotedReply,
            .sticker,
            .viewOnce,
            .audioAttachment,
            .genericAttachment,
            .contactShare,
            .reactions,
        ]
        var contents = [String]()
        for key in accessibilityComponentKeys {
            if let subcomponent = self.subcomponent(forKey: key) {
                if let accessibilityComponent = subcomponent as? CVAccessibilityComponent {
                    contents.append(accessibilityComponent.accessibilityDescription)
                } else {
                    owsFailDebug("Invalid accessibilityComponent.")
                }
            }
        }

        let timestampText: String
        if let paymentStatus = componentState.paymentAttachment?.status {
            timestampText = CVComponentFooter.paymentMessageTimestampText(
                forInteraction: interaction,
                paymentState: paymentStatus,
                shouldUseLongFormat: true,
            )
        } else {
            timestampText = CVComponentFooter.timestampText(
                forInteraction: interaction,
                shouldUseLongFormat: true,
                hasBodyAttachments: componentState.messageHasBodyAttachments,
                adminDeleteRecipientStates: nil, // TODO: get correct adminDeleteRecipientStates
            )
        }
        contents.append(timestampText)

        if let footerAccessibilityLabel = standaloneFooter?.footerAccessibilityLabel {
            contents.append(footerAccessibilityLabel)
        }

        elements.append(contents.joined(separator: ", "))

        // NOTE: In the interest of keeping the accessibility label short,
        // we do not include information that is usually presented in the
        // following components:
        //
        // * footer (disappearing message status).
        //   We _do_ include time but not date. Dates are in the date headers.
        // * senderName
        // * senderAvatar
        // * quotedReply
        // * bottomButtons
        // * sendFailureBadge

        let result = elements.joined(separator: " ")
        return result
    }

    private var hOuterStackConfig: CVStackViewConfig {
        let bottomInset = reactions != nil ? reactionsVProtrusion : 0
        let cellLayoutMargins = UIEdgeInsets(
            top: 0,
            leading: conversationStyle.fullWidthGutterLeading,
            bottom: bottomInset,
            trailing: conversationStyle.fullWidthGutterTrailing,
        )
        return CVStackViewConfig(
            axis: .horizontal,
            alignment: .fill,
            spacing: ConversationStyle.messageStackSpacing,
            layoutMargins: cellLayoutMargins,
        )
    }

    private var hInnerStackConfig: CVStackViewConfig {
        let tailSpace = Self.tellomiTailSideSpace(
            isIncoming: isIncoming,
            followsAvatar: isIncoming && hasSenderAvatarLayout && senderAvatar != nil,
            margin: tellomiTailSideMargin,
        )
        return CVStackViewConfig(
            axis: .horizontal,
            alignment: .bottom,
            spacing: ConversationStyle.messageStackSpacing + tailSpace.afterAvatar,
            layoutMargins: UIEdgeInsets(
                top: 0,
                leading: tailSpace.leading,
                bottom: 0,
                trailing: tailSpace.trailing,
            ),
        )
    }

    /// Tellomi：尾巴那一侧多留的 [margin] 放在哪。对方发的尾巴在左下：带头像时加在头像和气泡之间，
    /// 单聊（没头像）加在最前面；我发的加在最后面。
    static func tellomiTailSideSpace(
        isIncoming: Bool,
        followsAvatar: Bool,
        margin: CGFloat,
    ) -> (leading: CGFloat, afterAvatar: CGFloat, trailing: CGFloat) {
        guard isIncoming else {
            return (leading: 0, afterAvatar: 0, trailing: margin)
        }
        return followsAvatar ? (leading: 0, afterAvatar: margin, trailing: 0) : (leading: margin, afterAvatar: 0, trailing: 0)
    }

    /// Tellomi（规范 #1204 第 2 节最后一条，owner 2026-09-26 定照规范加）：气泡在尾巴那一侧多留 `Tail.sideMargin`，
    /// 尾巴不贴屏幕边、不压头像。一组里没画尾巴的几条也留，整列才对齐；不画尾巴的消息详情、居中显示的发布说明不留。
    private var tellomiTailSideMargin: CGFloat {
        guard conversationStyle.type != .messageDetails, !isReleaseNotesMessage else {
            return 0
        }
        return BubbleConfiguration.Tail.sideMargin
    }

    private let reactionsHInset: CGFloat = 6
    // The overlap between the message content and the reactions bubble.
    private var reactionsVOverlap: CGFloat {
        CVReactionCountsView.inset
    }

    // How far the reactions bubble protrudes below the message content.
    private var reactionsVProtrusion: CGFloat {
        let reactionsHeight = CVReactionCountsView.height
        return max(0, reactionsHeight - reactionsVOverlap)
    }

    /// - Returns: Bubble background color for the current message.
    ///
    /// This method checks for all the special cases when bubble for the current message should have a non-default background styling.
    /// Examples: remotely deleted message, sticker message etc.
    /// For messages that are not a special case value from `ConversationStyle` will be returned.
    private var bubbleChatColor: ColorOrGradientValue {
        if conversationStyle.hasWallpaper == false, wasRemotelyDeleted {
            return .solidColor(color: Theme.backgroundColor)
        }
        if isBubbleTransparent {
            return .transparent
        }

        var messageDirection: ConversationStyle.MessageDirection
        if isReleaseNotesMessage {
            messageDirection = .releaseNotes
        } else if isOutgoing {
            messageDirection = .outgoing
        } else {
            messageDirection = .incoming
        }

        return itemModel.conversationStyle.bubbleChatColor(messageDirection: messageDirection)
    }

    /// - Returns: Bubble stroke configuration for the current message.
    ///
    /// This method checks for all the special cases when stroke styling for current message's bubble should have non-default styling.
    /// For messages that are not a special case value from `ConversationStyle` will be returned.
    private var bubbleStroke: BubbleConfiguration.Stroke? {
        if conversationStyle.hasWallpaper == false, wasRemotelyDeleted {
            return BubbleConfiguration.Stroke(color: UIColor.Signal.transparentSeparator, width: 1)
        }
        if isBubbleTransparent {
            return nil
        }
        return itemModel.conversationStyle.bubbleStroke(isIncoming: isIncoming)
    }

    private static let measurementKey_hOuterStack = "CVComponentMessage.measurementKey_hOuterStack"
    private static let measurementKey_hInnerStack = "CVComponentMessage.measurementKey_hInnerStack"
    private static let measurementKey_contentStack = "CVComponentMessage.measurementKey_contentStack"
    private static let measurementKey_topFullWidthStackView = "CVComponentMessage.measurementKey_topFullWidthStackView"
    private static let measurementKey_topNestedStackView = "CVComponentMessage.measurementKey_topNestedStackView"
    private static let measurementKey_bottomFullWidthStackView = "CVComponentMessage.measurementKey_bottomFullWidthStackView"
    private static let measurementKey_bottomNestedShareStackView = "CVComponentMessage.measurementKey_bottomNestedShareStackView"
    private static let measurementKey_bottomNestedTextStackView = "CVComponentMessage.measurementKey_bottomNestedTextStackView"
    private static let measurementKey_tellomiCaptionAboveTextStackView = "CVComponentMessage.measurementKey_tellomiCaptionAboveTextStackView"
    private static let measurementKey_tellomiCaptionAboveMediaStackView = "CVComponentMessage.measurementKey_tellomiCaptionAboveMediaStackView"
    private static let measurementKey_reactions = "CVComponentMessage.measurementKey_reactions"
    private static let measurementKey_bottomNestedTextSpacing = "CVComponentMessage.measurementKey_bottomNestedTextSpacing"

    public func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        let selectionViewWidth = ConversationStyle.selectionViewWidth

        let hOuterStackConfig = self.hOuterStackConfig
        var contentMaxWidth = maxWidth - hOuterStackConfig.layoutMargins.totalWidth
        contentMaxWidth -= ConversationStyle.messageDirectionSpacing
        // Tellomi：尾巴那一侧多留的外边距也从内容里让出来（见 hInnerStackConfig）
        contentMaxWidth -= tellomiTailSideMargin
        if isShowingSelectionUI || wasShowingSelectionUI {
            contentMaxWidth -= selectionViewWidth + hOuterStackConfig.spacing
            if isReleaseNotesMessage {
                // Release notes messages have an extra spacer view that centers them.
                // This means they have an extra spacing gap between views that we have to
                // account for to prevent our measured size being too big.
                contentMaxWidth -= hOuterStackConfig.spacing
            }
        }
        if !isIncoming, hasSendFailureBadge {
            contentMaxWidth -= sendFailureBadgeSize + hOuterStackConfig.spacing
        }
        if hasSenderAvatarLayout {
            // Sender avatar in groups.
            contentMaxWidth -= CGFloat(ConversationStyle.groupMessageAvatarSizeClass.diameter) + ConversationStyle.messageStackSpacing
        }

        owsAssertDebug(conversationStyle.maxMediaMessageWidth <= conversationStyle.maxMessageWidth)
        let shouldUseNarrowMaxWidth = (
            bodyMedia != nil ||
                linkPreview != nil,
        )
        if shouldUseNarrowMaxWidth {
            contentMaxWidth = max(0, min(conversationStyle.maxMediaMessageWidth, contentMaxWidth))
        } else {
            contentMaxWidth = max(0, min(conversationStyle.maxMessageWidth, contentMaxWidth))
        }

        let contentStackSize = measureContentStack(
            maxWidth: contentMaxWidth,
            measurementBuilder: measurementBuilder,
        )
        if contentStackSize.width > contentMaxWidth {
            owsFailDebug("contentStackSize: \(contentStackSize) > contentMaxWidth: \(contentMaxWidth)")
        }

        var hInnerStackSubviewInfos = [ManualStackSubviewInfo]()
        if
            hasSenderAvatarLayout,
            nil != self.senderAvatar
        {
            // Sender avatar in groups.
            let avatarSize = CGSize.square(CGFloat(ConversationStyle.groupMessageAvatarSizeClass.diameter))
            hInnerStackSubviewInfos.append(avatarSize.asManualSubviewInfo(hasFixedSize: true))
        }
        // NOTE: The contentStackSize does not have fixed width and may grow
        //       to reflect the minBubbleWidth below.
        hInnerStackSubviewInfos.append(contentStackSize.asManualSubviewInfo)
        let hInnerStackMeasurement = ManualStackView.measure(
            config: hInnerStackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_hInnerStack,
            subviewInfos: hInnerStackSubviewInfos,
        )
        var hInnerStackSize = hInnerStackMeasurement.measuredSize
        let minBubbleWidth = Self.bubbleWideCornerRadius * 2
        hInnerStackSize.width = max(hInnerStackSize.width, minBubbleWidth)

        var hOuterStackSubviewInfos = [ManualStackSubviewInfo]()
        if isShowingSelectionUI || wasShowingSelectionUI {
            let selectionViewSize = CGSize(width: selectionViewWidth, height: 0)
            hOuterStackSubviewInfos.append(selectionViewSize.asManualSubviewInfo(hasFixedWidth: true))
        }
        if isOutgoing || isReleaseNotesMessage {
            // cellSpacer
            hOuterStackSubviewInfos.append(CGSize.zero.asManualSubviewInfo)
        }
        hOuterStackSubviewInfos.append(hInnerStackSize.asManualSubviewInfo(hasFixedWidth: true))
        if isIncoming || isReleaseNotesMessage {
            // cellSpacer
            hOuterStackSubviewInfos.append(CGSize.zero.asManualSubviewInfo)
        }
        if !isIncoming, hasSendFailureBadge {
            let sendFailureBadgeSize = CGSize(square: sendFailureBadgeSize)
            hOuterStackSubviewInfos.append(sendFailureBadgeSize.asManualSubviewInfo(hasFixedWidth: true))
        }
        let hOuterStackMeasurement = ManualStackView.measure(
            config: hOuterStackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_hOuterStack,
            subviewInfos: hOuterStackSubviewInfos,
            maxWidth: maxWidth,
        )

        if let reactionsSubcomponent = subcomponent(forKey: .reactions) {
            let reactionsSize = reactionsSubcomponent.measure(
                maxWidth: maxWidth,
                measurementBuilder: measurementBuilder,
            )
            measurementBuilder.setSize(key: Self.measurementKey_reactions, size: reactionsSize)
        }

        return hOuterStackMeasurement.measuredSize
    }

    // The behavior of this method has to align exactly with that of configureContentStack().
    private func measureContentStack(
        maxWidth contentMaxWidth: CGFloat,
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> CGSize {

        func measure(
            stackConfig: CVStackViewConfig,
            measurementKey: String,
            componentKeys keys: [CVComponentKey],
        ) -> CGSize {
            let maxWidth = contentMaxWidth - stackConfig.layoutMargins.totalWidth
            var subviewSizes = [CGSize]()
            for key in keys {
                guard let subcomponent = self.subcomponent(forKey: key) else {
                    // Not all subcomponents may be present.
                    continue
                }
                let subviewSize = subcomponent.measure(
                    maxWidth: maxWidth,
                    measurementBuilder: measurementBuilder,
                )
                if subviewSize.width > maxWidth {
                    owsFailDebug("key: \(key), subviewSize: \(subviewSize) > maxWidth: \(maxWidth)")
                }
                subviewSizes.append(subviewSize)
            }

            var stackConfig = stackConfig
            func tryToOverlapBodyTextAndFooter() {
                guard
                    keys == [.bodyText, .footer],
                    let bodyText = self.bodyText as? CVComponentBodyText,
                    let standaloneFooter = self.standaloneFooter,
                    !standaloneFooter.tapForMoreState.shouldShowFooter
                else {
                    return
                }
                guard
                    let footerMeasurement = CVComponentFooter.footerMeasurement(measurementBuilder: measurementBuilder),
                    let bodyTextMaxWidth = CVComponentBodyText.bodyTextMaxWidth(measurementBuilder: measurementBuilder),
                    let bodyTextMeasurement = CVComponentBodyText.bodyTextMeasurement(measurementBuilder: measurementBuilder),
                    let lastLineRect = bodyTextMeasurement.lastLineRect,
                    lastLineRect.width > 0,
                    lastLineRect.height > 0
                else {
                    owsFailDebug("Missing measurement state.")
                    return
                }
                guard
                    let bodyTextSubviewSize = subviewSizes.first,
                    bodyTextSubviewSize == bodyTextMeasurement.size
                else {
                    owsFailDebug("Invalid bodyTextSubviewSize.")
                    return
                }

                let textMessageFont = bodyText.textMessageFont
                let lineHeight = max(0, textMessageFont.lineHeight)
                let capHeight = max(0, textMessageFont.capHeight)
                // NOTE: descender is expressed as a negative value.
                let descender = max(0, -textMessageFont.descender)

                // TODO: Design is finalizing how this value should scale with dynamic type.
                let spacingScaling = max(1, lineHeight / 20)
                let kMinimumOverlapSpacingDefault: CGFloat = 6
                let minOverlapSpacing = kMinimumOverlapSpacingDefault * spacingScaling

                let isRTL = CurrentAppContext().isRTL
                let bodyTextSize = bodyTextSubviewSize.width
                let footerSize = footerMeasurement.measuredSize
                let overlappedLastLineWidth = ceil(lastLineRect.width) + minOverlapSpacing + footerSize.width
                let overlappedContentWidth = max(bodyTextSize, overlappedLastLineWidth)
                let hasSpaceForOverlap = overlappedContentWidth <= bodyTextMaxWidth
                guard hasSpaceForOverlap else {
                    return
                }

                // Do collision detection to determine if footer and last line would
                // collide if overlapped.
                let isFooterAlignedLeft = isRTL

                var isBodyTextAlignedLeft = false
                let bodyTextLabelConfig = bodyText.buildBodyTextLabelConfig()
                // For body text messages, textAlignment should reflect the natural
                // alignment of the content.
                switch bodyTextLabelConfig.textAlignment {
                case .left:
                    isBodyTextAlignedLeft = true
                case .right:
                    isBodyTextAlignedLeft = false
                default:
                    // This is expected for edge cases: oversize text messages, remotely deleted, etc.
                    return
                }

                var detectionLastLineFrame = CGRect(origin: .zero, size: lastLineRect.size)
                if !isBodyTextAlignedLeft {
                    detectionLastLineFrame.x = overlappedContentWidth - lastLineRect.width
                }
                // Simplify y-axis for purposes of collision detection.
                detectionLastLineFrame.y = 0
                detectionLastLineFrame.height = 1

                var detectionFooterFrame = CGRect(origin: .zero, size: footerSize)
                if !isFooterAlignedLeft {
                    detectionFooterFrame.x = overlappedContentWidth - footerSize.width
                }
                // Inset one of the frames to account for the "min overlap spacing".
                detectionFooterFrame = detectionFooterFrame.insetBy(dx: -minOverlapSpacing, dy: 0)
                detectionFooterFrame.y = 0
                detectionFooterFrame.height = 1

                let doComponentsIntersect = detectionLastLineFrame.intersects(detectionFooterFrame)

                guard !doComponentsIntersect else {
                    return
                }

                let fontOuterSpacing = max(0, lineHeight - (capHeight + descender)) * 0.5
                let baselineSpacing = max(0, fontOuterSpacing + descender)
                // We want to v-align the center of the footer with the baseline of the
                // last line of body text.
                let overlapHeight = footerMeasurement.measuredSize.height * 0.5 + baselineSpacing
                let bottomNestedTextSpacing = -overlapHeight

                // 1. Rewrite the stack spacing for overlap.
                stackConfig = stackConfig.withSpacing(bottomNestedTextSpacing)

                // 2. Store the spacing for usage when rendering.
                measurementBuilder.setValue(
                    key: Self.measurementKey_bottomNestedTextSpacing,
                    value: bottomNestedTextSpacing,
                )

                // 3. Rewrite the body text component size for overlap.
                subviewSizes[0] = CGSize(
                    width: overlappedContentWidth,
                    height: bodyTextSubviewSize.height,
                )
            }
            tryToOverlapBodyTextAndFooter()

            let subviewInfos: [ManualStackSubviewInfo] = subviewSizes.map { subviewSize in
                subviewSize.asManualSubviewInfo
            }

            let stackMeasurement = ManualStackView.measure(
                config: stackConfig,
                measurementBuilder: measurementBuilder,
                measurementKey: measurementKey,
                subviewInfos: subviewInfos,
            )
            return stackMeasurement.measuredSize
        }

        if componentState.isBorderlessStickerMessage {
            // Borderless sticker message.
            //
            // Stack is borderless.
            // Optional footer.
            return measure(
                stackConfig: buildBorderlessStackConfig(),
                measurementKey: Self.measurementKey_contentStack,
                componentKeys: [.senderName, .sticker, .footer],
            )
        } else {
            // The non-sticker case.
            // Use multiple stacks.

            let contentSections = buildContentSections()

            var subviewSizes = [CGSize]()
            enumerate(contentSections: contentSections) { (contentSection: ContentSection, stackConfig: CVStackViewConfig) in
                guard let stackMeasurementKey = contentSection.stackMeasurementKey else {
                    owsFailDebug("Missing stackMeasurementKey.")
                    return
                }
                let componentKeys = contentSection.components.map { $0.componentKey }
                let stackSize = measure(
                    stackConfig: stackConfig,
                    measurementKey: stackMeasurementKey,
                    componentKeys: componentKeys,
                )
                subviewSizes.append(stackSize)
            }
            // Append the bottom buttons if necessary.
            if let bottomButtons {
                let subviewSize = bottomButtons.measure(
                    maxWidth: contentMaxWidth,
                    measurementBuilder: measurementBuilder,
                )
                subviewSizes.append(subviewSize)
            }

            if let bottomLabel {
                let subviewSize = bottomLabel.measure(
                    maxWidth: contentMaxWidth,
                    measurementBuilder: measurementBuilder,
                )
                subviewSizes.append(subviewSize)
            }

            let subviewInfos: [ManualStackSubviewInfo] = subviewSizes.map { subviewSize in
                subviewSize.asManualSubviewInfo
            }
            return ManualStackView.measure(
                config: buildContentStackConfig(),
                measurementBuilder: measurementBuilder,
                measurementKey: Self.measurementKey_contentStack,
                subviewInfos: subviewInfos,
            ).measuredSize
        }
    }

    // MARK: - Events

    override public func cellWillBecomeVisible(componentDelegate: any CVComponentDelegate) {
        subcomponents(forKeys: CVComponentKey.allCases).forEach { subcomponent in
            subcomponent.cellWillBecomeVisible(componentDelegate: componentDelegate)
        }
    }

    override public func handleTap(
        sender: UIGestureRecognizer,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem,
    ) -> Bool {
        guard let componentView = componentView as? CVComponentViewMessage else {
            owsFailDebug("Unexpected componentView.")
            return false
        }

        if isShowingSelectionUI {
            // By default, use primarySelectionView to handle .allContent...
            let primarySelectionView = componentView.primarySelectionView
            var selectionView = primarySelectionView
            var selectionType: CVSelectionType = .allContent

            // ...but we might have separate "primary" and "secondary" selections.
            // "Primary" is "everything but body text" and "secondary" is "just body text".
            if hasSecondaryContentForSelection {
                let secondarySelectionView = componentView.secondarySelectionView
                func distanceToViewCenter(_ view: UIView) -> CGFloat {
                    let tapLocation = sender.location(in: view)
                    let viewCenter = view.bounds.center
                    return tapLocation.distance(viewCenter)
                }
                let primaryDistance = distanceToViewCenter(primarySelectionView)
                let secondaryDistance = distanceToViewCenter(secondarySelectionView)
                if primaryDistance < secondaryDistance {
                    selectionView = primarySelectionView
                    selectionType = .primaryContent
                } else {
                    selectionView = secondarySelectionView
                    selectionType = .secondaryContent
                }
            }

            let itemViewModel = CVItemViewModelImpl(renderItem: renderItem)
            let selectionState = componentDelegate.selectionState
            if selectionState.isSelected(interaction.uniqueId, selectionType: selectionType) {
                selectionView.isSelected = false
                componentDelegate.selectionState.remove(
                    itemViewModel: itemViewModel,
                    selectionType: selectionType,
                )
            } else {
                selectionView.isSelected = true
                componentDelegate.selectionState.add(
                    itemViewModel: itemViewModel,
                    selectionType: selectionType,
                )
            }

            // Suppress other tap handling during selection mode.
            return true
        }

        if let outgoingMessage = interaction as? TSOutgoingMessage, !(outgoingMessage is OWSPaymentMessage) {
            switch outgoingMessage.messageState {
            case .failed:
                // Tap to retry.
                componentDelegate.didTapFailedMessage(outgoingMessage)
                return true
            case .pending:
                componentDelegate.didTapPendingOutgoingMessage(outgoingMessage)
                return true
            case .sending:
                // Sending messages should still allow taps to be processed
                break
            default:
                break
            }
        }

        if let message = interaction as? TSIncomingMessage, message.wasRemotelyDeleted {
            let db = DependenciesBridge.shared.db
            let recipientAddressStates = db.read { tx in
                AdminDeleteManager.recipientAddressStates(message: message, tx: tx)
            }
            if AdminDeleteManager.isFailedAdminDelete(recipientAddressStates: recipientAddressStates) {
                componentDelegate.didTapFailedMessage(message)
                return true
            }
        }

        if
            hasSenderAvatar,
            componentView.avatarView.containsGestureLocation(sender)
        {
            componentDelegate.didTapSenderAvatar(interaction)
            return true
        }

        for subcomponentAndView in findComponentAndViews(sender: sender, componentView: componentView) {
            let subcomponent = subcomponentAndView.component
            let subcomponentView = subcomponentAndView.componentView
            if
                subcomponent.handleTap(
                    sender: sender,
                    componentDelegate: componentDelegate,
                    componentView: subcomponentView,
                    renderItem: renderItem,
                )
            {
                return true
            }
        }

        if let message = interaction as? TSMessage, componentState.skippedDownloads != nil {
            componentDelegate.didTapSkippedDownloads(message)
            return true
        }

        return false
    }

    override public func canHandleDoubleTap(
        sender: UIGestureRecognizer,
        componentDelegate: any CVComponentDelegate,
        renderItem: CVRenderItem,
    ) -> Bool {
        if isShowingSelectionUI {
            return false
        }

        let viewModel = CVItemViewModelImpl(renderItem: renderItem)
        return viewModel.canEditMessage
    }

    override public func handleDoubleTap(sender: UIGestureRecognizer, componentDelegate: any CVComponentDelegate, renderItem: CVRenderItem) -> Bool {
        guard canHandleDoubleTap(sender: sender, componentDelegate: componentDelegate, renderItem: renderItem) else {
            return false
        }

        let viewModel = CVItemViewModelImpl(renderItem: renderItem)
        componentDelegate.didDoubleTapTextViewItem(viewModel)
        return true
    }

    override public func findLongPressHandler(
        sender: UIGestureRecognizer,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem,
    ) -> CVLongPressHandler? {

        guard let componentView = componentView as? CVComponentViewMessage else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }

        if
            let componentAndView = findActiveComponentAndView(
                key: .bodyText,
                messageView: componentView,
                ignoreMissing: true,
            ),
            let handler = componentAndView.component.findLongPressHandler(
                sender: sender,
                componentDelegate: componentDelegate,
                componentView: componentAndView.componentView,
                renderItem: renderItem,
            )
        {
            return handler
        }

        let longPressKeys: [CVComponentKey: CVLongPressHandler.GestureLocation] = [
            .sticker: .sticker,
            .bodyMedia: .media,
            .audioAttachment: .media,
            .genericAttachment: .media,
            .quotedReply: .quotedReply,
            .paymentAttachment: .paymentMessage,
            .archivedPaymentAttachment: .paymentMessage,
            .poll: .poll,

            // Bottom buttons, labels, and footers are associated
            // with other components and should not have unique long-press actions.
            .bottomButtons: .associatedSubcomponent,
            .bottomLabel: .associatedSubcomponent,
            .footer: .associatedSubcomponent,
            // TODO: linkPreview?
        ]
        // Recognize the correct message type when tapping next to the message itself
        let hotArea = UIEdgeInsets(hMargin: -.greatestFiniteMagnitude, vMargin: 0)
        for (key, gestureLocation) in longPressKeys {
            if
                let subcomponentView = componentView.subcomponentView(key: key),
                subcomponentView.rootView.containsGestureLocation(sender, hotAreaInsets: hotArea)
            {
                return CVLongPressHandler(
                    delegate: componentDelegate,
                    renderItem: renderItem,
                    gestureLocation: gestureLocation,
                )
            }
        }

        return CVLongPressHandler(
            delegate: componentDelegate,
            renderItem: renderItem,
            gestureLocation: .`default`,
        )
    }

    // For a configured & active cell, this will return the list of
    // currently active subcomponents & their corresponding subcomponent
    // views. This can be used for gesture dispatch, etc.
    private func findComponentAndViews(
        sender: UIGestureRecognizer,
        componentView: CVComponentViewMessage,
    ) -> [CVComponentAndView] {
        return activeComponentAndViews(messageView: componentView).compactMap { subcomponentAndView in
            let subcomponentView = subcomponentAndView.componentView
            let rootView = subcomponentView.rootView
            if rootView.containsGestureLocation(sender) {
                return subcomponentAndView
            }
            return nil
        }
    }

    // For a configured & active cell, this will return the list of
    // currently active subcomponents & their corresponding subcomponent
    // views. This can be used for gesture dispatch, etc.
    private func activeComponentAndViews(messageView: CVComponentViewMessage) -> [CVComponentAndView] {
        var result = [CVComponentAndView]()
        for key in CVComponentKey.allCases {
            guard
                let componentAndView = findActiveComponentAndView(
                    key: key,
                    messageView: messageView,
                    ignoreMissing: true,
                )
            else {
                continue
            }
            result.append(componentAndView)
        }
        return result
    }

    // For a configured & active cell, this will return a (component,
    // component view) tuple IFF that component is active.
    private func findActiveComponentAndView(
        key: CVComponentKey,
        messageView: CVComponentViewMessage,
        ignoreMissing: Bool = false,
    ) -> CVComponentAndView? {
        guard let subcomponent = self.subcomponent(forKey: key) else {
            // Not all subcomponents will be active.
            return nil
        }
        guard let subcomponentView = messageView.subcomponentView(key: key) else {
            if !ignoreMissing {
                owsFailDebug("Missing subcomponentView.")
            }
            return nil
        }
        return CVComponentAndView(key: key, component: subcomponent, componentView: subcomponentView)
    }

    public func albumItemView(
        forAttachment attachment: ReferencedAttachment,
        componentView: CVComponentView,
    ) -> UIView? {
        guard let componentView = componentView as? CVComponentViewMessage else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }
        guard
            let componentAndView = findActiveComponentAndView(
                key: .bodyMedia,
                messageView: componentView,
            )
        else {
            owsFailDebug("Missing bodyMedia subcomponent.")
            return nil
        }
        guard let bodyMediaComponent = componentAndView.component as? CVComponentBodyMedia else {
            owsFailDebug("Unexpected subcomponent.")
            return nil
        }
        let bodyMediaComponentView = componentAndView.componentView
        return bodyMediaComponent.albumItemView(
            forAttachment: attachment,
            componentView: bodyMediaComponentView,
        )
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    public class CVComponentViewMessage: NSObject, CVComponentView {

        // Contains the cell contents which are arranged horizontally:
        //
        // * Gutters
        // * Message Selection UI
        // * hInnerStack
        // * "Send failure" badge
        fileprivate let hOuterStack = ManualStackView(name: "message.hOuterStack")

        // Contains the cell contents which are arranged horizontally:
        //
        // * Group sender avatar
        // * Content view wrapped in message bubble _or_ unwrapped content view.
        //
        // Additionally, it contains:
        //
        // * Reactions view, which uses a custom layout block.
        fileprivate let hInnerStack = ManualStackView(name: "message.hInnerStack")

        fileprivate let avatarView = ConversationAvatarView(
            sizeClass: ConversationStyle.groupMessageAvatarSizeClass,
            localUserDisplayMode: .asUser,
            useAutolayout: false,
        )

        // This view provides background for outgoing messages in all scenarios
        // and for incoming messages when there's no chat wallpaper.
        fileprivate let chatColorView = CVColorOrGradientView()
        // This view provides background for incoming messages when
        // there is a chat wallpaper and bubble background is "blur".
        fileprivate var wallpaperBlurView: CVWallpaperBlurView?
        fileprivate func ensureWallpaperBlurView() -> CVWallpaperBlurView {
            if let wallpaperBlurView {
                return wallpaperBlurView
            }
            let wallpaperBlurView = CVWallpaperBlurView()
            self.wallpaperBlurView = wallpaperBlurView
            return wallpaperBlurView
        }

        // Contains the actual renderable message content, arranged vertically.
        fileprivate let contentStack = ManualStackView(name: "message.contentStack")

        // Tellomi（#1205）：有尾巴时，气泡里的内容放进这一层、再在尾巴那一侧缩回。
        fileprivate let tellomiTailContentView = ManualLayoutView(name: "message.tellomiTailContentView")

        // We use these stack views when there is a mixture of subcomponents,
        // some of which are full-width and some of which are not.
        fileprivate let topFullWidthStackView = ManualStackView(name: "message.topFullWidthStackView")
        fileprivate let topNestedStackView = ManualStackView(name: "message.topNestedStackView")
        fileprivate let bottomFullWidthStackView = ManualStackView(name: "message.bottomFullWidthStackView")
        fileprivate let bottomNestedShareStackView = ManualStackView(name: "message.bottomNestedShareStackView")
        fileprivate let bottomNestedTextStackView = ManualStackView(name: "message.bottomNestedTextStackView")
        // Tellomi（ADR-0068 §4.7）：说明文字在媒体上方时用的两节。
        fileprivate let tellomiCaptionAboveTextStackView = ManualStackView(name: "message.tellomiCaptionAboveTextStackView")
        fileprivate let tellomiCaptionAboveMediaStackView = ManualStackView(name: "message.tellomiCaptionAboveMediaStackView")

        // If hasSecondaryContentForSelection is false, this is used to select
        // all content.
        //
        // If hasSecondaryContentForSelection is true, this is used to select
        // everything except the body text, e.g. the body media or generic attachment.
        fileprivate lazy var primarySelectionView = MessageSelectionView()
        // If hasSecondaryContentForSelection is true, this is used to select
        // just the body text.
        fileprivate lazy var secondarySelectionView = MessageSelectionView()
        fileprivate let selectionWrapper = ManualLayoutView(name: "message.selectionWrapper")

        fileprivate let swipeToReplyIconView = SwipeToReplyIndicatorView()

        fileprivate let cellSpacerLeading = UIView()
        fileprivate let cellSpacerTrailing = UIView()

        fileprivate let avatarViewSwipeToReplyWrapper = SwipeToReplyWrapper(
            name: "avatarViewSwipeToReplyWrapper",
            useSlowOffset: true,
            shouldReset: false,
        )
        fileprivate let swipeToReplyIconSwipeToReplyWrapper = SwipeToReplyWrapper(
            name: "swipeToReplyIconSwipeToReplyWrapper",
            useSlowOffset: true,
            shouldReset: false,
        )
        fileprivate var contentViewSwipeToReplyWrapper = SwipeToReplyWrapper(
            name: "contentViewSwipeToReplyWrapper",
            useSlowOffset: false,
            shouldReset: true,
        )
        fileprivate var reactionsSwipeToReplyWrapper = SwipeToReplyWrapper(
            name: "reactionsSwipeToReplyWrapper",
            useSlowOffset: false,
            shouldReset: true,
        )
        fileprivate var swipeToReplyWrappers: [SwipeToReplyWrapper] {
            [
                avatarViewSwipeToReplyWrapper,
                swipeToReplyIconSwipeToReplyWrapper,
                contentViewSwipeToReplyWrapper,
                reactionsSwipeToReplyWrapper,
            ]
        }

        public var isDedicatedCellView = false

        public var rootView: UIView {
            hOuterStack
        }

        // MARK: - Subcomponents

        var senderNameView: CVComponentView?
        var bodyTextView: CVComponentView?
        var bodyMediaView: CVComponentView?
        var footerView: CVComponentView?
        var stickerView: CVComponentView?
        var viewOnceView: CVComponentView?
        var quotedReplyView: CVComponentView?
        var linkPreviewView: CVComponentView?
        var giftBadgeView: CVComponentView?
        var reactionsView: CVComponentView?
        var audioAttachmentView: CVComponentView?
        var genericAttachmentView: CVComponentView?
        var paymentAttachmentView: CVComponentView?
        var undownloadableAttachmentView: CVComponentView?
        var archivedPaymentView: CVComponentView?
        var contactShareView: CVComponentView?
        var bottomButtonsView: CVComponentView?
        var bottomLabelView: CVComponentView?
        var pollView: CVComponentView?

        private var allSubcomponentViews: [CVComponentView] {
            [
                senderNameView,
                bodyTextView,
                bodyMediaView,
                footerView,
                stickerView,
                viewOnceView,
                quotedReplyView,
                linkPreviewView,
                giftBadgeView,
                reactionsView,
                audioAttachmentView,
                genericAttachmentView,
                paymentAttachmentView,
                undownloadableAttachmentView,
                archivedPaymentView,
                contactShareView,
                bottomButtonsView,
                bottomLabelView,
                pollView,
            ].compactMap { $0 }
        }

        /// Tellomi（交互审计 A-07）：回应飞入的落点——这条消息回应胶囊里显示 [emoji] 的那个字。
        func reactionEmojiLabel(for emoji: String) -> UILabel? {
            (reactionsView as? CVComponentReactions.CVComponentViewReactions)?.emojiLabel(for: emoji)
        }

        fileprivate func subcomponentView(key: CVComponentKey) -> CVComponentView? {
            switch key {
            case .senderName:
                return senderNameView
            case .bodyText:
                return bodyTextView
            case .bodyMedia:
                return bodyMediaView
            case .footer:
                return footerView
            case .sticker:
                return stickerView
            case .viewOnce:
                return viewOnceView
            case .quotedReply:
                return quotedReplyView
            case .linkPreview:
                return linkPreviewView
            case .giftBadge:
                return giftBadgeView
            case .reactions:
                return reactionsView
            case .audioAttachment:
                return audioAttachmentView
            case .genericAttachment:
                return genericAttachmentView
            case .paymentAttachment:
                return paymentAttachmentView
            case .archivedPaymentAttachment:
                return archivedPaymentView
            case .undownloadableAttachment:
                return undownloadableAttachmentView
            case .contactShare:
                return contactShareView
            case .bottomButtons:
                return bottomButtonsView
            case .poll:
                return pollView
            case .bottomLabel:
                return bottomLabelView
            // We don't render sender avatars with a subcomponent.
            case .senderAvatar:
                owsFailDebug("Invalid component key: \(key)")
                return nil
            case .systemMessage, .dateHeader, .unreadIndicator, .typingIndicator, .threadDetails, .skippedDownloads, .sendFailureBadge, .unknownThreadWarning, .defaultDisappearingMessageTimer, .collapseSet, .messageRoot:
                owsFailDebug("Invalid component key: \(key)")
                return nil
            }
        }

        fileprivate func setSubcomponentView(key: CVComponentKey, subcomponentView: CVComponentView?) {
            switch key {
            case .senderName:
                senderNameView = subcomponentView
            case .bodyText:
                bodyTextView = subcomponentView
            case .bodyMedia:
                bodyMediaView = subcomponentView
            case .footer:
                footerView = subcomponentView
            case .sticker:
                stickerView = subcomponentView
            case .viewOnce:
                viewOnceView = subcomponentView
            case .quotedReply:
                quotedReplyView = subcomponentView
            case .linkPreview:
                linkPreviewView = subcomponentView
            case .giftBadge:
                giftBadgeView = subcomponentView
            case .reactions:
                reactionsView = subcomponentView
            case .audioAttachment:
                audioAttachmentView = subcomponentView
            case .genericAttachment:
                genericAttachmentView = subcomponentView
            case .paymentAttachment:
                paymentAttachmentView = subcomponentView
            case .archivedPaymentAttachment:
                archivedPaymentView = subcomponentView
            case .undownloadableAttachment:
                undownloadableAttachmentView = subcomponentView
            case .contactShare:
                contactShareView = subcomponentView
            case .bottomButtons:
                bottomButtonsView = subcomponentView
            case .poll:
                pollView = subcomponentView
            case .bottomLabel:
                bottomLabelView = subcomponentView
            // We don't render sender avatars with a subcomponent.
            case .senderAvatar:
                owsAssertDebug(subcomponentView == nil)
            case .systemMessage, .dateHeader, .unreadIndicator, .typingIndicator, .threadDetails, .skippedDownloads, .sendFailureBadge, .unknownThreadWarning, .defaultDisappearingMessageTimer, .collapseSet, .messageRoot:
                owsAssertDebug(subcomponentView == nil)
            }
        }

        // MARK: -

        override init() {
            chatColorView.layoutMargins = .zero
            chatColorView.ensureSubviewsFillBounds = true

            avatarViewSwipeToReplyWrapper.subview = avatarView
            swipeToReplyIconSwipeToReplyWrapper.subview = swipeToReplyIconView
            // Configure contentViewSwipeToReplyWrapper and
            // reactionsSwipeToReplyWrapper later.
        }

        public func setIsCellVisible(_ isCellVisible: Bool) {
            for subcomponentView in allSubcomponentViews {
                subcomponentView.setIsCellVisible(isCellVisible)
            }
            if isCellVisible {
                chatColorView.updateAppearance()
            }
        }

        public func setSwipeToReplyOffset(
            fastOffset: CGPoint,
            slowOffset: CGPoint,
        ) {
            for swipeToReplyWrapper in swipeToReplyWrappers {
                let offset = (
                    swipeToReplyWrapper.useSlowOffset
                        ? slowOffset
                        : fastOffset,
                )
                swipeToReplyWrapper.offset = offset
            }
        }

        public func reset() {
            removeSwipeActionAnimations()

            if !isDedicatedCellView {
                hOuterStack.reset()
                hInnerStack.reset()
                contentStack.reset()
                topFullWidthStackView.reset()
                topNestedStackView.reset()
                bottomFullWidthStackView.reset()
                bottomNestedShareStackView.reset()
                bottomNestedTextStackView.reset()
                tellomiCaptionAboveTextStackView.reset()
                tellomiCaptionAboveMediaStackView.reset()

                for swipeToReplyWrapper in swipeToReplyWrappers {
                    if swipeToReplyWrapper.shouldReset {
                        swipeToReplyWrapper.reset()
                    } else {
                        swipeToReplyWrapper.offset = .zero
                    }
                }
            }

            selectionWrapper.reset()

            contentStack.removeFromSuperview()

            chatColorView.removeFromSuperview()
            chatColorView.reset()

            tellomiTailContentView.removeFromSuperview()
            tellomiTailContentView.reset()

            wallpaperBlurView?.removeFromSuperview()

            avatarView.reset()

            swipeToReplyIconView.alpha = 0

            // We use hInnerStack.frame to detect whether or not
            // the cell has been laid out yet. Therefore we clear it here.
            hInnerStack.frame = .zero

            if isDedicatedCellView {
                for subcomponentView in allSubcomponentViews {
                    subcomponentView.isDedicatedCellView = true
                }
            }

            for subcomponentView in allSubcomponentViews {
                subcomponentView.reset()
            }

            if !isDedicatedCellView {
                for key in CVComponentKey.allCases {
                    // Don't clear bodyTextView; it is expensive to build.
                    if key != .bodyText {
                        self.setSubcomponentView(key: key, subcomponentView: nil)
                    }
                }
            }
        }

        public func canHandleDoubleTapGesture(_ sender: UIGestureRecognizer) -> Bool {
            // If we have a body text view, allow taps anywhere (incl. adjacent whitespace).
            return bodyTextView != nil
        }

        public func contextMenuContentView() -> UIView? {
            chatColorView.animationsEnabled = true
            // Tellomi（#1205）：交出气泡视图本身，不交包装：尾巴画在包装外扩出去的那一条里，
            // 长按预览按视图自己的范围截图，交包装会截掉尾巴、那个角变成直角。
            return contentViewSwipeToReplyWrapper.subview ?? contentViewSwipeToReplyWrapper
        }

        public func contextMenuAuxiliaryContentView() -> UIView? {
            reactionsSwipeToReplyWrapper
        }

        public func contextMenuPresentationWillBegin() {
            avatarView.isHidden = true
        }

        public func contextMenuPresentationDidEnd() {
            avatarView.isHidden = false
            chatColorView.animationsEnabled = false
        }

        fileprivate func removeSwipeActionAnimations() {
            // Tellomi（A-10）：回位弹簧停在当前位置（手指又按住了，或这一格要复用）。
            tellomiSwipeReturnAnimator?.stopAnimation(true)
            tellomiSwipeReturnAnimator = nil
            for swipeToReplyWrapper in swipeToReplyWrappers {
                swipeToReplyWrapper.layer.removeAllAnimations()
            }
        }

        /// Tellomi（交互审计 A-10）：滑动回复松手后的回位弹簧。
        private var tellomiSwipeReturnAnimator: UIViewPropertyAnimator?

        /// Tellomi（A-10）：气泡、图标、头像各层从当前位置用 `TellomiMotion.release` 弹簧回到原位；
        /// `initialVelocity` 是「每秒走完剩余路程的比例」（`TellomiMotion.relativeVelocity`），快慢两层按同一比例走。
        fileprivate func startSwipeToReplyReturn(initialVelocity: CGVector) {
            AssertIsOnMainThread()
            tellomiSwipeReturnAnimator?.stopAnimation(true)
            let animator = MainActor.assumeIsolated {
                TellomiMotion.animator(TellomiMotion.release, initialVelocity: initialVelocity) { [weak self] in
                    self?.setSwipeToReplyOffset(fastOffset: .zero, slowOffset: .zero)
                }
            }
            animator.addCompletion { [weak self, weak animator] _ in
                guard let self, let animator, self.tellomiSwipeReturnAnimator === animator else {
                    return
                }
                self.tellomiSwipeReturnAnimator = nil
            }
            tellomiSwipeReturnAnimator = animator
            animator.startAnimation()
        }

        // MARK: - Flashing Message Bubble

        func performMessageBubbleHighlightAnimation() {
            var dimmableBubbleView: CVDimmableView?
            if let wallpaperBlurView, wallpaperBlurView.superview != nil {
                dimmableBubbleView = wallpaperBlurView
            } else if chatColorView.superview != nil {
                dimmableBubbleView = chatColorView
            }
            guard let dimmableBubbleView else { return }
            dimmableBubbleView.dimmerColor = Theme.isDarkThemeEnabled ? .ows_whiteAlpha25 : .ows_blackAlpha25
            dimmableBubbleView.performDimmingAnimation(animationDuration: 0.4, dimDuration: 0.8)
        }
    }

    // MARK: - Swipe To Reply

    override public func findPanHandler(
        sender: UIPanGestureRecognizer,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem,
        messageSwipeActionState: CVMessageSwipeActionState,
    ) -> CVPanHandler? {
        AssertIsOnMainThread()

        guard let componentView = componentView as? CVComponentViewMessage else {
            owsFailDebug("Unexpected componentView.")
            return nil
        }

        if
            let audioAttachment = self.audioAttachment,
            let subcomponentView = componentView.subcomponentView(key: .audioAttachment),
            subcomponentView.rootView.containsGestureLocation(sender),
            let panHandler = audioAttachment.findPanHandler(
                sender: sender,
                componentDelegate: componentDelegate,
                componentView: subcomponentView,
                renderItem: renderItem,
                messageSwipeActionState: messageSwipeActionState,
            )
        {
            return panHandler
        }

        return CVPanHandler(
            delegate: componentDelegate,
            panType: .messageSwipeAction,
            renderItem: renderItem,
        )
    }

    override public func startPanGesture(
        sender: UIPanGestureRecognizer,
        panHandler: CVPanHandler,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem,
        messageSwipeActionState: CVMessageSwipeActionState,
    ) {
        AssertIsOnMainThread()

        guard let componentView = componentView as? CVComponentViewMessage else {
            owsFailDebug("Unexpected componentView.")
            return
        }
        owsAssertDebug(sender.state == .began)

        switch panHandler.panType {
        case .scrubAudio:
            guard
                let audioAttachment = self.audioAttachment,
                let subcomponentView = componentView.subcomponentView(key: .audioAttachment)
            else {
                owsFailDebug("Missing audio attachment component.")
                return
            }
            audioAttachment.startPanGesture(
                sender: sender,
                panHandler: panHandler,
                componentDelegate: componentDelegate,
                componentView: subcomponentView,
                renderItem: renderItem,
                messageSwipeActionState: messageSwipeActionState,
            )
        case .messageSwipeAction:
            updateSwipeActionProgress(
                sender: sender,
                panHandler: panHandler,
                componentDelegate: componentDelegate,
                renderItem: renderItem,
                componentView: componentView,
                messageSwipeActionState: messageSwipeActionState,
                hasFinished: false,
            )
            tryToApplySwipeAction(componentView: componentView)
        }
    }

    override public func handlePanGesture(
        sender: UIPanGestureRecognizer,
        panHandler: CVPanHandler,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem,
        messageSwipeActionState: CVMessageSwipeActionState,
    ) {
        AssertIsOnMainThread()

        guard let componentView = componentView as? CVComponentViewMessage else {
            owsFailDebug("Unexpected componentView.")
            return
        }

        switch panHandler.panType {
        case .scrubAudio:
            guard
                let audioAttachment = self.audioAttachment,
                let subcomponentView = componentView.subcomponentView(key: .audioAttachment)
            else {
                owsFailDebug("Missing audio attachment component.")
                return
            }
            audioAttachment.handlePanGesture(
                sender: sender,
                panHandler: panHandler,
                componentDelegate: componentDelegate,
                componentView: subcomponentView,
                renderItem: renderItem,
                messageSwipeActionState: messageSwipeActionState,
            )
        case .messageSwipeAction:
            let hasFinished: Bool
            switch sender.state {
            case .changed:
                hasFinished = false
            case .ended:
                hasFinished = true
            default:
                clearSwipeAction(
                    componentView: componentView,
                    renderItem: renderItem,
                    messageSwipeActionState: messageSwipeActionState,
                    isAnimated: false,
                )
                return
            }
            // Tellomi（交互审计 A-10）：松手前记下气泡这一刻对应的手指位移（上一次 .changed 的），回位弹簧从这里出发。
            // 原来松手时 `tryToApplySwipeAction` 读到已清零的进度、不带动画把位移设成 0，之后的 0.2 s 补间是 0 → 0。
            let releaseFingerOffset = max(-(swipeActionProgress?.xOffset ?? 0), 0)
            updateSwipeActionProgress(
                sender: sender,
                panHandler: panHandler,
                componentDelegate: componentDelegate,
                renderItem: renderItem,
                componentView: componentView,
                messageSwipeActionState: messageSwipeActionState,
                hasFinished: hasFinished,
            )
            if sender.state == .ended {
                clearSwipeAction(
                    componentView: componentView,
                    renderItem: renderItem,
                    messageSwipeActionState: messageSwipeActionState,
                    isAnimated: true,
                    releaseFingerOffset: releaseFingerOffset,
                    releaseFingerVelocity: Self.tellomiReplyDirectionVelocity(sender: sender, in: componentView.rootView),
                )
            } else {
                tryToApplySwipeAction(componentView: componentView)
            }
        }
    }

    override public func contextMenuAccessoryViews(componentView: CVComponentView) -> [ContextMenuTargetedPreviewAccessory]? {
        if hasSenderAvatar {
            guard let componentView = componentView as? CVComponentViewMessage else {
                owsFailDebug("Unexpected componentView.")
                return nil
            }

            let avatarView = ConversationAvatarView(sizeClass: componentView.avatarView.configuration.sizeClass, localUserDisplayMode: .asUser)
            avatarView.updateWithSneakyTransactionIfNecessary { newConfig in
                newConfig = componentView.avatarView.configuration
            }
            avatarView.frame = componentView.avatarView.bounds
            let isRTL = CurrentAppContext().isRTL
            let horizontalEdgeAlignment: ContextMenuTargetedPreviewAccessory.AccessoryAlignment.Edge = isRTL ? .trailing : .leading
            let alignment = ContextMenuTargetedPreviewAccessory.AccessoryAlignment(alignments: [(horizontalEdgeAlignment, .exterior), (.bottom, .interior)], alignmentOffset: CGPoint(x: 8, y: 0))
            let avatarViewAccessory = ContextMenuTargetedPreviewAccessory(accessoryView: avatarView, accessoryAlignment: alignment)
            avatarViewAccessory.animateAccessoryPresentationAlongsidePreview = true
            return [avatarViewAccessory]
        } else {
            return nil
        }
    }

    private var swipeActionOffsetThreshold: CGFloat {
        Self.tellomiSwipeToReplyThreshold(isIncoming: isIncoming)
    }

    /// Tellomi（tellomi/tellomi#1109，ADR-0058 §2）：过这个位移松手才算回复——对方的消息 45、自己的 60
    /// （Telegram `ChatMessageBubbleItemNode.swipeToReplyGesture` 同值）。
    static func tellomiSwipeToReplyThreshold(isIncoming: Bool) -> CGFloat {
        isIncoming ? 45 : 60
    }

    /// Tellomi（tellomi/tellomi#1109，ADR-0058 §2）：手指沿回复方向走了 `fingerOffset` → 气泡跟着走多少。
    /// 阈值内 1:1 跟手，过阈值后橡皮筋（range 100、系数 0.4），整体最多 180。
    static func tellomiSwipeToReplyBubbleOffset(fingerOffset: CGFloat, threshold: CGFloat) -> CGFloat {
        guard fingerOffset > threshold else {
            return max(fingerOffset, 0)
        }
        let range: CGFloat = 100
        let overflow = fingerOffset - threshold
        let band = (1 - 1 / (overflow * 0.4 / range + 1)) * range
        return min(threshold + band, 180)
    }

    /// Tellomi（交互审计 A-10，标准第四节「判定用投射落点」）：投射落点里速度乘的时间，0.1 s（与 Android 同值，
    /// 相当于 `UIScrollView.DecelerationRate.fast` 的投射距离）。1000 pt/s 的一甩多算 100 pt，200 pt/s 的晃动只多算 20 pt。
    static let tellomiSwipeToReplyProjectionSeconds: CGFloat = 0.1

    /// Tellomi（A-10）：松手时手指在 `fingerOffset`、速度 `fingerVelocity`（沿回复方向为正，pt/s）：投射落点过阈值就回复。
    /// 快速一甩也算，往回甩取消。
    static func tellomiSwipeToReplyShouldReply(fingerOffset: CGFloat, fingerVelocity: CGFloat, threshold: CGFloat) -> Bool {
        fingerOffset + fingerVelocity * tellomiSwipeToReplyProjectionSeconds > threshold
    }

    /// Tellomi（A-10）：手指在 `fingerOffset` 处以 `fingerVelocity` 移动时气泡的速度——橡皮筋在这一点的斜率 × 手指速度。
    /// 阈值内 1:1；到了上限或还没出发时气泡不动。松手回位的弹簧从这个速度起步。
    static func tellomiSwipeToReplyBubbleVelocity(fingerOffset: CGFloat, fingerVelocity: CGFloat, threshold: CGFloat) -> CGFloat {
        guard fingerOffset >= 0 else {
            return 0
        }
        guard fingerOffset > threshold else {
            return fingerVelocity
        }
        guard tellomiSwipeToReplyBubbleOffset(fingerOffset: fingerOffset, threshold: threshold) < 180 else {
            return 0
        }
        let d = (fingerOffset - threshold) * 0.4 / 100 + 1
        return fingerVelocity * 0.4 / (d * d)
    }

    /// Tellomi（A-10）：越过 / 退回阈值的触感（标准第五节 `.impact(.light)`，带 view 的写法）。手势回调都在主线程。
    private static func tellomiThresholdHaptic(in view: UIView) {
        MainActor.assumeIsolated {
            ImpactHapticFeedback.impactOccurred(style: .light, in: view)
        }
    }

    /// Tellomi（A-10）：手势沿回复方向的速度（pt/s，往回复方向为正；RTL 镜像）。
    private static func tellomiReplyDirectionVelocity(sender: UIPanGestureRecognizer, in view: UIView) -> CGFloat {
        let xVelocity = sender.velocity(in: view).x
        return CurrentAppContext().isRTL ? xVelocity : -xVelocity
    }

    private func updateSwipeActionProgress(
        sender: UIPanGestureRecognizer,
        panHandler: CVPanHandler,
        componentDelegate: CVComponentDelegate,
        renderItem: CVRenderItem,
        componentView: CVComponentViewMessage,
        messageSwipeActionState: CVMessageSwipeActionState,
        hasFinished: Bool,
    ) {
        AssertIsOnMainThread()

        var xOffset = sender.translation(in: componentView.rootView).x

        // Invert positions for RTL logic, since the user is swiping in the opposite direction.
        if CurrentAppContext().isRTL {
            xOffset = -xOffset
        }

        let hasFailed = [.failed, .cancelled].contains(sender.state)
        let storedOffset = (hasFailed || hasFinished) ? 0 : xOffset
        let progress = CVMessageSwipeActionState.Progress(xOffset: storedOffset)
        messageSwipeActionState.setProgress(
            interactionId: renderItem.interactionUniqueId,
            progress: progress,
        )
        self.swipeActionProgress = progress

        let swipeToReplyIconView = componentView.swipeToReplyIconView
        let swipeToReplyIconWrapper = componentView.swipeToReplyIconSwipeToReplyWrapper

        let previousActiveDirection = panHandler.activeDirection
        let activeDirection: CVPanHandler.ActiveDirection
        switch xOffset {
        case let x where x <= -swipeActionOffsetThreshold:
            // Tellomi（tellomi/tellomi#1109）：手指从右往左过阈值 = 回复（Telegram 基线）。
            // 原来的「从右往左 = 交互式推出消息详情」去掉了，详情仍在长按菜单里。
            // We should only become active if this message allows swipe-to-reply.
            let itemViewModel = CVItemViewModelImpl(renderItem: renderItem)
            if componentDelegate.shouldAllowMessageSendActionsForItem(itemViewModel) {
                activeDirection = .left
            } else {
                activeDirection = .none
            }
        default:
            activeDirection = .none
        }

        let didChangeActiveDirection = previousActiveDirection != activeDirection

        panHandler.activeDirection = activeDirection

        // Tellomi（交互审计 A-10，标准第四节「阈值要有反馈」、第五节触感表）：越过阈值、退回阈值以内各一次 `.impact(.light)`。
        // 原来只在越过时 `.heavy` 一次（照 Telegram）；两端统一按标准，Android 同时改成系统的阈值触感。
        if didChangeActiveDirection, !hasFinished {
            Self.tellomiThresholdHaptic(in: componentView.rootView)
        }

        // Update the reply image styling to reflect active state
        let isStarting = sender.state == .began

        if isStarting || didChangeActiveDirection {
            let shouldAnimate = didChangeActiveDirection
            let transform: CGAffineTransform
            let tintColor: UIColor
            if activeDirection == .left {
                transform = CGAffineTransform(scaleX: 1.16, y: 1.16)
                tintColor = conversationStyle.bubbleTextColorIncoming
            } else {
                transform = .identity
                tintColor = conversationStyle.bubbleTextColorIncoming.withAlphaComponent(0.5)
            }
            swipeToReplyIconWrapper.layer.removeAllAnimations()
            swipeToReplyIconView.tintColor = tintColor
            if shouldAnimate {
                UIView.animate(
                    withDuration: 0.2,
                    delay: 0,
                    usingSpringWithDamping: 0.06,
                    initialSpringVelocity: 0.8,
                    options: [.curveEaseInOut, .beginFromCurrentState],
                    animations: {
                        swipeToReplyIconWrapper.transform = transform
                    },
                    completion: nil,
                )
            } else {
                swipeToReplyIconWrapper.transform = transform
            }
        }

        // Tellomi（交互审计 A-10，标准第四节「判定用投射落点」）：位移 + 速度 × 0.1 s 过阈值就回复，快速一甩也算、往回甩取消
        // （原来照 ADR-0058 §2 / Telegram 只看松手时的位移）。没越过阈值、靠投射回复的，松手时补一次触感。
        if hasFinished {
            let itemViewModel = CVItemViewModelImpl(renderItem: renderItem)
            let shouldReply = Self.tellomiSwipeToReplyShouldReply(
                fingerOffset: -xOffset,
                fingerVelocity: Self.tellomiReplyDirectionVelocity(sender: sender, in: componentView.rootView),
                threshold: swipeActionOffsetThreshold,
            )
            if shouldReply, componentDelegate.shouldAllowMessageSendActionsForItem(itemViewModel) {
                if previousActiveDirection != .left {
                    Self.tellomiThresholdHaptic(in: componentView.rootView)
                }
                componentDelegate.didTapReplyToItem(itemViewModel)
            }
        }
    }

    private func messageAllowsSwipeReplyAction() -> Bool {
        guard
            !wasRemotelyDeleted,
            !thread.isReleaseNotesThread,
            !thread.isTerminatedGroup,
            !thread.isBlockedByAnnouncementOnly
        else {
            return false
        }
        return true
    }

    private func tryToApplySwipeAction(componentView: CVComponentViewMessage) {
        AssertIsOnMainThread()

        guard let swipeActionProgress else {
            return
        }

        guard messageAllowsSwipeReplyAction() else {
            return
        }

        let swipeToReplyIconView = componentView.swipeToReplyIconView

        // Tellomi（tellomi/tellomi#1109）：只有手指从右往左才移动气泡（xOffset 已按 RTL 翻过，负 = 回复方向）；
        // 往右一律不动，把右滑留给系统返回。阈值内 1:1 跟手，过阈值后橡皮筋。
        let fingerOffset = max(-swipeActionProgress.xOffset, 0)
        let offset = Self.tellomiSwipeToReplyBubbleOffset(fingerOffset: fingerOffset, threshold: swipeActionOffsetThreshold)
        let position = CurrentAppContext().isRTL ? offset : -offset

        // The swipe content moves at 1/8th the speed of the message bubble,
        // so that it reveals itself from underneath with an elastic feel.
        let slowPosition = position / 8

        var iconAlpha: CGFloat = 1
        let useSwipeFadeTransition = isBorderless
        if useSwipeFadeTransition {
            iconAlpha = CGFloat.inverseLerp(fingerOffset, min: 0, max: swipeActionOffsetThreshold).clamp01()
        }

        componentView.removeSwipeActionAnimations()

        swipeToReplyIconView.alpha = iconAlpha
        componentView.setSwipeToReplyOffset(
            fastOffset: CGPoint(x: position, y: 0),
            slowOffset: CGPoint(x: slowPosition, y: 0),
        )
    }

    private func clearSwipeAction(
        componentView: CVComponentViewMessage,
        renderItem: CVRenderItem,
        messageSwipeActionState: CVMessageSwipeActionState,
        isAnimated: Bool,
        releaseFingerOffset: CGFloat = 0,
        releaseFingerVelocity: CGFloat = 0,
    ) {
        AssertIsOnMainThread()

        messageSwipeActionState.resetProgress(interactionId: renderItem.interactionUniqueId)

        let iconView = componentView.swipeToReplyIconView

        if isAnimated {
            // Tellomi（交互审计 A-10，标准第四节「松手」）：`TellomiMotion.release` 弹簧从松手时的位置和速度出发回到原位
            // （原来是 0.2 s 补间）。初速 = 气泡速度 ÷ 剩余路程：往外甩着松手时先多走一点再回来。
            // 减弱动态效果时 `TellomiMotion.animator` 自动去掉回弹。图标是透明度，照标准淡出、不用弹簧。
            let threshold = swipeActionOffsetThreshold
            let bubbleOffset = Self.tellomiSwipeToReplyBubbleOffset(fingerOffset: releaseFingerOffset, threshold: threshold)
            let bubbleVelocity = Self.tellomiSwipeToReplyBubbleVelocity(
                fingerOffset: releaseFingerOffset,
                fingerVelocity: releaseFingerVelocity,
                threshold: threshold,
            )
            componentView.startSwipeToReplyReturn(
                initialVelocity: TellomiMotion.relativeVelocity(
                    CGPoint(x: bubbleVelocity, y: 0),
                    remaining: CGVector(dx: -bubbleOffset, dy: 0),
                ),
            )
            UIView.animate(
                withDuration: TellomiMotion.fadeOutDuration,
                delay: 0,
                options: [.curveEaseIn, .beginFromCurrentState],
                animations: { iconView.alpha = 0 },
            )
        } else {
            componentView.removeSwipeActionAnimations()
            componentView.setSwipeToReplyOffset(fastOffset: .zero, slowOffset: .zero)
            iconView.alpha = 0
        }

        self.swipeActionProgress = nil
    }
}

// MARK: -

private extension CVComponentMessage {

    func configureSubcomponentView(
        messageView: CVComponentViewMessage,
        subcomponent: CVComponent,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
        key: CVComponentKey,
    ) -> CVComponentView {
        if let subcomponentView = messageView.subcomponentView(key: key) {
            subcomponent.configureForRendering(
                componentView: subcomponentView,
                cellMeasurement: cellMeasurement,
                componentDelegate: componentDelegate,
            )
            return subcomponentView
        } else {
            let subcomponentView = subcomponent.buildComponentView(componentDelegate: componentDelegate)
            messageView.setSubcomponentView(key: key, subcomponentView: subcomponentView)
            subcomponent.configureForRendering(
                componentView: subcomponentView,
                cellMeasurement: cellMeasurement,
                componentDelegate: componentDelegate,
            )
            return subcomponentView
        }
    }

    func configureSubcomponent(
        messageView: CVComponentViewMessage,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
        key: CVComponentKey,
    ) -> CVComponentAndView? {
        guard let subcomponent = self.subcomponent(forKey: key) else {
            return nil
        }
        let subcomponentView = configureSubcomponentView(
            messageView: messageView,
            subcomponent: subcomponent,
            cellMeasurement: cellMeasurement,
            componentDelegate: componentDelegate,
            key: key,
        )
        return CVComponentAndView(key: key, component: subcomponent, componentView: subcomponentView)
    }

    private enum ContentStackMargin {
        case none
        case topMargin
        case bottomMargin
        case spacingDefault
        case spacingCustom(spacing: CGFloat)
    }

    private func buildNestedStackConfig(
        topMargin: ContentStackMargin,
        bottomMargin: ContentStackMargin,
    ) -> CVStackViewConfig {
        func marginValue(_ margin: ContentStackMargin) -> CGFloat {
            switch margin {
            case .none:
                return 0
            case .topMargin:
                return conversationStyle.textInsetTop
            case .bottomMargin:
                return conversationStyle.textInsetBottom
            case .spacingDefault:
                return Self.textViewVSpacing
            case .spacingCustom(let spacing):
                return spacing
            }
        }
        var layoutMargins = conversationStyle.textInsets
        layoutMargins.top = marginValue(topMargin)
        layoutMargins.bottom = marginValue(bottomMargin)
        return CVStackViewConfig(
            axis: .vertical,
            alignment: .fill,
            spacing: Self.textViewVSpacing,
            layoutMargins: layoutMargins,
        )
    }

    func buildBorderlessStackConfig() -> CVStackViewConfig {
        buildNoMarginsStackConfig()
    }

    func buildFullWidthStackConfig(includeTopMargin: Bool, includeBottomMargin: Bool) -> CVStackViewConfig {
        var layoutMargins = UIEdgeInsets.zero
        if includeTopMargin {
            layoutMargins.top = conversationStyle.textInsets.top
        }
        if includeBottomMargin {
            layoutMargins.bottom = conversationStyle.textInsets.bottom
        }
        return CVStackViewConfig(
            axis: .vertical,
            alignment: .fill,
            spacing: Self.textViewVSpacing,
            layoutMargins: layoutMargins,
        )
    }

    func buildNoMarginsStackConfig() -> CVStackViewConfig {
        CVStackViewConfig(
            axis: .vertical,
            alignment: .fill,
            spacing: Self.textViewVSpacing,
            layoutMargins: .zero,
        )
    }

    func buildContentStackConfig() -> CVStackViewConfig {
        CVStackViewConfig(
            axis: .vertical,
            alignment: .fill,
            spacing: 0,
            layoutMargins: .zero,
        )
    }

    func configureSubcomponentStack(
        messageView: CVComponentViewMessage,
        stackView: ManualStackView,
        stackConfig: CVStackViewConfig,
        cellMeasurement: CVCellMeasurement,
        measurementKey: String,
        componentDelegate: CVComponentDelegate,
        keys: [CVComponentKey],
    ) {

        let subviews: [UIView] = keys.compactMap { key in
            // TODO: configureSubcomponent should probably just return the componentView.
            guard
                let componentAndView = configureSubcomponent(
                    messageView: messageView,
                    cellMeasurement: cellMeasurement,
                    componentDelegate: componentDelegate,
                    key: key,
                )
            else {
                return nil
            }
            return componentAndView.componentView.rootView
        }

        stackView.reset()
        stackView.configure(
            config: stackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: measurementKey,
            subviews: subviews,
        )
    }

    func subcomponents(forKeys keys: [CVComponentKey]) -> [CVComponent] {
        keys.compactMap { key in
            guard let subcomponent = self.subcomponent(forKey: key) else {
                // Not all subcomponents may be present.
                return nil
            }
            return subcomponent
        }
    }

    func buildSubcomponentMap(keys: [CVComponentKey]) -> [CVComponentKey: CVComponent] {
        var result = [CVComponentKey: CVComponent]()
        for key in keys {
            guard let subcomponent = self.subcomponent(forKey: key) else {
                // Not all subcomponents may be present.
                continue
            }
            result[key] = subcomponent
        }
        return result
    }
}

// MARK: -

class SwipeToReplyWrapper: ManualLayoutView {

    var offset: CGPoint = .zero {
        didSet {
            layoutSubviews()
        }
    }

    var subview: UIView? {
        didSet {
            // This view should only be configured after being reset.
            owsAssertDebug((subview == nil) || (oldValue == nil))

            oldValue?.removeFromSuperview()

            if let subview {
                owsAssertDebug(subview.superview == nil)
                addSubview(subview)

                layoutSubviews()
            }
        }
    }

    /// Tellomi（#1205）：子视图（气泡）比自己大出的部分：有尾巴时尾巴那一侧外扩 `BubbleConfiguration.Tail.extent`。
    var tellomiSubviewOutsets: UIEdgeInsets = .zero {
        didSet {
            layoutSubviews()
        }
    }

    let useSlowOffset: Bool
    let shouldReset: Bool

    init(
        name: String,
        useSlowOffset: Bool,
        shouldReset: Bool,
    ) {
        self.useSlowOffset = useSlowOffset
        self.shouldReset = shouldReset

        super.init(name: name)

        addDefaultLayoutBlock()
    }

    private func addDefaultLayoutBlock() {
        addLayoutBlock { view in
            guard let view = view as? SwipeToReplyWrapper else {
                owsFailDebug("Invalid reference view.")
                return
            }
            guard let subview = view.subview else {
                return
            }
            let outsets = view.tellomiSubviewOutsets
            var subviewFrame = view.bounds.inset(by: UIEdgeInsets(top: -outsets.top, left: -outsets.left, bottom: -outsets.bottom, right: -outsets.right))
            subviewFrame.origin += view.offset
            ManualLayoutView.setSubviewFrame(subview: subview, frame: subviewFrame)
        }
    }

    override func reset() {
        super.reset()

        subview = nil
        offset = .zero
        tellomiSubviewOutsets = .zero
        addDefaultLayoutBlock()
    }
}

private class SwipeToReplyIndicatorView: UIView {

    var backgroundEffect: UIVisualEffect? = nil {
        didSet {
            // Show/hide background.
            let imageName: String
            if let backgroundEffect {
                if let backgroundView {
                    backgroundView.effect = backgroundEffect
                    backgroundView.isHidden = false
                } else {
                    let blurEffectView = UIVisualEffectView(effect: backgroundEffect)
                    blurEffectView.clipsToBounds = true
                    if #available(iOS 26, *) {
                        blurEffectView.cornerConfiguration = .capsule()
                    }
                    insertSubview(blurEffectView, at: 0)
                    self.backgroundView = blurEffectView
                }
                backgroundView?.contentView.addSubview(imageView)

                // Smaller icon when we there is a background.
                imageName = "reply-20"
            } else {
                backgroundView?.effect = nil
                backgroundView?.isHidden = true
                addSubview(imageView)

                // Larger - 24 dp - icon.
                imageName = "reply"
            }

            // Update icon:
            imageView.image = UIImage(named: imageName)?.withRenderingMode(.alwaysTemplate)

            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    private let imageView = UIImageView()
    private var backgroundView: UIVisualEffectView?

    init() {
        super.init(frame: .zero)

        imageView.contentMode = .center
        addSubview(imageView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let size: CGFloat = (backgroundView?.isHidden ?? true) ? 34 : 24
        return .square(size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        imageView.frame = bounds

        if let backgroundView {
            backgroundView.frame = bounds
            if #unavailable(iOS 26) {
                backgroundView.layer.cornerRadius = min(bounds.height, bounds.width) / 2
            }
        }
    }
}

// MARK: - 用例

extension CVComponentMessage.CVComponentViewMessage {
    /// Tellomi 用例：气泡的排版位置（不含尾巴外扩）在 `view` 里的矩形
    func tellomiContentFrameForTesting(in view: UIView) -> CGRect {
        contentViewSwipeToReplyWrapper.convert(contentViewSwipeToReplyWrapper.bounds, to: view)
    }

    /// Tellomi 用例：群聊里对方的头像在 `view` 里的矩形；这一条没排头像时为 nil
    func tellomiAvatarFrameForTesting(in view: UIView) -> CGRect? {
        guard avatarViewSwipeToReplyWrapper.superview != nil else {
            return nil
        }
        return avatarViewSwipeToReplyWrapper.convert(avatarViewSwipeToReplyWrapper.bounds, to: view)
    }
}

// MARK: -

/// 整条消息的无障碍元素（消息里有独立的无障碍按钮时用，见 `CVComponentMessage.configureAccessibility`）：框就是容器视图（`hInnerStack`）的框，
/// 每次被问到时现算，不缓存——列表滚动、重新排版以后它仍然盖在消息上。
final class CVMessageAccessibilityElement: UIAccessibilityElement {
    override var accessibilityFrame: CGRect {
        get {
            guard let container = accessibilityContainer as? UIView else {
                return super.accessibilityFrame
            }
            return UIAccessibility.convertToScreenCoordinates(container.bounds, in: container)
        }
        set {
            super.accessibilityFrame = newValue
        }
    }
}
