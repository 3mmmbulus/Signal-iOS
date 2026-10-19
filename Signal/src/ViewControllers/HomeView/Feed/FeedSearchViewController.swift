//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 搜索页（`dynamic-feed.md` 第三节第 34 条）：顶上一个搜索框，下面「全部 / 用户 / 动态」三个范围；没输入时是最近搜索和最近看过的人。
/// 逻辑在 `FeedSearchStore`，画什么在 `FeedSearchPresentation`；和信息流共用同一个 `FeedStore`，结果里的赞和信息流、详情页、主页是同一份数据。
///
/// 默认不接到任何入口（见 `TellomiFeed.isSearchEnabled`），不影响现有页面。
final class FeedSearchViewController: OWSViewController {
    /// 未成年人时限的提示页（时限关着时是 nil）。
    private(set) var minorLock: FeedMinorLockController?

    let store: FeedSearchStore
    let searchTableView = UITableView(frame: .zero, style: .plain)
    /// 搜索框（单测 / 截图用）。
    let searchBar = UISearchBar()
    /// 范围切换（单测 / 截图用）。
    let scopeControl = UISegmentedControl(items: nil)

    private let source: FeedSource
    private let feed: FeedStore?
    private let scopes = [FeedAPI.searchAll, FeedAPI.searchUsers, FeedAPI.searchPosts]
    private let scopeContainer = UIView()

    private(set) var presentation: FeedSearchPresentation
    private(set) var rows = [FeedSearchPresentation.Row]()
    /// 最近一次弹出的提示文字（单测 / 截图用）。
    private(set) var lastToastText: String?
    /// 页面已经（因为 `feed_hidden`）收起过（单测 / 截图用）。
    private(set) var didClose = false

    /// 点了一个人（搜索结果或最近看过的人）；默认推作者主页。
    var onOpenPerson: ((FeedPersonSummary) -> Void)?
    /// 点了一条帖子；默认推帖子详情。
    var onOpenPost: ((FeedCard) -> Void)?
    /// 帖子详情里点作者；不设就不响应（作者主页入口没开）。
    var onOpenAuthor: ((FeedAuthor) -> Void)?
    /// 点了帖子上的 `#话题`；不设就不响应。
    var onOpenTopic: ((FeedTopic) -> Void)?

    private var hasAppeared = false

