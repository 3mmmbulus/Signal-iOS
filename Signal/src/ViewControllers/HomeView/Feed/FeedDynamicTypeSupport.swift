//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 动态页的「最大字号」支持（数字在 `FeedDynamicTypeLayout`，Linux 上测过；这里只接 UIKit）。
extension UISegmentedControl {

    private static let feedMinHeightIdentifier = "feed.segmented.minHeight"

    /// 标题用跟正文一样大的字体（不夹紧；放不下才缩），控件也跟着长高（系统默认的分段控件字号和高度都是固定的，
    /// 最大字号下标题小得和别处不搭）。字号档位变了会自己更新（iOS 17 起；更早的系统下次建页面时更新）。
    func installFeedDynamicType() {
        applyFeedDynamicType()
        if #available(iOS 17, *) {
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (control: UISegmentedControl, _) in
                control.applyFeedDynamicType()
            }
        }
    }

    /// 标题字体：跟正文一样大（不夹紧），最宽的标题放不进一格才按比例缩小（`FeedDynamicTypeLayout.segmentedTitlePointSize`），
    /// 最小不低于夹紧的脚注字号。还没布局（宽度 0）时按屏幕宽度减左右边距估一格有多宽。
    private func feedTitleFont() -> UIFont {
        let body = UIFont.dynamicTypeBody
        let count = max(numberOfSegments, 1)
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 32
        let widest = (0..<numberOfSegments)
            .compactMap { titleForSegment(at: $0) }
            .map { ($0 as NSString).size(withAttributes: [.font: body]).width }
            .max() ?? 0
        let points = FeedDynamicTypeLayout.segmentedTitlePointSize(
            bodyPoints: body.pointSize,
            widestTitleWidth: widest.rounded(.up),
            segmentWidth: width / CGFloat(count) - Self.feedTitlePadding,
            floorPoints: UIFont.dynamicTypeFootnoteClamped.pointSize,
        )
        return points < body.pointSize ? body.withSize(points) : body
    }

    /// 一格里标题左右各留的空白加起来。
    private static let feedTitlePadding: CGFloat = 16

    func applyFeedDynamicType() {
        let font = feedTitleFont()
        setTitleTextAttributes([.font: font], for: .normal)
        setTitleTextAttributes([.font: font], for: .selected)
        let height = FeedDynamicTypeLayout.segmentedMinHeight(lineHeight: font.lineHeight)
        if let existing = constraints.first(where: { $0.identifier == Self.feedMinHeightIdentifier }) {
            existing.constant = height
        } else {
            let constraint = autoSetDimension(.height, toSize: height, relation: .greaterThanOrEqual)
            constraint.identifier = Self.feedMinHeightIdentifier
        }
    }
}

enum FeedChoiceRow {

    /// 「几选一」的一行（对勾在右边）。比 `OWSTableItem(text:)` 的行好的地方：字用不夹紧的动态字体、可以换行，
    /// 最大字号下和同页别的行（`textRow`）一样放大。
    static func item(text: String, selected: Bool, action: @escaping () -> Void) -> OWSTableItem {
        return OWSTableItem(
            customCellBlock: {
                let cell = OWSTableItem.newCell()
                let label = UILabel()
                label.text = text
                label.font = .dynamicTypeBody
                label.textColor = UIColor.Signal.label
                label.numberOfLines = 0
                cell.contentView.addSubview(label)
                label.autoPinEdgesToSuperviewMargins()
                cell.accessoryType = selected ? .checkmark : .none
                if selected { cell.accessibilityTraits.insert(.selected) }
                return cell
            },
            actionBlock: action,
        )
    }
}

enum FeedSwitchRow {

    /// 带开关的一行。`OWSTableItem.switch` 的字是夹紧的、一行放不下就被截；这里字用不夹紧的动态字体、可以换行，
    /// 开关在右边不被挤；最大字号下和同页别的行一样放大。`action` 收到开关的新值。
    static func item(text: String, isOn: Bool, isEnabled: Bool = true, action: @escaping (Bool) -> Void) -> OWSTableItem {
        return OWSTableItem(
            customCellBlock: {
                let cell = OWSTableItem.newCell()
                let label = UILabel()
                label.text = text
                label.font = .dynamicTypeBody
                label.textColor = isEnabled ? UIColor.Signal.label : UIColor.Signal.secondaryLabel
                label.numberOfLines = 0
                let toggle = UISwitch()
                toggle.isOn = isOn
                toggle.isEnabled = isEnabled
                toggle.accessibilityLabel = text
                toggle.addAction(UIAction { [weak toggle] _ in action(toggle?.isOn ?? false) }, for: .valueChanged)
                toggle.setContentHuggingPriority(.required, for: .horizontal)
                toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
                let stack = UIStackView(arrangedSubviews: [label, toggle])
                stack.axis = .horizontal
                stack.alignment = .center
                stack.spacing = 16
                cell.contentView.addSubview(stack)
                stack.autoPinEdgesToSuperviewMargins()
                cell.selectionStyle = .none
                return cell
            },
            actionBlock: nil,
        )
    }
}
