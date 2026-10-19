//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import Network

/// Tellomi（tellomi/tellomi#1056 第四刀）：选路器，RegionProfile 契约第六节（ADR-0065 §6.5）。
///
/// 只给建议，不切换：`probe()` 并发探所有**开着的**区，按决策表给出建议和理由；切不切、什么时候切，由调用方拿决策去调
/// `TellomiNetProvider.switchTo`。决策表和阈值与 Desktop 的 `RegionSelector`（Signal-Desktop `ts/util/tellomiRegion.std.ts`）
/// 逐条一致，用例也是照那边的搬过来的。
///
/// 和 Desktop 不同的一处：当前区和上次切区时间不在这里另存一份，用的时候现取——当前区是装上的 provider 的生效区，
/// 上次切区时间是 `TellomiRegionStore` 里的（provider 切区时写）。选路器和真正生效的区不会分叉。
public final class TellomiRegionSelector: Sendable {

    public struct Thresholds: Sendable {
        /// 上次切区之后这么久之内，不因为「别的区更快」而切（failover 不受它限制）。没有记录 = 已满足，所以冷启动时 RTT 更低的区直接胜出。
        public var minDwell: TimeInterval
        /// 当前区连续失败这么多次才允许 failover：单次超时不切。
        public var failureThreshold: Int
        /// 别的区要快出这么多才切。
        public var latencyAdvantage: TimeInterval
        /// 单次探测超时。
        public var probeTimeout: TimeInterval

        /// 编进包里的默认值（契约第六节表）：拿 /v2/config 本身要先连上服务端，所以不能只放在远程配置里。
        public static let defaults = Thresholds(minDwell: 10 * .minute, failureThreshold: 3, latencyAdvantage: 0.050, probeTimeout: 5)
    }

    public enum ProbeResult: Sendable, Equatable {
        case ok(rtt: TimeInterval)
        case failed(String)

        var rtt: TimeInterval? {
            if case .ok(let rtt) = self {
                return rtt
            }
            return nil
        }
    }

    public enum Reason: String, Sendable {
        case stay
        case faster
        case dwell
        case failover
        case currentFailing = "current-failing"
        case noAlternative = "no-alternative"
    }

    public struct Decision: Sendable {
        public let current: TellomiRegionId
        public let recommended: TellomiRegionId
        public let reason: Reason
        public let results: [TellomiRegionId: ProbeResult]
    }

    /// 探一个区：成功给握手用时，失败给原因。只会对开着的区调。
    public typealias Probe = @Sendable (TellomiRegionProfile, TimeInterval) async -> ProbeResult

    private struct FailureCount: Sendable {
        var region: TellomiRegionId?
        var count = 0
    }

    private let profiles: @Sendable () -> [TellomiRegionProfile]
    private let currentRegion: @Sendable () -> TellomiRegionId
    private let lastSwitchAt: @Sendable () -> Date?
    private let probeRegion: Probe
    private let now: @Sendable () -> Date
    private let thresholds: Thresholds
    private let failures = AtomicValue<FailureCount>(FailureCount(), lock: .init())

    public init(
        profiles: @escaping @Sendable () -> [TellomiRegionProfile],
        currentRegion: @escaping @Sendable () -> TellomiRegionId,
        lastSwitchAt: @escaping @Sendable () -> Date?,
        probe: @escaping Probe = TellomiRegionSelector.chatEndpointProbe,
        now: @escaping @Sendable () -> Date = { Date() },
        thresholds: Thresholds = .defaults,
    ) {
        self.profiles = profiles
        self.currentRegion = currentRegion
        self.lastSwitchAt = lastSwitchAt
        self.probeRegion = probe
        self.now = now
        self.thresholds = thresholds
    }

    /// 接本进程装上的 provider 和 app group 里的切区记录（provider 切区时写的那一份）。
    public static func forProvider(_ provider: TellomiNetProvider) -> TellomiRegionSelector {
        TellomiRegionSelector(
            profiles: { provider.profiles },
            currentRegion: { provider.activeRegion.id },
            lastSwitchAt: { TellomiRegionStore.appGroup.lastSwitchAt() },
        )
    }

    /// 当前区一次连接失败。返回 true = 连续失败到阈值了，该探测了（契约第六节的触发条件：连续 N 次连接失败）。
    @discardableResult
    public func reportConnectionFailure() -> Bool {
        let region = currentRegion()
        let count = countFailure(of: region)
        return count >= thresholds.failureThreshold
    }

    public func reportConnectionSuccess() {
        failures.set(FailureCount(region: currentRegion(), count: 0))
    }

