//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// card-visual §3.11 验收（ADR-0063 §8.1 第 6 行）：表 3.7 的每一行，「字段全」和「只有必填」各一张，浅色、暗色各一套。
///
/// 表驱动：一行一条数据（手写、不联网；URL 取 `rust/links` 注册表认得的真实形状），每条数据按会话页同一条渲染路径
/// （`CVLoader.buildStandaloneRenderItem` + `CVCellView`）排成真实的消息 cell，断言它落在文档那一行写的样子——
/// 级别、三行骨架的文字与顺序、图的版式、染不染色、染色卡的标题对比度——并在 `TELLOMI_SHOTS=1` 时存 PNG、
/// 拼成每个主题一张的联系表（行 = kind，两列 = 字段全 / 只有必填）。
///
/// 出图：`TEST_RUNNER_TELLOMI_SHOTS=1 TEST_RUNNER_TELLOMI_SHOTS_DIR=<目录> xcodebuild test … -only-testing:SignalTests/TellomiLinkCardAcceptanceTests`。
/// 要单独跑这个类：预览图的缓存只有 2 项、键是附件 id，而每条用例都是一份新的内存库（id 从头数起），和别的用例一起跑会拿到它们的图。
final class TellomiLinkCardAcceptanceTests: XCTestCase {

    private var oldContext: (any AppContext)!
    private var report = ""

