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
/// 每栏一个 `FeedTimelineViewController`，数据都在 `FeedStore`。打开 App 默认还是「聊天」（第三节第 17 条），这里只是最左边的标签。
final class FeedViewController: OWSViewController, HomeTabViewController {

    private(set) var tabs: [FeedTab] = FeedTab.allCases
    private(set) var pages = [FeedTimelineViewController]()
    let store: FeedStore
    private let source: FeedSource

    /// 发布按钮只在右下角（第三节第 45 条），滑动时不动（第 46 条）。
    let composeButton = UIButton(type: .custom)
    static let composeButtonSize: CGFloat = 56

    private lazy var topBar = FeedTopBarView(tabs: tabs)
    private let pagingScrollView = UIScrollView()

    init(source: FeedSource = FeedSources.current()) {
        self.source = source
        store = FeedStore(source: source)
        super.init()
        pages = tabs.map { FeedTimelineViewController(tab: $0, store: store) }

        store.onChange = { [weak self] tab in
            guard let self else { return }
            for page in self.pages where tab == nil || page.feedTab == tab {
                page.apply()
            }
        }
        store.onTransientError = { [weak self] error in
            guard let self, self.viewIfLoaded?.window != nil else { return }
            switch error {
            case .network:
                self.presentToast(text: OWSLocalizedString("TELLOMI_FEED_NETWORK_ERROR", comment: "Feed: toast when refreshing the feed failed but older posts are still shown."))
            case .actionFailed:
                self.presentToast(text: OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed."))
            }
        }
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

        composeButton.setImage(UIImage(named: "compose"), for: .normal)
        composeButton.tintColor = .white
        composeButton.backgroundColor = UIColor.Signal.accent
        composeButton.layer.cornerRadius = Self.composeButtonSize / 2
        composeButton.layer.shadowColor = UIColor.black.cgColor
        composeButton.layer.shadowOpacity = 0.18
        composeButton.layer.shadowRadius = 6
        composeButton.layer.shadowOffset = CGSize(width: 0, height: 2)
        composeButton.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_COMPOSE_NEW_POST", comment: "Feed: accessibility label of the button that opens the publish page.")
        composeButton.addAction(UIAction { [weak self] _ in self?.showCompose() }, for: .touchUpInside)
        view.addSubview(composeButton)
        composeButton.autoSetDimensions(to: CGSize(square: Self.composeButtonSize))
        composeButton.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 16)
        composeButton.autoPinEdge(toSuperviewSafeArea: .bottom, withInset: 16)

        Task { await store.loadConfig() }
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

    /// 打开发布页（全屏）。发出去之后提示「已发布」或「审核中」（R-2.2），两栏刷新。
    func showCompose() {
        let compose = FeedComposeViewController(source: source) { [weak self] state in
            guard let self else { return }
            let text = state == FeedCreatePostResponse.statePending
                ? OWSLocalizedString("TELLOMI_FEED_COMPOSE_PENDING", comment: "Feed: toast after publishing when the post waits for review before others can see it.")
                : OWSLocalizedString("TELLOMI_FEED_COMPOSE_PUBLISHED", comment: "Feed: toast after the post was published.")
            self.presentToast(text: text)
            self.store.onPublished()
        }
        let navigationController = OWSNavigationController(rootViewController: compose)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true)
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
    /// 一栏第一次露出时才去取它的第一页。
    private func updateScrollsToTop() {
        let selected = topBar.selectedIndex
        for (index, page) in pages.enumerated() {
            page.isCurrentPage = index == selected
        }
        if let tab = tabs[safe: selected] {
            store.onTabShown(tab)
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
