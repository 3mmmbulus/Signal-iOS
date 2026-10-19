//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedChromeState.swift (new file)
// Scroll-aware top / bottom bars (I-14). Mirror of Android `FeedChromeState.kt` + a content-offset adapter for UIScrollView.
// The animation (220 / 180 ms) and the `HomeTabBarController` hook are UI and are not drafted.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 动态页的「滚动感知」顶栏与底栏（`dynamic-feed.md` 第三节第 46 条）：
/// 往更早的内容滚累计 `hideAfter` 收起，往回累计 `showAfter` 出现，离顶 `alwaysShowWithin` 内一律显示；
/// 收起 220 ms、出现 180 ms。顶栏（动态页自己的「推荐 / 关注」）和主底栏读同一个 `visible`，所以同帧收起。
/// 发布按钮不动；二级页没有底栏，不受影响。文档里的单位是 pt，iOS 直接用 pt。
final class FeedChromeState {
    static let hideAfter: Double = 48
    static let showAfter: Double = 12
    static let alwaysShowWithin: Double = 64
    static let hideMillis = 220
    static let showMillis = 180

    private let hideAfterPx: Double
    private let showAfterPx: Double

    init(hideAfter: Double = FeedChromeState.hideAfter, showAfter: Double = FeedChromeState.showAfter) {
        hideAfterPx = hideAfter
        showAfterPx = showAfter
    }

    /// 顶栏和底栏都在这里订阅；变了才通知（同一个值不重复发）。
    var onVisibilityChange: ((Bool) -> Void)?

    private(set) var visible = true {
        didSet {
            if visible != oldValue { onVisibilityChange?(visible) }
        }
    }

    /// 当前方向上累计滚了多少；换方向清零。
    private var accumulated: Double = 0
    private var nearTop = true
    private var lastOffset: Double?

    /// 当前这一栏离顶部在 `alwaysShowWithin` 以内。
    func onNearTopChanged(_ near: Bool) {
        nearTop = near
        if near {
            visible = true
            accumulated = 0
        }
    }

    /// `towardOlder` > 0 表示往更早的内容滚（手指往上推），< 0 表示往回。
    func onScroll(towardOlder: Double) {
        if nearTop || towardOlder == 0 { return }
        if visible {
            accumulated = towardOlder > 0 ? accumulated + towardOlder : 0
            if accumulated >= hideAfterPx {
                visible = false
                accumulated = 0
            }
        } else {
            accumulated = towardOlder < 0 ? accumulated - towardOlder : 0
            if accumulated >= showAfterPx {
                visible = true
                accumulated = 0
            }
        }
    }

    /// 换栏、离开动态页：一律显示。
    func reset() {
        visible = true
        accumulated = 0
        nearTop = true
        lastOffset = nil
    }

    // MARK: - UIScrollView 适配

    /// 在 `scrollViewDidScroll` 里调：`offsetFromTop = contentOffset.y + adjustedContentInset.top`（0 = 在最顶）。
    /// 第一次调用只记位置、不算滚动（刚出现 / 换栏）；之后用和上一次的差当 `towardOlder`。
    func onContentOffsetChanged(offsetFromTop: Double) {
        let near = offsetFromTop <= Self.alwaysShowWithin
        defer { lastOffset = offsetFromTop }
        // 先按「上一次的」是否在顶部附近处理这一步的滚动，再更新位置状态：
        // 走出顶部区的那一步不累计（Android 里 near-top 是布局之后才更新的，同样不算这一步）。
        if let last = lastOffset { onScroll(towardOlder: offsetFromTop - last) }
        if near != nearTop { onNearTopChanged(near) }
    }

    /// 内容被程序换掉（下拉刷新、换栏、重新加载）后调：下一次 `onContentOffsetChanged` 只记位置，不把跳变当成滚动。
    func onContentReplaced() {
        lastOffset = nil
    }
}
