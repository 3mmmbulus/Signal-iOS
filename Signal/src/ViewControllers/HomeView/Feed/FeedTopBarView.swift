//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 动态页顶栏：只有一行，「推荐 / 关注」居中（附录 10「顶栏一行」；第三节第 45 条去掉了「有什么新鲜事」）。
///
/// 放在导航栏的 `titleView` 里。下面的滑块跟着内容的横向滑动走（`setPosition`，跟手），
/// 点一栏由调用方滚过去（`10-feed-prototype-log.md` 第 435 行）。点 Tab 不震（第三节第 37 条）。
final class FeedTopBarView: UIView {

    static let indicatorWidth: CGFloat = 20
    private static let indicatorHeight: CGFloat = 2
    private static let buttonHorizontalPadding: CGFloat = 14
    private static let height: CGFloat = 44

    private(set) var tabs: [FeedTab]
    var onSelect: ((Int) -> Void)?

    private var buttons = [UIButton]()
    private let stackView = UIStackView()
    private let indicator = UIView()

    /// 0 = 第一栏，1 = 第二栏，中间值是正在滑。
    private(set) var position: CGFloat = 0

    init(tabs: [FeedTab]) {
        self.tabs = tabs
        super.init(frame: .zero)

        stackView.axis = .horizontal
        stackView.alignment = .center
        addSubview(stackView)
        stackView.autoPinEdgesToSuperviewEdges()

        indicator.layer.cornerRadius = Self.indicatorHeight / 2
        addSubview(indicator)

        rebuildButtons()
        applyTheme()

        NotificationCenter.default.addObserver(self, selector: #selector(applyTheme), name: .themeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 按选中时（粗体）的宽度算，切换选中时标题不会换行、两栏也不会左右跳。
    override var intrinsicContentSize: CGSize {
        let width = tabs.reduce(CGFloat(0)) { $0 + Self.buttonWidth(for: $1) }
        return CGSize(width: width, height: Self.height)
    }

    private static func buttonWidth(for tab: FeedTab) -> CGFloat {
        let textWidth = (tab.title as NSString).size(withAttributes: [.font: selectedFont]).width
        return textWidth.rounded(.up) + buttonHorizontalPadding * 2
    }

    private static var selectedFont: UIFont { UIFont.dynamicTypeHeadlineClamped.semibold() }
    private static var unselectedFont: UIFont { UIFont.dynamicTypeHeadlineClamped }

    func setTabs(_ tabs: [FeedTab]) {
        guard tabs != self.tabs else { return }
        self.tabs = tabs
        rebuildButtons()
    }

    func setPosition(_ position: CGFloat) {
        self.position = max(0, min(position, CGFloat(max(tabs.count - 1, 0))))
        updateSelection()
        setNeedsLayout()
    }

    var selectedIndex: Int {
        return Int(position.rounded())
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutIndicator()
    }

    private func rebuildButtons() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = tabs.enumerated().map { index, tab in
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: Self.buttonHorizontalPadding, bottom: 8, trailing: Self.buttonHorizontalPadding)
            config.title = tab.title
            config.titleLineBreakMode = .byClipping
            let button = UIButton(configuration: config)
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
            stackView.addArrangedSubview(button)
            button.autoSetDimension(.width, toSize: Self.buttonWidth(for: tab))
            return button
        }
        invalidateIntrinsicContentSize()
        updateSelection()
    }

    private func updateSelection() {
        let selected = selectedIndex
        for (index, button) in buttons.enumerated() {
            let isSelected = index == selected
            let font = isSelected ? Self.selectedFont : Self.unselectedFont
            let color = isSelected ? UIColor.Signal.label : UIColor.Signal.secondaryLabel
            button.configuration?.attributedTitle = AttributedString(
                tabs[index].title,
                attributes: AttributeContainer([.font: font, .foregroundColor: color]),
            )
            if isSelected {
                button.accessibilityTraits.insert(.selected)
            } else {
                button.accessibilityTraits.remove(.selected)
            }
        }
    }

    /// 滑块在两栏标题中心之间按位置插值，所以手指拖到一半时滑块也在一半。
    private func layoutIndicator() {
        guard !buttons.isEmpty else { return }
        stackView.layoutIfNeeded()
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, buttons.count - 1)
        let fraction = position - CGFloat(lower)
        let lowerCenter = buttons[lower].convert(CGPoint(x: buttons[lower].bounds.midX, y: 0), to: self).x
        let upperCenter = buttons[upper].convert(CGPoint(x: buttons[upper].bounds.midX, y: 0), to: self).x
        let centerX = lowerCenter + (upperCenter - lowerCenter) * fraction
        indicator.frame = CGRect(
            x: centerX - Self.indicatorWidth / 2,
            y: bounds.height - Self.indicatorHeight - 4,
            width: Self.indicatorWidth,
            height: Self.indicatorHeight,
        )
    }

    @objc
    private func applyTheme() {
        indicator.backgroundColor = UIColor.Signal.label
        updateSelection()
    }
}
