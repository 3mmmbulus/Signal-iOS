//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 作者主页（`dynamic-feed.md` 第三节第 8–10、29、33 条）：头部（头像、名字、简介、粉丝数、关注按钮）+ 下面的帖子列表。
/// 逻辑在 `FeedProfilePageStore`，画什么在 `FeedProfilePresentation`；和信息流共用同一个 `FeedStore`，
/// 所以这里点的赞、详情页里点的赞、信息流里的赞是同一份数据。
///
/// 默认不接到任何入口（见 `TellomiFeed.isProfilePageEnabled`），不影响现有页面。
final class FeedProfileViewController: OWSViewController {
    /// 未成年人时限的提示页（时限关着时是 nil）。
    private(set) var minorLock: FeedMinorLockController?

    /// 要先问一句的操作（关注按钮上的取消关注 / 撤回请求；屏蔽在「···」里）。
    enum Confirmation: Equatable {
        case unfollow
        case cancelRequest
        case block
    }

    static let avatarSize: CGFloat = 72

    let store: FeedProfilePageStore
    let profileTableView = UITableView(frame: .zero, style: .plain)
    private let source: FeedSource
    private let feed: FeedStore?
    private let titleHint: String?

    private(set) var presentation: FeedProfilePresentation
    private(set) var rows = [FeedProfilePresentation.Row]()
    /// 最近一次弹出的提示文字（单测 / 截图用）。
    private(set) var lastToastText: String?
    /// 页面已经（因为 `feed_hidden`）收起过（单测 / 截图用）。
    private(set) var didClose = false

    /// 单测 / 截图用：不弹确认框，直接把问题和「确认」交出去。
    var confirmDestructive: ((Confirmation, @escaping () -> Void) -> Void)?
    /// 点了一条帖子；默认推帖子详情。
    var onOpenPost: ((FeedCard) -> Void)?

    private let refreshControl = UIRefreshControl()
    private var hasAppeared = false

