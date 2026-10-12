//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// Tellomi（tellomi/tellomi#1139）：什么时候用「必须更新」阻断页盖住整个 App。
///
/// 照上游 `ClockSkewMonitoringManager` 的做法：过期状态一变（`AppExpiry.AppExpiryDidChange`，499 与到期定时器都会发），
/// 以及每次回到前台，都重新判断一次。盖不盖按 owner 2026-09-24 定的三条规则（taishi 中转包 6）：
/// - 只有服务端判定的（499、远程配置宣布到期）才盖；本机构建到期只降成只读（上游的会话列表提示 + 输入框换成「更新」）。
/// - 没有可用的更新渠道（App Store / TestFlight 对外开放之前）不盖：按钮无处可去，直接只读。
/// - 用户在阻断页选了「暂不更新，只看聊天记录」，这个版本就不再盖；装上新版本，这个选择就作废。
/// 连 Signal 官方服务时保持上游行为。
///
/// tellomi/tellomi#1491：另外读更新清单（`TellomiUpdateManifests`）——启动和每次回到前台都拉（只读时不节流），
/// 清单判「必须」会让 `AppExpiry` 过期、撤销会解开；清单里验过签的 TestFlight 公开链接就是更新渠道，
/// 阻断页的原因、版本和「了解更新内容」也跟着清单走。
class TellomiUpdateRequiredMonitoringManager {
    /// iOS 的更新渠道。owner 2026-09-25 定：用 TestFlight 外部测试的公开链接发给朋友（以后上架就是 App Store 条目）。
    /// 链接到了填在这里，同时把 `TSConstants.appStoreUrl` 换成同一个地址：阻断页只在两者一致时才会出现（规则 3，见 `hasUpdateChannel`）。
    /// 为 nil 时 iOS 不硬拦，只降成只读。放在这个文件而不放 TSConstants：那里 donationsEnabled 后面是别的分支插新常量的地方。
    static let updateChannelUrl: URL? = nil

    private let appExpiry: AppExpiry
    private let windowManager: TellomiUpdateRequiredBlockHost
    private let userDefaults: UserDefaults
    private let isTellomiDeployment: Bool
    private let appStoreUrl: URL
    private let updateChannelUrl: URL?
    private let currentAppVersion: String
    private let manifest: () -> TellomiUpdateManifest?
    private let refreshManifest: (_ force: Bool) async -> Void

    /// 后面几个参数只为用例能把「出口」一路接起来（taishi 审查 b15 启用前置 2），App 里都用缺省值。
    init(
        appExpiry: AppExpiry,
        windowManager: TellomiUpdateRequiredBlockHost,
        userDefaults: UserDefaults = CurrentAppContext().appUserDefaults(),
        isTellomiDeployment: Bool = !TSConstants.isUsingProductionService,
        appStoreUrl: URL = TSConstants.appStoreUrl,
        updateChannelUrl: URL? = TellomiUpdateRequiredMonitoringManager.updateChannelUrl,
        currentAppVersion: String = AppVersionImpl.shared.currentAppVersion,
        manifest: @escaping () -> TellomiUpdateManifest? = { TellomiUpdateManifests.current(db: DependenciesBridge.shared.db) },
        refreshManifest: @escaping (_ force: Bool) async -> Void = { force in
            await TellomiUpdateManifests.refresh(force: force, db: DependenciesBridge.shared.db, appExpiry: DependenciesBridge.shared.appExpiry)
        },
    ) {
        self.appExpiry = appExpiry
        self.windowManager = windowManager
        self.userDefaults = userDefaults
        self.isTellomiDeployment = isTellomiDeployment
        self.appStoreUrl = appStoreUrl
        self.updateChannelUrl = updateChannelUrl
        self.currentAppVersion = currentAppVersion
        self.manifest = manifest
        self.refreshManifest = refreshManifest
    }

    func start() {
        AssertIsOnMainThread()

        windowManager.updateRequiredViewChatsOnlyHandler = { [weak self] in
            self?.chooseViewChatsOnly()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateIsBlocked),
            name: AppExpiry.AppExpiryDidChange,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: .OWSApplicationDidBecomeActive,
            object: nil,
        )

