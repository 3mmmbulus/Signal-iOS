//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 通知页（`dynamic-feed.md` 第三节第 43 条）：互动 / 新关注 / 系统通知三栏，每栏按「今天 / 七天内 / 更早」分组，同一条帖子的赞合成一行。
/// 逻辑在 `FeedNotificationsStore`，画什么在 `FeedNotificationsPresentation`；和信息流共用同一个 `FeedStore`：未读数（动态页的红点）是同一份，点开帖子时详情页拿到的就是信息流里现在的样子。
///
/// 默认不接到任何入口（见 `TellomiFeed.isNotificationsEnabled`），不影响现有页面。
final class FeedNotificationsViewController: OWSViewController {

    let store: FeedNotificationsStore
    let notificationsTableView = UITableView(frame: .zero, style: .plain)
    /// 三栏切换（单测 / 截图用）。
    let tabControl = UISegmentedControl(items: nil)

    private let source: FeedSource
    private let feed: FeedStore?
    private let refreshControl = UIRefreshControl()

    private(set) var presentation: FeedNotificationsPresentation
    private(set) var rows = [FeedNotificationsPresentation.Row]()
    /// 最近一次弹出的提示文字（单测 / 截图用）。
    private(set) var lastToastText: String?
    /// 页面已经（因为 `feed_hidden`）收起过（单测 / 截图用）。
    private(set) var didClose = false

    /// 点了一条帖子相关的通知；默认推帖子详情（换好的卡片）。
    var onOpenPost: ((FeedCard) -> Void)?
    /// 点了新关注 / 亲密好友请求；默认推那个人的主页。
    var onOpenPerson: ((FeedPersonSummary) -> Void)?
    /// 详情里点作者；不设就不响应（作者主页入口没开）。
    var onOpenAuthor: ((FeedAuthor) -> Void)?
    /// 详情里点 `#话题`；不设就不响应。
    var onOpenTopic: ((FeedTopic) -> Void)?

    private var shownPeople = [String: FeedPersonSummary]()

    init(initialTab: String = FeedAPI.notificationsInteractions, source: FeedSource, feed: FeedStore?) {
        self.source = source
        self.feed = feed
        self.store = FeedNotificationsStore(initialTab: initialTab, source: source, feed: feed)
        self.presentation = FeedNotificationsPresentation(state: store.state, now: Date(), calendar: .current)
        super.init()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = OWSLocalizedString("TELLOMI_FEED_NOTIF_TITLE", comment: "Feed notifications page: title.")
        hidesBottomBarWhenPushed = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Signal.background

        for (index, tab) in FeedNotificationsStore.tabs.enumerated() {
            tabControl.insertSegment(withTitle: Self.tabTitle(tab, badge: 0), at: index, animated: false)
        }
        tabControl.addAction(UIAction { [weak self] _ in self?.tabChanged() }, for: .valueChanged)
        let tabContainer = UIView()
        tabContainer.addSubview(tabControl)
        tabControl.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(hMargin: 16, vMargin: 8))

        notificationsTableView.backgroundColor = .clear
        notificationsTableView.separatorStyle = .none
        notificationsTableView.rowHeight = UITableView.automaticDimension
        notificationsTableView.estimatedRowHeight = 72
        notificationsTableView.dataSource = self
        notificationsTableView.delegate = self
        notificationsTableView.register(FeedNotificationCell.self, forCellReuseIdentifier: FeedNotificationCell.reuseIdentifier)
        notificationsTableView.register(FeedNotificationHeaderCell.self, forCellReuseIdentifier: FeedNotificationHeaderCell.reuseIdentifier)
        notificationsTableView.register(FeedStatusRowCell.self, forCellReuseIdentifier: FeedStatusRowCell.reuseIdentifier)

        view.addSubview(tabContainer)
        view.addSubview(notificationsTableView)
        tabContainer.autoPinEdge(toSuperviewSafeArea: .top)
        tabContainer.autoPinEdge(toSuperviewEdge: .leading)
        tabContainer.autoPinEdge(toSuperviewEdge: .trailing)
        notificationsTableView.autoPinEdge(.top, to: .bottom, of: tabContainer)
        notificationsTableView.autoPinEdge(toSuperviewEdge: .leading)
        notificationsTableView.autoPinEdge(toSuperviewEdge: .trailing)
        notificationsTableView.autoPinEdge(toSuperviewEdge: .bottom)

