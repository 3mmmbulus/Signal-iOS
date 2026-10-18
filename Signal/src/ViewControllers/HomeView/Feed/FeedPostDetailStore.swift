//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedPostDetailStore.swift (new file)
// Post detail state + actions (I-4), no UIKit. Mirror of Android `detail/FeedPostDetailViewModel.kt`.
// Muting / blocking the author ("leave" actions beyond not-interested) need the relations API → added by I-5.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

struct FeedPostDetailState {
    enum Notice: Equatable {
        /// 语音评论发出去了，人工复核通过后别人才看得到。
        case voicePending
        /// 作者关了这条动态的语音评论。
        case voiceOff
        /// 话筒要按住说话。
        case holdToRecord
        /// 发出去了，等审核（大陆区一律先审后发）。
        case pending
        case published
        case closed
        case replyNotAllowed
        /// 引擎要先建公开主页才能评论（建主页是 I-5）。
        case profileRequired
        case parentGone
        /// 置顶已满 3 条。
        case pinLimit
        /// 已存进「我的收藏」。
        case saved
        /// 已转发到自己的动态。
        case reposted
        /// 编辑保存了；大陆区要重新审核。
        case edited
        case editedPending
        /// 「不看 TA」要先有自己的公开主页。
        case hideProfileRequired
        case failed
    }

    enum Leave: Equatable {
        case notInterested
        case muted
        case blocked
    }

    var post: FeedCard
    /// Card API 说这条已经看不到了（删了、被屏蔽、没权限）。
    var postGone = false
    var comments = [FeedCard]()
    var cursor: String?
    var loading = true
    var loadedOnce = false
    var failed = false
    var canComment = true
    var draft = ""
    /// 评论框碰到了字数上限（拦下或粘贴被截）：界面可以抖一下计数；下一次正常输入清掉（I-20）。
    var draftLimitHit = false
    /// 作者关了这条的语音评论时收起话筒（发的时候才知道：403 `voice_comments_off`）。
    var voiceAllowed = true
    /// 正在回复的评论；nil = 直接评论帖子。
    var replyTarget: FeedCard?
    var sending = false
    var notice: Notice?
    var mediaBaseUrl: String?
    var showIpRegion = false
    /// 「查看数据」弹窗；nil = 没开。
    var insights: FeedInsightsState?
    /// 自己删掉了这条，页面该关了。
    var deleted = false
    /// 发布后多久内能改（引擎 config）。
    var editWindowSeconds = FeedLimits().editWindowSeconds
    var voiceMaxSeconds = FeedLimits().voiceCommentMaxSeconds
    /// 不感兴趣 / 不看 TA / 屏蔽成了：提示一句，页面关掉。
    var leaving: Leave?

    init(post: FeedCard) {
        self.post = post
        canComment = post.viewer.canComment
    }

