//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest
@testable import SignalServiceKit

/// tellomi/tellomi#1056：区域表与 RegionProfile 契约 v2（超级仓库 docs/signal/REGION_PROFILE.md）的不变量。
class TellomiRegionsTest: XCTestCase {
    private let global = TellomiRegions.global
    private let cn = TellomiRegions.cn
    /// 关着的 CN（远程配置驱动切区之前包里的样子）：「关着的区不碰网络」这些判据仍要守住。
    private var cnOff: TellomiRegionProfile { TellomiRegionProfile(copying: cn, enabled: false) }
    private var cnOffTable: [TellomiRegionProfile] { [global, cnOff] }

    func testGlobalRegionIsExactlyTheContractTable() {
        XCTAssertEqual(global.id, .global)
        XCTAssertTrue(global.enabled)
        XCTAssertEqual(global.chat, "https://chat.tellomi.app")
        XCTAssertEqual(global.grpcChatHost, "grpc.chat.tellomi.app")
        XCTAssertEqual(global.storage, "https://storage.tellomi.app")
        XCTAssertEqual(global.cdn0, "https://cdn.tellomi.app")
        XCTAssertEqual(global.cdn2, "https://cdn2.tellomi.app")
        XCTAssertEqual(global.cdn3, "https://cdn3.tellomi.app")
        XCTAssertEqual(global.updates, "https://updates.tellomi.app")
        XCTAssertEqual(global.contentProxyHost, "contentproxy.tellomi.app")
        XCTAssertEqual(global.contentProxyPort, 443)
        XCTAssertEqual(global.captchaRegistration, "https://chat.tellomi.app/captcha-tellomi/registration/generate.html")
        XCTAssertEqual(global.captchaChallenge, "https://chat.tellomi.app/captcha-tellomi/challenge/generate.html")
        XCTAssertEqual(global.sfu, "https://chat.tellomi.app/callingService")
        XCTAssertEqual(global.uptimeHost, "uptime.tellomi.app")
        XCTAssertEqual(global.debugLog, "https://chat.tellomi.app/debuglogs")
    }

    func testTheTellomiConstantsAreReadFromTheGlobalRegion() {
        // 契约第五节第 5 条「端点只从 profile 取」：所有构建默认用的 TSConstantsStaging 和原来写死的回落地址都指到表里
        let constants = TSConstantsStaging()
        XCTAssertEqual(constants.mainServiceURL, global.chat)
        XCTAssertEqual(constants.customServerChatHostname, global.grpcChatHost)
        XCTAssertEqual(constants.storageServiceURL, global.storage)
        XCTAssertEqual(constants.textSecureCDN0ServerURL, global.cdn0)
        XCTAssertEqual(constants.textSecureCDN2ServerURL, global.cdn2)
        XCTAssertEqual(constants.textSecureCDN3ServerURL, global.cdn3)
        XCTAssertEqual(constants.updatesURL, global.updates)
        XCTAssertEqual(constants.updates2URL, global.updates)
        XCTAssertEqual(constants.registrationCaptchaURL, global.captchaRegistration)
        XCTAssertEqual(constants.challengeCaptchaURL, global.captchaChallenge)
        XCTAssertEqual(constants.sfuURL, global.sfu)
        XCTAssertEqual(constants.sfuTestURL, global.sfu)
        XCTAssertEqual(ContentProxy.defaultEndpoint.host, global.contentProxyHost)
        XCTAssertEqual(ContentProxy.defaultEndpoint.port, global.contentProxyPort)
    }

    func testCnRegionOnlySwapsTheHostIntoTellomiCn() {
        XCTAssertEqual(cn.id, .cn)
        // REGION_PROFILE 第六节之二：CN 可用（enabled = true），切不切由远程配置 global.tellomi.region.target 决定
        XCTAssertTrue(cn.enabled)
        XCTAssertEqual(cn.chat, "https://chat.tellomi.cn")
        XCTAssertEqual(cn.grpcChatHost, "grpc.chat.tellomi.cn")
        XCTAssertEqual(cn.captchaRegistration, "https://chat.tellomi.cn/captcha-tellomi/registration/generate.html")
        XCTAssertEqual(cn.sfu, "https://chat.tellomi.cn/callingService")
        XCTAssertEqual(cn.contentProxyHost, "contentproxy.tellomi.cn")
        XCTAssertEqual(cn.contentProxyPort, 443)
        XCTAssertEqual(cn.debugLog, "https://chat.tellomi.cn/debuglogs")

        // App 备案要填运行时连接的全部域名：CN 档一条都不能留在 tellomi.app
        XCTAssertFalse(cn.endpoints.contains { $0.contains("tellomi.app") })
        // 整张核（不只抽查）：今天 global 的端点路径里都不含 tellomi.app，所以整串替换就是正确答案
        XCTAssertEqual(cn.endpoints, global.endpoints.map { $0.replacingOccurrences(of: ".tellomi.app", with: ".tellomi.cn") })
    }

    func testHostRewriteKeepsEverythingButTheHost() {
        XCTAssertEqual(TellomiRegions.toCnHost("https://updates.tellomi.app/ios/manifest.json"), "https://updates.tellomi.cn/ios/manifest.json")
        XCTAssertEqual(TellomiRegions.toCnHost("contentproxy.tellomi.app:443"), "contentproxy.tellomi.cn:443")
        XCTAssertEqual(
            TellomiRegions.toCnHost("https://chat.tellomi.app:8443/x.tellomi.app/y?q=z.tellomi.app#f.tellomi.app"),
            "https://chat.tellomi.cn:8443/x.tellomi.app/y?q=z.tellomi.app#f.tellomi.app",
        )
        // 别的域名、顶级域本身都不动（由 problems 挑出来）
        XCTAssertEqual(TellomiRegions.toCnHost("https://api.stripe.com/v1"), "https://api.stripe.com/v1")
        XCTAssertEqual(TellomiRegions.toCnHost("https://tellomi.app/download"), "https://tellomi.app/download")
        XCTAssertEqual(TellomiRegions.toCnHost("wss://svr2.staging.signal.org"), "wss://svr2.staging.signal.org")

        XCTAssertEqual(TellomiRegions.hostOf("https://chat.tellomi.app/callingService"), "chat.tellomi.app")
        XCTAssertEqual(TellomiRegions.hostOf("grpc.chat.tellomi.app"), "grpc.chat.tellomi.app")
        XCTAssertEqual(TellomiRegions.hostOf("contentproxy.tellomi.app:443"), "contentproxy.tellomi.app")
    }

    func testPackagedRegionsSatisfyTheInvariants() {
        XCTAssertEqual(TellomiRegions.problems(TellomiRegions.all), [])
        XCTAssertEqual(TellomiRegions.all.map(\.id), [.global, .cn])
    }

    func testInvariantCheckCatchesABrokenTable() {
        let disabledGlobal = TellomiRegionProfile(copying: global, enabled: false)
        XCTAssertFalse(TellomiRegions.problems([disabledGlobal, cn]).isEmpty)

        XCTAssertFalse(TellomiRegions.problems([cn]).isEmpty)

        // 开着的 CN 是合法的；关着的也合法
        XCTAssertEqual(TellomiRegions.problems([global, cn]), [])
        XCTAssertEqual(TellomiRegions.problems(cnOffTable), [])

        // CN 漏换一个主机
        let leakyCn = TellomiRegionProfile(copying: cn, uptimeHost: global.uptimeHost)
        XCTAssertEqual(TellomiRegions.problems([global, leakyCn]), ["cn endpoint outside tellomi.cn: uptime.tellomi.app"])

        XCTAssertFalse(TellomiRegions.problems([global, cn, cn]).isEmpty)
    }

    // MARK: - 当前区（#1056 第二刀）

