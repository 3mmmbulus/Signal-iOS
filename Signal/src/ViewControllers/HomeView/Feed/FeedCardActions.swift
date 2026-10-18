//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedCardActions.swift (new file)
// Pure card logic for I-3 (no UIKit): poll presentation, own-post actions, media URL, share link / saved-message text,
// the two-step "save" flow. Mirror of Android `FeedPollView.kt` (percent/footer), `FeedOwnPost.kt`, `FeedPostCard.kt`
// (`remoteUrlOrNull`), `FeedShare.kt`, `FeedSavedMessages.kt`, `FeedViewModel.kt` (`withReposted`, `withPollState`).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

// MARK: - Poll

extension FeedPollState {
    init(counts: [Int] = [], voted: [Int] = []) {
        self.counts = counts
        self.voted = voted
    }

    var hasVoted: Bool { !voted.isEmpty }
}

/// 投票这块要画什么（Android `FeedPollView` 里算出来的那些值）。界面只管画。
///
/// - 没投、没截止：单选点一项就投；多选先勾，再点「投票」；
/// - 投过或截止了：每项按票数比例填色、右边百分比、我选的打勾。投了不能改；
/// - `interactive == false`（搜索结果等没接 `onVote` 的地方）：只看不投，没投过也不显示票数。
struct FeedPollPresentation: Equatable {
    enum Remaining: Equatable {
        case closed
        case days(Int)
        case hours(Int)
        case minutes(Int)
    }

    var optionCount: Int
    var multi: Bool
    var showResults: Bool
    var canVote: Bool
    var total: Int
    /// 每项：四舍五入的百分比（只在 `showResults` 时界面才画）。
    var percents: [Int]
    /// 每项：填色条宽度占比 0…1（没有结果时全是 0）。
    var fractions: [Double]
    var mine: [Bool]
    /// 页脚要不要写「N 票」。
    var showVotes: Bool
    /// 没有 `closes_at` 时是 nil。
    var remaining: Remaining?

    init(poll: FeedPoll, state: FeedPollState?, interactive: Bool, now: Date) {
        let closesAt = poll.closesAt.flatMap { FeedDates.parse($0) }
        let closed = closesAt.map { $0 <= now } ?? false
        let voted = !(state?.voted.isEmpty ?? true)
        let results = voted || closed
        let counts = state?.counts ?? []
        let total = counts.reduce(0, +)

        optionCount = poll.options.count
        multi = poll.multi
        showResults = results
        canVote = !results && interactive
        self.total = total
        percents = poll.options.indices.map { Self.percent(counts.indices.contains($0) ? counts[$0] : 0, of: total) }
        fractions = poll.options.indices.map { index in
            guard results, total > 0 else { return 0 }
            return Double(counts.indices.contains(index) ? counts[index] : 0) / Double(total)
        }
        mine = poll.options.indices.map { state?.voted.contains($0) ?? false }
        showVotes = results || interactive
        remaining = closesAt.map { Self.remaining(until: $0, now: now) }
    }

    /// 四舍五入的百分比；各项加起来不一定正好 100，和多数产品一样不去凑。
    /// 用 `Float`，和 Android 的 `Math.round(count * 100f / total)` 一样（正数时「四舍五入」同为 half-up）。
    static func percent(_ count: Int, of total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int((Float(count) * 100 / Float(total)).rounded(.toNearestOrAwayFromZero))
    }

    /// 离截止还有多久：不到 1 小时按分钟（至少 1），不到 1 天按小时，其余按天；到点或过了是 `.closed`。
    static func remaining(until closesAt: Date, now: Date) -> Remaining {
        let left = Int64((closesAt.timeIntervalSince(now) * 1000).rounded(.towardZero))
        let minute: Int64 = 60_000, hour = 60 * minute, day = 24 * hour
        switch left {
        case ..<1: return .closed
        case day...: return .days(Int(left / day))
        case hour...: return .hours(Int(left / hour))
        default: return .minutes(max(1, Int(left / minute)))
        }
    }
}

