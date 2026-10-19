//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 详情页补全样例里的可变部分（本机内存，重开就回到初始）：我投过的票、批准 / 拒绝过的待审回复、转发 / 收藏的记录。
/// 样例自带：`mine-seed-2`（单选）、`mine-seed-3`（多选）带投票；`mine-seed-*` 的评论里有一条待我批准的回复、一条语音评论。
final class SampleDetailExtrasState {
    private let lock = NSLock()
    private var votes = [String: [Int]]()
    private var approved = Set<String>()
    private var declined = Set<String>()
    private(set) var calls = [String]()

    static let pollOptions: [String: (options: [String], multi: Bool, counts: [Int])] = [
        "mine-seed-2": (["Tea", "Coffee", "Water"], false, [12, 7, 3]),
        "mine-seed-3": (["Running", "Reading", "Cooking", "Gaming"], true, [5, 9, 4, 2]),
    ]

    func record(_ call: String) {
        lock.lock()
        defer { lock.unlock() }
        calls.append(call)
    }

    func myVote(_ postId: String) -> [Int]? {
        lock.lock()
        defer { lock.unlock() }
        return votes[postId]
    }

    /// 投一次；投过的是 nil（引擎 409 `already_voted`）。
    func vote(_ postId: String, options: [Int]) -> FeedPollState? {
        lock.lock()
        defer { lock.unlock() }
        guard votes[postId] == nil, let poll = Self.pollOptions[postId] else { return nil }
        let chosen = Array(Set(options.filter { poll.counts.indices.contains($0) })).sorted()
        guard !chosen.isEmpty, poll.multi || chosen.count == 1 else { return nil }
        votes[postId] = chosen
        calls.append("vote:\(postId):\(chosen.map(String.init).joined(separator: ","))")
        return Self.state(postId: postId, voted: chosen)
    }

    static func state(postId: String, voted: [Int]) -> FeedPollState? {
        guard let poll = pollOptions[postId] else { return nil }
        var counts = poll.counts
        for index in voted where counts.indices.contains(index) { counts[index] += 1 }
        return FeedPollState(counts: counts, voted: voted)
    }

    func approve(_ commentId: String) {
        lock.lock()
        defer { lock.unlock() }
        approved.insert(commentId)
        calls.append("approve:\(commentId)")
    }

    func isApproved(_ commentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return approved.contains(commentId)
    }

    /// 拒绝 = 删掉；这条是样例里的待审回复就记下并返回 true。
    func decline(_ commentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard commentId.contains("-held") else { return false }
        declined.insert(commentId)
        calls.append("decline:\(commentId)")
        return true
    }

    func isDeclined(_ commentId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return declined.contains(commentId)
    }
}

extension SampleFeedSource {

    func setReposted(contentId: String, reposted: Bool) async throws {
        let simulation = self.simulation
        try await simulatedDetailAction(failing: simulation.failsLikes)
        detailExtras.record("repost:\(contentId):\(reposted)")
    }

    func setSaved(contentId: String, saved: Bool) async throws {
        let simulation = self.simulation
        try await simulatedDetailAction(failing: simulation.failsLikes)
        detailExtras.record("save:\(contentId):\(saved)")
    }

    func vote(contentId: String, options: [Int]) async throws -> FeedPollState {
        let simulation = self.simulation
        try await simulatedDetailAction(failing: simulation.failsLikes)
        guard let state = detailExtras.vote(contentId, options: options) else {
            throw FeedAPIError(status: 409, code: "already_voted")
        }
        return state
    }

    func approveComment(postId: String, commentId: String) async throws {
        let simulation = self.simulation
        try await simulatedDetailAction(failing: simulation.failsComments)
        guard commentId.contains("-held"), !detailExtras.isDeclined(commentId) else {
            throw FeedAPIError(status: 404, code: "not_found")
        }
        detailExtras.approve(commentId)
    }

    private func simulatedDetailAction(failing: Bool) async throws {
        if failing { throw SampleFeedError.simulatedActionFailure }
        await Task.yield()
    }

    /// `mine-seed-N`（自己的已发布帖子）的评论：一条普通的、一条等我批准的回复、一条语音评论。批准了的不再是待审；拒绝了的没有了。
    func sampleDetailExtrasComments(postId: String) -> [FeedCard] {
        guard postId.hasPrefix("mine-seed-") else { return [] }
        let current = now()
        func make(_ suffix: String, minutesAgo: Double, author: FeedAuthor, text: String?, parent: String? = nil) -> FeedCard {
            var comment = FeedCard(
                id: "\(postId)-\(suffix)",
                kind: FeedCard.kindComment,
                publishedAt: FeedDates.format(current.addingTimeInterval(-minutesAgo * 60)),
                author: author,
                text: text,
            )
            comment.rootId = postId
            comment.parentId = parent
            return comment
        }
        var list = [make("c0", minutesAgo: 30, author: Self.authors[0], text: "Nice one!")]
        var held = make("held1", minutesAgo: 12, author: Self.authors[1], text: "This reply is waiting for your approval", parent: "\(postId)-c0")
        held.held = !detailExtras.isApproved(held.id)
        if !detailExtras.isDeclined(held.id) { list.append(held) }
        var voice = make("voice", minutesAgo: 5, author: Self.authors[2], text: nil)
        var audio = FeedMedia(key: "sample/voice/\(postId).m4a")
        audio.type = FeedMedia.typeAudio
        audio.durationMs = 4000
        voice.media = [audio]
        voice.transcript = "Sample voice comment transcript"
        list.append(voice)
        return list
    }

    /// 样例自带帖子上的投票和转发：投票按我投过的票换票数，所有自己的帖子都能转发。
    func applyDetailExtras(to card: inout FeedCard) {
        card.shareable = true
        if let poll = SampleDetailExtrasState.pollOptions[card.id] {
            card.poll = FeedPoll(options: poll.options, closesAt: FeedDates.format(now().addingTimeInterval(2 * 86400)), multi: poll.multi)
            let voted = detailExtras.myVote(card.id) ?? []
            card.pollState = SampleDetailExtrasState.state(postId: card.id, voted: voted)
        }
    }
}