    init(
        source: FeedSource,
        feed: FeedStore?,
        history: FeedSearchHistory = StoredFeedSearchHistory(storage: FeedLocalStorages.backupExcluded),
        savedMessages: FeedSavedMessages? = nil,
        debounceNanos: UInt64 = 350_000_000
    ) {
        self.source = source
        self.feed = feed
        self.store = FeedSearchStore(source: source, history: history, savedMessages: savedMessages, feed: feed, debounceNanos: debounceNanos)
        self.presentation = FeedSearchPresentation(state: store.state)
        super.init()
        navigationItem.largeTitleDisplayMode = .never
        hidesBottomBarWhenPushed = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tellomiApplyFeedPreviewPrompt()
        view.backgroundColor = UIColor.Signal.background

        searchBar.placeholder = OWSLocalizedString("TELLOMI_FEED_SEARCH_PLACEHOLDER", comment: "Feed search page: placeholder in the search field.")
        searchBar.searchBarStyle = .minimal
        searchBar.autocapitalizationType = .none
        searchBar.autocorrectionType = .no
        searchBar.returnKeyType = .search
        searchBar.delegate = self
        navigationItem.titleView = searchBar

        for (index, scope) in scopes.enumerated() {
            scopeControl.insertSegment(withTitle: Self.scopeTitle(scope), at: index, animated: false)
        }
        scopeControl.selectedSegmentIndex = 0
        scopeControl.addAction(UIAction { [weak self] _ in self?.scopeChanged() }, for: .valueChanged)
        scopeControl.installFeedDynamicType()
        scopeContainer.addSubview(scopeControl)
        scopeControl.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16))

        searchTableView.backgroundColor = .clear
        searchTableView.separatorStyle = .none
        searchTableView.rowHeight = UITableView.automaticDimension
        searchTableView.estimatedRowHeight = 72
        searchTableView.keyboardDismissMode = .onDrag
        searchTableView.dataSource = self
        searchTableView.delegate = self
        searchTableView.register(FeedSearchHeaderCell.self, forCellReuseIdentifier: FeedSearchHeaderCell.reuseIdentifier)
        searchTableView.register(FeedSearchRecentQueryCell.self, forCellReuseIdentifier: FeedSearchRecentQueryCell.reuseIdentifier)
        searchTableView.register(FeedSearchPersonCell.self, forCellReuseIdentifier: FeedSearchPersonCell.reuseIdentifier)
        searchTableView.register(FeedStatusRowCell.self, forCellReuseIdentifier: FeedStatusRowCell.reuseIdentifier)
        searchTableView.register(FeedPostCell.self, forCellReuseIdentifier: FeedPostCell.reuseIdentifier)

        // 范围条没输入时整个收掉（藏起来的 arranged subview 不占位置）
        let column = UIStackView(arrangedSubviews: [scopeContainer, searchTableView])
        column.axis = .vertical
        column.spacing = 0
        view.addSubview(column)
        column.autoPinEdge(toSuperviewSafeArea: .top)
        column.autoPinEdge(toSuperviewEdge: .leading)
        column.autoPinEdge(toSuperviewEdge: .trailing)
        column.autoPinEdge(toSuperviewEdge: .bottom)

        store.onChange = { [weak self] state in self?.apply(state) }
        apply(store.state)

        // 未成年人时限（I-15）：和动态标签过同一个检查（`FeedMinorSession`），锁着时盖上提示页。放最后，盖在所有东西上面
        minorLock = FeedMinorLockController.install(in: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 第一次进来直接能打字；从详情 / 主页回来不再弹键盘
        if !hasAppeared, store.state.query.isEmpty { searchBar.becomeFirstResponder() }
        hasAppeared = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 被弹出了：不再订阅信息流、放掉借着的卡片（盖了别的页面不算）
        if isMovingFromParent || isBeingDismissed || navigationController == nil { store.detach() }
    }

    // MARK: - Rendering

    private func apply(_ state: FeedSearchState) {
        let next = FeedSearchPresentation(state: state)
        presentation = next
        guard isViewLoaded else { return }

        scopeContainer.isHidden = !next.showsScopeBar
        if let index = scopes.firstIndex(of: next.scope), scopeControl.selectedSegmentIndex != index {
            scopeControl.selectedSegmentIndex = index
        }
        // 点了最近搜索 / 被截断时，搜索框里的字跟着 store（正在输入时 store 的值就是输入的，不会打架）
        if searchBar.text != state.query { searchBar.text = state.query }

        let nextRows = next.rows
        if nextRows == rows {
            for cell in searchTableView.visibleCells {
                guard let indexPath = searchTableView.indexPath(for: cell), rows.indices.contains(indexPath.row) else { continue }
                if let cell = cell as? FeedPostCell, case .post(let id) = rows[indexPath.row],
                   let card = next.posts.first(where: { $0.id == id }) {
                    cell.configure(card: card, showIpRegion: showIpRegion)
                }
            }
        } else {
            rows = nextRows
            searchTableView.reloadData()
        }

        if state.notice != nil {
            // `apply` 是 store 改 `state` 的 didSet 里调进来的：提示在下一轮主线程里显示并清掉
            DispatchQueue.main.async { [weak self] in self?.consumeNotice() }
        }
        if next.feedHidden { closeBecauseFeedHidden() }
    }

    private var showIpRegion: Bool {
        return feed?.showsIpRegion ?? false
    }

    private func closeBecauseFeedHidden() {
        guard !didClose else { return }
        didClose = true
        searchBar.resignFirstResponder()
        DispatchQueue.main.async { [weak self] in
            guard let self, let navigationController = self.navigationController else { return }
            if navigationController.topViewController === self {
                navigationController.popViewController(animated: true)
            } else {
                navigationController.viewControllers.removeAll { $0 === self }
            }
        }
    }

    // MARK: - Actions

    private func scopeChanged() {
        guard scopes.indices.contains(scopeControl.selectedSegmentIndex) else { return }
        store.selectScope(scopes[scopeControl.selectedSegmentIndex])
    }

    /// 点了一个人：记进最近看过的人，再打开主页。
    func openPerson(_ person: FeedPersonSummary) {
        searchBar.resignFirstResponder()
        store.onPersonOpened(person)
        if let onOpenPerson {
            onOpenPerson(person)
            return
        }
        let profile = FeedProfileViewController(profileId: person.id, titleHint: person.displayName, source: source, feed: feed)
        navigationController?.pushViewController(profile, animated: true)
    }

    private func openPost(_ card: FeedCard) {
        searchBar.resignFirstResponder()
        store.onPostOpened()
        if let onOpenPost {
            onOpenPost(card)
            return
        }
        let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: showIpRegion, feed: feed, eventSurface: .search)
        detail.onOpenAuthor = onOpenAuthor
        detail.onOpenTopic = onOpenTopic
        navigationController?.pushViewController(detail, animated: true)
    }

    private func consumeNotice() {
        guard let notice = store.state.notice else { return }
        if let text = Self.toastText(for: notice, retryAfterSeconds: store.state.retryAfterSeconds) {
            lastToastText = text
            if viewIfLoaded?.window != nil { presentToast(text: text) }
        }
        store.onNoticeShown()
    }

    // MARK: - Texts

    static func scopeTitle(_ scope: String) -> String {
        switch scope {
        case FeedAPI.searchUsers:
            return OWSLocalizedString("TELLOMI_FEED_SEARCH_SCOPE_USERS", comment: "Feed search page: scope tab that only searches people.")
        case FeedAPI.searchPosts:
            return OWSLocalizedString("TELLOMI_FEED_SEARCH_SCOPE_POSTS", comment: "Feed search page: scope tab that only searches posts.")
        default:
            return OWSLocalizedString("TELLOMI_FEED_SEARCH_SCOPE_ALL", comment: "Feed search page: scope tab that searches people and posts.")
        }
    }

    static func toastText(for notice: FeedSearchState.Notice, retryAfterSeconds: Int? = nil) -> String? {
        switch notice {
        case .profileRequired:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_REQUIRED", comment: "Feed: toast when an action needs the user to set up their public profile first.")
        case .throttled:
            return FeedProfileViewController.throttledText(retryAfterSeconds)
        case .failed:
            return OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed.")
        case .saved, .reposted:
            // 这个页面上没有对应的按钮
            return nil
        }
    }

    static func headerTitle(for row: FeedSearchPresentation.Row) -> String? {
        switch row {
        case .recentQueriesHeader:
            return OWSLocalizedString("TELLOMI_FEED_SEARCH_RECENT_QUERIES", comment: "Feed search page: header above the recent searches.")
        case .recentPeopleHeader:
            return OWSLocalizedString("TELLOMI_FEED_SEARCH_RECENT_PEOPLE", comment: "Feed search page: header above the people the user recently opened.")
        case .usersHeader:
            return OWSLocalizedString("TELLOMI_FEED_SEARCH_USERS_HEADER", comment: "Feed search page: header above the people in the results.")
        case .postsHeader:
            return OWSLocalizedString("TELLOMI_FEED_SEARCH_POSTS_HEADER", comment: "Feed search page: header above the posts in the results.")
        default:
            return nil
        }
    }

    static func statusTexts(for status: FeedSearchPresentation.Status) -> FeedStatusTexts {
        switch status {
        case .loading, .loadingMore:
            return FeedStatusTexts(spins: true)
        case .failed(let seconds):
            return FeedStatusTexts(
                title: OWSLocalizedString("TELLOMI_FEED_SEARCH_FAILED", comment: "Feed search page: shown when the search failed."),
                body: seconds.map { FeedProfileViewController.throttledText($0) },
                retry: true,
            )
        case .noResults(let query):
            return FeedStatusTexts(title: String(
                format: OWSLocalizedString("TELLOMI_FEED_SEARCH_NO_RESULTS_FORMAT", comment: "Feed search page: shown when nothing matched. Embeds {{what the user searched for}}."),
                query,
            ))
        case .hint:
            return FeedStatusTexts(title: OWSLocalizedString("TELLOMI_FEED_SEARCH_HINT", comment: "Feed search page: shown before the user types anything and has no history."))
        case .loadMoreFailed(let seconds):
            return FeedStatusTexts(
                title: OWSLocalizedString("TELLOMI_FEED_SEARCH_MORE_FAILED", comment: "Feed search page: shown at the end of the results when more could not be loaded."),
                body: seconds.map { FeedProfileViewController.throttledText($0) },
                retry: true,
            )
        }
    }
}

