//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 话题页（`dynamic-feed.md` 第三节第 18 条）：头上 `#话题` + 「关注话题」，下面是带这个话题的帖子（时间倒序）。
/// 逻辑在 `FeedTopicStore`，画什么在 `FeedTopicPresentation`；和信息流共用同一个 `FeedStore`，所以这里点的赞、详情里的赞、信息流里的赞是同一份数据。
///
/// 默认不接到任何入口（见 `TellomiFeed.isSearchEnabled`），不影响现有页面。
final class FeedTopicViewController: OWSViewController {
    /// 未成年人时限的提示页（时限关着时是 nil）。
    private(set) var minorLock: FeedMinorLockController?

    let store: FeedTopicStore
    let topicTableView = UITableView(frame: .zero, style: .plain)
    private let source: FeedSource
    private let feed: FeedStore?
    private let labelHint: String?

    private(set) var presentation: FeedTopicPresentation
    private(set) var rows = [FeedTopicPresentation.Row]()
    /// 最近一次弹出的提示文字（单测 / 截图用）。
    private(set) var lastToastText: String?
    /// 页面已经（因为 `feed_hidden`）收起过（单测 / 截图用）。
    private(set) var didClose = false

    /// 点了一条帖子；默认推帖子详情。
    var onOpenPost: ((FeedCard) -> Void)?
    /// 点了作者的头像 / 名字；不设就不响应（作者主页入口没开）。
    var onOpenAuthor: ((FeedAuthor) -> Void)?
    /// 点了帖子上的 `#话题`（别的话题）；不设就不响应。
    var onOpenTopic: ((FeedTopic) -> Void)?

    private let refreshControl = UIRefreshControl()

