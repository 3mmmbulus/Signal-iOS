//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// M11 动态（ADR-0071、`docs/product/specs/dynamic-feed.md`、tellomi/tellomi#1355）的总开关。
///
/// 客户端不做任何区域判断（ADR-0071 §十五）：显不显示入口看服务端下发的 `global.feed.enabled`，
/// 再加上内容引擎说的能不能看（内测名单、紧急开关，`GET /v1/feed/status`，契约 3.1，见 `FeedEntryCheck`）。
/// 内部用户可以在「Internal → Tellomi Feed → Force feed tab」里先打开，方便在服务端下发之前开发和内测。
/// 和 Android 的 `TellomiFeed`（tellomi/Signal-Android#180）同口径。
enum TellomiFeed {

    static var isTabEnabled: Bool {
        return isTabEnabled(
            remoteEnabled: RemoteConfig.current.isTellomiFeedEnabled,
            engineVisible: engineVisible,
            forcedByInternalUser: isForcedByInternalUser,
        )
    }

    /// 纯函数版本，单测用。引擎说不能看（不在内测名单、紧急开关关了）时隐藏入口，不显示空列表（契约 1.1）。
    /// 对应 Android `TellomiFeed.isTabEnabled(remoteEnabled, engineVisible, forcedByInternalUser)`。
    static func isTabEnabled(remoteEnabled: Bool, engineVisible: Bool, forcedByInternalUser: Bool) -> Bool {
        return forcedByInternalUser || (remoteEnabled && engineVisible)
    }

    // MARK: - 引擎上一次说的「能不能看」（Android `TellomiFeedValues.engineVisible` 等；注意 iOS 的 UserDefaults 会进设备备份，和 Android 的「不进备份」不同，靠 15 分钟的过期检查兜底）

    private static let engineVisibleKey = "TellomiFeed.engineVisible"
    private static let engineCheckedAtKey = "TellomiFeed.engineCheckedAt"
    private static let useSampleDataKey = "TellomiFeed.useSampleData"

    /// 引擎上一次回的 `visible`。没问过是 false：入口要等引擎说了能看才出现。
    static var engineVisible: Bool {
        get { UserDefaults.standard.bool(forKey: engineVisibleKey) }
        set { UserDefaults.standard.set(newValue, forKey: engineVisibleKey) }
    }

    /// 上一次问到结果的时间（`timeIntervalSince1970` 毫秒）；0 = 没问过。
    static var engineCheckedAtMillis: Int64 {
        get { Int64(UserDefaults.standard.double(forKey: engineCheckedAtKey)) }
        set { UserDefaults.standard.set(Double(newValue), forKey: engineCheckedAtKey) }
    }

    /// 内部设置「Feed sample data」：强制打开动态标签时，用本机样例（默认 true）还是连当前区的内容引擎（false）。
    static var useSampleData: Bool {
        get { UserDefaults.standard.object(forKey: useSampleDataKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: useSampleDataKey) }
    }

    /// 要不要去问内容引擎能不能看：入口可能出现（远程开关开了），或者内部用户要连引擎联调。
    static var shouldAskEngine: Bool {
        return RemoteConfig.current.isTellomiFeedEnabled || (isForcedByInternalUser && !useSampleData)
    }

    private static let forceTabKey = "TellomiFeed.forceFeedTab"

