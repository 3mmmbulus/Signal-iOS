//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 「我的动态」页（`dynamic-feed.md` 第三节第 24 条）：自己发过的帖子和文章（含评论），每条有审核状态（审核中 / 已发布 / 未通过 / 已撤回）和可见范围，
/// 可以删除（左滑，先确认）、对未通过的申诉（每条一次；已撤回的引擎当前不收申诉，没有按钮）、点开已发布的看详情。
/// 逻辑在 `FeedMyPostsStore`，画什么在 `FeedMyPostsPresentation`；和信息流共用同一个 `FeedStore`：删掉的帖子信息流里同时去掉，点开时详情页拿到的就是信息流里现在的样子。
///
/// 默认不接到任何入口（见 `TellomiFeed.isMyPostsEnabled`），不影响现有页面。
/// 「发布页扩展」（`TellomiFeed.isComposeExtrasEnabled`）打开时：发布后 15 分钟内的帖子左滑多一个「编辑」（进发布页的编辑模式），
/// 本机有没写完的长文时页面顶上多一行「继续写」。
final class FeedMyPostsViewController: OWSViewController {
    /// 未成年人时限的提示页（时限关着时是 nil）。
    private(set) var minorLock: FeedMinorLockController?

    let store: FeedMyPostsStore
    let postsTableView = UITableView(frame: .zero, style: .plain)

    private let source: FeedSource
    private let feed: FeedStore?
    private let refreshControl = UIRefreshControl()
    private let composeExtras: Bool
    private let listsEnabled: Bool
    private let articleDrafts: FeedArticleDrafts?
    private let draftHeader = FeedDraftEntryHeader()
    private var draftEntry: FeedComposeDraftEntry?

    private(set) var presentation: FeedMyPostsPresentation
    private(set) var rows = [FeedMyPostsPresentation.Row]()
    /// 最近一次弹出的提示文字（单测 / 截图用）。
    private(set) var lastToastText: String?
    /// 最近一次弹出的确认 / 申诉对话框（单测 / 截图用）。
    private(set) var lastAlert: UIAlertController?
    /// 页面已经（因为 `feed_hidden`）收起过（单测 / 截图用）。
    private(set) var didClose = false

    /// 默认推帖子详情（换好的卡片）。
    var onOpenPost: ((FeedCard) -> Void)?
    /// 详情里点作者；不设就不响应（作者主页入口没开）。
    var onOpenAuthor: ((FeedAuthor) -> Void)?
    /// 详情里点 `#话题`；不设就不响应。
    var onOpenTopic: ((FeedTopic) -> Void)?

    init(
        source: FeedSource,
        feed: FeedStore?,
        composeExtras: Bool = TellomiFeed.isComposeExtrasEnabled,
        articleDrafts: FeedArticleDrafts? = nil,
        listsEnabled: Bool = TellomiFeed.isListsEnabled,
    ) {
        self.source = source
        self.feed = feed
        self.composeExtras = composeExtras
        self.listsEnabled = listsEnabled
        self.articleDrafts = composeExtras ? (articleDrafts ?? StoredFeedArticleDrafts(storage: FeedLocalStorages.backupExcluded)) : nil
        self.store = FeedMyPostsStore(source: source, feed: feed)
        self.presentation = FeedMyPostsPresentation(state: store.state)
        super.init()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.title = Self.title
        hidesBottomBarWhenPushed = true
        if listsEnabled {
            let button = UIBarButtonItem(image: UIImage(systemName: "person.2"), primaryAction: UIAction { [weak self] _ in self?.openLists() })
            button.accessibilityLabel = FeedListsViewController.title
            navigationItem.rightBarButtonItem = button
        }
    }

    /// 点右上角的名单按钮：推名单入口页（单测 / 截图直接调它）。
    func openLists() {
        guard listsEnabled else { return }
        navigationController?.pushViewController(FeedListsViewController(source: source), animated: true)
    }