    var threads: [FeedCommentThread] { FeedCommentThreads.build(comments) }
    /// 评论框还能再输入多少个码点（引擎 `MaxCommentChars` = 500；决定：到上限不让再输入，显示剩余数，I-20）。组字中可以是负数。
    var draftRemaining: Int { FeedInputLimit.remaining(draft, limit: FeedInputLimit.commentText) }
    var canSend: Bool {
        return canComment && !sending && draftRemaining >= 0 && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 帖子详情：整条帖子 + 评论（`dynamic-feed.md` 第三节第 2、4、10 条；契约第五节）。
///
/// 打开时先用信息流里带过来的卡片画出来，再用 Card API 取一次最新的（删了、看不到了就显示「已不可见」）。
/// 评论按楼排（`FeedCommentThreads`）；发出去的评论先审后显，审核通过前列表里没有它，只提示一次。
@MainActor
final class FeedPostDetailStore {
    private let source: FeedSource
    private let savedMessages: FeedSavedMessages?
    /// 和信息流共用的 store（nil = 独立运行，帖子只在 `state.post` 里，单测和还没接上的页面用）。
    /// 有它的时候，帖子的**唯一**数据在它里面：`state.post` 只是每次它变了之后从它重新读的投影，详情页自己从不单独改；
    /// 赞、收藏、转发、投票、置顶、评论数都改到 store 里，列表（也订阅着它）同时看到。
    private let feed: FeedStore?
    private var lease: FeedCardLease?
    private var subscription: FeedSubscription?

    private(set) var state: FeedPostDetailState {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedPostDetailState) -> Void)?

    private var commentsGeneration = 0
    private var commentsBusy = false
    private var saving = false
    private var reposting = false
    private var voting = false
    private var moderating = FeedInFlight()
    private var leaving = false
    private var tasks = [Task<Void, Never>]()

    init(initial: FeedCard, source: FeedSource, savedMessages: FeedSavedMessages? = nil, feed: FeedStore? = nil) {
        self.source = source
        self.savedMessages = savedMessages
        self.feed = feed
        if let feed {
            let lease = feed.retain(initial)
            self.lease = lease
            // 信息流里已经有这张卡片时，用 store 里现在的样子（可能比传进来的新：刚点过赞）
            self.state = FeedPostDetailState(post: feed.card(id: initial.id) ?? initial)
            self.subscription = feed.subscribe { [weak self] change in
                self?.onFeedChange(change)
            }
        } else {
            self.state = FeedPostDetailState(post: initial)
        }
    }

    // MARK: - 和信息流 store 同步

    private func onFeedChange(_ change: FeedChange) {
        switch change {
        case .cards(let ids):
            if ids.contains(state.post.id) { adoptFromFeed() }
        case .list:
            adoptFromFeed()
        case .actionFailed(let cardId):
            if cardId == state.post.id { state.notice = .failed }
        }
    }

    /// 从 store 里重新读这张卡片（和现在显示的一样就不动，免得白白通知界面）。
    private func adoptFromFeed() {
        guard let feed, let card = feed.card(id: state.post.id), card != state.post else { return }
        state.post = card
    }

    /// 改帖子：有信息流 store 就改在 store 里（`state.post` 随通知更新），没有就改自己的 `state.post`。
    private func updatePost(_ transform: (inout FeedCard) -> Void) {
        if let feed {
            feed.updateCard(state.post.id, transform)
        } else {
            transform(&state.post)
        }
    }

    /// 单测用：等已经发出去的请求都做完。
    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
        await feed?.waitForActions()
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        tasks.append(Task { await body() })
    }

    /// 打开页面：配置、最新的卡片、第一页评论（Android 在 `init` 里做）。
    func start() {
        run { [weak self, source] in
            do {
                let config = try await source.config()
                self?.state.mediaBaseUrl = config.mediaBaseUrl
                self?.state.showIpRegion = config.ipRegionVisible
                self?.state.editWindowSeconds = config.limits.editWindowSeconds
                self?.state.voiceMaxSeconds = config.limits.voiceCommentMaxSeconds
            } catch {
                Logger.warn("feed detail config failed: \(error)")
            }
        }
        refreshPost()
        refreshComments()
    }

    private func refreshPost() {
        run { [weak self, source] in
            guard let self else { return }
            do {
                let fresh = try await source.card(contentId: self.state.post.id)
                if let fresh {
                    if let feed = self.feed {
                        feed.ingest(fresh)
                    } else {
                        self.state.post = fresh
                    }
                    self.state.canComment = fresh.viewer.canComment
                } else {
                    self.state.postGone = true
                }
            } catch {
                Logger.warn("feed detail card refresh failed, keeping the feed copy: \(error)")
            }
        }
    }

    /// 编辑页保存回来（第三节第 23 条）：重新拉这条；大陆区改完要重新审核，提示不一样。
    func onEdited(publishState: String) {
        state.notice = publishState == FeedCreatePostResponse.statePending ? .editedPending : .edited
        refreshPost()
    }

    // MARK: - 评论列表

    func refreshComments() {
        commentsGeneration += 1
        let generation = commentsGeneration
        commentsBusy = true
        state.loading = true
        state.failed = false
        run { [weak self, source] in
            guard let self else { return }
            do {
                let page = try await source.comments(postId: self.state.post.id, cursor: nil)
                guard generation == self.commentsGeneration else { return }   // 被更新的一次顶掉了
                self.state.comments = page.comments
                self.state.cursor = page.cursor
                self.state.loading = false
                self.state.loadedOnce = true
                self.commentsBusy = false
            } catch {
                Logger.warn("feed detail comments failed: \(error)")
                guard generation == self.commentsGeneration else { return }
                self.state.loading = false
                self.state.failed = true
                self.state.loadedOnce = true
                self.commentsBusy = false
            }
        }
    }

