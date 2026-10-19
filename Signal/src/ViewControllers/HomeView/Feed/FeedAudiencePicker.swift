//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 选人页里的一个人：本机的 recipient id（回到发布页、再打开选人页时预先勾上）、ACI（找 Signal-Server 签名单用）、名字。
struct FeedAudienceCandidate: Equatable {
    var recipientId: Int64
    var aci: String
    var displayName: String

    var member: FeedAudienceMember {
        return FeedAudienceMember(recipientId: recipientId, aci: aci)
    }
}

/// 谁可以被选进「部分可见 / 不给谁看」（第三节第 39 条）：本机的好友（通讯录里的 Signal 用户 + 聊天里接受过的人）。
/// 真实现要读本机数据库，等「好友是谁」的口径定了再接（见报告「需要 erel 决定」）；在那之前发布页拿到的是 nil，
/// 这两档照旧显示「还不能选」。样例源和单测用 `StaticFeedAudienceCandidates`。
protocol FeedAudienceCandidateSource: AnyObject {
    func candidates() async throws -> [FeedAudienceCandidate]
}

final class StaticFeedAudienceCandidates: FeedAudienceCandidateSource {
    private let list: [FeedAudienceCandidate]
    private let error: Error?
    private let latencyNanos: UInt64

    init(_ list: [FeedAudienceCandidate], error: Error? = nil, latencyNanos: UInt64 = 0) {
        self.list = list
        self.error = error
        self.latencyNanos = latencyNanos
    }

    func candidates() async throws -> [FeedAudienceCandidate] {
        if latencyNanos > 0 { try? await Task.sleep(nanoseconds: latencyNanos) }
        if let error { throw error }
        return list
    }
}

struct FeedAudiencePickerState: Equatable {
    /// `.include`（只给谁看）或 `.exclude`（不给谁看）；标题和说明按它换。
    var visibility: FeedVisibility
    var candidates = [FeedAudienceCandidate]()
    /// 已选的人（recipient id），按选的先后。
    var selected = [Int64]()
    var query = ""
    var loading = true
    var loadFailed = false
    /// 刚才想选第 501 个被挡住了（界面提示一次，`onLimitShown` 清掉）。
    var limitHit = false
}

/// 选人页的状态（和 Android `FeedAudiencePickerActivity` 同一套规则：已经选了的预先勾上、最多 500 人、选完交回名单）。
@MainActor
final class FeedAudiencePickerStore {
    private let source: FeedAudienceCandidateSource
    private let preselected: [Int64]
    private let maxMembers: Int
    private var tasks = [Task<Void, Never>]()
    private var loadRunning = false
    private var loadedOnce = false

    private(set) var state: FeedAudiencePickerState {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedAudiencePickerState) -> Void)?

    init(visibility: FeedVisibility, preselected: [FeedAudienceMember], source: FeedAudienceCandidateSource, maxMembers: Int = FeedDraft.maxAudience) {
        self.source = source
        self.preselected = preselected.map(\.recipientId)
        self.maxMembers = maxMembers
        state = FeedAudiencePickerState(visibility: visibility)
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
    }

    /// 读候选人。失败 / 再读一次（`loadFailed` 后点「重试」）；正在读时再调不重复读。
    func load() {
        if loadRunning || (loadedOnce && !state.loadFailed) { return }
        loadRunning = true
        state.loading = true
        state.loadFailed = false
        tasks.append(Task { [weak self, source] in
            do {
                let raw = try await source.candidates()
                guard let self else { return }
                let candidates = Self.clean(raw)
                var next = self.state
                next.candidates = candidates
                // 预先勾上的：只留下现在还在候选里的（不再是好友的人静默去掉，不让名单里留着选不到的人）
                let known = Set(candidates.map(\.recipientId))
                var seen = Set<Int64>()
                next.selected = self.preselected.filter { known.contains($0) && seen.insert($0).inserted }.prefix(self.maxMembers).map { $0 }
                next.loading = false
                self.loadRunning = false
                self.loadedOnce = true
                self.state = next
            } catch {
                Logger.warn("feed audience candidates failed: \(error)")
                guard let self else { return }
                self.loadRunning = false
                self.state.loading = false
                self.state.loadFailed = true
            }
        })
    }

    /// 去掉 ACI 不是 UUID 的（签不了名）、重复的人（recipient id 或 ACI 重复）；名字空的显示成 ACI 的前 8 位。
    nonisolated static func clean(_ raw: [FeedAudienceCandidate]) -> [FeedAudienceCandidate] {
        var ids = Set<Int64>()
        var acis = Set<String>()
        var result = [FeedAudienceCandidate]()
        for candidate in raw {
            guard UUID(uuidString: candidate.aci) != nil else { continue }
            let aci = candidate.aci.lowercased()
            guard ids.insert(candidate.recipientId).inserted, acis.insert(aci).inserted else { continue }
            var cleaned = candidate
            cleaned.aci = aci
            if cleaned.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cleaned.displayName = String(aci.prefix(8))
            }
            result.append(cleaned)
        }
        return result
    }

    func toggle(recipientId: Int64) {
        guard state.candidates.contains(where: { $0.recipientId == recipientId }) else { return }
        if let index = state.selected.firstIndex(of: recipientId) {
            state.selected.remove(at: index)
        } else if state.selected.count >= maxMembers {
            state.limitHit = true
        } else {
            state.selected.append(recipientId)
        }
    }

    func setQuery(_ query: String) {
        state.query = query
    }

    func onLimitShown() {
        state.limitHit = false
    }

    var maximum: Int { maxMembers }

    /// 搜索框过滤之后的候选人（名字包含搜索词，不分大小写和音调；搜索词是空的就是全部），顺序照候选列表。
    var visibleCandidates: [FeedAudienceCandidate] {
        return Self.filter(state.candidates, query: state.query)
    }

    nonisolated static func filter(_ candidates: [FeedAudienceCandidate], query: String) -> [FeedAudienceCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return candidates }
        return candidates.filter { $0.displayName.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    func isSelected(_ recipientId: Int64) -> Bool {
        return state.selected.contains(recipientId)
    }

    /// 选了至少一个人才能完成（`include` / `exclude` 都不能是空名单，和 `FeedDraft.problem` 一致）。
    var canConfirm: Bool {
        return !state.loading && !state.selected.isEmpty
    }

    /// 选好的名单，按选的先后。
    var result: [FeedAudienceMember] {
        let byId = Dictionary(state.candidates.map { ($0.recipientId, $0) }, uniquingKeysWith: { first, _ in first })
        return state.selected.compactMap { byId[$0]?.member }
    }
}

/// 样例源 / 内部开发用的候选人（固定的 UUID，名字有中英文和大小写，方便试搜索和 500 人上限）。
enum FeedAudienceSamples {
    static func candidates(count: Int = 12) -> [FeedAudienceCandidate] {
        let names = ["Alice Chen", "bob", "陈小明", "Carol", "大卫 David", "Eve", "方圆", "Grace", "Henry", "林一", "Iris", "Jack"]
        return (0..<count).map { index in
            FeedAudienceCandidate(
                recipientId: Int64(1000 + index),
                aci: String(format: "00000000-0000-4000-8000-%012d", index + 1),
                displayName: index < names.count ? names[index] : "Friend \(index + 1)"
            )
        }
    }
}
