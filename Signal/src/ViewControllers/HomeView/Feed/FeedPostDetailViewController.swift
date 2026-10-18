//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 帖子详情（`dynamic-feed.md` 第三节第 2、4 条）：整条帖子在最上面，下面是评论（按楼排，楼里的回复缩进）。
/// 在信息流里点一条帖子打开（`FeedViewController.openPost`）。数据在 `FeedPostDetailStore`，画什么由 `FeedPostDetailPresentation` 决定。
///
/// 帖子上的点赞可以点（乐观更新、失败改回，数据在列表共用的 `FeedStore` 里），「···」不显示（`FeedPostCell.isReadOnly`）；评论区有「加载中 / 加载失败（重试）/ 还没有评论」，
/// 帖子已经看不到了显示「已不可见」。底部是评论输入框（`FeedCommentInputView`，评论关了就收起），点一条评论回复它。
/// 转发、收藏、语音评论等随后面的步骤接。
final class FeedPostDetailViewController: OWSViewController {

    /// 离评论列表底部还剩几行时取下一页。
    static let loadMoreThreshold = 3

    private enum Row: Equatable {
        case post
        case comment(FeedPostDetailPresentation.CommentRow)
        case status(FeedPostDetailPresentation.CommentsPhase)
    }

    private let store: FeedPostDetailStore
    private let fallbackShowIpRegion: Bool
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let footerSpinner = UIActivityIndicatorView(style: .medium)
    /// 底部的评论输入框（评论关了就收起）。
    let commentInput = FeedCommentInputView()
    private lazy var goneView = FeedEmptyStateView(
        title: OWSLocalizedString("TELLOMI_FEED_DETAIL_GONE_TITLE", comment: "Feed: title of the post page when the post was deleted or can no longer be seen."),
        body: OWSLocalizedString("TELLOMI_FEED_DETAIL_GONE_BODY", comment: "Feed: explanation under the title when the post can no longer be seen."),
    )

    /// 举报页接上之后设置（参数是被举报的评论，nil = 举报帖子）；nil 时菜单里不显示「举报」（免得点了没反应）。
    var onReport: ((FeedCard?) -> Void)?
    /// 删除前的确认；nil = 用自带的确认弹窗。单测 / 截图里换掉，免得弹真的弹窗。
    var confirmDestructive: ((FeedDetailMenuItem, @escaping () -> Void) -> Void)?
    /// 导航栏「···」现在放的几项（没变就不重建菜单）。
    private(set) var shownPostMenu = [FeedDetailMenuItem]()

    private var rows = [Row]()
    private var post: FeedCard
    private var showIpRegion: Bool