    init(profileId: String, titleHint: String? = nil, source: FeedSource, feed: FeedStore?, savedMessages: FeedSavedMessages? = nil) {
        self.source = source
        self.feed = feed
        self.titleHint = titleHint
        self.store = FeedProfilePageStore(profileId: profileId, source: source, savedMessages: savedMessages, feed: feed)
        self.presentation = FeedProfilePresentation(state: store.state)
        super.init()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = titleHint
        hidesBottomBarWhenPushed = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tellomiApplyFeedPreviewPrompt()
        view.backgroundColor = UIColor.Signal.background

        profileTableView.backgroundColor = .clear
        profileTableView.separatorStyle = .none
        profileTableView.rowHeight = UITableView.automaticDimension
        profileTableView.estimatedRowHeight = 160
        profileTableView.dataSource = self
        profileTableView.delegate = self
        profileTableView.register(FeedProfileHeaderCell.self, forCellReuseIdentifier: FeedProfileHeaderCell.reuseIdentifier)
        profileTableView.register(FeedProfileStatusCell.self, forCellReuseIdentifier: FeedProfileStatusCell.reuseIdentifier)
        profileTableView.register(FeedPostCell.self, forCellReuseIdentifier: FeedPostCell.reuseIdentifier)
        view.addSubview(profileTableView)
        profileTableView.autoPinEdgesToSuperviewEdges()

        refreshControl.addAction(UIAction { [weak self] _ in self?.store.refresh() }, for: .valueChanged)
        profileTableView.refreshControl = refreshControl

        store.onChange = { [weak self] state in self?.apply(state) }
        apply(store.state)
        store.start()

        // 未成年人时限（I-15）：和动态标签过同一个检查（`FeedMinorSession`），锁着时盖上提示页。放最后，盖在所有东西上面
        minorLock = FeedMinorLockController.install(in: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从帖子详情回来：那边可能删了帖子、改了置顶
        if hasAppeared { store.onReappeared() }
        hasAppeared = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 被弹出了：不再订阅信息流、放掉借着的卡片（盖了别的页面不算）
        if isMovingFromParent || isBeingDismissed || navigationController == nil { store.detach() }
    }

    // MARK: - Rendering

    private func apply(_ state: FeedProfilePageState) {
        let next = FeedProfilePresentation(state: state)
        presentation = next
        guard isViewLoaded else { return }
        navigationItem.title = next.displayName.isEmpty ? titleHint : next.displayName
        updateNavigationItems(next)

        let nextRows = next.rows
        if nextRows == rows {
            for case let cell as FeedPostCell in profileTableView.visibleCells {
                guard let indexPath = profileTableView.indexPath(for: cell), case .post(let id) = rows[indexPath.row],
                      let card = next.posts.first(where: { $0.id == id }) else { continue }
                cell.configure(card: card, showIpRegion: state.showIpRegion)
            }
            for case let cell as FeedProfileHeaderCell in profileTableView.visibleCells {
                cell.configure(next, onFollow: { [weak self] in self?.followTapped() })
            }
        } else {
            rows = nextRows
            profileTableView.reloadData()
        }
        if !state.loading, refreshControl.isRefreshing { refreshControl.endRefreshing() }

        if state.notice != nil {
            // `apply` 是 store 改 `state` 的 didSet 里调进来的：提示在下一轮主线程里显示并清掉
            DispatchQueue.main.async { [weak self] in self?.consumeNotice() }
        }
        if next.page == .feedHidden { closeBecauseFeedHidden() }
    }

    // MARK: - 「···」菜单

    /// 导航栏上现在放着的菜单项（单测 / 截图用）。
    private(set) var shownMenu = [FeedProfileMenuItem]()
    /// 正在显示的举报页（单测 / 截图用）。
    private(set) var presentedReport: FeedReportViewController?

    /// 导航栏右上角的「···」：别人的主页是「不看 / 不让看」「屏蔽」「举报」，自己的主页没有。没有可放的项就不显示按钮。
    private func updateNavigationItems(_ presentation: FeedProfilePresentation) {
        guard presentation.menu != shownMenu else { return }
        shownMenu = presentation.menu
        guard !shownMenu.isEmpty else {
            navigationItem.rightBarButtonItem = nil
            return
        }
        let button = UIBarButtonItem.contextMenuButton(actions: shownMenu.map { menuAction($0) })
        button.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_MORE", comment: "Feed: accessibility label for the ··· button on a post.")
        navigationItem.rightBarButtonItem = button
    }

    private func menuAction(_ item: FeedProfileMenuItem) -> UIAction {
        return UIAction(title: Self.menuTitle(for: item), attributes: item == .block ? .destructive : []) { [weak self] _ in
            self?.handleMenuItem(item)
        }
    }

    /// 点了菜单里的一项。屏蔽先确认；举报打开举报页。单测 / 截图直接调它。
    func handleMenuItem(_ item: FeedProfileMenuItem) {
        switch item {
        case .mute(let on):
            store.setHidden(list: FeedAPI.hideMute, on: on)
        case .hideFrom(let on):
            store.setHidden(list: FeedAPI.hideFrom, on: on)
        case .block:
            confirm(.block) { [weak self] in self?.store.setBlocked(true) }
        case .unblock:
            store.setBlocked(false)
        case .report:
            presentReport()
        }
    }

    func presentReport() {
        guard presentedReport == nil else { return }
        let reportStore = store.reportStore()
        reportStore.start()
        let report = FeedReportViewController(store: reportStore) { [weak self] outcome in
            self?.presentedReportFinished(outcome)
        }
        presentedReport = report
        present(OWSNavigationController(rootViewController: report), animated: true)
    }

    /// 举报页关了：提交成功提示「已提交」，`feed_hidden` 让主页跟着收起。
    func presentedReportFinished(_ outcome: FeedReportViewController.Outcome) {
        presentedReport = nil
        // feed_hidden：主页马上要收起，举报页不做收起动画——否则主页的 pop 要等举报页的转场结束（约 0.8 秒）才开始
        dismiss(animated: outcome != .feedHidden)
        switch outcome {
        case .sent: store.onReported()
        case .feedHidden: store.onFeedHidden()
        case .cancelled: break
        }
    }

    static func menuTitle(for item: FeedProfileMenuItem) -> String {
        switch item {
        case .mute(let on):
            return on
                ? OWSLocalizedString("TELLOMI_FEED_PROFILE_MENU_MUTE_ON", comment: "Feed profile page: ··· menu item that hides this person's posts from the feed.")
                : OWSLocalizedString("TELLOMI_FEED_PROFILE_MENU_MUTE_OFF", comment: "Feed profile page: ··· menu item that shows this person's posts in the feed again.")
        case .hideFrom(let on):
            return on
                ? OWSLocalizedString("TELLOMI_FEED_PROFILE_MENU_HIDE_FROM_ON", comment: "Feed profile page: ··· menu item that hides the user's posts from this person.")
                : OWSLocalizedString("TELLOMI_FEED_PROFILE_MENU_HIDE_FROM_OFF", comment: "Feed profile page: ··· menu item that lets this person see the user's posts again.")
        case .block:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_BLOCK", comment: "Feed profile page: confirmation button that blocks someone.")
        case .unblock:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_UNBLOCK", comment: "Feed profile page: button that unblocks someone.")
        case .report:
            return OWSLocalizedString("TELLOMI_FEED_MENU_REPORT", comment: "Feed: ··· menu item that reports a post or a comment.")
        }
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

    /// 点了头部的关注按钮（单测 / 截图直接调它）。
    func followTapped() {
        switch presentation.followButton {
        case .hidden:
            break
        case .follow:
            store.follow()
        case .requested:
            confirm(.cancelRequest) { [weak self] in self?.store.unfollow() }
        case .following:
            confirm(.unfollow) { [weak self] in self?.store.unfollow() }
        case .unblock:
            store.setBlocked(false)
        }
    }

    func confirm(_ confirmation: Confirmation, proceed: @escaping () -> Void) {
        if let confirmDestructive {
            confirmDestructive(confirmation, proceed)
            return
        }
        OWSActionSheets.showConfirmationAlert(
            title: Self.confirmationTitle(for: confirmation),
            proceedTitle: Self.confirmationButton(for: confirmation),
            proceedStyle: .destructive,
            proceedAction: { _ in proceed() },
            fromViewController: self,
        )
    }

    private func openPost(_ card: FeedCard) {
        if let onOpenPost {
            onOpenPost(card)
            return
        }
        let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: presentation.ipRegionLabel != nil || (feed?.showsIpRegion ?? false), feed: feed, eventSurface: .profile)
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

    static func toastText(for notice: FeedProfilePageState.Notice, retryAfterSeconds: Int? = nil) -> String? {
        switch notice {
        case .followed:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_FOLLOWED", comment: "Feed profile page: toast after following someone.")
        case .requested:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_REQUESTED", comment: "Feed profile page: toast after asking to follow a private account.")
        case .profileRequired:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_REQUIRED", comment: "Feed: toast when an action needs the user to set up their public profile first.")
        case .blocked:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_BLOCKED", comment: "Feed profile page: toast after blocking someone.")
        case .unblocked:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_UNBLOCKED", comment: "Feed profile page: toast after unblocking someone.")
        case .muted:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_MUTED", comment: "Feed profile page: toast after choosing not to see someone's posts.")
        case .hiddenFrom:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_HIDDEN_FROM", comment: "Feed profile page: toast after hiding your posts from someone.")
        case .throttled:
            return throttledText(retryAfterSeconds)
        case .reported:
            return OWSLocalizedString("TELLOMI_FEED_REPORT_SENT", comment: "Feed: toast after a report was submitted.")
        case .failed:
            return OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed.")
        case .pinLimit, .saved, .reposted:
            // 这个页面上没有对应的按钮
            return nil
        }
    }

    /// 限速说「请 N 秒后再试」，没有秒数就泛泛地说（和详情页同样两句）。
    static func throttledText(_ seconds: Int?) -> String {
        if let seconds {
            return String(
                format: OWSLocalizedString("TELLOMI_FEED_THROTTLED_FORMAT", comment: "Feed: toast when the server says to slow down. Embeds {{the number of seconds to wait}}."),
                OWSFormat.formatInt(seconds),
            )
        }
        return OWSLocalizedString("TELLOMI_FEED_THROTTLED", comment: "Feed: toast when the server says to slow down and gives no time.")
    }

    static func followTitle(for button: FeedProfilePresentation.FollowButton) -> String {
        switch button {
        case .hidden, .follow:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_FOLLOW", comment: "Feed profile page: button that follows someone.")
        case .requested:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_REQUESTED_BUTTON", comment: "Feed profile page: button shown after asking to follow a private account; tapping withdraws the request.")
        case .following:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_FOLLOWING", comment: "Feed profile page: button shown when already following someone; tapping unfollows.")
        case .unblock:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_UNBLOCK", comment: "Feed profile page: button that unblocks someone.")
        }
    }

    static func confirmationTitle(for confirmation: Confirmation) -> String {
        switch confirmation {
        case .unfollow:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_UNFOLLOW_CONFIRM", comment: "Feed profile page: question before unfollowing someone.")
        case .cancelRequest:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_CANCEL_REQUEST_CONFIRM", comment: "Feed profile page: question before withdrawing a follow request.")
        case .block:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_BLOCK_CONFIRM", comment: "Feed profile page: question before blocking someone.")
        }
    }

    static func confirmationButton(for confirmation: Confirmation) -> String {
        switch confirmation {
        case .unfollow:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_UNFOLLOW", comment: "Feed profile page: confirmation button that unfollows.")
        case .cancelRequest:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_CANCEL_REQUEST", comment: "Feed profile page: confirmation button that withdraws a follow request.")
        case .block:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_BLOCK", comment: "Feed profile page: confirmation button that blocks someone.")
        }
    }

    /// 状态行的标题和说明（`nil` = 不显示）。
    static func statusTexts(for status: FeedProfilePresentation.Status) -> (title: String?, body: String?) {
        switch status {
        case .loading, .loadingMore:
            return (nil, nil)
        case .failed(let seconds):
            return (
                OWSLocalizedString("TELLOMI_FEED_PROFILE_LOAD_FAILED", comment: "Feed profile page: shown when the profile could not be loaded."),
                seconds.map { throttledText($0) },
            )
        case .gone:
            return (
                OWSLocalizedString("TELLOMI_FEED_PROFILE_GONE_TITLE", comment: "Feed profile page: title when the profile cannot be seen (deleted, blocked, or not allowed)."),
                OWSLocalizedString("TELLOMI_FEED_PROFILE_GONE_BODY", comment: "Feed profile page: explanation under 'This profile is not available'."),
            )
        case .empty(let isSelf):
            return (
                OWSLocalizedString("TELLOMI_FEED_PROFILE_EMPTY_TITLE", comment: "Feed profile page: shown when a profile has no posts."),
                isSelf ? OWSLocalizedString("TELLOMI_FEED_PROFILE_EMPTY_SELF_BODY", comment: "Feed profile page: explanation on the user's own empty profile.") : nil,
            )
        case .postsFailed:
            return (OWSLocalizedString("TELLOMI_FEED_PROFILE_POSTS_FAILED", comment: "Feed profile page: shown when the posts could not be loaded."), nil)
        case .loadMoreFailed:
            return (OWSLocalizedString("TELLOMI_FEED_PROFILE_POSTS_FAILED", comment: "Feed profile page: shown when the posts could not be loaded."), nil)
        case .privateLocked:
            return (
                OWSLocalizedString("TELLOMI_FEED_PROFILE_PRIVATE_TITLE", comment: "Feed profile page: title on a private account the user does not follow yet."),
                OWSLocalizedString("TELLOMI_FEED_PROFILE_PRIVATE_BODY", comment: "Feed profile page: explanation on a private account: follow to see posts."),
            )
        case .blocked:
            return (
                OWSLocalizedString("TELLOMI_FEED_PROFILE_BLOCKED_TITLE", comment: "Feed profile page: title when the user has blocked this person."),
                OWSLocalizedString("TELLOMI_FEED_PROFILE_BLOCKED_BODY", comment: "Feed profile page: explanation: unblock to see posts again."),
            )
        case .regionUnavailable:
            return (
                OWSLocalizedString("TELLOMI_FEED_PROFILE_REGION_TITLE", comment: "Feed profile page: title when the person posts in another content region."),
                OWSLocalizedString("TELLOMI_FEED_PROFILE_REGION_BODY", comment: "Feed profile page: explanation: this person's posts are not available here."),
            )
        }
    }

    /// 名字下面那一行：`@handle` 或「Tellomi 号」，再加 IP 属地。
    static func identityLine(_ presentation: FeedProfilePresentation) -> String {
        var parts = [String]()
        switch presentation.identity {
        case .handle(let handle):
            parts.append("@\(handle)")
        case .tellomiNumber(let number):
            parts.append(String(
                format: OWSLocalizedString("TELLOMI_FEED_TELLOMI_NUMBER_FORMAT", comment: "Feed: shown under the name of someone who has not set an ID. Embeds {{the 10-digit Tellomi number}}."),
                number,
            ))
        case .none:
            break
        }
        if let region = presentation.ipRegionLabel {
            parts.append(String(
                format: OWSLocalizedString("TELLOMI_FEED_IP_REGION_FORMAT", comment: "Feed: where the author's IP address is, shown under their name in mainland China. Embeds {{province name}}."),
                region,
            ))
        }
        return parts.joined(separator: " · ")
    }

    static func countsLine(_ presentation: FeedProfilePresentation) -> String {
        let followers = String(
            format: OWSLocalizedString("TELLOMI_FEED_PROFILE_FOLLOWERS_FORMAT", comment: "Feed profile page: follower count. Embeds {{number of followers}}."),
            OWSFormat.formatInt(presentation.followers),
        )
        let following = String(
            format: OWSLocalizedString("TELLOMI_FEED_PROFILE_FOLLOWING_FORMAT", comment: "Feed profile page: how many people this person follows. Embeds {{number}}."),
            OWSFormat.formatInt(presentation.following),
        )
        return "\(followers) · \(following)"
    }
}

// MARK: - Table

extension FeedProfileViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .header:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedProfileHeaderCell.reuseIdentifier, for: indexPath) as! FeedProfileHeaderCell
            cell.configure(presentation, onFollow: { [weak self] in self?.followTapped() })
            return cell
        case .post(let id):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedPostCell.reuseIdentifier, for: indexPath) as! FeedPostCell
            // 主页上的帖子：不放「不感兴趣」（那是信息流里的），赞可以点
            cell.isReadOnly = true
            cell.allowsLikeWhenReadOnly = true
            if let card = presentation.posts.first(where: { $0.id == id }) {
                cell.configure(card: card, showIpRegion: store.state.showIpRegion)
            }
            cell.onLike = { [weak self] card in self?.store.toggleLike(card) }
            return cell
        case .status(let status):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedProfileStatusCell.reuseIdentifier, for: indexPath) as! FeedProfileStatusCell
            cell.configure(status: status) { [weak self] in self?.retry(status) }
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
            store.loadMorePosts()
        }
    }

    private func retry(_ status: FeedProfilePresentation.Status) {
        switch status {
        case .loadMoreFailed:
            store.loadMorePosts()
        default:
            store.refresh()
        }
    }
}