// MARK: - Search bar

extension FeedSearchViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        store.onQueryChange(searchText)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        store.submit()
        searchBar.resignFirstResponder()
    }
}

// MARK: - Table

extension FeedSearchViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        switch row {
        case .recentQueriesHeader:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedSearchHeaderCell.reuseIdentifier, for: indexPath) as! FeedSearchHeaderCell
            cell.configure(title: Self.headerTitle(for: row) ?? "", actionTitle: OWSLocalizedString("TELLOMI_FEED_SEARCH_CLEAR", comment: "Feed search page: button that clears the search history.")) { [weak self] in
                self?.store.clearRecentQueries()
            }
            return cell
        case .recentPeopleHeader:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedSearchHeaderCell.reuseIdentifier, for: indexPath) as! FeedSearchHeaderCell
            cell.configure(title: Self.headerTitle(for: row) ?? "", actionTitle: OWSLocalizedString("TELLOMI_FEED_SEARCH_CLEAR", comment: "Feed search page: button that clears the search history.")) { [weak self] in
                self?.store.clearRecentPeople()
            }
            return cell
        case .usersHeader, .postsHeader:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedSearchHeaderCell.reuseIdentifier, for: indexPath) as! FeedSearchHeaderCell
            cell.configure(title: Self.headerTitle(for: row) ?? "", actionTitle: nil, action: nil)
            return cell
        case .recentQuery(let query):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedSearchRecentQueryCell.reuseIdentifier, for: indexPath) as! FeedSearchRecentQueryCell
            cell.configure(query: query)
            return cell
        case .recentPerson(let id):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedSearchPersonCell.reuseIdentifier, for: indexPath) as! FeedSearchPersonCell
            if let person = presentation.recentPeople.first(where: { $0.id == id }) {
                cell.configure(name: person.displayName, handle: person.handle)
            }
            return cell
        case .user(let id):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedSearchPersonCell.reuseIdentifier, for: indexPath) as! FeedSearchPersonCell
            if let user = presentation.users.first(where: { $0.id == id }) {
                cell.configure(name: user.displayName, handle: user.handle)
            }
            return cell
        case .post(let id):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedPostCell.reuseIdentifier, for: indexPath) as! FeedPostCell
            // 搜索结果里的帖子：不放「不感兴趣」（那是信息流里的），赞可以点
            cell.isReadOnly = true
            cell.allowsLikeWhenReadOnly = true
            if let card = presentation.posts.first(where: { $0.id == id }) {
                cell.configure(card: card, showIpRegion: showIpRegion)
            }
            cell.onLike = { [weak self] card in self?.store.toggleLike(card) }
            cell.onTopicTap = onOpenTopic
            return cell
        case .status(let status):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedStatusRowCell.reuseIdentifier, for: indexPath) as! FeedStatusRowCell
            cell.configure(Self.statusTexts(for: status)) { [weak self] in self?.retry(status) }
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row) else { return }
        switch rows[indexPath.row] {
        case .recentQuery(let query):
            store.useRecentQuery(query)
            searchBar.resignFirstResponder()
        case .recentPerson(let id):
            if let person = presentation.recentPeople.first(where: { $0.id == id }) { openPerson(person) }
        case .user(let id):
            if let user = presentation.users.first(where: { $0.id == id }) { openPerson(user.asPerson()) }
        case .post(let id):
            if let card = presentation.posts.first(where: { $0.id == id }) { openPost(card) }
        case .recentQueriesHeader, .recentPeopleHeader, .usersHeader, .postsHeader, .status:
            break
        }
    }

    /// 最近搜索左滑可以删掉一条。
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard rows.indices.contains(indexPath.row), case .recentQuery(let query) = rows[indexPath.row] else { return nil }
        let remove = UIContextualAction(style: .destructive, title: OWSLocalizedString("TELLOMI_FEED_SEARCH_REMOVE", comment: "Feed search page: swipe action that removes one recent search.")) { [weak self] _, _, done in
            self?.store.removeRecentQuery(query)
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if presentation.canLoadMore, indexPath.row >= rows.count - 3 {
            store.loadMore()
        }
    }

    private func retry(_ status: FeedSearchPresentation.Status) {
        switch status {
        case .loadMoreFailed:
            store.loadMore()
        default:
            store.retry()
        }
    }
}

