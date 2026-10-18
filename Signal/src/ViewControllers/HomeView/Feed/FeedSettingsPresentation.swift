//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 内容引擎 `configs/categories` 的 36 个类别（话题 slug），顺序就是引擎的编号顺序（「按类别调整」按这个顺序列）。
/// 兴趣标签、最近看的内容、按类别调整都只给 slug，名字由客户端起（`FeedTopicNames.kt`）；不认识的 slug 显示成 `#slug`。
enum FeedTopicSlug: String, CaseIterable, Equatable {
    case ai, tech, dev, games, anime, film, music, books, photo, design
    case food, baking, explore, travel, camping, fitness, running, ballsports, fashion, beauty
    case portrait, pets, home, parenting, work, frugal, cars, science, health, mood
    case funny, diy, plants, city, campus, news
}

/// 一个要显示的名字：认得的话题（界面查本地化名字），或者原样的文字。
enum FeedSettingsLabel: Equatable {
    case topic(FeedTopicSlug)
    case text(String)

    /// 话题 slug → 名字；不认识的显示成 `#slug`。
    static func fromSlug(_ slug: String) -> FeedSettingsLabel {
        if let known = FeedTopicSlug(rawValue: slug) { return .topic(known) }
        return .text("#" + slug)
    }
}

/// 一个类别的三档（引擎 `categories` 的值）。认不得的值当「默认」。
enum FeedCategoryChoice: Equatable, CaseIterable {
    case reduce
    case `default`
    case increase

    init(value: String?) {
        switch value {
        case FeedPreferences.categoryReduce: self = .reduce
        case FeedPreferences.categoryIncrease: self = .increase
        default: self = .default
        }
    }

    var apiValue: String {
        switch self {
        case .reduce: return FeedPreferences.categoryReduce
        case .default: return FeedPreferences.categoryDefault
        case .increase: return FeedPreferences.categoryIncrease
        }
    }
}

/// 敏感内容的三档。认不得的值当「标准」。
enum FeedSensitiveChoice: Equatable {
    case reduce
    case standard
    case more

    init(value: String) {
        switch value {
        case FeedPreferences.sensitiveReduce: self = .reduce
        case FeedPreferences.sensitiveMore: self = .more
        default: self = .standard
        }
    }

    var apiValue: String {
        switch self {
        case .reduce: return FeedPreferences.sensitiveReduce
        case .standard: return FeedPreferences.sensitiveStandard
        case .more: return FeedPreferences.sensitiveMore
        }
    }
}

/// 加关键词对话框里填的东西（和 Android `KeywordForm` 一样）。长度按 Unicode 码点算（引擎 `MaxKeywordChars`，不是 Character）。
struct FeedKeywordForm: Equatable {
    var text = ""
    /// false = 少推荐（默认）；true = 完全屏蔽。
    var block = false
    var days = 0

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var valid: Bool { !trimmed.isEmpty && trimmed.unicodeScalars.count <= FeedKeywordRequest.maxChars }
    var mode: FeedKeyword.Mode { block ? .block : .downrank }
    /// 有效期的三个选项，顺序：永久、30 天、7 天（和 Android 一样）。
    static let dayChoices = FeedKeywordRequest.allowedDays
}

/// 「动态设置」页的展示逻辑（纯逻辑，没有文字）：界面按这些挑本地化句子，测试直接对着它测。
enum FeedSettingsPresentation {

    // MARK: - 页面

    enum Phase: Equatable {
        case loading
        /// 整页读不到；限速时带还要等几秒。
        case failed(retryAfterSeconds: Int?)
        case content
    }

    /// 偏好和兴趣标签都读到了才画内容（关键词读不到不挡整页）。
    static func phase(_ state: FeedRecommendationSettingsState) -> Phase {
        if state.preferences != nil, state.interests != nil { return .content }
        if state.loadFailed { return .failed(retryAfterSeconds: state.retryAfterSeconds) }
        return .loading
    }

    // MARK: - 个性化

    enum PersonalizationRow: Equatable {
        case toggle(on: Bool)
        /// 编辑精选阶段（R-1.5）推荐本来就不按个人兴趣，没有开关可给，只说明一句。
        case editorialNote
    }

    static func personalization(_ state: FeedRecommendationSettingsState) -> PersonalizationRow? {
        guard let preferences = state.preferences else { return nil }
        return state.personalizationToggleVisible ? .toggle(on: preferences.personalized) : .editorialNote
    }

    // MARK: - 最近看的内容

    struct RecentTopicRow: Equatable {
        var label: FeedSettingsLabel
        /// 0…1（引擎给的比例夹在这个范围里；进度条用）。
        var share: Double
        /// 四舍五入的百分数（和 Android `Math.round(share * 100)` 一样，但先夹到 0…100，引擎给了 1.3 也不会说 130%）。
        var percent: Int
    }