/// 多选时勾了哪几项；单选点一下就是投票。界面持有一份，卡片的票数状态换了就重建。
struct FeedPollSelection: Equatable {
    private(set) var checked = Set<Int>()

    /// 点第 `index` 项。单选返回要立刻投的 `[index]`；多选只勾 / 取消勾，返回 nil。
    mutating func tap(_ index: Int, multi: Bool) -> [Int]? {
        guard multi else { return [index] }
        if checked.contains(index) {
            checked.remove(index)
        } else {
            checked.insert(index)
        }
        return nil
    }

    /// 「投票」按钮：没勾就不能点；勾了按下标升序发。
    var canSubmit: Bool { !checked.isEmpty }
    var submission: [Int] { checked.sorted() }
}

// MARK: - 「···」里自己帖子的几项

/// 自己帖子「···」里除了编辑、删除以外的几项（`dynamic-feed.md` 第三节第 26 条）。
enum FeedOwnPostAction: Equatable {
    case pin
    case unpin
    case hideLikes
    case showLikes
    /// 回复选项：打开面板读当前值再改（卡片自己处理，不走 `FeedStore.onOwnPostAction`）。
    case replySettings
    case insights

    /// 要发给引擎的设置；「回复选项」「查看数据」不是一下就改，是 nil。
    var settingsUpdate: FeedPostSettingsUpdate? {
        switch self {
        case .pin: return FeedPostSettingsUpdate(pinned: true)
        case .unpin: return FeedPostSettingsUpdate(pinned: false)
        case .hideLikes: return FeedPostSettingsUpdate(likeCountHidden: true)
        case .showLikes: return FeedPostSettingsUpdate(likeCountHidden: false)
        case .replySettings, .insights: return nil
        }
    }

    /// 这张卡片「···」里该给哪几项，按菜单顺序。别人的帖子和评论没有。
    static func available(for card: FeedCard) -> [FeedOwnPostAction] {
        guard card.viewer.isAuthor, card.kind != FeedCard.kindComment else { return [] }
        return [
            card.pinned ? .unpin : .pin,
            .replySettings,
            card.stats.likeCountHidden ? .showLikes : .hideLikes,
            .insights,
        ]
    }

    /// 置顶满 3 条时引擎回 409 `too_many_pinned`，单独提示；其余一律「操作失败」。
    static func isPinLimit(_ error: Error) -> Bool {
        return (error as? FeedAPIError)?.code == "too_many_pinned"
    }
}

/// 「查看数据」弹窗的状态。
enum FeedInsightsState: Equatable {
    case loading
    case ready(FeedPostInsights)
    case failed
}

// MARK: - 先改界面用的卡片变换（失败时再变回来）

extension FeedCard {
    func withSaved(_ saved: Bool) -> FeedCard {
        guard viewer.saved != saved else { return self }
        var card = self
        card.viewer.saved = saved
        return card
    }

    func withReposted(_ reposted: Bool) -> FeedCard {
        guard viewer.reposted != reposted else { return self }
        var card = self
        card.viewer.reposted = reposted
        card.stats.reposts = max(0, stats.reposts + (reposted ? 1 : -1))
        return card
    }

    /// 投完票：换成服务端给的票数和我的选择。
    func withPollState(_ state: FeedPollState) -> FeedCard {
        var card = self
        card.pollState = state
        return card
    }

    /// 把设置套到卡片上（置顶、隐藏点赞数）。
    func withSettings(_ update: FeedPostSettingsUpdate) -> FeedCard {
        var card = self
        card.pinned = update.pinned ?? pinned
        card.stats.likeCountHidden = update.likeCountHidden ?? stats.likeCountHidden
        return card
    }
}

// MARK: - 图片地址