    init(slug: String, labelHint: String? = nil, source: FeedSource, feed: FeedStore?, savedMessages: FeedSavedMessages? = nil) {
        self.source = source
        self.feed = feed
        self.labelHint = labelHint
        self.store = FeedTopicStore(slug: slug, source: source, savedMessages: savedMessages, feed: feed)
        self.presentation = FeedTopicPresentation(state: store.state, slug: slug, labelHint: labelHint)
        super.init()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = presentation.title
        hidesBottomBarWhenPushed = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Signal.background

        topicTableView.backgroundColor = .clear
        topicTableView.separatorStyle = .none
        topicTableView.rowHeight = UITableView.automaticDimension
        topicTableView.estimatedRowHeight = 160
        topicTableView.dataSource = self
        topicTableView.delegate = self
        topicTableView.register(FeedTopicHeaderCell.self, forCellReuseIdentifier: FeedTopicHeaderCell.reuseIdentifier)
        topicTableView.register(FeedStatusRowCell.self, forCellReuseIdentifier: FeedStatusRowCell.reuseIdentifier)
        topicTableView.register(FeedPostCell.self, forCellReuseIdentifier: FeedPostCell.reuseIdentifier)
        view.addSubview(topicTableView)
        topicTableView.autoPinEdgesToSuperviewEdges()

        refreshControl.addAction(UIAction { [weak self] _ in self?.store.refresh() }, for: .valueChanged)
        topicTableView.refreshControl = refreshControl

        store.onChange = { [weak self] state in self?.apply(state) }
        apply(store.state)
        store.start()

        // 未成年人时限（I-15）：和动态标签过同一个检查（`FeedMinorSession`），锁着时盖上提示页。放最后，盖在所有东西上面
        minorLock = FeedMinorLockController.install(in: self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 被弹出了：不再订阅信息流、放掉借着的卡片（盖了别的页面不算）
        if isMovingFromParent || isBeingDismissed || navigationController == nil { store.detach() }
    }

    // MARK: - Rendering

    private func apply(_ state: FeedTopicState) {
        let next = FeedTopicPresentation(state: state, slug: store.slug, labelHint: labelHint)
        presentation = next
        guard isViewLoaded else { return }
        navigationItem.title = next.title

        let nextRows = next.rows
        if nextRows == rows {
            for cell in topicTableView.visibleCells {
                guard let indexPath = topicTableView.indexPath(for: cell), rows.indices.contains(indexPath.row) else { continue }
                switch (cell, rows[indexPath.row]) {
                case (let cell as FeedPostCell, .post(let id)):
                    if let card = next.posts.first(where: { $0.id == id }) {
                        cell.configure(card: card, showIpRegion: showIpRegion)
                    }
                case (let cell as FeedTopicHeaderCell, .header):
                    cell.configure(next, onFollow: { [weak self] in self?.followTapped() })
                default:
                    break
                }
            }
        } else {
            rows = nextRows
            topicTableView.reloadData()
        }
        if !state.loading, refreshControl.isRefreshing { refreshControl.endRefreshing() }

        if state.notice != nil {
            // `apply` 是 store 改 `state` 的 didSet 里调进来的：提示在下一轮主线程里显示并清掉
            DispatchQueue.main.async { [weak self] in self?.consumeNotice() }
        }
        if next.page == .feedHidden { closeBecauseFeedHidden() }
    }

    private var showIpRegion: Bool {
        return feed?.showsIpRegion ?? false
    }

    private func closeBecauseFeedHidden() {
        guard !didClose else { return }
        didClose = true
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

    /// 点了头部的「关注话题」（单测 / 截图直接调它）。取消关注不再问一句（话题关注很轻，随时能再点关注）。
    func followTapped() {
        guard presentation.isFollowEnabled else { return }
        store.toggleFollow()
    }

    private func openPost(_ card: FeedCard) {
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

    static func toastText(for notice: FeedTopicState.Notice, retryAfterSeconds: Int? = nil) -> String? {
        switch notice {
        case .followed:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_FOLLOWED", comment: "Feed topic page: toast after following a topic.")
        case .unfollowed:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_UNFOLLOWED", comment: "Feed topic page: toast after unfollowing a topic.")
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

    static func followTitle(for button: FeedTopicPresentation.FollowButton) -> String {
        switch button {
        case .hidden, .follow:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_FOLLOW", comment: "Feed topic page: button that follows a topic.")
        case .following:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_FOLLOWING", comment: "Feed topic page: button shown when already following the topic; tapping unfollows.")
        }
    }

    static func statusTexts(for status: FeedTopicPresentation.Status) -> FeedStatusTexts {
        switch status {
        case .loading, .loadingMore:
            return FeedStatusTexts(spins: true)
        case .failed(let seconds):
            return FeedStatusTexts(
                title: OWSLocalizedString("TELLOMI_FEED_TOPIC_LOAD_FAILED", comment: "Feed topic page: shown when the topic could not be loaded."),
                body: seconds.map { FeedProfileViewController.throttledText($0) },
                retry: true,
            )
        case .gone:
            return FeedStatusTexts(
                title: OWSLocalizedString("TELLOMI_FEED_TOPIC_GONE_TITLE", comment: "Feed topic page: title when the topic does not exist."),
                body: OWSLocalizedString("TELLOMI_FEED_TOPIC_GONE_BODY", comment: "Feed topic page: explanation under 'This topic is not available'."),
            )
        case .empty:
            return FeedStatusTexts(title: OWSLocalizedString("TELLOMI_FEED_TOPIC_EMPTY", comment: "Feed topic page: shown when nobody has posted with this topic yet."))
        case .loadMoreFailed(let seconds):
            return FeedStatusTexts(
                title: OWSLocalizedString("TELLOMI_FEED_TOPIC_POSTS_FAILED", comment: "Feed topic page: shown at the end of the list when more posts could not be loaded."),
                body: seconds.map { FeedProfileViewController.throttledText($0) },
                retry: true,
            )
        }
    }
}

// MARK: - Table

extension FeedTopicViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .header:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedTopicHeaderCell.reuseIdentifier, for: indexPath) as! FeedTopicHeaderCell
            cell.configure(presentation, onFollow: { [weak self] in self?.followTapped() })
            return cell
        case .post(let id):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedPostCell.reuseIdentifier, for: indexPath) as! FeedPostCell
            // 话题页上的帖子：不放「不感兴趣」（那是信息流里的），赞可以点
            cell.isReadOnly = true
            cell.allowsLikeWhenReadOnly = true
            if let card = presentation.posts.first(where: { $0.id == id }) {
                cell.configure(card: card, showIpRegion: showIpRegion)
            }
            cell.onLike = { [weak self] card in self?.store.toggleLike(card) }
            cell.onAuthorTap = onOpenAuthor
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
        guard rows.indices.contains(indexPath.row), case .post(let id) = rows[indexPath.row],
              let card = presentation.posts.first(where: { $0.id == id }) else { return }
        openPost(card)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if presentation.canLoadMore, indexPath.row >= rows.count - 3 {
            store.loadMore()
        }
    }

    private func retry(_ status: FeedTopicPresentation.Status) {
        switch status {
        case .loadMoreFailed:
            store.loadMore()
        default:
            store.refresh()
        }
    }
}

// MARK: - Cells

/// 状态行要显示的文字（话题页、搜索页共用）：`nil` = 不显示。
struct FeedStatusTexts: Equatable {
    var title: String?
    var body: String?
    var spins = false
    var retry = false
}

/// 没有帖子时的状态行 / 列表末尾的「加载中」「重试」：转圈、标题 + 说明、「重试」。
final class FeedStatusRowCell: UITableViewCell {
    static let reuseIdentifier = "FeedStatusRowCell"

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    /// 单测 / 截图用。
    let retryButton = UIButton(type: .system)
    private var onRetry: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        titleLabel.font = .dynamicTypeHeadline
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        bodyLabel.font = .dynamicTypeSubheadline
        bodyLabel.textColor = UIColor.Signal.secondaryLabel
        bodyLabel.textAlignment = .center
        bodyLabel.numberOfLines = 0

