//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedFriendSync.swift (new file)
// Friend sync (my half of "who counts as a friend", signed by Signal-Server and handed to the engine), audience-list signing
// models, the engine's `POST /v1/feed/friends` (I-11).
// Mirror of Android `friends/FeedFriendSync.kt`, `friends/FeedFriends.kt` (the wiring, minus the DB query), `net/FeedAuth.kt`
// (`FeedAuthApi.friendAssertion/audienceList` models), `FeedApi.reportFriend`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

// MARK: - Signal-Server 签名（模型和接口）

/// `POST /v1/tellomi/feed/friend-assertions` 的请求：对方的 ACI（标准 36 位 UUID）。
struct FeedFriendAssertionRequest: Codable, Equatable {
    var peerAci: String

    private enum CodingKeys: String, CodingKey { case peerAci = "peer_aci" }
}

/// 好友声明（5 分钟有效），客户端看不懂、也不用看懂，原样交给引擎。
struct FeedFriendAssertionResponse: Codable, Equatable {
    var assertion: String
}

/// `POST /v1/tellomi/feed/audience-lists`：`include` 或 `exclude`，最多 500 个 ACI（重复的和自己会被服务端去掉）。
struct FeedAudienceListRequest: Codable, Equatable {
    var kind: String
    var peerAcis: [String]

    private enum CodingKeys: String, CodingKey {
        case kind
        case peerAcis = "peer_acis"
    }
}

/// 签好的名单（10 分钟有效），发帖时放进 `audience`。
struct FeedAudienceListResponse: Codable, Equatable {
    var audienceToken: String

    private enum CodingKeys: String, CodingKey { case audienceToken = "audience_token" }
}

enum FeedSignerPaths {
    static let friendAssertions = "v1/tellomi/feed/friend-assertions"
    static let audienceLists = "v1/tellomi/feed/audience-lists"
}

/// 向 Signal-Server 要动态用的签名（`TellomiFeedController`）：走已登录的账号鉴权，引擎只认这里签的东西，
/// 客户端从头到尾不接触别人的假名。真实现是 `SignalServerFeedSigner`（`FeedSigner+UIKit.swift`，没编译过）。
protocol FeedFriendSigning: Sendable {
    /// 「我把 `peerAci` 当好友」（`add`）或撤回（整条边删掉）。加的时候对方没有账号，服务端回 **404 + `Content-Type: application/json` +
    /// `{"error":"account_not_found"}`**：只有带这个标记的 404 才返回 nil（不用报）；撤回不管对方还在不在。
    /// **没带标记的 404**（没 body、别的 body、不是 JSON、路由不存在）抛 `FeedSignerUnavailable`：路由没部署，不能当成「没账号」。
    /// 其他失败抛错。
    func friendAssertion(peerAci: String, add: Bool) async throws -> String?

    /// 「部分可见 / 不给谁看」的名单，回 `audience_token`。失败抛错（Android 抛 `invalid_audience`）。
    func audienceToken(kind: String, peerAcis: [String]) async throws -> String
}

// MARK: - 引擎

extension FeedAPI {
    /// 把 Signal-Server 签的好友声明原样交给引擎（数据模型 2.4）。两边都报了才 `confirmed`；只报了自己这一半是 false。
    func reportFriend(assertion: String) async throws -> Bool {
        let body = try Self.encoder.encode(FeedFriendReportRequest(assertion: assertion))
        return try await send(FeedFriendReportResponse.self, request(path: ["v1", "feed", "friends"], method: "POST", body: body)).confirmed
    }
}

private struct FeedFriendReportRequest: Encodable {
    var assertion: String
}

struct FeedFriendReportResponse: Decodable, Equatable {
    var confirmed = false

    init(confirmed: Bool = false) {
        self.confirmed = confirmed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
    }

    private enum CodingKeys: String, CodingKey { case confirmed }
}

// MARK: - 同步

/// 在这个引擎上报过的好友，和上次检查的时间。
protocol FeedFriendSyncState: AnyObject, Sendable {
    /// 上次检查的时间；从没检查过是 nil。
    var checkedAt: Date? { get set }
    /// 在这个引擎（`engineKey`）上报过的好友 ACI；换了引擎（切区）就是空的，重新报一遍。
    func reported(engineKey: String) -> Set<String>
    func save(engineKey: String, acis: Set<String>)
}

