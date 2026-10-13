//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 动态页取数据的地方。界面只认这个协议，不管背后是内容引擎还是本机样例。和 Android `FeedSource` 同一组方法。
protocol FeedSource: AnyObject {
    func config() async throws -> FeedConfig
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage
    func setLiked(contentId: String, liked: Bool) async throws
    func notInterested(contentId: String) async throws
    func undoNotInterested(contentId: String) async throws

    /// 发一条。`clientNonce` 每条草稿一个，重试时不变（引擎补上 `client_nonce` 去重后会带上，契约 7.2）。
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse
}

/// 发不出去：引擎的发帖接口还不收图片（`media_keys` 和媒体上传待引擎补，契约 7.1），或者没有可用的内容引擎。
enum FeedPublishError: Error {
    case mediaUploadNotAvailable
    case feedNotAvailable
}

/// 内容引擎。列表只给 id，这里再用 Card API 换成卡片（一次最多 `FeedAPI.maxCardIds` 个），
/// 不可用的卡片（删了、被屏蔽、没权限看，引擎不说是哪种）直接跳过。
final class RemoteFeedSource: FeedSource {
    /// 推荐「还有下一页」的标记，不发给服务端。
    static let recommendMore = "more"

    private let api: FeedAPI

    init(api: FeedAPI) {
        self.api = api
    }

    /// 引擎还没有配置接口：能看就用客户端默认值（两栏、编辑精选、默认上限）。
    func config() async throws -> FeedConfig {
        var config = FeedConfig()
        config.enabled = try await api.status().visible
        config.tabs = FeedTab.allCases.map(\.apiName)
        return config
    }

    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage {
        switch tab {
        case .following:
            let page = try await api.feed(tabApiName: tab.apiName, cursor: cursor)
            return FeedTimelinePage(cards: try await hydrate(page.items), nextCursor: page.cursor)
        case .recommend:
            // 推荐没有 cursor：每次给新的一页（看过的引擎记了曝光），给空了才算到底（契约 4.1）
            let page = try await api.feed(tabApiName: tab.apiName, cursor: nil)
            return FeedTimelinePage(cards: try await hydrate(page.items), nextCursor: page.items.isEmpty ? nil : Self.recommendMore)
        }
    }

    func setLiked(contentId: String, liked: Bool) async throws {
        try await api.setReaction(contentId: contentId, reaction: .like, on: liked)
    }

    func notInterested(contentId: String) async throws {
        try await api.notInterested(contentId: contentId, reason: nil)
    }

    func undoNotInterested(contentId: String) async throws {
        try await api.undoNotInterested(contentId: contentId)
    }

    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        // 引擎发帖接口还不收图片和 client_nonce（契约 7.2「待引擎补」）；在那之前带图的帖子不发
        guard draft.attachedImages.isEmpty else {
            throw FeedPublishError.mediaUploadNotAvailable
        }
        return try await api.createPost(draft.request)
    }

    private func hydrate(_ items: [FeedItemRef]) async throws -> [FeedCard] {
        var ids = [String]()
        for item in items where !ids.contains(item.id) {
            ids.append(item.id)
        }
        var cards = [FeedCard]()
        var start = 0
        while start < ids.count {
            let chunk = Array(ids[start..<min(start + FeedAPI.maxCardIds, ids.count)])
            let response = try await api.cards(ids: chunk)
            let byId = Dictionary(response.cards.compactMap { result in result.toCard().map { (result.id, $0) } }, uniquingKeysWith: { first, _ in first })
            // 按列表给的顺序，不按 Card API 返回的顺序
            cards += chunk.compactMap { byId[$0] }
            start += FeedAPI.maxCardIds
        }
        return cards
    }
}

/// 没有可用的内容引擎时用的空来源：配置是「关」，信息流是空的。
///
/// 内容引擎的主机还没进 RegionProfile（ADR-0071 §十四「网络」），Signal-Server 也还没有 `/v1/tellomi/feed/auth`，
/// 所以服务端下发了 `global.feed.enabled` 的账号目前也只会看到空页面（和 Android 一样）。
final class EmptyFeedSource: FeedSource {
    static let shared = EmptyFeedSource()

    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        throw FeedPublishError.feedNotAvailable
    }
}

enum FeedSources {
    /// 内部用户强制打开动态标签时用本机样例（`SampleFeedSource`），看得到卡片、能点赞；其余情况在内容引擎接上之前用空来源。
    /// 样例只在本机内存里，不发任何网络请求。
    static func current() -> FeedSource {
        return TellomiFeed.isSampleDataEnabled ? SampleFeedSource.shared : EmptyFeedSource.shared
    }
}
