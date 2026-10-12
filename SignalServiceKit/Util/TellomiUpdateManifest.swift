//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

/// Tellomi（tellomi/tellomi#1491）：更新清单——三档更新（可选 / 推荐 / 必须）的唯一来源。
///
/// 格式、签名和判档规则见需求 `docs/product/specs/app-update-and-version-policy.md` §3.2.1；
/// 发布方是超级仓库的 `scripts/release/update_manifest.py`（`update/v1/ios-testflight.json` + `.sig`）。
/// 和 Android 的 `UpdateManifest.kt` 同一套规则。
public struct TellomiUpdateManifest: Equatable {

    public struct Latest: Equatable {
        public let version: String
        /// 与 User-Agent 的 `Build/<n>` 同一个数：iOS 是 CFBundleVersion。
        public let build: UInt64
        /// TestFlight 公开链接（以后上架是 App Store 页）；还没有时为 nil：必须档只进只读、指向官网下载页（需求 §3.4 / §3.5）。
        public let url: URL?

        public init(version: String, build: UInt64, url: URL?) {
            self.version = version
            self.build = build
            self.url = url
        }
    }

    public enum RequiredReason: Equatable {
        case security
        case protocolChange
        case other
    }

    public enum Tier: Equatable {
        case none
        case optional
        case recommended
        case required
    }

    public let serial: UInt64
    public let latest: Latest
    public let recommendedMinBuild: UInt64
    public let requiredMinBuild: UInt64
    public let requiredReason: RequiredReason?
    /// 必须档生效时间；nil = 立即。
    public let requiredFrom: Date?
    /// 「了解更新内容」：官网更新日志。
    public let notesUrl: URL?

    public init(
        serial: UInt64,
        latest: Latest,
        recommendedMinBuild: UInt64,
        requiredMinBuild: UInt64,
        requiredReason: RequiredReason?,
        requiredFrom: Date?,
        notesUrl: URL?,
    ) {
        self.serial = serial
        self.latest = latest
        self.recommendedMinBuild = recommendedMinBuild
        self.requiredMinBuild = requiredMinBuild
        self.requiredReason = requiredReason
        self.requiredFrom = requiredFrom
        self.notesUrl = notesUrl
    }

    public static let name = "tellomi-update"
    public static let schema = 1

    /// iOS 的「更新」只认这两个主机（同 `update_manifest.py` 的 `TESTFLIGHT_HOSTS`）：清单是我们签的，这里再挡一道，
    /// 不会把人送去装别的 App（taishi 审查 b15 启用前置 4 的同一个顾虑）。
    static let channelHosts: Set<String> = ["testflight.apple.com", "apps.apple.com"]

    /// 判档（§3.2.1）：
    /// 1. requiredMinBuild > build，且没有 requiredFrom 或已到 → 必须；
    /// 2. 否则 requiredMinBuild > build（还没到生效时间）或 recommendedMinBuild > build → 推荐；
    /// 3. 否则 latest.build > build → 可选；
    /// 4. 否则不提示。
    public func tier(build: UInt64, now: Date) -> Tier {
        if requiredMinBuild > build, requiredFrom.map({ now >= $0 }) ?? true {
            return .required
        }
        if requiredMinBuild > build || recommendedMinBuild > build {
            return .recommended
        }
        if latest.build > build {
            return .optional
        }
        return .none
    }

    /// 客户端采信规则（§3.2.1），任何一条不过就返回 nil（调用方照用缓存，不拦、不提示）：
    /// 签名对 → name / schema 对 → platform / channel 是自己 → serial ≥ 缓存里的。
    ///
    /// - Parameter publicKey: 33 字节（0x05 前缀）的发布公钥
    /// - Parameter cachedSerial: 上一份采信过的清单的 serial；还没有时传 0
    public static func accept(
        data: Data,
        signatureHex: String,
        publicKey: Data,
        platform: String,
        channel: String,
        cachedSerial: UInt64,
    ) -> TellomiUpdateManifest? {
        guard verify(data: data, signatureHex: signatureHex, publicKey: publicKey) else {
            Logger.warn("Rejected an update manifest: bad signature.")
            return nil
        }
        guard let raw = try? JSONDecoder().decode(RawManifest.self, from: data) else {
            Logger.warn("Rejected an update manifest: unreadable.")
            return nil
        }
        guard raw.name == name, raw.schema == schema, raw.platform == platform, raw.channel == channel else {
            Logger.warn("Rejected an update manifest: name / schema / target mismatch.")
            return nil
        }
        guard let manifest = raw.toManifest() else {
            Logger.warn("Rejected an update manifest: missing or malformed fields.")
            return nil
        }
        guard manifest.serial >= cachedSerial else {
            Logger.warn("Rejected an update manifest: serial \(manifest.serial) is older than the cached \(cachedSerial).")
            return nil
        }
        return manifest
    }

    /// 只在清单已经采信过（缓存）时用：不再验签，按同一套字段规则读出来。
    public static func parseTrusted(_ data: Data) -> TellomiUpdateManifest? {
        return (try? JSONDecoder().decode(RawManifest.self, from: data))?.toManifest()
    }

    private static func verify(data: Data, signatureHex: String, publicKey: Data) -> Bool {
        guard
            let signature = Data(hex: signatureHex.trimmingCharacters(in: .whitespacesAndNewlines)),
            signature.count == 64
        else {
            return false
        }
        do {
            return try PublicKey(publicKey).verifySignature(message: data, signature: signature)
        } catch {
            return false
        }
    }

    private struct RawManifest: Decodable {
        let name: String?
        let schema: Int?
        let platform: String?
        let channel: String?
        let serial: UInt64?
        let latest: RawLatest?
        let recommendedMinBuild: UInt64?
        let requiredMinBuild: UInt64?
        let requiredReason: String?
        let requiredFrom: String?
        let notesUrl: String?

        func toManifest() -> TellomiUpdateManifest? {
            guard
                let latest,
                let version = latest.version,
                let build = latest.build, build > 0,
                let serial, serial > 0
            else {
                return nil
            }
            let required = requiredMinBuild ?? 0
            let reason: RequiredReason? = {
                guard required > 0 else { return nil }
                switch requiredReason {
                case "security": return .security
                case "protocol": return .protocolChange
                default: return .other
                }
            }()
            let requiredFromDate: Date? = {
                guard required > 0, let requiredFrom else { return nil }
                // 时间读不懂就当已经生效：宁可按发布方的意思拦，也不因为格式问题放过一个「必须」（同 Android）
                return ISO8601DateFormatter().date(from: requiredFrom) ?? .distantPast
            }()
            return TellomiUpdateManifest(
                serial: serial,
                latest: Latest(version: version, build: build, url: Self.channelUrl(latest.url)),
                recommendedMinBuild: recommendedMinBuild ?? 0,
                requiredMinBuild: required,
                requiredReason: reason,
                requiredFrom: requiredFromDate,
                notesUrl: notesUrl.flatMap { URL(string: $0) }.flatMap { $0.scheme == "https" ? $0 : nil },
            )
        }

        private static func channelUrl(_ string: String?) -> URL? {
            guard
                let string,
                let url = URL(string: string),
                url.scheme == "https",
                let host = url.host?.lowercased(),
                TellomiUpdateManifest.channelHosts.contains(host)
            else {
                return nil
            }
            return url
        }
    }

    private struct RawLatest: Decodable {
        let version: String?
        let build: UInt64?
        let url: String?
    }
}