final class InMemoryFeedFriendSyncState: FeedFriendSyncState, @unchecked Sendable {
    private let lock = NSLock()
    private var _checkedAt: Date?
    private var engine: String?
    private var acis = Set<String>()

    init() {}

    var checkedAt: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _checkedAt }
        set { lock.lock(); _checkedAt = newValue; lock.unlock() }
    }

    func reported(engineKey: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return engine == engineKey ? acis : []
    }

    func save(engineKey: String, acis: Set<String>) {
        lock.lock()
        engine = engineKey
        self.acis = acis
        lock.unlock()
    }
}

/// 存在本机（`{"engine": …, "acis": […]}`，ACI 排序后存），**不进 iCloud / iTunes 备份**（tellomi测试 2026-10-16 定；
/// 和 Android 的 `SignalStore` 一致）：传 `FeedLocalStorages.backupExcluded`（`I-18/`）。
/// 换新手机后这里是空的：下一次同步把本机好友名单全部重新报一遍（引擎那边的边还在，重复的 `add` 是幂等的；
/// 新手机上已经不是好友的人，引擎边会留着直到 TA 或我撤回——这是「不进备份」的代价，也和 Android 换机一致）。
/// 旧版放在 `UserDefaults` 里的由 `FeedStorageMigration` 搬过来（`checkedAt` 旧版存的是 Double，不搬，多检查一次而已）。
final class StoredFeedFriendSyncState: FeedFriendSyncState, @unchecked Sendable {
    static let checkedAtKey = "tellomiFeedFriendsCheckedAt"
    static let reportedKey = "tellomiFeedFriendsReported"

    private struct Reported: Codable {
        var engine: String
        var acis: [String]
    }

    private let storage: FeedLocalStorage

    /// 故意没有默认值：不要回到会进备份的 `UserDefaults`。
    init(storage: FeedLocalStorage) {
        self.storage = storage
    }

    var checkedAt: Date? {
        get {
            // 文本里放秒数；读不懂 / 0 都当没问过
            guard let data = storage.data(forKey: Self.checkedAtKey), let text = String(data: data, encoding: .utf8),
                  let seconds = Double(text), seconds != 0 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }
        set {
            if let newValue {
                storage.set(Data(String(newValue.timeIntervalSince1970).utf8), forKey: Self.checkedAtKey)
            } else {
                storage.removeValue(forKey: Self.checkedAtKey)
            }
        }
    }

    func reported(engineKey: String) -> Set<String> {
        guard let data = storage.data(forKey: Self.reportedKey), let stored = try? JSONDecoder().decode(Reported.self, from: data) else { return [] }
        return stored.engine == engineKey ? Set(stored.acis) : []
    }

    func save(engineKey: String, acis: Set<String>) {
        if let data = try? JSONEncoder().encode(Reported(engine: engineKey, acis: acis.sorted())) { storage.set(data, forKey: Self.reportedKey) }
    }
}

