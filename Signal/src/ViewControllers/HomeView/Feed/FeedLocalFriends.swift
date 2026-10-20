//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//
// I-11 好友同步 + 「部分可见 / 不给谁看」选人的本机接线。
// 「好友是谁」照 Android `friends/FeedFriends.kt`（tellomi 843ca6a1，`myFriendAcis`）：
// 通讯录里的 Signal 用户，或者在聊天里接受过（资料共享白名单）的人；屏蔽了的、隐藏了的、没注册的、我自己都不算。
// 只读本机数据库，不改任何聊天 / 联系人数据；不碰附件面板、会话列表、相机等。
// NOT COMPILED on Linux（swiftc -parse only）; needs a Mac.
//

import Foundation
import SignalServiceKit

// MARK: - 本机好友

enum FeedLocalFriends {
    /// 一个本机好友（选人页要名字，同步只要 ACI）。
    struct Friend: Equatable {
        var recipientId: Int64
        var aci: String
        var displayName: String
    }

    /// 判断一个人算不算好友（纯逻辑，单测用；和 Android 的 SQL 条件一一对应）。
    static func isFriend(isSelf: Bool, hasAci: Bool, isRegistered: Bool, isBlocked: Bool, isHidden: Bool, isProfileWhitelisted: Bool, isSystemContact: Bool) -> Bool {
        guard !isSelf, hasAci, isRegistered, !isBlocked, !isHidden else { return false }
        return isProfileWhitelisted || isSystemContact
    }

    /// 读本机数据库。没有环境（单测 / 启动早期）或没登录时是空的。会读整张 recipient 表，别在主线程上等。
    static func load() -> [Friend] {
        guard SSKEnvironment.hasShared else { return [] }
        let deps = DependenciesBridge.shared
        let env = SSKEnvironment.shared
        return env.databaseStorageRef.read { tx -> [Friend] in
            guard let local = deps.tsAccountManager.localIdentifiers(tx: tx) else { return [] }
            var result = [Friend]()
            deps.recipientDatabaseTable.enumerateAll(tx: tx) { recipient in
                guard let aci = recipient.aci else { return }
                let address = recipient.address
                let friend = isFriend(
                    isSelf: aci == local.aci,
                    hasAci: true,
                    isRegistered: recipient.isRegistered,
                    isBlocked: env.blockingManagerRef.isAddressBlocked(address, transaction: tx),
                    isHidden: deps.recipientHidingManager.isHiddenRecipient(recipientId: recipient.id, tx: tx),
                    isProfileWhitelisted: env.profileManagerRef.isUser(inProfileWhitelist: address, transaction: tx),
                    isSystemContact: env.contactManagerRef.fetchSignalAccount(for: address, transaction: tx) != nil,
                )
                guard friend else { return }
                let name = env.contactManagerRef.displayName(for: address, tx: tx).resolvedValue()
                result.append(Friend(recipientId: recipient.id, aci: aci.serviceIdString, displayName: name))
            }
            return sorted(result)
        }
    }

    /// 按名字排（本地化比较），同名按 ACI，顺序稳定。
    static func sorted(_ friends: [Friend]) -> [Friend] {
        return friends.sorted { lhs, rhs in
            let order = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return order == .orderedSame ? lhs.aci < rhs.aci : order == .orderedAscending
        }
    }
}

/// 选人页的候选人：本机好友（发布页「部分可见 / 不给谁看」）。
final class LocalFeedAudienceCandidates: FeedAudienceCandidateSource {
    private let load: @Sendable () -> [FeedLocalFriends.Friend]

    init(load: @escaping @Sendable () -> [FeedLocalFriends.Friend] = { FeedLocalFriends.load() }) {
        self.load = load
    }

    func candidates() async throws -> [FeedAudienceCandidate] {
        let load = self.load
        return await Task.detached(priority: .userInitiated) {
            load().map { FeedAudienceCandidate(recipientId: $0.recipientId, aci: $0.aci, displayName: $0.displayName) }
        }.value
    }
}

// MARK: - 当前引擎的 capabilities

/// 用 `FeedEngineCapabilities` 已经问到（并缓存）的能力表回答，不另发请求。拿不到 = 没有。
/// 注意：样例数据 / 不问引擎时 `allows` 会放行，所以用它的地方自己先排除样例（见 `FeedFriendSyncRunner.isEnabled`、`FeedComposeViewController.make`）。
struct CurrentEngineFeatureGate: FeedFeatureGate {
    func isAvailable(_ feature: String) async -> Bool {
        return FeedEngineCapabilities.allows([feature])
    }
}

// MARK: - 好友同步

/// 动态页出现、回到前台时调 `syncIfStale()`；`FeedFriendSync` 自己按 15 分钟限频、按 `friend_assertions` 判断。
/// 开关：沿用 `TellomiFeed.isComposeExtrasEnabled`（默认关、只有内部构建认），加上动态标签开着、不是样例数据、在问引擎。
enum FeedFriendSyncRunner {
    static func isEnabled(tabEnabled: Bool, sampleData: Bool, asksEngine: Bool, extrasEnabled: Bool) -> Bool {
        return tabEnabled && !sampleData && asksEngine && extrasEnabled
    }

    private static let sync = FeedFriendSync(
        enabled: {
            isEnabled(
                tabEnabled: TellomiFeed.isTabEnabled,
                sampleData: TellomiFeed.isSampleDataEnabled,
                asksEngine: TellomiFeed.shouldAskEngine,
                extrasEnabled: TellomiFeed.isComposeExtrasEnabled,
            )
        },
        engineKey: {
            let region = TellomiRegions.active()
            return "\(region.id.rawValue) \(region.feed)"
        },
        friends: { Set(FeedLocalFriends.load().map(\.aci)) },
        signer: SignalServerFeedSigner(),
        engine: { assertion in
            guard let remote = FeedSources.engine() as? RemoteFeedSource else { throw FeedPublishError.feedNotAvailable }
            try await remote.reportFriendAssertion(assertion)
        },
        state: StoredFeedFriendSyncState(storage: FeedLocalStorages.backupExcluded),
        features: CurrentEngineFeatureGate(),
    )

    private static let running = AtomicBool(false, lock: .sharedGlobal)

    /// 不等结果；同一时间只跑一个。
    static func syncIfStale() {
        guard running.tryToSetFlag() else { return }
        Task.detached(priority: .utility) {
            let outcome = await sync.syncIfStale()
            if outcome != .skipped && outcome != .unchanged {
                Logger.info("feed friend sync: \(outcome)")
            }
            running.set(false)
        }
    }
}
