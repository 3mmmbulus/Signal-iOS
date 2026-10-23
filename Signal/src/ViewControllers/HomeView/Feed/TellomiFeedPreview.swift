//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// TestFlight 动态预览（erel 2026-10-19：TestFlight 31 里要能看到动态页面）。
///
/// 2026-10-24 产品改定（TF32 真机上「关于 Tellomi」里没有开关之后）：TestFlight 构建**默认**就显示底栏「动态」（动态在最左，
/// 打开 App 仍默认选「聊天」），用本机样例，跟着预览的页面全开，分享 / 复制链接照旧关；商店版全关、没有入口。
/// 「关于 Tellomi」里的开关保留，只在 TestFlight 构建出现，默认开，可以手动关掉（关掉后底栏没有「动态」）。
///
/// 内容引擎还没部署、`global.feed.enabled` 也没下发，而「Internal → Force feed tab」只在 `DebugFlags.internalSettings`
/// （`build <= .internal`）里有，TestFlight 包（`FeatureBuild.production`，和 App Store 是同一个二进制）用不了。
/// 所以加一个只有 **TestFlight 装的包** 认的开关：在「设置 → 关于 Tellomi」里手动打开（默认关），打开后底栏出现「动态」，
/// 所有动态页面都用本机样例（`SampleFeedSource`），不连内容引擎、不向 Signal-Server 取凭证，页面顶上写着「预览·样例数据」。
///
/// 怎么保证正式包里永远不生效：
/// 1. 是不是 TestFlight 只看收据（`AppExpiry.isTestFlightInstall`）：TestFlight 装的包带 `sandboxReceipt`，
///    App Store 装的包收据叫 `receipt`，Xcode 直接装的开发包没有收据文件。不看 `FeatureBuild`（TestFlight 和 App Store 是同一个包，分不出来）。
/// 2. 不是 TestFlight 时：开关行不出现，读永远是 false，写什么都不存（即使备份里带着以前存的 true 也不认）。
/// 3. `isCompiledIn`：总闸，跟构建走、不再手改：只有 Info.plist 里 `TellomiTestFlightFeed` 是 `YES` 才开。
///    这个键在 `Signal/Signal-Info.plist` 里写的是 `$(TELLOMI_TESTFLIGHT_FEED)`，没设这个 build setting 时展开成空 = 关；
///    打 TestFlight 时在 `xcodebuild archive` 命令行上加 `TELLOMI_TESTFLIGHT_FEED=YES`。
///    提交 App Store 审核的构建**不要**加（App Review 的设备也是沙盒收据，只能靠这个闸挡）。
/// 不认任何账号：谁装了 TestFlight 包、自己去打开，谁就能看到样例；样例里没有真实的人和内容。
enum TellomiFeedPreview {

    /// Info.plist 键名（值来自 build setting `TELLOMI_TESTFLIGHT_FEED`）。
    static let infoPlistKey = "TellomiTestFlightFeed"

    /// 总闸：只有这个构建显式标了 TestFlight（Info.plist `TellomiTestFlightFeed` = `YES`）才开；没标、空、别的值都是关。
    static var isCompiledIn: Bool {
        return isCompiledIn(infoPlistValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey))
    }

    static func isCompiledIn(infoPlistValue: Any?) -> Bool {
        if let value = infoPlistValue as? String {
            return value == "YES"
        }
        if let value = infoPlistValue as? Bool {
            return value
        }
        return false
    }

    /// 存在本机 UserDefaults（只是测试开关，和其他 `TellomiFeed.*` 开关一样）。
    static let storageKey = "TellomiFeed.testFlightPreview"

    /// 开关行出不出现、存的值认不认：总闸开着，并且这个包是 TestFlight 装的。
    static func isAvailable(compiledIn: Bool = isCompiledIn, isTestFlightInstall: Bool) -> Bool {
        return compiledIn && isTestFlightInstall
    }

    /// 读：不可用时永远 false，不管存了什么；没存过是 true（TestFlight 构建默认开，2026-10-24 产品决定）。
    static func isEnabled(isAvailable: Bool, defaults: UserDefaults) -> Bool {
        guard isAvailable else { return false }
        return defaults.object(forKey: storageKey) as? Bool ?? true
    }

    /// 写：不可用时什么都不存，返回 false；存了返回 true（调用方据此通知底栏重画）。
    @discardableResult
    static func setEnabled(_ enabled: Bool, isAvailable: Bool, defaults: UserDefaults) -> Bool {
        guard isAvailable else { return false }
        defaults.set(enabled, forKey: storageKey)
        return true
    }

    /// 动态里那些「默认关、只有内部构建认」的页面开关（`TellomiFeed.isSearchEnabled` 等）。
    enum Page: CaseIterable {
        case profile
        case search
        case notifications
        case myPosts
        case settings
        case composeExtras
        case lists
        case articleReader
        case detailExtras
        case detailEvents
        /// 「分享 / 复制链接」：会把帖子外链交给系统分享面板、发到 App 外面，样例帖子的链接是打不开的。预览里不开。
        case share
        /// 未成年人时限：照原样，只有内部构建的开关行能开（产品要求「未成年人模式等现有逻辑不变」）。
        case minorTime

        /// 预览打开时跟着打开的页面。都只读写 `SampleFeedSource`（本机内存），不连网。
        var followsPreview: Bool {
            switch self {
            case .profile, .search, .notifications, .myPosts, .settings, .composeExtras, .lists, .articleReader, .detailExtras, .detailEvents:
                return true
            case .share, .minorTime:
                return false
            }
        }
    }

    /// 页面开关最后的值：内部构建照旧只看内部开关；别的构建（TestFlight / 正式包）只有预览打开、并且这一页跟着预览时才开。
    static func isPageEnabled(_ page: Page, internalBuild: Bool, internalValue: () -> Bool, previewEnabled: Bool) -> Bool {
        if internalBuild {
            return internalValue()
        }
        return previewEnabled && page.followsPreview
    }

    // MARK: - 接到 `TellomiFeed` 的式子（纯函数，单测用）

    /// 「动态」标签要不要强制显示：内部开关，或者预览。
    static func tabForced(internalForced: Bool, previewEnabled: Bool) -> Bool {
        return internalForced || previewEnabled
    }

    /// 信息流用不用本机样例：预览打开一定用；否则照旧（内部强制打开并且没关「Feed sample data」）。
    static func usesSampleData(previewEnabled: Bool, internalForced: Bool, internalUseSampleData: Bool) -> Bool {
        return previewEnabled || (internalForced && internalUseSampleData)
    }

    /// 要不要去问内容引擎 `status`：预览打开时永远不问；否则照旧。
    static func shouldAskEngine(previewEnabled: Bool, remoteEnabled: Bool, internalForced: Bool, internalUseSampleData: Bool) -> Bool {
        guard !previewEnabled else { return false }
        return remoteEnabled || (internalForced && !internalUseSampleData)
    }
}
