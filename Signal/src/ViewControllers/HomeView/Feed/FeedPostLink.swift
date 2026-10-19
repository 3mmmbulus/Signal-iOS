//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedPostLink.swift (new file).
// (If `TellomiLinks.firstPartyShape` in SignalServiceKit should recognise `/m#<id>`, `parsePostId` has to move to
// SignalServiceKit/Util/ — it only needs Foundation. That edit is in a shared file next to the chat link-card code: see the I-16 spec, "overlap".)
// Post links `https://tell.cc/m#<id>` and the landing state of opening one (I-16).
// Mirror of Android `util/TellomiLinks.kt` (`postLink`, `parsePostId`) and `feed/link/FeedPostLinkViewModel.kt`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

enum FeedPostLink {
    static let host = "tell.cc"
    static let path = "/m"

    /// 一条动态的外链：`https://tell.cc/m#<content id>`。只给公开动态、作者不是私密账号时用（第三节第 29 条，`FeedCard.shareable`）。
    static func postLink(contentId: String) -> String {
        return "https://\(host)\(path)#\(contentId.lowercased())"
    }

    // `\z`：只在整串末尾结束（Kotlin 的 `$` 也不吃中间的换行）。
    private static let regex = try! NSRegularExpression(
        pattern: #"^(https://|tellomi://)tell\.cc/m/?#([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\z"#,
        options: [.caseInsensitive]
    )

    /// 动态外链里的 content id（小写），不是就返回 nil。两种都认：`https://tell.cc/m#<id>` 和 App 内的 `tellomi://tell.cc/m#<id>`；
    /// `/m` 后面多一个 `/` 也认（落地页和手打都可能有）。id 必须是 UUID，不认的一律 nil，不去问引擎。
    static func parsePostId(_ link: String?) -> String? {
        guard let link else { return nil }
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              let idRange = Range(match.range(at: 2), in: trimmed) else { return nil }
        return String(trimmed[idRange]).lowercased()
    }
}

/// 打开一条动态的外链（`tell.cc/m#<id>`，内容引擎 docs/api.md「动态的外链」）：用 Card API 取这一张卡，
/// 取到就进详情，取不到显示「这条动态已不可见」。动态没对你开放（本机的开关没开）也按不可见处理，
/// 不另说原因，免得链接本身泄露「有这条动态」。
@MainActor
final class FeedPostLinkStore {
    enum State: Equatable {
        case loading
        case ready(FeedCard)
        case gone
        case failed

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading), (.gone, .gone), (.failed, .failed): return true
            case let (.ready(a), .ready(b)): return a.id == b.id
            default: return false
            }
        }
    }

    private let contentId: String?
    private let feedEnabled: Bool
    private let source: () -> FeedSource
    private var task: Task<Void, Never>?
    private var tasks = [Task<Void, Never>]()

    private(set) var state = State.loading {
        didSet { onChange?(state) }
    }
    var onChange: ((State) -> Void)?

    /// `link` 是打开的那条链接原文；`feedEnabled` 是本机能不能看动态（`TellomiFeed.isTabEnabled`）。
    init(link: String?, feedEnabled: Bool, source: @escaping () -> FeedSource) {
        self.contentId = FeedPostLink.parsePostId(link)
        self.feedEnabled = feedEnabled
        self.source = source
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
    }

    func load() {
        guard let contentId, feedEnabled else {
            task?.cancel()
            state = .gone
            return
        }
        task?.cancel()
        state = .loading
        let feed = source()
        let newTask = Task { [weak self] in
            let next: State
            do {
                let card = try await feed.card(contentId: contentId)
                if let card, card.isRenderable { next = .ready(card) } else { next = .gone }
            } catch {
                Logger.warn("feed post link lookup failed: \(error)")
                next = .failed
            }
            // 点了重试又发了一次：旧的结果不盖掉新的
            guard !Task.isCancelled else { return }
            self?.state = next
        }
        task = newTask
        tasks.append(newTask)
    }
}