    static var title: String {
        return OWSLocalizedString("TELLOMI_FEED_MINE_TITLE", comment: "Feed my posts page: title.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tellomiApplyFeedPreviewPrompt()
        view.backgroundColor = UIColor.Signal.background

        postsTableView.backgroundColor = .clear
        postsTableView.separatorStyle = .singleLine
        postsTableView.rowHeight = UITableView.automaticDimension
        postsTableView.estimatedRowHeight = 120
        postsTableView.dataSource = self
        postsTableView.delegate = self
        postsTableView.register(FeedMyPostCell.self, forCellReuseIdentifier: FeedMyPostCell.reuseIdentifier)
        postsTableView.register(FeedStatusRowCell.self, forCellReuseIdentifier: FeedStatusRowCell.reuseIdentifier)
        view.addSubview(postsTableView)
        FeedReadableWidth.pin(postsTableView, in: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.store.refresh() }, for: .valueChanged)
        postsTableView.refreshControl = refreshControl

        draftHeader.onTap = { [weak self] in self?.continueDraft() }

        store.onChange = { [weak self] state in self?.apply(state) }
        apply(store.state)
        store.start()

        // 未成年人时限（I-15）：和动态标签过同一个检查（`FeedMinorSession`），锁着时盖上提示页。放最后，盖在所有东西上面
        minorLock = FeedMinorLockController.install(in: self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDraftHeader()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从详情页回来：那边删了帖子，这里的行也要去掉
        store.syncWithFeed()
        refreshDraftEntry()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 被弹出了：不再订阅信息流、放掉借着的卡片（盖了别的页面不算）
        if isMovingFromParent || isBeingDismissed || navigationController == nil { store.detach() }
    }

    // MARK: - Rendering

    private func apply(_ state: FeedMyPostsState) {
        let next = FeedMyPostsPresentation(state: state)
        presentation = next
        guard isViewLoaded else { return }

        if next.rows != rows {
            rows = next.rows
            postsTableView.reloadData()
        }
        if !state.loading, refreshControl.isRefreshing { refreshControl.endRefreshing() }

        if state.notice != nil || state.appealNotice != nil || state.editNotice != nil {
            // `apply` 是 store 改 `state` 的 didSet 里调进来的：提示在下一轮主线程里显示并清掉
            DispatchQueue.main.async { [weak self] in self?.consumeNotices() }
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

    /// 点一行（单测 / 截图直接调它）：已发布的帖子 / 文章推详情，别的不响应。
    func open(_ row: FeedMyPostRow) {
        guard row.canOpen, let post = store.state.posts.first(where: { $0.id == row.id }) else { return }
        store.openPost(post)
    }

    /// 删除：先问一句（评论、点赞、投票会一起删），确认后才发请求（单测 / 截图直接调它）。
    func confirmDelete(_ row: FeedMyPostRow) {
        guard row.canDelete, store.state.posts.contains(where: { $0.id == row.id }) else { return }
        let alert = UIAlertController(
            title: OWSLocalizedString("TELLOMI_FEED_MINE_DELETE_TITLE", comment: "Feed my posts page: title of the confirmation before deleting one of your posts."),
            message: OWSLocalizedString("TELLOMI_FEED_MINE_DELETE_BODY", comment: "Feed my posts page: explains that comments, likes and votes are deleted too and it can't be undone."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: CommonStrings.cancelButton, style: .cancel))
        alert.addAction(UIAlertAction(title: Self.deleteTitle, style: .destructive) { [weak self] _ in
            self?.deleteConfirmed(row)
        })
        lastAlert = alert
        present(alert, animated: true)
    }

    /// 确认框里点了「删除」（单测直接调它）。
    func deleteConfirmed(_ row: FeedMyPostRow) {
        guard let post = store.state.posts.first(where: { $0.id == row.id }) else { return }
        store.delete(post)
    }

    /// 申诉：一个输入理由的对话框（最多 500 个字，多的 store 里按码点截掉）；只给「未通过且能申诉」的（单测 / 截图直接调它）。
    /// 编辑（单测 / 截图直接调它）：扩展开着、没被拒 / 撤回、在窗口内的帖子进发布页的编辑模式；保存后重新拉列表。
    func edit(_ row: FeedMyPostRow, now: Date = Date()) {
        guard composeExtras, row.canEdit(now: now, windowSeconds: store.state.editWindowSeconds), let target = row.editTarget else { return }
        let compose = FeedComposeViewController.make(source: source, editTarget: target) { [weak self] state in
            self?.store.onEdited(publishState: state)
        }
        let navigationController = OWSNavigationController(rootViewController: compose)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true)
    }

    /// 草稿入口：发布页打开时自己会把本机的长文接回来。
    func continueDraft() {
        guard composeExtras else { return }
        let compose = FeedComposeViewController.make(source: source) { [weak self] state in
            guard let self else { return }
            let text = state == FeedCreatePostResponse.statePending
                ? OWSLocalizedString("TELLOMI_FEED_COMPOSE_PENDING", comment: "Feed: toast after publishing when the post waits for review before others can see it.")
                : OWSLocalizedString("TELLOMI_FEED_COMPOSE_PUBLISHED", comment: "Feed: toast after the post was published.")
            self.lastToastText = text
            self.presentToast(text: text)
            self.feed?.onPublished()
            self.store.refresh()
            self.refreshDraftEntry()
        }
        let navigationController = OWSNavigationController(rootViewController: compose)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true)
    }

    /// 本机有没写完的长文就在列表顶上放一行；没有（或扩展关着）就收起。
    func refreshDraftEntry() {
        draftEntry = composeExtras ? FeedComposeDraftEntry.make(articleDrafts?.load()) : nil
        guard isViewLoaded else { return }
        if let draftEntry {
            draftHeader.configure(draftEntry)
            if postsTableView.tableHeaderView !== draftHeader { postsTableView.tableHeaderView = draftHeader }
            layoutDraftHeader()
        } else {
            postsTableView.tableHeaderView = nil
        }
    }

    private func layoutDraftHeader() {
        guard postsTableView.tableHeaderView === draftHeader, postsTableView.bounds.width > 0 else { return }
        let size = draftHeader.systemLayoutSizeFitting(
            CGSize(width: postsTableView.bounds.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        )
        if draftHeader.frame.size.width != postsTableView.bounds.width || draftHeader.frame.size.height != size.height {
            draftHeader.frame = CGRect(x: 0, y: 0, width: postsTableView.bounds.width, height: size.height)
            postsTableView.tableHeaderView = draftHeader
        }
    }

    func presentAppeal(_ row: FeedMyPostRow) {
        guard row.canAppeal, !presentation.appealBusy, store.state.posts.contains(where: { $0.id == row.id }) else { return }
        let alert = UIAlertController(
            title: OWSLocalizedString("TELLOMI_FEED_MINE_APPEAL_TITLE", comment: "Feed my posts page: title of the appeal dialog."),
            message: OWSLocalizedString("TELLOMI_FEED_MINE_APPEAL_BODY", comment: "Feed my posts page: explains that you can appeal once, a person reviews it and the post stays hidden until then."),
            preferredStyle: .alert,
        )
        alert.addTextField { field in
            field.placeholder = OWSLocalizedString("TELLOMI_FEED_MINE_APPEAL_HINT", comment: "Feed my posts page: placeholder of the appeal reason field.")
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: CommonStrings.cancelButton, style: .cancel))
        alert.addAction(UIAlertAction(title: OWSLocalizedString("TELLOMI_FEED_MINE_APPEAL_SEND", comment: "Feed my posts page: button that sends the appeal."), style: .default) { [weak self, weak alert] _ in
            self?.appealSubmitted(row, text: alert?.textFields?.first?.text ?? "")
        })
        lastAlert = alert
        present(alert, animated: true)
    }

    /// 申诉框里点了「提交申诉」（单测直接调它）。
    func appealSubmitted(_ row: FeedMyPostRow, text: String) {
        guard let post = store.state.posts.first(where: { $0.id == row.id }) else { return }
        store.appeal(post, text: text)
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

    private func consumeNotices() {
        var text: String?
        if let notice = store.state.notice {
            text = Self.toastText(for: notice)
            store.onNoticeShown()
        }
        if let result = store.state.appealNotice {
            text = Self.toastText(for: result)
            store.onAppealNoticeShown()
        }
        if let published = store.state.editNotice {
            text = Self.editToastText(publishState: published)
            store.onEditNoticeShown()
        }
        guard let text else { return }
        lastToastText = text
        if viewIfLoaded?.window != nil { presentToast(text: text) }
    }

    // MARK: - Texts

    static var deleteTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_MINE_DELETE", comment: "Feed my posts page: swipe action / button that deletes one of your posts.")
    }

    static var appealTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_MINE_APPEAL", comment: "Feed my posts page: button that opens the appeal dialog for a post that wasn't approved.")
    }

