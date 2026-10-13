//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 「动态」标签（M11 P1，`dynamic-feed.md` 第四节 L2-1）。
///
/// 顶栏只有一行：「推荐 / 关注」居中（`FeedTopBarView`）。两栏左右滑切换，滑块和内容一起跟手。
/// 每栏一个 `FeedTimelineViewController`。打开 App 默认还是「聊天」（第三节第 17 条），这里只是最左边的标签。
final class FeedViewController: OWSViewController, HomeTabViewController {

    private(set) var tabs: [FeedTab] = FeedTab.allCases
    private(set) var pages = [FeedTimelineViewController]()

    private lazy var topBar = FeedTopBarView(tabs: tabs)
    private let pagingScrollView = UIScrollView()

    override init() {
        super.init()
        pages = tabs.map { FeedTimelineViewController(tab: $0) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.Signal.background
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = topBar
        navigationItem.backButtonDisplayMode = .minimal
        topBar.onSelect = { [weak self] index in self?.scrollToPage(index, animated: true) }

        pagingScrollView.isPagingEnabled = true
        pagingScrollView.showsHorizontalScrollIndicator = false
        pagingScrollView.bounces = false
        pagingScrollView.contentInsetAdjustmentBehavior = .never
        pagingScrollView.scrollsToTop = false
        pagingScrollView.delegate = self
        view.addSubview(pagingScrollView)
        pagingScrollView.autoPinEdgesToSuperviewEdges()

        for page in pages {
            addChild(page)
            pagingScrollView.addSubview(page.view)
            page.didMove(toParent: self)
        }
        updateScrollsToTop()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let size = pagingScrollView.bounds.size
        guard size.width > 0 else { return }
        let selected = topBar.selectedIndex
        for (index, page) in pages.enumerated() {
            page.view.frame = CGRect(x: CGFloat(index) * size.width, y: 0, width: size.width, height: size.height)
        }
        pagingScrollView.contentSize = CGSize(width: size.width * CGFloat(pages.count), height: size.height)
        // 转屏、分屏改宽度后停在原来那一栏
        pagingScrollView.contentOffset = CGPoint(x: CGFloat(selected) * size.width, y: 0)
    }

    var selectedTab: FeedTab {
        return tabs[safe: topBar.selectedIndex] ?? .recommend
    }

    /// 底栏再点一次「动态」：当前这一栏回到顶部（和聊天列表一样）。
    func scrollToTop() {
        pages[safe: topBar.selectedIndex]?.scrollToTop()
    }

    private func scrollToPage(_ index: Int, animated: Bool) {
        let width = pagingScrollView.bounds.width
        guard width > 0, pages.indices.contains(index) else { return }
        pagingScrollView.setContentOffset(CGPoint(x: CGFloat(index) * width, y: 0), animated: animated)
        if !animated {
            topBar.setPosition(CGFloat(index))
            updateScrollsToTop()
        }
    }

    /// 点状态栏回顶只交给当前这一栏（同一屏里有多个 `scrollsToTop` 的滚动视图时系统一个都不处理）。
    private func updateScrollsToTop() {
        let selected = topBar.selectedIndex
        for (index, page) in pages.enumerated() {
            page.isCurrentPage = index == selected
        }
    }
}

extension FeedViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let previous = topBar.selectedIndex
        topBar.setPosition(scrollView.contentOffset.x / width)
        if topBar.selectedIndex != previous {
            updateScrollsToTop()
        }
    }
}
