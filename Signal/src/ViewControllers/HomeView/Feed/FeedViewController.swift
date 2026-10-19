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

    private var feedSubscription: FeedSubscription?

    private lazy var topBar = FeedTopBarView(tabs: tabs)
    private let pagingScrollView = UIScrollView()

    /// 作者主页入口开着没有（`TellomiFeed.isProfilePageEnabled`，默认关）。单测 / 截图可以直接传 true。
    let profilePageEnabled: Bool

    /// 搜索页 / 话题页入口开着没有（`TellomiFeed.isSearchEnabled`，默认关）。单测 / 截图可以直接传 true。
    let searchEnabled: Bool

    /// 通知页入口（左上角的铃铛）开着没有（`TellomiFeed.isNotificationsEnabled`，默认关）。单测 / 截图可以直接传 true。
    let notificationsEnabled: Bool
    /// 铃铛按钮和它的红点（单测 / 截图用；入口没开时按钮不在导航栏上）。
    let notificationsButton = FeedBellButton()

    /// 「我的动态」入口（左上角的文档图标）开着没有（`TellomiFeed.isMyPostsEnabled`，默认关）。单测 / 截图可以直接传 true。
    let myPostsEnabled: Bool
    /// 「我的动态」按钮（单测 / 截图用；入口没开时是 nil）。
    private(set) var myPostsItem: UIBarButtonItem?

    /// 动态设置入口（右上角的齿轮）开着没有（`TellomiFeed.isSettingsEnabled`，默认关）。单测 / 截图可以直接传 true。
    let settingsEnabled: Bool
    /// 齿轮按钮（单测 / 截图用；入口没开时是 nil）。
    private(set) var settingsItem: UIBarButtonItem?
    /// 入口按钮有 4 个时，「我的动态」和齿轮收进的「···」菜单按钮（单测 / 截图用；其它时候是 nil，那时两个按钮各自在栏上）。
    private(set) var overflowItem: UIBarButtonItem?
    /// 本机「完全屏蔽」的词：设置页和信息流（`FeedStore`）共用这一份；入口没开时是 nil（信息流不过滤）。
    let blockedKeywords: FeedBlockedKeywords?

    /// 未成年人时限（I-15，`TellomiFeed.isMinorTimeEnabled`，默认关）：App 级共用的那一份；关着时是 nil，不计时、不锁。
    let minorSession: FeedMinorSession?
    /// 盖在动态上的提示页（`FeedMinorLockController`；时限关着时是 nil）。
    private(set) var minorLock: FeedMinorLockController?

    init(
        source: FeedSource = FeedSources.current(),
        profilePageEnabled: Bool = TellomiFeed.isProfilePageEnabled,
        searchEnabled: Bool = TellomiFeed.isSearchEnabled,
        notificationsEnabled: Bool = TellomiFeed.isNotificationsEnabled,
        myPostsEnabled: Bool = TellomiFeed.isMyPostsEnabled,
        settingsEnabled: Bool = TellomiFeed.isSettingsEnabled,
        blockedKeywords: FeedBlockedKeywords? = nil,
        minorSession: FeedMinorSession? = FeedMinorSession.current
    ) {
        self.source = source
        self.profilePageEnabled = profilePageEnabled
        self.searchEnabled = searchEnabled
        self.notificationsEnabled = notificationsEnabled
        self.myPostsEnabled = myPostsEnabled
        self.settingsEnabled = settingsEnabled
        // 设置页打开时才读本机的词表（放在不进备份的目录里）；没开设置入口，信息流和以前一样不过滤
        let keywords = blockedKeywords ?? (settingsEnabled ? StoredFeedBlockedKeywords(storage: FeedLocalStorages.backupExcluded) : nil)
        self.blockedKeywords = keywords
        store = FeedStore(source: source, blockedKeywords: keywords)
        self.minorSession = minorSession
        super.init()
        if let minorSession {
            // 配置回来记住 `minor_mode`（App 级那一份；从通知 / 链接直接打开的详情也用它）
            store.onConfigLoaded = { [weak minorSession] config in minorSession?.configLoaded(minorMode: config.minorMode) }
        }
        pages = tabs.map { FeedTimelineViewController(tab: $0, store: store) }
        for page in pages {
            page.onOpenPost = { [weak self] card in self?.openPost(card) }
            if profilePageEnabled {
                page.onOpenAuthor = { [weak self] author in self?.openAuthor(author) }
            }
            if searchEnabled {
                page.onOpenTopic = { [weak self] topic in self?.openTopic(topic) }
            }
        }

        // 和帖子详情页订阅同一个 store：详情里点了赞，这里的那一行也跟着变（拿着回执就订着，页面销毁时一起放掉）
        feedSubscription = store.subscribe { [weak self] change in
            self?.onStoreChange(change)
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

    /// `FeedStore` 里有什么变了：列表（某一栏）、卡片内容（详情页点赞 / 评论数变了…）都重画；
    /// 动作失败（点赞失败已改回）的提示走 `onTransientError`，这里不重复提示。
    private func onStoreChange(_ change: FeedChange) {
        switch change {
        case .list(let tab):
            for page in pages where tab == nil || page.feedTab == tab {
                page.apply()
            }
        case .cards:
            for page in pages {
                page.apply()
            }
        case .unread:
            updateNotificationsBadge()
        case .actionFailed:
            break
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tellomiApplyFeedPreviewPrompt()

        view.backgroundColor = UIColor.Signal.background
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = topBar
        navigationItem.backButtonDisplayMode = .minimal
        topBar.onSelect = { [weak self] index in self?.scrollToPage(index, animated: true) }
        // 入口按钮（铃铛、我的动态、搜索、齿轮）有 4 个：标题栏被挤得放不下「Following」，我的动态和齿轮收进「···」菜单
        let entryCount = [notificationsEnabled, myPostsEnabled, searchEnabled, settingsEnabled].filter { $0 }.count
        let overflow = FeedDynamicTypeLayout.topBarUsesOverflow(entryCount: entryCount)
        var rightItems = [UIBarButtonItem]()
        if searchEnabled {
            let search = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.openSearch() })
            search.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_SEARCH_BUTTON", comment: "Feed: accessibility label of the search button at the top of the feed.")
            rightItems.append(search)
        }
        var leftItems = [UIBarButtonItem]()
        if notificationsEnabled {
            notificationsButton.addAction(UIAction { [weak self] _ in self?.openNotifications() }, for: .touchUpInside)
            notificationsButton.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_NOTIF_TITLE", comment: "Feed notifications page: title.")
            leftItems.append(UIBarButtonItem(customView: notificationsButton))
            updateNotificationsBadge()
        }
        if overflow {
            let myPosts = UIAction(title: FeedMyPostsViewController.title, image: UIImage(systemName: "doc.text")) { [weak self] _ in self?.openMyPosts() }
            let settings = UIAction(title: FeedRecommendationSettingsViewController.title, image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.openSettings() }
            let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [myPosts, settings]))
            more.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_MORE", comment: "Feed: accessibility label for the ··· button on a post.")
            overflowItem = more
            // 搜索在最右，菜单在它左边（`rightBarButtonItems` 第一个是最右的）
            rightItems.append(more)
        } else {
            if settingsEnabled {
                let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in self?.openSettings() })
                settings.accessibilityLabel = FeedRecommendationSettingsViewController.title
                settingsItem = settings
                // 搜索在最右，齿轮在它左边
                rightItems.append(settings)
            }
            if myPostsEnabled {
                let myPosts = UIBarButtonItem(image: UIImage(systemName: "doc.text"), primaryAction: UIAction { [weak self] _ in self?.openMyPosts() })
                myPosts.accessibilityLabel = FeedMyPostsViewController.title
                myPostsItem = myPosts
                leftItems.append(myPosts)
            }
        }
        if rightItems.count == 1 {
            navigationItem.rightBarButtonItem = rightItems[0]
        } else if !rightItems.isEmpty {
            navigationItem.rightBarButtonItems = rightItems
        }
        if !leftItems.isEmpty { navigationItem.leftBarButtonItems = leftItems }

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

        // 退到后台：停掉曝光计时，发掉攒着的事件（契约 6.1）
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: .OWSApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: .OWSApplicationWillEnterForeground, object: nil)

        // 最后装：盖在所有东西上面
        minorLock = FeedMinorLockController.install(in: self, session: minorSession)
        minorLock?.onLockChanged = { [weak self] lock in self?.applyMinorLock(lock) }
        applyMinorLock(minorSession?.lock)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setFeedVisible(true)
        if notificationsEnabled { store.refreshNotificationUnread() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        setFeedVisible(false)
    }

    /// 锁上（提示页由 `FeedMinorLockController` 盖、导航栏按钮也由它禁用）：再藏掉发布按钮、顶栏不能切、停掉曝光；解锁后恢复。
    func applyMinorLock(_ lock: FeedMinorTime.Lock?) {
        guard isViewLoaded else { return }
        let locked = lock != nil
        composeButton.isHidden = locked
        topBar.isUserInteractionEnabled = !locked
        if locked {
            setFeedVisible(false)
        } else if viewIfLoaded?.window != nil {
            setFeedVisible(true)
        }
    }

    @objc
    private func didEnterBackground() {
        setFeedVisible(false)
    }

    @objc
    private func willEnterForeground() {
        if viewIfLoaded?.window != nil {
            setFeedVisible(true)
            if notificationsEnabled { store.refreshNotificationUnread() }
        }
    }

    /// 动态页在不在屏幕上；看不见时 `FeedStore` 停掉曝光计时并发掉攒着的事件。
    func setFeedVisible(_ visible: Bool) {
        // 未成年人时限锁着时，提示页下面的列表不算看得见（不计曝光）
        let visible = visible && minorSession?.isLocked != true
        for page in pages {
            page.isFeedVisible = visible
        }
        if !visible {
            store.onFeedHidden()
        }
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
        let compose = FeedComposeViewController.make(source: source) { [weak self] state in
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

    /// 点一条帖子：推帖子详情页（`FeedPostDetailViewController`），底栏收起。
    private func openPost(_ card: FeedCard) {
        // 详情页用列表的 store（单一数据源）：赞、评论数改在 store 里，列表这边通过订阅同步
        let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: store.showsIpRegion, feed: store, eventSurface: FeedEventSurface(tab: selectedTab))
        if profilePageEnabled {
            detail.onOpenAuthor = { [weak self] author in self?.openAuthor(author) }
        }
        if searchEnabled {
            detail.onOpenTopic = { [weak self] topic in self?.openTopic(topic) }
        }
        navigationController?.pushViewController(detail, animated: true)
    }

    /// 点帖子上的 `#话题`：推话题页（和列表、详情共用同一个 `FeedStore`）。
    func openTopic(_ topic: FeedTopic) {
        guard searchEnabled, !topic.slug.isEmpty else { return }
        let page = FeedTopicViewController(slug: topic.slug, labelHint: topic.label, source: source, feed: store)
        if profilePageEnabled {
            page.onOpenAuthor = { [weak self] author in self?.openAuthor(author) }
        }
        page.onOpenTopic = { [weak self] topic in self?.openTopic(topic) }
        navigationController?.pushViewController(page, animated: true)
    }

    /// 点右上角的搜索：推搜索页。搜索结果里点人默认推作者主页（不看作者主页那个开关：搜到人就是为了点进去）。
    func openSearch() {
        guard searchEnabled else { return }
        let page = FeedSearchViewController(source: source, feed: store)
        if profilePageEnabled {
            page.onOpenAuthor = { [weak self] author in self?.openAuthor(author) }
        }
        page.onOpenTopic = { [weak self] topic in self?.openTopic(topic) }
        navigationController?.pushViewController(page, animated: true)
    }

    /// 点左上角的铃铛：推通知页（和列表、详情共用同一个 `FeedStore`，红点是同一份）。
    func openNotifications() {
        guard notificationsEnabled else { return }
        let page = FeedNotificationsViewController(source: source, feed: store)
        if profilePageEnabled {
            page.onOpenAuthor = { [weak self] author in self?.openAuthor(author) }
        }
        if searchEnabled {
            page.onOpenTopic = { [weak self] topic in self?.openTopic(topic) }
        }
        navigationController?.pushViewController(page, animated: true)
    }

    /// 点左上角的「我的动态」：推我的动态页（和列表、详情共用同一个 `FeedStore`：删掉的帖子信息流里同时去掉）。
    func openMyPosts() {
        guard myPostsEnabled else { return }
        let page = FeedMyPostsViewController(source: source, feed: store)
        if profilePageEnabled {
            page.onOpenAuthor = { [weak self] author in self?.openAuthor(author) }
        }
        if searchEnabled {
            page.onOpenTopic = { [weak self] topic in self?.openTopic(topic) }
        }
        navigationController?.pushViewController(page, animated: true)
    }

    /// 点右上角的齿轮：推动态设置页（本机屏蔽词和信息流共用同一份；改了词，信息流下一次刷新时才认）。
    func openSettings() {
        guard settingsEnabled, let blockedKeywords else { return }
        let page = FeedRecommendationSettingsViewController(source: source, blockedKeywords: blockedKeywords)
        navigationController?.pushViewController(page, animated: true)
    }

    /// 铃铛上的红点：互动 / 新关注 / 系统任何一栏有没读的就亮。
    private func updateNotificationsBadge() {
        guard notificationsEnabled else { return }
        let unread = store.notificationUnread
        notificationsButton.setUnreadCount(unread.interactions + unread.follows + unread.system)
    }

    /// 点作者的头像 / 名字：推作者主页（和列表、详情共用同一个 `FeedStore`）。外部作者没有主页，不响应。
    func openAuthor(_ author: FeedAuthor) {
        guard profilePageEnabled, tellomiFeedCanOpenProfile(of: author) else { return }
        let profile = FeedProfileViewController(profileId: author.profileId, titleHint: author.displayName, source: source, feed: store)
        navigationController?.pushViewController(profile, animated: true)
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

/// 动态页左上角的铃铛：右上角一个红点（有没读的通知时）。
final class FeedBellButton: UIButton {
    /// 红点（单测 / 截图用）。
    let dot = UIView()
    private(set) var unreadCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        setImage(UIImage(systemName: "bell"), for: .normal)
        tintColor = UIColor.Signal.label
        dot.backgroundColor = .systemRed
        dot.layer.cornerRadius = 4.5
        dot.isUserInteractionEnabled = false
        dot.isHidden = true
        addSubview(dot)
        dot.autoSetDimensions(to: CGSize(square: 9))
        dot.autoPinEdge(toSuperviewEdge: .top, withInset: 4)
        dot.autoPinEdge(toSuperviewEdge: .trailing, withInset: 4)
        autoSetDimensions(to: CGSize(square: 44))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setUnreadCount(_ count: Int) {
        unreadCount = count
        dot.isHidden = count <= 0
        accessibilityValue = count > 0 ? OWSFormat.formatInt(min(count, 99)) : nil
    }
}