    static var editTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_MINE_EDIT", comment: "Feed my posts page: swipe action that edits a post published a few minutes ago.")
    }

    /// 编辑保存之后：大陆区要重新审核（`pending`），审核通过前别人看到的还是旧的。
    static func editToastText(publishState: String) -> String {
        if publishState == FeedCreatePostResponse.statePending {
            return OWSLocalizedString("TELLOMI_FEED_MINE_EDIT_SAVED_PENDING", comment: "Feed my posts page: toast after saving an edit that has to be reviewed before others see the change.")
        }
        return OWSLocalizedString("TELLOMI_FEED_MINE_EDIT_SAVED", comment: "Feed my posts page: toast after saving an edit.")
    }

    static func toastText(for notice: FeedMyPostsNotice) -> String {
        switch notice {
        case .deleteFailed:
            return OWSLocalizedString("TELLOMI_FEED_MINE_DELETE_FAILED", comment: "Feed my posts page: toast when deleting a post failed.")
        case .postGone:
            return OWSLocalizedString("TELLOMI_FEED_MINE_POST_GONE", comment: "Feed my posts page: toast when the post can't be shown anymore.")
        case .throttled(let seconds):
            return FeedProfileViewController.throttledText(seconds)
        case .failed:
            return OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed.")
        }
    }

    static func toastText(for result: FeedAppealResult) -> String {
        switch result {
        case .sent:
            return OWSLocalizedString("TELLOMI_FEED_MINE_APPEAL_SENT", comment: "Feed my posts page: toast after the appeal was sent.")
        case .already:
            return OWSLocalizedString("TELLOMI_FEED_MINE_APPEAL_ALREADY", comment: "Feed my posts page: toast when the post was already appealed.")
        case .notRejected:
            return OWSLocalizedString("TELLOMI_FEED_MINE_APPEAL_NOT_REJECTED", comment: "Feed my posts page: toast when the post isn't in a state that can be appealed anymore.")
        case .throttled(let seconds):
            return FeedProfileViewController.throttledText(seconds)
        case .failed:
            return OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed.")
        }
    }

    static func statusTitle(_ status: FeedMyPostStatus) -> String {
        switch status {
        case .pending:
            return OWSLocalizedString("TELLOMI_FEED_MINE_STATE_PENDING", comment: "Feed my posts page: status chip, the post is waiting for review.")
        case .rejected:
            return OWSLocalizedString("TELLOMI_FEED_MINE_STATE_REJECTED", comment: "Feed my posts page: status chip, the post wasn't approved.")
        case .withdrawn:
            return OWSLocalizedString("TELLOMI_FEED_MINE_STATE_WITHDRAWN", comment: "Feed my posts page: status chip, the post was removed.")
        case .published:
            return OWSLocalizedString("TELLOMI_FEED_MINE_STATE_PUBLISHED", comment: "Feed my posts page: status chip, the post is published.")
        }
    }

    static func reasonText(_ reason: FeedRejectionReason) -> String {
        switch reason {
        case .prohibitedWords:
            return OWSLocalizedString("TELLOMI_FEED_MINE_REASON_WORDING", comment: "Feed my posts page: reason a post wasn't approved, completes 'Not approved: …'.")
        case .reviewUnavailable:
            return OWSLocalizedString("TELLOMI_FEED_MINE_REASON_REVIEW_UNAVAILABLE", comment: "Feed my posts page: reason a post wasn't approved, completes 'Not approved: …'.")
        case .accountRestricted:
            return OWSLocalizedString("TELLOMI_FEED_MINE_REASON_ACCOUNT", comment: "Feed my posts page: reason a post wasn't approved, completes 'Not approved: …'.")
        case .communityGuidelines:
            return OWSLocalizedString("TELLOMI_FEED_MINE_REASON_GUIDELINES", comment: "Feed my posts page: reason a post wasn't approved, completes 'Not approved: …'.")
        }
    }

    /// 一行下面的说明文字；`isError` = 红色（未通过）。
    static func noteText(_ note: FeedMyPostNote) -> (text: String, isError: Bool) {
        switch note {
        case .pendingHint:
            return (OWSLocalizedString("TELLOMI_FEED_MINE_PENDING_HINT", comment: "Feed my posts page: note under a post in review, only you can see it until then."), false)
        case .rejected(let reasons):
            let joined = ListFormatter.localizedString(byJoining: reasons.map { reasonText($0) })
            return (String(format: OWSLocalizedString("TELLOMI_FEED_MINE_REJECTED_BECAUSE", comment: "Feed my posts page: note under a rejected post. Embeds {{the reasons, already joined}}."), joined), true)
        case .appealReceived:
            return (OWSLocalizedString("TELLOMI_FEED_MINE_APPEAL_RECEIVED", comment: "Feed my posts page: note under a post whose appeal is being reviewed."), false)
        case .appealUpheld:
            return (OWSLocalizedString("TELLOMI_FEED_MINE_APPEAL_UPHELD", comment: "Feed my posts page: note under a post whose appeal was reviewed and the decision stays."), false)
        }
    }

    static func statusTexts(for status: FeedMyPostsPresentation.Status) -> FeedStatusTexts {
        switch status {
        case .loading, .loadingMore:
            return FeedStatusTexts(spins: true)
        case .failed(let seconds):
            return FeedStatusTexts(
                title: OWSLocalizedString("TELLOMI_FEED_MINE_LOAD_FAILED", comment: "Feed my posts page: shown when the list could not be loaded."),
                body: seconds.map { FeedProfileViewController.throttledText($0) },
                retry: true,
            )
        case .loadMoreFailed(let seconds):
            return FeedStatusTexts(
                title: OWSLocalizedString("TELLOMI_FEED_MINE_LOAD_MORE_FAILED", comment: "Feed my posts page: shown at the end of the list when more posts could not be loaded."),
                body: seconds.map { FeedProfileViewController.throttledText($0) },
                retry: true,
            )
        case .empty:
            return FeedStatusTexts(title: OWSLocalizedString("TELLOMI_FEED_MINE_EMPTY", comment: "Feed my posts page: empty state, you haven't posted anything yet."))
        }
    }

    /// 一行的预览文字：文章先标题、再正文；去掉多余空白。
    static func previewText(_ row: FeedMyPostRow) -> (title: String?, body: String) {
        let body = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (row.title, body)
    }
}

