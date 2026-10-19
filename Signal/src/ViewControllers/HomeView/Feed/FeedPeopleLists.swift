//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

// 名单页（`dynamic-feed.md` 第三节第 29、42、44 条，和 Android `FeedPeopleViewModel` / `FeedClosePeopleViewModel` 同一套行为）：
// 关注请求、屏蔽名单、「不看 TA 的动态」、「不让 TA 看我的动态」四张名单共用一个页面（按 `FeedPeopleMode` 换数据和按钮），
// 「关心的人」另有一个页面（搜人、最多 3 个、回应设了我的人）。
// 处理完的一行先从名单里拿掉，引擎说不行再放回去；对方已经撤回（404）就当处理完了。

enum FeedPeopleMode: Equatable, CaseIterable {
    /// 别人想关注我的私密账号：同意 / 拒绝。
    case followRequests
    /// 我在动态里屏蔽的作者、来源、话题：取消屏蔽。
    case blocked
    /// 「不看 TA 的动态」：移出。
    case muted
    /// 「不让 TA 看我的动态」：移出。
    case hiddenFrom

    /// 对应的引擎名单（`/v1/feed/me/hide-lists/{list}`）；另外两种不是。
    var hideList: String? {
        switch self {
        case .muted: return FeedAPI.hideMute
        case .hiddenFrom: return FeedAPI.hideFrom
        case .followRequests, .blocked: return nil
        }
    }
}

/// 名单里的一行。屏蔽来源 / 话题时没有 `person`，只有 `block`。
struct FeedPeopleRow: Equatable {
    var key: String
    var person: FeedPersonSummary?
    var block: FeedBlockEntry?

    /// 界面上这一行写什么：人用名字（和 ID），屏蔽的来源 / 话题 / 不认识的类型各自一种。
    enum Display: Equatable {
        case person(name: String, handle: String?, avatarKey: String?)
        case source(String)
        case topic(String)
        case other(String)
    }

    var display: Display {
        if let block {
            switch block.type {
            case FeedAPI.targetAuthor:
                if let profile = block.profile ?? person {
                    return .person(name: profile.displayName, handle: profile.handle, avatarKey: profile.avatarKey)
                }
                return .other(block.id)
            case "source":
                return .source(block.id)
            case FeedAPI.targetTopic:
                return .topic(block.id)
            default:
                return .other(block.id)
            }
        }
        if let person {
            return .person(name: person.displayName, handle: person.handle, avatarKey: person.avatarKey)
        }
        return .other(key)
    }

    static func followRequest(_ request: FeedFollowRequest) -> FeedPeopleRow {
        return FeedPeopleRow(key: request.profile.id, person: request.profile)
    }

    static func block(_ entry: FeedBlockEntry) -> FeedPeopleRow {
        return FeedPeopleRow(key: "\(entry.type)/\(entry.id)", person: entry.profile, block: entry)
    }

    static func listed(_ person: FeedPersonSummary) -> FeedPeopleRow {
        return FeedPeopleRow(key: person.id, person: person)
    }
}

enum FeedPeopleNotice: Equatable {
    case approved
    case declined
    case unblocked
    case removed
    case failed
    case throttled(retryAfterSeconds: Int?)
}

struct FeedPeopleState: Equatable {
    var loading = false
    /// 读过一次了（不管成没成功）：之前是「还没读」，界面不要先说「没有」。
    var loadedOnce = false
    var failed = false
    var retryAfterSeconds: Int?
    var rows = [FeedPeopleRow]()
    var notice: FeedPeopleNotice?
    /// 引擎说动态被关了（404 `feed_hidden`）：页面该收起。
    var feedHidden = false
}

@MainActor
final class FeedPeopleStore {
    let mode: FeedPeopleMode
    private let source: FeedSource
    private var tasks = [Task<Void, Never>]()
    private var acting = Set<String>()
    private var generation = 0

