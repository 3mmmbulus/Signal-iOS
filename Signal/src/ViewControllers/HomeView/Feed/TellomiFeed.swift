//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import UIKit

/// M11 动态（ADR-0071、`docs/product/specs/dynamic-feed.md`、tellomi/tellomi#1355）的总开关。
///
/// 客户端不做任何区域判断（ADR-0071 §十五）：显不显示入口看服务端下发的 `global.feed.enabled`，
/// 再加上内容引擎说的能不能看（内测名单、紧急开关，`GET /v1/feed/status`，契约 3.1，见 `FeedEntryCheck`）。
/// 内部用户可以在「Internal → Tellomi Feed → Force feed tab」里先打开，方便在服务端下发之前开发和内测。
/// TestFlight 装的包可以在「关于 Tellomi → 动态预览」里打开样例预览（`TellomiFeedPreview`，默认关，App Store 包里不生效）。
/// 和 Android 的 `TellomiFeed`（tellomi/Signal-Android#180）同口径。
enum TellomiFeed {

    static var isTabEnabled: Bool {
        return isTabEnabled(
            remoteEnabled: RemoteConfig.current.isTellomiFeedEnabled,
            engineVisible: engineVisible,
            engineHasFeed: FeedEngineCapabilities.allows(FeedEngineCapabilities.tabFeatures, features: FeedEngineCapabilities.currentFeatures, usesSampleData: false),
            forcedByInternalUser: TellomiFeedPreview.tabForced(internalForced: isForcedByInternalUser, previewEnabled: isTestFlightPreviewEnabled),
        )
    }

