//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 动态页在「最大字号」下的版面数字（纯计算，没有 UIKit，Linux harness 能测）。
///
/// Mac 的最大字号截图（`TEST-REPORT-mac-ios-feed-*`）里的几类问题：
/// 分段控件的标题不跟着放大；顶栏「推荐 / 关注」被两侧按钮挤得「Following」被截；
/// 我的动态每一行上面那排「状态 + 可见范围 + 时间」在一行里放不下被截断。
enum FeedDynamicTypeLayout {

    /// 分段控件至少这么高：系统默认 32，字放大了就跟着长（行高 + 上下各 8）。
    static let segmentedBaseHeight: CGFloat = 32
    static let segmentedVerticalPadding: CGFloat = 8

    static func segmentedMinHeight(lineHeight: CGFloat) -> CGFloat {
        return max(segmentedBaseHeight, lineHeight.rounded(.up) + segmentedVerticalPadding * 2)
    }

    /// 顶栏字号缩到不低于这个比例。
    static let topBarMinimumScale: CGFloat = 0.7

    /// 顶栏（导航栏 `titleView`）：自然宽度 `natural` 超过导航栏给的 `available` 时，字按比例缩小；
    /// 只往小走（`current` 之后只会更小，直到字号档位变了才由调用方重置为 1），所以不会来回抖。
    static func topBarFontScale(available: CGFloat, natural: CGFloat, current: CGFloat) -> CGFloat {
        guard available > 0, natural > 0, current > topBarMinimumScale else { return max(current, topBarMinimumScale) }
        guard natural > available + 0.5 else { return current }
        let next = (current * available / natural * 100).rounded(.down) / 100
        return min(current, max(topBarMinimumScale, next))
    }

    /// 我的动态每行的「状态 / 可见范围 / 时间」：无障碍字号档位下竖着排（一行放不下）。
    static func stacksPostMetaVertically(isAccessibilityCategory: Bool) -> Bool {
        return isAccessibilityCategory
    }
}
