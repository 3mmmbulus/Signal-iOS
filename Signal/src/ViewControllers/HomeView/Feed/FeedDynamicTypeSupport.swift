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

    /// 标题用跟字号走（夹住上限）的字体，控件也跟着长高（系统默认的分段控件字号和高度都是固定的，
    /// 最大字号下标题小得和别处不搭）。字号档位变了会自己更新（iOS 17 起；更早的系统下次建页面时更新）。
    func installFeedDynamicType() {
        applyFeedDynamicType()
        if #available(iOS 17, *) {
            registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (control: UISegmentedControl, _) in
                control.applyFeedDynamicType()
            }
        }
    }

    func applyFeedDynamicType() {
        let font = UIFont.dynamicTypeFootnoteClamped
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