    /// 纯函数版本，单测用。引擎说不能看（不在内测名单、紧急开关关了）时隐藏入口，不显示空列表（契约 1.1）。
    /// 对应 Android `TellomiFeed.isTabEnabled(remoteEnabled, engineVisible, forcedByInternalUser)`。
    /// `engineHasFeed`：引擎 `GET /v1/capabilities` 里有 `feed` 和 `reports`（拿不到算没有，见 `FeedEngineCapabilities`）。
    static func isTabEnabled(remoteEnabled: Bool, engineVisible: Bool, engineHasFeed: Bool = true, forcedByInternalUser: Bool) -> Bool {
        return forcedByInternalUser || (remoteEnabled && engineVisible && engineHasFeed)
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
    /// TestFlight 预览打开时永远不问（预览不发任何请求）。
    static var shouldAskEngine: Bool {
        // 单元测试里没有环境（RemoteConfig 读不到）：当作远程开关关，别崩。
        return TellomiFeedPreview.shouldAskEngine(
            previewEnabled: isTestFlightPreviewEnabled,
            remoteEnabled: SSKEnvironment.hasShared && RemoteConfig.current.isTellomiFeedEnabled,
            internalForced: isForcedByInternalUser,
            internalUseSampleData: useSampleData,
        )
    }

    // MARK: - TestFlight 动态预览（`TellomiFeedPreview`）

    /// 收据只看一次：同一次运行里不会从 TestFlight 变成 App Store。
    private static let isTestFlightInstall: Bool = AppExpiry.isTestFlightInstallOfMainApp

    /// 「关于 Tellomi」里的「动态预览」行出不出现：只有 TestFlight 装的包（App Store 包、Xcode 装的开发包都没有）。
    static var isTestFlightPreviewAvailable: Bool {
        return TellomiFeedPreview.isAvailable(isTestFlightInstall: isTestFlightInstall)
    }

    /// 「动态预览」开关。默认关；不是 TestFlight 包时读永远是 false、写不进去。
    static var isTestFlightPreviewEnabled: Bool {
        get { TellomiFeedPreview.isEnabled(isAvailable: isTestFlightPreviewAvailable, defaults: .standard) }
        set {
            guard TellomiFeedPreview.setEnabled(newValue, isAvailable: isTestFlightPreviewAvailable, defaults: .standard) else { return }
            NotificationCenter.default.post(name: .tellomiFeedTabStateDidChange, object: nil)
        }
    }

    /// 预览打开时，每个动态页面导航栏上方那一行（`navigationItem.prompt`）；没开是 nil。
    static var testFlightPreviewPrompt: String? {
        guard isTestFlightPreviewEnabled else { return nil }
        return OWSLocalizedString(
            "TELLOMI_FEED_TESTFLIGHT_PREVIEW_BADGE",
            value: "Preview · Sample data",
            comment: "Tellomi: line above the navigation bar on every feed page while the TestFlight feed preview is on. The feed shows on-device sample posts only and nothing is sent to a server.",
        )
    }

    /// 页面开关：内部构建照旧看内部开关；别的构建只有预览打开时、跟着预览的页面才开（`TellomiFeedPreview.Page.followsPreview`）。
    private static func isPageEnabled(_ page: TellomiFeedPreview.Page, key: String) -> Bool {
        let switchedOn = TellomiFeedPreview.isPageEnabled(
            page,
            internalBuild: DebugFlags.internalSettings,
            internalValue: { UserDefaults.standard.bool(forKey: key) },
            previewEnabled: isTestFlightPreviewEnabled,
        )
        // 引擎没部署这个功能（或拿不到 capabilities）：入口隐藏
        return switchedOn && FeedEngineCapabilities.allows(page: page)
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
        get { isPageEnabled(.profile, key: profilePageKey) }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: profilePageKey)
        }
    }

    private static let searchKey = "TellomiFeed.search"

    /// 搜索页和话题页入口（动态页右上角的搜索按钮、帖子上的 `#话题`）。默认关；只有内部构建认这个值（正式包里永远是 false），
    /// 存在本机 UserDefaults，和 `isProfilePageEnabled` 一样只是开发开关。还没有 Internal Settings 的开关行（见报告「需要你定的」）。
    static var isSearchEnabled: Bool {
        get { isPageEnabled(.search, key: searchKey) }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: searchKey)
        }
    }

    private static let notificationsKey = "TellomiFeed.notifications"

    /// 通知页入口（动态页左上角的铃铛 + 红点）。默认关；只有内部构建认这个值（正式包里永远是 false），
    /// 存在本机 UserDefaults，和 `isSearchEnabled` 一样只是开发开关。还没有 Internal Settings 的开关行（见报告「需要你定的」）。
    static var isNotificationsEnabled: Bool {
        get { isPageEnabled(.notifications, key: notificationsKey) }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: notificationsKey)
        }
    }

    private static let myPostsKey = "TellomiFeed.myPosts"
    private static let detailEventsKey = "TellomiFeed.detailEvents"
    private static let shareKey = "TellomiFeed.share"

    /// 「我的动态」入口（动态页左上角的文档图标）。默认关；只有内部构建认这个值（正式包里永远是 false），
    /// 存在本机 UserDefaults，和 `isNotificationsEnabled` 一样只是开发开关（Internal Settings 里有开关行）。
    static var isMyPostsEnabled: Bool {
        get { isPageEnabled(.myPosts, key: myPostsKey) }
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
        get { isPageEnabled(.settings, key: settingsKey) }
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
        get { isPageEnabled(.composeExtras, key: composeExtrasKey) }
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
        get { isPageEnabled(.lists, key: listsKey) }
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
        get { isPageEnabled(.articleReader, key: articleReaderKey) }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: articleReaderKey)
        }
    }

    private static let detailExtrasKey = "TellomiFeed.detailExtras"

    /// 未成年人时限（I-15）：引擎说是未成年人模式（`config.minor_mode`，记住上一次的）时，动态每天最多 40 分钟、22:00–6:00 不能用，
    /// 到点盖上提示页。默认关；只有内部构建认这个值，开关行在 Internal Settings。关着时不计时、不锁。
    static var isMinorTimeEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: minorTimeKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: minorTimeKey)
        }
    }

    private static let minorTimeKey = "TellomiFeed.minorTime"

    /// 详情页补全：投票、转发 / 收藏按钮、语音评论播放（只读）、作者批准 / 拒绝等着的回复、从通知点评论直接定位到那一条、自己帖子「···」里的「编辑」（窗口内）。
    /// 默认关；只有内部构建认这个值（正式包里永远是 false），存在本机 UserDefaults，和 `isMyPostsEnabled` 一样只是开发开关
    /// （Internal Settings 里有开关行）。关着时详情页和通知页和之前一样。
    static var isDetailExtrasEnabled: Bool {
        get { isPageEnabled(.detailExtras, key: detailExtrasKey) }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: detailExtrasKey)
        }
    }

    /// 详情事件（I-13）：打开详情报 `open`、离开时按停留报 `dwell` / `quick_exit`。默认关；只有内部构建认这个值，开关行在 Internal Settings。
    /// 关着时不多报任何事件（曝光照旧）。
    static var isDetailEventsEnabled: Bool {
        get { isPageEnabled(.detailEvents, key: detailEventsKey) }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: detailEventsKey)
        }
    }

    /// 详情页「···」里的「分享 / 复制链接」（只给 `shareable` 的帖子），分享完成才报 `share` 事件（I-13）。默认关，同上。
    static var isShareEnabled: Bool {
        get {
            guard DebugFlags.internalSettings else { return false }
            return UserDefaults.standard.bool(forKey: shareKey)
        }
        set {
            guard DebugFlags.internalSettings else { return }
            UserDefaults.standard.set(newValue, forKey: shareKey)
        }
    }

    /// 内部用户强制打开动态标签、并且没关掉「Feed sample data」时，信息流用本机样例，不连内容引擎。
    /// 关掉之后强制打开的标签连当前区的内容引擎，用来联调。
    /// TestFlight 预览打开时一定用本机样例。
    static var isSampleDataEnabled: Bool {
        return TellomiFeedPreview.usesSampleData(
            previewEnabled: isTestFlightPreviewEnabled,
            internalForced: isForcedByInternalUser,
            internalUseSampleData: useSampleData,
        )
    }
}

extension UIViewController {
    /// TestFlight 动态预览打开时，在导航栏上方写「预览·样例数据」（动态的每个页面在 `viewDidLoad` 里调）。
    func tellomiApplyFeedPreviewPrompt() {
        guard let prompt = TellomiFeed.testFlightPreviewPrompt else { return }
        navigationItem.prompt = prompt
    }
}

extension Notification.Name {
    /// 「动态」标签该不该显示可能变了（内部开关切换）。远程配置的变化在回到前台时重新判断。
    static let tellomiFeedTabStateDidChange = Notification.Name("TellomiFeedTabStateDidChange")
}
