//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import LibSignalClient

/// Tellomi（tellomi/tellomi#1366）：对方改了头像 / 名字，这边要及时一点看到。
///
/// 服务端改资料时不通知任何人（上游设计），这边只能自己重拉。上游 iOS 只在会话页出现时（同一个人 5 分钟一次，内存里记）和每天一轮的
/// 例行刷新（只挑最近 30 天「发过消息」、1 天没拉过的人）时拉；换头像 / 改名不换 profile key。这里补三条，都不动协议，规则和安卓 /
/// Desktop 一样：
/// - 收到 1:1 对方的消息，距上次拉这个人超过 ``refreshOnMessageAfter`` 就顺手拉一次（`MessageReceiver`）。只收不发的联系人
///   进不了例行刷新的名单（上游只在发送路径记「有来往」），这条把他们也补上；
/// - 对方的资料页（会话设置）出现时也顺手拉（`ConversationSettingsViewController`，上游只有会话页）；
/// - 例行刷新调勤：``staleFetchInterval`` 一轮、挑 ``staleAfter`` 没拉过的人（每轮最多 25 个照旧）。
/// 都走「顺手拉」（opportunistic）：只在主 App 里拉（通知扩展里不拉），同一个人 5 分钟内拉过就不再拉。
public enum TellomiProfileRefresh {
    /// 收到 1:1 消息时，距上次拉这个人多久就顺手重拉。
    public static let refreshOnMessageAfter: TimeInterval = 1 * .hour

    /// 例行刷新（cron `.fetchStaleProfiles`）多久一轮（上游 1 天）。
    public static let staleFetchInterval: TimeInterval = 2 * .hour

    /// 例行刷新挑多久没拉过的人（上游 1 天）。
    public static let staleAfter: TimeInterval = 6 * .hour

    /// 从没拉过、或上次拉在 1 小时以前（时钟往回拨过也算）→ 该拉。
    public static func shouldRefreshOnMessage(lastFetchDate: Date?, now: Date) -> Bool {
        guard let lastFetchDate else {
            return true
        }
        return now < lastFetchDate || now.timeIntervalSince(lastFetchDate) >= refreshOnMessageAfter
    }

    /// 收到一条数据消息（`MessageReceiver`，在处理消息的事务里）：1:1、不是自己，到了间隔就在事务提交后顺手拉。群消息不管——群成员靠
    /// 会话页和例行刷新。
    static func onIncomingMessage(
        from aci: Aci,
        isGroupMessage: Bool,
        localIdentifiers: LocalIdentifiers,
        tx: DBWriteTransaction,
    ) {
        guard !isGroupMessage, !localIdentifiers.contains(serviceId: aci) else {
            return
        }
        let userProfile = OWSUserProfile.getUserProfile(for: .otherUser(SignalServiceAddress(aci)), tx: tx)
        guard shouldRefreshOnMessage(lastFetchDate: userProfile?.lastFetchDate, now: Date()) else {
            return
        }
        tx.addSyncCompletion {
            let profileFetcher = SSKEnvironment.shared.profileFetcherRef
            _ = profileFetcher.fetchProfileSync(for: aci, context: ProfileFetchContext(isOpportunistic: true))
        }
    }

    /// 对方的资料页出现：顺手拉一次（同一个人 5 分钟内拉过就不拉）。
    public static func onProfileScreenAppear(serviceId: ServiceId) {
        Task {
            let profileFetcher = SSKEnvironment.shared.profileFetcherRef
            _ = try? await profileFetcher.fetchProfile(for: serviceId, context: ProfileFetchContext(isOpportunistic: true))
        }
    }
}
