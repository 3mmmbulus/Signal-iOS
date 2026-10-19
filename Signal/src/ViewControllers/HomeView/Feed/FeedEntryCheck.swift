//
// DRAFT — NOT COMPILED. Written on Linux; needs a Mac + Xcode to build and test.
// Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedEntryCheck.swift (new file)
// Mirror of Android feed/FeedEntryCheck.kt.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 记住的结果。测试用内存实现，正式的是 `TellomiFeed.engineVisible` / `engineCheckedAtMillis`。
/// （顶层声明：嵌套在 struct 里的 protocol 要 Swift 5.10，不确定工程用哪个版本。）
protocol FeedEntryCheckState: AnyObject {
    var visible: Bool { get set }
    var checkedAtMillis: Int64 { get set }
}

/// 动态入口跟着内容引擎走（契约 3.1）：回到前台时如果离上次问已经过了 `staleAfterMillis`，问一次 `status`，
/// 记住 `visible`；变了就让底栏重画。入口隐藏随这次拉取生效（R-2.11），不另作时间承诺。
///
/// 网络失败不改记住的值（不因为一次断网把入口藏起来，也不因此放出来）；引擎回 404 `feed_hidden` 算「不能看」。
struct FeedEntryCheck {
    static let staleAfterMillis: Int64 = 15 * 60 * 1000

    var shouldAsk: () -> Bool
    var isVisible: () async throws -> Bool
    var state: FeedEntryCheckState
    var clockMillis: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    private final class DefaultState: FeedEntryCheckState {
        var visible: Bool {
            get { TellomiFeed.engineVisible }
            set { TellomiFeed.engineVisible = newValue }
        }
        var checkedAtMillis: Int64 {
            get { TellomiFeed.engineCheckedAtMillis }
            set { TellomiFeed.engineCheckedAtMillis = newValue }
        }
    }

    static func forCurrentProcess() -> FeedEntryCheck {
        return FeedEntryCheck(
            shouldAsk: { TellomiFeed.shouldAskEngine },
            isVisible: {
                guard let remote = FeedSources.engine() as? RemoteFeedSource else {
                    throw FeedAPIError(status: 0, code: "feed_unavailable", retryAfterSeconds: nil)
                }
                return try await remote.isVisible()
            },
            state: DefaultState(),
        )
    }

    /// 过期了才问；返回记住的 `visible` 有没有变（变了要刷新底栏）。会走网络。
    func refreshIfStale() async -> Bool {
        guard shouldAsk() else { return false }
        let now = clockMillis()
        if state.checkedAtMillis != 0, (0..<Self.staleAfterMillis).contains(now - state.checkedAtMillis) {
            return false
        }

        let visible: Bool
        do {
            visible = try await isVisible()
        } catch let error as FeedAPIError where error.isFeedHidden {
            visible = false
        } catch let error as FeedAPIError where error.isAuthNotDeployed {
            // `/v1/tellomi/feed/auth` 没部署（按 2026-10-16 的假设）：入口保持原样（默认不可见），不报错、不更新时间；
            // token 源在退避期内不会再打网络，所以每次回前台也只是本地失败一次。
            Logger.info("feed auth endpoint not deployed; keeping feed entry as is")
            return false
        } catch {
            // 断网、5xx、凭证接口不通：不改记住的值（Android 同）
            Logger.warn("feed status failed: \(error)")
            return false
        }

        let changed = visible != state.visible
        state.visible = visible
        state.checkedAtMillis = now
        return changed
    }
}
