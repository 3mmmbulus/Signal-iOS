//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Tellomi（tellomi/tellomi#1491）：更新清单在本机这一半——什么时候去拉、拉到以后怎么改只读状态。和 Android 的 `UpdateManifests.kt` 同一套规则。
///
/// 只读复用上游的 `AppExpiry`：过期了就发不出、收不到，会话列表提示、输入框、阻断页（`TellomiUpdateRequiredMonitoringManager`）都是现成的。
/// 原来只有服务端 499、远程配置和构建到期会让它过期，而且只有换版本才解（需求 §3.3「现状」）；
/// 这里加上清单判「必须」时置过期、清单撤销时解（`AppExpiry.tellomiReleaseServerExpiry`）。
public enum TellomiUpdateManifests {

    public static let platform = "ios"
    public static let channel = "testflight"
    public static let path = "update/v1/ios-testflight.json"

    /// 发布公钥 = Desktop 更新源和链接注册表那一把（`clients/desktop/config/default.json` 的 `updatesPublicKey`）。
    /// 私钥只在发版那台 Mac 上（超级仓库 `scripts/release/update_manifest.py`）。
    static let publicKeyHex = "0569dca6fde7f7dd8e03eee459d54b385b4067230e4c0452eb0c6fc3d2644f914c"

    public static var publicKey: Data { Data(hex: publicKeyHex)! }

    /// 回前台时最多这么久拉一次（需求 §3.2「节流 6 小时」）；只读时每次回前台都拉，好让撤销尽快生效。
    public static let checkInterval: TimeInterval = 6 * .hour

    private static let keyValueStore = KeyValueStore(collection: "TellomiUpdateManifest")
    private static let manifestKey = "manifest"
    private static let serialKey = "serial"
    private static let checkedAtKey = "checkedAt"
    /// 进入只读时缓存里那份清单的 serial；没有 = 没在只读。之后拿到一份 serial 更大、不判「必须」的清单才放行。
    private static let readOnlySinceSerialKey = "readOnlySinceSerial"

    // MARK: - Reading

    /// 当前采信的清单（缓存）；没有或读不出时为 nil。
    public static func current(tx: DBReadTransaction) -> TellomiUpdateManifest? {
        return keyValueStore.getData(manifestKey, transaction: tx).flatMap { TellomiUpdateManifest.parseTrusted($0) }
    }

    public static func current(db: any DB) -> TellomiUpdateManifest? {
        return db.read { current(tx: $0) }
    }

    /// 本机构建号（CFBundleVersion）：`AppVersion.currentAppVersion` 的第四段，与 User-Agent 的 `Build/<n>` 同一个数。
    public static func currentBuild(appVersion: String = AppVersionImpl.shared.currentAppVersion) -> UInt64? {
        let components = appVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count > 3 else {
            return nil
        }
        return UInt64(components.dropFirst(3).joined(separator: "."))
    }

    // MARK: - Fetching

    /// 回到前台（`TellomiUpdateRequiredMonitoringManager`）：按节流去拉（只读时每次都拉），然后调只读状态。
    /// `force`：阻断页正盖着时用，不管节流。
    public static func refresh(force: Bool, db: any DB, appExpiry: AppExpiry, now: Date = Date()) async {
        let checkedAt = db.read { keyValueStore.getDate(checkedAtKey, transaction: $0) }
        if force || shouldCheck(now: now, lastChecked: checkedAt, isReadOnly: appExpiry.isExpired(now: now)) {
            await fetchAndAccept(db: db, now: now)
        }
        await reconcile(db: db, appExpiry: appExpiry, now: now)
    }

    static func shouldCheck(now: Date, lastChecked: Date?, isReadOnly: Bool) -> Bool {
        if isReadOnly {
            return true
        }
        guard let lastChecked else {
            return true
        }
        let sinceLast = now.timeIntervalSince(lastChecked)
        // 时钟往回拨过（sinceLast < 0）也拉一次，免得一直等到「上次」那个未来时间
        return sinceLast < 0 || sinceLast >= checkInterval
    }

    private static func fetchAndAccept(db: any DB, now: Date) async {
        await db.awaitableWrite { tx in
            keyValueStore.setDate(now, key: checkedAtKey, transaction: tx)
        }
        guard let (data, signature) = await fetch() else {
            return
        }
        _ = await accept(data: data, signatureHex: signature, db: db)
    }

    /// 拉清单和签名。清单还没发布（404）、断网、跨境同意之前（`OWSURLSession` 一个请求都不发）都返回 nil：照用缓存。
    /// 只读（过期）时也要能拉到撤销，所以 `ignoreAppExpiry`。
    private static func fetch() async -> (Data, String)? {
        let urlSession = SSKEnvironment.shared.signalServiceRef.urlSessionForUpdates2()
        let manifestUrl = URL(string: TSConstants.updates2URL)!.appendingPathComponent(path)
        do {
            let manifest = try await urlSession.performRequest(
                request: URLRequest(url: manifestUrl),
                maxResponseSize: 64 * 1024,
                ignoreAppExpiry: true,
            )
            let signature = try await urlSession.performRequest(
                request: URLRequest(url: manifestUrl.appendingPathExtension("sig")),
                maxResponseSize: 1024,
                ignoreAppExpiry: true,
            )
            guard
                let data = manifest.responseBodyData,
                let signatureData = signature.responseBodyData,
                let signatureHex = String(data: signatureData, encoding: .utf8)
            else {
                return nil
            }
            return (data, signatureHex)
        } catch {
            Logger.info("No update manifest this time: \(error)")
            return nil
        }
    }