    /// 并发探所有开着的区，给出建议。关着的区在碰网络之前就跳过：不查 DNS、不建连接（#1056 判据 4）。
    public func probe() async -> Decision {
        let enabled = profiles().filter(\.enabled)
        let probeRegion = self.probeRegion
        let timeout = thresholds.probeTimeout
        let results = await withTaskGroup(of: (TellomiRegionId, ProbeResult).self) { group in
            for region in enabled {
                group.addTask { (region.id, await probeRegion(region, timeout)) }
            }
            var results = [TellomiRegionId: ProbeResult]()
            for await (id, result) in group {
                results[id] = result
            }
            return results
        }

        let current = currentRegion()
        func decide(_ recommended: TellomiRegionId, _ reason: Reason) -> Decision {
            Decision(current: current, recommended: recommended, reason: reason, results: results)
        }

        // 别的区里握手最快的那个
        let best = results
            .filter { $0.key != current }
            .compactMap { id, result in result.rtt.map { (id: id, rtt: $0) } }
            .min { $0.rtt < $1.rtt }

        guard let mine = results[current]?.rtt else {
            let count = countFailure(of: current)
            guard let best else {
                return decide(current, .noAlternative)
            }
            return count >= thresholds.failureThreshold ? decide(best.id, .failover) : decide(current, .currentFailing)
        }

        failures.set(FailureCount(region: current, count: 0))
        guard let best, best.rtt + thresholds.latencyAdvantage < mine else {
            return decide(current, .stay)
        }
        // 驻留从上一次切区算起（持久化的），不从进程启动算起；没有记录视为已满足
        let since = lastSwitchAt() ?? .distantPast
        return now().timeIntervalSince(since) >= thresholds.minDwell ? decide(best.id, .faster) : decide(current, .dwell)
    }

    /// 连续失败按区计：生效区变了（切过区）就从 0 重新数。
    private func countFailure(of region: TellomiRegionId) -> Int {
        failures.update { state in
            if state.region != region {
                state = FailureCount(region: region, count: 0)
            }
            state.count += 1
            return state.count
        }
    }

    // MARK: - 探测：chat 端点的 TCP + TLS 握手

    private static let probeQueue = DispatchQueue(label: "org.tellomi.region-probe", qos: .utility)

    /// 对区的 chat 主机做 TCP + TLS 握手并计时（和 Desktop 的 `createChatProbe` 同一件事）。不发请求、不要账号，注册前也能用。
    /// 证书按系统信任根校验（自建服务端用公开 CA 签发的证书），DNS 被污染的入口过不了握手，不会被当成健康。
    /// 没有路由、解析不了（`.waiting`）立刻算失败，不等超时。
    public static let chatEndpointProbe: Probe = { region, timeout in
        guard let url = URL(string: region.chat), let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else {
            return .failed("bad chat url: \(region.chat)")
        }
        let connection = NWConnection(
            to: NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port),
            using: NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options()),
        )
        let startedAt = Date()
        return await withCheckedContinuation { continuation in
            let finished = AtomicBool(false, lock: .init())
            let finish: @Sendable (ProbeResult) -> Void = { result in
                guard finished.tryToSetFlag() else {
                    return
                }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.ok(rtt: Date().timeIntervalSince(startedAt)))
                case .waiting(let error), .failed(let error):
                    finish(.failed("\(error)"))
                default:
                    break
                }
            }
            connection.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + timeout) {
                finish(.failed("timeout after \(timeout)s"))
            }
        }
    }
}

// MARK: - 远程配置驱动的切区（REGION_PROFILE 第六节之二）
// 放在这个文件里而不是新建：新文件要手工登记进 project.pbxproj（BUILD_IOS.md）。

/// Tellomi：远程配置驱动的切区（超级仓库 `docs/signal/REGION_PROFILE.md` 第六节之二）。
///
/// 规则和 Android `TellomiRegionAutoSwitch`、Desktop `ts/util/tellomiRegionTarget.std.ts` 逐条一致：
/// - `global.tellomi.region.target` 只认 `global` / `cn`；没下发、空、不认识 = 目标 global 且「没明说」。
/// - 当前区 ≠ 目标：先探目标，探通了才切（`switch`），探不通留在原地（`target-unreachable`）。
/// - 当前区 = 目标且没明说：功能关着（`off`），什么都不探，连 `tellomi.cn` 的名字都不解析。
/// - 当前区 = 目标且明说了：探当前区。通 = `stay`（失败计数清零）；不通计一次，不到阈值 `current-failing`，
///   到阈值去探另一个开着的区，通了切过去（`failover`），不通 `no-alternative`。
/// - 失败切走之后，下一轮当前区 ≠ 目标，目标一探通就切回来。撤回 = 改远程配置的值。
public struct TellomiRegionAutoSwitch {
    public static let key = "global.tellomi.region.target"
    public static let defaultFailureThreshold = 3

