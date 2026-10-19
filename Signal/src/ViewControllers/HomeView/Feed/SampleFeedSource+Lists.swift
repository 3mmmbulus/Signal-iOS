//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 名单页样例里的可变部分（本机内存，重开就回到初始）。
/// 样例自带：3 个想关注我的人；一个被屏蔽的来源和一个话题（作者的屏蔽 / 不看 / 不让看 复用主页的 `SampleProfileState`）；
/// 两个只在名单里的「不看 TA」和一个「不让 TA 看」；关心的人：山风已同意，周末烘焙设了我（等我同意）。
final class SampleListsState {
    private let lock = NSLock()
    private var requests = SampleListsState.seedRequests
    private var extraBlocks = SampleListsState.seedBlocks
    private var extraMuted = SampleListsState.seedMuted
    private var extraHiddenFrom = SampleListsState.seedHiddenFrom
    private var closeMine = [FeedClosePersonEntry(id: "s-1", displayName: "山风", state: FeedClosePersonEntry.stateAccepted)]
    private var closeRequests = [FeedClosePersonEntry(id: "s-4", displayName: "周末烘焙", state: FeedClosePersonEntry.statePending)]

    static let seedRequests = [
        FeedPersonSummary(id: "req-1", handle: "xiaoyu", displayName: "林小雨", avatarKey: nil),
        FeedPersonSummary(id: "req-2", handle: "old_k", displayName: "老K", avatarKey: nil),
        FeedPersonSummary(id: "req-3", handle: nil, displayName: "阿宁", avatarKey: nil),
    ]
    static let seedBlocks = [
        FeedBlockEntry(type: "source", id: "sample-news", createdAt: nil, profile: nil),
        FeedBlockEntry(type: FeedAPI.targetTopic, id: "gossip", createdAt: nil, profile: nil),
    ]
    static let seedMuted = [
        FeedPersonSummary(id: "seed-m1", handle: "loud_one", displayName: "话痨小王", avatarKey: nil),
        FeedPersonSummary(id: "seed-m2", handle: nil, displayName: "每日鸡汤", avatarKey: nil),
    ]
    static let seedHiddenFrom = [
        FeedPersonSummary(id: "seed-h1", handle: "boss_li", displayName: "李经理", avatarKey: nil),
    ]

    func withLock<T>(_ body: (SampleListsState) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(self)
    }

    // 下面的方法只在 `withLock` 里调。
    var followRequests: [FeedPersonSummary] { get { requests } set { requests = newValue } }
    var seededBlocks: [FeedBlockEntry] { get { extraBlocks } set { extraBlocks = newValue } }
    var seededMuted: [FeedPersonSummary] { get { extraMuted } set { extraMuted = newValue } }
    var seededHiddenFrom: [FeedPersonSummary] { get { extraHiddenFrom } set { extraHiddenFrom = newValue } }
    var mine: [FeedClosePersonEntry] { get { closeMine } set { closeMine = newValue } }
    var closeRequestsList: [FeedClosePersonEntry] { get { closeRequests } set { closeRequests = newValue } }
}

extension SampleFeedSource {
    private func listsGate() async throws {
        let simulation = self.simulation
        if simulation.listsLatencyNanos > 0 { try? await Task.sleep(nanoseconds: simulation.listsLatencyNanos) }
        if simulation.feedHidden { throw FeedAPIError(status: 404, code: "feed_hidden") }
        if let seconds = simulation.listsThrottledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
    }

    private func listsRead() async throws {
        try await listsGate()
        if simulation.failsListsLoad { throw SampleFeedError.simulatedActionFailure }
    }

    private func listsWrite() async throws {
        try await listsGate()
        if simulation.failsListsActions { throw SampleFeedError.simulatedActionFailure }
    }

    private static func person(_ id: String) -> FeedPersonSummary? {
        return authors.first { $0.profileId == id }.map { FeedPersonSummary(id: $0.profileId, handle: $0.handle, displayName: $0.displayName, avatarKey: nil) }
    }

    func followRequests() async throws -> [FeedFollowRequest] {
        try await listsRead()
        return listsState.withLock { $0.followRequests }.map { FeedFollowRequest(profile: $0, requestedAt: nil) }
    }