        refreshControl.addAction(UIAction { [weak self] _ in self?.store.refresh() }, for: .valueChanged)
        notificationsTableView.refreshControl = refreshControl

        store.onChange = { [weak self] state in self?.apply(state) }
        apply(store.state)
        store.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 被弹出了：不再订阅信息流、放掉借着的卡片（盖了别的页面不算）
        if isMovingFromParent || isBeingDismissed || navigationController == nil { store.detach() }
    }

    // MARK: - Rendering

    private func apply(_ state: FeedNotificationsState) {
        let next = FeedNotificationsPresentation(state: state, now: Date(), calendar: .current)
        presentation = next
        guard isViewLoaded else { return }

        for (index, tab) in FeedNotificationsStore.tabs.enumerated() where index < tabControl.numberOfSegments {
            let title = Self.tabTitle(tab, badge: next.badge(for: tab))
            if tabControl.titleForSegment(at: index) != title { tabControl.setTitle(title, forSegmentAt: index) }
        }
        if let index = FeedNotificationsStore.tabs.firstIndex(of: next.tab), tabControl.selectedSegmentIndex != index {
            tabControl.selectedSegmentIndex = index
        }

        if next.rows != rows || next.people != shownPeople {
            rows = next.rows
            shownPeople = next.people
            notificationsTableView.reloadData()
        }
        if !state.tab(state.selectedTab).loading, refreshControl.isRefreshing { refreshControl.endRefreshing() }

        if state.notice != nil {
            // `apply` 是 store 改 `state` 的 didSet 里调进来的：提示在下一轮主线程里显示并清掉
            DispatchQueue.main.async { [weak self] in self?.consumeNotice() }
        }
        if let card = state.openCard {
            DispatchQueue.main.async { [weak self] in self?.showDetail(card) }
        }
        if next.feedHidden { closeBecauseFeedHidden() }
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

    private func tabChanged() {
        let index = tabControl.selectedSegmentIndex
        guard FeedNotificationsStore.tabs.indices.contains(index) else { return }
        store.selectTab(FeedNotificationsStore.tabs[index])
    }

    /// 点一行通知（单测 / 截图直接调它）。
    func open(_ row: FeedNotificationRow) {
        switch FeedNotificationsPresentation.target(for: row) {
        case .post(let contentId):
            store.openPost(contentId)
        case .profile(let id):
            openPerson(id: id)
        case nil:
            break
        }
    }

    private func openPerson(id: String) {
        let person = presentation.people[id] ?? FeedPersonSummary(id: id, handle: nil, displayName: "", avatarKey: nil)
        if let onOpenPerson {
            onOpenPerson(person)
            return
        }
        let profile = FeedProfileViewController(profileId: id, titleHint: person.displayName.isEmpty ? nil : person.displayName, source: source, feed: feed)
        navigationController?.pushViewController(profile, animated: true)
    }

    /// `store` 换好了一张卡片：推详情（详情页自己借着这张卡片之后，这边放手）。
    private func showDetail(_ card: FeedCard) {
        guard store.state.openCard?.id == card.id else { return }
        if let onOpenPost {
            onOpenPost(card)
        } else {
            let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: showIpRegion, feed: feed)
            detail.onOpenAuthor = onOpenAuthor
            detail.onOpenTopic = onOpenTopic
            navigationController?.pushViewController(detail, animated: true)
        }
        store.onCardOpened()
    }

    private func consumeNotice() {
        guard let notice = store.state.notice else { return }
        lastToastText = Self.toastText(for: notice, retryAfterSeconds: store.state.retryAfterSeconds)
        if let text = lastToastText, viewIfLoaded?.window != nil { presentToast(text: text) }
        store.onNoticeShown()
    }

    // MARK: - Texts

    static func tabTitle(_ tab: String, badge: Int) -> String {
        let name: String
        switch tab {
        case FeedAPI.notificationsFollows:
            name = OWSLocalizedString("TELLOMI_FEED_NOTIF_TAB_FOLLOWS", comment: "Feed notifications page: tab for new followers and follow requests.")
        case FeedAPI.notificationsSystem:
            name = OWSLocalizedString("TELLOMI_FEED_NOTIF_TAB_SYSTEM", comment: "Feed notifications page: tab for review results and appeal outcomes.")
        default:
            name = OWSLocalizedString("TELLOMI_FEED_NOTIF_TAB_INTERACTIONS", comment: "Feed notifications page: tab for likes, comments and replies.")
        }
        guard badge > 0 else { return name }
        return "\(name) · \(badge > 99 ? "99+" : OWSFormat.formatInt(badge))"
    }

    static func headerTitle(_ bucket: FeedNotificationBucket) -> String {
        switch bucket {
        case .today:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_TODAY", comment: "Feed notifications page: section header for today's notifications.")
        case .thisWeek:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_THIS_WEEK", comment: "Feed notifications page: section header for notifications from the last seven days.")
        case .earlier:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_EARLIER", comment: "Feed notifications page: section header for older notifications.")
        }
    }

    static func toastText(for notice: FeedNotificationsState.Notice, retryAfterSeconds: Int? = nil) -> String? {
        switch notice {
        case .deleted:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_DELETED", comment: "Feed notifications page: toast after deleting a notification.")
        case .muted:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_MUTED", comment: "Feed notifications page: toast after turning off all notifications for a post.")
        case .mutedLikes:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_MUTED_LIKES", comment: "Feed notifications page: toast after turning off like notifications for a post.")
        case .postGone:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_POST_GONE", comment: "Feed notifications page: toast when the post a notification is about can't be shown anymore.")
        case .throttled:
            return FeedProfileViewController.throttledText(retryAfterSeconds)
        case .failed:
            return OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed.")
        }
    }

    /// 一行通知的文字（名字没查到的说「有人」）。
    static func summaryText(_ summary: FeedNotificationSummary) -> String {
        let someone = OWSLocalizedString("TELLOMI_FEED_NOTIF_SOMEONE", comment: "Feed notifications page: stands in for a person's name that isn't known yet.")
        switch summary {
        case .liked(let names, let total):
            let like = OWSLocalizedString("TELLOMI_FEED_NOTIF_LIKE", comment: "Feed notifications page: someone liked your post. Embeds {{the person's name}}.")
            if let first = names.first {
                if total <= 1 { return String(format: like, first) }
                let many = OWSLocalizedString("TELLOMI_FEED_NOTIF_LIKE_MANY", comment: "Feed notifications page: several people liked your post. Embeds {{the first person's name}} and {{how many others}}.")
                return String(format: many, first, OWSFormat.formatInt(total - 1))
            }
            if total <= 1 { return String(format: like, someone) }
            let people = OWSLocalizedString("TELLOMI_FEED_NOTIF_LIKE_PEOPLE", comment: "Feed notifications page: several people whose names aren't known liked your post. Embeds {{how many people}}.")
            return String(format: people, OWSFormat.formatInt(total))
        case .commented(let name):
            return String(format: OWSLocalizedString("TELLOMI_FEED_NOTIF_COMMENT", comment: "Feed notifications page: someone commented on your post. Embeds {{the person's name}}."), name ?? someone)
        case .commentHeld(let name):
            return String(format: OWSLocalizedString("TELLOMI_FEED_NOTIF_COMMENT_HELD", comment: "Feed notifications page: someone commented on your post and it waits for your approval. Embeds {{the person's name}}."), name ?? someone)
        case .replied(let name):
            return String(format: OWSLocalizedString("TELLOMI_FEED_NOTIF_REPLY", comment: "Feed notifications page: someone replied to your comment. Embeds {{the person's name}}."), name ?? someone)
        case .replyHeld(let name):
            return String(format: OWSLocalizedString("TELLOMI_FEED_NOTIF_REPLY_HELD", comment: "Feed notifications page: someone replied to your comment and it waits for your approval. Embeds {{the person's name}}."), name ?? someone)
        case .followed(let name):
            return String(format: OWSLocalizedString("TELLOMI_FEED_NOTIF_FOLLOW", comment: "Feed notifications page: someone started following you. Embeds {{the person's name}}."), name ?? someone)
        case .followRequested(let name):
            return String(format: OWSLocalizedString("TELLOMI_FEED_NOTIF_FOLLOW_REQUEST", comment: "Feed notifications page: someone asked to follow you. Embeds {{the person's name}}."), name ?? someone)
        case .closePersonRequest(let name):
            return String(format: OWSLocalizedString("TELLOMI_FEED_NOTIF_SYSTEM_CLOSE_PERSON", comment: "Feed notifications page: someone added you as a close person. Embeds {{the person's name}}."), name ?? someone)
        case .system(let kind):
            switch kind {
            case .rejected:
                return OWSLocalizedString("TELLOMI_FEED_NOTIF_SYSTEM_REJECTED", comment: "Feed notifications page: your post wasn't approved in review.")
            case .editRejected:
                return OWSLocalizedString("TELLOMI_FEED_NOTIF_SYSTEM_EDIT_REJECTED", comment: "Feed notifications page: your edit of a post wasn't approved in review.")
            case .takenDown:
                return OWSLocalizedString("TELLOMI_FEED_NOTIF_SYSTEM_TAKEN_DOWN", comment: "Feed notifications page: your post was taken down.")
            case .appealUpheld:
                return OWSLocalizedString("TELLOMI_FEED_NOTIF_SYSTEM_APPEAL_UPHELD", comment: "Feed notifications page: result of an appeal - the original decision stands.")
            case .appealOverturned:
                return OWSLocalizedString("TELLOMI_FEED_NOTIF_SYSTEM_APPEAL_OVERTURNED", comment: "Feed notifications page: result of an appeal - the post is visible again.")
            case .other:
                return OWSLocalizedString("TELLOMI_FEED_NOTIF_SYSTEM_OTHER", comment: "Feed notifications page: generic update about your post.")
            }
        case .other:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_SYSTEM_OTHER", comment: "Feed notifications page: generic update about your post.")
        }
    }

    static func statusTexts(for status: FeedNotificationsPresentation.Status) -> FeedStatusTexts {
        switch status {
        case .loading, .loadingMore:
            return FeedStatusTexts(spins: true)
        case .failed(let seconds):
            return FeedStatusTexts(
                title: OWSLocalizedString("TELLOMI_FEED_NOTIF_LOAD_FAILED", comment: "Feed notifications page: shown when notifications could not be loaded."),
                body: seconds.map { FeedProfileViewController.throttledText($0) },
                retry: true,
            )
        case .loadMoreFailed(let seconds):
            return FeedStatusTexts(
                title: OWSLocalizedString("TELLOMI_FEED_NOTIF_LOAD_MORE_FAILED", comment: "Feed notifications page: shown at the end of the list when more notifications could not be loaded."),
                body: seconds.map { FeedProfileViewController.throttledText($0) },
                retry: true,
            )
        case .empty(let tab):
            switch tab {
            case FeedAPI.notificationsFollows:
                return FeedStatusTexts(title: OWSLocalizedString("TELLOMI_FEED_NOTIF_EMPTY_FOLLOWS", comment: "Feed notifications page: empty state of the followers tab."))
            case FeedAPI.notificationsSystem:
                return FeedStatusTexts(title: OWSLocalizedString("TELLOMI_FEED_NOTIF_EMPTY_SYSTEM", comment: "Feed notifications page: empty state of the system tab."))
            default:
                return FeedStatusTexts(title: OWSLocalizedString("TELLOMI_FEED_NOTIF_EMPTY_INTERACTIONS", comment: "Feed notifications page: empty state of the interactions tab."))
            }
        }
    }
}