    public enum Reason: String, Sendable {
        case off
        case stay
        case `switch`
        case targetUnreachable = "target-unreachable"
        case currentFailing = "current-failing"
        case failover
        case noAlternative = "no-alternative"
    }

    public struct Target: Equatable, Sendable {
        public let id: TellomiRegionId
        public let explicit: Bool
    }

    public static func parseTarget(_ value: String?) -> Target {
        switch value {
        case "global": return Target(id: .global, explicit: true)
        case "cn": return Target(id: .cn, explicit: true)
        default: return Target(id: .global, explicit: false)
        }
    }

    let profiles: () -> [TellomiRegionProfile]
    let currentId: () -> TellomiRegionId
    let targetValue: () -> String?
    let loadFailures: () -> Int
    let storeFailures: (Int) -> Void
    let probe: (TellomiRegionProfile) async -> Bool
    let switchTo: (TellomiRegionId) throws -> Void
    let failureThreshold: Int

    public init(
        profiles: @escaping () -> [TellomiRegionProfile],
        currentId: @escaping () -> TellomiRegionId,
        targetValue: @escaping () -> String?,
        loadFailures: @escaping () -> Int,
        storeFailures: @escaping (Int) -> Void,
        probe: @escaping (TellomiRegionProfile) async -> Bool,
        switchTo: @escaping (TellomiRegionId) throws -> Void,
        failureThreshold: Int = TellomiRegionAutoSwitch.defaultFailureThreshold,
    ) {
        self.profiles = profiles
        self.currentId = currentId
        self.targetValue = targetValue
        self.loadFailures = loadFailures
        self.storeFailures = storeFailures
        self.probe = probe
        self.switchTo = switchTo
        self.failureThreshold = failureThreshold
    }

    public func evaluate() async -> Reason {
        let enabled = profiles().filter(\.enabled)
        func profile(_ id: TellomiRegionId) -> TellomiRegionProfile? { enabled.first { $0.id == id } }

        let current = profile(currentId())?.id ?? .global
        var target = Self.parseTarget(targetValue())
        if profile(target.id) == nil {
            target = Target(id: .global, explicit: false)
        }

        if current != target.id {
            guard let targetProfile = profile(target.id), await probe(targetProfile) else {
                return .targetUnreachable
            }
            return doSwitch(to: target.id) ? .switch : .targetUnreachable
        }

        guard target.explicit else {
            if loadFailures() != 0 {
                storeFailures(0)
            }
            return .off
        }

        guard let currentProfile = profile(current) else {
            return .off
        }
        if await probe(currentProfile) {
            if loadFailures() != 0 {
                storeFailures(0)
            }
            return .stay
        }

        let failures = loadFailures() + 1
        storeFailures(failures)
        guard failures >= failureThreshold else {
            return .currentFailing
        }

        guard let other = enabled.first(where: { $0.id != current }), await probe(other) else {
            return .noAlternative
        }
        return doSwitch(to: other.id) ? .failover : .noAlternative
    }

    private func doSwitch(to id: TellomiRegionId) -> Bool {
        do {
            try switchTo(id)
            storeFailures(0)
            return true
        } catch {
            Logger.warn("[Tellomi region] auto switch to \(id.rawValue) failed: \(error)")
            return false
        }
    }
}

/// 接本进程装上的 provider、远程配置和 app group 里的失败计数。只在主 App 里跑：NSE / 分享扩展跟着 app group 里记住的区走。
public enum TellomiRegionAutoSwitchRunner {
    private static let running = AtomicBool(false, lock: .init())

    /// 远程配置刷新之后、回到前台时调。同一时刻只跑一轮；功能关着时不碰网络。
    public static func evaluateAsync(_ why: String) {
        guard CurrentAppContext().isMainApp, let provider = TellomiNetProvider.installed else {
            return
        }
        guard running.tryToSetFlag() else {
            return
        }
        Task.detached(priority: .utility) {
            defer { running.set(false) }
            let store = TellomiRegionStore.appGroup
            let auto = TellomiRegionAutoSwitch(
                profiles: { provider.profiles },
                currentId: { provider.activeRegion.id },
                targetValue: { RemoteConfig.current.tellomiRegionTarget },
                loadFailures: { store.targetFailures() },
                storeFailures: { store.setTargetFailures($0) },
                probe: { region in
                    let result = await TellomiRegionSelector.chatEndpointProbe(region, TellomiRegionSelector.Thresholds.defaults.probeTimeout)
                    if case .ok = result {
                        return true
                    }
                    return false
                },
                switchTo: { id in _ = try provider.switchTo(id) },
            )
            let reason = await auto.evaluate()
            if reason != .off {
                Logger.info("[Tellomi region] auto switch (\(why)): \(reason.rawValue), now on \(provider.activeRegion.id.rawValue)")
            }
        }
    }
}