    private(set) var state = FeedPeopleState() {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedPeopleState) -> Void)?

    init(mode: FeedPeopleMode, source: FeedSource) {
        self.mode = mode
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
    }

    func refresh() {
        generation += 1
        let current = generation
        var next = state
        next.loading = true
        next.failed = false
        state = next
        tasks.append(Task { [weak self, source, mode] in
            do {
                let rows: [FeedPeopleRow]
                switch mode {
                case .followRequests:
                    rows = try await source.followRequests().map(FeedPeopleRow.followRequest)
                case .blocked:
                    rows = try await source.blocks().map(FeedPeopleRow.block)
                case .muted:
                    rows = try await source.hideLists().mute.map(FeedPeopleRow.listed)
                case .hiddenFrom:
                    rows = try await source.hideLists().hideFrom.map(FeedPeopleRow.listed)
                }
                guard let self, self.generation == current else { return }
                var next = self.state
                next.rows = rows.filter { !self.acting.contains($0.key) }
                next.loading = false
                next.loadedOnce = true
                next.failed = false
                next.retryAfterSeconds = nil
                self.state = next
            } catch {
                Logger.warn("feed people list failed: \(error)")
                guard let self, self.generation == current else { return }
                self.listFailed(error)
            }
        })
    }

    private func listFailed(_ error: Error) {
        var next = state
        next.loading = false
        next.loadedOnce = true
        let failure = FeedActionFailure.classify(error)
        if failure == .feedHidden {
            next.feedHidden = true
        } else {
            next.failed = true
            if case .throttled(let seconds) = failure { next.retryAfterSeconds = seconds }
        }
        state = next
    }

    // MARK: - 动作

    /// 同意或拒绝一条关注请求。
    func answer(_ row: FeedPeopleRow, approve: Bool) {
        guard mode == .followRequests, let person = row.person else { return }
        act(row, done: approve ? .approved : .declined) { [source] in
            try await source.answerFollowRequest(profileId: person.id, approve: approve)
        }
    }

    /// 取消屏蔽（名单里的一项可以是作者、来源或话题）。
    func unblock(_ row: FeedPeopleRow) {
        guard mode == .blocked, let entry = row.block else { return }
        act(row, done: .unblocked) { [source] in
            try await source.unblock(entry)
        }
    }

    /// 从「不看 TA」或「不让 TA 看」名单里移出。
    func remove(_ row: FeedPeopleRow) {
        guard let list = mode.hideList, let person = row.person else { return }
        act(row, done: .removed) { [source] in
            try await source.setHideList(list: list, profileId: person.id, on: false)
        }
    }

    func onNoticeShown() {
        state.notice = nil
    }

    private func act(_ row: FeedPeopleRow, done: FeedPeopleNotice, _ call: @escaping () async throws -> Void) {
        guard !acting.contains(row.key), let index = state.rows.firstIndex(where: { $0.key == row.key }) else { return }
        acting.insert(row.key)
        var next = state
        next.rows.remove(at: index)
        state = next
        tasks.append(Task { [weak self] in
            do {
                try await call()
                self?.finished(row, notice: done)
            } catch {
                Logger.warn("feed people action failed: \(error)")
                self?.actionFailed(row, index: index, error: error, done: done)
            }
        })
    }

    private func finished(_ row: FeedPeopleRow, notice: FeedPeopleNotice) {
        acting.remove(row.key)
        state.notice = notice
    }

    private func actionFailed(_ row: FeedPeopleRow, index: Int, error: Error, done: FeedPeopleNotice) {
        let failure = FeedActionFailure.classify(error)
        if failure == .gone {
            // 对方已经撤回 / 已经不在名单里：和成功一样
            finished(row, notice: done)
            return
        }
        acting.remove(row.key)
        var next = state
        if failure == .feedHidden {
            next.feedHidden = true
        } else {
            if !next.rows.contains(where: { $0.key == row.key }) {
                next.rows.insert(row, at: min(index, next.rows.count))
            }
            if case .throttled(let seconds) = failure {
                next.notice = .throttled(retryAfterSeconds: seconds)
            } else {
                next.notice = .failed
            }
        }
        state = next
    }
}

// MARK: - 关心的人

enum FeedClosePeopleNotice: Equatable {
    case added
    case full
    case profileRequired
    case notAllowed
    case failed
    case throttled(retryAfterSeconds: Int?)
}

