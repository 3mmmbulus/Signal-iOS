//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Thrown when a request isn't sent because the app is already expired.
public struct AppExpiredError: Error {}

public final class AppExpiry {

    public static let appExpiredStatusCode: UInt = 499

    private let keyValueStore: KeyValueStore

    private let appVersion: AppVersionNumber4
    private let buildDate: Date
    private let isTestFlightBuild: Bool

    private struct ExpirationState: Codable, Equatable {
        let appVersion: String

        enum Mode: String, Codable {
            case `default`
            case immediately
            case atDate
        }

        let mode: Mode

        let expirationDate: Date?

        init(appVersion: String, mode: Mode = .default, expirationDate: Date? = nil) {
            self.appVersion = appVersion
            self.mode = mode
            self.expirationDate = expirationDate

            // It'd be great to enforce this with an associated object
            // on the enum, but Codable conformance with associated
            // objects is a very manual process.
            owsAssertDebug(mode != .atDate || expirationDate != nil)
        }
    }

    private let expirationState: AtomicValue<ExpirationState>

    static let keyValueCollection = "AppExpiry"
    static let keyValueKey = "expirationState"

    public convenience init(appVersion: any AppVersion) {
        self.init(appVersion: appVersion.currentAppVersion4, buildDate: appVersion.buildDate, isTestFlightBuild: Self.isTestFlightInstall())
    }

#if TESTABLE_BUILD

    public static func forUnitTests(buildDate: Date = Date(), isTestFlightBuild: Bool = false) -> Self {
        return Self(appVersion: try! AppVersionNumber4(AppVersionNumber("1.2.3.4")), buildDate: buildDate, isTestFlightBuild: isTestFlightBuild)
    }

#endif

    public init(
        appVersion: AppVersionNumber4,
        buildDate: Date,
        isTestFlightBuild: Bool = false,
    ) {
        self.keyValueStore = KeyValueStore(collection: Self.keyValueCollection)
        self.appVersion = appVersion
        self.buildDate = buildDate
        self.isTestFlightBuild = isTestFlightBuild

        self.expirationState = AtomicValue(
            .init(appVersion: appVersion.wrappedValue.rawValue, mode: .default),
            lock: .sharedGlobal,
        )
    }

    public func warmCaches(with tx: DBReadTransaction) {
        let persistedExpirationState: ExpirationState? = try? self.keyValueStore.getCodableValue(
            forKey: Self.keyValueKey,
            failDebugOnParseError: false,
            transaction: tx,
        )

        // We only want to restore the persisted state if it's for our current version.
        guard
            let persistedExpirationState,
            persistedExpirationState.appVersion == appVersion.wrappedValue.rawValue
        else {
            return
        }

        expirationState.set(persistedExpirationState)
    }

    private func updateExpirationState(_ state: ExpirationState, db: any DB) async {
        expirationState.set(state)

        await db.awaitableWrite { transaction in
            do {
                // Don't write or fire notification if the value hasn't changed.
                let oldState: ExpirationState? = try self.keyValueStore.getCodableValue(
                    forKey: Self.keyValueKey,
                    transaction: transaction,
                )
                if let oldState, oldState == state {
                    return
                }
            } catch {
                owsFailDebug("Error reading expiration state \(error)")
            }
            do {
                try self.keyValueStore.setCodable(
                    state,
                    key: Self.keyValueKey,
                    transaction: transaction,
                )
            } catch {
                owsFailDebug("Error persisting expiration state \(error)")
            }
        }

        await didUpdateExpirationState()
    }

    @MainActor
    private func didUpdateExpirationState() {
        _refreshExpirationTimerIfStarted()
        NotificationCenter.default.post(name: Self.AppExpiryDidChange, object: nil)
    }

    public func setHasAppExpiredAtCurrentVersion(db: any DB) async {
        Logger.warn("")

        let newState = ExpirationState(appVersion: appVersion.wrappedValue.rawValue, mode: .immediately)
        await updateExpirationState(newState, db: db)
    }

    public func setExpirationDateForCurrentVersion(_ newExpirationDate: Date?, now: Date, db: any DB) async {
        guard !isExpired(now: now) else {
            Logger.warn("Ignoring expiration date change for expired build.")
            return
        }

        let newState: ExpirationState
        if let newExpirationDate {
            Logger.warn("Considering remote expiration of \(newExpirationDate)")
            // Ignore any expiration date that is later than when the app expires by default.
            guard newExpirationDate < defaultExpirationDate else { return }
            newState = .init(
                appVersion: appVersion.wrappedValue.rawValue,
                mode: .atDate,
                expirationDate: newExpirationDate,
            )
        } else {
            newState = .init(appVersion: appVersion.wrappedValue.rawValue, mode: .default)
        }
        await updateExpirationState(newState, db: db)
    }