// MARK: - Table

extension FeedMyPostsViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case .post(let row):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedMyPostCell.reuseIdentifier, for: indexPath) as! FeedMyPostCell
            cell.configure(row)
            cell.onAppeal = { [weak self] in self?.presentAppeal(row) }
            return cell
        case .status(let status):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedStatusRowCell.reuseIdentifier, for: indexPath) as! FeedStatusRowCell
            cell.configure(Self.statusTexts(for: status)) { [weak self] in self?.retry(status) }
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row), case .post(let row) = rows[indexPath.row] else { return }
        open(row)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard rows.indices.contains(indexPath.row), case .post(let row) = rows[indexPath.row] else { return nil }
        var actions = [UIContextualAction]()
        if row.canDelete {
            let delete = UIContextualAction(style: .destructive, title: Self.deleteTitle) { [weak self] _, _, done in
                self?.confirmDelete(row)
                done(false)   // 确认之后才真的删；先让行滑回来
            }
            actions.append(delete)
        }
        if composeExtras, row.canEdit(now: Date(), windowSeconds: store.state.editWindowSeconds) {
            let edit = UIContextualAction(style: .normal, title: Self.editTitle) { [weak self] _, _, done in
                self?.edit(row)
                done(true)
            }
            edit.backgroundColor = .systemBlue
            actions.append(edit)
        }
        if row.canAppeal {
            let appeal = UIContextualAction(style: .normal, title: Self.appealTitle) { [weak self] _, _, done in
                self?.presentAppeal(row)
                done(true)
            }
            appeal.backgroundColor = .systemOrange
            actions.append(appeal)
        }
        return actions.isEmpty ? nil : UISwipeActionsConfiguration(actions: actions)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if presentation.canLoadMore, indexPath.row >= rows.count - 3 {
            store.loadMore()
        }
    }

    private func retry(_ status: FeedMyPostsPresentation.Status) {
        switch status {
        case .loadMoreFailed:
            store.loadMore()
        default:
            store.refresh()
        }
    }
}