        retryButton.setTitle(OWSLocalizedString("TELLOMI_FEED_RETRY", comment: "Feed: button that tries loading the feed again."), for: .normal)
        retryButton.titleLabel?.font = .dynamicTypeBody.semibold()
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [spinner, titleLabel, bodyLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 32, left: 40, bottom: 32, right: 40))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ texts: FeedStatusTexts, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        if texts.spins { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !texts.spins
        titleLabel.text = texts.title
        titleLabel.isHidden = texts.title == nil
        bodyLabel.text = texts.body
        bodyLabel.isHidden = texts.body == nil
        retryButton.isHidden = !texts.retry
    }
}

/// 话题页头部：`#话题` + 「关注话题」按钮。
final class FeedTopicHeaderCell: UITableViewCell {
    static let reuseIdentifier = "FeedTopicHeaderCell"

    private let titleLabel = UILabel()
    /// 单测 / 截图用。
    let followButton = UIButton(type: .system)
    private var onFollow: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        titleLabel.font = .dynamicTypeTitle2.semibold()
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center

        followButton.addAction(UIAction { [weak self] _ in self?.onFollow?() }, for: .touchUpInside)
        // 最大号动态字体时按钮里的字比 40 高：只定最矮，不定死
        followButton.autoSetDimension(.height, toSize: 40, relation: .greaterThanOrEqual)
        followButton.autoSetDimension(.width, toSize: 140, relation: .greaterThanOrEqual)

        let stack = UIStackView(arrangedSubviews: [titleLabel, followButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 20, left: 24, bottom: 20, right: 24))

        let separator = UIView()
        separator.backgroundColor = UIColor.Signal.opaqueSeparator.withAlphaComponent(0.5)
        contentView.addSubview(separator)
        separator.autoPinEdge(toSuperviewEdge: .leading)
        separator.autoPinEdge(toSuperviewEdge: .trailing)
        separator.autoPinEdge(toSuperviewEdge: .bottom)
        separator.autoSetDimension(.height, toSize: 1 / max(UIScreen.main.scale, 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ presentation: FeedTopicPresentation, onFollow: @escaping () -> Void) {
        self.onFollow = onFollow
        titleLabel.text = presentation.title
        followButton.isHidden = presentation.followButton == .hidden
        var configuration = presentation.followButton == .following ? UIButton.Configuration.gray() : UIButton.Configuration.filled()
        configuration.title = FeedTopicViewController.followTitle(for: presentation.followButton)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24)
        followButton.configuration = configuration
        followButton.isEnabled = presentation.isFollowEnabled
    }
}
