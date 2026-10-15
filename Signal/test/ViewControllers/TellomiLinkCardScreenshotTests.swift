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

/// tellomi/tellomi#1423：收到的链接卡片，按会话页同一条渲染路径（`CVLoader.buildStandaloneRenderItem` + `CVCellView`）排成**真实的消息 cell**，
/// 在内存环境里（不连服务端、不建真账号）截图；同时断言每条消息落在哪一级、要不要只画卡片。
///
/// 截图只在 `TELLOMI_SHOTS=1` 时存（xcodebuild 用 `TEST_RUNNER_TELLOMI_SHOTS=1` 传进来），写到 `TELLOMI_SHOTS_DIR/<屏宽>/`，屏宽取
/// `TELLOMI_SHOT_WIDTHS`（默认 402）。断言总是跑。
final class TellomiLinkCardScreenshotTests: XCTestCase {

    private var oldContext: (any AppContext)!
    private var report = ""
    /// 预览图画成细网格（肉眼看得出缩略图糊不糊）；只有看清晰度的那条用例打开。
    private var detailedImages = false

    @MainActor
    override func setUp() {
        super.setUp()
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
        // 先把这个测试开的窗口摘下来，环境还在时让它们收尾（TellomiTestWindow.swift）。
        UIWindow.tellomiDetachTestWindows()
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

    private var shotWidth: CGFloat {
        let raw = ProcessInfo.processInfo.environment["TELLOMI_SHOT_WIDTHS"] ?? "402"
        return raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.first.map { CGFloat($0) } ?? 402
    }

    private func shotsDirectory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: root).appendingPathComponent("\(Int(shotWidth))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 样例

    private struct Fixture {
        let name: String
        /// 消息正文；nil = 就是这条链接。
        var body: String?
        let url: String
        var previewTitle: String?
        var previewDescription: String?
        var rich: Rich?
        var hasPreview = true
        /// 预览图的像素尺寸和主色（(色相, 饱和度, 亮度)）；nil = 没有图。
        var image: (size: CGSize, hsb: (CGFloat, CGFloat, CGFloat))?
        /// rust/links 应该给的级别（带着 rich 和图一起问）。
        let expectedLevel: String
        /// 气泡里必须出现的文字（卡片上的标题 / 副行 / 域名行）。
        var cardTexts: [String] = []
        /// 链接文字有没有画在卡片下面：只有一条链接的消息不画（card-visual §3.5）。
        var urlTextShown = false
        /// 图的下半部分（底部约 30%）的颜色；nil = 整张图一个颜色。大图卡的染色取最下面一条，用来验证方向没有上下颠倒。
        var imageBottomHsb: (CGFloat, CGFloat, CGFloat)?
        /// 版式，按 cell 里的视图判：`icon`（右上角 54 pt 图标，照 Telegram）、`large`（整宽大图）、`text`（没有图）；nil = 不断言。
        var expectedLayout: String?
        /// 染色的色相范围（HSB 的 H，0…1）；nil = 不染色（保持默认卡片底色）。
        var expectedTintHue: ClosedRange<CGFloat>?
        /// 卡片上不该出现的文字（第一方卡没有域名行）。
        var absentTexts: [String] = []
        /// 染色卡上标题的文字（默认 = 预览标题）；品牌壳的标题是平台名，不是发送端的预览标题。
        var titleText: String?
        /// 本机已经是这个群的正式成员（群名用本地的）：先在库里建一个这样的群。
        var localGroupMasterKey: [UInt8]?
        var localGroupName: String?
        /// 本机已经装了这个贴纸包。
        var stickerPackInstalled = false

        struct Rich {
            let kind: String
            let provider: String
            let level: UInt32
            let attrs: [(String, String)]
        }
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            name: "bilibili-video",
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: "【演示】给朋友发一条视频链接会长什么样",
            previewDescription: "发送端写的描述——不该出现在卡片上",
            rich: .init(kind: "video", provider: "bilibili", level: 2, attrs: [("author", "演示UP主"), ("duration_ms", "257000"), ("published_at", "2025-03-14T10:00:00Z")]),
            image: (CGSize(width: 1280, height: 720), (0.55, 0.55, 0.85)),
            expectedLevel: "structured",
            cardTexts: ["【演示】给朋友发一条视频链接会长什么样", "演示UP主 · 4:17", "bilibili.com"],
        ),
        Fixture(
            name: "taobao-brand",
            url: "https://item.taobao.com/item.htm?id=674169489573",
            previewTitle: "登录",
            rich: .init(kind: "product", provider: "taobao", level: 1, attrs: []),
            expectedLevel: "brand",
            cardTexts: ["Taobao", "Product", "taobao.com"],
            // 品牌壳的图是随包图标（card-visual §3.9）：淘宝官网的图标，橙底，按它染色；发送端的预览标题不显示。
            expectedLayout: "icon",
            expectedTintHue: 0.03...0.12,
            absentTexts: ["登录"],
            titleText: "Taobao",
        ),
        Fixture(
            // 官网没有声明图标的品牌壳：只出平台名 + 域名（和以前一样，无图卡，不染色）。
            name: "meituan-brand-no-icon",
            url: "https://www.meituan.com/",
            previewTitle: "美团",
            rich: .init(kind: "web", provider: "meituan", level: 1, attrs: []),
            expectedLevel: "brand",
            cardTexts: ["Meituan", "meituan.com"],
            expectedLayout: "text",
        ),
        Fixture(
            // 支付金融：品牌壳，不染色（ADR-0063 L10），也没有图标。
            name: "alipay-payment",
            url: "https://render.alipay.com/p/f/fd-j5rqp49m/index.html",
            previewTitle: "支付宝",
            rich: .init(kind: "web", provider: "alipay", level: 1, attrs: []),
            expectedLevel: "brand",
            cardTexts: ["Alipay", "alipay.com"],
            expectedLayout: "text",
        ),
        Fixture(name: "tellomi-user", url: "https://tell.cc/hk881qb", previewTitle: "Tellomi", expectedLevel: "first_party", cardTexts: ["@hk881qb", "Tellomi user", "Message"], expectedLayout: "firstparty", absentTexts: ["tell.cc"]),
        Fixture(name: "tellomi-official", url: "https://tellomi.app/download", previewTitle: "Tellomi", expectedLevel: "first_party", cardTexts: ["Tellomi website", "/download", "Open"], expectedLayout: "firstparty", absentTexts: ["tellomi.app"]),
        Fixture(name: "generic", url: "https://www.wikipedia.org/", previewTitle: "Wikipedia", previewDescription: "Wikipedia is a free online encyclopedia, created and edited by volunteers.", expectedLevel: "generic", cardTexts: ["Wikipedia", "wikipedia.org"], expectedLayout: "text"),
        Fixture(
            name: "with-text",
            body: "看看这个 https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: "【演示】给朋友发一条视频链接会长什么样",
            rich: .init(kind: "video", provider: "bilibili", level: 2, attrs: [("author", "演示UP主"), ("duration_ms", "257000")]),
            image: (CGSize(width: 1280, height: 720), (0.55, 0.55, 0.85)),
            expectedLevel: "structured",
            cardTexts: ["演示UP主 · 4:17"],
            urlTextShown: true,
        ),
        Fixture(name: "no-preview", url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6", hasPreview: false, expectedLevel: "plain_link", cardTexts: ["bilibili.com"]),
        Fixture(name: "lookalike", url: "https://www.bi1ibili.com/video/BV1YDhJ6ZEL6", hasPreview: false, expectedLevel: "plain_link", cardTexts: ["bi1ibili.com"]),
        Fixture(
            name: "icon-yellow",
            url: "https://www.meituan.com/",
            previewTitle: "美团",
            image: (CGSize(width: 100, height: 100), (0.13, 0.95, 0.98)),
            expectedLevel: "generic",
            cardTexts: ["美团", "meituan.com"],
            expectedLayout: "icon",
            expectedTintHue: 0.09...0.17,
        ),
        Fixture(
            name: "icon-white",
            url: "https://www.jd.com/",
            previewTitle: "京东",
            image: (CGSize(width: 100, height: 100), (0, 0, 0.98)),
            expectedLevel: "generic",
            cardTexts: ["京东", "jd.com"],
            expectedLayout: "icon",
        ),
        Fixture(
            name: "large-orange",
            url: "https://www.cloudflare.com/",
            previewTitle: "Cloudflare",
            previewDescription: "Connect, protect, and build everywhere.",
            image: (CGSize(width: 1400, height: 800), (0.06, 0.9, 0.95)),
            expectedLevel: "generic",
            cardTexts: ["Cloudflare", "cloudflare.com"],
            expectedLayout: "large",
            expectedTintHue: 0.02...0.10,
        ),
        Fixture(
            name: "large-two-tone",
            url: "https://www.apple.com/",
            previewTitle: "Apple",
            image: (CGSize(width: 1200, height: 630), (0.33, 0.8, 0.8)),
            expectedLevel: "generic",
            cardTexts: ["Apple", "apple.com"],
            imageBottomHsb: (0.78, 0.7, 0.7),
            expectedLayout: "large",
            expectedTintHue: 0.72...0.84,
        ),
        Fixture(
            name: "tellomi-group",
            url: TellomiLinkCardScreenshotTests.groupInviteUrl(masterKeyByte: 1),
            previewTitle: "周末爬山群",
            rich: .init(kind: "tellomi.group", provider: "tellomi", level: 1, attrs: [("member_count", "12")]),
            image: (CGSize(width: 512, height: 512), (0.55, 0.5, 0.8)),
            expectedLevel: "first_party",
            cardTexts: ["周末爬山群", "12 members", "Join Group"],
            expectedLayout: "avatar",
            absentTexts: ["tell.cc"],
        ),
        Fixture(
            name: "tellomi-group-member",
            url: TellomiLinkCardScreenshotTests.groupInviteUrl(masterKeyByte: 2),
            previewTitle: "发送端写的群名",
            rich: .init(kind: "tellomi.group", provider: "tellomi", level: 1, attrs: [("member_count", "12")]),
            image: (CGSize(width: 512, height: 512), (0.3, 0.5, 0.8)),
            expectedLevel: "first_party",
            cardTexts: ["本地群名", "You’re a member", "Open"],
            expectedLayout: "avatar",
            absentTexts: ["发送端写的群名", "12 members", "Join Group"],
            localGroupMasterKey: Array(repeating: 2, count: 32),
            localGroupName: "本地群名",
        ),
        Fixture(
            name: "tellomi-sticker",
            url: "https://tell.cc/s#pack_id=00112233445566778899aabbccddeeff&pack_key=\(String(repeating: "11", count: 32))",
            previewTitle: "Bandit",
            rich: .init(kind: "tellomi.sticker", provider: "tellomi", level: 1, attrs: [("sticker_count", "24")]),
            image: (CGSize(width: 512, height: 512), (0.1, 0.6, 0.9)),
            expectedLevel: "first_party",
            cardTexts: ["Bandit", "24 stickers", "Add"],
            expectedLayout: "avatar",
            absentTexts: ["tell.cc"],
        ),
        Fixture(
            name: "tellomi-sticker-installed",
            url: "https://tell.cc/s#pack_id=ffeeddccbbaa99887766554433221100&pack_key=\(String(repeating: "22", count: 32))",
            previewTitle: "Bandit 2",
            rich: .init(kind: "tellomi.sticker", provider: "tellomi", level: 1, attrs: [("sticker_count", "24")]),
            image: (CGSize(width: 512, height: 512), (0.85, 0.5, 0.9)),
            expectedLevel: "first_party",
            cardTexts: ["Bandit 2", "Added", "View"],
            expectedLayout: "avatar",
            absentTexts: ["24 stickers"],
            stickerPackInstalled: true,
        ),
    ]

    /// 合法的群邀请链接（tell.cc/g#…），主密钥是同一个字节重复 32 次。
    private static func groupInviteUrl(masterKeyByte: UInt8) -> String {
        let masterKey = try! GroupMasterKey(contents: Data(repeating: masterKeyByte, count: 32))
        return try! GroupInviteLink(masterKey: masterKey, inviteLinkPassword: Data(repeating: masterKeyByte, count: 16)).url().absoluteString
    }

    // MARK: - 用例

    /// 每条样例：真排一次版（画出来的 cell 不崩、有高度），并存截图。
    @MainActor
    func testEveryFixtureRenders() async throws {
        let width = shotWidth
        let thread = write { tx -> TSContactThread in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
        var shots = [UIImage]()
        for fixture in Self.fixtures {
            try prepareLocalState(fixture)
            let message = try await insert(fixture, thread: thread, incoming: true)
            // 窗口的外观跟着 Theme 走（模拟器系统外观），否则气泡是深色、卡片却按浅色画
            let hosted = try await host(message: message, thread: thread, width: width, dark: Theme.isDarkThemeEnabled)
            XCTAssertGreaterThan(hosted.cellView.frame.size.height, 20, "\(fixture.name)：cell 没有高度")
            let card = TellomiLinkRegistry.classifier.classify(
                .init(
                    url: fixture.url,
                    title: fixture.previewTitle,
                    description: fixture.previewDescription,
                    hasImage: fixture.image != nil,
                    rich: fixture.hasPreview ? Self.richBytes(fixture.rich) : nil,
                ),
                body: fixture.body ?? fixture.url,
                isStory: false,
                attachmentContentTypes: [],
            )
            report += "\(fixture.name): cell height \(hosted.cellView.frame.size.height), level \(card?.level.rawValue ?? "nil") (\(card?.reason ?? "-"))\n"
            XCTAssertEqual(card?.level.rawValue, fixture.expectedLevel, "\(fixture.name)：rust/links 给的级别")
            let texts = Self.texts(in: hosted.cellView)
            let joined = texts.joined(separator: "\n")
            for expected in fixture.cardTexts {
                XCTAssertTrue(joined.contains(expected), "\(fixture.name)：气泡里应该有「\(expected)」，实际：\(texts)")
            }
            for absent in fixture.absentTexts {
                XCTAssertFalse(texts.contains { $0.contains(absent) }, "\(fixture.name)：气泡里不该有「\(absent)」，实际：\(texts)")
            }
            XCTAssertEqual(Self.containsBodyText(in: hosted.cellView), fixture.urlTextShown, "\(fixture.name)：正文文字该不该画在卡片下面，实际：\(texts)")
            report += "  texts: \(texts)\n"
            checkVisual(fixture, hosted, dark: Theme.isDarkThemeEnabled)
            if shooting {
                shots.append(render(hosted))
            }
            hosted.tearDown()
        }
        if shooting {
            try save(stack(shots, width: width), name: "cards-incoming.png")
            try report.write(to: shotsDirectory().deletingLastPathComponent().appendingPathComponent("metrics-cards.txt"), atomically: true, encoding: .utf8)
        }
    }

    /// 读屏（card-visual §3.6）：整条消息是一个无障碍元素，「只显示卡片」时正文组件被拿掉，标签里得有卡片上的文字，
    /// 不然 VoiceOver 读不到链接的任何内容。读的是真排出来的 cell 上的无障碍元素（拼法三端同一份，见 `a11y-strings.md`）：
    /// 第三方卡「链接，标题，域名」（不读副行）；第一方卡「类型，标题，副标题，按钮：动作」。
    @MainActor
    func testTheMessageReadsItsCardToVoiceOver() async throws {
        let width = shotWidth
        let thread = write { tx -> TSContactThread in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
        // 夹具名 → 整条消息的无障碍标签里必须有的一段（按文档 §3.6 拼，英文界面）
        let expected: [String: String] = [
            "bilibili-video": "Link, 【演示】给朋友发一条视频链接会长什么样, bilibili.com",
            "taobao-brand": "Link, Taobao, taobao.com",
            "generic": "Link, Wikipedia, wikipedia.org",
            "no-preview": "Link, bilibili.com",
            "with-text": "Link, 【演示】给朋友发一条视频链接会长什么样, bilibili.com",
            "tellomi-user": "Tellomi user, @hk881qb, button: Message",
            "tellomi-official": "Tellomi website, /download, button: Open",
            "tellomi-group": "Tellomi group, 周末爬山群, 12 members, button: Join Group",
            "tellomi-sticker": "Tellomi sticker pack, Bandit, 24 stickers, button: Add",
        ]
        // 不该出现在读屏里的（副行、描述、「官方」徽标的词）
        let absent: [String: [String]] = [
            "bilibili-video": ["演示UP主", "4:17", "发送端写的描述"],
            "taobao-brand": ["Product"],
            "generic": ["free online encyclopedia"],
            "tellomi-official": ["Official"],
        ]
        for fixture in Self.fixtures {
            guard let snippet = expected[fixture.name] else {
                continue
            }
            try prepareLocalState(fixture)
            let message = try await insert(fixture, thread: thread, incoming: true)
            let hosted = try await host(message: message, thread: thread, width: width, dark: Theme.isDarkThemeEnabled)
            let labels = Self.voiceOverElements(in: hosted.cellView).compactMap(\.accessibilityLabel)
            XCTAssertTrue(labels.contains { $0.contains(snippet) }, "\(fixture.name)：无障碍标签里应该有「\(snippet)」，实际：\(labels)")
            for word in absent[fixture.name] ?? [] {
                XCTAssertFalse(labels.contains { $0.contains(word) }, "\(fixture.name)：读屏里不该有「\(word)」，实际：\(labels)")
            }
            // 消息就是这条链接时只显示卡片：正文组件没有了，链接只能从卡片读到（对照：有文字时正文也在标签里）
            if fixture.name == "with-text" {
                XCTAssertTrue(labels.contains { $0.contains("看看这个 https://www.bilibili.com/video/BV1YDhJ6ZEL6") }, "with-text：正文也要读，实际：\(labels)")
            }
            hosted.tearDown()
        }
    }

    /// 一条收到的消息直接排成 cell（不检查级别、不存截图），给下面读屏和按下态的用例用。
    @MainActor
    private func hostedForA11yAndPress(_ fixture: Fixture, dark: Bool = false) async throws -> Hosted {
        let thread = write { tx -> TSContactThread in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
        try prepareLocalState(fixture)
        let message = try await insert(fixture, thread: thread, incoming: true)
        return try await host(message: message, thread: thread, width: shotWidth, dark: dark)
    }

    /// VoiceOver 实际能聚焦到的元素，按 UIKit 的规则收：自己是元素的视图算一个（里面的不再看）；不是元素、但列了 `accessibilityElements` 的容器，
    /// 取它列的（视图或 `UIAccessibilityElement`）；其余往下找子视图；隐藏的不算。
    private static func voiceOverElements(in view: UIView) -> [NSObject] {
        if view.isHidden || view.alpha == 0 || view.accessibilityElementsHidden {
            return []
        }
        if view.isAccessibilityElement {
            return [view]
        }
        if let listed = view.accessibilityElements {
            return listed.compactMap { $0 as? NSObject }
        }
        return view.subviews.flatMap { voiceOverElements(in: $0) }
    }

    /// card-visual §3.6 / a11y-strings：第一方卡的底部动作按钮是一个独立的无障碍按钮（button 角色、可聚焦、可激活），
    /// 整条消息照旧读整句；卡上别的文字不各读一遍（整条消息一个元素，不是卡上每个标签一个）。
    @MainActor
    func testTheFirstPartyCardActionIsAnAccessibleButton() async throws {
        let expected: [String: (sentence: String, button: String)] = [
            "tellomi-user": ("Tellomi user, @hk881qb, button: Message", "Message"),
            "tellomi-official": ("Tellomi website, /download, button: Open", "Open"),
            "tellomi-group": ("Tellomi group, 周末爬山群, 12 members, button: Join Group", "Join Group"),
            "tellomi-sticker": ("Tellomi sticker pack, Bandit, 24 stickers, button: Add", "Add"),
            "tellomi-group-member": ("Tellomi group, 本地群名, You’re a member, button: Open", "Open"),
        ]
        for (name, want) in expected {
            let fixture = try XCTUnwrap(Self.fixtures.first { $0.name == name }, name)
            let hosted = try await hostedForA11yAndPress(fixture, dark: Theme.isDarkThemeEnabled)
            defer { hosted.tearDown() }
            let elements = Self.voiceOverElements(in: hosted.cellView)
            let message = try XCTUnwrap(elements.first { ($0.accessibilityLabel ?? "").contains(want.sentence) }, "\(name)：找不到整句，实际 \(elements.map(\.accessibilityLabel))")
            XCTAssertFalse(message.accessibilityTraits.contains(.button), "\(name)：整条消息不是按钮")
            let buttons = elements.filter { $0.accessibilityTraits.contains(.button) }
            XCTAssertEqual(buttons.count, 1, "\(name)：恰好一个无障碍按钮，实际 \(buttons.map(\.accessibilityLabel))")
            let button = try XCTUnwrap(buttons.first)
            XCTAssertEqual(button.accessibilityLabel, want.button, "\(name)：按钮读它上面的字")
            XCTAssertTrue(button.isAccessibilityElement)
            // 按钮元素就是卡片底部那一条（36 pt 高），在整条消息的容器里面、靠下。
            // （离屏的窗口没有挂在屏幕上，`accessibilityFrame`（屏幕坐标）是 0，所以用视图自己的坐标判。）
            let buttonView = try XCTUnwrap(button as? UIView, "\(name)：按钮元素是卡上那个视图本身")
            XCTAssertEqual(buttonView.bounds.size.height, 36, accuracy: 0.6, "\(name)：按钮 36 pt 高")
            let container = try XCTUnwrap((message as? UIAccessibilityElement)?.accessibilityContainer as? UIView, "\(name)：整条消息元素挂在容器视图上")
            XCTAssertTrue(container.accessibilityElements?.contains { $0 as AnyObject === message } == true, "\(name)：容器里列着整条消息元素")
            let buttonInContainer = container.convert(buttonView.bounds, from: buttonView)
            XCTAssertTrue(container.bounds.contains(buttonInContainer), "\(name)：按钮在消息容器里，按钮 \(buttonInContainer)，容器 \(container.bounds)")
            XCTAssertGreaterThan(buttonInContainer.midY, container.bounds.midY, "\(name)：按钮在消息的下半部分")
            // 卡上别的文字不各自成为元素（标题、副行没有单独的读屏元素）
            XCTAssertEqual(elements.count, 2, "\(name)：只有整条消息和按钮两个元素，实际 \(elements.map(\.accessibilityLabel))")
            // 消息元素的框盖着整条消息，按钮元素在它后面（点触探索时后面的在上面）
            XCTAssertLessThan(try XCTUnwrap(elements.firstIndex(of: message)), try XCTUnwrap(elements.firstIndex(of: button)), "\(name)：先读整句，再到按钮")
        }
    }

    /// 对照：第三方卡、纯链接卡（没有动作按钮）仍然整条消息一个元素，没有多出来的按钮。
    @MainActor
    func testACardWithoutAnActionButtonStaysOneAccessibilityElement() async throws {
        for name in ["bilibili-video", "taobao-brand", "generic", "no-preview", "alipay-payment"] {
            let fixture = try XCTUnwrap(Self.fixtures.first { $0.name == name }, name)
            let hosted = try await hostedForA11yAndPress(fixture, dark: Theme.isDarkThemeEnabled)
            defer { hosted.tearDown() }
            let elements = Self.voiceOverElements(in: hosted.cellView)
            XCTAssertEqual(elements.filter { $0.accessibilityTraits.contains(.button) }.count, 0, "\(name)：没有按钮元素")
            XCTAssertEqual(elements.filter { ($0.accessibilityLabel ?? "").hasPrefix("Link") || ($0.accessibilityLabel ?? "").contains("Link, ") }.count, 1, "\(name)：卡片的句子只读一遍，实际 \(elements.map(\.accessibilityLabel))")
        }
    }

    // MARK: - 按下态 / 悬停态（card-visual §3.6 / §3.8）

    /// 画出来的卡片上，窗口坐标 `point` 那一个像素的颜色。
    @MainActor
    private func pixelColor(of hosted: Hosted, atWindowPoint point: CGPoint) -> UIColor? {
        let image = render(hosted)
        guard let cgImage = image.cgImage else {
            return nil
        }
        let scale = image.scale
        let x = Int((point.x * scale).rounded())
        let y = Int((point.y * scale).rounded())
        guard x >= 0, y >= 0, x < cgImage.width, y < cgImage.height, let crop = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            return nil
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn = pixel.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                )
            else {
                return false
            }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else {
            return nil
        }
        return UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// 按下态：整张卡叠一层半透明的黑 / 白（和卡上的字同一个黑 / 白），不换底色。染色卡与中性卡都要；浅色、深色都要。
    @MainActor
    func testPressingACardLaysAHalfTransparentBlackOrWhiteOverItAndKeepsTheBaseColour() async throws {
        let names = ["generic", "icon-yellow", "large-orange", "tellomi-user", "tellomi-official"]
        var shots = [Bool: [UIImage]]()
        defer {
            if shooting {
                for (dark, images) in shots {
                    try? save(stack(images, width: shotWidth), name: "w2-pressed-\(dark ? "dark" : "light").png")
                }
            }
        }
        // 气泡的颜色跟着 Theme 走，浅 / 深两遍都得把 Theme 也切过去，不然是深色窗口里画着浅色气泡
        let systemIsDark = Theme.isDarkThemeEnabled
        defer { Theme.setIsDarkThemeEnabledForTests(systemIsDark) }
        for dark in [false, true] {
            Theme.setIsDarkThemeEnabledForTests(dark)
            for name in names {
                let fixture = try XCTUnwrap(Self.fixtures.first { $0.name == name }, name)
                let hosted = try await hostedForA11yAndPress(fixture, dark: dark)
                defer { hosted.tearDown() }
                let cardView = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView), "\(name)：找不到卡片") as! CVLinkPreviewView
                let traits = hosted.window.traitCollection
                XCTAssertEqual(cardView.highlight, .idle, "\(name)：一开始没有叠层")
                XCTAssertEqual(cardView.highlightOverlayView.alpha, 0, accuracy: 0.001, "\(name)：一开始叠层是透明的")

                // 底色采样点：卡片左下角里面（圆角之内、在文字和图标之外）
                let cardFrame = cardView.convert(cardView.bounds, to: hosted.window)
                let sample = CGPoint(x: cardFrame.minX + 12, y: cardFrame.maxY - 5)
                let before = try XCTUnwrap(pixelColor(of: hosted, atWindowPoint: sample), "\(name)：读不到像素")

                cardView.pressBegan(at: CGPoint(x: 20, y: 20))
                XCTAssertEqual(cardView.highlight, .pressed, "\(name)：按下以后是按下态")
                // 叠层是 0.06 秒的淡入：截图和采样都取淡入结束的样子
                cardView.highlightOverlayView.layer.removeAllAnimations()
                cardView.layoutIfNeeded()
                hosted.window.layoutIfNeeded()
                if shooting {
                    shots[dark, default: []].append(render(hosted))
                }
                let pressed = try XCTUnwrap(pixelColor(of: hosted, atWindowPoint: sample), "\(name)：读不到按下后的像素")

                // 叠层颜色 = 标题的字色（黑或白，标题对比度 ≥ 4.5:1 的那个），不透明度在 6%–20% 之间
                let overlay = try XCTUnwrap(cardView.highlightOverlayView.backgroundColor).resolvedColor(with: traits)
                let (r, g, b) = Self.rgb(overlay)
                XCTAssertTrue((r < 0.05 && g < 0.05 && b < 0.05) || (r > 0.95 && g > 0.95 && b > 0.95), "\(name)：叠层是纯黑或纯白，实际 \(overlay)")
                XCTAssertGreaterThan(cardView.highlightOverlayView.alpha, 0.05, "\(name)：按下态的叠层看得见")
                XCTAssertLessThan(cardView.highlightOverlayView.alpha, 0.2, "\(name)：叠层是半透明，不盖住内容")

                // 画出来的像素：往叠层的颜色挪了一点（黑叠层变暗、白叠层变亮），幅度不超过 20%，不是换了一个颜色
                let isBlackOverlay = r < 0.5
                let beforeLuminance = Self.luminance(before)
                let pressedLuminance = Self.luminance(pressed)
                if isBlackOverlay {
                    XCTAssertLessThan(pressedLuminance, beforeLuminance - 0.01, "\(name)（\(dark ? "深" : "浅")色）：黑叠层应该让底色变暗，前 \(beforeLuminance)，后 \(pressedLuminance)")
                } else {
                    XCTAssertGreaterThan(pressedLuminance, beforeLuminance + 0.005, "\(name)（\(dark ? "深" : "浅")色）：白叠层应该让底色变亮，前 \(beforeLuminance)，后 \(pressedLuminance)")
                }
                XCTAssertLessThan(Self.distance(before, pressed), 0.2, "\(name)：只是叠一层，不是换底色，前 \(before)，后 \(pressed)")

                // 抬起以后叠层退掉，画回原来的底色
                cardView.pressEnded()
                XCTAssertEqual(cardView.highlight, .idle, "\(name)：抬起以后没有叠层")
                cardView.highlightOverlayView.layer.removeAllAnimations()
                XCTAssertEqual(cardView.highlightOverlayView.alpha, 0, accuracy: 0.001, "\(name)：叠层退掉")
            }
        }
    }

    /// 按下的过程：手指挪远了（开始滚动）就退掉；按住太久就退掉（0.2 秒时会话页的长按会拿起整条消息，预览里不能带着叠层）；
    /// 指针悬停是更淡的叠层，按下盖过悬停，悬停结束不带走按下态。
    @MainActor
    func testThePressedStateEndsWhenTheFingerMovesAwayOrHoldsTooLongAndHoverIsLighter() async throws {
        let fixture = try XCTUnwrap(Self.fixtures.first { $0.name == "generic" })
        let hosted = try await hostedForA11yAndPress(fixture)
        defer { hosted.tearDown() }
        let cardView = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView)) as! CVLinkPreviewView

        // 挪近一点还算按着，超过 10 pt 就是在拖（滚动）
        cardView.pressBegan(at: CGPoint(x: 50, y: 50))
        cardView.pressMoved(to: CGPoint(x: 54, y: 53))
        XCTAssertEqual(cardView.highlight, .pressed, "挪了 5 pt 还算按着")
        cardView.pressMoved(to: CGPoint(x: 50, y: 62))
        XCTAssertEqual(cardView.highlight, .idle, "挪了 12 pt：在拖，退掉叠层")
        cardView.pressMoved(to: CGPoint(x: 50, y: 50))
        XCTAssertEqual(cardView.highlight, .idle, "退掉以后挪回来不再叠（这一次触摸已经算拖动）")
        cardView.pressEnded()

        // 悬停 < 按下
        cardView.setHovering(true)
        XCTAssertEqual(cardView.highlight, .hover)
        let hoverAlpha = cardView.highlightOverlayView.alpha
        cardView.pressBegan(at: .zero)
        XCTAssertEqual(cardView.highlight, .pressed)
        XCTAssertGreaterThan(cardView.highlightOverlayView.alpha, hoverAlpha, "按下比悬停更深")
        cardView.setHovering(false)
        XCTAssertEqual(cardView.highlight, .pressed, "悬停结束不带走按下态")
        cardView.pressEnded()
        XCTAssertEqual(cardView.highlight, .idle)
        cardView.setHovering(true)
        cardView.setHovering(false)
        XCTAssertEqual(cardView.highlight, .idle)

        // 按住太久：到点自己退掉（测试里把上限缩到 0.05 秒）
        let oldMax = CVLinkPreviewView.pressedMaxDuration
        CVLinkPreviewView.pressedMaxDuration = 0.05
        defer { CVLinkPreviewView.pressedMaxDuration = oldMax }
        cardView.pressBegan(at: .zero)
        XCTAssertEqual(cardView.highlight, .pressed)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(cardView.highlight, .idle, "按住超过上限：叠层自己退掉（不留到长按菜单的预览里）")
    }