    func testCurrentRegionFallsBackToGlobalForAnythingUnusable() {
        // 契约第五节第 8 条：没有记录、不认识、那个区关着，一律回落 global
        for storedId in [nil, "global", "unknown", "", "GLOBAL", "CN"] {
            XCTAssertEqual(TellomiRegions.resolve(storedId: storedId).id, .global, String(describing: storedId))
        }
        XCTAssertEqual(TellomiRegions.resolve(storedId: "cn").id, .cn)
        XCTAssertEqual(TellomiRegions.resolve(storedId: "cn", profiles: cnOffTable).id, .global)
        // CN 打开以后才认 "cn"
        let cnOn = TellomiRegionProfile(copying: cn, enabled: true)
        XCTAssertEqual(TellomiRegions.resolve(storedId: "cn", profiles: [global, cnOn]).id, .cn)
        XCTAssertEqual(TellomiRegions.resolve(storedId: "global", profiles: [global, cnOn]).id, .global)
    }

    func testCurrentRegionReadsTheSharedStoreAndNeverThrows() {
        let defaults = TestUtils.userDefaults()
        let store = TellomiRegionStore(userDefaults: { defaults })
        XCTAssertNil(store.storedRegionId())
        XCTAssertNil(store.lastSwitchAt())
        XCTAssertEqual(TellomiRegions.current(store: store), global)

        let switchedAt = Date(timeIntervalSince1970: 1_790_000_000)
        store.record(.cn, at: switchedAt)
        XCTAssertEqual(store.storedRegionId(), "cn")
        XCTAssertEqual(store.lastSwitchAt(), switchedAt)
        // CN 允许（REGION_PROFILE 第六节之二）：记住了 cn 就落在 cn
        XCTAssertEqual(TellomiRegions.current(store: store), cn)
        // 那个区关着时仍回落 global（契约第五节第 8 条）
        XCTAssertEqual(TellomiRegions.resolve(storedId: store.storedRegionId(), profiles: cnOffTable), global)

        // 读不出来（suite 建不起来）：回落 global，写入也不崩
        let unavailable = TellomiRegionStore(userDefaults: { nil })
        XCTAssertEqual(TellomiRegions.current(store: unavailable), global)
        unavailable.record(.cn, at: switchedAt)
        XCTAssertNil(unavailable.storedRegionId())
    }

    func testStagingEndpointsAreReadAtUseTimeNotOnce() {
        // #1056 交接评论第二处：TSConstants.shared 是 static let，端点要是在初始化时存下来，
        // 以后切区只重建了 Net，REST 侧还连旧区（半切换）。这里切换当前区，同一个实例取到的端点要跟着变。
        var region = global
        let constants = TSConstantsStaging(region: { region })
        XCTAssertEqual(constants.mainServiceURL, "https://chat.tellomi.app")

        region = cn
        XCTAssertEqual(constants.mainServiceURL, cn.chat)
        XCTAssertEqual(constants.customServerChatHostname, cn.grpcChatHost)
        XCTAssertEqual(constants.storageServiceURL, cn.storage)
        XCTAssertEqual(constants.textSecureCDN0ServerURL, cn.cdn0)
        XCTAssertEqual(constants.textSecureCDN2ServerURL, cn.cdn2)
        XCTAssertEqual(constants.textSecureCDN3ServerURL, cn.cdn3)
        XCTAssertEqual(constants.updatesURL, cn.updates)
        XCTAssertEqual(constants.updates2URL, cn.updates)
        XCTAssertEqual(constants.registrationCaptchaURL, cn.captchaRegistration)
        XCTAssertEqual(constants.challengeCaptchaURL, cn.captchaChallenge)
        XCTAssertEqual(constants.sfuURL, cn.sfu)
        XCTAssertEqual(constants.sfuTestURL, cn.sfu)
    }

    // MARK: - 门禁：端点只从区域表取（契约第五节第 5 条）

    /// 区域表里的端点主机。别的源文件再写这些主机的字面量，就绕过了区域表：切区时它还连旧区，CN 档备案也会漏报。
    /// 官网（tellomi.app 本身）、tell.cc 不分区，不在单子里。
    private static let endpointHosts = [
        "chat.tellomi.app",
        "grpc.chat.tellomi.app",
        "storage.tellomi.app",
        "cdn.tellomi.app",
        "cdn2.tellomi.app",
        "cdn3.tellomi.app",
        "updates.tellomi.app",
        "contentproxy.tellomi.app",
        "uptime.tellomi.app",
    ]

    private static let regionTableFile = "SignalServiceKit/Environment/TellomiRegions.swift"