    /// Tellomi（tellomi/tellomi#1491，需求 app-update-and-version-policy §3.2.1「撤销」、§3.3「现状」）：更新清单撤销了「必须」，
    /// 把服务端判定的过期（499 的 `.immediately`、远程配置的 `.atDate`）改回默认——只按构建年龄算。
    /// 本机构建过了有效期的不动（owner 2026-09-24 规则 2：到期只降成只读，换新版才解）。
    /// 发 `AppExpiryDidChange`，聊天连接（`OWSChatConnection.appExpiryDidChange`）随之重连；服务端如果还在拒，下一次 499 会再置回来。
    ///
    /// - Returns: 是否真的放行了
    @discardableResult
    public func tellomiReleaseServerExpiry(now: Date, db: any DB) async -> Bool {
        guard isExpired(now: now), !isBuildTooOld(now: now) else {
            return false
        }
        Logger.warn("")
        await updateExpirationState(.init(appVersion: appVersion.wrappedValue.rawValue, mode: .default), db: db)
        return true
    }

    public static let AppExpiryDidChange = Notification.Name("AppExpiryDidChange")

    public var expirationDate: Date {
        let state = expirationState.get()
        switch state.mode {
        case .default:
            return defaultExpirationDate
        case .atDate:
            guard let expirationDate = state.expirationDate else {
                owsFailDebug("Missing expiration date, expiring immediately")
                return .distantPast
            }
            return expirationDate
        case .immediately:
            return .distantPast
        }
    }

    public func isExpired(now: Date) -> Bool { expirationDate < now }

    /// Tellomi（tellomi/tellomi#1139）：「必须更新」阻断页要分辨「构建本身过了有效期」和「服务端拒绝（499）/
    /// 远程配置宣布到期」：前者只降成只读、不盖阻断页（owner 2026-09-24 规则 2）。过期状态是私有的，这里只暴露构建年龄这一条。
    public func isBuildTooOld(now: Date) -> Bool { defaultExpirationDate < now }

    // Tellomi（tellomi/tellomi#1142，需求 app-update-and-version-policy 第 3.6 节）：上游 90 天。Tellomi 发版没那么勤，
    // 90 天不发版所有人会同时停止收发；兜底保留，时长三端统一 180 天（owner 可改）。
    public static let defaultExpirationInterval: TimeInterval = 180 * .day

    // Tellomi（owner 2026-09-25：iOS 用 TestFlight 外部测试发给朋友）：TestFlight 的构建 90 天后会被 TestFlight 停用、打不开，
    // 180 天的兜底在它上面永远走不到，「14 天后过期」的提醒也就永远不出现。TestFlight 装的包按 90 天算，第 76 天起提醒。
    public static let testFlightExpirationInterval: TimeInterval = 90 * .day

    static func expirationInterval(isTestFlightBuild: Bool) -> TimeInterval {
        return isTestFlightBuild ? testFlightExpirationInterval : defaultExpirationInterval
    }

    /// 这个包是不是从 TestFlight 装的：TestFlight 装的包带沙盒收据（`sandboxReceipt`），App Store 正式包的收据叫 `receipt`，
    /// Xcode 直接装的开发包收据地址照样叫 `sandboxReceipt`，但文件不存在。扩展里 `Bundle.main` 是扩展自己，所以看主 App 的收据。
    static func isTestFlightInstall(receiptURL: URL? = Bundle.main.app.appStoreReceiptURL, fileManager: FileManager = .default) -> Bool {
        guard let receiptURL, receiptURL.lastPathComponent == "sandboxReceipt" else {
            return false
        }
        return fileManager.fileExists(atPath: receiptURL.path)
    }

    private var defaultExpirationDate: Date {
        return buildDate.addingTimeInterval(Self.expirationInterval(isTestFlightBuild: isTestFlightBuild))
    }

    @MainActor
    private var expirationWorkItem: DispatchWorkItem?

    @MainActor
    private func _refreshExpirationTimerIfStarted() {
        if self.expirationWorkItem != nil {
            self.refreshExpirationTimer()
        }
    }

