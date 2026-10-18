//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedMyPosts.swift (new file)
// "My posts" (review states, edit window, appeal) without UI (I-6). Mirror of Android `mine/FeedMyPostsViewModel.kt`,
// `compose/FeedEditTarget.kt`, `FeedApi.myPosts/editPost/appeal`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// `GET /v1/feed/me/posts` 的一项：自己的帖子带审核状态（契约 7.3，第三节第 24 条）。
/// `rejectionReasons` 只有作者看得到；引擎给的是规则代码（`lexicon:…`、`uncertain`），界面按代码转成文案。
struct FeedMyPost: Decodable, Equatable {
    var id: String
    var kind = FeedCard.kindPost
    var state: String
    var version = 1
    var title: String?
    var text: String?
    var visibility: String?
    var createdAt: String?
    var editedAt: String?
    var rejectionReasons = [String]()
    /// 未通过且还没申诉过（每条一次，R-2.1）。
    var appealable = false
    /// 申诉进度：`received` 复核中、`upheld` 维持原决定、`overturned` 改判通过；没申诉过是 nil。
    var appealState: String?

    static let appealReceived = "received"
    static let appealUpheld = "upheld"
    static let appealOverturned = "overturned"
    /// 申诉理由的上限（引擎 `MaxAppealChars`）。
    static let maxAppealChars = FeedInputLimit.appealReason

    static let statePending = FeedCreatePostResponse.statePending
    static let statePublished = FeedCreatePostResponse.statePublished
    static let stateRejected = "rejected"
    static let stateWithdrawn = "withdrawn"

    init(id: String, state: String, kind: String = FeedCard.kindPost, title: String? = nil, text: String? = nil, createdAt: String? = nil, appealable: Bool = false, appealState: String? = nil) {
        self.id = id
        self.state = state
        self.kind = kind
        self.title = title
        self.text = text
        self.createdAt = createdAt
        self.appealable = appealable
        self.appealState = appealState
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? FeedCard.kindPost
        state = try c.decode(String.self, forKey: .state)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        title = try c.decodeIfPresent(String.self, forKey: .title)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        editedAt = try c.decodeIfPresent(String.self, forKey: .editedAt)
        rejectionReasons = try c.decodeIfPresent([String].self, forKey: .rejectionReasons) ?? []
        appealable = try c.decodeIfPresent(Bool.self, forKey: .appealable) ?? false
        appealState = try c.decodeIfPresent(String.self, forKey: .appealState)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, state, version, title, text, visibility, appealable
        case createdAt = "created_at"
        case editedAt = "edited_at"
        case rejectionReasons = "rejection_reasons"
        case appealState = "appeal_state"
    }
}

/// 每页 30 条，新的在前；`nextBefore` 是下一页的 `?before=`，没有就是最后一页。
struct FeedMyPostsPage: Decodable, Equatable {
    var posts = [FeedMyPost]()
    var nextBefore: String?

    init() {}

    init(posts: [FeedMyPost], nextBefore: String?) {
        self.posts = posts
        self.nextBefore = nextBefore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = try c.decodeIfPresent([FeedMyPost].self, forKey: .posts) ?? []
        nextBefore = try c.decodeIfPresent(String.self, forKey: .nextBefore)
    }

    private enum CodingKeys: String, CodingKey {
        case posts
        case nextBefore = "next_before"
    }
}

/// `PATCH /v1/feed/posts/{id}`：只改正文和长文标题（nil 不发）；回包和发帖一样（`state` 是 `pending` 或 `published`）。
struct FeedEditPostRequest: Encodable, Equatable {
    var text: String
    var title: String?
}

/// `POST /v1/feed/posts/{id}/appeal`。
struct FeedAppealRequest: Encodable, Equatable {
    var text: String
}

extension FeedAPI {
    /// 自己的帖子，带审核状态。`before` 是上一页的 `next_before`。
    func myPosts(before: String?) async throws -> FeedMyPostsPage {
        let query = before.map { [URLQueryItem(name: "before", value: $0)] } ?? []
        return try await send(FeedMyPostsPage.self, request(path: ["v1", "feed", "me", "posts"], query: query))
    }

