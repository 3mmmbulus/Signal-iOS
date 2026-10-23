//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedComposeStore.swift (new file)
// The publish page's state machine (I-12). `FeedComposeViewController` keeps its own `draft` today; this is the same rules
// in one place so the poll / topics / reply options / quote / edit / article-autosave pieces can be wired in screen by screen.
// Mirror of Android `compose/FeedComposeViewModel.kt` + `FeedComposeState`.
//
// Audience picking (`onAudiencePicked`) was added in I-11. Not included: the camera dual-shot.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

struct FeedComposeState: Equatable {
    var draft = FeedDraft()
    var limits = FeedLimits()
    var minorMode = false
    var publishing = false
    var failed = false
    /// 编辑时引擎说过了 15 分钟（或这条已经不能改了）。
    var editWindowClosed = false
    /// 引擎说引用的那条已经看不到了（400 `quote_unavailable`），引用已从草稿里去掉。
    var quoteUnavailable = false
    /// 刚才输入/粘贴碰到了标题的上限（被挡住或剪短了），界面可以让计数闪一下（I-20）。
    var titleLimitHit = false
    /// 引擎说还没建公开主页（409 `profile_required`）：先去建，建好接着发。
    var profileRequired = false
    /// 编辑模式：在改哪一条，和打开时的样子（没改动就不让保存、关页面也不问）。
    var editing: FeedEditTarget?
    var original: FeedDraft?
    /// 打开时恢复了上次没写完的长文，提示一句。
    var restoredArticle = false
    /// 发出去之后服务端给的 `state`（`pending` / `published`）；非空表示可以关页面了。
    var publishedState: String?
    /// 引擎有 `audience_tokens`（I-19）：「部分好友 / 屏蔽某些人」才能选。打开页面时 `refreshFeatures` 问；没问到之前和查不到都是 false。
    var audienceAvailable = false
    /// 未成年人时限锁着（I-15）：不能发，草稿留在这一页（长文照样自动存在本机），解锁后接着发。已经在发的那一次不拦。
    var minorLocked = false

    /// 发布按钮能不能点。
    var canPublish: Bool { problem == nil && !publishing && !minorLocked }

    /// 编辑时可见范围不动，所以不查可见范围那两项；没改动也不能保存。
    var problem: FeedDraft.Problem? {
        // 标题只有输入法拼写中才会超过 100（I-20）：这时先别让发，拼完会被剪回 100。
        if draft.kind == .article && titleRemaining < 0 { return .tooLong }
        let problem = draft.problem(limits: limits, minorMode: minorMode)
        if editing == nil { return problem }
        switch problem {
        case .visibilityNotAllowed?, .missingAudience?, .audienceTooLarge?:
            return isUnchanged ? .unchanged : nil
        case nil:
            return isUnchanged ? .unchanged : nil
        default:
            return problem
        }
    }

    /// 长文标题还能输几个字（按码点，I-20）。拼写中可能是负数。
    var titleRemaining: Int { FeedInputLimit.remaining(draft.title, limit: FeedInputLimit.articleTitle) }

    var isUnchanged: Bool {
        guard let original else { return false }
        return original.title.trimmed == draft.title.trimmed && original.text.trimmed == draft.text.trimmed
    }

    /// 新写的长文（不是编辑、不是引用）边写边存在本机（第 25 条）。动态那一栏选了图或加了投票的不算：那些不存，关页面要问。
    var autosavesArticle: Bool {
        return editing == nil && draft.quote == nil && draft.kind == .article && draft.images.isEmpty && draft.poll == nil
    }

    /// 关页面要不要问「放弃吗」。自动保存的长文不问。
    var hasUnsavedChanges: Bool {
        if editing != nil { return !isUnchanged }
        return !draft.isEmpty && !autosavesArticle
    }

    var textLimit: Int { draft.textLimit(limits) }

    var canAddImages: Bool {
        // 引擎没部署图片上传（`media_upload`）：不给加（I-2）
        return editing == nil && draft.kind == .post && draft.images.count < limits.postImages
            && FeedEngineCapabilities.allows(FeedEngineCapabilities.mediaUploadFeatures)
    }

