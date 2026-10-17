//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import LibSignalClient

/// Tellomi（tellomi/tellomi ADR-0078 §3.4 第三刀）：服务端的人工处置说明。
///
/// 服务端在三处给出同一个形状 `{"tellomiRestriction":{"level","until","appeal","case"}}`：发消息被拒的 403（iOS 的发送走
/// libsignal，这里读不到 body）、取发送证书被拒的 403、`GET /v1/tellomi/restriction` 的 200（没有处置是 204）。
/// `until` 是 epoch 秒，`case` 是案件号（老条目可能没有）。
public struct TellomiRestriction: Equatable, Sendable {
    public enum Level: String, Sendable {
        case stranger
        case all
        case suspended
    }

    public let level: Level
    public let until: Date
    public let appeal: String
    public let caseId: String?

    public init(level: Level, until: Date, appeal: String, caseId: String?) {
        self.level = level
        self.until = until
        self.appeal = appeal
        self.caseId = caseId
    }

    public func isActive(now: Date = Date()) -> Bool {
        return until > now
    }

    private static let appealPattern = try! NSRegularExpression(pattern: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$")
    private static let caseIdPattern = try! NSRegularExpression(pattern: "^[0-9A-Za-z._-]{1,64}$")

    private static func matches(_ pattern: NSRegularExpression, _ string: String) -> Bool {
        return pattern.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    /// body 里没有可用的 `tellomiRestriction` 就是 nil（老服务端、别的错误、空的 204、字段不对）。
    public static func parse(_ data: Data?) -> TellomiRestriction? {
        guard
            let data, !data.isEmpty,
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let raw = root["tellomiRestriction"] as? [String: Any],
            let level = (raw["level"] as? String).flatMap(Level.init(rawValue:)),
            let until = (raw["until"] as? NSNumber)?.int64Value, until > 0,
            let appeal = raw["appeal"] as? String, matches(appealPattern, appeal)
        else {
            return nil
        }
        let caseId = (raw["case"] as? String).flatMap { matches(caseIdPattern, $0) ? $0 : nil }
        return TellomiRestriction(level: level, until: Date(timeIntervalSince1970: TimeInterval(until)), appeal: appeal, caseId: caseId)
    }

    /// 存回本机用：和服务端同一个形状，读的时候走 `parse`。
    func jsonData() -> Data? {
        var raw: [String: Any] = ["level": level.rawValue, "until": Int64(until.timeIntervalSince1970), "appeal": appeal]
        if let caseId {
            raw["case"] = caseId
        }
        return try? JSONSerialization.data(withJSONObject: ["tellomiRestriction": raw], options: [.sortedKeys])
    }
}

/// 什么时候问、存在哪、告诉谁（ADR-0078 §3.4「怎么告诉当事人」）：
/// - 回到前台：至多每 6 小时问一次；
/// - 发消息被拒（libsignal 只给一句 `unexpected response status 403`）或取发送证书被拒（403）：马上问一次（证书的 403 自带说明就直接用）；
/// - 结果存在 KeyValueStore，会话列表顶上的提示显示它（`ChatListViewController+Reminders`）；截止时间到了、或者服务端说没有了就清掉。
///
/// 被暂停的账号登不上，问不了；暂停只在重新注册被拒（422）时说明（注册流程自己解析）。
public enum TellomiRestrictions {

    public static let path = "v1/tellomi/restriction"
    public static let checkInterval: TimeInterval = 6 * .hour

    /// 说明变了（在主线程发）：会话列表的提示跟着重判。
    public static let didChangeNotification = Notification.Name("TellomiRestrictionDidChange")

    private static let keyValueStore = KeyValueStore(collection: "TellomiRestriction")
    private static let currentKey = "current"
    private static let checkedAtKey = "checkedAt"

    // MARK: - Reading

    /// 现在生效的处置；过期的不算。
    public static func active(tx: DBReadTransaction, now: Date = Date()) -> TellomiRestriction? {
        return TellomiRestriction.parse(keyValueStore.getData(currentKey, transaction: tx)).flatMap { $0.isActive(now: now) ? $0 : nil }
    }

    public static func active(db: any DB) -> TellomiRestriction? {
        return db.read { active(tx: $0) }
    }

    // MARK: - Writing

    /// 记下一条说明（nil = 清掉），变了就通知会话列表；有说明时到截止时间再通知一次，让提示自己消失。
    public static func store(_ restriction: TellomiRestriction?, db: any DB) async {
        let active = restriction.flatMap { $0.isActive() ? $0 : nil }
        let changed: Bool = await db.awaitableWrite { tx in
            let before = TellomiRestriction.parse(keyValueStore.getData(currentKey, transaction: tx))
            if let active, let data = active.jsonData() {
                keyValueStore.setData(data, key: currentKey, transaction: tx)
            } else {
                keyValueStore.removeValue(forKey: currentKey, transaction: tx)
            }
            return before != active
        }
        if changed {
            Logger.info(active.map { "Restriction active: \($0.level.rawValue)" } ?? "Restriction cleared")
            await MainActor.run {
                NotificationCenter.default.post(name: didChangeNotification, object: nil)
            }
        }
        if let active {
            scheduleExpiryNotification(at: active.until)
        }
    }

    private static func scheduleExpiryNotification(at until: Date) {
        let delay = max(until.timeIntervalSinceNow, 0) + 1
        Task {
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 30 * .day) * Double(NSEC_PER_SEC)))
            await MainActor.run {
                NotificationCenter.default.post(name: didChangeNotification, object: nil)
            }
        }
    }

    // MARK: - Fetching

    /// 问服务端一次。`force` = 不管 6 小时节流（发送 / 取证书被拒时）。失败（断网、老服务端 404）不动现有的说明。
    public static func refresh(force: Bool, db: any DB = DependenciesBridge.shared.db, now: Date = Date()) async {
        guard DependenciesBridge.shared.tsAccountManager.registrationStateWithMaybeSneakyTransaction.isRegistered else {
            return
        }
        let checkedAt = db.read { keyValueStore.getDate(checkedAtKey, transaction: $0) }
        guard force || shouldCheck(now: now, lastChecked: checkedAt) else {
            return
        }
        await db.awaitableWrite { tx in
            keyValueStore.setDate(now, key: checkedAtKey, transaction: tx)
        }
        do {
            let response = try await SSKEnvironment.shared.networkManagerRef.asyncRequest(
                TSRequest(url: URL(string: path)!, method: "GET", parameters: nil),
            )
            // 204 没有 body = 没有处置
            await store(response.responseStatusCode == 200 ? TellomiRestriction.parse(response.responseBodyData) : nil, db: db)
        } catch {
            Logger.warn("Couldn't refresh the restriction: \(error)")
        }
    }

    static func shouldCheck(now: Date, lastChecked: Date?) -> Bool {
        guard let lastChecked else {
            return true
        }
        let sinceLast = now.timeIntervalSince(lastChecked)
        // 时钟往回拨过（sinceLast < 0）也问一次
        return sinceLast < 0 || sinceLast >= checkInterval
    }

    /// 取发送证书被拒（`OWSUDManager`）：403 自带说明就记下，不然问一次服务端。
    public static func onSenderCertificateFailure(_ error: Error) {
        guard error.httpStatusCode == 403 else {
            return
        }
        Task {
            if let restriction = TellomiRestriction.parse(error.httpResponseData) {
                await store(restriction, db: DependenciesBridge.shared.db)
            } else {
                await refresh(force: true)
            }
        }
    }

    /// 发消息失败（`MessageSender`）：libsignal 把服务端的 403 变成 `networkProtocolError("unexpected response status 403")`，
    /// 读不到 body，只能看这句话认出来，然后问服务端。
    public static func onSendFailure(_ error: Error) {
        guard isForbiddenSend(error) else {
            return
        }
        Task {
            await refresh(force: true)
        }
    }

    static func isForbiddenSend(_ error: Error) -> Bool {
        guard case SignalError.networkProtocolError(let message) = error else {
            return false
        }
        return message.contains("status 403")
    }
}