    @MainActor
    public func refreshExpirationTimer() {
        let now = Date()
        let expirationDate = self.expirationDate

        self.expirationWorkItem?.cancel()
        self.expirationWorkItem = nil

        guard now < expirationDate else {
            return
        }

        let expirationDelay = self.expirationDate.timeIntervalSince(now)
        let wallDeadline: DispatchWallTime = .now() + expirationDelay

        // This is a DispatchWorkItem so that we can use the wall clock.
        let expirationWorkItem = DispatchWorkItem(block: { [weak self] in
            NotificationCenter.default.post(name: Self.AppExpiryDidChange, object: nil)
            self?.refreshExpirationTimer()
        })
        self.expirationWorkItem = expirationWorkItem
        DispatchQueue.main.asyncAfter(wallDeadline: wallDeadline, execute: expirationWorkItem)
    }
}

// MARK: - Tellomi：跨境单独告知与同意（tellomi/tellomi#1133）

/// 服务端还在香港的这段时间，**同意跨境之前不发任何网络请求**（需求 `docs/product/specs/privacy-compliance-hk-cross-border.md`
/// 2.1 / 2.7）。和「App 过期」同一种闸：`OWSChatConnection._canOpenWebSocketError()` 不开连接，`OWSURLSession` 直接失败。
/// 失败时报的是 `OWSHTTPError.networkFailure(.genericFailure)`（和「没网」一样），各处本来就会按没网处理、稍后重试，
/// 不会走到只在 Debug 构建里崩的 `owsFailDebug`。
/// 实测：全新安装启动 11 秒内就连了 grpc.chat.tellomi.app（未注册连接），用户什么都还没同意（#1133 的评论）。
/// 记录放在 App Group 的 UserDefaults，通知扩展也读得到。
public enum TellomiCrossBorderConsent {
    /// 告知文本的版本。文本有实质变化就改这里，已经同意过的人会被重新询问（同意前网络也会重新关上）。
    /// Tellomi（tellomi/tellomi#1338）：定稿后是独立的 `cb-1`，不跟隐私政策版本走（隐私政策 2.0.0 第 21.7 节：只有实质变化才重新征得同意）；
    /// `docs/legal/manifest.json` 的 `notices` 里登记 `cross-border` = `cb-1` ↔ 隐私政策 `2.0.0`，改版时和 Android、Desktop 的常量一起改。
    public static let noticeVersion = "cb-1"

    public static let didChangeNotification = Notification.Name("TellomiCrossBorderConsentDidChange")

    private static let versionKey = "TellomiCrossBorderConsent.version"
    private static let dateKey = "TellomiCrossBorderConsent.date"
    private static let linkedDeviceAcknowledgementOnlyKey = "TellomiCrossBorderConsent.linkedDeviceAcknowledgementOnly"

    public static var hasAgreed: Bool {
        CurrentAppContext().appUserDefaults().string(forKey: versionKey) == noticeVersion
    }

    /// 网络闸：还没同意就不联网。单元测试里不拦——测试用的是假网络，拦了只会让无关的用例失败。
    public static var blocksNetwork: Bool {
        !CurrentAppContext().isRunningTests && !hasAgreed
    }

    /// Tellomi（tellomi/tellomi#1338）：这台设备自己点过「同意并继续」，而不只是关联设备时点的「知道了」。
    /// 只读版写的是「同意在您的手机上取得」，所以这台设备要是改走主设备注册（发号码、恢复 / 转移），仍要完整同意一次。
    public static var hasGivenSeparateConsent: Bool {
        hasAgreed && !CurrentAppContext().appUserDefaults().bool(forKey: linkedDeviceAcknowledgementOnlyKey)
    }

    /// 本机记一份（版本 + 时间），然后放开网络。服务端的最小记录点由 taishi 设计（tellomi/tellomi#1133）。
    public static func recordAgreement() {
        record(linkedDeviceAcknowledgementOnly: false)
    }

    /// Tellomi（tellomi/tellomi#1338，需求第六节 ④）：关联设备只读版的「知道了」。和同意一样在本机记下 `noticeVersion`、放开网络
    /// （主设备的同意覆盖同一账号，关联设备不另行收集），另记一笔「只是知悉」，给 `hasGivenSeparateConsent` 用。
    public static func recordLinkedDeviceAcknowledgement() {
        record(linkedDeviceAcknowledgementOnly: true)
    }

    private static func record(linkedDeviceAcknowledgementOnly: Bool) {
        let defaults = CurrentAppContext().appUserDefaults()
        defaults.set(noticeVersion, forKey: versionKey)
        defaults.set(Date(), forKey: dateKey)
        defaults.set(linkedDeviceAcknowledgementOnly, forKey: linkedDeviceAcknowledgementOnlyKey)
        NotificationCenter.default.postOnMainThread(name: didChangeNotification, object: nil)
    }
}
