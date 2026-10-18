//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedSearch.swift (new file)
// Search (people + posts), search history (phone only), followed topics API, FeedSearchStore (I-8).
// Mirror of Android `search/FeedSearchViewModel.kt`, `search/FeedSearchHistory.kt`, `FeedApi.search/followedTopics`,
// and `FeedSearchResponse` / `FeedSearchUser` / `FeedSearchPage` / `FeedFollowedTopics` in `FeedModels.kt`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

// MARK: - 模型

/// 搜出来的一个人。`badge` 是引擎给的徽标（官方等），界面决定怎么画。
struct FeedSearchUser: Decodable, Equatable {
    var id: String
    var handle: String?
    var displayName: String
    var avatarKey: String?
    var badge: String?

    init(id: String, displayName: String, handle: String? = nil, avatarKey: String? = nil, badge: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.avatarKey = avatarKey
        self.badge = badge
    }

    func asPerson() -> FeedPersonSummary {
        FeedPersonSummary(id: id, handle: handle, displayName: displayName, avatarKey: avatarKey)
    }

    private enum CodingKeys: String, CodingKey {
        case id, handle, badge
        case displayName = "display_name"
        case avatarKey = "avatar_key"
    }
}

/// `GET /v1/feed/search`：人在 `users`，帖子是和时间线一样的 `items`（还要用 Card API 换成卡片）。
struct FeedSearchResponse: Decodable, Equatable {
    var users = [FeedSearchUser]()
    var items = [FeedItemRef]()
    var cursor: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        users = (try c.decodeIfPresent([Lossy<FeedSearchUser>].self, forKey: .users) ?? []).compactMap(\.value)
        items = try c.decodeIfPresent([FeedItemRef].self, forKey: .items) ?? []
        cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    }

    private enum CodingKeys: String, CodingKey { case users, items, cursor }
}

/// 界面用的一页搜索结果：帖子已经换成卡片。
struct FeedSearchPage: Equatable {
    var users = [FeedSearchUser]()
    var posts = [FeedCard]()
    var cursor: String?
}

/// `GET /v1/feed/me/followed-topics`：我关注的话题，最近关注的在前。
struct FeedFollowedTopics: Decodable, Equatable {
    var topics = [FeedFollowedTopic]()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topics = (try c.decodeIfPresent([Lossy<FeedFollowedTopic>].self, forKey: .topics) ?? []).compactMap(\.value)
    }

    private enum CodingKeys: String, CodingKey { case topics }
}

struct FeedFollowedTopic: Decodable, Equatable {
    var slug: String
    var followedAt: String?

    private enum CodingKeys: String, CodingKey {
        case slug
        case followedAt = "followed_at"
    }
}

extension FeedAPI {
    static let searchAll = "all"
    static let searchUsers = "users"
    static let searchPosts = "posts"
    /// 搜索词最长字数（Android `take(50)`，数 UTF-16 单位；这里数 Character，不会把一个 emoji 切开）。
    static let searchMaxQuery = FeedInputLimit.searchQuery
    static let targetTopic = "topic"

    /// 搜人和帖子（`scope` 是上面三个）。帖子一页 10 条，带 `cursor` 翻页。
    func search(query: String, scope: String, cursor: String?) async throws -> FeedSearchResponse {
        var items = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "scope", value: scope)]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await send(FeedSearchResponse.self, request(path: ["v1", "feed", "search"], query: items))
    }

    func followedTopics() async throws -> FeedFollowedTopics {
        return try await send(FeedFollowedTopics.self, request(path: ["v1", "feed", "me", "followed-topics"]))
    }
}

// MARK: - 搜索历史（只在手机上）

/// 搜索历史和「最近看过的人」。只在手机上（第三节第 34 条），服务端不记。
protocol FeedSearchHistory: AnyObject {
    static var maxQueries: Int { get }
    static var maxPeople: Int { get }

    func queries() -> [String]
    func addQuery(_ query: String)
    func removeQuery(_ query: String)
    func clearQueries()
    func people() -> [FeedPersonSummary]
    func addPerson(_ person: FeedPersonSummary)
    func clearPeople()
}

/// 存起来的「最近看过的人」（`FeedPersonSummary` 只解不编，这里单独一份能编能解的）。
struct FeedRecentPerson: Codable, Equatable {
    var id: String
    var handle: String?
    var displayName: String
    var avatarKey: String?

    init(_ person: FeedPersonSummary) {
        id = person.id
        handle = person.handle
        displayName = person.displayName
        avatarKey = person.avatarKey
    }

    var person: FeedPersonSummary { FeedPersonSummary(id: id, handle: handle, displayName: displayName, avatarKey: avatarKey) }
}

/// 纯内存的一份，给测试和样例用。
class InMemoryFeedSearchHistory: FeedSearchHistory {
    static var maxQueries: Int { 20 }
    static var maxPeople: Int { 10 }

    fileprivate(set) var queryList = [String]()
    fileprivate(set) var peopleList = [FeedPersonSummary]()

    init() {}

    func queries() -> [String] { queryList }