    func loadMoreComments() {
        guard let cursor = state.cursor, !commentsBusy else { return }
        commentsGeneration += 1
        let generation = commentsGeneration
        commentsBusy = true
        state.loading = true
        run { [weak self, source] in
            guard let self else { return }
            do {
                let page = try await source.comments(postId: self.state.post.id, cursor: cursor)
                guard generation == self.commentsGeneration else { return }
                let known = Set(self.state.comments.map(\.id))
                self.state.comments += page.comments.filter { !known.contains($0.id) }
                self.state.cursor = page.cursor
                self.state.loading = false
                self.commentsBusy = false
            } catch {
                Logger.warn("feed detail comments page failed: \(error)")
                guard generation == self.commentsGeneration else { return }
                self.state.loading = false
                self.commentsBusy = false
            }
        }
    }

    // MARK: - 帖子上的动作（同信息流，Android 同一套规则）

    func toggleLike() {
        if let feed {
            // 赞的乐观更新、失败回滚、连点都在 FeedStore 里；失败时它发 `.actionFailed`，这里变成 `.failed` 提示
            feed.toggleLike(id: state.post.id)
            return
        }
        let post = state.post
        let nowLiked = !post.viewer.liked
        state.post = FeedStore.withLiked(post, nowLiked)
        run { [weak self, source] in
            do {
                try await source.setLiked(contentId: post.id, liked: nowLiked)
            } catch {
                Logger.warn("feed detail like failed: \(error)")
                guard let self else { return }
                self.state.post = FeedStore.withLiked(self.state.post, !nowLiked)
                self.state.notice = .failed
            }
        }
    }

    /// 收藏 / 取消收藏：先改「我的收藏」，再以假名上报（上报失败不改回）。
    func toggleSave() {
        guard !saving else { return }
        saving = true
        let post = state.post
        let nowSaved = !post.viewer.saved
        updatePost { $0 = $0.withSaved(nowSaved) }
        run { [weak self, source, savedMessages] in
            do {
                guard let savedMessages else { throw FeedPublishError.feedNotAvailable }
                try await FeedSaveFlow.setSaved(post, saved: nowSaved, savedMessages: savedMessages, source: source) {
                    Logger.warn("feed detail save report failed: \($0)")
                }
                self?.saving = false
                if nowSaved { self?.state.notice = .saved }
            } catch {
                Logger.warn("feed detail saved messages failed: \(error)")
                guard let self else { return }
                self.saving = false
                self.updatePost { $0 = $0.withSaved(!nowSaved) }
                self.state.notice = .failed
            }
        }
    }

    func toggleRepost() {
        guard !reposting else { return }
        reposting = true
        let post = state.post
        let nowReposted = !post.viewer.reposted
        updatePost { $0 = $0.withReposted(nowReposted) }
        run { [weak self, source] in
            do {
                try await source.setReposted(contentId: post.id, reposted: nowReposted)
                self?.reposting = false
                if nowReposted { self?.state.notice = .reposted }
            } catch {
                Logger.warn("feed detail repost failed: \(error)")
                guard let self else { return }
                self.reposting = false
                self.updatePost { $0 = $0.withReposted(!nowReposted) }
                self.state.notice = .failed
            }
        }
    }

    /// 投票：等服务端回了票数再换上（投了不能改）。
    func vote(_ options: [Int]) {
        guard !options.isEmpty, !voting else { return }
        voting = true
        let postId = state.post.id
        run { [weak self, source] in
            do {
                let result = try await source.vote(contentId: postId, options: options)
                self?.voting = false
                self?.updatePost { $0 = $0.withPollState(result) }
            } catch {
                Logger.warn("feed detail vote failed: \(error)")
                self?.voting = false
                self?.state.notice = .failed
            }
        }
    }