    /// - Parameters:
    ///   - post: 信息流里带过来的那张卡片，先用它画出来，再向 Card API 取最新的。
    ///   - showIpRegion: 信息流里是不是显示 IP 属地；详情拿到自己的配置后以配置为准。
    ///   - feed: 信息流的 `FeedStore`。传了就和列表共用它（卡片只在它里面，详情自己不留副本，赞和评论数改在它里面，列表同步）；
    ///     不传就自己独立运行（单测、还没接上的入口）。
    init(post: FeedCard, source: FeedSource, showIpRegion: Bool, feed: FeedStore? = nil) {
        self.post = post
        self.showIpRegion = showIpRegion
        fallbackShowIpRegion = showIpRegion
        store = FeedPostDetailStore(initial: post, source: source, feed: feed)
        super.init()
        // 和 Telegram 一样：推进去以后底栏收起来
        hidesBottomBarWhenPushed = true
        title = OWSLocalizedString("TELLOMI_FEED_DETAIL_TITLE", comment: "Feed: title of the page that shows one post and its comments.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.Signal.background
        navigationItem.largeTitleDisplayMode = .never

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(FeedPostCell.self, forCellReuseIdentifier: FeedPostCell.reuseIdentifier)
        tableView.register(FeedCommentCell.self, forCellReuseIdentifier: FeedCommentCell.reuseIdentifier)
        tableView.register(FeedDetailStatusCell.self, forCellReuseIdentifier: FeedDetailStatusCell.reuseIdentifier)
        tableView.keyboardDismissMode = .interactive
        tableView.setContentHuggingPriority(.defaultLow, for: .vertical)

        // 表格在上、评论输入框在下，整体贴着键盘（评论输入框收起时不占位）
        let contentStack = UIStackView(arrangedSubviews: [tableView, commentInput])
        contentStack.axis = .vertical
        view.addSubview(contentStack)
        contentStack.autoPinEdge(toSuperviewEdge: .top)
        contentStack.autoPinEdge(toSuperviewEdge: .leading)
        contentStack.autoPinEdge(toSuperviewEdge: .trailing)
        contentStack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true

        commentInput.onEdit = { [weak self] range, text, composing in
            self?.store.onDraftEdit(range: range, replacement: text, composing: composing)
        }
        commentInput.onChanged = { [weak self] text, composing in
            self?.store.onDraftChanged(text, composing: composing)
        }
        commentInput.onSend = { [weak self] in self?.store.send() }
        commentInput.onCancelReply = { [weak self] in self?.store.replyTo(nil) }

        goneView.isHidden = true
        view.addSubview(goneView)
        goneView.autoPinEdgesToSuperviewEdges()

        footerSpinner.frame = CGRect(x: 0, y: 0, width: 0, height: 56)

        store.onChange = { [weak self] state in
            self?.apply(state)
        }
        apply(store.state)
        store.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 弹出 / 关闭：不再订阅列表的 store、放掉借着的卡片（盖上别的页面再回来不算离开）
        if isMovingFromParent || isBeingDismissed {
            store.detach()
        }
    }

    /// 单测 / 截图用：页面背后的 store。
    var detailStore: FeedPostDetailStore {
        return store
    }

    /// 单测 / 截图用：帖子那一行的格子（不在屏幕上时是 nil）。
    var postCell: FeedPostCell? {
        return tableView.visibleCells.compactMap { $0 as? FeedPostCell }.first
    }

    /// 单测 / 截图用：现在的表格。
    var detailTableView: UITableView {
        return tableView
    }

    /// 把 `store` 的状态画出来。
    private func apply(_ state: FeedPostDetailState) {
        guard isViewLoaded else { return }

        switch FeedPostDetailPresentation.page(for: state) {
        case .postGone:
            tableView.isHidden = true
            commentInput.isHidden = true
            goneView.isHidden = false
            updateNavigationMenu(items: [])
            return
        case .post:
            tableView.isHidden = false
            goneView.isHidden = true
        }
        commentInput.apply(FeedCommentInputPresentation(state: state), draft: state.draft)

        post = state.post
        showIpRegion = state.showIpRegion || fallbackShowIpRegion
        updateNavigationMenu(items: FeedDetailMenu.shown(state.postMenu, reportAvailable: onReport != nil))
        closeIfFinished(state)

        var newRows: [Row] = [.post]
        let phase = FeedPostDetailPresentation.commentsPhase(for: state)
        if phase == .content {
            newRows += FeedPostDetailPresentation.commentRows(for: state).map { Row.comment($0) }
        } else {
            newRows.append(.status(phase))
        }
        if newRows == rows {
            // 行没变（只是帖子上的赞、评论数变了）：就地更新帖子那一格，不整表重载（不闪、不丢滚动位置）
            for case let cell as FeedPostCell in tableView.visibleCells {
                cell.configure(card: post, showIpRegion: showIpRegion)
            }
        } else {
            rows = newRows
            tableView.reloadData()
        }

        if FeedPostDetailPresentation.hasMoreComments(for: state) {
            footerSpinner.startAnimating()
            tableView.tableFooterView = footerSpinner
        } else {
            footerSpinner.stopAnimating()
            tableView.tableFooterView = nil
        }

        if state.notice != nil {
            // `apply` 是 store 改 `state` 的 didSet 里调进来的：提示在下一轮主线程里显示并清掉，不在 didSet 里再改 store
            DispatchQueue.main.async { [weak self] in
                self?.consumeNotice()
            }
        }
    }

    // MARK: - 「···」菜单

    /// 导航栏右上角的「···」：别人的帖子是「不感兴趣」「举报」，自己的帖子是「删除」。没有可放的项就不显示按钮。
    private func updateNavigationMenu(items: [FeedDetailMenuItem]) {
        guard items != shownPostMenu else { return }
        shownPostMenu = items
        guard !items.isEmpty else {
            navigationItem.rightBarButtonItem = nil
            return
        }
        let button = UIBarButtonItem.contextMenuButton(actions: items.map { menuAction($0, comment: nil) })
        button.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_MORE", comment: "Feed: accessibility label for the ··· button on a post.")
        navigationItem.rightBarButtonItem = button
    }

    private func menuAction(_ item: FeedDetailMenuItem, comment: FeedCard?) -> UIAction {
        return UIAction(title: Self.menuTitle(for: item), attributes: item.isDestructive ? .destructive : []) { [weak self] _ in
            self?.handleMenuItem(item, comment: comment)
        }
    }

    /// 一条评论的「···」里放哪几项（长按评论弹出；没有项就不弹）。
    func commentMenuItems(for comment: FeedCard) -> [FeedDetailMenuItem] {
        return FeedDetailMenu.shown(FeedDetailMenu.items(forComment: comment), reportAvailable: onReport != nil)
    }

    /// 点了菜单里的一项（`comment` 是 nil = 帖子本身）。删除先确认，确认了才调 store。单测 / 截图直接调它。
    func handleMenuItem(_ item: FeedDetailMenuItem, comment: FeedCard? = nil) {
        switch item {
        case .notInterested:
            store.notInterested()
        case .report:
            onReport?(comment)
        case .deleteComment:
            guard let comment else { return }
            confirm(item) { [weak self] in self?.store.deleteComment(comment) }
        case .deletePost:
            confirm(item) { [weak self] in self?.store.deletePost() }
        case .own:
            break
        }
    }

    private func confirm(_ item: FeedDetailMenuItem, proceed: @escaping () -> Void) {
        if let confirmDestructive {
            confirmDestructive(item, proceed)
            return
        }
        OWSActionSheets.showConfirmationAlert(
            title: Self.confirmationTitle(for: item),
            proceedTitle: CommonStrings.deleteButton,
            proceedStyle: .destructive,
            proceedAction: { _ in proceed() },
            fromViewController: self,
        )
    }

    static func menuTitle(for item: FeedDetailMenuItem) -> String {
        switch item {
        case .notInterested:
            return OWSLocalizedString("TELLOMI_FEED_NOT_INTERESTED", comment: "Feed: ··· menu item that hides a post and tells the recommender to show fewer like it.")
        case .report:
            return OWSLocalizedString("TELLOMI_FEED_MENU_REPORT", comment: "Feed: ··· menu item that reports a post or a comment.")
        case .deleteComment:
            return OWSLocalizedString("TELLOMI_FEED_MENU_DELETE_COMMENT", comment: "Feed: ··· menu item that deletes the user's own comment.")
        case .deletePost:
            return OWSLocalizedString("TELLOMI_FEED_MENU_DELETE_POST", comment: "Feed: ··· menu item that deletes the user's own post.")
        case .own:
            return ""
        }
    }

    static func confirmationTitle(for item: FeedDetailMenuItem) -> String {
        switch item {
        case .deleteComment:
            return OWSLocalizedString("TELLOMI_FEED_DELETE_COMMENT_CONFIRM", comment: "Feed: confirmation question before deleting the user's own comment.")
        case .deletePost:
            return OWSLocalizedString("TELLOMI_FEED_DELETE_POST_CONFIRM", comment: "Feed: confirmation question before deleting the user's own post.")
        case .notInterested, .report, .own:
            return ""
        }
    }

    // MARK: - 做完就关页

    /// 页面为什么关的（单测 / 截图用）。
    enum CloseReason: Equatable {
        /// 「不感兴趣」成了：列表那一行已经换成可撤销的反馈卡。
        case notInterested
        /// 自己的帖子删掉了：列表里已经去掉。
        case deleted
        /// 引擎说这个区域的动态关了（404 `feed_hidden`）。
        case feedHidden
    }

    private(set) var closeReason: CloseReason?

    /// 不感兴趣 / 删帖成了、或动态被关了：关掉这一页（只关一次）。`apply` 是 store 改 `state` 的 didSet 里调进来的，所以放到下一轮主线程里再弹出。
    private func closeIfFinished(_ state: FeedPostDetailState) {
        guard closeReason == nil else { return }
        let reason: CloseReason
        if state.leaving != nil {
            reason = .notInterested
        } else if state.deleted {
            reason = .deleted
        } else if state.feedHidden {
            reason = .feedHidden
        } else {
            return
        }
        closeReason = reason
        DispatchQueue.main.async { [weak self] in
            guard let self, let navigationController = self.navigationController else { return }
            if navigationController.topViewController === self {
                navigationController.popViewController(animated: true)
            } else {
                // 上面盖着别的页面（比如举报页）：把自己从栈里拿掉，不动上面那页
                navigationController.viewControllers.removeAll { $0 === self }
            }
        }
    }

    /// 最近一次弹出的提示文字（单测 / 截图用）。
    private(set) var lastToastText: String?

    /// store 里的一次性提示（`notice`）：有对应文案就弹一句，然后清掉。点赞失败（已经改回）用列表同一句「操作失败」。
    private func consumeNotice() {
        guard let notice = store.state.notice else { return }
        if let text = Self.toastText(for: notice, retryAfterSeconds: store.state.retryAfterSeconds) {
            lastToastText = text
            let placement = Self.toastPlacement(inputVisible: !commentInput.isHidden, keyboardUp: commentInput.textView.isFirstResponder)
            lastToastPlacement = placement
            if viewIfLoaded?.window != nil {
                presentDetailToast(text: text, placement: placement)
            }
        }
        store.onNoticeShown()
    }

    /// 提示条放哪儿：不能盖住评论输入框（占位文字、发送键）。
    enum ToastPlacement: Equatable {
        /// 输入框收起了：和别的页面一样贴着底部。
        case bottom
        /// 贴着底部、再往上抬一个输入框的高度（键盘没出来时）。
        case aboveInput
        /// 键盘出来了：`ToastController` 会把提示条贴到键盘上沿，正好是输入框的位置，所以改放到导航栏下面。
        case top
    }

    static func toastPlacement(inputVisible: Bool, keyboardUp: Bool) -> ToastPlacement {
        guard inputVisible else { return .bottom }
        return keyboardUp ? .top : .aboveInput
    }

    /// 最近一次提示条的位置（单测 / 截图用）。
    private(set) var lastToastPlacement: ToastPlacement?

    private func presentDetailToast(text: String, placement: ToastPlacement) {
        switch placement {
        case .bottom:
            presentToast(text: text)
        case .aboveInput:
            presentToast(text: text, extraVInset: commentInput.bounds.size.height)
        case .top:
            let controller = ToastController(text: text, image: nil)
            controller.presentToastView(from: .top, of: view, inset: view.safeAreaInsets.top + 8)
        }
    }

    static func toastText(for notice: FeedPostDetailState.Notice, retryAfterSeconds: Int? = nil) -> String? {
        switch notice {
        case .commentDeleted:
            return OWSLocalizedString("TELLOMI_FEED_COMMENT_DELETED", comment: "Feed: toast after the user deleted their own comment.")
        case .reported:
            return OWSLocalizedString("TELLOMI_FEED_REPORT_SENT", comment: "Feed: toast after a report was submitted.")
        case .throttled:
            if let seconds = retryAfterSeconds {
                return String(
                    format: OWSLocalizedString("TELLOMI_FEED_THROTTLED_FORMAT", comment: "Feed: toast when the server says to slow down. Embeds {{the number of seconds to wait}}."),
                    OWSFormat.formatInt(seconds),
                )
            }
            return OWSLocalizedString("TELLOMI_FEED_THROTTLED", comment: "Feed: toast when the server says to slow down and gives no time.")
        case .hideProfileRequired:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_REQUIRED", comment: "Feed: toast when an action needs the user to set up their public profile first.")
        case .failed:
            // 点赞失败（已改回）、发评论失败（文字还留在输入框里）都用列表那句「操作失败」
            return OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed.")
        case .published:
            return OWSLocalizedString("TELLOMI_FEED_COMPOSE_PUBLISHED", comment: "Feed: toast after the post was published.")
        case .pending:
            return OWSLocalizedString("TELLOMI_FEED_COMPOSE_PENDING", comment: "Feed: toast after publishing when the post waits for review before others can see it.")
        case .closed:
            return OWSLocalizedString("TELLOMI_FEED_COMMENT_CLOSED", comment: "Feed: toast when sending a comment failed because the author turned comments off for this post.")
        case .replyNotAllowed:
            return OWSLocalizedString("TELLOMI_FEED_COMMENT_REPLY_NOT_ALLOWED", comment: "Feed: toast when replying to a comment is not allowed.")
        case .profileRequired:
            return OWSLocalizedString("TELLOMI_FEED_COMMENT_PROFILE_REQUIRED", comment: "Feed: toast when commenting needs the user to set up their public profile first.")
        case .parentGone:
            return OWSLocalizedString("TELLOMI_FEED_COMMENT_PARENT_GONE", comment: "Feed: toast when the comment being replied to no longer exists.")
        default:
            return nil
        }
    }
}

extension FeedPostDetailViewController: UITableViewDataSource, UITableViewDelegate {
    /// 长按一条评论：自己的评论「删除」，别人的「举报」（举报页接上之后）。
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard rows.indices.contains(indexPath.row), case .comment(let row) = rows[indexPath.row] else { return nil }
        let comment = row.comment
        let items = commentMenuItems(for: comment)
        guard !items.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: items.map { self.menuAction($0, comment: comment) })
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .post:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedPostCell.reuseIdentifier, for: indexPath) as! FeedPostCell
            cell.isReadOnly = true
            cell.allowsLikeWhenReadOnly = true
            cell.onLike = { [weak self] _ in self?.store.toggleLike() }
            cell.configure(card: post, showIpRegion: showIpRegion)
            return cell
        case .comment(let row):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedCommentCell.reuseIdentifier, for: indexPath) as! FeedCommentCell
            cell.configure(row: row)
            return cell
        case .status(let phase):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedDetailStatusCell.reuseIdentifier, for: indexPath) as! FeedDetailStatusCell
            cell.configure(phase: phase) { [weak self] in
                self?.store.refreshComments()
            }
            return cell
        }
    }

    /// 点一条评论：回复它（输入框上面出现「正在回复 xxx」，光标进输入框）。评论关了不响应。
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard store.state.canComment, case .comment(let row) = rows[indexPath.row] else { return }
        store.replyTo(row.comment)
        commentInput.focus()
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if cell is FeedCommentCell, indexPath.row >= rows.count - Self.loadMoreThreshold {
            store.loadMoreComments()
        }
    }
}