    func addQuery(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return }
        // 同一个词（不分大小写）只留最新的一个
        queryList = Array(([q] + queryList.filter { $0.caseInsensitiveCompare(q) != .orderedSame }).prefix(Self.maxQueries))
        changed()
    }

    func removeQuery(_ query: String) {
        queryList = queryList.filter { $0 != query }
        changed()
    }

    func clearQueries() {
        queryList = []
        changed()
    }

    func people() -> [FeedPersonSummary] { peopleList }

    func addPerson(_ person: FeedPersonSummary) {
        peopleList = Array(([person] + peopleList.filter { $0.id != person.id }).prefix(Self.maxPeople))
        changed()
    }

    func clearPeople() {
        peopleList = []
        changed()
    }

    func changed() {}
}

/// 存在本机，**不进 iCloud / iTunes 备份**（tellomi测试 2026-10-16 定；和 Android 的 `SignalStore` 一致）：
/// 传 `FeedLocalStorages.backupExcluded`（`I-18/`）。旧版放在 `UserDefaults` 里的由 `FeedStorageMigration` 搬过来。
final class StoredFeedSearchHistory: InMemoryFeedSearchHistory {
    static let queriesKey = "tellomiFeedSearchQueries"
    static let peopleKey = "tellomiFeedSearchPeople"

    private let storage: FeedLocalStorage

    /// 故意没有默认值：不要回到会进备份的 `UserDefaults`。
    init(storage: FeedLocalStorage) {
        self.storage = storage
        super.init()
        // 存坏了就当没有（Android：捕获异常 → emptyList）
        if let data = storage.data(forKey: Self.queriesKey), let list = try? JSONDecoder().decode([String].self, from: data) {
            queryList = list
        }
        if let data = storage.data(forKey: Self.peopleKey), let list = try? JSONDecoder().decode([FeedRecentPerson].self, from: data) {
            peopleList = list.map(\.person)
        }
    }

    override func changed() {
        if queryList.isEmpty {
            storage.removeValue(forKey: Self.queriesKey)
        } else if let data = try? JSONEncoder().encode(queryList) {
            storage.set(data, forKey: Self.queriesKey)
        }
        if peopleList.isEmpty {
            storage.removeValue(forKey: Self.peopleKey)
        } else if let data = try? JSONEncoder().encode(peopleList.map(FeedRecentPerson.init)) {
            storage.set(data, forKey: Self.peopleKey)
        }
    }
}

// MARK: - 搜索页

/// 一次搜索的结果，记着是哪个词、哪个范围搜出来的。
struct FeedSearchResults: Equatable {
    var query: String
    var scope: String
    var users = [FeedSearchUser]()
    var posts = [FeedCard]()
    var cursor: String?
}

struct FeedSearchState: Equatable {
    enum Notice: Equatable {
        case saved
        case reposted
        case failed
    }

    var query = ""
    var scope = FeedAPI.searchAll
    var results: FeedSearchResults?
    var loading = false
    var loadingMore = false
    var failed = false
    var recentQueries = [String]()
    var recentPeople = [FeedPersonSummary]()
    var notice: Notice?
}

/// 动态搜索（第三节第 34 条）。边打边搜（停 `debounceNanos` 再发）；按键盘「搜索」或点开结果才记进本机最近搜索。
/// 范围：全部（5 个人 + 帖子）/ 用户（20 个人）/ 动态（帖子翻页）。
@MainActor
final class FeedSearchStore {
    private let source: FeedSource
    private let history: FeedSearchHistory
    private let savedMessages: FeedSavedMessages?
    private let sleep: (UInt64) async throws -> Void
    private let debounceNanos: UInt64