    /// 按采信规则判（`TellomiUpdateManifest.accept`），采信就存下。返回是否采信。
    @discardableResult
    static func accept(data: Data, signatureHex: String, db: any DB) async -> Bool {
        let cachedSerial = db.read { keyValueStore.getUInt64(serialKey, defaultValue: 0, transaction: $0) }
        guard
            let manifest = TellomiUpdateManifest.accept(
                data: data,
                signatureHex: signatureHex,
                publicKey: publicKey,
                platform: platform,
                channel: channel,
                cachedSerial: cachedSerial,
            )
        else {
            return false
        }
        await db.awaitableWrite { tx in
            keyValueStore.setData(data, key: manifestKey, transaction: tx)
            keyValueStore.setUInt64(manifest.serial, key: serialKey, transaction: tx)
        }
        Logger.info("Accepted update manifest \(manifest.serial): latest \(manifest.latest.build), recommended \(manifest.recommendedMinBuild), required \(manifest.requiredMinBuild).")
        return true
    }

    // MARK: - Read-only state

    public struct Reconciled: Equatable {
        public enum Action: Equatable {
            case none
            /// 清单判「必须」：置过期（只读）。
            case expire
            /// 清单撤销了：解开服务端判定的过期。
            case release
        }

        public let action: Action
        /// 要存的「进入只读时的清单 serial」；nil = 没在只读。
        public let readOnlySinceSerial: UInt64?
    }

    /// 纯函数（单测用）。规则（需求 §3.2.1「撤销」、§3.3「现状」），和 Android 一样：
    /// - 清单判「必须」→ 只读；
    /// - 已经只读、而且不是本机构建到期：记下当时缓存里那份清单的 serial（服务端 499 置只读时这里不在场，第一次看到时补记）；
    ///   之后拿到一份 serial 更大、不判「必须」的清单 → 放行。服务端如果还在拒，下一次请求的 499 会再置回只读。
    /// - 本机构建到期的只读不归清单管（owner 2026-09-24：到期只降成只读，换新版才解）。
    public static func reconcile(
        manifest: TellomiUpdateManifest?,
        build: UInt64,
        now: Date,
        isReadOnly: Bool,
        isBuildTooOld: Bool,
        readOnlySinceSerial: UInt64?,
    ) -> Reconciled {
        let tier = manifest?.tier(build: build, now: now) ?? TellomiUpdateManifest.Tier.none

        if tier == .required, let manifest {
            return Reconciled(
                action: isReadOnly ? .none : .expire,
                readOnlySinceSerial: (isReadOnly ? readOnlySinceSerial : nil) ?? manifest.serial,
            )
        }
        guard isReadOnly else {
            return Reconciled(action: .none, readOnlySinceSerial: nil)
        }
        guard !isBuildTooOld else {
            return Reconciled(action: .none, readOnlySinceSerial: readOnlySinceSerial)
        }
        guard let readOnlySinceSerial else {
            return Reconciled(action: .none, readOnlySinceSerial: manifest?.serial ?? 0)
        }
        if let manifest, manifest.serial > readOnlySinceSerial {
            return Reconciled(action: .release, readOnlySinceSerial: nil)
        }
        return Reconciled(action: .none, readOnlySinceSerial: readOnlySinceSerial)
    }

    /// 按缓存的清单和现在的时间调只读状态。
    public static func reconcile(db: any DB, appExpiry: AppExpiry, now: Date = Date()) async {
        guard let build = currentBuild() else {
            owsFailDebug("No build number in the app version.")
            return
        }
        let (manifest, readOnlySinceSerial) = db.read { tx in
            (current(tx: tx), keyValueStore.getUInt64(readOnlySinceSerialKey, transaction: tx))
        }
        let result = reconcile(
            manifest: manifest,
            build: build,
            now: now,
            isReadOnly: appExpiry.isExpired(now: now),
            isBuildTooOld: appExpiry.isBuildTooOld(now: now),
            readOnlySinceSerial: readOnlySinceSerial,
        )

        await db.awaitableWrite { tx in
            if let serial = result.readOnlySinceSerial {
                keyValueStore.setUInt64(serial, key: readOnlySinceSerialKey, transaction: tx)
            } else {
                keyValueStore.removeValue(forKey: readOnlySinceSerialKey, transaction: tx)
            }
        }

        switch result.action {
        case .none:
            break
        case .expire:
            Logger.warn("The update manifest requires an update. This version is now read-only.")
            await appExpiry.setHasAppExpiredAtCurrentVersion(db: db)
        case .release:
            Logger.info("The required update was withdrawn. Leaving read-only.")
            await appExpiry.tellomiReleaseServerExpiry(now: now, db: db)
        }
    }
}
