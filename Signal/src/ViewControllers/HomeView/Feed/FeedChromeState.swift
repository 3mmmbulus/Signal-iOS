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

/// 把 `FeedChromeState` 接到两条栏上（I-14）：可见性一变，顶栏（导航栏，「推荐 / 关注」在里面）和主底栏在同一次回调里
/// 一起开始动画，收起 220 ms、出现 180 ms，所以同帧收起 / 出现。两条栏怎么动由调用方给（`FeedViewController`
/// 用导航栏和 `HomeTabBarController.setTabBarHidden`），这里不碰 UIKit，单测可以直接用假的。
final class FeedChromeCoordinator {
    typealias SetBarHidden = (_ hidden: Bool, _ duration: TimeInterval) -> Void

    let state: FeedChromeState
    private let setTopBarHidden: SetBarHidden
    private let setBottomBarHidden: SetBarHidden

    /// 两条栏现在是不是收着（按最后一次下发的）。
    private(set) var barsHidden = false
    /// 栏刚动过：下一次列表位置只记不算（见 `apply`）。
    private var skipNextOffset = false
    private var isResetting = false

    init(state: FeedChromeState = FeedChromeState(), setTopBarHidden: @escaping SetBarHidden, setBottomBarHidden: @escaping SetBarHidden) {
        self.state = state
        self.setTopBarHidden = setTopBarHidden
        self.setBottomBarHidden = setBottomBarHidden
        state.onVisibilityChange = { [weak self] visible in
            guard let self, !self.isResetting else { return }
            self.apply(visible: visible, animated: true)
        }
    }

    static func duration(visible: Bool) -> TimeInterval {
        return TimeInterval(visible ? FeedChromeState.showMillis : FeedChromeState.hideMillis) / 1000
    }

    /// 当前这一栏的列表滚了（`scrollViewDidScroll`）：`offsetFromTop = contentOffset.y + adjustedContentInset.top`。
    func onListScrolled(offsetFromTop: Double) {
        if skipNextOffset {
            skipNextOffset = false
            state.onContentReplaced()
        }
        state.onContentOffsetChanged(offsetFromTop: offsetFromTop)
    }

    /// 列表内容被换掉（重新加载、下拉刷新）：下一次位置只记不算。
    func onContentReplaced() {
        state.onContentReplaced()
    }

    /// 换栏（推荐 ↔ 关注）、离开动态页、二级页推进来：两条栏马上显示（不动画），计数清零。
    func reset() {
        // `state.reset()` 自己也会报「出现」：那次不要动画，由下面一次不动画的放回代替
        isResetting = true
        state.reset()
        isResetting = false
        if barsHidden { apply(visible: true, animated: false) }
    }

    private func apply(visible: Bool, animated: Bool) {
        let hidden = !visible
        barsHidden = hidden
        let duration = animated ? Self.duration(visible: visible) : 0
        setTopBarHidden(hidden, duration)
        setBottomBarHidden(hidden, duration)
        // 栏收起 / 出现会改列表的 adjustedContentInset.top，offsetFromTop 跟着跳一下：那一下不是手指滚的，不算。
        // （这里还在 `onContentOffsetChanged` 里面，它最后会记下这次位置，所以要等下一次再清。）
        skipNextOffset = true
    }
}
