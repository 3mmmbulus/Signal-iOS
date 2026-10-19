//
// DRAFT — NOT COMPILED. Written on Linux; needs a Mac + Xcode to build and test.
// Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedDetailEvents.swift (new file)
// Companion to FeedEvents.swift (impression only today). Adds open / dwell / quick_exit / share (契约 6.1).
// Android has NO equivalent yet (feed/FeedEvents.kt only has impression), so this is written from the contract + engine,
// not ported. See android-behaviour-specs/I-13-events.md for the exact behaviour (decisions of 2026-10-16 applied).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 引擎认的 `surface`（`api/interactions.go` 的 `surfaces`）：`recommend`、`following`、`hot`、`search`、`profile`。
enum FeedEventSurface: String {
    case recommend
    case following
    case hot
    case search
    case profile

    /// 推荐 / 关注两栏用栏的路由名；从搜索、主页点进详情时用 `.search` / `.profile`。
    init(tab: FeedTab) {
        // FeedTab.apiName 就是 "recommend" / "following"（FeedAPI.tabRecommend / tabFollowing）
        self = FeedEventSurface(rawValue: tab.apiName) ?? .recommend
    }
}

extension FeedEventPayload {
    static let typeOpen = "open"
    static let typeDwell = "dwell"
    static let typeQuickExit = "quick_exit"
    static let typeShare = "share"

    /// 引擎对 `value` 的范围：0 到 86400（含），超出整批 400 `invalid_event`，所以这里夹住。
    static let maxValue: Double = 86_400

    /// 打开详情（点进一条帖子 / 文章）。
    static func open(contentId: String, surface: FeedEventSurface, at date: Date) -> FeedEventPayload {
        return FeedEventPayload(contentId: contentId, type: typeOpen, surface: surface.rawValue, value: nil, occurredAt: FeedDates.format(date))
    }

    /// 离开详情时停留的秒数。引擎只把 ≥ 30 秒的算一次「深度阅读」（`DwellSeconds = 30`，兴趣 +2）；
/// 不到 30 秒的引擎照样收进事件日志，但兴趣权重是 0（`interactions.go` `record`），所以客户端只在 ≥ 30 秒时才报。
    static func dwell(contentId: String, surface: FeedEventSurface, seconds: TimeInterval, at date: Date) -> FeedEventPayload {
        return FeedEventPayload(contentId: contentId, type: typeDwell, surface: surface.rawValue, value: clamp(seconds), occurredAt: FeedDates.format(date))
    }

    /// 打开后 3 秒内退出（兴趣 -0.5）。`value` 放实际停留秒数（引擎不判定阈值，只要 `type` 是 `quick_exit` 就扣）。
    static func quickExit(contentId: String, surface: FeedEventSurface, seconds: TimeInterval, at date: Date) -> FeedEventPayload {
        return FeedEventPayload(contentId: contentId, type: typeQuickExit, surface: surface.rawValue, value: clamp(seconds), occurredAt: FeedDates.format(date))
    }

    /// 分享出去：**只在用户真的完成了分享动作之后**才报（复制链接成功、系统分享面板返回「已完成」）；
/// 点开分享面板又取消不算。引擎不核实这件事（只检查卡片对你可见），所以这是客户端的责任。兴趣 +5、热度 +3。
    static func share(contentId: String, surface: FeedEventSurface, at date: Date) -> FeedEventPayload {
        return FeedEventPayload(contentId: contentId, type: typeShare, surface: surface.rawValue, value: nil, occurredAt: FeedDates.format(date))
    }

    private static func clamp(_ seconds: TimeInterval) -> Double {
        guard seconds.isFinite else { return 0 }
        return min(max(seconds, 0), maxValue)
    }
}