/// 把「我把谁当好友」报给内容引擎（数据模型 2.4、Q-16；需求第三节第 19 条）。
///
/// 好友在 Signal 里是端到端的，服务端看不到，所以每个人只报自己这一半：本机算出好友名单（`friends`），
/// 和上次报过的比一比，新加的报 `add`，没了的报 `remove`。两边都报了引擎才建边，任何一方撤回整条边就删。
/// 每一步都先找 Signal-Server 签名（`signer`，签的是假名），再把签名原样交给引擎（`engine`），客户端不接触别人的假名。
///
/// 回到前台时调 `syncIfStale()`：离上次不到 `interval` 就不做；名单没变不走网络。
/// 一次最多处理 `maxChangesPerRun` 个变化，先撤回再新加（撤回关系到别人还能不能看到我的帖子，更急）；
/// 没做完的下次回到前台接着做。出错就停在这里，做完的部分已经记下。
actor FeedFriendSync {
    enum Outcome: Equatable {
        case skipped
        case unchanged
        case done
        case moreLeft
        case failed
        /// 引擎没有 `friend_assertions`（太旧、查不到、404）：什么也没做，也没记「检查过」，下次回到前台再看（`FeedCapabilitiesCache` 自己限频）。
        case notSupported
        /// Signal-Server 的 `friend-assertions` 回了没带 `account_not_found` 标记的 404（路由没部署）：这次停下，**没把任何好友记成已报**；
        /// 已经记过「检查过」，所以 `interval`（15 分钟）之内不再去问，之后再试一次。
        case signerUnavailable
    }

    static let interval: TimeInterval = 15 * 60
    static let maxChangesPerRun = 50

    private let enabled: @Sendable () -> Bool
    private let engineKey: @Sendable () -> String
    private let friends: @Sendable () async -> Set<String>
    private let signer: FeedFriendSigning
    private let engine: @Sendable (_ assertion: String) async throws -> Void
    private let state: FeedFriendSyncState
    private let features: FeedFeatureGate
    private let clock: @Sendable () -> Date

    /// `features` 故意没有默认值：好友同步只在引擎说有 `friend_assertions` 时才做（I-19）。
    init(
        enabled: @escaping @Sendable () -> Bool,
        engineKey: @escaping @Sendable () -> String,
        friends: @escaping @Sendable () async -> Set<String>,
        signer: FeedFriendSigning,
        engine: @escaping @Sendable (_ assertion: String) async throws -> Void,
        state: FeedFriendSyncState,
        features: FeedFeatureGate,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.enabled = enabled
        self.engineKey = engineKey
        self.friends = friends
        self.signer = signer
        self.engine = engine
        self.state = state
        self.features = features
        self.clock = clock
    }

    /// 会走网络，别在主线程等。
    func syncIfStale() async -> Outcome {
        if !enabled() { return .skipped }
        // 先问引擎有没有这个功能（`GET /v1/capabilities`，缓存过）：没有就不签名、不报、不记时间。
        // 好友加返回 404 分不清「没部署」和「别的」，所以不靠试。注意它只说引擎；Signal-Server 的签名路由另有入口检查。
        if !(await features.isAvailable(FeedFeature.friendAssertions)) { return .notSupported }
        let now = clock()
        // 时钟被调回去（间隔是负的）不算「刚检查过」，照做
        if let checked = state.checkedAt, now.timeIntervalSince(checked) >= 0, now.timeIntervalSince(checked) < Self.interval { return .skipped }
        state.checkedAt = now

        let key = engineKey()
        var reported = state.reported(engineKey: key)
        let desired = await friends()
        let removals = reported.subtracting(desired).sorted()
        let additions = desired.subtracting(reported).sorted()
        if removals.isEmpty && additions.isEmpty { return .unchanged }

        let changes = removals.map { ($0, false) } + additions.map { ($0, true) }
        do {
            for (aci, add) in changes.prefix(Self.maxChangesPerRun) {
                if let assertion = try await signer.friendAssertion(peerAci: aci, add: add) {
                    try await engine(assertion)
                }
                if add { reported.insert(aci) } else { reported.remove(aci) }
                state.save(engineKey: key, acis: reported)
            }
        } catch let unavailable as FeedSignerUnavailable {
            Logger.warn("feed friend sync: friend-assertions unavailable (\(unavailable.status) without account_not_found)")
            return .signerUnavailable
        } catch {
            Logger.warn("feed friend sync stopped: \(error)")
            return .failed
        }

        if changes.count > Self.maxChangesPerRun {
            // 下次回到前台就接着做，不等满 15 分钟
            state.checkedAt = nil
            return .moreLeft
        }
        return .done
    }
}

// MARK: - 发布页选的人

/// 名单里的一个人：本机的 recipient id（再打开选人页时预先勾上）和 ACI（找 Signal-Server 签名单用）。
struct FeedAudienceMember: Equatable {
    var recipientId: Int64
    var aci: String
}

// MARK: - 入口

/// 好友相关的入口（同步、「部分好友」的选人）要不要出现：看引擎的 `features`（I-19）。
/// 查不到（断网、404、解析不了）都算没有。
enum FeedFriendEntry {
    /// 好友同步 / 好友声明（`friend_assertions`）。
    static func syncAvailable(_ features: FeedFeatureGate) async -> Bool {
        return await features.isAvailable(FeedFeature.friendAssertions)
    }

    /// 发帖选「部分好友 / 屏蔽某些人」（`audience_tokens`）。
    static func audienceAvailable(_ features: FeedFeatureGate) async -> Bool {
        return await features.isAvailable(FeedFeature.audienceTokens)
    }
}