    // MARK: - 发评论

    /// 整段文本被设置（粘贴后整体设置、恢复、输入法组字结束后补一次）：超过 500 个码点就按码点截（不劈开一个字）。
    /// `composing` 为 true（输入法组字中）不动。没走 `onDraftEdit` 的输入框也靠这个兜底。
    func onDraftChanged(_ text: String, composing: Bool = false) {
        let clipped = FeedInputLimit.clip(text, limit: FeedInputLimit.commentText, composing: composing)
        state.draft = clipped.text
        state.draftLimitHit = clipped.clipped
    }

    /// `shouldChangeCharactersIn` / `shouldChangeTextIn` 钩子（I-20）：把当前草稿的 `range`（UTF-16 区间）换成 `replacement`。
    /// 到上限就拦下，粘贴超长按码点截到上限；返回值告诉钩子要不要自己设文本（`accepted` 以外都要）。草稿已经按结果更新。
    @discardableResult
    func onDraftEdit(range: NSRange, replacement: String, composing: Bool = false) -> FeedInputEdit {
        let edit = FeedInputLimit.edit(current: state.draft, range: range, replacement: replacement, limit: FeedInputLimit.commentText, composing: composing)
        if edit.changed { state.draft = edit.text }
        state.draftLimitHit = edit.limitHit
        return edit
    }

    func replyTo(_ comment: FeedCard?) {
        state.replyTarget = comment
    }

    func send() {
        let snapshot = state
        let text = snapshot.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !snapshot.sending, snapshot.canComment, snapshot.draftRemaining >= 0 else { return }   // 超过 500 码点（组字中）不发（I-20）
        state.sending = true
        run { [weak self, source] in
            do {
                let publishState = try await source.postComment(postId: snapshot.post.id, text: text, parentId: snapshot.replyTarget?.id)
                guard let self else { return }
                let pending = publishState == FeedCreatePostResponse.statePending
                self.state.sending = false
                self.state.draft = ""
                self.state.replyTarget = nil
                self.state.notice = pending ? .pending : .published
                if !pending {
                    // 发出去就直接显示的评论：帖子上的评论数 +1（列表上的数也同步）；待审的别人看不到，不算
                    self.updatePost { $0.stats.comments += 1 }
                    self.refreshComments()
                }
            } catch {
                Logger.warn("feed detail comment failed: \(error)")
                self?.applyCommentError(error, voice: false)
            }
        }
    }

    /// 发一条语音评论（第三节第 4 条）：录好的 `.m4a` 传完就删（不管成不成功）。作者关了语音评论（403 `voice_comments_off`）
    /// 就收起这条帖子的话筒；语音一律人工复核，所以成功后总是说「审核通过后别人才看得到」。
    func sendVoice(file: URL) {
        let snapshot = state
        guard !snapshot.sending, snapshot.canComment, snapshot.voiceAllowed else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        state.sending = true
        run { [weak self, source] in
            defer { try? FileManager.default.removeItem(at: file) }
            do {
                let audio = try Data(contentsOf: file)
                _ = try await source.postVoiceComment(postId: snapshot.post.id, audio: audio, parentId: snapshot.replyTarget?.id)
                self?.state.sending = false
                self?.state.replyTarget = nil
                self?.state.notice = .voicePending
            } catch {
                Logger.warn("feed detail voice comment failed: \(error)")
                self?.applyCommentError(error, voice: true)
            }
        }
    }

    private func applyCommentError(_ error: Error, voice: Bool) {
        state.sending = false
        guard let apiError = error as? FeedAPIError else {
            state.notice = .failed
            return
        }
        switch apiError.code {
        case "voice_comments_off" where voice:
            state.voiceAllowed = false
            state.notice = .voiceOff
        case "comments_closed", "not_commentable":
            state.canComment = false
            state.notice = .closed
        case "reply_not_allowed":
            state.notice = .replyNotAllowed
        case "profile_required":
            state.notice = .profileRequired
        case "invalid_parent":
            state.replyTarget = nil
            state.notice = .parentGone
        default:
            state.notice = .failed
        }
    }