    /// 内部设置里的「Force feed tab」。只有内部构建认这个值（正式包里永远是 false）。
    /// 存在本机 UserDefaults：只是开发开关，不进备份、不跨设备。
    static var isForcedByInternalUser: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: forceTabKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: forceTabKey)
            NotificationCenter.default.post(name: .tellomiFeedTabStateDidChange, object: nil)
        }
    }

    private static let profilePageKey = "TellomiFeed.profilePage"

    /// 作者主页入口（点帖子 / 评论上的头像或名字）。默认关；只有内部构建认这个值（正式包里永远是 false），
    /// 存在本机 UserDefaults，和「Force feed tab」一样只是开发开关。还没有 Internal Settings 的开关行（见报告「需要你定的」）。
    static var isProfilePageEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: profilePageKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: profilePageKey)
        }
    }

    private static let searchKey = "TellomiFeed.search"

    /// 搜索页和话题页入口（动态页右上角的搜索按钮、帖子上的 `#话题`）。默认关；只有内部构建认这个值（正式包里永远是 false），
    /// 存在本机 UserDefaults，和 `isProfilePageEnabled` 一样只是开发开关。还没有 Internal Settings 的开关行（见报告「需要你定的」）。
    static var isSearchEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: searchKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: searchKey)
        }
    }

    private static let notificationsKey = "TellomiFeed.notifications"

    /// 通知页入口（动态页左上角的铃铛 + 红点）。默认关；只有内部构建认这个值（正式包里永远是 false），
    /// 存在本机 UserDefaults，和 `isSearchEnabled` 一样只是开发开关。还没有 Internal Settings 的开关行（见报告「需要你定的」）。
    static var isNotificationsEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: notificationsKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: notificationsKey)
        }
    }

    private static let myPostsKey = "TellomiFeed.myPosts"

    /// 「我的动态」入口（动态页左上角的文档图标）。默认关；只有内部构建认这个值（正式包里永远是 false），
    /// 存在本机 UserDefaults，和 `isNotificationsEnabled` 一样只是开发开关（Internal Settings 里有开关行）。
    static var isMyPostsEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: myPostsKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: myPostsKey)
        }
    }

    private static let settingsKey = "TellomiFeed.settings"

    /// 动态设置入口（动态页右上角的齿轮，进推荐偏好 / 兴趣标签 / 屏蔽关键词）。默认关；只有内部构建认这个值（正式包里永远是 false），
    /// 存在本机 UserDefaults，和 `isMyPostsEnabled` 一样只是开发开关（Internal Settings 里有开关行）。
    /// 打开时，动态页的信息流才会按本机「完全屏蔽」的词过滤（关着时那份词表不读、不过滤）。
    static var isSettingsEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: settingsKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: settingsKey)
        }
    }

    private static let composeExtrasKey = "TellomiFeed.composeExtras"

    /// 发布页扩展：编辑自己 15 分钟内的帖子（「我的动态」左滑「编辑」）、长文草稿存在本机并能从「我的动态」继续写 / 放弃、
    /// 「只给谁看 / 不给谁看」选人页。默认关；只有内部构建认这个值（正式包里永远是 false），
    /// 存在本机 UserDefaults，和 `isMyPostsEnabled` 一样只是开发开关（Internal Settings 里有开关行）。
    /// 关着时发布页和之前一样：草稿只在内存里，两档选人显示「还不能选」。
    static var isComposeExtrasEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: composeExtrasKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: composeExtrasKey)
        }
    }

    private static let listsKey = "TellomiFeed.lists"

    /// 名单页：关注请求、不看 TA 的动态、不让 TA 看我的动态、动态屏蔽列表、关心的人。入口是动态设置页里的一行和「我的动态」右上角的按钮。
    /// 默认关；只有内部构建认这个值（正式包里永远是 false），存在本机 UserDefaults，和 `isMyPostsEnabled` 一样只是开发开关
    /// （Internal Settings 里有开关行）。关着时设置页和「我的动态」页和之前一样，没有这个入口。
    static var isListsEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: listsKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: listsKey)
        }
    }

    private static let articleReaderKey = "TellomiFeed.articleReader"

    /// 长文阅读页：帖子详情页里长文那一行从「信息流里的卡片」换成整篇长文（大标题、作者和读完要几分钟、小标题 / 引用 / 列表 / 粗体 / 斜体排版）。
    /// 默认关；只有内部构建认这个值（正式包里永远是 false），存在本机 UserDefaults，和 `isMyPostsEnabled` 一样只是开发开关
    /// （Internal Settings 里有开关行）。关着时详情页和之前一样（长文只显示摘要的开头几行）。
    static var isArticleReaderEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: articleReaderKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: articleReaderKey)
        }
    }

    private static let detailExtrasKey = "TellomiFeed.detailExtras"

    /// 详情页补全：投票、转发 / 收藏按钮、语音评论播放（只读）、作者批准 / 拒绝等着的回复、从通知点评论直接定位到那一条、自己帖子「···」里的「编辑」（窗口内）。
    /// 默认关；只有内部构建认这个值（正式包里永远是 false），存在本机 UserDefaults，和 `isMyPostsEnabled` 一样只是开发开关
    /// （Internal Settings 里有开关行）。关着时详情页和通知页和之前一样。
    static var isDetailExtrasEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: detailExtrasKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: detailExtrasKey)
        }
    }

    /// 内部用户强制打开动态标签、并且没关掉「Feed sample data」时，信息流用本机样例，不连内容引擎。
    /// 关掉之后强制打开的标签连当前区的内容引擎，用来联调。
    static var isSampleDataEnabled: Bool {
        return isForcedByInternalUser && useSampleData
    }
}

extension Notification.Name {
    /// 「动态」标签该不该显示可能变了（内部开关切换）。远程配置的变化在回到前台时重新判断。
    static let tellomiFeedTabStateDidChange = Notification.Name("TellomiFeedTabStateDidChange")
}