    func answerFollowRequest(profileId: String, approve: Bool) async throws {
        try await listsWrite()
        if simulation.followRequestWithdrawn { throw FeedAPIError(status: 404, code: "not_found") }
        let found = listsState.withLock { state -> Bool in
            guard state.followRequests.contains(where: { $0.id == profileId }) else { return false }
            state.followRequests.removeAll { $0.id == profileId }
            return true
        }
        if !found { throw FeedAPIError(status: 404, code: "not_found") }
    }

    func blocks() async throws -> [FeedBlockEntry] {
        try await listsRead()
        let blockedAuthors = profiles.withLock { _, blocked, _, _ in blocked }
        let authorEntries = blockedAuthors.sorted().compactMap { id -> FeedBlockEntry? in
            guard let person = Self.person(id) else { return nil }
            return FeedBlockEntry(type: FeedAPI.targetAuthor, id: id, createdAt: nil, profile: person)
        }
        return authorEntries + listsState.withLock { $0.seededBlocks }
    }

    func unblock(_ entry: FeedBlockEntry) async throws {
        if entry.type == FeedAPI.targetAuthor {
            try await setBlocked(profileId: entry.id, blocked: false)
            return
        }
        try await listsWrite()
        let found = listsState.withLock { state -> Bool in
            let before = state.seededBlocks.count
            state.seededBlocks.removeAll { $0.type == entry.type && $0.id == entry.id }
            return state.seededBlocks.count != before
        }
        if !found { throw FeedAPIError(status: 404, code: "not_found") }
    }

    func hideLists() async throws -> FeedHideLists {
        try await listsRead()
        let sets = profiles.withLock { _, _, muted, hiddenFrom in (muted, hiddenFrom) }
        var lists = FeedHideLists()
        lists.mute = sets.0.sorted().compactMap(Self.person) + listsState.withLock { $0.seededMuted }
        lists.hideFrom = sets.1.sorted().compactMap(Self.person) + listsState.withLock { $0.seededHiddenFrom }
        return lists
    }

    /// 样例里主页菜单加进名单的人和名单页自带的人放在两处；移出时两处都清。
    func removeFromSeededHideList(list: String, profileId: String) {
        listsState.withLock { state in
            if list == FeedAPI.hideMute {
                state.seededMuted.removeAll { $0.id == profileId }
            } else {
                state.seededHiddenFrom.removeAll { $0.id == profileId }
            }
        }
    }

    func closePeople() async throws -> FeedClosePeopleResponse {
        try await listsRead()
        var response = FeedClosePeopleResponse()
        listsState.withLock { state in
            response.mine = state.mine
            response.requests = state.closeRequestsList
        }
        return response
    }

    func addClosePerson(profileId: String) async throws -> String {
        try await listsWrite()
        let simulation = self.simulation
        if simulation.closePeopleProfileRequired { throw FeedAPIError(status: 409, code: "profile_required") }
        guard let person = Self.person(profileId), profileId != Self.me.profileId else { throw FeedAPIError(status: 404, code: "not_found") }
        return try listsState.withLock { state -> String in
            if let existing = state.mine.first(where: { $0.id == profileId }) { return existing.state }
            if simulation.closePeopleFull || state.mine.count >= FeedClosePersonEntry.max {
                throw FeedAPIError(status: 409, code: "close_people_full")
            }
            state.mine.append(FeedClosePersonEntry(id: person.id, displayName: person.displayName, state: FeedClosePersonEntry.statePending))
            return FeedClosePersonEntry.statePending
        }
    }

    func removeClosePerson(profileId: String) async throws {
        try await listsWrite()
        listsState.withLock { state in
            state.mine.removeAll { $0.id == profileId }
        }
    }

    func answerClosePerson(ownerProfileId: String, accept: Bool) async throws {
        try await listsWrite()
        let found = listsState.withLock { state -> Bool in
            guard let index = state.closeRequestsList.firstIndex(where: { $0.id == ownerProfileId }) else { return false }
            if accept {
                state.closeRequestsList[index].state = FeedClosePersonEntry.stateAccepted
            } else {
                state.closeRequestsList.remove(at: index)
            }
            return true
        }
        if !found { throw FeedAPIError(status: 404, code: "not_found") }
    }
}
