//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 按内容引擎 `GET /v1/capabilities` 隐藏没部署的功能入口（产品 2026-10-20 定）。
///
/// - 拿不到 capabilities（没问过、断网、超时、404、版本不认、解析不了）一律按「没部署」：入口隐藏。不拿旧的顶（和 `FeedCapabilitiesCache` 同口径）。
/// - 上次成功的结果存本机（产品 2026-10-20 第二次定）：按账号 + 引擎地址分开存，退出登录时清掉（`clearOnLogout`）。
///   冷启动先用它画底栏（`loadAtLaunch`，在第一次画底栏之前同步读，底栏不闪），后台再问，有变化才重画。
///   存的结果超过 24 小时（或时钟被调回去）、从没成功过、没登录：按「拿不到就藏」。问失败时退回到存的结果（同样看 24 小时）。
/// - 信息流用本机样例时（TestFlight 预览、内部「Force feed tab」+「Feed sample data」）不连引擎，这一层不管，照预览 / 内部开关原样。
/// - 只在 `TellomiFeed.shouldAskEngine` 为真时才去问（预览不发任何请求）。不问引擎时（远程开关关、没有内部强制联调）这一层也不拦子入口：
///   那时动态标签本身就不出现（`isTabEnabled` 要远程开关 + 引擎可见 + `feed`），子入口到不了；这样单测和预览不受影响。
/// - 举报入口不藏（合规红线，产品 2026-10-20）：引擎没有 `reports` 时整个动态一起藏（`tabFeatures`）。
/// - TestFlight 预览和内部「强制 + 样例」不受这一层影响；商店包里它们是关的：预览要 TestFlight 收据（`TellomiFeedPreview.isAvailable`），
///   内部开关要 `DebugFlags.internalSettings`（商店包 `build == .production` 时是 false），见 `TellomiFeedEngineCapabilitiesGateTests`。
enum FeedEngineCapabilities {

    // MARK: - 入口要哪些能力

    /// 「动态」标签：要 `feed`，也要 `reports`——举报后端没部署就整个动态不出现（举报入口本身从不按能力藏）。
    static let tabFeatures = [FeedFeature.feed, FeedFeature.reports]
    /// 帖子详情页的评论输入框。
    static let commentFeatures = [FeedFeature.comments]
    /// 点赞（心形）。
    static let likeFeatures = [FeedFeature.reactions]
    /// 投票（详情页的投票行、发布页「加投票」）。
    static let pollFeatures = [FeedFeature.polls]
    /// 语音评论（评论里的播放行）。
    static let voiceCommentFeatures = [FeedFeature.voiceComments]
    /// 动态页右下角的发布按钮。
    static let composeFeatures = [FeedFeature.posting]

    /// 各个页面开关要的能力；空 = 引擎没有对应的能力名，这一层不拦（见报告「映射待产品确认」）。
    static func requiredFeatures(for page: TellomiFeedPreview.Page) -> [String] {
        switch page {
        case .profile: return [FeedFeature.profiles]
        case .search: return [FeedFeature.search]
        case .notifications: return [FeedFeature.notifications]
        case .myPosts: return [FeedFeature.posting]
        case .composeExtras: return [FeedFeature.posting]
        case .lists: return [FeedFeature.follow, FeedFeature.blocks]
        case .detailEvents: return [FeedFeature.events]
        case .settings, .articleReader, .detailExtras, .share, .minorTime: return []
        }
    }

    // MARK: - 判断（纯函数，单测用）

    /// `features == nil` 是「没拿到」：按没部署处理。
    /// `asksEngine == false`：没在问引擎（标签本身不会出现），子入口不拦。
    static func allows(_ required: [String], features: Set<String>?, usesSampleData: Bool, asksEngine: Bool = true) -> Bool {
        if usesSampleData || !asksEngine { return true }
        guard let features else { return false }
        return required.allSatisfy { features.contains($0) }
    }

    /// 一次问的结果记成什么：只有 `available` 记下能力表，别的都是 nil（= 没部署）。
    static func features(from snapshot: FeedCapabilitiesSnapshot) -> Set<String>? {
        if case let .available(capabilities) = snapshot { return capabilities.features }
        return nil
    }

    // MARK: - 当前进程

    // MARK: - 存本机（纯函数 + 可换的 UserDefaults，单测用）

    static let storageKey = "TellomiFeed.engineCapabilities"
    static let maxStoredAge: TimeInterval = 24 * 60 * 60

    struct Stored: Codable, Equatable {
        var features: [String]
        var fetchedAt: Date
    }