    var canAddPoll: Bool {
        // 引擎没部署投票（`polls`）：不给加
        return editing == nil && draft.kind == .post && draft.poll == nil && FeedEngineCapabilities.allows(FeedEngineCapabilities.pollFeatures)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

@MainActor
final class FeedComposeStore {
    private let source: FeedSource
    private let articleDrafts: FeedArticleDrafts
    private var tasks = [Task<Void, Never>]()

    /// 这条草稿的去重号（契约 7.2 `client_nonce`）：点了发布、网络断了再点，服务端只收一次。
    let clientNonce: String

    private(set) var state: FeedComposeState {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedComposeState) -> Void)?

    init(
        editTarget: FeedEditTarget? = nil,
        quoteTarget: FeedQuoteTarget? = nil,
        source: FeedSource,
        articleDrafts: FeedArticleDrafts,
        clientNonce: String = UUID().uuidString
    ) {
        self.source = source
        self.articleDrafts = articleDrafts
        self.clientNonce = clientNonce
        if let editTarget {
            var draft = FeedDraft()
            draft.kind = editTarget.draftKind
            draft.title = editTarget.title ?? ""
            draft.text = editTarget.text
            state = FeedComposeState(draft: draft, editing: editTarget, original: draft)
        } else if let quoteTarget {
            var draft = FeedDraft()
            draft.quote = quoteTarget
            state = FeedComposeState(draft: draft)
        } else if let saved = articleDrafts.load(), !saved.title.trimmed.isEmpty || !saved.text.trimmed.isEmpty {
            // 上次没写完的长文接着写（第 25 条）
            var draft = FeedDraft()
            draft.kind = .article
            draft.title = saved.title
            draft.text = saved.text
            state = FeedComposeState(draft: draft, restoredArticle: true)
        } else {
            state = FeedComposeState()
        }
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
    }

    /// 读配置（字数 / 图片上限、未成年人模式）。读不到就用默认值。
    func start() {
        tasks.append(Task { [weak self, source] in
            do {
                let config = try await source.config()
                guard let self else { return }
                var next = self.state
                // 新的一条用默认档；恢复出来的长文如果是这个模式下不许的档（未成年人模式不能公开），也换成默认档
                let useDefault = next.editing == nil
                    && (next.draft.isEmpty || !FeedVisibility.allowed(minorMode: config.minorMode).contains(next.draft.visibility))
                if useDefault { next.draft.visibility = FeedVisibility.defaultValue(minorMode: config.minorMode) }
                next.limits = config.limits
                next.minorMode = config.minorMode
                self.state = next
            } catch {
                Logger.warn("feed compose config failed, using defaults: \(error)")
            }
        })
    }

    /// 问引擎有没有 `audience_tokens`（`GET /v1/capabilities`，I-19；打开页面时和 `start()` 一起调）。
    /// 没有（含查不到、404）→ 「部分好友 / 屏蔽某些人」选不了；草稿里已经是这两档的退回默认档并清掉名单，免得发出去被引擎拒。
    func refreshFeatures(_ features: FeedFeatureGate) {
        tasks.append(Task { [weak self] in
            let available = await features.isAvailable(FeedFeature.audienceTokens)
            guard let self else { return }
            var next = self.state
            next.audienceAvailable = available
            if !available, next.editing == nil, next.draft.visibility.needsAudience {
                next.draft.visibility = FeedVisibility.defaultValue(minorMode: next.minorMode)
                next.draft.audience = []
            }
            self.state = next
        })
    }

    // MARK: - 编辑草稿

    func onKindChanged(_ kind: FeedDraftKind) {
        // 编辑时不换类型；引用只能是动态
        if state.editing == nil && state.draft.quote == nil { updateDraft { $0.kind = kind } }
    }

    /// 整段替换标题（粘贴、恢复、测试用）：超过 100 个码点就剪到 100；拼写中（`composing`）先放行，拼完再来一次（I-20）。
    func onTitleChanged(_ title: String, composing: Bool = false) {
        let clipped = FeedInputLimit.clip(title, limit: FeedInputLimit.articleTitle, composing: composing)
        updateDraft { $0.title = clipped.text }
        state.titleLimitHit = clipped.clipped
    }

    /// 标题输入框的 `shouldChangeCharactersIn` 里调：返回 `accepted` 为真就让系统照常改，否则返回 NO，
    /// 并在 `clipped` 时由界面把文字设成 `store.state.draft.title`（I-20）。
    @discardableResult
    func onTitleEdit(range: NSRange, replacement: String, composing: Bool = false) -> FeedInputEdit {
        let edit = FeedInputLimit.edit(current: state.draft.title, range: range, replacement: replacement,
                                       limit: FeedInputLimit.articleTitle, composing: composing)
        if edit.changed { updateDraft { $0.title = edit.text } }
        state.titleLimitHit = edit.limitHit
        return edit
    }

    func onTextChanged(_ text: String) { updateDraft { $0.text = text } }

    /// 加图，超出上限的部分不要（选图器本身也限了张数，这里兜底）；同一张不重复加。
    func onImagesPicked(_ images: [FeedDraftImage]) {
        let room = max(state.limits.postImages - state.draft.images.count, 0)
        updateDraft { draft in
            var added = [FeedDraftImage]()
            for image in images where !draft.images.contains(image) && !added.contains(image) {
                added.append(image)
            }
            draft.images += added.prefix(room)
        }
    }

    func onImageRemoved(id: String) { updateDraft { $0.images.removeAll { $0.id == id } } }

    func onVisibilityChanged(_ visibility: FeedVisibility) {
        if FeedVisibility.allowed(minorMode: state.minorMode).contains(visibility) && !visibility.needsAudience {
            updateDraft { $0.visibility = visibility }
        }
    }

    /// 正在给哪一档选人（选人页开着时转屏，回来还知道是哪一档）。
    var pickingAudienceFor: FeedVisibility?

    /// 选人页回来：选了人才换到这一档；一个没选（或者取消）就保持原来的档位（I-11）。
    func onAudiencePicked(_ visibility: FeedVisibility, _ members: [FeedAudienceMember]) {
        if !state.audienceAvailable || !visibility.needsAudience || !FeedVisibility.allowed(minorMode: state.minorMode).contains(visibility) || members.isEmpty { return }
        updateDraft {
            $0.visibility = visibility
            $0.audience = members
        }
    }

    func onReplySettingsChanged(_ settings: FeedReplySettings) {
        if state.editing == nil { updateDraft { $0.replies = settings } }
    }

    /// 选上或取消一个话题；满 3 个时再选不进去。编辑时不能改（引擎编辑只收正文和标题）。
    func onTopicToggled(_ slug: String) {
        if state.editing != nil { return }
        updateDraft { draft in
            if draft.topics.contains(slug) {
                draft.topics.removeAll { $0 == slug }
            } else if draft.topics.count < FeedDraft.maxTopics {
                draft.topics.append(slug)
            }
        }
    }

    // MARK: - 投票

    /// 加投票（编辑时不能加：引擎编辑只收正文和标题）。
    func onPollAdded() {
        if state.canAddPoll { updateDraft { $0.poll = FeedDraftPoll() } }
    }

    func onPollRemoved() { updateDraft { $0.poll = nil } }

    func onPollOptionChanged(_ index: Int, _ text: String) {
        updatePoll { poll in
            if poll.options.indices.contains(index) { poll.options[index] = FeedDraftPoll.clip(text) }
        }
    }

    func onPollOptionAdded() {
        updatePoll { if $0.canAddOption { $0.options.append("") } }
    }

    /// 至少留两个格子。
    func onPollOptionRemoved(_ index: Int) {
        updatePoll { poll in
            if poll.options.count > FeedDraftPoll.minOptions && poll.options.indices.contains(index) { poll.options.remove(at: index) }
        }
    }

    func onPollMultiChanged(_ multi: Bool) { updatePoll { $0.multi = multi } }

    func onPollDurationChanged(_ duration: FeedPollDuration) { updatePoll { $0.duration = duration } }

    // MARK: - 发布

    func publish() {
        let current = state
        if current.publishing || current.problem != nil || current.minorLocked { return }
        state.publishing = true
        state.failed = false
        state.editWindowClosed = false
        state.quoteUnavailable = false
        tasks.append(Task { [weak self, source, clientNonce, articleDrafts] in
            do {
                let response: FeedCreatePostResponse
                if let target = current.editing {
                    response = try await source.editPost(contentId: target.id, draft: current.draft)
                } else {
                    response = try await source.publish(draft: current.draft, clientNonce: clientNonce)
                    articleDrafts.clear()
                }
                self?.state.publishing = false
                self?.state.publishedState = response.state
            } catch {
                guard let self else { return }
                if let error = error as? FeedAPIError {
                    Logger.warn("feed publish failed: \(error.status) \(error.code ?? "")")
                    let closed = error.status == 409 && (error.code == "edit_window_closed" || error.code == "not_editable")
                    let noProfile = error.status == 409 && error.code == "profile_required"
                    // 引用的那条在写的时候被删了或看不到了：去掉引用，正文留着，用户可以照普通动态再发
                    let quoteGone = error.status == 400 && error.code == "quote_unavailable" && current.draft.quote != nil
                    var next = self.state
                    next.publishing = false
                    next.failed = !closed && !noProfile && !quoteGone
                    next.editWindowClosed = closed
                    next.profileRequired = noProfile
                    next.quoteUnavailable = quoteGone
                    if quoteGone { next.draft.quote = nil }
                    self.state = next
                } else {
                    Logger.warn("feed publish failed: \(error)")
                    self.state.publishing = false
                    self.state.failed = true
                }
            }
        })
    }

    func onFailureShown() {
        // 一次改完再通知：逐个字段改的话，第一次 `state.failed = false` 的 didSet 就会让页面再进 consumeNotices，
        // 那时 `editWindowClosed` 还是 true，又调回这里 —— 无限递归，栈溢出崩溃（编辑过了窗口时必现）。
        var next = state
        next.failed = false
        next.editWindowClosed = false
        next.quoteUnavailable = false
        state = next
    }

    func onRestoredArticleShown() { state.restoredArticle = false }

    /// 放弃草稿（发布页导航栏的「放弃草稿」，已经问过确认）：清空正文 / 标题 / 图 / 投票 / 话题 / 回复选项和名单，
    /// 可见范围回到默认档，本机存着的长文也删掉。引用的那条留着（那不是草稿内容）；编辑时没有草稿，什么也不做。
    func discardDraft() {
        guard state.editing == nil else { return }
        var next = state
        var fresh = FeedDraft()
        fresh.visibility = FeedVisibility.defaultValue(minorMode: state.minorMode)
        fresh.quote = state.draft.quote
        next.draft = fresh
        next.restoredArticle = false
        next.titleLimitHit = false
        next.failed = false
        state = next
        articleDrafts.clear()
    }

    /// 未成年人时限锁上 / 解开（`FeedMinorSession`）。
    func setMinorLocked(_ locked: Bool) {
        guard state.minorLocked != locked else { return }
        state.minorLocked = locked
    }

    /// 已经打开了建主页的页面。
    func onProfileRequiredShown() { state.profileRequired = false }

    // MARK: - 内部

    private func updatePoll(_ transform: (inout FeedDraftPoll) -> Void) {
        updateDraft { draft in
            guard var poll = draft.poll else { return }
            transform(&poll)
            draft.poll = poll
        }
    }

    private func updateDraft(_ transform: (inout FeedDraft) -> Void) {
        var next = state
        transform(&next.draft)
        state = next
        if next.autosavesArticle {
            let draft = next.draft
            if draft.title.trimmed.isEmpty && draft.text.trimmed.isEmpty {
                articleDrafts.clear()
            } else {
                articleDrafts.save(FeedSavedArticle(title: draft.title, text: draft.text))
            }
        }
    }
}