// MARK: - Cells

/// 一行自己的帖子：状态、可见范围、时间，标题 / 正文预览，说明（审核中 / 未通过原因 / 申诉进度），能申诉的有「申诉」按钮。
final class FeedMyPostCell: UITableViewCell {
    static let reuseIdentifier = "FeedMyPostCell"

    /// 单测 / 截图用。
    let statusLabel = UILabel()
    let visibilityLabel = UILabel()
    let timeLabel = UILabel()
    let titleLabel = UILabel()
    let bodyLabel = UILabel()
    let notesStack = UIStackView()
    let appealButton = UIButton(type: .system)
    private let chip = UIView()
    /// 状态 / 可见范围 / 时间：平时一行，最大字号下竖着排（一行放不下会被截断）。
    let headerStack = UIStackView()
    private let headerSpacer = UIView()
    private let contentStack = UIStackView()

    var onAppeal: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear

        statusLabel.font = .dynamicTypeCaption1.semibold()
        chip.layer.cornerRadius = 6
        chip.addSubview(statusLabel)
        statusLabel.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(hMargin: 8, vMargin: 2))
        chip.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        visibilityLabel.font = .dynamicTypeCaption1
        visibilityLabel.textColor = UIColor.Signal.secondaryLabel
        timeLabel.font = .dynamicTypeCaption1
        timeLabel.textColor = UIColor.Signal.secondaryLabel
        timeLabel.textAlignment = .right
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        visibilityLabel.numberOfLines = 0
        statusLabel.numberOfLines = 0

        let header = headerStack
        for view in [chip, visibilityLabel, headerSpacer, timeLabel] { header.addArrangedSubview(view) }
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8

        titleLabel.font = .dynamicTypeBody.semibold()
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.numberOfLines = 2
        bodyLabel.font = .dynamicTypeBody
        bodyLabel.textColor = UIColor.Signal.label
        bodyLabel.numberOfLines = 3

        notesStack.axis = .vertical
        notesStack.spacing = 4

        appealButton.setTitle(FeedMyPostsViewController.appealTitle, for: .normal)
        appealButton.titleLabel?.font = .dynamicTypeSubheadline.semibold()
        appealButton.contentHorizontalAlignment = .leading
        appealButton.addAction(UIAction { [weak self] _ in self?.onAppeal?() }, for: .touchUpInside)

        let stack = contentStack
        for view in [header, titleLabel, bodyLabel, notesStack, appealButton] { stack.addArrangedSubview(view) }
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 6
        contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAppeal = nil
    }

    override func layoutSubviews() {
        updateHeaderLayout()
        updateAppealSpacing()
        super.layoutSubviews()
    }

    /// 表格算行高（自适应高度）时不一定先走 layoutSubviews：先把「表头竖排 / 申诉间距」按现在的字号定下来再量，
    /// 否则行高按横排 + 6pt 算，排版时才改成竖排 + 16pt，多出来的高度只能从状态标签和「申诉」按钮里挤（最大字号下状态标签被压成一条线）。
    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority,
    ) -> CGSize {
        updateHeaderLayout()
        updateAppealSpacing()
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontalFittingPriority, verticalFittingPriority: verticalFittingPriority)
    }

    /// 备注和「申诉」按钮之间现在的距离（单测用）。
    var appealSpacingForTesting: CGFloat { contentStack.customSpacing(after: notesStack) }

    /// 备注和「申诉」按钮之间的距离：字大了贴得紧，加大（`FeedDynamicTypeLayout.appealSpacing`）。
    private func updateAppealSpacing() {
        let spacing = FeedDynamicTypeLayout.appealSpacing(isAccessibilityCategory: traitCollection.preferredContentSizeCategory.isAccessibilityCategory)
        if contentStack.customSpacing(after: notesStack) != spacing { contentStack.setCustomSpacing(spacing, after: notesStack) }
    }

    private func updateHeaderLayout() {
        let vertical = FeedDynamicTypeLayout.stacksPostMetaVertically(isAccessibilityCategory: traitCollection.preferredContentSizeCategory.isAccessibilityCategory)
        let axis: NSLayoutConstraint.Axis = vertical ? .vertical : .horizontal
        guard headerStack.axis != axis else { return }
        headerStack.axis = axis
        headerStack.alignment = vertical ? .leading : .center
        headerSpacer.isHidden = vertical
        timeLabel.textAlignment = vertical ? .natural : .right
    }

    func configure(_ row: FeedMyPostRow) {
        statusLabel.text = FeedMyPostsViewController.statusTitle(row.status)
        let (background, foreground) = Self.chipColors(row.status)
        chip.backgroundColor = background
        statusLabel.textColor = foreground

        visibilityLabel.text = row.visibility?.title
        visibilityLabel.isHidden = row.visibility == nil
        timeLabel.text = row.createdAt.flatMap { FeedDates.parse($0) }.map { FeedPostCell.relativeTime($0, now: Date()) }

        let preview = FeedMyPostsViewController.previewText(row)
        titleLabel.text = preview.title
        titleLabel.isHidden = preview.title == nil
        bodyLabel.text = preview.body
        bodyLabel.isHidden = preview.body.isEmpty

        for view in notesStack.arrangedSubviews {
            notesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var spoken = [String]()
        for note in row.notes {
            let (text, isError) = FeedMyPostsViewController.noteText(note)
            let label = UILabel()
            label.font = .dynamicTypeFootnote
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            // 备注不省略：最大字号下换行显示全，行高跟着长（不被上面的行或固定行高压扁）
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            label.text = text
            label.textColor = isError ? .systemRed : UIColor.Signal.secondaryLabel
            notesStack.addArrangedSubview(label)
            spoken.append(text)
        }
        notesStack.isHidden = row.notes.isEmpty
        appealButton.isHidden = !row.canAppeal
        selectionStyle = row.canOpen ? .default : .none

        accessibilityLabel = ([statusLabel.text, row.visibility?.title, preview.title, preview.body.isEmpty ? nil : preview.body] + spoken).compactMap { $0 }.joined(separator: ", ")
    }

    static func chipColors(_ status: FeedMyPostStatus) -> (UIColor, UIColor) {
        switch status {
        case .pending:
            return (UIColor.systemOrange.withAlphaComponent(0.15), .systemOrange)
        case .rejected:
            return (UIColor.systemRed.withAlphaComponent(0.15), .systemRed)
        case .withdrawn:
            return (UIColor.Signal.secondaryBackground, UIColor.Signal.secondaryLabel)
        case .published:
            return (UIColor.systemGreen.withAlphaComponent(0.15), .systemGreen)
        }
    }
}
