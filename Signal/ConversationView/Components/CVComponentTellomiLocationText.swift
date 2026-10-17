//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
public import SignalUI

/// Tellomi（spec attachment-files-location L-11）：地点消息地图下面的名称 + 地址。
///
/// 照 Telegram `ChatMessageMapBubbleContentNode`：名称 medium 14、一行；地址 regular 14、最多两行、次要文字色；不显示原文里的
/// 地图链接。占 `.bodyText` 的位置，所以和上游的说明文字一样排（地图下 7 pt、左右 12 pt），时间放得下就压在地址最后一行右边。
final class CVComponentTellomiLocationText: CVComponentBase, CVComponent {

    var componentKey: CVComponentKey { .bodyText }

    let location: TellomiLocationMessage

    init(itemModel: CVItemModel, location: TellomiLocationMessage) {
        self.location = location

        super.init(itemModel: itemModel)
    }

    static var titleFont: UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14, weight: .medium))
    }

    static var addressFont: UIFont {
        UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14))
    }

    private var title: String { location.name ?? "" }

    private var address: String? { location.address?.nilIfEmpty }

    private var lastLineFont: UIFont { address != nil ? Self.addressFont : Self.titleFont }

    func buildComponentView(componentDelegate: CVComponentDelegate) -> CVComponentView {
        CVComponentViewTellomiLocationText()
    }

    func configureForRendering(
        componentView componentViewParam: CVComponentView,
        cellMeasurement: CVCellMeasurement,
        componentDelegate: CVComponentDelegate,
    ) {
        guard let componentView = componentViewParam as? CVComponentViewTellomiLocationText else {
            owsFailDebug("Unexpected componentView.")
            componentViewParam.reset()
            return
        }

        let titleLabel = componentView.titleLabel
        titleLabel.font = Self.titleFont
        titleLabel.textColor = conversationStyle.bubbleTextColor(isIncoming: isIncoming)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.text = title

        var subviews: [UIView] = [titleLabel]
        if let address {
            let addressLabel = componentView.addressLabel
            addressLabel.font = Self.addressFont
            addressLabel.textColor = conversationStyle.bubbleSecondaryTextColor(isIncoming: isIncoming)
            addressLabel.numberOfLines = 2
            addressLabel.lineBreakMode = .byTruncatingTail
            addressLabel.text = address
            subviews.append(addressLabel)
        }

        componentView.stackView.reset()
        componentView.stackView.configure(
            config: Self.stackConfig,
            cellMeasurement: cellMeasurement,
            measurementKey: Self.measurementKey_stackView,
            subviews: subviews,
        )
    }

    private static var stackConfig: CVStackViewConfig {
        CVStackViewConfig(axis: .vertical, alignment: .fill, spacing: 0, layoutMargins: .zero)
    }

    private static let measurementKey_stackView = "CVComponentTellomiLocationText.measurementKey_stackView"
    private static let measurementKey_lastLineWidth = "CVComponentTellomiLocationText.measurementKey_lastLineWidth"
    private static let measurementKey_maxWidth = "CVComponentTellomiLocationText.measurementKey_maxWidth"

    func measure(maxWidth: CGFloat, measurementBuilder: CVCellMeasurement.Builder) -> CGSize {
        owsAssertDebug(maxWidth > 0)

        let titleMeasurement = Self.measure(text: title, font: Self.titleFont, numberOfLines: 1, maxWidth: maxWidth)
        var subviewInfos = [titleMeasurement.size.asManualSubviewInfo]
        var lastLineWidth = titleMeasurement.lastLineWidth
        if let address {
            let addressMeasurement = Self.measure(text: address, font: Self.addressFont, numberOfLines: 2, maxWidth: maxWidth)
            subviewInfos.append(addressMeasurement.size.asManualSubviewInfo)
            lastLineWidth = addressMeasurement.lastLineWidth
        }
        measurementBuilder.setValue(key: Self.measurementKey_lastLineWidth, value: lastLineWidth)
        measurementBuilder.setValue(key: Self.measurementKey_maxWidth, value: maxWidth)

        let stackMeasurement = ManualStackView.measure(
            config: Self.stackConfig,
            measurementBuilder: measurementBuilder,
            measurementKey: Self.measurementKey_stackView,
            subviewInfos: subviewInfos,
            maxWidth: maxWidth,
        )
        return stackMeasurement.measuredSize
    }

    /// 一个最多 `numberOfLines` 行、尾部省略的标签的大小，和它最后一行字的宽度（用来判断时间能不能压在最后一行右边）。
    static func measure(text: String, font: UIFont, numberOfLines: Int, maxWidth: CGFloat) -> (size: CGSize, lastLineWidth: CGFloat) {
        guard !text.isEmpty else {
            return (.zero, 0)
        }
        let textStorage = NSTextStorage(attributedString: NSAttributedString(string: text, attributes: [.font: font]))
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = numberOfLines
        textContainer.lineBreakMode = .byTruncatingTail
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        var lastLineWidth: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: textContainer)) { _, usedRect, _, _, _ in
            lastLineWidth = usedRect.width
        }
        let usedRect = layoutManager.usedRect(for: textContainer)
        let size = CGSize(width: min(maxWidth, ceil(usedRect.width)), height: ceil(usedRect.height))
        return (size, min(maxWidth, ceil(lastLineWidth)))
    }

    /// 时间压在最后一行右边要的东西：最后一行字宽、可用宽度、最后一行的字体。没量过返回 nil。
    static func lastLineForFooterOverlap(
        measurementBuilder: CVCellMeasurement.Builder,
    ) -> (lastLineWidth: CGFloat, maxWidth: CGFloat)? {
        guard
            let lastLineWidth = measurementBuilder.getValue(key: measurementKey_lastLineWidth),
            let maxWidth = measurementBuilder.getValue(key: measurementKey_maxWidth)
        else {
            return nil
        }
        return (lastLineWidth, maxWidth)
    }

    var lastLineFontForFooterOverlap: UIFont { lastLineFont }

    // MARK: - Events

    override func handleTap(
        sender: UIGestureRecognizer,
        componentDelegate: CVComponentDelegate,
        componentView: CVComponentView,
        renderItem: CVRenderItem,
    ) -> Bool {
        componentDelegate.tellomiDidTapLocation(location, itemViewModel: CVItemViewModelImpl(renderItem: renderItem))
        return true
    }

    // MARK: -

    final class CVComponentViewTellomiLocationText: NSObject, CVComponentView {

        fileprivate let stackView = ManualStackView(name: "CVComponentTellomiLocationText.stackView")
        fileprivate let titleLabel = CVLabel()
        fileprivate let addressLabel = CVLabel()

        var isDedicatedCellView = false

        var rootView: UIView {
            stackView
        }

        func setIsCellVisible(_ isCellVisible: Bool) {}

        func reset() {
            stackView.reset()
            titleLabel.text = nil
            addressLabel.text = nil
        }
    }
}

// MARK: -

extension CVComponentTellomiLocationText: CVAccessibilityComponent {
    var accessibilityDescription: String {
        [location.name, location.address].compactMap { $0 }.joined(separator: ", ")
    }
}