// MARK: - Cells

/// 头部：头像、名字、一行身份、简介、私密标记、粉丝数、关注按钮。
final class FeedProfileHeaderCell: UITableViewCell {
    static let reuseIdentifier = "FeedProfileHeaderCell"

    private let avatarView = FeedAvatarView(size: FeedProfileViewController.avatarSize)
    private let nameLabel = UILabel()
    private let identityLabel = UILabel()
    private let badgeLabel = UILabel()
    private let bioLabel = UILabel()
    private let countsLabel = UILabel()
    /// 单测 / 截图用。
    let followButton = UIButton(type: .system)
    private var onFollow: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear

        nameLabel.font = .dynamicTypeTitle2.semibold()
        nameLabel.textColor = UIColor.Signal.label
        nameLabel.numberOfLines = 0
        nameLabel.textAlignment = .center

        identityLabel.font = .dynamicTypeSubheadline
        identityLabel.textColor = UIColor.Signal.secondaryLabel
        identityLabel.textAlignment = .center
        identityLabel.numberOfLines = 0

        badgeLabel.font = .dynamicTypeFootnote
        badgeLabel.textColor = UIColor.Signal.secondaryLabel
        badgeLabel.textAlignment = .center

        bioLabel.font = .dynamicTypeBody
        bioLabel.textColor = UIColor.Signal.label
        bioLabel.numberOfLines = 0
        bioLabel.textAlignment = .center