    /// 发布后 15 分钟内改正文 / 标题；超时 409 `edit_window_closed`，未通过的 409 `not_editable`。
    func editPost(contentId: String, request body: FeedEditPostRequest) async throws -> FeedCreatePostResponse {
        let data = try Self.encoder.encode(body)
        return try await send(FeedCreatePostResponse.self, request(path: ["v1", "feed", "posts", contentId], method: "PATCH", body: data))
    }

    /// 对未通过的帖子申诉一次（202）。409 `not_rejected` / `already_appealed`，400 `invalid_text`。
    func appeal(contentId: String, text: String) async throws {
        let data = try Self.encoder.encode(FeedAppealRequest(text: text))
        try await sendNoContent(request(path: ["v1", "feed", "posts", contentId, "appeal"], method: "POST", body: data))
    }
}

extension FeedDraft {
    /// 编辑只带正文和长文标题。
    func toEditRequest() -> FeedEditPostRequest {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeedEditPostRequest(text: text.trimmingCharacters(in: .whitespacesAndNewlines), title: kind == .article ? trimmedTitle : nil)
    }
}

/// 要编辑的那条（第三节第 23 条：发布后 15 分钟内可改，标「已编辑」，大陆区保存后重新审核）。
/// 只能改正文和长文标题，图片和可见范围不改。
struct FeedEditTarget: Equatable {
    var id: String
    var kind: String
    var title: String?
    var text: String
    /// 发布时间（RFC 3339）；引擎按它算 15 分钟，客户端只用来决定入口显不显示。
    var publishedAt: String?

    var draftKind: FeedDraftKind {
        return FeedDraftKind.allCases.first { $0.apiName == kind } ?? .post
    }

    /// 时间读不懂就给入口，最后由引擎判（409 `edit_window_closed`）。
    func isWithinWindow(now: Date, windowSeconds: Int) -> Bool {
        guard let published = publishedAt.flatMap(FeedDates.parse) else { return true }
        return now.timeIntervalSince(published) <= TimeInterval(windowSeconds)
    }

    static func of(_ card: FeedCard) -> FeedEditTarget? {
        guard card.kind == FeedCard.kindPost || card.kind == FeedCard.kindArticle else { return nil }
        return FeedEditTarget(id: card.id, kind: card.kind, title: card.title, text: card.text ?? "", publishedAt: card.publishedAt)
    }

    /// 未通过和已撤回的不能改（引擎 409 `not_editable`）。
    static func of(_ post: FeedMyPost) -> FeedEditTarget? {
        if post.state == FeedMyPost.stateRejected || post.state == FeedMyPost.stateWithdrawn { return nil }
        guard post.kind == FeedCard.kindPost || post.kind == FeedCard.kindArticle else { return nil }
        return FeedEditTarget(id: post.id, kind: post.kind, title: post.title, text: post.text ?? "", publishedAt: post.createdAt)
    }
}

enum FeedAppealResult: Equatable {
    case sent
    case already
    /// 这条已经不是「未通过」（别处申诉过、复核完了、被撤回）：状态过时了，列表会重新拉。
    case notRejected
    /// 引擎限速（429 / 带 `Retry-After` 的 503）；带还要等几秒。
    case throttled(retryAfterSeconds: Int?)
    case failed
}

/// 「我的动态」页上要提示一次的事（提示过就清掉）。
enum FeedMyPostsNotice: Equatable {
    case deleteFailed
    case throttled(retryAfterSeconds: Int?)
    /// 点开的帖子已经没了（撤回 / 删除 / 作者被屏蔽）。
    case postGone
    case failed
}