// MARK: - Cells

/// 一段的标题（可带右边的「清除」）。
final class FeedSearchHeaderCell: UITableViewCell {
    static let reuseIdentifier = "FeedSearchHeaderCell"

    private let titleLabel = UILabel()
    /// 单测 / 截图用。
    let actionButton = UIButton(type: .system)
    private var action: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        titleLabel.font = .dynamicTypeSubheadline.semibold()
        titleLabel.textColor = UIColor.Signal.secondaryLabel
        titleLabel.numberOfLines = 0
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        actionButton.titleLabel?.font = .dynamicTypeSubheadline
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionButton.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, actionButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 16, left: 16, bottom: 6, right: 16))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, actionTitle: String?, action: (() -> Void)?) {
        self.action = action
        titleLabel.text = title
        actionButton.setTitle(actionTitle, for: .normal)
        actionButton.isHidden = actionTitle == nil
    }
}

/// 一条最近搜索。
final class FeedSearchRecentQueryCell: UITableViewCell {
    static let reuseIdentifier = "FeedSearchRecentQueryCell"

    private let iconView = UIImageView(image: UIImage(systemName: "clock"))
    private let queryLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        iconView.tintColor = UIColor.Signal.secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.autoSetDimensions(to: CGSize(square: 20))

        queryLabel.font = .dynamicTypeBody
        queryLabel.textColor = UIColor.Signal.label
        queryLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [iconView, queryLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(query: String) {
        queryLabel.text = query
    }
}

/// 一个人（搜索结果 / 最近看过）：头像、名字、@handle。
final class FeedSearchPersonCell: UITableViewCell {
    static let reuseIdentifier = "FeedSearchPersonCell"

    private let avatarView = FeedAvatarView(size: 44)
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        nameLabel.font = .dynamicTypeBody.semibold()
        nameLabel.textColor = UIColor.Signal.label
        nameLabel.numberOfLines = 0
        handleLabel.font = .dynamicTypeSubheadline
        handleLabel.textColor = UIColor.Signal.secondaryLabel

        let texts = UIStackView(arrangedSubviews: [nameLabel, handleLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let stack = UIStackView(arrangedSubviews: [avatarView, texts])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(name: String, handle: String?) {
        avatarView.configure(name: name)
        nameLabel.text = name
        let shown = handle.flatMap { $0.isEmpty ? nil : "@\($0)" }
        handleLabel.text = shown
        handleLabel.isHidden = shown == nil
    }
}