extension FeedMedia {
    /// 引擎的媒体 key 拼到 `media_base_url`（契约 3.2，引擎保证以 `/` 结尾）后面。只认 https 的基址；
    /// key 像完整地址、以 `/` 开头或带 `..` 的不拼，免得一张卡片把图片请求带到别的主机或路径上。
    func remoteURLString(mediaBaseURL: String?) -> String? {
        guard let base = mediaBaseURL, base.hasPrefix("https://"), base.hasSuffix("/") else { return nil }
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key.contains("://") || key.hasPrefix("/") {
            return nil
        }
        if key.split(separator: "/", omittingEmptySubsequences: false).contains("..") { return nil }
        return base + key
    }
}

// MARK: - 分享 / 收藏

enum FeedShare {
    static let host = "tell.cc"
    static let postPath = "/m"

    /// 一条动态的外链：`https://tell.cc/m#<content id 小写>`。只给 `shareable` 的卡片用（第 29 条：私密账号和非公开动态没有外链）。
    static func postLink(contentId: String) -> String {
        return "https://\(host)\(postPath)#\(contentId.lowercased())"
    }

    static func link(for card: FeedCard) -> String {
        return postLink(contentId: card.id)
    }

    static let snippetLength = 60

    /// 「我的收藏」里那条消息 / 发到聊天 / 分享到快拍的正文：作者和开头一段给电脑端和没装渲染器的版本看，最后一行是链接。
    ///
    /// 和 Android `savedMessageBody` 同一个规则（有标题用标题，否则正文；去首尾空白、换行换成空格、超过 60 个字就截断加「…」）。
    /// 差别：Android 按 UTF-16 单元数截，会把一个 emoji 劈成两半；这里按字符（`Character`）数截，不会劈。
    static func savedMessageBody(for card: FeedCard, link: String) -> String {
        let name = card.author?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let titleText: String? = {
            guard let title = card.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return title
        }()
        var snippet = (titleText ?? card.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if snippet.count > snippetLength {
            snippet = String(snippet.prefix(snippetLength)) + "…"
        }
        let head = [name, snippet].filter { !$0.isEmpty }.joined(separator: "：")
        return head.isEmpty ? link : "\(head)\n\(link)"
    }
}

/// 收藏动态 = 存进「我的收藏」（第三节第 27 条）。端到端加密、电脑上也能看，都是 Signal 给自己发消息本来就有的。
/// iOS 的实现（给自己发一条带链接的消息 / 删掉那条）要用 SignalServiceKit，**这一刀没写**，需在 Mac 上接（见规格）。
protocol FeedSavedMessages: AnyObject {
    /// 给自己发一条带动态链接的消息。
    func add(_ card: FeedCard) async throws
    /// 删掉这台手机存过的那条；没存过或已经手动删了就什么都不做。
    func remove(contentId: String) async throws
}

enum FeedSaveFlow {
    /// 收藏 / 取消收藏的两步：先存进或删掉「我的收藏」里那条（失败就抛，调用方把界面改回来），
    /// 再以假名上报（第三节第 27 条）；上报失败不影响收藏本身，只交给 `onReportFailure`（记日志）。
    static func setSaved(
        _ card: FeedCard,
        saved: Bool,
        savedMessages: FeedSavedMessages,
        source: FeedSource,
        onReportFailure: (Error) -> Void = { _ in },
    ) async throws {
        if saved {
            try await savedMessages.add(card)
        } else {
            try await savedMessages.remove(contentId: card.id)
        }
        do {
            try await source.setSaved(contentId: card.id, saved: saved)
        } catch {
            onReportFailure(error)
        }
    }
}

/// 同一条同时只放一个在途操作（连点由这里挡）：Android 的 `saving` / `reposting` / `voting` 三个 `mutableSetOf<String>()`。
struct FeedInFlight {
    private var ids = Set<String>()

    /// 能开始就记下并返回 true；这条已经在途返回 false。
    mutating func begin(_ id: String) -> Bool {
        return ids.insert(id).inserted
    }

    mutating func end(_ id: String) {
        ids.remove(id)
    }
}
