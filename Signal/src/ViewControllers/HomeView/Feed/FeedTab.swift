//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 动态页的两个分栏（`dynamic-feed.md` 第三节第 18 条：只有「推荐 / 关注」）。顺序就是空间顺序：
/// 推荐在左、关注在右，左右滑切换（`10-feed-prototype-log.md` 第 435 行）。
///
/// `apiName` 是内容引擎的路由名：`GET /v1/feed/recommend`、`GET /v1/feed/following`
/// （`docs/adr/0071/client-api-2026-10.md` 4.1）。
enum FeedTab: String, CaseIterable {
    case recommend
    case following

    var apiName: String { rawValue }

    var title: String {
        switch self {
        case .recommend:
            return OWSLocalizedString("TELLOMI_FEED_TAB_RECOMMEND", comment: "Feed: the first tab at the top of the feed (recommended posts).")
        case .following:
            return OWSLocalizedString("TELLOMI_FEED_TAB_FOLLOWING", comment: "Feed: the second tab at the top of the feed (posts from friends and people you follow).")
        }
    }

    var emptyTitle: String {
        switch self {
        case .recommend:
            return OWSLocalizedString("TELLOMI_FEED_RECOMMEND_EMPTY_TITLE", comment: "Feed: title shown while the recommended tab has no posts.")
        case .following:
            return OWSLocalizedString("TELLOMI_FEED_FOLLOWING_EMPTY_TITLE", comment: "Feed: title shown while the following tab has no posts.")
        }
    }

    var emptyBody: String {
        switch self {
        case .recommend:
            return OWSLocalizedString("TELLOMI_FEED_RECOMMEND_EMPTY_BODY", comment: "Feed: body shown while the recommended tab has no posts.")
        case .following:
            return OWSLocalizedString("TELLOMI_FEED_FOLLOWING_EMPTY_BODY", comment: "Feed: body shown while the following tab has no posts.")
        }
    }

    /// 服务端 `config.tabs` 给的分栏（契约第三节），按服务端的顺序；不认识的名字跳过。
    /// 一个都不认识时退回两栏都显示，免得页面空着。
    static func fromApiNames(_ names: [String]) -> [FeedTab] {
        var result = [FeedTab]()
        for name in names {
            if let tab = FeedTab(rawValue: name), !result.contains(tab) {
                result.append(tab)
            }
        }
        return result.isEmpty ? FeedTab.allCases : result
    }
}