/// 分享动作的结果。只有 `.completed` 才报 `share`；`.cancelled`（关掉分享面板、没选目标）什么都不报。
/// 调用方把 `UIActivityViewController.completionWithItemsHandler` 的 `completed` 和「复制链接」成功与否映射到这里。
///
/// `shareable` 是卡片外层的 `shareable`（公开动态、作者不是私密账号；`FeedCard.shareable`）：不能分享的卡片没有分享入口，
/// 也就不该有 `share` 事件——引擎不检查这一点（交叉核对 G-3），所以在这里拦住。
/// 转发（`PUT …/repost`）有自己的接口和同样的兴趣权重，**不要**再补报一次 `share`；调用方走转发时不要调用这里。
enum FeedShareOutcome {
    case completed
    case cancelled

    func event(contentId: String, surface: FeedEventSurface, shareable: Bool, at date: Date) -> FeedEventPayload? {
        guard shareable else { return nil }
        switch self {
        case .completed:
            return .share(contentId: contentId, surface: surface, at: date)
        case .cancelled:
            return nil
        }
    }
}

/// 一次「打开详情 → 离开详情」要报的事件（纯逻辑，界面在出现 / 消失时调；和 `FeedImpressionTracker` 一样可单测）。
///
/// 语义按引擎 `docs/api.md` 第 198–200 行和 `interactions.go`（2026-10-16 决定，见 B-8 对账记录）：
/// - 打开：报 `open`（兴趣 +1）。
/// - 离开：停留 ≤ `quickExitThreshold`（3 秒）→ 报 `quick_exit`（兴趣 −0.5，不报 `dwell`）；
///   停留 ≥ `minDwellSeconds`（30 秒）→ 报 `dwell`（`value` = 秒，兴趣 +2）；
///   3 到 30 秒之间：只有 `open`，不再补事件。
/// - 同时只有一次详情；还没离开就又打开了一个，先把上一个按「现在离开」收尾。
/// - 退到后台算离开（调用方在进入后台时调 `closed`）；回到前台不重新计时、也不重发 `open`。
///
/// 阈值是产品侧的判断，可以调：`reportsQuickExit`、`quickExitThreshold`、`minDwellSeconds` 都是 `var`。
/// 注意引擎**没有**对 `quick_exit` 的 3 秒做校验，所以这个阈值完全由客户端把关；契约原文的 2 秒已作废。
struct FeedDetailEventTracker {
    var reportsQuickExit = true
    /// 「3 秒内退出」：停留 ≤ 这个值算 `quick_exit`（含 3 秒整）。
    var quickExitThreshold: TimeInterval = 3
    /// 停留不到这么多秒就不报 `dwell`：引擎只在 ≥ 30 秒时加权（`DwellSeconds = 30`），更短的报了也是 0 权重。
    var minDwellSeconds: TimeInterval = 30

    private struct Open {
        var contentId: String
        var surface: FeedEventSurface
        var openedAt: Date
    }

    private var current: Open?

    var isOpen: Bool {
        return current != nil
    }

    /// 打开了一条。返回要报的事件（如果前一个还没收尾，先带上它的收尾事件）。
    mutating func opened(contentId: String, surface: FeedEventSurface, now: Date) -> [FeedEventPayload] {
        var events = closed(now: now)
        current = Open(contentId: contentId, surface: surface, openedAt: now)
        events.append(.open(contentId: contentId, surface: surface, at: now))
        return events
    }

    /// 离开了（返回、切标签、退到后台）。没有打开的详情就什么也不报。
    mutating func closed(now: Date) -> [FeedEventPayload] {
        guard let open = current else { return [] }
        current = nil
        // 时钟往回拨过：当作 0 秒
        let elapsed = max(now.timeIntervalSince(open.openedAt), 0)
        if reportsQuickExit, elapsed <= quickExitThreshold {
            return [.quickExit(contentId: open.contentId, surface: open.surface, seconds: elapsed, at: now)]
        }
        if elapsed >= minDwellSeconds {
            return [.dwell(contentId: open.contentId, surface: open.surface, seconds: elapsed, at: now)]
        }
        return []
    }
}