    @MainActor
    override func setUp() {
        super.setUp()
        // 76 格真排版 + 截图，本机单独跑要 ~100 秒；带 `-test-timeouts-enabled YES -default-test-execution-time-allowance 60` 的整套跑会被判超时。
        executionTimeAllowance = 600
        let setupExpectation = expectation(description: "mock ssk environment setup completed")
        self.oldContext = CurrentAppContext()
        Task {
            let appReadiness = AppReadinessImpl()
            await MockSSKEnvironment.activate(
                appReadiness: appReadiness,
                testDependencies: AppSetup.TestDependencies(
                    groupV2Updates: MockGroupV2Updates(),
                    groupsV2: MockGroupsV2(),
                    messageSender: FakeMessageSender(),
                    networkManager: OWSFakeNetworkManager(appReadiness: appReadiness, netProvider: nil),
                    paymentsCurrencies: MockPaymentsCurrencies(),
                    paymentsHelper: MockPaymentsHelper(),
                    pendingReceiptRecorder: NoopPendingReceiptRecorder(),
                    reachabilityManager: MockSSKReachabilityManager(),
                    remoteConfigManager: StubbableRemoteConfigManager(),
                    signalService: OWSSignalServiceMock(),
                    storageServiceManager: FakeStorageServiceManager(),
                    syncManager: OWSMockSyncManager(),
                    systemStoryManager: SystemStoryManagerMock(),
                    versionedProfiles: MockVersionedProfiles(),
                    webSocketFactory: WebSocketFactoryMock(),
                ),
            )
            setupExpectation.fulfill()
        }
        waitForExpectations(timeout: 30)

        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    @MainActor
    override func tearDown() {
        MockSSKEnvironment.deactivate(oldContext: self.oldContext)
        super.tearDown()
    }

    private func read<T>(block: (DBReadTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.read(block: block)
    }

    private func write<T>(block: (DBWriteTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.write(block: block)
    }

    private var shooting: Bool { ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" }

    private let width: CGFloat = 402

    private func shotsDirectory(_ theme: String) throws -> URL {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: root).appendingPathComponent("acceptance").appendingPathComponent(theme)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 表 3.7

    /// 图的版式，按 cell 里的视图判。
    private enum ImageLayout: String {
        /// 没有图：文字 + 右侧通用链接图标（card-visual §3.2「无图卡」）。
        case none
        /// 右上角 54 pt 方形图标（图标卡）。
        case icon
        /// 图在上、占满卡宽（大图卡）。
        case large
        /// 第一方卡左侧 56 pt 的头像 / 封面 / 图标（§5.2）。
        case avatar
    }

    private enum Variant: String, CaseIterable {
        case full = "字段全"
        case minimal = "只有必填"

        var fileName: String {
            switch self {
            case .full: "full"
            case .minimal: "min"
            }
        }
    }

    /// 发送端带来的预览图：用渐变 + 文字画出来，纯色图标和染色的底一个颜色，截图里看不见它。
    private struct Picture {
        let size: CGSize
        let hue: CGFloat
        let label: String
    }

    private struct Rich {
        let kind: String
        let provider: String
        var level: UInt32 = 2
        var attrs: [(String, String)] = []
    }

    /// 一张卡：输入（消息、预览、rich、图）和文档那一行写的样子。
    private struct Card {
        var url: String
        /// nil = 消息就是这条链接。
        var body: String?
        var hasPreview = true
        var previewTitle: String?
        var previewDescription: String?
        var rich: Rich?
        var picture: Picture?

        /// rust/links 应该给的级别。
        var level: String
        /// 标题位（第三方卡的标题 / 纯链接的域名 / 第一方卡的名字）。
        var title: String
        /// 副行；没有这一段就不占这一行。
        var subLine: String?
        /// 域名行；第一方卡没有，改成底部的动作按钮。
        var domain: String?
        var button: String?
        /// 官网卡标题后面的「官方」徽标。
        var officialBadge = false
        var layout: ImageLayout
        var tinted = false
        /// 卡片上不该出现的文字：发送端写的描述 / 标题（文档：任何级别都不显示；品牌壳和第一方卡不用发送端的字）。
        var absent: [String] = []

        /// 卡上的文字，从上到下。「官方」徽标是画成图、作为附件塞进标题文字里的（标题换行、测量都还是一段文字），所以标题后面多一个附件字符。
        var texts: [String] {
            [officialBadge ? title + " \u{FFFC}" : title, subLine, domain, button].compactMap { $0 }
        }
    }

    private struct Row {
        /// 表 3.7 的行。
        let id: String
        /// 联系表左边写的名字。
        let name: String
        let full: Card
        let minimal: Card
        /// 本机认识这个用户（用户名已存、资料已放行，§5.2「本地认识 → 真头像」）。
        var knownUsername: String?

        func card(_ variant: Variant) -> Card {
            variant == .full ? full : minimal
        }
    }

    private static let bilibili = "https://www.bilibili.com/video/BV1YDhJ6ZEL6"
    private static let videoTitle = "【演示】给朋友发一条视频链接会长什么样"
    private static let callUrl = "https://tell.cc/call#key=bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz"

    /// 合法的群邀请链接（tell.cc/g#…），主密钥是同一个字节重复 32 次。
    private static func groupInviteUrl(masterKeyByte: UInt8) -> String {
        let masterKey = try! GroupMasterKey(contents: Data(repeating: masterKeyByte, count: 32))
        return try! GroupInviteLink(masterKey: masterKey, inviteLinkPassword: Data(repeating: masterKeyByte, count: 16)).url().absoluteString
    }

    /// 表 3.7 的行，顺序就是文档里的顺序；「字段全」= 把可选字段都填上，「只有必填」= 只带 `kinds.toml` 里的必填字段（ADR-0063 §4.6）。
    private static let rows: [Row] = [
        plainLinkRow,
        genericRow,
        brandWithIconRow,
        brandWithoutIconRow,
        paymentRow,
        videoRow,
        channelRow,
        trackRow,
        albumRow,
        playlistRow,
        placeRow,
        appRow,
        repoRow,
        userRow,
        groupRow,
        callRow,
        stickerRow,
        officialRow,
        unknownKindRow,
    ]

    /// §3.7 的行 id，测试里单独写一份：表里少了谁，这里对不上。
    private static let specRowIds = [
        "plain_link",
        "generic",
        "brand",
        "brand-no-icon",
        "brand-payment",
        "video",
        "channel",
        "music.track",
        "music.album",
        "music.playlist",
        "place",
        "app",
        "repo",
        "tellomi.user",
        "tellomi.group",
        "tellomi.call",
        "tellomi.sticker",
        "tellomi.official",
        "unknown-kind",
    ]

    // 纯链接：消息就是这条链接、没有预览；接收端本地画无图卡（域名当标题 + 链接图标）。没有可选字段，两张一样。
    private static let plainLinkRow: Row = {
        let card = Card(url: bilibili, hasPreview: false, level: "plain_link", title: "bilibili.com", layout: .none)
        return Row(id: "plain_link", name: "纯链接", full: card, minimal: card)
    }()

    private static let genericRow = Row(
        id: "generic",
        name: "generic",
        full: Card(
            url: "https://www.wikipedia.org/",
            previewTitle: "Wikipedia",
            previewDescription: "Wikipedia is a free online encyclopedia, created and edited by volunteers.",
            picture: Picture(size: CGSize(width: 1200, height: 630), hue: 0.58, label: "generic"),
            level: "generic",
            title: "Wikipedia",
            domain: "wikipedia.org",
            layout: .large,
            tinted: true,
            absent: ["free online encyclopedia"],
        ),
        minimal: Card(url: "https://www.wikipedia.org/", previewTitle: "Wikipedia", level: "generic", title: "Wikipedia", domain: "wikipedia.org", layout: .none),
    )

    // 品牌壳：平台名 + 类型文字（kind 由 URL 的路径判，认不出对象就是「网页」）+ 域名；不用发送端的标题和图。
    private static let brandWithIconRow = Row(
        id: "brand",
        name: "品牌壳·有图标",
        full: Card(
            url: "https://item.taobao.com/item.htm?id=674169489573",
            previewTitle: "登录",
            rich: Rich(kind: "product", provider: "taobao", level: 1),
            level: "brand",
            title: "Taobao",
            subLine: "Product",
            domain: "taobao.com",
            layout: .icon,
            tinted: true,
            absent: ["登录"],
        ),
        minimal: Card(
            url: "https://www.taobao.com/",
            previewTitle: "淘宝网",
            rich: Rich(kind: "web", provider: "taobao", level: 1),
            level: "brand",
            title: "Taobao",
            subLine: "Web page",
            domain: "taobao.com",
            layout: .icon,
            tinted: true,
            absent: ["淘宝网"],
        ),
    )

    private static let brandWithoutIconRow = Row(
        id: "brand-no-icon",
        name: "品牌壳·无图标",
        full: Card(
            url: "https://g.meituan.com/app/gfe-app-page-tuan/detail-mt.html?dealId=123456789",
            previewTitle: "双人套餐",
            rich: Rich(kind: "deal", provider: "meituan", level: 1),
            level: "brand",
            title: "Meituan",
            subLine: "Deal",
            domain: "meituan.com",
            layout: .none,
            absent: ["双人套餐"],
        ),
        minimal: Card(
            url: "https://www.meituan.com/",
            previewTitle: "美团",
            rich: Rich(kind: "web", provider: "meituan", level: 1),
            level: "brand",
            title: "Meituan",
            subLine: "Web page",
            domain: "meituan.com",
            layout: .none,
            absent: ["美团"],
        ),
    )

    // 支付金融（ADR-0063 L10）：品牌壳、不染色、没有图标；没有可选字段，两张一样。
    private static let paymentRow: Row = {
        let card = Card(
            url: "https://render.alipay.com/p/f/fd-j5rqp49m/index.html",
            previewTitle: "支付宝",
            rich: Rich(kind: "web", provider: "alipay", level: 1),
            level: "brand",
            title: "Alipay",
            subLine: "Web page",
            domain: "alipay.com",
            layout: .none,
            absent: ["支付宝"],
        )
        return Row(id: "brand-payment", name: "品牌壳·支付", full: card, minimal: card)
    }()

    private static let videoRow = Row(
        id: "video",
        name: "video",
        full: Card(
            url: bilibili,
            previewTitle: videoTitle,
            previewDescription: "发送端写的描述——不该出现在卡片上",
            rich: Rich(kind: "video", provider: "bilibili", attrs: [("author", "演示UP主"), ("duration_ms", "257000"), ("published_at", "2025-03-14T10:00:00Z")]),
            picture: Picture(size: CGSize(width: 1280, height: 720), hue: 0.55, label: "video"),
            level: "structured",
            title: videoTitle,
            subLine: "演示UP主 · 4:17",
            domain: "bilibili.com ⋅ Mar 14, 2025",
            layout: .large,
            tinted: true,
            absent: ["发送端写的描述"],
        ),
        // 必填 = 标题 + 图
        minimal: Card(
            url: bilibili,
            previewTitle: videoTitle,
            rich: Rich(kind: "video", provider: "bilibili"),
            picture: Picture(size: CGSize(width: 1280, height: 720), hue: 0.55, label: "video"),
            level: "structured",
            title: videoTitle,
            domain: "bilibili.com",
            layout: .large,
            tinted: true,
        ),
    )

    private static let channelRow = Row(
        id: "channel",
        name: "channel",
        full: Card(
            url: "https://www.youtube.com/@tellomi",
            previewTitle: "Tellomi Studio",
            rich: Rich(kind: "channel", provider: "youtube", attrs: [("author", "Tellomi Inc.")]),
            picture: Picture(size: CGSize(width: 400, height: 400), hue: 0.08, label: "channel"),
            level: "structured",
            title: "Tellomi Studio",
            subLine: "Tellomi Inc.",
            domain: "youtube.com",
            layout: .icon,
            tinted: true,
        ),
        minimal: Card(
            url: "https://www.youtube.com/@tellomi",
            previewTitle: "Tellomi Studio",
            rich: Rich(kind: "channel", provider: "youtube"),
            level: "structured",
            title: "Tellomi Studio",
            domain: "youtube.com",
            layout: .none,
        ),
    )

    private static let trackRow = Row(
        id: "music.track",
        name: "music.track",
        full: Card(
            url: "https://open.spotify.com/track/7qiZfU4dY1lWllzX7mPBI3",
            previewTitle: "Blue Hour",
            rich: Rich(kind: "music.track", provider: "spotify", attrs: [("artist", "Nova Lin"), ("album", "Night Drive"), ("duration_ms", "225000")]),
            picture: Picture(size: CGSize(width: 300, height: 300), hue: 0.72, label: "track"),
            level: "structured",
            title: "Blue Hour",
            subLine: "Nova Lin · Night Drive · 3:45",
            domain: "spotify.com",
            layout: .icon,
            tinted: true,
        ),
        minimal: Card(
            url: "https://open.spotify.com/track/7qiZfU4dY1lWllzX7mPBI3",
            previewTitle: "Blue Hour",
            rich: Rich(kind: "music.track", provider: "spotify"),
            level: "structured",
            title: "Blue Hour",
            domain: "spotify.com",
            layout: .none,
        ),
    )

    private static let albumRow = Row(
        id: "music.album",
        name: "music.album",
        full: Card(
            url: "https://open.spotify.com/album/1DFixLWuPkv3KT3TnV35m3",
            previewTitle: "Night Drive",
            rich: Rich(kind: "music.album", provider: "spotify", attrs: [("artist", "Nova Lin"), ("track_count", "12")]),
            picture: Picture(size: CGSize(width: 640, height: 640), hue: 0.83, label: "album"),
            level: "structured",
            title: "Night Drive",
            subLine: "Nova Lin · 12 tracks",
            domain: "spotify.com",
            layout: .large,
            tinted: true,
        ),
        minimal: Card(
            url: "https://open.spotify.com/album/1DFixLWuPkv3KT3TnV35m3",
            previewTitle: "Night Drive",
            rich: Rich(kind: "music.album", provider: "spotify"),
            level: "structured",
            title: "Night Drive",
            domain: "spotify.com",
            layout: .none,
        ),
    )

    private static let playlistRow = Row(
        id: "music.playlist",
        name: "music.playlist",
        full: Card(
            url: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
            previewTitle: "Focus Mix",
            rich: Rich(kind: "music.playlist", provider: "spotify", attrs: [("author", "Tellomi Music"), ("track_count", "24")]),
            picture: Picture(size: CGSize(width: 300, height: 300), hue: 0.33, label: "playlist"),
            level: "structured",
            title: "Focus Mix",
            subLine: "Tellomi Music · 24 tracks",
            domain: "spotify.com",
            layout: .icon,
            tinted: true,
        ),
        minimal: Card(
            url: "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
            previewTitle: "Focus Mix",
            rich: Rich(kind: "music.playlist", provider: "spotify"),
            level: "structured",
            title: "Focus Mix",
            domain: "spotify.com",
            layout: .none,
        ),
    )

    // 位置：坐标不显示成文字，P1 不画地图缩略图（ADR-0063 §8.3）；必填 = 坐标（或名字）。
    private static let placeRow = Row(
        id: "place",
        name: "place",
        full: Card(
            url: "https://uri.amap.com/marker?position=116.47,39.99&name=Lakeside%20Coffee",
            previewTitle: "高德地图",
            rich: Rich(kind: "place", provider: "amap", attrs: [("lat", "39.99"), ("lng", "116.47"), ("coord_sys", "gcj02"), ("name", "Lakeside Coffee"), ("address", "88 West Lake Rd")]),
            level: "structured",
            title: "Lakeside Coffee",
            subLine: "88 West Lake Rd",
            domain: "amap.com",
            layout: .none,
        ),
        minimal: Card(
            url: "https://uri.amap.com/marker?position=116.47,39.99",
            previewTitle: "高德地图",
            rich: Rich(kind: "place", provider: "amap", attrs: [("lat", "39.99"), ("lng", "116.47"), ("coord_sys", "gcj02")]),
            level: "structured",
            title: "高德地图",
            domain: "amap.com",
            layout: .none,
        ),
    )

    private static let appRow = Row(
        id: "app",
        name: "app",
        full: Card(
            url: "https://apps.apple.com/us/app/tellomi/id1234567890",
            previewTitle: "Tellomi",
            rich: Rich(kind: "app", provider: "app-store", attrs: [("developer", "Tellomi Inc."), ("platform", "ios")]),
            picture: Picture(size: CGSize(width: 512, height: 512), hue: 0.6, label: "app"),
            level: "structured",
            title: "Tellomi",
            subLine: "Tellomi Inc. · iOS",
            domain: "apple.com",
            layout: .icon,
            tinted: true,
        ),
        // 必填 = 标题 + 图
        minimal: Card(
            url: "https://apps.apple.com/us/app/tellomi/id1234567890",
            previewTitle: "Tellomi",
            rich: Rich(kind: "app", provider: "app-store"),
            picture: Picture(size: CGSize(width: 512, height: 512), hue: 0.6, label: "app"),
            level: "structured",
            title: "Tellomi",
            domain: "apple.com",
            layout: .icon,
            tinted: true,
        ),
    )

    private static let repoRow = Row(
        id: "repo",
        name: "repo",
        full: Card(
            url: "https://github.com/tellomi/signal-ios",
            previewTitle: "tellomi/signal-ios: Tellomi for iOS",
            rich: Rich(kind: "repo", provider: "github", attrs: [("owner", "tellomi")]),
            picture: Picture(size: CGSize(width: 1280, height: 640), hue: 0.97, label: "repo"),
            level: "structured",
            title: "tellomi/signal-ios: Tellomi for iOS",
            subLine: "tellomi",
            domain: "github.com",
            layout: .large,
            tinted: true,
        ),
        minimal: Card(
            url: "https://github.com/tellomi/signal-ios",
            previewTitle: "tellomi/signal-ios: Tellomi for iOS",
            rich: Rich(kind: "repo", provider: "github"),
            level: "structured",
            title: "tellomi/signal-ios: Tellomi for iOS",
            domain: "github.com",
            layout: .none,
        ),
    )

    // 第一方卡：不画域名行，底部一个动作按钮；不染色（Tellomi 中性样式）。
    private static let userRow = Row(
        id: "tellomi.user",
        name: "tellomi.user",
        // 本地认识：名字取本地联系人的显示名（这个联系人只有用户名，显示的就是用户名），头像取本地库的
        full: Card(
            url: "https://tell.cc/hk881qb",
            previewTitle: "Tellomi",
            level: "first_party",
            title: "hk881qb",
            subLine: "Tellomi user",
            button: "Message",
            layout: .avatar,
        ),
        // 不认识：名字从 URL 算成「@nickname」，默认头像
        minimal: Card(
            url: "https://tell.cc/nobody",
            previewTitle: "Tellomi",
            level: "first_party",
            title: "@nobody",
            subLine: "Tellomi user",
            button: "Message",
            layout: .avatar,
        ),
        knownUsername: "hk881qb",
    )

    private static let groupRow = Row(
        id: "tellomi.group",
        name: "tellomi.group",
        full: Card(
            url: groupInviteUrl(masterKeyByte: 1),
            previewTitle: "周末爬山群",
            rich: Rich(kind: "tellomi.group", provider: "tellomi", level: 1, attrs: [("member_count", "12")]),
            picture: Picture(size: CGSize(width: 512, height: 512), hue: 0.55, label: "group"),
            level: "first_party",
            title: "周末爬山群",
            subLine: "12 members",
            button: "Join Group",
            layout: .avatar,
        ),
        // 必填 = 名字（取自预览标题）
        minimal: Card(
            url: groupInviteUrl(masterKeyByte: 3),
            previewTitle: "周末爬山群",
            level: "first_party",
            title: "周末爬山群",
            button: "Join Group",
            layout: .avatar,
        ),
    )

    private static let callRow = Row(
        id: "tellomi.call",
        name: "tellomi.call",
        full: Card(
            url: callUrl,
            previewTitle: "周五例会",
            rich: Rich(kind: "tellomi.call", provider: "tellomi", level: 1),
            level: "first_party",
            title: "周五例会",
            button: "Join Call",
            layout: .avatar,
        ),
        minimal: Card(url: callUrl, level: "first_party", title: "Tellomi call", button: "Join Call", layout: .avatar),
    )

    private static let stickerRow = Row(
        id: "tellomi.sticker",
        name: "tellomi.sticker",
        full: Card(
            url: "https://tell.cc/s#pack_id=00112233445566778899aabbccddeeff&pack_key=\(String(repeating: "11", count: 32))",
            previewTitle: "Bandit",
            rich: Rich(kind: "tellomi.sticker", provider: "tellomi", level: 1, attrs: [("sticker_count", "24")]),
            picture: Picture(size: CGSize(width: 512, height: 512), hue: 0.1, label: "sticker"),
            level: "first_party",
            title: "Bandit",
            subLine: "24 stickers",
            button: "Add",
            layout: .avatar,
        ),
        // 必填 = 名字
        minimal: Card(
            url: "https://tell.cc/s#pack_id=ffeeddccbbaa99887766554433221100&pack_key=\(String(repeating: "22", count: 32))",
            previewTitle: "Bandit",
            level: "first_party",
            title: "Bandit",
            button: "Add",
            layout: .avatar,
        ),
    )

    // 官网：固定文字「Tellomi 官网」+ 路径 + 官方徽标 + 「打开」；文字全由 URL 算出来。首页没有路径，副标题写根路径「/」。
    private static let officialRow = Row(
        id: "tellomi.official",
        name: "tellomi.official",
        full: Card(url: "https://tellomi.app/download", previewTitle: "Tellomi", level: "first_party", title: "Tellomi website", subLine: "/download", button: "Open", officialBadge: true, layout: .avatar),
        minimal: Card(url: "https://tellomi.app/", previewTitle: "Tellomi", level: "first_party", title: "Tellomi website", subLine: "/", button: "Open", officialBadge: true, layout: .avatar),
    )

    // 不认识的 kind（新注册表、旧客户端）：按 generic 显示 snapshot，永远不因为不认识而失败（ADR-0063 §4.5）。
    private static let unknownKindRow = Row(
        id: "unknown-kind",
        name: "不认识的 kind",
        full: Card(
            url: bilibili,
            previewTitle: videoTitle,
            rich: Rich(kind: "video.short", provider: "bilibili", attrs: [("author", "演示UP主")]),
            picture: Picture(size: CGSize(width: 1280, height: 720), hue: 0.4, label: "?"),
            level: "generic",
            title: videoTitle,
            domain: "bilibili.com",
            layout: .large,
            tinted: true,
            absent: ["演示UP主"],
        ),
        minimal: Card(
            url: bilibili,
            previewTitle: videoTitle,
            rich: Rich(kind: "video.short", provider: "bilibili"),
            level: "generic",
            title: videoTitle,
            domain: "bilibili.com",
            layout: .none,
        ),
    )

    // MARK: - 用例

    /// 表里有且只有文档 §3.7 的 19 行，每行两种填法。
    func testTheTableHasExactlyTheRowsOfTheSpec() {
        XCTAssertEqual(Self.rows.map(\.id), Self.specRowIds)
        XCTAssertEqual(Set(Self.rows.map(\.id)).count, Self.rows.count, "行 id 不重复")
        XCTAssertEqual(Self.rows.count, 19)
    }

    /// 每一行、每种填法、浅色与暗色：真排一次、按文档那一行断言、存图、拼联系表。
    @MainActor
    func testEveryRowRendersAsTheSpecSaysInBothVariantsAndBothThemes() async throws {
        let initialDark = Theme.isDarkThemeEnabled
        defer { Theme.setIsDarkThemeEnabledForTests(initialDark) }

        let thread = write { tx -> TSContactThread in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }

        // 主题 → 行 → 填法 → 图
        var shots = [Bool: [String: [Variant: UIImage]]]()
        for row in Self.rows {
            if let username = row.knownUsername {
                let aci = Aci.randomForTesting()
                write { tx in
                    DependenciesBridge.shared.usernameLookupManager.saveUsername("\(username).01", forAci: aci, transaction: tx)
                    var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                    SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
                }
            }
            for variant in Variant.allCases {
                let card = row.card(variant)
                let message = try await insert(card, thread: thread)
                for dark in [false, true] {
                    Theme.setIsDarkThemeEnabledForTests(dark)
                    let hosted = try await host(message: message, thread: thread, dark: dark)
                    let label = "\(row.id) · \(variant.rawValue) · \(dark ? "暗色" : "浅色")"
                    check(card, hosted, label: label, dark: dark)
                    if shooting {
                        let image = render(hosted)
                        shots[dark, default: [:]][row.id, default: [:]][variant] = image
                        let number = String(format: "%02d", (Self.rows.firstIndex { $0.id == row.id } ?? 0) + 1)
                        try save(image, name: "\(number)-\(row.id)-\(variant.fileName).png", theme: dark ? "dark" : "light")
                    }
                    hosted.tearDown()
                }
            }
        }
        Theme.setIsDarkThemeEnabledForTests(initialDark)

        if shooting {
            for dark in [false, true] {
                let sheet = contactSheet(dark: dark, shots: shots[dark] ?? [:])
                try save(sheet, name: "contact-sheet-\(dark ? "dark" : "light").png", theme: dark ? "dark" : "light")
            }
            let url = try shotsDirectory("light").deletingLastPathComponent().appendingPathComponent("report.txt")
            try report.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 断言：一张卡是不是文档那一行写的样子

    @MainActor
    private func check(_ card: Card, _ hosted: Hosted, label: String, dark: Bool) {
        XCTAssertGreaterThan(hosted.cellView.frame.size.height, 20, "\(label)：cell 没有高度")
        // 级别：rust/links 给的（和会话页同一个分类函数）
        let classified = TellomiLinkRegistry.classifier.classify(
            .init(
                url: card.url,
                title: card.previewTitle,
                description: card.previewDescription,
                hasImage: card.picture != nil,
                rich: card.hasPreview ? Self.richBytes(card.rich) : nil,
            ),
            body: card.body ?? card.url,
            isStory: false,
            attachmentContentTypes: [],
        )
        XCTAssertEqual(classified?.level.rawValue, card.level, "\(label)：rust/links 给的级别")

        guard let cardView = Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView) else {
            XCTFail("\(label)：找不到卡片视图")
            return
        }
        let traits = hosted.window.traitCollection

        // 三行骨架：标题 → 副行 → 域名行（第一方卡：名字 → 副标题 → 按钮），顺序、内容，缺哪段不占哪一行
        let texts = Self.orderedTexts(in: cardView)
        XCTAssertEqual(texts, card.texts, "\(label)：卡上的文字（从上到下）")
        for absent in card.absent {
            XCTAssertFalse(texts.contains { $0.contains(absent) }, "\(label)：卡上不该有「\(absent)」，实际：\(texts)")
        }
        // 只有一条链接的消息只画卡片，不再画链接文字（§3.5）
        XCTAssertEqual(Self.containsBodyText(in: hosted.cellView), card.body != nil, "\(label)：链接文字该不该画在卡片下面")
        if card.level != "first_party" {
            if let title = Self.label(withText: card.title, in: cardView) {
                XCTAssertLessThanOrEqual(title.numberOfLines, 2, "\(label)：标题最多 2 行")
            }
            if let subLine = card.subLine, let subLineLabel = Self.label(withText: subLine, in: cardView) {
                XCTAssertEqual(subLineLabel.numberOfLines, 1, "\(label)：副行 1 行")
            }
            if let domain = card.domain, let domainLabel = Self.label(withText: domain, in: cardView) {
                XCTAssertEqual(domainLabel.numberOfLines, 1, "\(label)：域名行 1 行")
            }
        }

        // 图的版式
        let layout = Self.detectLayout(in: cardView)
        XCTAssertEqual(layout.layout, card.layout, "\(label)：图的版式，实际 \(layout)")
        let hasLinkIcon = Self.findLinkIcon(in: cardView) != nil
        XCTAssertEqual(hasLinkIcon, card.layout == .none, "\(label)：只有没有图的卡画通用链接图标")

        // 染色：第三方卡按图染，其余（无图、支付、第一方、域名卡）保持中性底色
        guard let background = cardView.backgroundColor?.resolvedColor(with: traits) else {
            XCTFail("\(label)：卡片没有底色")
            return
        }
        let neutral = UIColor.Signal.LightBase.fillTertiary.resolvedColor(with: traits)
        let tinted = Self.distance(background, neutral) > 0.02
        XCTAssertEqual(tinted, card.tinted, "\(label)：\(card.tinted ? "应该染色" : "不该染色")，实际底色 \(background)")
        if card.tinted, let titleLabel = Self.label(withText: card.title, in: cardView) {
            let ratio = Self.contrast(titleLabel.textColor.resolvedColor(with: traits), background)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(label)：染色卡的标题对比度应 ≥ 4.5:1，实际 \(ratio)")
        }
        report += "\(label): level \(classified?.level.rawValue ?? "nil"), layout \(layout.layout.rawValue), tinted \(tinted), linkIcon \(hasLinkIcon), height \(Int(hosted.cellView.frame.size.height)), texts \(texts)\n"
    }

    // MARK: - 视图里读出来的东西

    private static func findView(suffix: String, in view: UIView) -> UIView? {
        if NSStringFromClass(type(of: view)).hasSuffix(suffix) {
            return view
        }
        for subview in view.subviews {
            if let found = findView(suffix: suffix, in: subview) {
                return found
            }
        }
        return nil
    }

    private static func label(withText text: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, (label.attributedText?.string ?? label.text) == text {
            return label
        }
        for subview in view.subviews {
            if let found = label(withText: text, in: subview) {
                return found
            }
        }
        return nil
    }

    /// 卡里所有标签上的文字，按位置从上到下、同一行从左到右。
    private static func orderedTexts(in card: UIView) -> [String] {
        var found = [(y: CGFloat, x: CGFloat, text: String)]()
        func walk(_ view: UIView) {
            if let label = view as? UILabel, let text = label.attributedText?.string ?? label.text, !text.isEmpty {
                let frame = card.convert(label.bounds, from: label)
                found.append((frame.minY.rounded(), frame.minX, text))
            }
            view.subviews.forEach(walk)
        }
        walk(card)
        return found.sorted { ($0.y, $0.x) < ($1.y, $1.x) }.map(\.text)
    }

    /// 正文文字是 `CVTextLabel` 自己的（私有）视图画的，不是 UILabel / UITextView；有没有这个视图就是有没有画正文。
    private static func containsBodyText(in view: UIView) -> Bool {
        if NSStringFromClass(type(of: view)).contains("CVTextLabel") {
            return true
        }
        return view.subviews.contains { containsBodyText(in: $0) }
    }

    /// 卡片里画的通用链接图标（和纯链接卡同一个 `link` 图标，模板渲染）。
    private static func findLinkIcon(in view: UIView) -> UIImageView? {
        guard let linkData = UIImage(named: "link")?.pngData() else {
            return nil
        }
        if let imageView = view as? UIImageView, let data = imageView.image?.pngData(), data == linkData {
            return imageView
        }
        for subview in view.subviews {
            if let found = findLinkIcon(in: subview) {
                return found
            }
        }
        return nil
    }

    /// 第一方卡左边 56 pt 的头像 / 封面 / 图标：消息带来的图、头像视图、或默认的占位圆。
    private static func findAvatar(in view: UIView) -> UIView? {
        let name = NSStringFromClass(type(of: view))
        let isAvatarLike = name.hasSuffix("CVLinkPreviewImageView") || name.hasSuffix("ConversationAvatarView") || view is UIImageView
        if isAvatarLike, abs(view.bounds.size.width - 56) < 0.6, abs(view.bounds.size.height - 56) < 0.6 {
            return view
        }
        for subview in view.subviews {
            if let found = findAvatar(in: subview) {
                return found
            }
        }
        return nil
    }

    private struct DetectedLayout: CustomStringConvertible {
        let layout: ImageLayout
        let frame: CGRect?

        var description: String { "\(layout.rawValue) \(frame.map { "\($0)" } ?? "-")" }
    }

    /// 按视图判版式，同时核几何：图标 54 pt 贴右上（离上 6、离右 10）、大图占满卡宽且宽高比夹在 1.91:1–1:1、第一方头像 56 pt 在左边（§3.2 / §5.2）。
    @MainActor
    private static func detectLayout(in cardView: UIView) -> DetectedLayout {
        if let imageView = findView(suffix: "CVLinkPreviewImageView", in: cardView) {
            let frame = cardView.convert(imageView.bounds, from: imageView)
            if abs(frame.size.width - cardView.bounds.size.width) < 1.5, frame.minY < 1 {
                return DetectedLayout(layout: .large, frame: frame)
            }
            if abs(frame.size.width - 54) < 0.6, abs(frame.size.height - 54) < 0.6 {
                return DetectedLayout(layout: .icon, frame: frame)
            }
        }
        if let avatar = findAvatar(in: cardView) {
            return DetectedLayout(layout: .avatar, frame: cardView.convert(avatar.bounds, from: avatar))
        }
        return DetectedLayout(layout: .none, frame: nil)
    }

    private static func rgb(_ color: UIColor) -> (CGFloat, CGFloat, CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }

    /// WCAG 相对亮度。
    private static func luminance(_ color: UIColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let (red, green, blue) = rgb(color)
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let lighter = max(luminance(a), luminance(b))
        let darker = min(luminance(a), luminance(b))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func distance(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let (r1, g1, b1) = rgb(a)
        let (r2, g2, b2) = rgb(b)
        return max(abs(r1 - r2), abs(g1 - g2), abs(b1 - b2))
    }

    // MARK: - 建消息

    private static func richBytes(_ rich: Rich?) -> Data? {
        guard let rich else {
            return nil
        }
        let builder = SSKProtoRichContent.builder()
        builder.setKind(rich.kind)
        builder.setProvider(rich.provider)
        builder.setSchema(1)
        builder.setLevel(rich.level)
        for (key, value) in rich.attrs {
            let attr = SSKProtoAttr.builder()
            attr.setKey(key)
            attr.setValue(value)
            builder.addAttrs(attr.buildInfallibly())
        }
        return try? builder.buildSerializedData()
    }

    @MainActor
    private func insert(_ card: Card, thread: TSContactThread) async throws -> TSMessage {
        let richBytes = Self.richBytes(card.rich)
        let authorAci = try XCTUnwrap(thread.contactAddress.aci)
        let message: TSIncomingMessage = write { tx in
            let body = DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                MessageBody(text: card.body ?? card.url, ranges: .empty),
                tx: tx,
            )
            let linkPreview = card.hasPreview
                ? OWSLinkPreview(
                    urlString: card.url,
                    title: card.previewTitle,
                    previewDescription: card.previewDescription,
                    date: nil,
                    rich: richBytes,
                )
                : nil
            let builder: TSIncomingMessageBuilder = .withDefaultValues(
                thread: thread,
                timestamp: Date.ows_millisecondTimestamp(),
                authorAci: authorAci,
                messageBody: body,
                linkPreview: linkPreview,
            )
            let message = builder.build()
            message.anyInsert(transaction: tx)
            return message
        }
        if card.hasPreview, let picture = card.picture {
            let pending = try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
                png(picture),
                mimeType: "image/png",
                renderingFlag: .default,
                sourceFilename: nil,
            )
            try write { tx in
                _ = try DependenciesBridge.shared.attachmentManager.createAttachmentStream(
                    from: OwnedAttachmentDataSource(
                        dataSource: .pendingAttachment(pending),
                        owner: .messageLinkPreview(.init(
                            messageRowId: message.sqliteRowId!,
                            receivedAtTimestamp: message.receivedAtTimestamp,
                            threadRowId: thread.sqliteRowId!,
                            isPastEditRevision: false,
                        )),
                    ),
                    tx: tx,
                )
            }
        }
        return message
    }

    /// 预览图：竖向渐变（染色取主色 / 最下面一条，渐变让「取哪一块」在截图里看得见）+ 细边框 + 居中的文字。
    private func png(_ picture: Picture) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: picture.size, format: format).image { context in
            let top = UIColor(hue: picture.hue, saturation: 0.7, brightness: 0.9, alpha: 1)
            let bottom = UIColor(hue: picture.hue, saturation: 0.85, brightness: 0.6, alpha: 1)
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: picture.size.height), options: [])
            }
            let inset = min(picture.size.width, picture.size.height) * 0.04
            UIColor.white.withAlphaComponent(0.8).setStroke()
            let border = UIBezierPath(rect: CGRect(origin: .zero, size: picture.size).insetBy(dx: inset, dy: inset))
            border.lineWidth = max(2, inset / 3)
            border.stroke()
            let fontSize = min(picture.size.width, picture.size.height) / 5
            let text = picture.label as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: fontSize), .foregroundColor: UIColor.white]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (picture.size.width - textSize.width) / 2, y: (picture.size.height - textSize.height) / 2), withAttributes: attributes)
        }.pngData()!
    }

    // MARK: - Hosting（同 TellomiLinkCardScreenshotTests）

    private struct Hosted {
        let window: UIWindow
        let cellView: CVCellView
        let delegate: MockConversationView

        func tearDown() {
            cellView.isCellVisible = false
            window.isHidden = true
        }
    }

    @MainActor
    private func host(message: TSMessage, thread: TSThread, dark: Bool) async throws -> Hosted {
        // 排版和装配都在目标外观里做：这就是系统外观和 App 主题一致时的样子（真机上的常态）。
        // 「官方」徽标不靠这一层：它在文字画的时候按标签自己的外观画，系统外观和 App 主题不一样、配好后切主题都对
        // （见 TellomiOfficialBadgeContrastTests）。
        var made: Result<Hosted, Error>?
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            made = Result { try makeHosted(message: message, thread: thread, dark: dark) }
        }
        let hosted = try XCTUnwrap(made).get()
        // 缩略图是异步解出来的
        for _ in 0..<8 {
            try await Task.sleep(nanoseconds: 150_000_000)
            hosted.window.layoutIfNeeded()
        }
        return hosted
    }

    @MainActor
    private func makeHosted(message: TSMessage, thread: TSThread, dark: Bool) throws -> Hosted {
        let width = self.width
        let renderItem = try read { (tx: DBReadTransaction) throws -> CVRenderItem in
            let chatColor = DependenciesBridge.shared.chatColorSettingStore.resolvedChatColor(for: thread, tx: tx)
            let conversationStyle = ConversationStyle(
                type: .`default`,
                thread: thread,
                viewWidth: width,
                hasWallpaper: false,
                shouldDimWallpaperInDarkMode: false,
                chatColor: chatColor,
            )
            let latest = try XCTUnwrap(TSMessage.anyFetch(uniqueId: message.uniqueId, transaction: tx) as? TSMessage)
            return try XCTUnwrap(CVLoader.buildStandaloneRenderItem(
                interaction: latest,
                thread: thread,
                conversationStyle: conversationStyle,
                spoilerState: SpoilerRenderState(),
                groupNameColors: GroupNameColors.forThread(thread),
                transaction: tx,
            ))
        }

        let delegate = MockConversationView(model: .init(items: []), hasWallpaper: false, customChatColor: nil)
        let cellHeight = renderItem.cellMeasurement.cellSize.height
        let window = UIWindow(frame: CGRect(x: 0, y: 150, width: width, height: cellHeight + 24))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.backgroundColor = dark ? .black : .white
        let cellView = CVCellView()
        cellView.configure(renderItem: renderItem, componentDelegate: delegate)
        cellView.frame = CGRect(x: 0, y: 12, width: width, height: cellHeight)
        window.addSubview(cellView)
        window.isHidden = false
        cellView.isCellVisible = true
        window.layoutIfNeeded()
        return Hosted(window: window, cellView: cellView, delegate: delegate)
    }

    @MainActor
    private func render(_ hosted: Hosted) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: hosted.window.bounds, format: format).image { _ in
            hosted.window.drawHierarchy(in: hosted.window.bounds, afterScreenUpdates: true)
        }
    }

    // MARK: - 联系表

    /// 一个主题一张：左边写 kind 和它的级别，右边两列（字段全 / 只有必填）。
    @MainActor
    private func contactSheet(dark: Bool, shots: [String: [Variant: UIImage]]) -> UIImage {
        let labelWidth: CGFloat = 132
        let gap: CGFloat = 10
        let headerHeight: CGFloat = 40
        let footerHeight: CGFloat = 34
        let sheetWidth = labelWidth + gap + width + gap + width + gap
        let background: UIColor = dark ? .black : .white
        let primary: UIColor = dark ? .white : .black
        let secondary: UIColor = dark ? UIColor(white: 1, alpha: 0.55) : UIColor(white: 0, alpha: 0.5)

        func rowHeight(_ row: Row) -> CGFloat {
            let images = Variant.allCases.compactMap { shots[row.id]?[$0] }
            return max(images.map(\.size.height).max() ?? 0, 60)
        }
        let totalHeight = headerHeight + Self.rows.reduce(0) { $0 + rowHeight($1) + gap } + footerHeight

        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: sheetWidth, height: totalHeight), format: format).image { context in
            background.setFill()
            context.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: totalHeight))

            func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor, width maxWidth: CGFloat) {
                (text as NSString).draw(in: CGRect(x: point.x, y: point.y, width: maxWidth, height: 60), withAttributes: [.font: font, .foregroundColor: color])
            }
            draw(dark ? "暗色 · Dark" : "浅色 · Light", at: CGPoint(x: gap, y: 12), font: .boldSystemFont(ofSize: 15), color: primary, width: labelWidth)
            for (index, variant) in Variant.allCases.enumerated() {
                let x = labelWidth + gap + CGFloat(index) * (width + gap)
                draw(variant.rawValue, at: CGPoint(x: x + 12, y: 12), font: .boldSystemFont(ofSize: 15), color: primary, width: width)
            }

            var y = headerHeight
            for row in Self.rows {
                draw(row.name, at: CGPoint(x: gap, y: y + 14), font: .boldSystemFont(ofSize: 13), color: primary, width: labelWidth - gap)
                draw(row.full.level, at: CGPoint(x: gap, y: y + 32), font: .systemFont(ofSize: 11), color: secondary, width: labelWidth - gap)
                for (index, variant) in Variant.allCases.enumerated() {
                    if let image = shots[row.id]?[variant] {
                        image.draw(at: CGPoint(x: labelWidth + gap + CGFloat(index) * (width + gap), y: y))
                    }
                }
                y += rowHeight(row) + gap
            }
            // 预览图是测试合成的，不是真实站点的图；文字、版式、染色、按钮是产品代码真排出来的
            draw("预览图是测试合成的渐变图（不联网、不取真实站点的图）；文字、版式、染色、按钮是产品代码按会话页同一条渲染路径排出来的。", at: CGPoint(x: gap, y: y + 6), font: .systemFont(ofSize: 11), color: secondary, width: sheetWidth - gap * 2)
        }
    }

    private func save(_ image: UIImage, name: String, theme: String) throws {
        let url = try shotsDirectory(theme).appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
    }
}