        updateIsBlocked()
        refreshManifestThenUpdate()
    }

    @objc
    private func applicationDidBecomeActive() {
        updateIsBlocked()
        refreshManifestThenUpdate()
    }

    /// 拉一次更新清单再重新判断（需求 §3.2：启动 + 回到前台；阻断页盖着时不节流，撤销才能尽快生效）。
    private func refreshManifestThenUpdate() {
        AssertIsOnMainThread()
        guard isTellomiDeployment else {
            return
        }
        let force = windowManager.isUpdateRequiredBlockActive
        Task { @MainActor in
            await self.refreshManifest(force)
            self.updateIsBlocked()
        }
    }

    @objc
    private func updateIsBlocked() {
        AssertIsOnMainThread()

        let now = Date()
        let pageInfo = Self.pageInfo(
            manifest: isTellomiDeployment ? manifest() : nil,
            build: TellomiUpdateManifests.currentBuild(appVersion: currentAppVersion),
            now: now,
        )
        windowManager.updateRequiredPageInfo = pageInfo
        windowManager.isUpdateRequiredBlockActive = Self.shouldBlock(
            appExpiry: appExpiry,
            now: now,
            isTellomiDeployment: isTellomiDeployment,
            hasUpdateChannel: Self.hasUpdateChannel(appStoreUrl: appStoreUrl, ourChannel: updateChannelUrl) || pageInfo.updateUrl != nil,
            viewChatsOnlyChosen: Self.viewChatsOnlyChosen(userDefaults: userDefaults, currentAppVersion: currentAppVersion),
        )
    }

    /// 阻断页上随清单变的几样（tellomi/tellomi#1491）。没有清单：服务端 499 那一句、没有版本和链接。
    static func pageInfo(manifest: TellomiUpdateManifest?, build: UInt64?, now: Date) -> TellomiUpdateRequiredPageInfo {
        guard let manifest else {
            return .serverRejected
        }
        let isRequired = build.map { manifest.tier(build: $0, now: now) == .required } ?? false
        let isNewer = build.map { manifest.latest.build > $0 } ?? false
        return TellomiUpdateRequiredPageInfo(
            reason: isRequired ? manifest.requiredReason : nil,
            newVersion: isNewer ? manifest.latest.version : nil,
            notesUrl: manifest.notesUrl,
            updateUrl: manifest.latest.url,
        )
    }

    /// 阻断页上确认了「暂不更新，只看聊天记录」。收起阻断页以后，锁上着就先看到应用锁（WindowManager 照常处理）。
    private func chooseViewChatsOnly() {
        AssertIsOnMainThread()

        Self.recordViewChatsOnly(userDefaults: userDefaults, currentAppVersion: currentAppVersion)
        updateIsBlocked()
    }

    static func shouldBlock(
        appExpiry: AppExpiry,
        now: Date,
        isTellomiDeployment: Bool,
        hasUpdateChannel: Bool,
        viewChatsOnlyChosen: Bool,
    ) -> Bool {
        guard isTellomiDeployment, appExpiry.isExpired(now: now) else {
            return false
        }
        // 规则 2：本机构建到期只降成只读，不盖。
        guard !appExpiry.isBuildTooOld(now: now) else {
            return false
        }
        // 规则 3、规则 1。
        return hasUpdateChannel && !viewChatsOnlyChosen
    }

    /// 规则 3 的判据：「立即更新」打开的 `appStoreUrl` 就是我们自己配的更新渠道（`updateChannelUrl`，
    /// owner 2026-09-25 定为 TestFlight 外部测试的公开链接）。
    /// 只认这一条（taishi 审查 b15 启用前置 4）：原来是「App Store / TestFlight 的地址、只要不是 Signal 的都算」，
    /// 别的 App 的条目、别人的 TestFlight 邀请也会被当成渠道。没配（nil）时 iOS 不盖阻断页，按钮也就不可能把人送去装别的 App。
    static func hasUpdateChannel(appStoreUrl: URL, ourChannel: URL?) -> Bool {
        guard let ourChannel else {
            return false
        }
        return appStoreUrl == ourChannel
    }

    static let viewChatsOnlyVersionKey = "TellomiUpdateRequiredViewChatsOnlyVersion"

    static func viewChatsOnlyChosen(userDefaults: UserDefaults, currentAppVersion: String) -> Bool {
        return userDefaults.string(forKey: viewChatsOnlyVersionKey) == currentAppVersion
    }

    static func recordViewChatsOnly(userDefaults: UserDefaults, currentAppVersion: String) {
        userDefaults.set(currentAppVersion, forKey: viewChatsOnlyVersionKey)
    }
}

/// 「必须更新」阻断页挂在哪里、出口交给谁。`WindowManager` 就是它；用例换成一个假的，
/// 把「暂不更新，只看聊天记录」从页面一路接到「不再盖」（taishi 审查 b15 启用前置 2）。
protocol TellomiUpdateRequiredBlockHost: AnyObject {
    var isUpdateRequiredBlockActive: Bool { get set }
    var updateRequiredViewChatsOnlyHandler: (@MainActor () -> Void)? { get set }
    /// 阻断页上随更新清单变的几样，以及「立即更新」去哪（tellomi/tellomi#1491）。
    var updateRequiredPageInfo: TellomiUpdateRequiredPageInfo { get set }
}

extension Notification.Name {
    /// 阻断页盖上或收起。应用锁（`ScreenLockUI`）靠它在收起后照常弹 Face ID / 密码框。
    static let tellomiUpdateRequiredBlockDidChange = Notification.Name("TellomiUpdateRequiredBlockDidChange")
}
