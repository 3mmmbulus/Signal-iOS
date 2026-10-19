//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

/// 只用来找到 SignalServiceKit 的 bundle：注册表文件和证书一样放在这里。
private final class TellomiLinkRegistryBundleAnchor {}

/// `LinkRegistry` 自己就有 `version`、`classify(preview:body:message:)`、`openPlan(_:)`。
extension LinkRegistry: TellomiLinkClassifying {
    func beginSendJob(url: String, context: String) throws -> any TellomiSendJob {
        return TellomiNativeSendJob(job: try begin(url, context: context))
    }
}

/// libsignal 的 `LinkJob` 套上 `TellomiSendJob`。
final class TellomiNativeSendJob: TellomiSendJob, @unchecked Sendable {
    private let job: LinkJob

    init(job: LinkJob) {
        self.job = job
    }

    func nextRequest() throws -> String? { try job.nextRequest() }

    func onResponse(id: UInt32, status: UInt32, finalUrl: String, contentType: String, location: String?, body: Data) throws {
        try job.onResponse(id: id, status: status, finalUrl: finalUrl, contentType: contentType, location: location, body: body)
    }

    func onNetworkError(id: UInt32) throws { try job.onNetworkError(id: id) }
    func onFailure(id: UInt32) throws { try job.onFailure(id: id) }
    func onFirstParty(id: UInt32, result: String) throws { try job.onFirstParty(id: id, result: result) }
    func onImage(id: UInt32, ok: Bool) throws { try job.onImage(id: id, ok: ok) }
    func finish() throws -> String { try job.finish() }
}

/// 随 App 带的链接注册表（ADR-0063 §8.1 第 3 行：iOS 随包，热更新在 P1 之后），和拿它做的接收端判定。
/// 与 Android `TellomiLinkRegistry.kt`、Desktop `linkRegistry.preload.ts` 是同一份文件（`links-2026101901.json`，
/// 2026-10-19 起有 `claimed` 档，要 libsignal 的 rust/links 认得它：tellomi/libsignal tellomi-0.102.0 8ea022cc（#33）或之后）。
/// 注册表加载失败时什么都不判，预览照 Signal 原样显示。
public enum TellomiLinkRegistry {
    public static let bundledResourceName = "links-2026101901"

    public static let classifier = TellomiLinkClassifier(
        registry: loadBundled(),
        log: { Logger.info($0) },
    )

    private static func loadBundled() -> (any TellomiLinkClassifying)? {
        let bundle = Bundle(for: TellomiLinkRegistryBundleAnchor.self)
        guard
            let url = bundle.url(forResource: bundledResourceName, withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            Logger.warn("The bundled link registry is missing")
            return nil
        }
        do {
            let registry = try LinkRegistry.load(data)
            Logger.info("Loaded bundled link registry \(registry.version)")
            return registry
        } catch {
            Logger.warn("Failed to load the bundled link registry: \(type(of: error))")
            return nil
        }
    }
}