struct FeedClosePeopleState: Equatable {
    var loading = false
    var loadedOnce = false
    var failed = false
    var retryAfterSeconds: Int?
    var mine = [FeedClosePersonEntry]()
    var requests = [FeedClosePersonEntry]()
    var query = ""
    var results = [FeedSearchUser]()
    var searching = false
    var adding = false
    var notice: FeedClosePeopleNotice?
    var feedHidden = false

    var canAdd: Bool { mine.count < FeedClosePersonEntry.max }

    /// 搜索结果里去掉已经设了的人。
    var addableResults: [FeedSearchUser] {
        return results.filter { user in !mine.contains { $0.id == user.id } }
    }
}

/// 「关心的人」（第三节第 42 条）：最多设 3 个，对方同意后才在我的主页上显示；也在这里回应设了我的人。
/// 加人靠搜 ID 或名字（和动态搜索的「用户」一样，只搜得到设了 ID 的人）。移除、回应都先在界面上改过去，失败再改回来。
@MainActor
final class FeedClosePeopleStore {
    private let source: FeedSource
    private let debounceNanos: UInt64
    private var tasks = [Task<Void, Never>]()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var refreshGeneration = 0

    private(set) var state = FeedClosePeopleState() {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedClosePeopleState) -> Void)?

    init(source: FeedSource, debounceNanos: UInt64 = 350_000_000) {
        self.source = source
        self.debounceNanos = debounceNanos
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
        await searchTask?.value
    }

    func start() {
        refresh()
    }

    func refresh() {
        refreshGeneration += 1
        let current = refreshGeneration
        var next = state
        next.loading = true
        next.failed = false
        state = next
        tasks.append(Task { [weak self, source] in
            do {
                let response = try await source.closePeople()
                guard let self, self.refreshGeneration == current else { return }
                var next = self.state
                next.loading = false
                next.loadedOnce = true
                next.mine = response.mine
                next.requests = response.requests
                self.state = next
            } catch {
                Logger.warn("feed close people failed: \(error)")
                guard let self, self.refreshGeneration == current else { return }
                var next = self.state
                next.loading = false
                next.loadedOnce = true
                let failure = FeedActionFailure.classify(error)
                if failure == .feedHidden {
                    next.feedHidden = true
                } else {
                    next.failed = true
                    if case .throttled(let seconds) = failure { next.retryAfterSeconds = seconds }
                }
                self.state = next
            }
        })
    }

    // MARK: - 搜人

    func onQueryChanged(_ query: String) {
        searchGeneration += 1
        let current = searchGeneration
        searchTask?.cancel()
        searchTask = nil
        var next = state
        next.query = query
        let trimmed = Self.searchTerm(query)
        if trimmed.isEmpty {
            next.results = []
            next.searching = false
            state = next
            return
        }
        next.searching = true
        state = next
        searchTask = Task { [weak self, source, debounceNanos] in
            if debounceNanos > 0 { try? await Task.sleep(nanoseconds: debounceNanos) }
            if Task.isCancelled { return }
            do {
                let users = try await source.search(query: trimmed, scope: FeedAPI.searchUsers, cursor: nil).users
                guard let self, self.searchGeneration == current else { return }
                var next = self.state
                next.searching = false
                next.results = users
                self.state = next
            } catch {
                Logger.warn("feed close people search failed: \(error)")
                guard let self, self.searchGeneration == current else { return }
                var next = self.state
                next.searching = false
                next.results = []
                self.state = next
            }
        }
    }

    /// 搜索词：首尾空白去掉，最长 `FeedAPI.searchMaxQuery`（和动态搜索一样）。
    nonisolated static func searchTerm(_ query: String) -> String {
        return String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(FeedAPI.searchMaxQuery))
    }

    // MARK: - 动作

    func add(_ user: FeedSearchUser) {
        let current = state
        if current.adding || !current.canAdd || current.mine.contains(where: { $0.id == user.id }) { return }
        var next = current
        next.adding = true
        state = next
        tasks.append(Task { [weak self, source] in
            do {
                let result = try await source.addClosePerson(profileId: user.id)
                guard let self else { return }
                self.searchGeneration += 1
                self.searchTask?.cancel()
                var next = self.state
                next.adding = false
                if !next.mine.contains(where: { $0.id == user.id }) {
                    next.mine.append(FeedClosePersonEntry(id: user.id, displayName: user.displayName, avatarKey: user.avatarKey, state: result))
                }
                next.query = ""
                next.results = []
                next.searching = false
                next.notice = .added
                self.state = next
            } catch {
                Logger.warn("feed close people add failed: \(error)")
                guard let self else { return }
                var next = self.state
                next.adding = false
                let failure = FeedActionFailure.classify(error)
                if let api = error as? FeedAPIError, api.status == 409, api.code == "close_people_full" {
                    next.notice = .full
                } else {
                    switch failure {
                    case .profileRequired: next.notice = .profileRequired
                    case .gone: next.notice = .notAllowed
                    case .throttled(let seconds): next.notice = .throttled(retryAfterSeconds: seconds)
                    case .feedHidden: next.feedHidden = true
                    case .failed: next.notice = .failed
                    }
                }
                self.state = next
            }
        })
    }

    func remove(_ entry: FeedClosePersonEntry) {
        guard let index = state.mine.firstIndex(where: { $0.id == entry.id }) else { return }
        var next = state
        next.mine.remove(at: index)
        state = next
        tasks.append(Task { [weak self, source] in
            do {
                try await source.removeClosePerson(profileId: entry.id)
            } catch {
                if FeedActionFailure.classify(error) == .gone { return }
                Logger.warn("feed close people remove failed: \(error)")
                guard let self else { return }
                var next = self.state
                if !next.mine.contains(where: { $0.id == entry.id }) {
                    next.mine.insert(entry, at: min(index, next.mine.count))
                }
                next.notice = Self.notice(for: error, fallback: .failed)
                if FeedActionFailure.classify(error) == .feedHidden { next.notice = nil; next.feedHidden = true }
                self.state = next
            }
        })
    }

    /// 同意，或者拒绝 / 撤回已经同意的。
    func answer(_ entry: FeedClosePersonEntry, accept: Bool) {
        let before = state.requests
        guard before.contains(where: { $0.id == entry.id }) else { return }
        var next = state
        if accept {
            next.requests = before.map { item in
                var item = item
                if item.id == entry.id { item.state = FeedClosePersonEntry.stateAccepted }
                return item
            }
        } else {
            next.requests = before.filter { $0.id != entry.id }
        }
        state = next
        tasks.append(Task { [weak self, source] in
            do {
                try await source.answerClosePerson(ownerProfileId: entry.id, accept: accept)
            } catch {
                if FeedActionFailure.classify(error) == .gone { return }
                Logger.warn("feed close people answer failed: \(error)")
                guard let self else { return }
                var next = self.state
                next.requests = before
                if FeedActionFailure.classify(error) == .feedHidden {
                    next.feedHidden = true
                } else {
                    next.notice = Self.notice(for: error, fallback: .failed)
                }
                self.state = next
            }
        })
    }

    func onNoticeShown() {
        state.notice = nil
    }

    private static func notice(for error: Error, fallback: FeedClosePeopleNotice) -> FeedClosePeopleNotice {
        if case .throttled(let seconds) = FeedActionFailure.classify(error) {
            return .throttled(retryAfterSeconds: seconds)
        }
        return fallback
    }
}

// MARK: - 入口

/// 名单入口页（设置里的一行、「我的动态」右上角进来）：每一行去哪个页面。顺序和 Android 一致：先处理别人的请求，再是我设的名单。
enum FeedListsEntry: Equatable, CaseIterable {
    case followRequests
    case muted
    case hiddenFrom
    case blocked
    case closePeople

    /// 前四个是 `FeedPeopleViewController` 的四种模式；「关心的人」是自己的页面。
    var peopleMode: FeedPeopleMode? {
        switch self {
        case .followRequests: return .followRequests
        case .muted: return .muted
        case .hiddenFrom: return .hiddenFrom
        case .blocked: return .blocked
        case .closePeople: return nil
        }
    }
}