/// 评论区还没有评论时占一行：加载中转圈；加载失败「加载失败」+「重试」；没有评论「还没有评论」。
private final class FeedDetailStatusCell: UITableViewCell {
    static let reuseIdentifier = "FeedDetailStatusCell"

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let retryButton = UIButton(type: .system)
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
        stack.autoPinEdge(toSuperviewEdge: .top, withInset: 40)
        stack.autoPinEdge(toSuperviewEdge: .bottom, withInset: 40)
        stack.autoPinEdge(toSuperviewEdge: .leading, withInset: 40)
        stack.autoPinEdge(toSuperviewEdge: .trailing, withInset: 40)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(phase: FeedPostDetailPresentation.CommentsPhase, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        switch phase {
        case .loading, .content:
            // `.content` 不会来到这里（有评论就画评论）；万一来了就当加载中，不显示文字
            spinner.isHidden = false
            spinner.startAnimating()
            titleLabel.isHidden = true
            bodyLabel.isHidden = true
            retryButton.isHidden = true
        case .failed:
            spinner.stopAnimating()
            spinner.isHidden = true
            titleLabel.text = OWSLocalizedString("TELLOMI_FEED_COMMENTS_LOAD_FAILED", comment: "Feed: shown under a post when its comments could not be loaded.")
            titleLabel.isHidden = false
            bodyLabel.isHidden = true
            retryButton.isHidden = false
        case .empty:
            spinner.stopAnimating()
            spinner.isHidden = true
            titleLabel.text = OWSLocalizedString("TELLOMI_FEED_COMMENTS_EMPTY_TITLE", comment: "Feed: shown under a post that has no comments yet.")
            titleLabel.isHidden = false
            bodyLabel.text = OWSLocalizedString("TELLOMI_FEED_COMMENTS_EMPTY_BODY", comment: "Feed: explanation under 'No comments yet'.")
            bodyLabel.isHidden = false
            retryButton.isHidden = true
        }
    }
}
