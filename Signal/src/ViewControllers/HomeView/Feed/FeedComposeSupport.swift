//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedComposeSupport.swift (new file)
// Compose completion pieces: poll draft, reply options, quote target, article autosave, topic catalog (I-12).
// Mirror of Android `compose/FeedDraft.kt` (FeedDraftPoll, FeedPollDuration, FeedReplyPolicy, FeedReplySettings),
// `FeedQuoteTarget.kt`, `FeedArticleDrafts.kt`, `settings/FeedTopicNames.kt` (slug list only).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension FeedPoll {
    /// 发布时的投票（`FeedPoll` 本来只有解码用的初始化）。
    init(options: [String], closesAt: String?, multi: Bool) {
        self.options = options
        self.closesAt = closesAt
        self.multi = multi
    }
}

/// 截止时间三档；默认一天（Threads 的投票也是默认 24 小时）。
enum FeedPollDuration: CaseIterable {
    case oneDay
    case threeDays
    case sevenDays

    var hours: Int {
        switch self {
        case .oneDay: return 24
        case .threeDays: return 72
        case .sevenDays: return 168
        }
    }
}

/// 写到一半的投票。问题就是正文（引擎没有单独的问题字段）。
///
/// 选项 2–10 个、每个最多 40 字（引擎 `postRequest.validate`）；空着的选项发的时候去掉，填了的不到 2 个不能发。
struct FeedDraftPoll: Equatable {
    static let minOptions = 2
    static let maxOptions = 10
    static let optionMaxChars = FeedInputLimit.pollOption

    var options = [String](repeating: "", count: FeedDraftPoll.minOptions)
    var multi = false
    var duration = FeedPollDuration.oneDay

    var filledOptions: [String] {
        return options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// 字数按 Unicode 码点数（一个汉字算 1，和 Android `codePointCount`、引擎同口径）。
    var isValid: Bool {
        let filled = filledOptions
        return (Self.minOptions...Self.maxOptions).contains(filled.count) && filled.allSatisfy { $0.unicodeScalars.count <= Self.optionMaxChars }
    }

    var canAddOption: Bool {
        return options.count < Self.maxOptions
    }

    /// 截止时间在点发布的那一刻算。
    func toApi(now: Date) -> FeedPoll {
        return FeedPoll(options: filledOptions, closesAt: FeedDates.format(now.addingTimeInterval(TimeInterval(duration.hours) * 3600)), multi: multi)
    }

    /// 超过 40 个码点的部分打不进去；只在字的边界上截（以前直接截码点，会把一个 ZWJ / 国旗 emoji 劈成半个）。
    static func clip(_ option: String) -> String {
        return FeedTextCap.cap(option, codePoints: optionMaxChars)
    }
}

/// 谁能回复。第 40 条写「选项未定」（第五节 Q-12）；先用引擎暂定的三档，定了再改。
enum FeedReplyPolicy: String, CaseIterable {
    case everyone
    case friends
    case following

    var apiName: String { rawValue }
}

/// 每条单独设的回复选项：谁能回复、关闭评论、审核回复（作者批准后才公开）、语音评论（默认开）。
/// 发布接口不收语音评论开关，只在发出去以后的「···」里改。
struct FeedReplySettings: Equatable {
    var policy = FeedReplyPolicy.everyone
    var commentsClosed = false
    var moderation = false
    var voiceComments = true

    var isDefault: Bool {
        return self == FeedReplySettings()
    }
}

/// 「分享」里的「引用」（第三节第 26 条）：发布页里压在正文下面的那条。只带画小框要的作者名和开头一段，
/// 发出去时只交 `id`（引擎 `quote_of`）。
struct FeedQuoteTarget: Equatable {
    var id: String
    var authorName: String
    var snippet: String

    static let snippetChars = 120

    /// 只有能分享的（公开、作者不是私密账号，第 29 条）才能引用；评论不能。
    /// 摘要取标题（没有就取正文）去掉首尾空白，超过 120 个字加「…」（Android `take` 数 UTF-16 单位；这里数 Character，不切开 emoji）。
    static func of(_ card: FeedCard) -> FeedQuoteTarget? {
        guard card.shareable, card.kind == FeedCard.kindPost || card.kind == FeedCard.kindArticle else { return nil }
        let base = (card.title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }) ?? card.text ?? ""
        var snippet = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.count > snippetChars { snippet = String(snippet.prefix(snippetChars)) + "…" }
        return FeedQuoteTarget(id: card.id, authorName: card.author?.displayName ?? "", snippet: snippet)
    }
}

// MARK: - 长文自动保存

/// 没写完的长文：标题和正文。
struct FeedSavedArticle: Codable, Equatable {
    var title = ""
    var text = ""

    init(title: String = "", text: String = "") {
        self.title = title
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case title, text }
}

/// 长文自动保存（第三节第 25 条）。只存一篇、只在本机：关掉发布页再打开，接着写；发出去就清掉。
/// 编辑已发的、引用别人的不存（那两种关页面照旧问「放弃吗」）。
protocol FeedArticleDrafts: AnyObject {
    func load() -> FeedSavedArticle?
    func save(_ article: FeedSavedArticle)
    func clear()
}

final class InMemoryFeedArticleDrafts: FeedArticleDrafts {
    private var saved: FeedSavedArticle?

    init(saved: FeedSavedArticle? = nil) {
        self.saved = saved
    }

    func load() -> FeedSavedArticle? { saved }
    func save(_ article: FeedSavedArticle) { saved = article }
    func clear() { saved = nil }
}

/// 存在本机，**不进 iCloud / iTunes 备份**（tellomi测试 2026-10-16 定：一篇没发的文章不该跟着备份走；和 Android 一致）：
/// 传 `FeedLocalStorages.backupExcluded`（`I-18/`）。旧版放在 `UserDefaults` 里的由 `FeedStorageMigration` 搬过来。
final class StoredFeedArticleDrafts: FeedArticleDrafts {
    static let key = "tellomiFeedArticleDraft"

    private let storage: FeedLocalStorage

    /// 故意没有默认值：不要回到会进备份的 `UserDefaults`。
    init(storage: FeedLocalStorage) {
        self.storage = storage
    }

    func load() -> FeedSavedArticle? {
        guard let data = storage.data(forKey: Self.key), !data.isEmpty else { return nil }
        // 存坏了就当没有（Android：捕获异常 → null）
        return try? JSONDecoder().decode(FeedSavedArticle.self, from: data)
    }

    func save(_ article: FeedSavedArticle) {
        if let data = try? JSONEncoder().encode(article) { storage.set(data, forKey: Self.key) }
    }

    func clear() {
        storage.removeValue(forKey: Self.key)
    }
}

// MARK: - 话题

/// 能选的话题 slug，照内容引擎 `configs/categories` 的 36 个类别、按引擎编号顺序（和 Android `FeedTopicNames.slugs` 一样）。
/// 名字（本地化文案）是 I-17；不认识的 slug 界面直接显示 `#slug`。
enum FeedTopicCatalog {
    static let slugs = [
        "ai", "tech", "dev", "games", "anime", "film", "music", "books", "photo", "design", "food", "baking",
        "explore", "travel", "camping", "fitness", "running", "ballsports", "fashion", "beauty", "portrait", "pets",
        "home", "parenting", "work", "frugal", "cars", "science", "health", "mood", "funny", "diy", "plants", "city",
        "campus", "news",
    ]
}