// MARK: - Table

extension FeedNotificationsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .header(let bucket):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedNotificationHeaderCell.reuseIdentifier, for: indexPath) as! FeedNotificationHeaderCell
            cell.configure(title: Self.headerTitle(bucket))
            return cell
        case .notification(let row):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedNotificationCell.reuseIdentifier, for: indexPath) as! FeedNotificationCell
            let summary = presentation.summary(for: row)
            let actor = row.actorIds.first.flatMap { presentation.people[$0] }
            cell.configure(
                avatarName: actor?.displayName,
                text: Self.summaryText(summary),
                time: FeedPostCell.relativeTime(row.createdAt, now: Date()),
                unread: row.unread,
                tappable: FeedNotificationsPresentation.target(for: row) != nil,
            )
            return cell
        case .status(let status):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedStatusRowCell.reuseIdentifier, for: indexPath) as! FeedStatusRowCell
            cell.configure(Self.statusTexts(for: status)) { [weak self] in self?.retry(status) }
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row), case .notification(let row) = rows[indexPath.row] else { return }
        open(row)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard rows.indices.contains(indexPath.row), case .notification(let row) = rows[indexPath.row] else { return nil }
        var actions = [UIContextualAction]()
        let delete = UIContextualAction(style: .destructive, title: OWSLocalizedString("TELLOMI_FEED_NOTIF_DELETE", comment: "Feed notifications page: swipe action that deletes a notification.")) { [weak self] _, _, done in
            self?.store.delete(row)
            done(true)
        }
        actions.append(delete)
        if FeedNotificationsPresentation.canMute(row) {
            let muteAll = UIContextualAction(style: .normal, title: OWSLocalizedString("TELLOMI_FEED_NOTIF_MUTE_ALL", comment: "Feed notifications page: swipe action that turns off all notifications for the post.")) { [weak self] _, _, done in
                self?.store.mute(row, likesOnly: false)
                done(true)
            }
            muteAll.backgroundColor = .systemGray
            actions.append(muteAll)
            if row.kind == FeedNotification.kindLike {
                let muteLikes = UIContextualAction(style: .normal, title: OWSLocalizedString("TELLOMI_FEED_NOTIF_MUTE_LIKES", comment: "Feed notifications page: swipe action that turns off only like notifications for the post.")) { [weak self] _, _, done in
                    self?.store.mute(row, likesOnly: true)
                    done(true)
                }
                muteLikes.backgroundColor = .systemOrange
                actions.append(muteLikes)
            }
        }
        return UISwipeActionsConfiguration(actions: actions)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if presentation.canLoadMore, indexPath.row >= rows.count - 3 {
            store.loadMore()
        }
    }

    private func retry(_ status: FeedNotificationsPresentation.Status) {
        switch status {
        case .loadMoreFailed:
            store.loadMore()
        default:
            store.refresh()
        }
    }
}