        countsLabel.font = .dynamicTypeSubheadline
        countsLabel.textColor = UIColor.Signal.secondaryLabel
        countsLabel.textAlignment = .center
        countsLabel.numberOfLines = 0

        followButton.addAction(UIAction { [weak self] _ in self?.onFollow?() }, for: .touchUpInside)
        // 最大号动态字体时按钮里的字比 40 高：只定最矮，不定死
        followButton.autoSetDimension(.height, toSize: 40, relation: .greaterThanOrEqual)
        followButton.autoSetDimension(.width, toSize: 140, relation: .greaterThanOrEqual)

        let stack = UIStackView(arrangedSubviews: [avatarView, nameLabel, identityLabel, badgeLabel, bioLabel, countsLabel, followButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(12, after: avatarView)
        stack.setCustomSpacing(16, after: countsLabel)
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

    func configure(_ presentation: FeedProfilePresentation, onFollow: @escaping () -> Void) {
        self.onFollow = onFollow
        avatarView.configure(name: presentation.displayName)
        nameLabel.text = presentation.displayName
        let identity = FeedProfileViewController.identityLine(presentation)
        identityLabel.text = identity
        identityLabel.isHidden = identity.isEmpty
        let badge = presentation.isPrivate ? OWSLocalizedString("TELLOMI_FEED_PROFILE_PRIVATE_BADGE", comment: "Feed profile page: label on a private account.") : presentation.badge
        badgeLabel.text = badge
        badgeLabel.isHidden = badge == nil
        bioLabel.text = presentation.bio
        bioLabel.isHidden = presentation.bio == nil
        countsLabel.text = FeedProfileViewController.countsLine(presentation)

        followButton.isHidden = presentation.followButton == .hidden
        var configuration = presentation.followButton == .follow ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
        configuration.title = FeedProfileViewController.followTitle(for: presentation.followButton)
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24)
        followButton.configuration = configuration
        followButton.isEnabled = presentation.isFollowEnabled
    }
}

/// 没有帖子时的状态行：转圈、标题 + 说明、「重试」。
final class FeedProfileStatusCell: UITableViewCell {
    static let reuseIdentifier = "FeedProfileStatusCell"

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

    func configure(status: FeedProfilePresentation.Status, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        let texts = FeedProfileViewController.statusTexts(for: status)
        let spins = status == .loading || status == .loadingMore
        if spins { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !spins
        titleLabel.text = texts.title
        titleLabel.isHidden = texts.title == nil
        bodyLabel.text = texts.body
        bodyLabel.isHidden = texts.body == nil
        switch status {
        case .failed, .postsFailed, .loadMoreFailed:
            retryButton.isHidden = false
        default:
            retryButton.isHidden = true
        }
    }
}