struct FeedMyPostsState: Equatable {
    var posts = [FeedMyPost]()
    var nextBefore: String?
    var loading = true
    var loadedOnce = false
    /// 下拉刷新中（已经有内容时）；翻页不算。
    var refreshing = false
    /// 翻页中（和 `loading` 分开：列表还在，只在末尾转圈）。
    var loadingMore = false
    /// 第一页（或下拉刷新）失败；限速时 `retryAfterSeconds` 是还要等几秒。已经有的内容还在。
    var failed = false
    /// 翻页失败：列表还在，末尾有「重试」，不再自动翻。
    var loadMoreFailed = false
    var retryAfterSeconds: Int?
    /// 动态被收起了（`feed_hidden`）：页面该收起。
    var feedHidden = false
    var notice: FeedMyPostsNotice?
    /// 发布后多久内能改（config `limits.edit_window_seconds`）。
    var editWindowSeconds = 900
    /// 刚保存的编辑，服务端给的 `state`；提示过就清掉。
    var editNotice: String?
    var appealing = false
    /// 刚发的申诉结果；提示过就清掉。
    var appealNotice: FeedAppealResult?
    /// 点开的已发布帖子（信息流 store 里借着的那份）；详情页关了就清掉。
    var openCard: FeedCard?
    /// 正在取详情的那一条（防止连点）。
    var opening: String?

    var deleteFailed: Bool { notice == .deleteFailed }
}

/// 「我的动态」：自己发过的帖子和审核状态（第三节第 24 条、R-2.2；契约 7.3）。
///
/// 和信息流 store 的关系（`feed` 为 nil 时只是单独一页，单测用）：
/// - 删掉自己的帖子（引擎说成了，或者早就没了 404）：`FeedStore.removeCard`，信息流 / 个人页 / 搜索里同一条一起没；
///   别处（详情页）删了，这里也据此去掉那一行。
/// - 点开已发布的帖子：取到的卡片走 `FeedCardMirror.adopt`（换进信息流、借着），详情页画的是信息流里现在的样子。
@MainActor
final class FeedMyPostsStore {
    private let source: FeedSource
    private let feed: FeedStore?
    private let mirror: FeedCardMirror?
    private var tasks = [Task<Void, Never>]()
    private var loadTask: Task<Void, Never>?
    private var loadRunning = false
    /// 删除请求还在路上的帖子：这时候回来的列表（刷新 / 翻页）里还有它，不能又画出来。
    private var deleting = Set<String>()