    /// 话筒只点了一下、没按住：提示按住说话。
    func onVoiceTooShort() {
        state.notice = .holdToRecord
    }

    // MARK: - 作者批准 / 拒绝等着的回复

    /// 帖子作者批准一条等着的回复（第三节第 40 条）：成功后去掉「等你批准」，别人就看得到了。
    func approveComment(_ comment: FeedCard) {
        moderate(comment) { [source] store in
            try await source.approveComment(postId: store.state.post.id, commentId: comment.id)
            store.state.comments = store.state.comments.map { item in
                guard item.id == comment.id else { return item }
                var approved = item
                approved.held = false
                return approved
            }
        }
    }

    /// 拒绝 = 删掉这条回复（引擎没有单独的拒绝）。
    func declineComment(_ comment: FeedCard) {
        moderate(comment) { [source] store in
            try await source.deletePost(contentId: comment.id)
            store.state.comments.removeAll { $0.id == comment.id }
        }
    }

    private func moderate(_ comment: FeedCard, _ action: @escaping @MainActor (FeedPostDetailStore) async throws -> Void) {
        guard comment.held, moderating.begin(comment.id) else { return }
        run { [weak self] in
            guard let self else { return }
            do {
                try await action(self)
            } catch {
                Logger.warn("feed detail moderating a reply failed: \(error)")
                self.state.notice = .failed
            }
            self.moderating.end(comment.id)
        }
    }

    func onNoticeShown() {
        state.notice = nil
    }

    // MARK: - 自己的帖子

    func onOwnPostAction(_ action: FeedOwnPostAction) {
        let post = state.post
        guard let update = action.settingsUpdate else {
            if action == .insights { loadInsights(post.id) }   // 回复选项卡片自己处理
            return
        }
        updatePost { $0 = $0.withSettings(update) }
        run { [weak self, source] in
            do {
                try await source.updatePostSettings(contentId: post.id, update: update)
            } catch {
                Logger.warn("feed detail post settings failed: \(error)")
                guard let self else { return }
                self.updatePost {
                    $0.pinned = post.pinned
                    $0.stats.likeCountHidden = post.stats.likeCountHidden
                }
                self.state.notice = FeedOwnPostAction.isPinLimit(error) ? .pinLimit : .failed
            }
        }
    }

    private func loadInsights(_ contentId: String) {
        state.insights = .loading
        run { [weak self, source] in
            let result: FeedInsightsState
            do {
                result = .ready(try await source.postInsights(contentId: contentId))
            } catch {
                Logger.warn("feed detail insights failed: \(error)")
                result = .failed
            }
            guard let self, self.state.insights != nil else { return }   // 等的时候关掉了弹窗就不再弹
            self.state.insights = result
        }
    }

    func onInsightsDismissed() {
        state.insights = nil
    }

    /// 删掉自己的帖子：删成功了页面关掉；失败留在这里提示。
    func deletePost() {
        let post = state.post
        run { [weak self, source] in
            do {
                try await source.deletePost(contentId: post.id)
                self?.state.deleted = true
            } catch {
                Logger.warn("feed detail delete failed: \(error)")
                self?.state.notice = .failed
            }
        }
    }

    // MARK: - 「···」里别人的帖子

    /// 不感兴趣（第三节第 11 条）：报给引擎，成了就关页。
    func notInterested() {
        let post = state.post
        leaveAfter(.notInterested) { [source] in try await source.notInterested(contentId: post.id) }
    }

    /// 报给引擎，成了就让页面关掉并提示；一次只能有一个在途。`profile_required`（还没有自己的公开主页）单独提示。
    func leaveAfter(_ leave: FeedPostDetailState.Leave, _ call: @escaping () async throws -> Void) {
        guard !leaving, state.leaving == nil else { return }
        leaving = true
        run { [weak self] in
            do {
                try await call()
                self?.state.leaving = leave
            } catch {
                Logger.warn("feed detail \(leave) failed: \(error)")
                let profileRequired = (error as? FeedAPIError)?.code == "profile_required"
                self?.state.notice = profileRequired ? .hideProfileRequired : .failed
            }
            self?.leaving = false
        }
    }
}
