//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 样例里「动态设置」的可变部分（本机内存，重开就回到初始）：内容偏好、兴趣标签（删掉的不再回来）、少推荐的词。
/// 规则照引擎（`docs/api.md`「兴趣标签」「内容偏好」「屏蔽关键词」）：
/// 敏感内容「更多」在大陆回 400 `not_available_in_region`；词只收 0 / 7 / 30 天，最多 100 个（第 101 个 409 `too_many_keywords`）；
/// 删兴趣标签后它不再出现，「重置」清掉学到的、删过的仍然是删掉的；`pause_days` 30 = 暂停到 30 天后，0 = 恢复。
final class SampleSettingsState {
    private let lock = NSLock()
    private var preferences: FeedPreferences
    private var topics: [FeedInterest]
    private var authors: [FeedInterest]
    private var sources: [FeedInterest]
    private var keywords: [FeedServerKeyword]

    static let maxKeywords = FeedKeywordRequest.maxKeywords

    init() {
        var preferences = FeedPreferences()
        preferences.categories = ["baking": FeedPreferences.categoryReduce, "travel": FeedPreferences.categoryIncrease]
        preferences.recentTopics = [
            FeedRecentTopic(key: "tech", share: 0.42),
            FeedRecentTopic(key: "food", share: 0.27),
            FeedRecentTopic(key: "anime", share: 0.18),
            // 引擎以后加了客户端还不认识的类别：显示成 #slug
            FeedRecentTopic(key: "new-topic", share: 0.09),
        ]
        self.preferences = preferences
        topics = [
            FeedInterest(key: "tech", score: 1),
            FeedInterest(key: "food", score: 0.7),
            FeedInterest(key: "anime", score: 0.45),
            FeedInterest(key: "travel", score: 0.2),
            FeedInterest(key: "new-topic", score: 0.1),
        ]
        authors = [
            FeedInterest(key: "n:s-1", label: "Ann (sample)", score: 0.6),
            // 没有名字的作者：显示 key
            FeedInterest(key: "x:ext-9", label: " ", score: 0.2),
        ]
        sources = [FeedInterest(key: "src-news", label: "Daily Sample News", score: 0.5)]
        keywords = [
            FeedServerKeyword(keyword: "spoiler"),
            FeedServerKeyword(keyword: "ads", expiresAt: FeedDates.format(Date().addingTimeInterval(7 * 86_400))),
        ]
    }

    func currentPreferences() -> FeedPreferences {
        lock.lock()
        defer { lock.unlock() }
        return preferences
    }

    /// 存偏好：回改完之后的整份（真引擎的 PUT 回的不带 `recent_topics`）。大陆选「更多」抛 `not_available_in_region`。
    func save(_ update: FeedPreferencesUpdate, region: String, now: Date) throws -> FeedPreferences {
        lock.lock()
        defer { lock.unlock() }
        if update.sensitive == FeedPreferences.sensitiveMore, region == "cn" {
            throw FeedAPIError(status: 400, code: "not_available_in_region")
        }
        if let v = update.personalized { preferences.personalized = v }
        if let v = update.style { preferences.style = v }
        if let v = update.sensitive { preferences.sensitive = v }
        if let v = update.categories { preferences.categories = v }
        if let days = update.pauseDays {
            preferences.pausedUntil = days > 0 ? FeedDates.format(now.addingTimeInterval(Double(days) * 86_400)) : nil
        }
        var reply = preferences
        reply.recentTopics = []
        return reply
    }

    func currentInterests() -> FeedInterests {
        lock.lock()
        defer { lock.unlock() }
        return FeedInterests(topics: topics, authors: authors, sources: sources)
    }

    func deleteInterest(dimension: String, key: String) {
        lock.lock()
        defer { lock.unlock() }
        switch dimension {
        case FeedInterests.dimTopic: topics.removeAll { $0.key == key }
        case FeedInterests.dimAuthor: authors.removeAll { $0.key == key }
        case FeedInterests.dimSource: sources.removeAll { $0.key == key }
        default: break
        }
    }

    /// 重置：学到的全清（样例里的都是学到的；删过的本来就已经不在）。
    func resetInterests() {
        lock.lock()
        defer { lock.unlock() }
        topics = []
        authors = []
        sources = []
        preferences.recentTopics = []
    }

    func currentKeywords() -> [FeedServerKeyword] {
        lock.lock()
        defer { lock.unlock() }
        return keywords
    }

    func putKeyword(_ keyword: String, days: Int, now: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        let count = keyword.unicodeScalars.count
        guard count > 0, count <= FeedKeywordRequest.maxChars, [0, 7, 30].contains(days) else {
            throw FeedAPIError(status: 400, code: "invalid_keyword")
        }
        let expires = days > 0 ? FeedDates.format(now.addingTimeInterval(Double(days) * 86_400)) : nil
        if let index = keywords.firstIndex(where: { $0.keyword == keyword }) {
            keywords[index].expiresAt = expires
            return
        }
        if keywords.count >= Self.maxKeywords { throw FeedAPIError(status: 409, code: "too_many_keywords") }
        keywords.append(FeedServerKeyword(keyword: keyword, expiresAt: expires))
    }

    func deleteKeyword(_ keyword: String) {
        lock.lock()
        defer { lock.unlock() }
        keywords.removeAll { $0.keyword == keyword }
    }
}

extension SampleFeedSource {
    private func settingsGate(write: Bool) async throws {
        let simulation = self.simulation
        if simulation.settingsLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: simulation.settingsLatencyNanos)
        }
        if simulation.feedHidden { throw FeedAPIError(status: 404, code: "feed_hidden") }
        if let seconds = simulation.settingsThrottledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
        if write ? simulation.failsSettingsWrites : simulation.failsSettingsLoad { throw SampleFeedError.simulatedActionFailure }
    }

    func preferences() async throws -> FeedPreferences {
        try await settingsGate(write: false)
        return settingsState.currentPreferences()
    }

    func savePreferences(_ update: FeedPreferencesUpdate) async throws -> FeedPreferences {
        try await settingsGate(write: true)
        return try settingsState.save(update, region: simulation.settingsRegion, now: now())
    }

    func interests() async throws -> FeedInterests {
        try await settingsGate(write: false)
        return settingsState.currentInterests()
    }

    func deleteInterest(dimension: String, key: String) async throws {
        try await settingsGate(write: true)
        settingsState.deleteInterest(dimension: dimension, key: key)
    }

    func resetInterests() async throws {
        try await settingsGate(write: true)
        settingsState.resetInterests()
    }

    func keywords() async throws -> [FeedServerKeyword] {
        try await settingsGate(write: false)
        if simulation.failsSettingsKeywordsLoad { throw SampleFeedError.simulatedActionFailure }
        return settingsState.currentKeywords()
    }

    func putKeyword(_ keyword: String, days: Int) async throws {
        try await settingsGate(write: true)
        try settingsState.putKeyword(keyword, days: days, now: now())
    }

    func deleteKeyword(_ keyword: String) async throws {
        try await settingsGate(write: true)
        settingsState.deleteKeyword(keyword)
    }
}