    /// 不响应点击的卡（消息请求里的域名卡）没有按下态：点了不会有反应，就不该有「可以点」的提示。
    @MainActor
    func testACardThatIgnoresTapsHasNoPressedState() async throws {
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        let fixture = try XCTUnwrap(Self.fixtures.first { $0.name == "generic" })
        let message = try await insert(fixture, thread: thread, incoming: true)
        let latestThread = try XCTUnwrap(read { TSThread.anyFetch(uniqueId: thread.uniqueId, transaction: $0) })
        let hosted = try await host(message: message, thread: latestThread, width: shotWidth, dark: Theme.isDarkThemeEnabled)
        defer { hosted.tearDown() }
        let cardView = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView)) as! CVLinkPreviewView
        XCTAssertFalse(cardView.isHighlightInteractive, "消息请求里的域名卡不响应点击")
        cardView.pressBegan(at: .zero)
        XCTAssertEqual(cardView.highlight, .idle, "不响应点击就没有按下态")
        cardView.setHovering(true)
        XCTAssertEqual(cardView.highlight, .idle, "也没有悬停态")
    }

    // MARK: - 第一方卡补齐（card-visual §5.2，审计 A12 / A14）

    /// 一条收到的消息直接排成 cell（不检查级别、不存截图），给下面第一方卡的用例用。
    @MainActor
    private func hostedForFirstParty(_ fixture: Fixture, dark: Bool = false) async throws -> Hosted {
        let thread = write { tx -> TSContactThread in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
        try prepareLocalState(fixture)
        let message = try await insert(fixture, thread: thread, incoming: true)
        return try await host(message: message, thread: thread, width: shotWidth, dark: dark)
    }

    /// `tellomi.user`（§5.2）：56 pt 圆形头像——本地认识（已被接受）→ 真头像；否则默认头像。头像只读本地库，不联网。
    @MainActor
    func testAKnownUserCardShowsTheRealAvatarAndAStrangerTheDefaultOne() async throws {
        let aci = Aci.randomForTesting()
        write { tx in
            DependenciesBridge.shared.usernameLookupManager.saveUsername("hk881qb.01", forAci: aci, transaction: tx)
            var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
            SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
        }
        let user = Fixture(name: "user", url: "https://tell.cc/hk881qb", previewTitle: "Tellomi", expectedLevel: "first_party")
        let stranger = Fixture(name: "stranger", url: "https://tell.cc/nobody", previewTitle: "Tellomi", expectedLevel: "first_party")

        let known = try await hostedForFirstParty(user, dark: Theme.isDarkThemeEnabled)
        defer { known.tearDown() }
        if shooting {
            try save(render(known), name: "w2-user-known.png")
        }
        let knownCard = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: known.cellView))
        let avatar = try XCTUnwrap(Self.findView(suffix: "ConversationAvatarView", in: knownCard), "认识的用户：应该是真头像（头像视图）") as! ConversationAvatarView
        let avatarFrame = knownCard.convert(avatar.bounds, from: avatar)
        XCTAssertEqual(avatarFrame.size.width, 56, accuracy: 0.6, "头像 56 pt")
        XCTAssertEqual(avatarFrame.size.height, 56, accuracy: 0.6)
        XCTAssertEqual(avatarFrame.minX, 10, accuracy: 1, "头像在左边")
        // 头像是数据层按这个用户从本地库取好的图（联系人照片 / 资料头像 / 默认头像），不是在 cell 配置阶段现取
        let expected = read {
            SSKEnvironment.shared.avatarBuilderRef.avatarImage(forAddress: SignalServiceAddress(aci), diameterPoints: 56, localUserDisplayMode: .asUser, transaction: $0)
        }
        guard case let .asset(image, _)? = avatar.configuration.dataSource else {
            return XCTFail("头像用数据层取好的现成的图（.asset），不在 cell 配置时开数据库事务，实际 \(String(describing: avatar.configuration.dataSource))")
        }
        XCTAssertEqual(image?.pngData(), expected?.pngData(), "头像取的是这个用户")
        XCTAssertNotNil(image, "本机认识的用户至少有默认头像")
        XCTAssertNotNil(avatar.primaryImage, "头像画出来了")
        XCTAssertFalse(Self.texts(in: known.cellView).contains { $0.contains("tell.cc") }, "第一方卡没有域名行")

        let unknown = try await hostedForFirstParty(stranger, dark: Theme.isDarkThemeEnabled)
        defer { unknown.tearDown() }
        if shooting {
            try save(render(unknown), name: "w2-user-unknown.png")
        }
        let unknownCard = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: unknown.cellView))
        XCTAssertNil(Self.findView(suffix: "ConversationAvatarView", in: unknownCard), "不认识的用户：默认头像（占位），不去取任何头像")
        XCTAssertNotNil(Self.findPlaceholderAvatar(in: unknownCard), "默认头像是 56 pt 的圆形占位")
    }

    /// 默认头像：56 pt 的圆（`secondaryFill` 底，里面一个人形），不是头像视图。
    private static func findPlaceholderAvatar(in view: UIView) -> UIImageView? {
        if let imageView = view as? UIImageView, imageView.image != nil, abs(imageView.bounds.size.width - 56) < 0.6, abs(imageView.bounds.size.height - 56) < 0.6 {
            return imageView
        }
        for subview in view.subviews {
            if let found = findPlaceholderAvatar(in: subview) {
                return found
            }
        }
        return nil
    }

    private static let callUrl = "https://tell.cc/call#key=bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz"

    /// `tellomi.call`（§5.2）：通话图标 + 房间名或「Tellomi 通话」，没有副标题，底部「加入通话」。原来 tell.cc 的通话链接被 Signal 自己的通话卡截走
    /// （副行是发送端的描述、有域名行 tell.cc、按钮是卡外面另一个 Signal 的「加入」）。
    @MainActor
    func testATellomiCallLinkIsAFirstPartyCardWithItsOwnJoinButton() async throws {
        let named = Fixture(
            name: "call-named",
            url: Self.callUrl,
            previewTitle: "周五例会",
            previewDescription: "Use this link to join a Tellomi call",
            rich: .init(kind: "tellomi.call", provider: "tellomi", level: 1, attrs: []),
            expectedLevel: "first_party",
        )
        let nameless = Fixture(name: "call-nameless", url: Self.callUrl, expectedLevel: "first_party")
        for (fixture, title) in [(named, "周五例会"), (nameless, "Tellomi call")] {
            let hosted = try await hostedForFirstParty(fixture, dark: Theme.isDarkThemeEnabled)
            defer { hosted.tearDown() }
            if shooting {
                try save(render(hosted), name: "w2-\(fixture.name).png")
            }
            let cardView = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView), "\(fixture.name)：找不到卡片")
            let texts = Self.texts(in: cardView)
            XCTAssertTrue(texts.contains(title), "\(fixture.name)：标题是房间名或「Tellomi call」，实际 \(texts)")
            XCTAssertNotNil(Self.findLabel(text: "Join Call", in: cardView), "\(fixture.name)：「加入通话」按钮在卡片里面，实际 \(texts)")
            XCTAssertFalse(texts.contains { $0.contains("tell.cc") }, "\(fixture.name)：没有域名行，实际 \(texts)")
            XCTAssertFalse(texts.contains { $0.contains("join a Tellomi call") }, "\(fixture.name)：没有发送端 / Signal 的描述，实际 \(texts)")
            XCTAssertEqual(texts.count, 2, "\(fixture.name)：只有标题和按钮两行字（没有副标题），实际 \(texts)")
            // Signal 自己的「加入」底部按钮不再有（卡片自带按钮，不重复）
            XCTAssertNil(Self.findView(suffix: "CVMessageActionButton", in: hosted.cellView), "\(fixture.name)：卡外面没有第二个「加入」按钮")
            // 通话图标：56 pt 的圆形占位（neutral），不是头像视图
            XCTAssertNotNil(Self.findPlaceholderAvatar(in: cardView), "\(fixture.name)：通话图标 56 pt")
            XCTAssertNil(Self.findView(suffix: "ConversationAvatarView", in: cardView))
            // 点进入通话的行为不变：点卡片 → `handleUrl` → `CallLink(url:)`（和 Signal 通话卡同一条路）
            let url = try XCTUnwrap(URL(string: Self.callUrl))
            if case let .url(routed) = ConversationViewController.tellomiInAppRoute(for: url) {
                XCTAssertNotNil(CallLink(url: routed), "\(fixture.name)：点开以后认得出是通话链接，进 presentLobby")
            } else {
                XCTFail("\(fixture.name)：tell.cc/call 应该走上游的通话链接解析")
            }
        }
    }

    /// 对照：Signal 自己的通话链接（`signal.link`）不是 Tellomi 的第一方对象，仍是 Signal 的通话卡 + 卡外面的「加入」按钮。
    @MainActor
    func testASignalCallLinkStaysSignalsCallCard() async throws {
        let fixture = Fixture(
            name: "signal-call",
            url: "https://signal.link/call/#key=bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz",
            previewTitle: "Weekly sync",
            expectedLevel: "generic",
        )
        let hosted = try await hostedForFirstParty(fixture, dark: Theme.isDarkThemeEnabled)
        defer { hosted.tearDown() }
        if shooting {
            try save(render(hosted), name: "w2-call-signal-old-form.png")
        }
        XCTAssertNotNil(Self.findView(suffix: "CVMessageActionButton", in: hosted.cellView), "Signal 的通话卡仍带着卡外面的「加入」按钮")
        let cardView = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView))
        XCTAssertTrue(Self.texts(in: cardView).contains("Weekly sync"))
    }

    /// 染色的卡在深色外观下：同一个色相、更暗的底、字色对比度仍达标；截图存 `cards-incoming-dark.png`。
    @MainActor
    func testTintedCardsFollowTheAppearance() async throws {
        let width = shotWidth
        let thread = write { tx -> TSContactThread in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
        var shots = [UIImage]()
        for fixture in Self.fixtures where fixture.expectedTintHue != nil {
            let message = try await insert(fixture, thread: thread, incoming: true)
            let light = try await host(message: message, thread: thread, width: width, dark: false)
            let lightBackground = Self.cardBackground(in: light)
            light.tearDown()
            let dark = try await host(message: message, thread: thread, width: width, dark: true)
            let darkBackground = Self.cardBackground(in: dark)
            if let lightBackground, let darkBackground {
                XCTAssertLessThan(Self.luminance(darkBackground), Self.luminance(lightBackground), "\(fixture.name)：深色下的底应该比浅色下更暗")
            } else {
                XCTFail("\(fixture.name)：找不到卡片底色")
            }
            checkVisual(fixture, dark, dark: true)
            if shooting {
                shots.append(render(dark))
            }
            dark.tearDown()
        }
        if shooting {
            try save(stack(shots, width: width), name: "cards-incoming-dark.png")
        }
    }

    /// 还没接受的会话（消息请求）里，同样的消息只画域名卡（card-visual §3.3 / §7.3，ADR-0063 §8.1 第 6 行）：
    /// 没有发送端写的标题 / 副行 / 图、品牌壳图标、第一方卡的头像和按钮，不染色，正文里的链接文字还在。截图存 `cards-request.png`。
    @MainActor
    func testMessageRequestsShowOnlyTheDomain() async throws {
        let width = shotWidth
        // 没放进白名单：陌生人发来的消息请求。
        let thread = write { tx in ContactThreadFactory().create(transaction: tx) }
        // 夹具名 → 卡片上应该只有的域名，以及不该出现的（发送端写的、品牌壳的、第一方卡的）文字。
        let expected: [String: (domain: String, absent: [String])] = [
            "bilibili-video": ("bilibili.com", ["【演示】给朋友发一条视频链接会长什么样", "演示UP主", "4:17", "不该出现在卡片上"]),
            "taobao-brand": ("taobao.com", ["Taobao", "Product", "登录"]),
            "alipay-payment": ("alipay.com", ["Alipay", "支付宝"]),
            "tellomi-user": ("tell.cc", ["@hk881qb", "Tellomi user", "Message"]),
            "generic": ("wikipedia.org", ["free online encyclopedia"]),
            "with-text": ("bilibili.com", ["演示UP主", "4:17"]),
            "no-preview": ("bilibili.com", []),
            "lookalike": ("bi1ibili.com", []),
        ]
        var shots = [UIImage]()
        for fixture in Self.fixtures {
            guard let expectation = expected[fixture.name] else {
                continue
            }
            try prepareLocalState(fixture)
            let message = try await insert(fixture, thread: thread, incoming: true)
            // 会话页拿到的是从库里取出来的线程：收到消息以后线程才「可见」，才算消息请求（刚建的那个对象还不是）。
            let latestThread = try XCTUnwrap(read { TSThread.anyFetch(uniqueId: thread.uniqueId, transaction: $0) })
            XCTAssertTrue(read { ThreadViewModel(thread: latestThread, forChatList: false, transaction: $0).hasPendingMessageRequest }, "\(fixture.name)：夹具要真的是消息请求")
            let hosted = try await host(message: message, thread: latestThread, width: width, dark: Theme.isDarkThemeEnabled)
            XCTAssertGreaterThan(hosted.cellView.frame.size.height, 20, "\(fixture.name)：cell 没有高度")
            let texts = Self.texts(in: hosted.cellView)
            XCTAssertEqual(texts.filter { $0 == expectation.domain }.count, 1, "\(fixture.name)：卡片上只有一个域名「\(expectation.domain)」，实际：\(texts)")
            for absent in expectation.absent {
                XCTAssertFalse(texts.contains { $0.contains(absent) }, "\(fixture.name)：消息请求里不该有「\(absent)」，实际：\(texts)")
            }
            XCTAssertTrue(Self.containsBodyText(in: hosted.cellView), "\(fixture.name)：正文里的链接文字不隐藏，实际：\(texts)")
            if let cardView = Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView) {
                XCTAssertNil(Self.findView(suffix: "CVLinkPreviewImageView", in: cardView), "\(fixture.name)：域名卡没有图")
                let background = cardView.backgroundColor?.resolvedColor(with: hosted.window.traitCollection)
                let plain = UIColor.Signal.LightBase.fillTertiary.resolvedColor(with: hosted.window.traitCollection)
                XCTAssertLessThan(background.map { Self.distance($0, plain) } ?? 1, 0.02, "\(fixture.name)：不染色，实际底色 \(String(describing: background))")
            } else {
                XCTFail("\(fixture.name)：找不到卡片视图")
            }
            report += "request \(fixture.name): cell height \(hosted.cellView.frame.size.height), texts \(texts)\n"
            if shooting {
                shots.append(render(hosted))
            }
            hosted.tearDown()
        }
        if shooting {
            try save(stack(shots, width: width), name: "cards-request.png")
        }
    }

    /// 输入框里群邀请链接确定失效时的提示（ADR-0063 §5.1 铁律 2 的例外）：一行字 + ( X )，截图存 `composer-group-inactive.png`。
    @MainActor
    func testTheComposerShowsTheInactiveGroupLinkMessage() throws {
        let width = shotWidth
        let dark = Theme.isDarkThemeEnabled
        let view = LinkPreviewView(state: .failed(LinkPreviewError.groupLinkInactive))
        // y = 150：不压在屏幕顶部的安全区上（别的离屏测试也这样放）
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 150, width: width, height: 100))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.backgroundColor = dark ? .black : .white
        view.translatesAutoresizingMaskIntoConstraints = false
        window.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: window.leadingAnchor, constant: 12),
            view.trailingAnchor.constraint(equalTo: window.trailingAnchor, constant: -12),
            view.topAnchor.constraint(equalTo: window.topAnchor, constant: 12),
        ])
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        // 输入框的容器把预览区的上下边贴在这个视图上，所以高度是视图按内容自己算出来的（不是被撑开的）
        let fitted = view.systemLayoutSizeFitting(
            CGSize(width: width - 24, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        )
        XCTAssertGreaterThanOrEqual(fitted.height, 40, "提示条至少 40 pt 高，实际 \(fitted)")
        XCTAssertLessThanOrEqual(fitted.height, 60, "一行提示不该比 60 pt 高，实际 \(fitted)")
        view.heightAnchor.constraint(equalToConstant: fitted.height).isActive = true
        window.layoutIfNeeded()

        XCTAssertEqual(Self.texts(in: view), ["This group link is not active"])
        XCTAssertNotNil(view.cancelButton.window, "( X ) 要在视图里")
        let cancelFrame = view.convert(view.cancelButton.frame, from: view.cancelButton.superview)
        XCTAssertTrue(view.bounds.contains(cancelFrame), "( X ) 不能画到条外：\(cancelFrame) / \(view.bounds)")

        if shooting {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try save(image, name: "composer-group-inactive.png")
        }
    }

    // MARK: - 第二波：版式与几何（card-visual §3.2 / §3.4 / §3.7，审计 A19 / B3 / B6 / §3 第 2 条）

    /// 一条收到的消息直接排成 cell（不检查级别、不存截图），给下面几条版式用例用。
    @MainActor
    private func hostedCell(for fixture: Fixture, dark: Bool = false) async throws -> Hosted {
        // 上一条用例（或上一张夹具）解出来的缩略图按「附件 id + 档位」缓存，新的内存库里 id 又从 1 开始，会撞键
        CVLinkPreviewView.resetImageCacheForTests()
        let thread = write { tx -> TSContactThread in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
        try prepareLocalState(fixture)
        let message = try await insert(fixture, thread: thread, incoming: true)
        return try await host(message: message, thread: thread, width: shotWidth, dark: dark)
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

    private static func findNamedStack(_ name: String, in view: UIView) -> UIView? {
        if let layoutView = view as? ManualLayoutView, layoutView.name == name {
            return layoutView
        }
        for subview in view.subviews {
            if let found = findNamedStack(name, in: subview) {
                return found
            }
        }
        return nil
    }

    private static func label(startingWith prefix: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, (label.attributedText?.string ?? label.text)?.hasPrefix(prefix) == true {
            return label
        }
        for subview in view.subviews {
            if let found = label(startingWith: prefix, in: subview) {
                return found
            }
        }
        return nil
    }

    /// §3.7：副行 1 行，放不下截断在末尾（Signal 原来是 3 行）。
    @MainActor
    func testTheSubLineIsOneLineAndTruncatesAtTheEnd() async throws {
        let longAuthor = String(repeating: "一个非常非常长的作者名字", count: 8)
        let fixture = Fixture(
            name: "video-long-author",
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: "【演示】给朋友发一条视频链接会长什么样",
            rich: .init(kind: "video", provider: "bilibili", level: 2, attrs: [("author", longAuthor), ("duration_ms", "257000")]),
            image: (CGSize(width: 1280, height: 720), (0.55, 0.55, 0.85)),
            expectedLevel: "structured",
        )
        let hosted = try await hostedCell(for: fixture)
        defer { hosted.tearDown() }
        let cardView = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView))
        let subLine = try XCTUnwrap(Self.label(startingWith: String(longAuthor.prefix(6)), in: cardView), "找不到副行")
        XCTAssertEqual(subLine.numberOfLines, 1, "副行最多 1 行")
        // 一行的标签比字体的行高略高（测量时取整 / 留白），两行就超过 1.5 倍行高了
        XCTAssertLessThan(subLine.bounds.size.height, subLine.font.lineHeight * 1.5, "副行只占一行的高度，实际 \(subLine.bounds.size.height)，行高 \(subLine.font.lineHeight)")
        XCTAssertEqual(subLine.lineBreakMode, .byTruncatingTail, "放不下截断在末尾")
        // 标题还是最多 2 行（不在这一条里动）
        let title = try XCTUnwrap(Self.label(startingWith: "【演示】", in: cardView))
        XCTAssertEqual(title.numberOfLines, 2)
    }

    /// §3.2：「无图卡」——标题（有的话）+ 域名，右侧通用链接图标；没有图的卡（generic 无图、没有随包图标的品牌壳、支付壳）都一样，
    /// 不是只有纯链接卡才画。有图的卡（图标卡、大图卡）和第一方卡不画。
    @MainActor
    func testEveryCardWithoutAnImageShowsTheLinkIconOnTheRight() async throws {
        let withIcon = ["generic", "meituan-brand-no-icon", "alipay-payment", "no-preview"]
        let without = ["taobao-brand", "icon-yellow", "large-orange", "tellomi-user", "tellomi-official"]
        var shots = [UIImage]()
        defer {
            if shooting {
                try? save(stack(shots, width: shotWidth), name: "w2-link-icon-cards.png")
            }
        }
        for name in withIcon + without {
            let fixture = try XCTUnwrap(Self.fixtures.first { $0.name == name }, name)
            let hosted = try await hostedCell(for: fixture, dark: Theme.isDarkThemeEnabled)
            defer { hosted.tearDown() }
            if shooting {
                shots.append(render(hosted))
            }
            let cardView = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView), "\(name)：找不到卡片")
            let icon = Self.findLinkIcon(in: cardView)
            if withIcon.contains(name) {
                let iconView = try XCTUnwrap(icon, "\(name)：无图卡右侧应该有通用链接图标")
                let frame = cardView.convert(iconView.bounds, from: iconView)
                XCTAssertEqual(frame.maxX, cardView.bounds.size.width - 10, accuracy: 1, "\(name)：图标贴右边（离右 10），实际 \(frame) / 卡宽 \(cardView.bounds.size.width)")
                XCTAssertEqual(frame.midY, cardView.bounds.size.height / 2, accuracy: 1.5, "\(name)：图标垂直居中，实际 \(frame) / 卡高 \(cardView.bounds.size.height)")
                XCTAssertGreaterThan(frame.size.width, 10, "\(name)：图标有大小")
            } else {
                XCTAssertNil(icon, "\(name)：有图 / 第一方卡不画通用链接图标")
            }
        }
    }

    /// card-visual §3.2：图标卡的文字与图间距——iOS 取 Telegram 的 6（cutout 宽 = 图宽 + 6），不是 Android 的 10。
    /// 标题写得够长、占满文字列时，文字列右边缘到图的左边缘就是这个间距。
    @MainActor
    func testTheIconCardKeepsSixPointsBetweenTheTextColumnAndTheIcon() async throws {
        // 图标画成细网格：纯色图标和染色的底一个颜色，截图里看不见它
        detailedImages = true
        let fixture = Fixture(
            name: "icon-long-title",
            url: "https://www.meituan.com/",
            previewTitle: String(repeating: "美团外卖 · 美好生活小帮手 ", count: 6),
            image: (CGSize(width: 100, height: 100), (0.13, 0.95, 0.98)),
            expectedLevel: "generic",
        )
        let hosted = try await hostedCell(for: fixture, dark: Theme.isDarkThemeEnabled)
        defer { hosted.tearDown() }
        if shooting {
            try save(render(hosted), name: "w2-icon-card-long-title.png")
        }
        let cardView = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView))
        let imageView = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewImageView", in: cardView), "应该是图标卡")
        let textStack = try XCTUnwrap(Self.findNamedStack("textStack", in: cardView))
        let iconFrame = cardView.convert(imageView.bounds, from: imageView)
        let textFrame = cardView.convert(textStack.bounds, from: textStack)
        XCTAssertEqual(iconFrame.size.width, 54, accuracy: 0.6)
        XCTAssertEqual(iconFrame.minX - textFrame.maxX, 6, accuracy: 0.6, "文字列与图标之间 6（Telegram cutout），实际文字列 \(textFrame)、图标 \(iconFrame)")
        XCTAssertEqual(textFrame.minX, 10, accuracy: 0.6, "文字离左 10（和图离右一样）")
    }

    /// 审计 §3 第 2 条：大图卡（短边 ≥ 300 且长边 ≥ 600，由 rust/links 定）仍按 Signal 旧的「宽 ≥ 气泡最大宽 × 2」挑缩略图档位，
    /// 竖图、偏窄的图会拿 `.small`（长边 200 pt）的缩略图铺满卡宽而发糊。缩略图的像素宽要够卡宽（受原图限制）。
    @MainActor
    func testALargeImageCardAsksForAThumbnailThatIsSharpEnough() async throws {
        let scale = UIScreen.main.scale
        detailedImages = true
        var shots = [UIImage]()
        defer {
            if shooting {
                try? save(stack(shots, width: shotWidth), name: "w2-large-image-sharpness.png")
            }
        }
        for (name, size) in [("large-portrait", CGSize(width: 600, height: 900)), ("large-narrow", CGSize(width: 620, height: 340))] {
            let fixture = Fixture(
                name: name,
                url: "https://www.cloudflare.com/",
                previewTitle: "Cloudflare",
                image: (size, (0.06, 0.9, 0.95)),
                expectedLevel: "generic",
            )
            let hosted = try await hostedCell(for: fixture, dark: Theme.isDarkThemeEnabled)
            defer { hosted.tearDown() }
            if shooting {
                shots.append(render(hosted))
            }
            let cardView = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView))
            let imageHolder = try XCTUnwrap(Self.findView(suffix: "CVLinkPreviewImageView", in: cardView), "\(name)：应该是大图卡")
            let cardFrame = cardView.convert(imageHolder.bounds, from: imageHolder)
            XCTAssertEqual(cardFrame.size.width, cardView.bounds.size.width, accuracy: 1, "\(name)：图占满卡宽")
            let decoded = try XCTUnwrap(Self.decodedImage(in: imageHolder), "\(name)：缩略图还没解出来")
            let pixelWidth = CGFloat(decoded.cgImage?.width ?? 0)
            let neededPixels = min(size.width, cardFrame.size.width * scale) * 0.9
            XCTAssertGreaterThanOrEqual(pixelWidth, neededPixels, "\(name)：缩略图 \(pixelWidth) px 宽，卡宽 \(cardFrame.size.width * scale) px、原图 \(size.width) px，至少要 \(neededPixels) px")
        }
    }

    private static func decodedImage(in view: UIView) -> UIImage? {
        if let imageView = view as? UIImageView, let image = imageView.image, image.cgImage != nil, imageView.bounds.size.width > 40 {
            return image
        }
        for subview in view.subviews {
            if let found = decodedImage(in: subview) {
                return found
            }
        }
        return nil
    }

    /// 版式（按视图判）、卡片底色（染色 / 不染色）、标题字色对比度（染色时 ≥ 4.5:1，card-visual §3.3）。
    @MainActor
    private func checkVisual(_ fixture: Fixture, _ hosted: Hosted, dark: Bool = false) {
        guard let cardView = Self.findView(suffix: "CVLinkPreviewView", in: hosted.cellView) else {
            if fixture.expectedLayout != nil || fixture.expectedTintHue != nil {
                XCTFail("\(fixture.name)：找不到卡片视图")
            }
            return
        }
        let traits = hosted.window.traitCollection
        let imageView = Self.findView(suffix: "CVLinkPreviewImageView", in: cardView)
        if let expectedLayout = fixture.expectedLayout {
            switch expectedLayout {
            case "icon":
                if let imageView {
                    let frame = cardView.convert(imageView.bounds, from: imageView)
                    XCTAssertEqual(frame.size.width, 54, accuracy: 0.6, "\(fixture.name)：图标卡的图标 54 pt（Telegram iOS 小图），实际 \(frame)")
                    XCTAssertEqual(frame.size.height, 54, accuracy: 0.6, "\(fixture.name)：图标卡的图标 54 pt（Telegram iOS 小图），实际 \(frame)")
                    XCTAssertEqual(frame.maxX, cardView.bounds.size.width - 10, accuracy: 1, "\(fixture.name)：图标贴右侧、离右边 10（和文字离左一样，Telegram 的内缩左右对称），实际 \(frame) / 卡宽 \(cardView.bounds.size.width)")
                    XCTAssertEqual(frame.minY, 6, accuracy: 1, "\(fixture.name)：图标贴上边、离上边 6（不垂直居中），实际 \(frame)")
                    XCTAssertGreaterThanOrEqual(cardView.bounds.size.height, 66 - 0.5, "\(fixture.name)：卡最矮 = 图 54 + 上下各 6，实际 \(cardView.bounds.size)")
                } else {
                    XCTFail("\(fixture.name)：图标卡应该有图")
                }
            case "avatar":
                if let imageView {
                    let frame = cardView.convert(imageView.bounds, from: imageView)
                    XCTAssertEqual(frame.size.width, 56, accuracy: 0.6, "\(fixture.name)：第一方卡的头像 / 封面 56 pt，实际 \(frame)")
                    XCTAssertEqual(frame.size.height, 56, accuracy: 0.6, "\(fixture.name)：第一方卡的头像 / 封面 56 pt，实际 \(frame)")
                    XCTAssertEqual(frame.minX, 10, accuracy: 1, "\(fixture.name)：头像在左边，实际 \(frame)")
                } else {
                    XCTFail("\(fixture.name)：第一方卡应该有消息带来的头像 / 封面")
                }
            case "large":
                if let imageView {
                    let frame = cardView.convert(imageView.bounds, from: imageView)
                    XCTAssertEqual(frame.size.width, cardView.bounds.size.width, accuracy: 1, "\(fixture.name)：大图卡的图占满卡宽，实际 \(frame)")
                    XCTAssertEqual(frame.minY, 0, accuracy: 1, "\(fixture.name)：大图在上，实际 \(frame)")
                    XCTAssertGreaterThanOrEqual(frame.size.height, frame.size.width / 1.91 - 1, "\(fixture.name)：图的宽高比不超过 1.91:1，实际 \(frame)")
                    XCTAssertLessThanOrEqual(frame.size.height, frame.size.width + 1, "\(fixture.name)：图的宽高比不低于 1:1，实际 \(frame)")
                } else {
                    XCTFail("\(fixture.name)：大图卡应该有图")
                }
            default:
                XCTAssertNil(imageView, "\(fixture.name)：这张卡没有图")
            }
        }
        guard let background = cardView.backgroundColor?.resolvedColor(with: traits) else {
            XCTFail("\(fixture.name)：卡片没有底色")
            return
        }
        // 第一方卡底部的动作按钮字：浅 / 深色下都要读得清（≥ 4.5:1）。卡片底色是半透明的，所以量画出来的像素，不算颜色值。
        if fixture.expectedLevel == "first_party", let action = fixture.cardTexts.last {
            if let label = Self.findLabel(text: action, in: cardView) {
                let rect = label.convert(label.bounds, to: hosted.window)
                if let ratio = Self.pixelContrast(in: render(hosted), rect: rect) {
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(fixture.name)：按钮字对比度应 ≥ 4.5:1，实际 \(ratio)（\(dark ? "深" : "浅")色）")
                } else {
                    XCTFail("\(fixture.name)：读不到按钮的像素")
                }
            } else {
                XCTFail("\(fixture.name)：找不到按钮「\(action)」")
            }
        }
        if let hueRange = fixture.expectedTintHue {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            background.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            XCTAssertTrue(hueRange.contains(hue), "\(fixture.name)：底色色相应在 \(hueRange)，实际 \(hue)（\(dark ? "深" : "浅")色）")
            XCTAssertGreaterThan(saturation, 0.2, "\(fixture.name)：染色的底色不该是灰的，实际饱和度 \(saturation)")
            if let title = fixture.titleText ?? fixture.previewTitle, let label = Self.findLabel(text: title, in: cardView) {
                let text = label.textColor.resolvedColor(with: traits)
                let ratio = Self.contrast(text, background)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(fixture.name)：标题对比度应 ≥ 4.5:1，实际 \(ratio)（\(dark ? "深" : "浅")色）")
            } else {
                XCTFail("\(fixture.name)：找不到标题")
            }
        } else if fixture.expectedLayout != nil {
            let plain = UIColor.Signal.LightBase.fillTertiary.resolvedColor(with: traits)
            XCTAssertLessThan(Self.distance(background, plain), 0.02, "\(fixture.name)：不该染色，实际底色 \(background)")
        }
    }

    /// 一块像素里字和底的对比度：底 = 出现最多的颜色，字 = 跟底对比最强的颜色（抗锯齿的中间色比不过纯色字）。
    private static func pixelContrast(in image: UIImage, rect: CGRect) -> CGFloat? {
        guard let cgImage = image.cgImage else {
            return nil
        }
        let scale = image.scale
        let crop = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.size.width * scale,
            height: rect.size.height * scale,
        ).integral
        guard let part = cgImage.cropping(to: crop), part.width > 0, part.height > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: part.width * part.height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: part.width,
                    height: part.height,
                    bitsPerComponent: 8,
                    bytesPerRow: part.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                )
            else {
                return false
            }
            context.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
            return true
        }
        guard drawn else {
            return nil
        }
        var counts = [UInt32: Int]()
        for index in stride(from: 0, to: buffer.count, by: 4) {
            let red = UInt32(buffer[index])
            let green = UInt32(buffer[index + 1])
            let blue = UInt32(buffer[index + 2])
            counts[(red << 16) | (green << 8) | blue, default: 0] += 1
        }
        func color(_ key: UInt32) -> UIColor {
            let red = CGFloat((key >> 16) & 255) / 255
            let green = CGFloat((key >> 8) & 255) / 255
            let blue = CGFloat(key & 255) / 255
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
        }
        guard let background = counts.max(by: { $0.value < $1.value })?.key else {
            return nil
        }
        return counts.keys.map { contrast(color($0), color(background)) }.max()
    }

    private static func cardBackground(in hosted: Hosted) -> UIColor? {
        findView(suffix: "CVLinkPreviewView", in: hosted.cellView)?.backgroundColor?.resolvedColor(with: hosted.window.traitCollection)
    }

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

    private static func findLabel(text: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, (label.attributedText?.string ?? label.text) == text {
            return label
        }
        for subview in view.subviews {
            if let found = findLabel(text: text, in: subview) {
                return found
            }
        }
        return nil
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

    // MARK: - 本机已有的状态

    /// 「已经是这个群的正式成员」「已经装了这个贴纸包」：先在本地库里建出来，卡片才会显示「你已加入」「已添加」。
    private func prepareLocalState(_ fixture: Fixture) throws {
        if let keyBytes = fixture.localGroupMasterKey {
            let masterKey = try GroupMasterKey(contents: Data(keyBytes))
            var membership = GroupMembership.Builder()
            membership.addFullMember(LocalIdentifiers.forUnitTests.aci, role: .normal)
            var builder = TSGroupModelBuilder(secretParams: try GroupSecretParams.deriveFromMasterKey(groupMasterKey: masterKey))
            builder.name = fixture.localGroupName
            builder.groupMembership = membership.build()
            let groupModel = try builder.buildAsV2()
            let groupThread = TSGroupThread(groupModel: groupModel)
            let secretParams = try GroupSecretParams.deriveFromMasterKey(groupMasterKey: masterKey)
            write { tx in
                groupThread.anyInsert(transaction: tx)
                // 群 id → 线程行的映射；没有这一行，按群 id 查不到线程（真实流程里入群时会建）。
                _ = GroupRecord.insertRecord(
                    groupId: groupModel.groupId,
                    threadId: groupThread.sqliteRowId!,
                    masterKey: try! secretParams.getMasterKey(),
                    refreshedAt: .distantPast,
                    tx: tx,
                )
            }
        }
        if fixture.stickerPackInstalled {
            let url = try XCTUnwrap(URL(string: fixture.url))
            let info = try XCTUnwrap(StickerPackInfo.parseStickerPackShare(TellomiLinks.legacyEquivalent(of: url)))
            let item = StickerPackItem(stickerId: 0, emojiString: "😀", contentType: "image/webp")
            let record = StickerPackRecord(info: info, title: fixture.previewTitle, author: nil, cover: item, items: [item])
            // 直接写库并标成已安装：`installStickerPack` 会排下载，测试里没有文件。
            write { tx in
                record.anyInsert(transaction: tx)
                record.updateWith(isInstalled: true, tx: tx)
            }
        }
    }

    // MARK: - 建消息

    private static func richBytes(_ rich: Fixture.Rich?) -> Data? {
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
    private func insert(_ fixture: Fixture, thread: TSContactThread, incoming: Bool) async throws -> TSMessage {
        let richBytes = Self.richBytes(fixture.rich)
        let authorAci = try XCTUnwrap(thread.contactAddress.aci)
        let message: TSIncomingMessage = write { tx in
            let body = DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                MessageBody(text: fixture.body ?? fixture.url, ranges: .empty),
                tx: tx,
            )
            let linkPreview = fixture.hasPreview
                ? OWSLinkPreview(
                    urlString: fixture.url,
                    title: fixture.previewTitle,
                    previewDescription: fixture.previewDescription,
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
        if fixture.hasPreview, let image = fixture.image {
            let pending = try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
                png(size: image.size, hsb: image.hsb, bottomHsb: fixture.imageBottomHsb),
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

    private func png(size: CGSize, hsb: (CGFloat, CGFloat, CGFloat), bottomHsb: (CGFloat, CGFloat, CGFloat)? = nil) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(hue: hsb.0, saturation: hsb.1, brightness: hsb.2, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if detailedImages {
                // 1 px 的白线、每 6 px 一根：缩得太小再拉大，线会糊成灰
                UIColor(white: 1, alpha: 0.85).setFill()
                for x in stride(from: CGFloat(0), to: size.width, by: 6) {
                    context.fill(CGRect(x: x, y: 0, width: 1, height: size.height))
                }
                for y in stride(from: CGFloat(0), to: size.height, by: 6) {
                    context.fill(CGRect(x: 0, y: y, width: size.width, height: 1))
                }
            }
            if let bottomHsb {
                UIColor(hue: bottomHsb.0, saturation: bottomHsb.1, brightness: bottomHsb.2, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: size.height * 0.7, width: size.width, height: size.height * 0.3))
            }
        }.pngData()!
    }

    // MARK: - Hosting（同 AlbumViewerScreenshotTests）

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
    private func host(message: TSMessage, thread: TSThread, width: CGFloat, dark: Bool = false) async throws -> Hosted {
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
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 150, width: width, height: cellHeight + 24))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.backgroundColor = dark ? .black : .white
        let cellView = CVCellView()
        cellView.configure(renderItem: renderItem, componentDelegate: delegate)
        cellView.frame = CGRect(x: 0, y: 12, width: width, height: cellHeight)
        window.addSubview(cellView)
        window.isHidden = false
        cellView.isCellVisible = true
        window.layoutIfNeeded()

        let hosted = Hosted(window: window, cellView: cellView, delegate: delegate)
        // 缩略图是异步解出来的
        for _ in 0..<8 {
            try await Task.sleep(nanoseconds: 150_000_000)
            window.layoutIfNeeded()
        }
        return hosted
    }

    @MainActor
    private func render(_ hosted: Hosted) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: hosted.window.bounds, format: format).image { _ in
            hosted.window.drawHierarchy(in: hosted.window.bounds, afterScreenUpdates: true)
        }
    }

    private func stack(_ images: [UIImage], width: CGFloat) -> UIImage {
        let height = images.reduce(0) { $0 + $1.size.height }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: max(1, height)), format: format).image { context in
            Theme.backgroundColor.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            var y: CGFloat = 0
            for image in images {
                image.draw(at: CGPoint(x: 0, y: y))
                y += image.size.height
            }
        }
    }

    /// 正文文字是 `CVTextLabel` 自己的（私有）视图画的，不是 UILabel / UITextView；有没有这个视图就是有没有画正文。
    private static func containsBodyText(in view: UIView) -> Bool {
        if NSStringFromClass(type(of: view)).contains("CVTextLabel") {
            return true
        }
        return view.subviews.contains { containsBodyText(in: $0) }
    }

    /// cell 里所有标签和文本视图上的文字。
    private static func texts(in view: UIView) -> [String] {
        var result = [String]()
        if let label = view as? UILabel, let text = label.attributedText?.string ?? label.text, !text.isEmpty {
            result.append(text)
        } else if let textView = view as? UITextView, !textView.attributedText.string.isEmpty {
            result.append(textView.attributedText.string)
        }
        for subview in view.subviews {
            result += texts(in: subview)
        }
        return result
    }

    private func save(_ image: UIImage, name: String) throws {
        let url = try shotsDirectory().appendingPathComponent(name)
        try XCTUnwrap(image.pngData()).write(to: url)
        report += "saved \(url.path)\n"
    }
}