    private(set) var state = FeedMyPostsState() {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedMyPostsState) -> Void)?

    init(source: FeedSource, feed: FeedStore? = nil) {
        self.source = source
        self.feed = feed
        self.mirror = feed.map { FeedCardMirror(feed: $0) }
        mirror?.shownIds = { [weak self] in
            guard let self else { return [] }
            return Set(self.state.posts.map(\.id) + (self.state.openCard.map { [$0.id] } ?? []))
        }
        mirror?.onChange = { [weak self] in
            self?.syncWithFeed()
        }
    }

    // MARK: - 和信息流 store 同步

    var isObservingFeed: Bool { mirror?.isObserving == true }
    /// 借着的帖子数（单测用）。
    var leaseCount: Int { mirror?.leaseCount ?? 0 }

    /// 页面离开了：不再订阅、放掉借着的卡片。可以重复调用。
    func detach() {
        mirror?.detach()
    }

    /// 别处删了帖子：这里去掉那一行；点开着的那张换成信息流里现在的样子。页面每次出现也调一次（订阅不一定有通知）。
    func syncWithFeed() {
        guard let feed else { return }
        let kept = state.posts.filter { !feed.isRemoved(id: $0.id) }
        if kept.count != state.posts.count { state.posts = kept }
        if let card = state.openCard, let next = mirror?.project([card]).first, next != card {
            state.openCard = next
        }
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
        await mirror?.waitForActions()
    }

    func start() {
        refresh()
        tasks.append(Task { [weak self, source] in
            do {
                let config = try await source.config()
                self?.state.editWindowSeconds = config.limits.editWindowSeconds
            } catch {
                Logger.warn("feed my posts config failed, using the default edit window: \(error)")
            }
        })
    }

    /// 编辑保存后：提示一次（大陆区是「审核通过后替换」），重新拉列表看新的状态。
    func onEdited(publishState: String) {
        state.editNotice = publishState
        refresh()
    }

    func onEditNoticeShown() {
        state.editNotice = nil
    }

    /// 别处让页面该收起（`feed_hidden`）。
    func onFeedHidden() {
        state.feedHidden = true
    }

    private func visible(_ posts: [FeedMyPost]) -> [FeedMyPost] {
        return posts.filter { !deleting.contains($0.id) && feed?.isRemoved(id: $0.id) != true }
    }

    /// 列表请求失败：`feed_hidden` 收起页面；限速带等待秒数；其余记成失败。
    private func listFailed(_ error: Error, firstPage: Bool) {
        let failure = FeedActionFailure.classify(error)
        state.loading = false
        state.refreshing = false
        state.loadingMore = false
        state.loadedOnce = true
        loadRunning = false
        if failure == .feedHidden {
            state.feedHidden = true
            return
        }
        var seconds: Int?
        if case .throttled(let retryAfter) = failure { seconds = retryAfter }
        if firstPage { state.failed = true } else { state.loadMoreFailed = true }
        state.retryAfterSeconds = seconds
    }

    func refresh() {
        loadTask?.cancel()
        state.loading = true
        state.refreshing = state.loadedOnce
        state.loadingMore = false
        state.failed = false
        state.loadMoreFailed = false
        state.retryAfterSeconds = nil
        loadRunning = true
        let task = Task { [weak self, source] in
            do {
                let page = try await source.myPosts(before: nil)
                guard !Task.isCancelled, let self else { return }
                self.state.posts = self.visible(page.posts)
                self.state.nextBefore = page.nextBefore
                self.state.loading = false
                self.state.refreshing = false
                self.state.loadedOnce = true
                self.loadRunning = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                Logger.warn("feed my posts failed: \(error)")
                self.listFailed(error, firstPage: true)
            }
        }
        loadTask = task
        tasks.append(task)
    }

    /// 往下翻（滚到底、或点末尾的「重试」）。
    func loadMore() {
        guard let before = state.nextBefore, !loadRunning, !state.feedHidden else { return }
        state.loadingMore = true
        state.loadMoreFailed = false
        state.retryAfterSeconds = nil
        loadRunning = true
        let task = Task { [weak self, source] in
            do {
                let page = try await source.myPosts(before: before)
                guard !Task.isCancelled, let self else { return }
                let known = Set(self.state.posts.map(\.id))
                self.state.posts += self.visible(page.posts).filter { !known.contains($0.id) }
                self.state.nextBefore = page.nextBefore
                self.state.loadingMore = false
                self.loadRunning = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                Logger.warn("feed my posts page failed: \(error)")
                self.listFailed(error, firstPage: false)
            }
        }
        loadTask = task
        tasks.append(task)
    }

    /// 先从列表里拿掉；成功（或者早就没了 404）：信息流里也去掉。失败放回原位，提示一次。
    func delete(_ post: FeedMyPost) {
        guard let index = state.posts.firstIndex(where: { $0.id == post.id }), !deleting.contains(post.id) else { return }
        deleting.insert(post.id)
        state.posts.removeAll { $0.id == post.id }
        tasks.append(Task { [weak self, source] in
            do {
                try await source.deletePost(contentId: post.id)
            } catch {
                Logger.warn("feed my post delete failed: \(error)")
                guard let self else { return }
                let failure = FeedActionFailure.classify(error)
                if failure == .gone {
                    // 早就删了：和成功一样。
                    self.deleting.remove(post.id)
                    self.feed?.removeCard(id: post.id)
                    return
                }
                self.deleting.remove(post.id)
                var restored = self.state.posts
                restored.insert(post, at: min(index, restored.count))
                self.state.posts = restored
                switch failure {
                case .feedHidden:
                    self.state.feedHidden = true
                case .throttled(let seconds):
                    self.state.notice = .throttled(retryAfterSeconds: seconds)
                default:
                    self.state.notice = .deleteFailed
                }
                return
            }
            guard let self else { return }
            self.deleting.remove(post.id)
            self.feed?.removeCard(id: post.id)
        })
    }

    /// 点开一条已发布的帖子（审核中 / 未通过 / 已撤回的别人看不到，不开）。
    func openPost(_ post: FeedMyPost) {
        guard FeedMyPostRow(post: post).canOpen, state.opening == nil else { return }
        state.opening = post.id
        tasks.append(Task { [weak self, source] in
            let card: FeedCard?
            do {
                card = try await source.card(contentId: post.id)
            } catch {
                Logger.warn("feed my post open failed: \(error)")
                guard let self else { return }
                self.state.opening = nil
                switch FeedActionFailure.classify(error) {
                case .feedHidden:
                    self.state.feedHidden = true
                case .throttled(let seconds):
                    self.state.notice = .throttled(retryAfterSeconds: seconds)
                case .gone:
                    self.state.notice = .postGone
                    self.refresh()
                default:
                    self.state.notice = .failed
                }
                return
            }
            guard let self else { return }
            self.state.opening = nil
            guard let card else {
                self.state.notice = .postGone
                self.refresh()
                return
            }
            let shown: FeedCard
            if let mirror = self.mirror {
                guard let adopted = mirror.adopt([card]).first else {
                    self.state.notice = .postGone
                    self.syncWithFeed()
                    return
                }
                shown = adopted
            } else {
                shown = card
            }
            self.state.openCard = shown
        })
    }

    /// 详情页接手了（自己借着那份卡片）：放掉这里借着的。
    func onCardOpened() {
        state.openCard = nil
        mirror?.releaseAll()
    }

    func onNoticeShown() {
        state.notice = nil
    }

    /// 申诉一次（第三节第 24 条）。成功或引擎说已经申诉过，都把这条标成「复核中」。
    /// 理由去掉首尾空白后最多 500 个 Unicode 码点（引擎 `MaxAppealChars`，按码点数；`FeedTextCap`，不劈开一个字；Android `take` 按 UTF-16 单元，会劈开 emoji）。
    /// 只有未通过且 `appealable` 的才能申诉；已撤回的引擎当前不收（`not_rejected`，引擎侧 A-6），所以界面不给按钮，这里也不发请求。
    func appeal(_ post: FeedMyPost, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || state.appealing { return }
        guard post.state == FeedMyPost.stateRejected, post.appealable, post.appealState == nil else { return }
        state.appealing = true
        let reason = FeedTextCap.cap(trimmed, codePoints: FeedMyPost.maxAppealChars)
        tasks.append(Task { [weak self, source] in
            let result: FeedAppealResult
            var stale = false
            do {
                try await source.appeal(contentId: post.id, text: reason)
                result = .sent
            } catch {
                Logger.warn("feed appeal failed: \(error)")
                let code = (error as? FeedAPIError)?.code
                let failure = FeedActionFailure.classify(error)
                if code == "already_appealed" {
                    result = .already
                } else if code == "not_rejected" {
                    result = .notRejected
                    stale = true
                } else if case .throttled(let seconds) = failure {
                    result = .throttled(retryAfterSeconds: seconds)
                } else if failure == .feedHidden {
                    guard let self else { return }
                    self.state.appealing = false
                    self.state.feedHidden = true
                    return
                } else {
                    result = .failed
                    stale = failure == .gone
                }
            }
            guard let self else { return }
            if result == .sent || result == .already {
                self.state.posts = self.state.posts.map { item in
                    guard item.id == post.id else { return item }
                    var marked = item
                    marked.appealable = false
                    marked.appealState = FeedMyPost.appealReceived
                    return marked
                }
            }
            self.state.appealing = false
            self.state.appealNotice = result
            if stale { self.refresh() }
        })
    }

    func onAppealNoticeShown() {
        state.appealNotice = nil
    }

    func onDeleteFailureShown() {
        if state.notice == .deleteFailed { state.notice = nil }
    }
}