// MARK: - Cells

/// 「今天 / 七天内 / 更早」。
final class FeedNotificationHeaderCell: UITableViewCell {
    static let reuseIdentifier = "FeedNotificationHeaderCell"

    private let titleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        titleLabel.font = .dynamicTypeSubheadline.semibold()
        titleLabel.textColor = UIColor.Signal.secondaryLabel
        contentView.addSubview(titleLabel)
        titleLabel.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 16, left: 16, bottom: 6, right: 16))
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String) {
        titleLabel.text = title
        accessibilityLabel = title
    }
}

/// 一行通知：头像、一句话、时间，没读的前面有个点。
final class FeedNotificationCell: UITableViewCell {
    static let reuseIdentifier = "FeedNotificationCell"

    private let avatarView = FeedAvatarView(size: 40)
    private let messageLabel = UILabel()
    private let timeLabel = UILabel()
    /// 没读的小点（单测 / 截图用）。
    let unreadDot = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        messageLabel.font = .dynamicTypeBody
        messageLabel.textColor = UIColor.Signal.label
        messageLabel.numberOfLines = 0
        timeLabel.font = .dynamicTypeFootnote
        timeLabel.textColor = UIColor.Signal.secondaryLabel

        unreadDot.backgroundColor = UIColor.Signal.accent
        unreadDot.layer.cornerRadius = 4
        unreadDot.autoSetDimensions(to: CGSize(square: 8))

        let texts = UIStackView(arrangedSubviews: [messageLabel, timeLabel])
        texts.axis = .vertical
        texts.spacing = 2
        let stack = UIStackView(arrangedSubviews: [unreadDot, avatarView, texts])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 16))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(avatarName: String?, text: String, time: String, unread: Bool, tappable: Bool) {
        avatarView.configure(name: avatarName)
        messageLabel.text = text
        timeLabel.text = time
        unreadDot.alpha = unread ? 1 : 0
        selectionStyle = tappable ? .default : .none
        accessibilityLabel = "\(text), \(time)"
    }
}