    /// 扫各个 App 目标的源码（不含测试），返回「相对路径:行号: 内容」。注释行不算。
    private func endpointLiterals() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Util
            .deletingLastPathComponent() // tests
            .deletingLastPathComponent() // SignalServiceKit
            .deletingLastPathComponent() // 仓库根
            .resolvingSymlinksInPath() // 本机 /tmp 是 /private/tmp 的链接，枚举出来的是解析后的路径，两边要一致
        var hits = [String]()
        for target in ["Signal", "SignalServiceKit", "SignalUI", "SignalNSE", "SignalShareExtension"] {
            let dir = root.appendingPathComponent(target)
            guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
                XCTFail("can't read \(dir.path)")
                continue
            }
            for case let url as URL in enumerator {
                if ["test", "tests", "TestUtils"].contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift" else {
                    continue
                }
                let path = url.resolvingSymlinksInPath().path
                guard path.hasPrefix(root.path + "/") else {
                    XCTFail("\(path) is outside \(root.path)")
                    continue
                }
                let relativePath = String(path.dropFirst(root.path.count + 1))
                let text = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                        continue
                    }
                    if Self.endpointHosts.contains(where: { line.contains($0) }) {
                        hits.append("\(relativePath):\(index + 1): \(trimmed)")
                    }
                }
            }
        }
        return hits
    }

    func testEndpointsAreReadOnlyFromTheRegionTable() throws {
        let outside = try endpointLiterals().filter { !$0.hasPrefix(Self.regionTableFile + ":") }
        XCTAssertEqual(outside, [], "端点主机只许写在区域表里，其余地方从 TellomiRegions.current() 取")
    }

    func testTheEndpointScanActuallyReadsTheSources() throws {
        // 正对照：区域表文件本身命中十几处，证明扫描确实读到了源码，上面那条「没找到」不是空断言
        let inTable = try endpointLiterals().filter { $0.hasPrefix(Self.regionTableFile + ":") }
        XCTAssertGreaterThanOrEqual(inTable.count, Self.endpointHosts.count)
    }

    // MARK: - #1056 第三刀：Net 只放在 provider 里

    /// 只建对象、不连：`.invalid` 永远解析不到。
    private func makeTestNet() -> Net {
        Net(customServerHostname: "chat.tellomi.invalid", userAgent: "TellomiRegionsTest", buildVariant: .production)
    }

    func testProviderHandsOutTheCurrentNetAndSwapsItAtomically() {
        let first = makeTestNet()
        let provider = TellomiNetProvider(region: global, net: first)
        XCTAssertTrue(provider.current === first)
        XCTAssertEqual(provider.activeRegion, global)
        XCTAssertEqual(provider.generation, 0)

        let second = makeTestNet()
        let replaced = provider.replace(net: second, region: cn)
        XCTAssertTrue(replaced === first)
        XCTAssertTrue(provider.current === second)
        XCTAssertEqual(provider.activeRegion, cn)
        XCTAssertEqual(provider.generation, 1)
    }

    func testHoldersDoNotKeepTheOldNetAlive() {
        // 切区要换掉 Net：持有方都活着的时候，换下来的旧 Net 也必须放得掉（#1056 判据 2 的单测版本）。
        // NetworkManager 那个跟进程一样长的网络变化 Task 以前直接捕获 Net，就是最容易漏的一处。
        weak var weakOld: Net?
        let provider = TellomiNetProvider(
            region: global,
            net: {
                let net = makeTestNet()
                weakOld = net
                return net
            }(),
        )
        let networkManager = NetworkManager(appReadiness: AppReadinessMock(), netProvider: provider)
        let signalService = OWSSignalService(netProvider: provider)
        XCTAssertNotNil(weakOld)
        XCTAssertTrue(networkManager.libsignalNet === provider.current)

        do {
            let replaced = provider.replace(net: makeTestNet(), region: global)
            XCTAssertTrue(replaced === weakOld)
        }

        XCTAssertNil(weakOld, "换下来的 Net 还被持有方留着")
        XCTAssertTrue(networkManager.libsignalNet === provider.current)
        withExtendedLifetime((networkManager, signalService)) {}
    }

    // MARK: - #1056 第三刀：本进程生效区（提交 B）

    func testActiveRegionFollowsTheInstalledProvider() {
        let cnOn = TellomiRegionProfile(copying: cn, enabled: true)
        let provider = TellomiNetProvider(region: cnOn, net: makeTestNet())
        let previous = TellomiNetProvider.installForTesting(provider)
        defer { TellomiNetProvider.installForTesting(previous) }

        // 生效区跟着 provider（和 Net 同一个原子状态），REST 端点、内容代理回落都跟着它
        XCTAssertEqual(TellomiRegions.active(), cnOn)
        XCTAssertEqual(TSConstantsStaging().mainServiceURL, cnOn.chat)
        XCTAssertEqual(TSConstantsStaging().textSecureCDN3ServerURL, cnOn.cdn3)
        XCTAssertEqual(ContentProxy.defaultEndpoint.host, cnOn.contentProxyHost)

        // 还没装 provider（AppSetup 建 Net 之前）：回落记住的区
        TellomiNetProvider.installForTesting(nil)
        XCTAssertEqual(TellomiRegions.active(), TellomiRegions.current())
    }

    func testCdnSessionsFollowTheActiveRegionAndOldOnesStayCached() async {
        let cnOn = TellomiRegionProfile(copying: cn, enabled: true)
        let provider = TellomiNetProvider(region: global, net: makeTestNet())
        let previous = TellomiNetProvider.installForTesting(provider)
        defer { TellomiNetProvider.installForTesting(previous) }
        let signalService = OWSSignalService(netProvider: provider)

        let before = await signalService.sharedUrlSessionForCdn(cdnNumber: 3)
        XCTAssertEqual(before.endpoint.baseUrl?.host, "cdn3.tellomi.app")

        // 切区后：按生效区解析出新地址，拿到新区的会话（不用等哪次网络失败把缓存冲掉）
        provider.replace(net: makeTestNet(), region: cnOn)
        let after = await signalService.sharedUrlSessionForCdn(cdnNumber: 3)
        XCTAssertEqual(after.endpoint.baseUrl?.host, "cdn3.tellomi.cn")

        // 旧区的会话还在缓存里，给钉住旧区的在途上传用：按旧地址取，拿到的是同一个
        let pinned = await signalService.sharedUrlSessionForCdn(cdnNumber: 3, baseUrl: URL(string: global.cdn3)!)
        XCTAssertTrue((pinned as AnyObject) === (before as AnyObject))
    }

    // MARK: - #1056 第三刀：在途上传钉住开始时的区（提交 D）

    private func makeForm(regionId: String?) -> Upload.Form {
        Upload.Form(headers: HttpHeaders(), signedUploadLocation: "https://cdn3.tellomi.app/upload", cdnKey: "key", cdnNumber: 3, tellomiRegionId: regionId)
    }

    func testUploadFormsAreStampedWithTheActiveRegion() {
        let cnOn = TellomiRegionProfile(copying: cn, enabled: true)
        let provider = TellomiNetProvider(region: global, net: makeTestNet(), profiles: [global, cnOn])
        let previous = TellomiNetProvider.installForTesting(provider)
        defer { TellomiNetProvider.installForTesting(previous) }
        let remote = UploadForm(cdn: 3, key: "key", headers: [:], signedUploadUrl: URL(string: "https://cdn3.tellomi.app/upload")!)

        XCTAssertEqual(Upload.Form(uploadForm: remote).tellomiRegionId, "global")
        provider.replace(net: makeTestNet(), region: cnOn)
        XCTAssertEqual(Upload.Form(uploadForm: remote).tellomiRegionId, "cn")
    }

    func testPinnedCdnAddressFollowsTheStampNotTheActiveRegion() {
        let cnOn = TellomiRegionProfile(copying: cn, enabled: true)
        let provider = TellomiNetProvider(region: global, net: makeTestNet(), profiles: [global, cnOn])
        let previous = TellomiNetProvider.installForTesting(provider)
        defer { TellomiNetProvider.installForTesting(previous) }
        let startedInGlobal = makeForm(regionId: "global")
        let startedInCn = makeForm(regionId: "cn")

        // 切区以后，在途的上传仍连开始时那个区的 cdn3；新开始的上传才用新区
        provider.replace(net: makeTestNet(), region: cnOn)
        XCTAssertEqual(startedInGlobal.tellomiPinnedCdnBaseUrl.host, "cdn3.tellomi.app")
        XCTAssertEqual(startedInCn.tellomiPinnedCdnBaseUrl.host, "cdn3.tellomi.cn")
        provider.replace(net: makeTestNet(), region: global)
        XCTAssertEqual(startedInCn.tellomiPinnedCdnBaseUrl.host, "cdn3.tellomi.cn")
    }

    func testFormsFromBeforeTheStampArePinnedToGlobal() throws {
        let cnOn = TellomiRegionProfile(copying: cn, enabled: true)
        let provider = TellomiNetProvider(region: cnOn, net: makeTestNet(), profiles: [global, cnOn])
        let previous = TellomiNetProvider.installForTesting(provider)
        defer { TellomiNetProvider.installForTesting(previous) }

        // 表单整个以 JSON 存在上传记录里：章跟着存取；第三刀之前存的记录没有这个键，按 global（不是按生效区）
        let stamped = try JSONDecoder().decode(Upload.Form.self, from: JSONEncoder().encode(makeForm(regionId: "cn")))
        XCTAssertEqual(stamped.tellomiRegionId, "cn")
        let legacyJson = try JSONEncoder().encode(makeForm(regionId: nil))
        XCTAssertFalse(String(decoding: legacyJson, as: UTF8.self).contains("tellomiRegionId"))
        let legacy = try JSONDecoder().decode(Upload.Form.self, from: legacyJson)
        XCTAssertNil(legacy.tellomiRegionId)
        XCTAssertEqual(legacy.tellomiPinnedRegion, global)
        XCTAssertEqual(legacy.tellomiPinnedCdnBaseUrl.host, "cdn3.tellomi.app")
    }

    func testAFormPinnedToATurnedOffRegionIsNotReused() {
        let net = makeTestNet()
        // 包里的 CN 允许（REGION_PROFILE 第六节之二）：钉在 CN 的表单照常续传，仍连 CN
        let cnAllowed = TellomiNetProvider(region: global, net: net, profiles: TellomiRegions.all)
        let previous = TellomiNetProvider.installForTesting(cnAllowed)
        defer { TellomiNetProvider.installForTesting(previous) }
        XCTAssertEqual(makeForm(regionId: "cn").tellomiPinnedRegion, TellomiRegions.cn)
        XCTAssertNil(makeForm(regionId: "unknown").tellomiPinnedRegion)
        XCTAssertEqual(makeForm(regionId: "global").tellomiPinnedRegion, TellomiRegions.global)

        // 那个区关着：钉在 CN 的表单不能再用，上传管理器当它过期，重新取表单、从 0 开始、落到当前区
        TellomiNetProvider.installForTesting(TellomiNetProvider(region: global, net: net, profiles: cnOffTable))
        XCTAssertNil(makeForm(regionId: "cn").tellomiPinnedRegion)
        XCTAssertNil(makeForm(regionId: "unknown").tellomiPinnedRegion)
        XCTAssertEqual(makeForm(regionId: "global").tellomiPinnedRegion, TellomiRegions.global)
    }

    /// 上传目录里取 CDN 会话，一律按表单钉住的地址取：不带 `baseUrl:` 的取法会按生效区走，切区后续传就换了区。
    private func uploadCdnSessionCalls() throws -> (unpinned: [String], pinned: Int) {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Util
            .deletingLastPathComponent() // tests
            .deletingLastPathComponent() // SignalServiceKit
            .appendingPathComponent("Upload")
            .resolvingSymlinksInPath()
        var unpinned = [String]()
        var pinned = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasPrefix("UploadEndpoint") && name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() where line.contains("sharedUrlSessionForCdn(cdnNumber:") {
                if line.contains("baseUrl: uploadForm.tellomiPinnedCdnBaseUrl") {
                    pinned += 1
                } else {
                    unpinned.append("\(name):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return (unpinned, pinned)
    }

    func testUploadEndpointsOnlyUsePinnedCdnSessions() throws {
        XCTAssertEqual(try uploadCdnSessionCalls().unpinned, [])
    }

    func testTheUploadScanActuallyFindsTheCalls() throws {
        // 正对照：CDN2 三处、CDN3 两处，都扫得到
        XCTAssertEqual(try uploadCdnSessionCalls().pinned, 5)
    }

    // MARK: - #1056 第三刀：切区（提交 C）

    private final class RebuildRecorder {
        var madeFor = [TellomiRegionId]()
        var configured = [ObjectIdentifier]()
    }

    private func makeSwitchableProvider(profiles: [TellomiRegionProfile], retireDelay: TimeInterval = 60) -> (TellomiNetProvider, RebuildRecorder) {
        let recorder = RebuildRecorder()
        let provider = TellomiNetProvider(region: global, net: makeTestNet(), profiles: profiles, retireDelay: retireDelay)
        provider.setRebuild(TellomiNetProvider.Rebuild(
            makeNet: { [unowned self] region in
                recorder.madeFor.append(region.id)
                return self.makeTestNet()
            },
            configure: { net in
                recorder.configured.append(ObjectIdentifier(net))
            },
        ))
        return (provider, recorder)
    }

    func testSwitchingRefusesUnknownAndDisabledRegionsBeforeTouchingTheNetwork() {
        // 关着的 CN：直接报错
        let (provider, recorder) = makeSwitchableProvider(profiles: cnOffTable)
        XCTAssertThrowsError(try provider.switchTo(.cn, store: nil)) { XCTAssertEqual($0 as? TellomiRegionSwitchError, .disabled) }
        // 不认识的区
        let (onlyGlobal, onlyGlobalRecorder) = makeSwitchableProvider(profiles: [global])
        XCTAssertThrowsError(try onlyGlobal.switchTo(.cn, store: nil)) { XCTAssertEqual($0 as? TellomiRegionSwitchError, .unknown) }
        // 两种都在建 Net 之前就停了：不查 DNS、不建连接（#1056 判据 4 在切换器这一层）
        XCTAssertEqual(recorder.madeFor, [])
        XCTAssertEqual(onlyGlobalRecorder.madeFor, [])
        XCTAssertEqual(provider.generation, 0)
        // 没接重建（USE_PRODUCTION、AppSetup 之前）
        XCTAssertThrowsError(try TellomiNetProvider(region: global, net: makeTestNet()).switchTo(.global, store: nil)) {
            XCTAssertEqual($0 as? TellomiRegionSwitchError, .notApplicable)
        }
    }

    func testSwitchingToTheActiveRegionIsANoOp() throws {
        let (provider, recorder) = makeSwitchableProvider(profiles: [global, TellomiRegionProfile(copying: cn, enabled: true)])
        XCTAssertFalse(try provider.switchTo(.global, store: nil))
        XCTAssertEqual(recorder.madeFor, [])
        XCTAssertEqual(provider.generation, 0)
    }

    func testSwitchingSwapsTheNetRecordsTheRegionAndNotifiesOnce() throws {
        let cnOn = TellomiRegionProfile(copying: cn, enabled: true)
        let (provider, recorder) = makeSwitchableProvider(profiles: [global, cnOn])
        let defaults = TestUtils.userDefaults()
        let store = TellomiRegionStore(userDefaults: { defaults })
        let before = provider.current
        let notifications = AtomicValue<Int>(0, lock: .init())
        let observer = NotificationCenter.default.addObserver(forName: .tellomiRegionDidChange, object: nil, queue: nil) { _ in
            notifications.update { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let switchedAt = Date(timeIntervalSince1970: 1_790_000_000)

        XCTAssertTrue(try provider.switchTo(.cn, store: store, now: switchedAt))

        // 按新区建了一个 Net，先配好再换上，换上以后幂等再配一次
        XCTAssertEqual(recorder.madeFor, [.cn])
        XCTAssertFalse(provider.current === before)
        XCTAssertEqual(recorder.configured, [ObjectIdentifier(provider.current), ObjectIdentifier(provider.current)])
        XCTAssertEqual(provider.activeRegion, cnOn)
        XCTAssertEqual(provider.generation, 1)
        // 主 App 记进 app group（区和切区时间，契约第六节「驻留时间从哪算起」）
        XCTAssertEqual(store.storedRegionId(), "cn")
        XCTAssertEqual(store.lastSwitchAt(), switchedAt)
        // 旧 Net 进了退役区
        XCTAssertEqual(provider.retiredCount, 1)
        // 通知在主线程发：让主线程跑一轮再数，只发一次
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(notifications.get(), 1)
    }

    func testAdoptingTheStoredRegionRebuildsOnlyWhenItChanged() throws {
        let cnOn = TellomiRegionProfile(copying: cn, enabled: true)
        let (provider, recorder) = makeSwitchableProvider(profiles: [global, cnOn])
        let defaults = TestUtils.userDefaults()
        let store = TellomiRegionStore(userDefaults: { defaults })

        // 没有记录 = global = 生效区：不重建
        XCTAssertFalse(provider.adoptStoredRegionIfChanged(store: store))
        // 主 App 记了 CN：NSE 跟着换，但不写 store（切区时间还是主 App 记的那个）
        let recordedAt = Date(timeIntervalSince1970: 1_790_000_000)
        store.record(.cn, at: recordedAt)
        XCTAssertTrue(provider.adoptStoredRegionIfChanged(store: store))
        XCTAssertEqual(provider.activeRegion, cnOn)
        XCTAssertEqual(store.lastSwitchAt(), recordedAt)
        // 没变：不重建
        XCTAssertFalse(provider.adoptStoredRegionIfChanged(store: store))
        XCTAssertEqual(recorder.madeFor, [.cn])
    }

    func testRetiredNetIsReleasedAfterTheDelay() throws {
        let cnOn = TellomiRegionProfile(copying: cn, enabled: true)
        let (provider, _) = makeSwitchableProvider(profiles: [global, cnOn], retireDelay: 0.2)
        weak let weakOld = provider.current
        XCTAssertTrue(try provider.switchTo(.cn, store: nil))

        // 退役期内还留着：旧连接的回调可能还在用它
        XCTAssertNotNil(weakOld)
        XCTAssertEqual(provider.retiredCount, 1)
        // 到期后在专用后台队列上放掉（不在 tokio 线程上、不在主线程上）
        let deadline = Date().addingTimeInterval(5)
        while weakOld != nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(weakOld)
        XCTAssertEqual(provider.retiredCount, 0)
    }

    // MARK: - 门禁：除 provider 外不许存 Net

    private static let netProviderFile = "SignalServiceKit/Network/TellomiNetProvider.swift"

    /// 存储型的 `Net` 属性（`let x: Net` / `var x: LibSignalClient.Net?`，没有 `{` 也没有初始值）。计算属性、函数参数不算。
    private static let storedNetPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:public|private|fileprivate|internal|open|nonisolated\(unsafe\)|static|final|weak|unowned|lazy)\s+)*(?:let|var)\s+\w+\s*:\s*(?:LibSignalClient\.)?Net\??\s*(?://.*)?$"#,
    )

    private func storedNetDeclarations() throws -> [String] {
        var hits = [String]()
        for file in try appSourceFiles() {
            for (index, line) in file.lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                if Self.storedNetPattern.firstMatch(in: line, range: range) != nil {
                    hits.append("\(file.relativePath):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return hits
    }

    func testOnlyTheProviderStoresANet() throws {
        let outside = try storedNetDeclarations().filter { !$0.hasPrefix(Self.netProviderFile + ":") }
        XCTAssertEqual(outside, [], "Net 只许放在 TellomiNetProvider 里，别处从 provider 现取（不然切区后旧 Net 放不掉）")
    }

    func testTheStoredNetScanActuallyFindsDeclarations() throws {
        // 正对照：provider 自己的 State 里存着一个 Net，扫得到才说明上面那条「没有」不是空断言
        let inProvider = try storedNetDeclarations().filter { $0.hasPrefix(Self.netProviderFile + ":") }
        XCTAssertGreaterThanOrEqual(inProvider.count, 1)
    }

    // MARK: - #1056 第三刀：测试区与切区演练（提交 E）

    private let testDomainKey = TellomiRegions.testRegionDomainKey

    func testTheTestRegionIsOffUnlessTheLaunchEnvironmentAsksForIt() {
        XCTAssertEqual(TellomiRegions.testRegionProfiles(environment: [:]), TellomiRegions.all)
        for notADomain in ["", "localhost", ".tellomi.test", "tellomi.test.", "tellomi..test", "tellomi.test/x", "tel lomi.test", "tellomi.测试"] {
            XCTAssertEqual(TellomiRegions.testRegionProfiles(environment: [testDomainKey: notADomain]), TellomiRegions.all, notADomain)
        }
        // 跑单测的进程没带这个变量：本进程的表就是包里的表
        XCTAssertEqual(TellomiRegions.processProfiles, TellomiRegions.all)
    }

    func testTheTestRegionMovesEveryCnHostUnderTheGivenDomain() {
        let profiles = TellomiRegions.testRegionProfiles(environment: [testDomainKey: "tellomi.test"])
        XCTAssertEqual(profiles.map(\.id), [.global, .cn])
        XCTAssertEqual(profiles[0], global)
        let testRegion = profiles[1]
        XCTAssertTrue(testRegion.enabled)
        for endpoint in testRegion.endpoints {
            XCTAssertTrue(TellomiRegions.hostOf(endpoint).hasSuffix(".tellomi.test"), endpoint)
        }
        // 同名标签，路径和端口不变
        XCTAssertEqual(testRegion.chat, "https://chat.tellomi.test")
        XCTAssertEqual(testRegion.grpcChatHost, "grpc.chat.tellomi.test")
        XCTAssertEqual(testRegion.cdn3, "https://cdn3.tellomi.test")
        XCTAssertEqual(testRegion.captchaRegistration, "https://chat.tellomi.test/captcha-tellomi/registration/generate.html")
        XCTAssertEqual(testRegion.contentProxyPort, global.contentProxyPort)
        // 包里的表不受影响：不变量照旧
        XCTAssertEqual(TellomiRegions.cn.chat, "https://chat.tellomi.cn")
        XCTAssertEqual(TellomiRegions.problems(TellomiRegions.all), [])
    }

    func testAStoredTestRegionFallsBackToGlobalWithoutTheLaunchEnvironment() {
        let profiles = TellomiRegions.testRegionProfiles(environment: [testDomainKey: "tellomi.test"])
        XCTAssertEqual(TellomiRegions.resolve(storedId: "cn", profiles: profiles), profiles[1])
        // 下次不带变量启动（NSE、分享扩展一直是这样）：记住的 cn 回到包里的正式 CN（tellomi.cn），不再指向测试域名
        XCTAssertEqual(TellomiRegions.resolve(storedId: "cn", profiles: TellomiRegions.all), TellomiRegions.cn)
    }

    func testTheRealCnDomainCanNotBeTheTestRegion() {
        // 测试区是「开着的假 CN」：域名填成 tellomi.cn 本身（或它的子域）就等于在测试构建里把真 CN 打开，
        // 而 CN 关着的时候 tellomi.cn 下一个请求都不许发（契约第四节，App 备案）
        for cnDomain in ["tellomi.cn", "TELLOMI.CN", "Tellomi.Cn", "chat.tellomi.cn", "a.b.tellomi.cn"] {
            XCTAssertEqual(TellomiRegions.testRegionProfiles(environment: [testDomainKey: cnDomain]), TellomiRegions.all, cnDomain)
        }
        // 只是长得像的别的域不受影响
        XCTAssertTrue(TellomiRegions.testRegionProfiles(environment: [testDomainKey: "nottellomi.cn"])[1].enabled)
        XCTAssertTrue(TellomiRegions.testRegionProfiles(environment: [testDomainKey: "tellomi.cn.test"])[1].enabled)
    }

    func testSwitchingToTheTestRegionDoesNotRecordCnInTheAppGroup() throws {
        let profiles = TellomiRegions.testRegionProfiles(environment: [testDomainKey: "tellomi.test"])
        XCTAssertTrue(TellomiRegions.isTestRegion(profiles[1]))
        // 包里的区（包括将来开着的真 CN）都不算测试区
        XCTAssertFalse(TellomiRegions.isTestRegion(global))
        XCTAssertFalse(TellomiRegions.isTestRegion(TellomiRegionProfile(copying: cn, enabled: true)))

        let (provider, _) = makeSwitchableProvider(profiles: profiles)
        let defaults = TestUtils.userDefaults()
        let store = TellomiRegionStore(userDefaults: { defaults })
        let intoTest = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(try provider.switchTo(.cn, store: store, now: intoTest))
        XCTAssertEqual(provider.activeRegion, profiles[1])
        // 测试区借用 cn 的 id：不记进 app group（否则这台测试机以后装上真开 CN 的包会直接落到 CN），
        // 只记切区时间（选路器的驻留照常从这次切区算）
        XCTAssertNil(store.storedRegionId())
        XCTAssertEqual(store.lastSwitchAt(), intoTest)

        // 切回包里的区照常记
        let backToGlobal = Date(timeIntervalSince1970: 1_790_000_600)
        XCTAssertTrue(try provider.switchTo(.global, store: store, now: backToGlobal))
        XCTAssertEqual(store.storedRegionId(), "global")
        XCTAssertEqual(store.lastSwitchAt(), backToGlobal)
    }

    // MARK: 测试区可以指定端口（TELLOMI_TEST_REGION_PORT）

    private let testPortKey = TellomiRegions.testRegionPortKey

    func testPackagedRegionsAlwaysUseChatPort443() {
        XCTAssertEqual(TellomiRegions.chatPort(for: global), 443)
        XCTAssertEqual(TellomiRegions.chatPort(for: TellomiRegions.cn), 443)
        // 没带端口的测试区也是 443
        let profiles = TellomiRegions.testRegionProfiles(environment: [testDomainKey: "tellomi.test"])
        XCTAssertEqual(TellomiRegions.chatPort(for: profiles[1]), 443)
    }

    func testTheTestRegionPortMovesEveryUrlEndpointAndTheChatPort() {
        let profiles = TellomiRegions.testRegionProfiles(environment: [testDomainKey: "127.0.0.1.nip.io", testPortKey: "18443"])
        XCTAssertEqual(profiles[0], global)
        XCTAssertEqual(TellomiRegions.chatPort(for: profiles[0]), 443)
        let testRegion = profiles[1]
        XCTAssertEqual(TellomiRegions.chatPort(for: testRegion), 18443)
        XCTAssertEqual(testRegion.chat, "https://chat.127.0.0.1.nip.io:18443")
        XCTAssertEqual(testRegion.grpcChatHost, "grpc.chat.127.0.0.1.nip.io")
        XCTAssertEqual(testRegion.captchaRegistration, "https://chat.127.0.0.1.nip.io:18443/captcha-tellomi/registration/generate.html")
        XCTAssertEqual(testRegion.contentProxyPort, 18443)
        XCTAssertEqual(testRegion.uptimeHost, "uptime.127.0.0.1.nip.io")
        let urls = [
            testRegion.chat,
            testRegion.storage,
            testRegion.cdn0,
            testRegion.cdn2,
            testRegion.cdn3,
            testRegion.updates,
            testRegion.captchaRegistration,
            testRegion.captchaChallenge,
            testRegion.sfu,
            testRegion.debugLog,
        ]
        for url in urls {
            XCTAssertEqual(URLComponents(string: url)?.port, 18443, url)
            XCTAssertTrue(TellomiRegions.hostOf(url).hasSuffix(".127.0.0.1.nip.io"), url)
        }
    }

    func testAnInvalidTestRegionPortIsIgnored() {
        let plain = TellomiRegions.testRegionProfiles(environment: [testDomainKey: "tellomi.test"])
        for notAPort in ["", "0", "65536", "-1", "abc", "443x", " 443"] {
            let profiles = TellomiRegions.testRegionProfiles(environment: [testDomainKey: "tellomi.test", testPortKey: notAPort])
            XCTAssertEqual(profiles, plain, notAPort)
            XCTAssertEqual(TellomiRegions.chatPort(for: profiles[1]), 443, notAPort)
        }
        // 光有端口、没有测试区域名：包里的表原样
        XCTAssertEqual(TellomiRegions.testRegionProfiles(environment: [testPortKey: "18443"]), TellomiRegions.all)
    }

    /// 起点要等线程「站稳」再数：tokio 的工作线程是新建运行时时才起的，线程名（`libsignal-tokio-worker`）由线程自己起来后
    /// 才设上（Rust std 在 macOS 上只能在线程内 `pthread_setname_np`）。刚建完 `Net` 马上数，还没跑到设名那一步的线程
    /// 数不进去，起点偏小；机器负载高时更明显（2026-10-19 Mac 复测：起点读到 9 / 11，切完读到 14，3 次挂 2 次；这个偶发 10-17、10-18 在没有切区改动的树上也出现过）。
    /// 连续 1 秒读数不变才算站稳，最多等 10 秒，取站稳时的读数（不取最大值：前一个用例的运行时正在退出时，最大值会把起点抬高）。
    /// 判据本身（切完回到起点）不放宽。
    private func settledTokioThreadCount() -> Int {
        var last = TellomiRegionDrill.tokioThreadCount()
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, Date().timeIntervalSince(stableSince) < 1 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let count = TellomiRegionDrill.tokioThreadCount()
            if count != last {
                last = count
                stableSince = Date()
            }
        }
        return last
    }

    func testSwitchingTenTimesLeavesNoTokioThreadsBehind() throws {
        // #1056 判据 2 的单测版：每个 Net 一个 tokio 运行时；切 10 次、退役期过后，线程数回到开始时
        let profiles = TellomiRegions.testRegionProfiles(environment: [testDomainKey: "tellomi.test"])
        let (provider, _) = makeSwitchableProvider(profiles: profiles, retireDelay: 0.1)
        let before = settledTokioThreadCount()
        XCTAssertGreaterThan(before, 0, "provider 第一个 Net 的运行时要数得到，否则下面的比较是空的")

        for step in 1...10 {
            XCTAssertTrue(try provider.switchTo(step.isMultiple(of: 2) ? .global : .cn, store: nil))
        }
        XCTAssertEqual(provider.generation, 10)

        // 等到退役完、线程数回落。数的是进程里所有叫 libsignal-tokio-worker 的线程，其中有 tokio 按需开的阻塞线程
        // （spawn_blocking，和工作线程同名），空闲 10 秒才退出（tokio `thread_keep_alive` 默认值）；
        // 只等 10 秒会和它赛跑，偶尔差一两个（2026-10-17 复测报告：28 > 26）。等过它的两倍，判据本身不放宽。
        let deadline = Date().addingTimeInterval(20)
        while provider.retiredCount > 0 || TellomiRegionDrill.tokioThreadCount() > before, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(provider.retiredCount, 0)
        XCTAssertLessThanOrEqual(TellomiRegionDrill.tokioThreadCount(), before)
    }

    // MARK: - #1056 第四刀：选路器（契约第六节；用例照 Desktop 的 RegionSelector 搬）

    private typealias ProbeResult = TellomiRegionSelector.ProbeResult

    /// 探测替身：按区给定结果，记下被探了哪些区、哪些 chat 主机。
    private final class ProbeLog: Sendable {
        private let ids = AtomicValue<[TellomiRegionId]>([], lock: .init())
        private let hosts = AtomicValue<[String]>([], lock: .init())

        var probedIds: [TellomiRegionId] { ids.get() }
        var probedHosts: [String] { hosts.get() }

        func record(_ region: TellomiRegionProfile) {
            ids.update { $0.append(region.id) }
            hosts.update { $0.append(TellomiRegions.hostOf(region.chat)) }
        }
    }

    private let selectorStart = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeSelector(
        profiles: [TellomiRegionProfile],
        results: [TellomiRegionId: ProbeResult],
        current: AtomicValue<TellomiRegionId> = AtomicValue(.global, lock: .init()),
        lastSwitchAt: AtomicValue<Date?> = AtomicValue(nil, lock: .init()),
        clock: AtomicValue<Date>? = nil,
    ) -> (TellomiRegionSelector, ProbeLog) {
        let log = ProbeLog()
        let clock = clock ?? AtomicValue(selectorStart, lock: .init())
        let selector = TellomiRegionSelector(
            profiles: { profiles },
            currentRegion: { current.get() },
            lastSwitchAt: { lastSwitchAt.get() },
            probe: { region, _ in
                log.record(region)
                return results[region.id] ?? .failed("unexpected probe of \(region.id.rawValue)")
            },
            now: { clock.get() },
        )
        return (selector, log)
    }

    private var bothEnabled: [TellomiRegionProfile] { [global, TellomiRegionProfile(copying: cn, enabled: true)] }

    func testTheSelectorProbesOnlyEnabledRegions() async {
        XCTAssertEqual(cnOffTable.filter(\.enabled).map(\.id), [.global])
        let (selector, log) = makeSelector(profiles: cnOffTable, results: [.global: .ok(rtt: 0.040)])

        let decision = await selector.probe()

        XCTAssertEqual(log.probedIds, [.global])
        XCTAssertEqual(Array(decision.results.keys), [.global])
        XCTAssertEqual(decision.recommended, .global)
    }

    func testNoTellomiCnHostIsProbedWhileCnIsDisabled() async {
        // #1056 判据 4 在选路器这一层：CN 关着时，探测连 tellomi.cn 的主机名都碰不到
        let (selector, log) = makeSelector(profiles: cnOffTable, results: [.global: .failed("offline in tests")])

        let decision = await selector.probe()

        XCTAssertEqual(log.probedHosts, ["chat.tellomi.app"])
        XCTAssertEqual(decision.reason, .noAlternative)
    }

    func testTheSelectorStaysUnlessTheOtherRegionIsFasterByTheThreshold() async {
        let advantage = TellomiRegionSelector.Thresholds.defaults.latencyAdvantage
        let clock = AtomicValue(selectorStart.addingTimeInterval(60 * .minute), lock: .init())
        let (selector, _) = makeSelector(profiles: bothEnabled, results: [.global: .ok(rtt: 0.100), .cn: .ok(rtt: 0.100 - advantage)], clock: clock)

        let reason = await selector.probe().reason
        XCTAssertEqual(reason, .stay)
    }

    func testTheFasterRegionWinsAtOnceWithoutASwitchOnRecord() async {
        let (selector, _) = makeSelector(profiles: bothEnabled, results: [.global: .ok(rtt: 0.200), .cn: .ok(rtt: 0.020)])

        let cold = await selector.probe()

        XCTAssertEqual(cold.reason, .faster)
        XCTAssertEqual(cold.recommended, .cn)
    }

    func testAFasterRegionIsHeldBackForTheMinimumDwell() async {
        // 驻留从记下的上一次切区算起，不从进程启动算起
        let minDwell = TellomiRegionSelector.Thresholds.defaults.minDwell
        let current = AtomicValue<TellomiRegionId>(.global, lock: .init())
        let lastSwitchAt = AtomicValue<Date?>(selectorStart, lock: .init())
        let clock = AtomicValue(selectorStart, lock: .init())
        let (selector, _) = makeSelector(
            profiles: bothEnabled,
            results: [.global: .ok(rtt: 0.200), .cn: .ok(rtt: 0.020)],
            current: current,
            lastSwitchAt: lastSwitchAt,
            clock: clock,
        )

        clock.set(selectorStart.addingTimeInterval(minDwell - 1))
        let early = await selector.probe()
        XCTAssertEqual(early.reason, .dwell)
        XCTAssertEqual(early.recommended, .global)

        clock.set(selectorStart.addingTimeInterval(minDwell))
        let later = await selector.probe()
        XCTAssertEqual(later.reason, .faster)
        XCTAssertEqual(later.recommended, .cn)

        // 调用方照建议切了区：provider 换了生效区、记下切区时间
        current.set(.cn)
        lastSwitchAt.set(clock.get())
        let again = await selector.probe()
        XCTAssertEqual(again.current, .cn)
        XCTAssertEqual(again.reason, .stay)
    }

    func testTheSelectorFailsOverOnlyAfterConsecutiveFailures() async {
        let (selector, _) = makeSelector(profiles: bothEnabled, results: [.global: .failed("timeout"), .cn: .ok(rtt: 0.030)])

        let first = await selector.probe()
        let second = await selector.probe()
        let third = await selector.probe()

        XCTAssertEqual(first.reason, .currentFailing)
        XCTAssertEqual(second.reason, .currentFailing)
        XCTAssertEqual(third.reason, .failover)
        XCTAssertEqual(third.recommended, .cn)
    }

    func testReportedConnectionFailuresCountTowardTheFailover() async {
        let (selector, _) = makeSelector(profiles: bothEnabled, results: [.global: .failed("timeout"), .cn: .ok(rtt: 0.030)])
        XCTAssertFalse(selector.reportConnectionFailure())
        XCTAssertFalse(selector.reportConnectionFailure())
        // 探测时当前区自己的失败是第三次
        let reason = await selector.probe().reason
        XCTAssertEqual(reason, .failover)

        selector.reportConnectionSuccess()
        XCTAssertFalse(selector.reportConnectionFailure())
        XCTAssertFalse(selector.reportConnectionFailure())
        XCTAssertTrue(selector.reportConnectionFailure())
    }

    func testADisabledRegionIsNeverRecommended() async {
        // 包里的 CN 关着：就算它会探得很快（假如探了的话），也不探、不推荐；当前区失败也只能 no-alternative
        let (selector, log) = makeSelector(profiles: cnOffTable, results: [.global: .failed("timeout"), .cn: .ok(rtt: 0.001)])

        for _ in 0..<3 {
            let decision = await selector.probe()
            XCTAssertEqual(decision.recommended, .global)
            XCTAssertEqual(decision.reason, .noAlternative)
        }
        XCTAssertFalse(log.probedIds.contains(.cn))
    }

    func testTheFailureCountStartsOverAfterTheRegionChanges() async {
        let current = AtomicValue<TellomiRegionId>(.global, lock: .init())
        let (selector, _) = makeSelector(
            profiles: bothEnabled,
            results: [.global: .ok(rtt: 0.030), .cn: .failed("timeout")],
            current: current,
        )
        // global 上攒了两次失败
        XCTAssertFalse(selector.reportConnectionFailure())
        XCTAssertFalse(selector.reportConnectionFailure())

        // 切到了 CN（生效区变了），CN 失败一次：从 1 数起，不 failover
        current.set(.cn)
        let decision = await selector.probe()
        XCTAssertEqual(decision.reason, .currentFailing)
        XCTAssertEqual(decision.recommended, .cn)
    }

    func testTheChatProbeFailsOnAnUnresolvableHost() async {
        // 真的探测器：.invalid 永远解析不到，不能被当成健康
        let unresolvable = TellomiRegions.testRegionProfiles(environment: [testDomainKey: "tellomi.invalid"])[1]
        XCTAssertEqual(TellomiRegions.hostOf(unresolvable.chat), "chat.tellomi.invalid")

        // 超时给足，用失败原因证明「解析不了（.waiting）立刻算失败、不等超时」：不看墙钟。
        // 本机实测 0.1 s 量级，但 CI 的模拟器上 DNS / TLS 栈冷启动一次就要十几秒（运行 102：11.6 s 才返回 NoSuchRecord），
        // 按秒数断言在忙的机器上必然偶发红。
        let result = await TellomiRegionSelector.chatEndpointProbe(unresolvable, 60)

        guard case .failed(let reason) = result else {
            return XCTFail("probe of \(unresolvable.chat) should fail, got \(result)")
        }
        XCTAssertFalse(reason.hasPrefix("timeout"), "解析失败应该当场报出来，不能等到超时：\(reason)")
    }

    // MARK: - 门禁：测试区和演练只在测试构建里

    /// 测试专用代码的标记。App 源码里出现的每一处都要在 `#if TESTABLE_BUILD` 里（App Store Release 没有这个宏）。
    private static let testOnlyMarkers = ["TELLOMI_TEST_REGION_DOMAIN", "TELLOMI_TEST_REGION_PORT", "TELLOMI_REGION_DRILL", "testRegionProfiles(", "TellomiRegionDrill"]

    private func testOnlyMarkerHits() throws -> (guarded: [String], unguarded: [String]) {
        var guarded = [String]()
        var unguarded = [String]()
        for file in try appSourceFiles() {
            let isGuarded = Self.linesInsideTestableBuild(file.lines)
            for (index, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                    continue
                }
                if Self.testOnlyMarkers.contains(where: { line.contains($0) }) {
                    let hit = "\(file.relativePath):\(index + 1): \(trimmed)"
                    if isGuarded[index] {
                        guarded.append(hit)
                    } else {
                        unguarded.append(hit)
                    }
                }
            }
        }
        return (guarded, unguarded)
    }

    /// 每一行是否在 `#if TESTABLE_BUILD` 的真分支里（套在别的 `#if` 里也算；它的 `#else` / `#elseif` 那一支不算）。
    private static func linesInsideTestableBuild(_ lines: [String]) -> [Bool] {
        var branches = [Bool]() // 每层 #if：当前这一支是不是 TESTABLE_BUILD 的真分支
        return lines.map { line in
            let directive = line.trimmingCharacters(in: .whitespaces).components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
            if directive.hasPrefix("#if ") {
                branches.append(directive == "#if TESTABLE_BUILD")
            } else if directive.hasPrefix("#elseif "), !branches.isEmpty {
                branches[branches.count - 1] = false
            } else if directive == "#else", !branches.isEmpty {
                branches[branches.count - 1] = false
            } else if directive == "#endif" {
                let inside = branches.contains(true)
                _ = branches.popLast()
                return inside
            }
            return branches.contains(true)
        }
    }

    func testTestOnlyCodeStaysBehindTestableBuild() throws {
        let hits = try testOnlyMarkerHits()
        XCTAssertEqual(hits.unguarded, [], "测试区和切区演练只许出现在 #if TESTABLE_BUILD 里")
        // 正对照：每个标记都在 #if TESTABLE_BUILD 里找到过，证明扫描和分支判断确实在工作
        for marker in Self.testOnlyMarkers {
            XCTAssertTrue(hits.guarded.contains { $0.contains(marker) }, marker)
        }
    }

    func testTheTestableBuildBranchTracking() {
        let lines = [
            "a",
            "#if TESTABLE_BUILD",
            "b",
            "#if DEBUG",
            "c",
            "#endif",
            "#else",
            "d",
            "#endif",
            "#if DEBUG",
            "#if TESTABLE_BUILD // 说明",
            "e",
            "#endif",
            "f",
            "#endif",
        ]
        let inside = Self.linesInsideTestableBuild(lines)
        let insideLines = zip(lines, inside).filter { $0.1 && $0.0.count == 1 }.map(\.0)
        XCTAssertEqual(insideLines, ["b", "c", "e"])
    }

    // MARK: -

    /// 各个 App 目标的 Swift 源码（不含测试）：相对仓库根的路径和按行拆开的内容。
    private func appSourceFiles() throws -> [(relativePath: String, lines: [String])] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Util
            .deletingLastPathComponent() // tests
            .deletingLastPathComponent() // SignalServiceKit
            .deletingLastPathComponent() // 仓库根
            .resolvingSymlinksInPath()
        var files = [(relativePath: String, lines: [String])]()
        for target in ["Signal", "SignalServiceKit", "SignalUI", "SignalNSE", "SignalShareExtension"] {
            guard let enumerator = FileManager.default.enumerator(at: root.appendingPathComponent(target), includingPropertiesForKeys: nil) else {
                XCTFail("can't read \(target)")
                continue
            }
            for case let url as URL in enumerator {
                if ["test", "tests", "TestUtils"].contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift" else {
                    continue
                }
                let path = url.resolvingSymlinksInPath().path
                let text = try String(contentsOf: url, encoding: .utf8)
                files.append((String(path.dropFirst(root.path.count + 1)), text.components(separatedBy: "\n")))
            }
        }
        return files
    }
}

private extension TellomiRegionProfile {
    /// 测试里造坏表用：只改给出的字段。
    init(copying other: TellomiRegionProfile, enabled: Bool? = nil, uptimeHost: String? = nil) {
        self.init(
            id: other.id,
            enabled: enabled ?? other.enabled,
            chat: other.chat,
            grpcChatHost: other.grpcChatHost,
            storage: other.storage,
            cdn0: other.cdn0,
            cdn2: other.cdn2,
            cdn3: other.cdn3,
            updates: other.updates,
            contentProxyHost: other.contentProxyHost,
            contentProxyPort: other.contentProxyPort,
            captchaRegistration: other.captchaRegistration,
            captchaChallenge: other.captchaChallenge,
            sfu: other.sfu,
            uptimeHost: uptimeHost ?? other.uptimeHost,
            debugLog: other.debugLog,
            feed: other.feed,
        )
    }
}

// MARK: - 远程配置驱动的切区（REGION_PROFILE 第六节之二）

/// 和 Android `TellomiRegionAutoSwitchTest`、Desktop `tellomiRegionTarget_test.node.ts` 逐条一致。
final class TellomiRegionAutoSwitchTest: XCTestCase {
    private let global = TellomiRegions.global
    private let cn = TellomiRegions.cn

    private final class World {
        var stored: TellomiRegionId
        var target: String?
        var failures: Int
        var up: [TellomiRegionId: Bool]
        var probed = [TellomiRegionId]()
        var probedHosts = [String]()
        var switched = [TellomiRegionId]()

        init(stored: TellomiRegionId = .global, target: String?, failures: Int = 0, up: [TellomiRegionId: Bool] = [:]) {
            self.stored = stored
            self.target = target
            self.failures = failures
            self.up = up
        }
    }

    private func auto(_ w: World, table: [TellomiRegionProfile] = TellomiRegions.all) -> TellomiRegionAutoSwitch {
        TellomiRegionAutoSwitch(
            profiles: { table },
            currentId: { w.stored },
            targetValue: { w.target },
            loadFailures: { w.failures },
            storeFailures: { w.failures = $0 },
            probe: { region in
                w.probed.append(region.id)
                w.probedHosts.append(TellomiRegions.hostOf(region.chat))
                return w.up[region.id] ?? false
            },
            switchTo: { id in
                w.switched.append(id)
                w.stored = id
            },
        )
    }

    func testParsesTheKey() {
        XCTAssertEqual(TellomiRegionAutoSwitch.parseTarget(nil), .init(id: .global, explicit: false))
        XCTAssertEqual(TellomiRegionAutoSwitch.parseTarget(""), .init(id: .global, explicit: false))
        XCTAssertEqual(TellomiRegionAutoSwitch.parseTarget("CN"), .init(id: .global, explicit: false))
        XCTAssertEqual(TellomiRegionAutoSwitch.parseTarget("cn"), .init(id: .cn, explicit: true))
        XCTAssertEqual(TellomiRegionAutoSwitch.parseTarget("global"), .init(id: .global, explicit: true))
    }

    func testOffWithoutTheKeyProbesNothing() async {
        for target in [nil, "", "nonsense"] as [String?] {
            let w = World(target: target)
            let reason = await auto(w).evaluate()
            XCTAssertEqual(reason, .off)
            XCTAssertEqual(w.probed, [])
            XCTAssertEqual(w.switched, [])
        }
        let explicitGlobal = World(target: "global", up: [.global: true])
        let reason = await auto(explicitGlobal).evaluate()
        XCTAssertEqual(reason, .stay)
        XCTAssertFalse(explicitGlobal.probedHosts.contains { $0.hasSuffix("tellomi.cn") })
    }

    func testMovesOnlyAfterASuccessfulProbe() async {
        let down = World(target: "cn", up: [.cn: false])
        let downReason = await auto(down).evaluate()
        XCTAssertEqual(downReason, .targetUnreachable)
        XCTAssertEqual(down.switched, [])
        XCTAssertEqual(down.probed, [.cn])

        let up = World(target: "cn", up: [.cn: true])
        let upReason = await auto(up).evaluate()
        XCTAssertEqual(upReason, .switch)
        XCTAssertEqual(up.stored, .cn)
    }

    func testRevertingTheKeyMovesBack() async {
        for target in ["global", "", nil] as [String?] {
            let w = World(stored: .cn, target: target, up: [.global: true])
            let reason = await auto(w).evaluate()
            XCTAssertEqual(reason, .switch)
            XCTAssertEqual(w.stored, .global)
            XCTAssertEqual(w.probed, [.global])
        }
    }

    func testFailsOverAfterRepeatedFailuresAndReturns() async {
        let w = World(stored: .cn, target: "cn", up: [.cn: false, .global: true])
        let a = auto(w)
        for i in 1..<TellomiRegionAutoSwitch.defaultFailureThreshold {
            let reason = await a.evaluate()
            XCTAssertEqual(reason, .currentFailing)
            XCTAssertEqual(w.failures, i)
        }
        let failover = await a.evaluate()
        XCTAssertEqual(failover, .failover)
        XCTAssertEqual(w.stored, .global)
        XCTAssertEqual(w.failures, 0)

        w.up[.cn] = true
        let back = await a.evaluate()
        XCTAssertEqual(back, .switch)
        XCTAssertEqual(w.stored, .cn)
    }

    func testNoAlternativeWhenBothAreDown() async {
        let w = World(stored: .cn, target: "cn", failures: 2, up: [.cn: false, .global: false])
        let reason = await auto(w).evaluate()
        XCTAssertEqual(reason, .noAlternative)
        XCTAssertEqual(w.stored, .cn)
    }

    func testADisabledCnIsNeverATarget() async {
        let w = World(stored: .cn, target: "cn", up: [.global: true])
        let reason = await auto(w, table: [global, TellomiRegionProfile(copying: cn, enabled: false)]).evaluate()
        XCTAssertEqual(reason, .off)
        XCTAssertFalse(w.probed.contains(.cn))
    }

    func testServerSuppliedHostsMustBeUnderTheCurrentRegionRoot() {
        XCTAssertEqual(TellomiRegions.tellomiRoot(of: "CHAT.tellomi.cn."), "tellomi.cn")
        XCTAssertNil(TellomiRegions.tellomiRoot(of: "nottellomi.cn"))
        XCTAssertTrue(TellomiRegions.isHost("contentproxy.tellomi.cn", inRegion: cn))
        XCTAssertFalse(TellomiRegions.isHost("contentproxy.tellomi.app", inRegion: cn))
        XCTAssertTrue(TellomiRegions.isHost("contentproxy.tellomi.app", inRegion: global))
        XCTAssertFalse(TellomiRegions.isHost("proxy.example.com", inRegion: global))
    }
}
