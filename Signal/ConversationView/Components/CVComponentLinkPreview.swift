//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

class CVComponentLinkPreview: CVComponentBase, CVComponent {

    var componentKey: CVComponentKey { .linkPreview }

    private let linkPreview: LinkPreviewState

    /// Tellomi（产品经理 2026-10-19 卡片样式定稿）：卡片不在气泡里（代替气泡，或单独一块在文字气泡下面）——
    /// 不留气泡里的左右内缩，圆角和气泡一样大。
    private let isStandalone: Bool

    init(
        itemModel: CVItemModel,
        linkPreview: LinkPreviewState,
        isStandalone: Bool = false,
    ) {
        self.linkPreview = linkPreview
        self.isStandalone = isStandalone

        super.init(itemModel: itemModel)
    }

    func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewLinkPreview()
    }

    func configureForRendering(
        componentView componentViewParam: CVComponentView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) {
        guard let componentView = componentViewParam as? CVComponentViewLinkPreview else {
            owsFailDebug("Unexpected componentView.")
            componentViewParam.reset()
            return
        }

        let linkPreviewWrapper = componentView.linkPreviewWrapper
        let linkPreviewView = componentView.linkPreviewView

        linkPreviewView.configureForRendering(
            linkPreview: linkPreview,
            isIncoming: isIncoming,
            // 按下态 / 悬停态只给点了会有反应的卡：不响应点击的域名卡没有，选择模式里点一下是选消息、不是点卡片，也没有。
            isInteractive: Self.respondsToTap(linkPreview) && !isShowingSelectionUI,
            isStandalone: isStandalone,
            cellMeasurement: cellMeasurement,
        )

        linkPreviewWrapper.configure(
            config: stackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_linkPreviewWrapper,
            subviews: [linkPreviewView],
        )
    }

    private var stackConfig: CVStackViewConfig {
        CVStackViewConfig(
            axis: .vertical,
            alignment: .fill,
            spacing: 0,
            layoutMargins: isStandalone ? .zero : UIEdgeInsets(hMargin: 8, vMargin: 0),
        )
    }

    private static let measurementKey_linkPreviewWrapper = "CVComponentLinkPreview.measurementKey_linkPreviewWrapper"

    func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        let maxWidth = min(maxWidth, conversationStyle.maxMediaMessageWidth)
        let maxContentWidth = maxWidth - stackConfig.layoutMargins.totalWidth

        let linkPreviewSize = CVLinkPreviewView.measure(
            maxWidth: maxContentWidth,
            measurementBuilder: measurementBuilder,
            linkPreview: linkPreview,
        )
        let subviewInfos = [linkPreviewSize.asManualSubviewInfo]
        let stackMeasurement = ManualStackView.measure(
            config: stackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_linkPreviewWrapper,
            subviewInfos: subviewInfos,
            maxWidth: maxWidth,
        )
        return stackMeasurement.measuredSize
    }

    // MARK: - Events

    override func handleTap(
        sender: UIGestureRecognizer,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem,
    ) -> Bool {
        guard Self.respondsToTap(linkPreview) else {
            return false
        }
        guard let urlString = linkPreview.urlString else {
            owsFailDebug("Missing url.")
            return false
        }
        guard let url = URL(string: urlString) else {
            // 不把 URL 写进日志（ADR-0063 §6.5）。
            owsFailDebug("Invalid url.")
            return false
        }
        componentDelegate.didTapLinkPreview(url: url)
        return true
    }

    /// 卡片响应点击吗。消息请求里的域名卡不响应（card-visual §7.3；同 Telegram iOS 对可疑发件人的处理：
    /// 卡片的点击动作是 `.none`），陌生人发来的链接不能一点就打开；接受以后才是完整的卡片。
    static func respondsToTap(_ linkPreview: LinkPreviewState) -> Bool {
        return (linkPreview as? TellomiLinkPreviewCardState)?.isInert != true
    }

    // MARK: -

    // Used for rendering some portion of an Conversation View item.
    // It could be the entire item or some part thereof.
    class CVComponentViewLinkPreview: NSObject, CVComponentView {

        fileprivate let linkPreviewView = CVLinkPreviewView()
        fileprivate let linkPreviewWrapper = ManualStackView(name: "Link Preview Wrapper")

        var isDedicatedCellView = false

        var rootView: UIView {
            linkPreviewWrapper
        }

        func setIsCellVisible(_ isCellVisible: Bool) {}

        func reset() {
            linkPreviewWrapper.reset()
            linkPreviewView.reset()
        }
    }
}

// MARK: - Accessibility

extension CVComponentLinkPreview: CVAccessibilityComponent {

    var accessibilityDescription: String {
        Self.accessibilityDescription(for: linkPreview, strings: .localized())
    }

    /// 卡片读给读屏的话（card-visual §3.6，拼法三端同一份）：Tellomi 第一方卡读「类型，标题，副标题，按钮：动作」，
    /// 其余的卡读「链接，标题，域名」（不读副行）——只用卡片上可见的文字。
    /// 整条消息是一个无障碍元素，「只显示卡片」时正文组件被拿掉，没有这一段读屏就读不到链接的任何内容。
    static func accessibilityDescription(for linkPreview: LinkPreviewState, strings: TellomiLinkCardAccessibility.Strings) -> String {
        if let card = linkPreview as? TellomiLinkPreviewCardState, let firstParty = card.firstParty {
            return TellomiLinkCardAccessibility.description(firstParty: firstParty, strings: strings)
        }
        return TellomiLinkCardAccessibility.description(
            title: linkPreview.title,
            domain: linkPreview.displayDomain,
            strings: strings,
        )
    }

    /// 第一方卡底部的动作按钮：一个独立的无障碍按钮元素（button 角色，读它上面的字；激活 = 点这张卡，做的就是按钮要做的事）。
    /// 没有这个按钮的卡（第三方卡、纯链接、Signal 原来的卡）是 nil。`CVComponentMessage` 把它和整条消息的元素并列放进容器里。
    func accessibilityActionElement(componentView: CVComponentView) -> UIView? {
        (componentView as? CVComponentViewLinkPreview)?.linkPreviewView.accessibilityActionElement
    }
}