    private(set) var state: FeedSearchState {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedSearchState) -> Void)?

    private var tasks = [Task<Void, Never>]()
    private var searchTask: Task<Void, Never>?
    private var saving = FeedInFlight()
    private var reposting = FeedInFlight()

    init(
        source: FeedSource,
        history: FeedSearchHistory,
        savedMessages: FeedSavedMessages? = nil,
        debounceNanos: UInt64 = 350_000_000,
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.source = source
        self.history = history
        self.savedMessages = savedMessages
        self.debounceNanos = debounceNanos
        self.sleep = sleep
        state = FeedSearchState(recentQueries: history.queries(), recentPeople: history.people())
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
    }

    func onQueryChange(_ query: String) {
        let clipped = FeedTextCap.cap(query, codePoints: FeedAPI.searchMaxQuery)   // 码点数，和引擎 `MaxSearchChars` 一致（FeedTextCap）
        state.query = clipped
        if clipped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchTask?.cancel()
            state.results = nil
            state.loading = false
            state.failed = false
        } else {
            search(debounce: true)
        }
    }

    /// 键盘上的「搜索」。
    func submit() {
        let q = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return }
        rememberQuery(q)
        search(debounce: false)
    }

    func selectScope(_ scope: String) {
        if scope == state.scope { return }
        state.scope = scope
        if !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search(debounce: false) }
    }

    func useRecentQuery(_ query: String) {
        state.query = query
        submit()
    }

    func removeRecentQuery(_ query: String) {
        history.removeQuery(query)
        state.recentQueries = history.queries()
    }

    func clearRecentQueries() {
        history.clearQueries()
        state.recentQueries = history.queries()
    }

    func clearRecentPeople() {
        history.clearPeople()
        state.recentPeople = history.people()
    }

    /// 点开一个人：记进「最近看过的人」和最近搜索。
    func onPersonOpened(_ person: FeedPersonSummary) {
        history.addPerson(person)
        rememberCurrentQuery()
        state.recentPeople = history.people()
    }

    func onPostOpened() {
        rememberCurrentQuery()
    }

    func loadMore() {
        guard let results = state.results, let cursor = results.cursor else { return }
        if state.loading || state.loadingMore { return }
        let query = results.query
        let scope = results.scope
        state.loadingMore = true
        let task = Task { [weak self, source] in
            do {
                let page = try await source.search(query: query, scope: scope, cursor: cursor)
                guard !Task.isCancelled, let self else { return }
                self.state.loadingMore = false
                guard var current = self.state.results, current.query == query, current.scope == scope else { return }
                let known = Set(current.posts.map(\.id))
                current.posts += page.posts.filter { !known.contains($0.id) }
                current.cursor = page.cursor
                self.state.results = current
            } catch {
                guard !Task.isCancelled else { return }
                Logger.warn("feed search more failed: \(error)")
                self?.state.loadingMore = false
            }
        }
        searchTask = task
        tasks.append(task)
    }

    func retry() {
        if !state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search(debounce: false) }
    }

    // MARK: - 结果里的卡片

    func toggleLike(_ card: FeedCard) {
        let nowLiked = !card.viewer.liked
        updatePost(card.id) { FeedStore.withLiked($0, nowLiked) }
        tasks.append(Task { [weak self, source] in
            do {
                try await source.setLiked(contentId: card.id, liked: nowLiked)
            } catch {
                Logger.warn("feed search like failed: \(error)")
                self?.updatePost(card.id) { FeedStore.withLiked($0, !nowLiked) }
            }
        })
    }

    func toggleSave(_ card: FeedCard) {
        guard saving.begin(card.id) else { return }
        let nowSaved = !card.viewer.saved
        updatePost(card.id) { $0.withSaved(nowSaved) }
        tasks.append(Task { [weak self, source, savedMessages] in
            do {
                guard let savedMessages else { throw FeedPublishError.feedNotAvailable }
                try await FeedSaveFlow.setSaved(card, saved: nowSaved, savedMessages: savedMessages, source: source) {
                    Logger.warn("feed save report failed: \($0)")
                }
                self?.saving.end(card.id)
                if nowSaved { self?.state.notice = .saved }
            } catch {
                Logger.warn("feed search save failed: \(error)")
                self?.saving.end(card.id)
                self?.updatePost(card.id) { $0.withSaved(!nowSaved) }
                self?.state.notice = .failed
            }
        })
    }

    func toggleRepost(_ card: FeedCard) {
        guard reposting.begin(card.id) else { return }
        let nowReposted = !card.viewer.reposted
        updatePost(card.id) { $0.withReposted(nowReposted) }
        tasks.append(Task { [weak self, source] in
            do {
                try await source.setReposted(contentId: card.id, reposted: nowReposted)
                self?.reposting.end(card.id)
                if nowReposted { self?.state.notice = .reposted }
            } catch {
                Logger.warn("feed search repost failed: \(error)")
                self?.reposting.end(card.id)
                self?.updatePost(card.id) { $0.withReposted(!nowReposted) }
                self?.state.notice = .failed
            }
        })
    }

    func onNoticeShown() {
        state.notice = nil
    }

    // MARK: - 内部

    private func search(debounce: Bool) {
        searchTask?.cancel()
        let query = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = state.scope
        if query.isEmpty { return }
        state.loading = true
        state.failed = false
        state.loadingMore = false
        let nanos = debounceNanos
        let task = Task { [weak self, source, sleep] in
            if debounce {
                do { try await sleep(nanos) } catch { return }
                if Task.isCancelled { return }
            }
            do {
                let page = try await source.search(query: query, scope: scope, cursor: nil)
                // 又打了字 / 换了范围：这一份已经过期，别盖掉新的
                guard !Task.isCancelled, let self else { return }
                self.state.loading = false
                self.state.results = FeedSearchResults(query: query, scope: scope, users: page.users, posts: page.posts, cursor: page.cursor)
            } catch {
                guard !Task.isCancelled else { return }
                Logger.warn("feed search failed: \(error)")
                self?.state.loading = false
                self?.state.failed = true
            }
        }
        searchTask = task
        tasks.append(task)
    }

    private func rememberCurrentQuery() {
        let q = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { rememberQuery(q) }
    }

    private func rememberQuery(_ query: String) {
        history.addQuery(query)
        state.recentQueries = history.queries()
    }

    private func updatePost(_ id: String, _ change: (FeedCard) -> FeedCard) {
        guard var results = state.results else { return }
        results.posts = results.posts.map { $0.id == id ? change($0) : $0 }
        state.results = results
    }
}