    static func recentTopics(_ preferences: FeedPreferences) -> [RecentTopicRow] {
        return preferences.recentTopics.map { topic in
            let share = topic.share.isFinite ? min(max(topic.share, 0), 1) : 0
            return RecentTopicRow(label: .fromSlug(topic.key), share: share, percent: Int((share * 100).rounded()))
        }
    }

    // MARK: - 兴趣标签

    struct InterestRow: Equatable {
        var dimension: String
        var interest: FeedInterest
        var label: FeedSettingsLabel
    }

    struct InterestSection: Equatable {
        enum Kind: Equatable { case topics, authors, sources }
        var kind: Kind
        var dimension: String
        var rows: [InterestRow]
    }

    /// 话题、人、来源三组，空的组不画；整个都空时界面说「还没有兴趣标签」。话题用名字表，人和来源用引擎给的 `label`（空白就用 key）。
    static func interestSections(_ interests: FeedInterests) -> [InterestSection] {
        func rows(_ dimension: String, _ list: [FeedInterest]) -> [InterestRow] {
            list.map { interest in
                let label: FeedSettingsLabel
                if dimension == FeedInterests.dimTopic {
                    label = .fromSlug(interest.key)
                } else if let text = interest.label, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    label = .text(text)
                } else {
                    label = .text(interest.key)
                }
                return InterestRow(dimension: dimension, interest: interest, label: label)
            }
        }
        let sections = [
            InterestSection(kind: .topics, dimension: FeedInterests.dimTopic, rows: rows(FeedInterests.dimTopic, interests.topics)),
            InterestSection(kind: .authors, dimension: FeedInterests.dimAuthor, rows: rows(FeedInterests.dimAuthor, interests.authors)),
            InterestSection(kind: .sources, dimension: FeedInterests.dimSource, rows: rows(FeedInterests.dimSource, interests.sources)),
        ]
        return sections.filter { !$0.rows.isEmpty }
    }

    // MARK: - 按类别调整

    struct CategoryRow: Equatable {
        var slug: FeedTopicSlug
        var choice: FeedCategoryChoice
    }

    /// 36 个类别都列，值取偏好里的（没有就是「默认」）。
    static func categoryRows(_ preferences: FeedPreferences) -> [CategoryRow] {
        return FeedTopicSlug.allCases.map { CategoryRow(slug: $0, choice: FeedCategoryChoice(value: preferences.categories[$0.rawValue])) }
    }

    /// 调整过几个类别（「减少」或「增加」的）。Android 数的是 `categories.size`；这里不数值是 `default` 的（引擎说 default = 去掉，万一回了也不算调整过）。
    static func adjustedCategoryCount(_ preferences: FeedPreferences) -> Int {
        return preferences.categories.values.filter { FeedCategoryChoice(value: $0) != .default }.count
    }

    // MARK: - 关键词

    struct KeywordRow: Equatable {
        var keyword: String
        var mode: FeedKeyword.Mode
        /// nil = 永久。
        var expiresAt: Date?
        /// 原样的词（删除时交回 store）。
        var source: FeedKeyword
    }

    /// 本机「完全屏蔽」的在前、服务端「少推荐」的在后（store 已经排好、滤掉了过期的）；这里把毫秒换成日期，并再滤一次过期的（页面开着时间过了）。
    static func keywordRows(_ keywords: [FeedKeyword], now: Date) -> [KeywordRow] {
        let nowMillis = InMemoryFeedBlockedKeywords.millis(now)
        return keywords.filter { $0.expiresAt.map { $0 > nowMillis } ?? true }.map {
            KeywordRow(keyword: $0.keyword, mode: $0.mode, expiresAt: $0.expiresAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }, source: $0)
        }
    }

    // MARK: - 暂停推荐

    enum PauseRow: Equatable {
        case notPaused
        /// 暂停到这一天；已经过了的当没暂停（Android 会照样写「暂停到 <过去的日期>」，这里不学）。
        case paused(until: Date)
    }

    static func pause(_ preferences: FeedPreferences, now: Date) -> PauseRow {
        guard let value = preferences.pausedUntil, let date = FeedDates.parse(value), date > now else { return .notPaused }
        return .paused(until: date)
    }

    // MARK: - 提示

    enum Toast: Equatable {
        case reset
        case invalidKeyword
        case tooManyKeywords
        case actionFailed
        case throttled(retryAfterSeconds: Int?)
    }

    static func toast(_ state: FeedRecommendationSettingsState) -> Toast? {
        guard let notice = state.notice else { return nil }
        switch notice {
        case .reset: return .reset
        case .invalidKeyword: return .invalidKeyword
        case .tooManyKeywords: return .tooManyKeywords
        case .failed: return .actionFailed
        case .throttled: return .throttled(retryAfterSeconds: state.retryAfterSeconds)
        }
    }
}