    /// 存的那一份按「账号 + 引擎地址」分开。
    static func scope(account: String, engine: String) -> String {
        return "\(account) \(engine)"
    }

    /// 存的结果还能不能用：0 ≤ 年龄 < 24 小时。
    static func usable(_ stored: Stored?, now: Date, maxAge: TimeInterval = maxStoredAge) -> Set<String>? {
        guard let stored else { return nil }
        let age = now.timeIntervalSince(stored.fetchedAt)
        guard age >= 0, age < maxAge else { return nil }
        return Set(stored.features)
    }

    static func load(scope: String, defaults: UserDefaults) -> Stored? {
        guard let all = defaults.dictionary(forKey: storageKey) as? [String: Data], let data = all[scope] else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func save(_ stored: Stored, scope: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        var all = defaults.dictionary(forKey: storageKey) as? [String: Data] ?? [:]
        all[scope] = data
        defaults.set(all, forKey: storageKey)
    }

    static func clearStored(defaults: UserDefaults) {
        defaults.removeObject(forKey: storageKey)
    }

    /// 一次刷新之后该记成什么：问到了用新的；问失败了退回到存的（看 24 小时）。
    static func next(after snapshot: FeedCapabilitiesSnapshot, stored: Stored?, now: Date) -> Set<String>? {
        return features(from: snapshot) ?? usable(stored, now: now)
    }

    private static let lock = NSLock()
    private static var storedFeatures: Set<String>?
    private static var cacheEntry: (key: String, cache: FeedCapabilitiesCache)?

    /// 上一次问到的能力表；nil = 没拿到。
    static var currentFeatures: Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return storedFeatures
    }

    static func allows(_ required: [String]) -> Bool {
        return allows(required, features: currentFeatures, usesSampleData: TellomiFeed.isSampleDataEnabled, asksEngine: TellomiFeed.shouldAskEngine)
    }

    static func allows(page: TellomiFeedPreview.Page) -> Bool {
        return allows(requiredFeatures(for: page))
    }

    /// 当前登录的账号（ACI）；没登录是 nil。
    private static func currentAccount() -> String? {
        return DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aci.serviceIdString
    }

    /// 当前账号 + 当前区引擎地址；没登录或地址不是 https 时没有。
    private static func currentScope() -> String? {
        let region = TellomiRegions.active()
        guard let account = currentAccount(), let baseURL = URL(string: region.feed), baseURL.scheme == "https" else { return nil }
        return scope(account: account, engine: baseURL.absoluteString)
    }

    /// 冷启动、第一次画底栏之前调：用上次成功的结果（24 小时内）。只读本机，不走网络。
    static func loadAtLaunch(now: Date = Date()) {
        let restored = currentScope().flatMap { usable(load(scope: $0, defaults: .standard), now: now) }
        lock.lock()
        defer { lock.unlock() }
        storedFeatures = restored
    }

    /// 退出登录：清掉本机存的和内存里的。
    static func clearOnLogout() {
        clearStored(defaults: .standard)
        lock.lock()
        defer { lock.unlock() }
        storedFeatures = nil
        cacheEntry = nil
    }

    /// 当前区的缓存（切区后地址变了就换一份）。地址不是 https 时没有。
    private static func cacheForActiveRegion() -> FeedCapabilitiesCache? {
        let region = TellomiRegions.active()
        guard let baseURL = URL(string: region.feed), baseURL.scheme == "https" else { return nil }
        let key = "\(region.id.rawValue) \(region.feed)"
        lock.lock()
        defer { lock.unlock() }
        if let cacheEntry, cacheEntry.key == key { return cacheEntry.cache }
        let cache = FeedCapabilitiesCache(fetcher: FeedCapabilitiesFetcher(baseURL: baseURL))
        cacheEntry = (key, cache)
        return cache
    }

    /// 问一次（缓存自己限频）；返回记住的能力表有没有变（变了要重画入口）。会走网络。
    @discardableResult
    static func refresh() async -> Bool {
        var next: Set<String>?
        if TellomiFeed.shouldAskEngine, let cache = cacheForActiveRegion() {
            let snapshot = await cache.current()
            let now = Date()
            if let scope = currentScope() {
                if let fresh = features(from: snapshot) {
                    save(Stored(features: fresh.sorted(), fetchedAt: now), scope: scope, defaults: .standard)
                }
                next = Self.next(after: snapshot, stored: load(scope: scope, defaults: .standard), now: now)
            } else {
                // 没登录：不存，也不认存的
                next = features(from: snapshot)
            }
        }
        lock.lock()
        defer { lock.unlock() }
        let changed = next != storedFeatures
        storedFeatures = next
        return changed
    }
}
