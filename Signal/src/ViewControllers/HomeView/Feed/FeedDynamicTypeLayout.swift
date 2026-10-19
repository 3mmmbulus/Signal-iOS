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

    // MARK: - 顶栏入口按钮（Mac 报告 2026-10-19 的 a）

    /// 顶栏上入口按钮（铃铛、我的动态、搜索、齿轮）有 4 个时，标题栏被挤到 117pt（默认字号也只有 80pt 放不下「Following」）：
    /// 把「我的动态」和齿轮收进一个「···」菜单，栏上只剩铃铛、搜索和菜单（3 个，Mac 上验过放得下）。少于 4 个照旧。
    static let topBarOverflowThreshold = 4

    static func topBarUsesOverflow(entryCount: Int) -> Bool {
        return entryCount >= topBarOverflowThreshold
    }

    // MARK: - 分段控件标题（Mac 报告 d）

    /// 分段标题要的字号：想跟正文一样大（`bodyPoints`，不夹紧），但最宽那条标题（按正文字号量出来是 `widestTitleWidth`）
    /// 放不进一格（`segmentWidth`，已经扣掉左右留白）就按比例缩小，最小不低于 `floorPoints`（再小的字就和别处不搭了，宁可截断）。向下取整。
    static func segmentedTitlePointSize(bodyPoints: CGFloat, widestTitleWidth: CGFloat, segmentWidth: CGFloat, floorPoints: CGFloat) -> CGFloat {
        let floorSize = min(floorPoints, bodyPoints)
        guard widestTitleWidth > 0, segmentWidth > 0, widestTitleWidth > segmentWidth else { return bodyPoints }
        let scaled = (bodyPoints * segmentWidth / widestTitleWidth).rounded(.down)
        return max(floorSize, scaled)
    }

    // MARK: - 我的动态行里的备注和「申诉」按钮（Mac 报告 e）

    /// 备注（审核中 / 被拒原因 / 申诉结果）和下面「申诉」按钮之间的距离：平时 10，无障碍字号 16（以前和别的行一样是 6，字大了贴得很紧）。
    static func appealSpacing(isAccessibilityCategory: Bool) -> CGFloat {
        return isAccessibilityCategory ? 16 : 10
    }
}
