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
    /// 未成年人时限的提示页（时限关着时是 nil）。
    private(set) var minorLock: FeedMinorLockController?

    /// 离评论列表底部还剩几行时取下一页。
    static let loadMoreThreshold = 3

    private enum Row: Equatable {
        case post
        /// 详情页补全开着：帖子下面的投票。
        case poll
        /// 详情页补全开着：帖子下面的转发 / 收藏按钮。
        case actions
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
    /// 点了帖子 / 评论上的头像 / 名字。nil（默认）= 不响应。要在页面出现前设好。
    var onOpenAuthor: ((FeedAuthor) -> Void)?
    /// 点了帖子上的 `#话题`。nil（默认）= 不响应。要在页面出现前设好。
    var onOpenTopic: ((FeedTopic) -> Void)?
    /// 删除前的确认；nil = 用自带的确认弹窗。单测 / 截图里换掉，免得弹真的弹窗。
    var confirmDestructive: ((FeedDetailMenuItem, @escaping () -> Void) -> Void)?
    /// 导航栏「···」现在放的几项（没变就不重建菜单）。
    private(set) var shownPostMenu = [FeedDetailMenuItem]()

    private var rows = [Row]()
    private var post: FeedCard
    private var showIpRegion: Bool
    private let articleReader: Bool
    private let extras: Bool
    private let source: FeedSource
    private let savedMessages: FeedSavedMessages?
    private let focusCommentId: String?
    private let voiceLoader: FeedVoiceLoader
    private let feedStore: FeedStore?
    /// 事件（I-13）里这次打开算哪个来源；nil = 不报（通知、我的动态点进来的没有对应的 `surface`）。
    private let eventSurface: FeedEventSurface?
    private let eventsEnabled: Bool
    private let shareEnabled: Bool
    private var eventOpened = false
    private var eventClosed = false
    /// 分享面板怎么弹（参数：外链、做完的回调，`true` = 真的分享了）；nil = 用系统分享面板。单测 / 截图里换掉。
    var presentShareSheet: ((String, @escaping (Bool) -> Void) -> Void)?
    /// 把外链放进剪贴板；单测里换掉，免得动真的剪贴板。
    var copyToPasteboard: (String) -> Void = { UIPasteboard.general.string = $0 }
    private lazy var voicePlayer = FeedVoicePlayer(loader: voiceLoader, baseUrl: { [weak self] in self?.store.state.mediaBaseUrl })
    /// 刚被定位到的评论（高亮几秒）。
    private(set) var highlightedCommentId: String?
    /// 拒绝回复前的确认；nil = 用自带的确认弹窗。单测 / 截图里换掉。
    var confirmDecline: ((@escaping () -> Void) -> Void)?
    /// 编辑页打开了（单测 / 截图用）。
    private(set) var presentedEditor: FeedComposeViewController?

    /// - Parameters:
    ///   - post: 信息流里带过来的那张卡片，先用它画出来，再向 Card API 取最新的。
    ///   - showIpRegion: 信息流里是不是显示 IP 属地；详情拿到自己的配置后以配置为准。
    ///   - feed: 信息流的 `FeedStore`。传了就和列表共用它（卡片只在它里面，详情自己不留副本，赞和评论数改在它里面，列表同步）；
    ///     不传就自己独立运行（单测、还没接上的入口）。
    ///   - articleReader: 长文时「帖子」那一行换成整篇长文的阅读排版（`FeedArticleCell`）。默认跟 `TellomiFeed.isArticleReaderEnabled`（默认关）。
    ///   - extras: 详情页补全：投票、转发 / 收藏、语音评论播放、作者批准 / 拒绝等着的回复、定位到评论、「···」里的「编辑」。默认跟 `TellomiFeed.isDetailExtrasEnabled`（默认关）。
    ///   - savedMessages: 「我的收藏」的实现（iOS 的那个要在 Mac 上接）；nil = 不显示「收藏」按钮。
    ///   - focusCommentId: 从评论通知点进来要定位的评论；只在 `extras` 开着时用。
    ///   - voiceLoader: 语音评论怎么下载、出声（单测换成假的）。
    init(
        post: FeedCard,
        source: FeedSource,
        showIpRegion: Bool,
        feed: FeedStore? = nil,
        articleReader: Bool = TellomiFeed.isArticleReaderEnabled,
        extras: Bool = TellomiFeed.isDetailExtrasEnabled,
        savedMessages: FeedSavedMessages? = nil,
        focusCommentId: String? = nil,
        voiceLoader: FeedVoiceLoader = FeedVoiceFileLoader(),
        eventSurface: FeedEventSurface? = nil,
        eventsEnabled: Bool = TellomiFeed.isDetailEventsEnabled,
        shareEnabled: Bool = TellomiFeed.isShareEnabled,
    ) {
        self.post = post
        self.showIpRegion = showIpRegion
        self.articleReader = articleReader
        self.extras = extras
        self.source = source
        self.savedMessages = extras ? savedMessages : nil
        self.focusCommentId = extras ? focusCommentId : nil
        self.voiceLoader = voiceLoader
        self.feedStore = feed
        self.eventSurface = eventSurface
        self.eventsEnabled = eventsEnabled && feed != nil
        self.shareEnabled = shareEnabled
        fallbackShowIpRegion = showIpRegion
        store = FeedPostDetailStore(initial: post, source: source, savedMessages: extras ? savedMessages : nil, feed: feed, editEnabled: extras, shareEnabled: shareEnabled)
        super.init()
        // 和 Telegram 一样：推进去以后底栏收起来
        hidesBottomBarWhenPushed = true
        title = OWSLocalizedString("TELLOMI_FEED_DETAIL_TITLE", comment: "Feed: title of the page that shows one post and its comments.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tellomiApplyFeedPreviewPrompt()

        view.backgroundColor = UIColor.Signal.background
        navigationItem.largeTitleDisplayMode = .never
        // 举报：详情页自己接上，菜单里才有「举报」（外面没接 `onReport` 就不显示）
        if onReport == nil {
            onReport = { [weak self] comment in self?.presentReport(forComment: comment) }
        }

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 120
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(FeedPostCell.self, forCellReuseIdentifier: FeedPostCell.reuseIdentifier)
        tableView.register(FeedArticleCell.self, forCellReuseIdentifier: FeedArticleCell.reuseIdentifier)
        tableView.register(FeedCommentCell.self, forCellReuseIdentifier: FeedCommentCell.reuseIdentifier)
        tableView.register(FeedPollCell.self, forCellReuseIdentifier: FeedPollCell.reuseIdentifier)
        tableView.register(FeedDetailActionsCell.self, forCellReuseIdentifier: FeedDetailActionsCell.reuseIdentifier)
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
        if extras {
            voicePlayer.onChange = { [weak self] playback in self?.voicePlaybackChanged(playback) }
        }
        apply(store.state)
        store.start()
        if let focusCommentId { store.locateComment(focusCommentId) }

        // 未成年人时限（I-15）：和动态标签过同一个检查（`FeedMinorSession`），锁着时盖上提示页。放最后，盖在所有东西上面
        minorLock = FeedMinorLockController.install(in: self)
    }

    /// 退到后台：语音暂停（和 Android 一样，回来点一下接着放）；详情事件按「离开」收尾并发出去。
    /// `OWSViewController` 已经订阅了这个通知，直接覆盖它的钩子（自己再订阅一次的话同名方法编不过，且会调两次）。
    override func appDidEnterBackground() {
        super.appDidEnterBackground()
        if extras { voicePlayer.pause() }
        closeDetailEvent(flush: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        openDetailEvent()
    }

    /// 打开详情（I-13）：整个页面生命里只报一次 `open`，盖上别的页面再回来、退到后台再回前台都不重报也不重新计时。
    func openDetailEvent() {
        guard eventsEnabled, let feedStore, let eventSurface, !eventOpened, !eventClosed else { return }
        eventOpened = true
        feedStore.onDetailOpened(contentId: store.state.post.id, surface: eventSurface)
    }

    /// 离开详情（返回、退到后台）：只收尾一次。
    func closeDetailEvent(flush: Bool = false) {
        guard eventOpened, !eventClosed, let feedStore else { return }
        eventClosed = true
        feedStore.onDetailClosed(flush: flush)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 弹出 / 关闭：不再订阅列表的 store、放掉借着的卡片（盖上别的页面再回来不算离开）
        if isMovingFromParent || isBeingDismissed {
            closeDetailEvent()
            store.detach()
            if extras { voicePlayer.release() }
        } else if extras {
            voicePlayer.pause()
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

    /// 单测 / 截图用：长文阅读页那一行的格子（没打开阅读页、不是长文、不在屏幕上时是 nil）。
    var articleCell: FeedArticleCell? {
        return tableView.visibleCells.compactMap { $0 as? FeedArticleCell }.first
    }

    /// 单测 / 截图用：投票那一行的格子。
    var pollCell: FeedPollCell? {
        return tableView.visibleCells.compactMap { $0 as? FeedPollCell }.first
    }

    /// 单测 / 截图用：转发 / 收藏那一行的格子。
    var actionsCell: FeedDetailActionsCell? {
        return tableView.visibleCells.compactMap { $0 as? FeedDetailActionsCell }.first
    }

    /// 单测 / 截图用：某条评论的格子（不在屏幕上时是 nil）。
    func commentCell(_ id: String) -> FeedCommentCell? {
        guard let index = commentRowIndex(id) else { return nil }
        return tableView.cellForRow(at: IndexPath(row: index, section: 0)) as? FeedCommentCell
    }

    /// 单测 / 截图用：语音播放器现在的状态。
    var voicePlayback: FeedVoicePlayback {
        return voicePlayer.playback
    }

    /// 单测：等语音这次加载走完。
    func waitForVoice() async {
        await voicePlayer.waitForLoad()
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
        // 引擎没部署评论（`comments`）：评论输入框收起来
        if !FeedEngineCapabilities.allows(FeedEngineCapabilities.commentFeatures) {
            commentInput.isHidden = true
        }

        post = state.post
        showIpRegion = state.showIpRegion || fallbackShowIpRegion
        updateNavigationMenu(items: FeedDetailMenu.shown(state.postMenu, reportAvailable: onReport != nil))
        closeIfFinished(state)

        var newRows: [Row] = [.post]
        if extras {
            let pollsAllowed = FeedEngineCapabilities.allows(FeedEngineCapabilities.pollFeatures)
            newRows += FeedPostDetailPresentation.extraRows(for: post, saveAvailable: savedMessages != nil)
                .filter { $0 != .poll || pollsAllowed }
                .map { $0 == .poll ? Row.poll : Row.actions }
        }
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
            // 长文：完整的正文取回来后这一格的高度会变，让表格重新量一次（不动画、不整表重载）
            for case let cell as FeedArticleCell in tableView.visibleCells {
                cell.configure(card: post, showIpRegion: showIpRegion)
                UIView.performWithoutAnimation { tableView.performBatchUpdates(nil) }
            }
            // 投票 / 转发 / 收藏：票数、转发 / 收藏状态变了就地更新；投完票选项条的高度会变
            for case let cell as FeedPollCell in tableView.visibleCells {
                cell.configure(card: post)
                UIView.performWithoutAnimation { tableView.performBatchUpdates(nil) }
            }
            if let actions = FeedPostDetailPresentation.actions(for: post, saveAvailable: savedMessages != nil) {
                for case let cell as FeedDetailActionsCell in tableView.visibleCells {
                    cell.configure(actions)
                }
            }
        } else {
            rows = newRows
            tableView.reloadData()
        }

        if let target = state.scrollTarget {
            // 和提示一样放到下一轮主线程：不在 store 的 didSet 里再改 store
            DispatchQueue.main.async { [weak self] in
                guard let self, self.store.state.scrollTarget == target else { return }   // 已经滚过了（连着几次 apply）
                self.scrollToComment(target)
            }
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
        case .edit:
            startEdit()
        case .share:
            share()
        case .copyLink:
            copyLink()
        case .own:
            break
        }
    }

    /// 分享帖子外链（系统分享面板）：选了分享目标就报 `share`（产品 2026-10-20），没选目标就关掉不报。单测里换掉 `presentShareSheet`
    /// （它的 `Bool` = 选了目标）。
    func share() {
        guard let link = shareLink() else { return }
        let finished: (Bool) -> Void = { [weak self] pickedTarget in self?.shareFinished(pickedTarget ? .completed : .cancelled) }
        if let presentShareSheet {
            presentShareSheet(link, finished)
            return
        }
        let controller = UIActivityViewController(activityItems: [link], applicationActivities: nil)
        controller.completionWithItemsHandler = { activityType, _, _, _ in
            finished(FeedShareOutcome.fromShareSheet(activityType: activityType?.rawValue) == .completed)
        }
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }

    /// 复制帖子外链：放进剪贴板就算分享完成。
    func copyLink() {
        guard let link = shareLink() else { return }
        copyToPasteboard(link)
        presentToast(text: OWSLocalizedString("TELLOMI_FEED_LINK_COPIED", comment: "Feed: toast after the link of a post was copied."))
        shareFinished(.completed)
    }

    private func shareLink() -> String? {
        guard store.state.canSharePost else { return nil }
        return FeedShare.link(for: store.state.post)
    }

    private func shareFinished(_ outcome: FeedShareOutcome) {
        guard eventsEnabled, let feedStore, let eventSurface else { return }
        let post = store.state.post
        feedStore.onShareFinished(contentId: post.id, surface: eventSurface, shareable: post.shareable, outcome: outcome)
    }

    /// 编辑自己的帖子（第 23 条）：打开发布页的编辑模式（只改正文和长文标题）；保存回来 store 重新取这条并提示。
    /// 只有详情页补全开着、帖子还在编辑窗口里才进（单测 / 截图直接调它）。
    func startEdit() {
        guard extras, store.state.canEditPost, let target = FeedEditTarget.of(store.state.post), presentedEditor == nil else { return }
        let compose = FeedComposeViewController.make(source: source, editTarget: target) { [weak self] publishState in
            self?.store.onEdited(publishState: publishState)
        }
        presentedEditor = compose
        let navigationController = OWSNavigationController(rootViewController: compose)
        navigationController.modalPresentationStyle = .fullScreen
        present(navigationController, animated: true)
    }

    // MARK: - 拒绝回复 / 语音 / 定位

    /// 拒绝一条等着的回复 = 删掉它：先确认（Android 同样），确认了才调 store。单测 / 截图直接调它。
    func declineConfirmed(_ comment: FeedCard) {
        let proceed: () -> Void = { [weak self] in self?.store.declineComment(comment) }
        if let confirmDecline {
            confirmDecline(proceed)
            return
        }
        OWSActionSheets.showConfirmationAlert(
            title: OWSLocalizedString("TELLOMI_FEED_DETAIL_DECLINE_TITLE", comment: "Feed: question before the post author declines a reply that is waiting for approval."),
            message: OWSLocalizedString("TELLOMI_FEED_DETAIL_DECLINE_BODY", comment: "Feed: explanation under the decline question: the reply will be deleted."),
            proceedTitle: OWSLocalizedString("TELLOMI_FEED_DETAIL_DECLINE", comment: "Feed: post author's button that declines (deletes) a reply that is waiting for them."),
            proceedStyle: .destructive,
            proceedAction: { _ in proceed() },
            fromViewController: self,
        )
    }

    /// 语音放到哪变了：只更新看得见的评论格子里的语音那一行。
    private func voicePlaybackChanged(_ playback: FeedVoicePlayback) {
        for case let cell as FeedCommentCell in tableView.visibleCells {
            cell.updatePlayback(playback)
        }
        // 「播放失败」那行出现 / 消失会改变行高：让表格重新量一次，否则只能从语音那一行里挤（播放按钮被压扁）
        if playback.failedKey != lastVoiceFailedKey {
            lastVoiceFailedKey = playback.failedKey
            UIView.performWithoutAnimation { tableView.performBatchUpdates(nil) }
        }
    }

    private var lastVoiceFailedKey: String?

    private func commentRowIndex(_ id: String) -> Int? {
        return rows.firstIndex { row in
            if case .comment(let commentRow) = row { return commentRow.comment.id == id }
            return false
        }
    }

    /// 滚到某条评论并高亮几秒（从评论通知点进来）。单测 / 截图直接调它。
    func scrollToComment(_ id: String) {
        store.onScrolled()
        guard let index = commentRowIndex(id) else { return }
        highlightedCommentId = id
        tableView.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
        tableView.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightSeconds) { [weak self] in
            guard let self, self.highlightedCommentId == id else { return }
            self.highlightedCommentId = nil
            if let current = self.commentRowIndex(id) {
                self.tableView.reloadRows(at: [IndexPath(row: current, section: 0)], with: .none)
            }
        }
    }

    static let highlightSeconds: TimeInterval = 2.5

    /// 打开举报页（`comment` 是 nil = 举报帖子本身）。提交成功详情页提示「已提交」；`feed_hidden` 跟着收起。
    private(set) var presentedReport: FeedReportViewController?

    func presentReport(forComment comment: FeedCard?) {
        guard presentedReport == nil else { return }
        let reportStore = store.reportStore(forComment: comment)
        reportStore.start()
        let report = FeedReportViewController(store: reportStore) { [weak self] outcome in
            self?.presentedReportFinished(outcome)
        }
        presentedReport = report
        let navigationController = OWSNavigationController(rootViewController: report)
        present(navigationController, animated: true)
    }

    /// 举报页关了：收起举报页；提交成功提示「已提交」，`feed_hidden` 让详情页跟着收起。
    func presentedReportFinished(_ outcome: FeedReportViewController.Outcome) {
        presentedReport = nil
        dismiss(animated: true)
        switch outcome {
        case .sent: store.onReported()
        case .feedHidden: store.onFeedHidden()
        case .cancelled: break
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
        case .edit:
            return OWSLocalizedString("TELLOMI_FEED_MINE_EDIT", comment: "Feed: ··· menu item that edits the user's own post.")
        case .share:
            return OWSLocalizedString("TELLOMI_FEED_MENU_SHARE", comment: "Feed: ··· menu item that shares the link of a post with the system share sheet.")
        case .copyLink:
            return OWSLocalizedString("TELLOMI_FEED_MENU_COPY_LINK", comment: "Feed: ··· menu item that copies the link of a post.")
        case .own(let action):
            switch action {
            case .pin:
                return OWSLocalizedString("TELLOMI_FEED_MENU_PIN", comment: "Feed: ··· menu item that pins the user's own post to the top of their profile.")
            case .unpin:
                return OWSLocalizedString("TELLOMI_FEED_MENU_UNPIN", comment: "Feed: ··· menu item that unpins the user's own post.")
            case .hideLikes:
                return OWSLocalizedString("TELLOMI_FEED_MENU_HIDE_LIKES", comment: "Feed: ··· menu item that hides the like count on the user's own post.")
            case .showLikes:
                return OWSLocalizedString("TELLOMI_FEED_MENU_SHOW_LIKES", comment: "Feed: ··· menu item that shows the like count on the user's own post again.")
            case .replySettings:
                return OWSLocalizedString("TELLOMI_FEED_MENU_REPLY_SETTINGS", comment: "Feed: ··· menu item that opens who-can-reply options for the user's own post.")
            case .insights:
                return OWSLocalizedString("TELLOMI_FEED_MENU_INSIGHTS", comment: "Feed: ··· menu item that shows view and like statistics of the user's own post.")
            }
        }
    }

    static func confirmationTitle(for item: FeedDetailMenuItem) -> String {
        switch item {
        case .deleteComment:
            return OWSLocalizedString("TELLOMI_FEED_DELETE_COMMENT_CONFIRM", comment: "Feed: confirmation question before deleting the user's own comment.")
        case .deletePost:
            return OWSLocalizedString("TELLOMI_FEED_DELETE_POST_CONFIRM", comment: "Feed: confirmation question before deleting the user's own post.")
        case .notInterested, .report, .own, .edit, .share, .copyLink:
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
        case .saved:
            return OWSLocalizedString("TELLOMI_FEED_SAVED_DONE", comment: "Feed: toast after a post was saved to Saved Messages.")
        case .reposted:
            return OWSLocalizedString("TELLOMI_FEED_REPOSTED_DONE", comment: "Feed: toast after a post was reposted to the user's own feed.")
        case .edited:
            return OWSLocalizedString("TELLOMI_FEED_MINE_EDIT_SAVED", comment: "Feed: toast after an edit of the user's own post was saved.")
        case .editedPending:
            return OWSLocalizedString("TELLOMI_FEED_MINE_EDIT_SAVED_PENDING", comment: "Feed: toast after an edit was saved and the post will be reviewed again before others see the change.")
        case .commentNotFound:
            return OWSLocalizedString("TELLOMI_FEED_DETAIL_COMMENT_NOT_FOUND", comment: "Feed: toast when the comment a notification pointed to can no longer be found.")
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
        case .post where articleReader && post.isArticle:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedArticleCell.reuseIdentifier, for: indexPath) as! FeedArticleCell
            cell.onLike = { [weak self] _ in self?.store.toggleLike() }
            cell.onAuthorTap = onOpenAuthor
            cell.onTopicTap = onOpenTopic
            cell.configure(card: post, showIpRegion: showIpRegion)
            return cell
        case .post:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedPostCell.reuseIdentifier, for: indexPath) as! FeedPostCell
            cell.isReadOnly = true
            cell.allowsLikeWhenReadOnly = true
            cell.onLike = { [weak self] _ in self?.store.toggleLike() }
            cell.onAuthorTap = onOpenAuthor
            cell.onTopicTap = onOpenTopic
            cell.configure(card: post, showIpRegion: showIpRegion)
            return cell
        case .poll:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedPollCell.reuseIdentifier, for: indexPath) as! FeedPollCell
            cell.setIndented(!(articleReader && post.isArticle))
            cell.onVote = { [weak self] options in self?.store.vote(options) }
            cell.configure(card: post)
            return cell
        case .actions:
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedDetailActionsCell.reuseIdentifier, for: indexPath) as! FeedDetailActionsCell
            cell.setIndented(!(articleReader && post.isArticle))
            cell.onRepost = { [weak self] in self?.store.toggleRepost() }
            cell.onSave = { [weak self] in self?.store.toggleSave() }
            if let actions = FeedPostDetailPresentation.actions(for: post, saveAvailable: savedMessages != nil) {
                cell.configure(actions)
            }
            return cell
        case .comment(let row):
            let cell = tableView.dequeueReusableCell(withIdentifier: FeedCommentCell.reuseIdentifier, for: indexPath) as! FeedCommentCell
            let comment = row.comment
            cell.onAuthorTap = onOpenAuthor
            if extras {
                cell.onApprove = { [weak self] in self?.store.approveComment(comment) }
                cell.onDecline = { [weak self] in self?.declineConfirmed(comment) }
                cell.onVoiceToggle = { [weak self] media in self?.voicePlayer.toggle(media) }
                cell.configure(
                    row: row,
                    extras: FeedCommentExtras(comment: comment, post: post, highlighted: comment.id == highlightedCommentId),
                    playback: voicePlayer.playback
                )
            } else {
                cell.configure(row: row)
            }
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
        // 等批准的回复还没公开，不能回复它（作者先批准或拒绝）
        if extras, row.comment.held { return }
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
