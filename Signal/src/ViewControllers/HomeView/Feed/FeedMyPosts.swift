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
    case failed
}

struct FeedMyPostsState: Equatable {
    var posts = [FeedMyPost]()
    var nextBefore: String?
    var loading = true
    var loadedOnce = false
    /// 下拉刷新中（已经有内容时）；翻页不算。
    var refreshing = false
    var failed = false
    var deleteFailed = false
    /// 发布后多久内能改（config `limits.edit_window_seconds`）。
    var editWindowSeconds = 900
    /// 刚保存的编辑，服务端给的 `state`；提示过就清掉。
    var editNotice: String?
    var appealing = false
    /// 刚发的申诉结果；提示过就清掉。
    var appealNotice: FeedAppealResult?
}

/// 「我的动态」：自己发过的帖子和审核状态（第三节第 24 条、R-2.2；契约 7.3）。
@MainActor
final class FeedMyPostsStore {
    private let source: FeedSource
    private var tasks = [Task<Void, Never>]()
    private var loadTask: Task<Void, Never>?
    private var loadRunning = false

    private(set) var state = FeedMyPostsState() {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedMyPostsState) -> Void)?

    init(source: FeedSource) {
        self.source = source
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
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

    func refresh() {
        loadTask?.cancel()
        state.loading = true
        state.refreshing = state.loadedOnce
        state.failed = false
        loadRunning = true
        let task = Task { [weak self, source] in
            do {
                let page = try await source.myPosts(before: nil)
                guard !Task.isCancelled, let self else { return }
                self.state.posts = page.posts
                self.state.nextBefore = page.nextBefore
                self.state.loading = false
                self.state.refreshing = false
                self.state.loadedOnce = true
                self.loadRunning = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                Logger.warn("feed my posts failed: \(error)")
                self.state.loading = false
                self.state.refreshing = false
                self.state.failed = true
                self.state.loadedOnce = true
                self.loadRunning = false
            }
        }
        loadTask = task
        tasks.append(task)
    }

    func loadMore() {
        guard let before = state.nextBefore, !loadRunning else { return }
        state.loading = true
        loadRunning = true
        let task = Task { [weak self, source] in
            do {
                let page = try await source.myPosts(before: before)
                guard !Task.isCancelled, let self else { return }
                let known = Set(self.state.posts.map(\.id))
                self.state.posts += page.posts.filter { !known.contains($0.id) }
                self.state.nextBefore = page.nextBefore
                self.state.loading = false
                self.loadRunning = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                Logger.warn("feed my posts page failed: \(error)")
                self.state.loading = false
                self.loadRunning = false
            }
        }
        loadTask = task
        tasks.append(task)
    }

    /// 先从列表里拿掉；删失败放回原位，提示一次。
    func delete(_ post: FeedMyPost) {
        guard let index = state.posts.firstIndex(where: { $0.id == post.id }) else { return }
        state.posts.removeAll { $0.id == post.id }
        tasks.append(Task { [weak self, source] in
            do {
                try await source.deletePost(contentId: post.id)
            } catch {
                Logger.warn("feed my post delete failed: \(error)")
                guard let self else { return }
                var restored = self.state.posts
                restored.insert(post, at: min(index, restored.count))
                self.state.posts = restored
                self.state.deleteFailed = true
            }
        })
    }

    /// 申诉一次（第三节第 24 条）。成功或引擎说已经申诉过，都把这条标成「复核中」。
    /// 理由去掉首尾空白后最多 500 个 Unicode 码点（引擎 `MaxAppealChars`，按码点数；`FeedTextCap`，不劈开一个字；Android `take` 按 UTF-16 单元，会劈开 emoji）。
    func appeal(_ post: FeedMyPost, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || state.appealing { return }
        state.appealing = true
        let reason = FeedTextCap.cap(trimmed, codePoints: FeedMyPost.maxAppealChars)
        tasks.append(Task { [weak self, source] in
            let result: FeedAppealResult
            do {
                try await source.appeal(contentId: post.id, text: reason)
                result = .sent
            } catch {
                Logger.warn("feed appeal failed: \(error)")
                result = (error as? FeedAPIError)?.code == "already_appealed" ? .already : .failed
            }
            guard let self else { return }
            if result != .failed {
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
        })
    }

    func onAppealNoticeShown() {
        state.appealNotice = nil
    }

    func onDeleteFailureShown() {
        state.deleteFailed = false
    }
}
