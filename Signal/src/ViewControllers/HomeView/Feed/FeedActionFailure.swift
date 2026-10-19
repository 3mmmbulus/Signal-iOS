//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 一个动作（删评论、举报、不感兴趣…）失败时界面该怎么说。把内容引擎的错误（契约 1.1）分成几类，各个 store 共用，免得每处各写一遍：
/// - 429，或带 `Retry-After` 的 503，或本机退避（`throttled_locally`）：被限速。带上还要等几秒（1…3600），界面可以说「请 N 秒后再试」；没有头就是 nil。
/// - 404 `feed_hidden`：这个区域的动态被关了（紧急开关 / 不在内测名单）：页面该收起，不是「操作失败」。
/// - 409 `profile_required`：要先建自己的公开主页。
/// - 其它 404：内容已经没了。
/// - 其余（包括网络错误、别的 5xx）：「操作失败」，**不自动重试**（动作不是幂等的，重试由用户再点一次）。
enum FeedActionFailure: Equatable {
    case throttled(retryAfterSeconds: Int?)
    case feedHidden
    case profileRequired
    case gone
    case failed

    static func classify(_ error: Error) -> FeedActionFailure {
        guard let api = error as? FeedAPIError else { return .failed }
        if api.isFeedHidden { return .feedHidden }
        if api.status == 429 || api.code == FeedAPI.backoffCode || (api.status == 503 && api.retryAfterSeconds != nil) {
            return .throttled(retryAfterSeconds: api.retryAfterSeconds)
        }
        if api.code == "profile_required" { return .profileRequired }
        if api.status == 404 { return .gone }
        return .failed
    }
}
