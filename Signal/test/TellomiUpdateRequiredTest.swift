//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1139）：「必须更新」阻断页，按 owner 2026-09-24 的三条规则盖或不盖。
@MainActor
final class TellomiUpdateRequiredTest: SignalBaseTest {

    // MARK: - When to block

    private let ourAppStoreListing = URL(string: "https://apps.apple.com/app/tellomi/id1234567890")!

    private func shouldBlock(
        _ appExpiry: AppExpiry,
        isTellomiDeployment: Bool = true,
        hasUpdateChannel: Bool = true,
        viewChatsOnlyChosen: Bool = false,
    ) -> Bool {
        TellomiUpdateRequiredMonitoringManager.shouldBlock(
            appExpiry: appExpiry,
            now: Date(),
            isTellomiDeployment: isTellomiDeployment,
            hasUpdateChannel: hasUpdateChannel,
            viewChatsOnlyChosen: viewChatsOnlyChosen,
        )
    }

    private func serverRejectedAppExpiry() async -> AppExpiry {
        let appExpiry = AppExpiry.forUnitTests(buildDate: Date())
        // 服务端回 499 时走的就是这一步（AppExpiry.appExpiredStatusCode）。
        await appExpiry.setHasAppExpiredAtCurrentVersion(db: InMemoryDB())
        return appExpiry
    }

    func testACurrentVersionIsNotBlocked() {
        XCTAssertFalse(shouldBlock(AppExpiry.forUnitTests(buildDate: Date())))
    }

    func testAVersionTheServerTurnedAwayIsBlocked() async {
        let appExpiry = await serverRejectedAppExpiry()
        XCTAssertTrue(shouldBlock(appExpiry))
    }

    func testABuildPastItsLifespanOnlyBecomesReadOnly() {
        // 规则 2：本机构建到期不盖，留给上游的只读（会话列表提示 + 输入框换成「更新」）。
        let buildDate = Date().addingTimeInterval(-AppExpiry.defaultExpirationInterval - .day)
        let appExpiry = AppExpiry.forUnitTests(buildDate: buildDate)
        XCTAssertTrue(appExpiry.isExpired(now: Date()))
        XCTAssertFalse(shouldBlock(appExpiry))
    }

    func testWithoutAnUpdateChannelTheAppGoesStraightToReadOnly() async {
        // 规则 3：没有可用的更新渠道时不盖，按钮无处可去。
        let appExpiry = await serverRejectedAppExpiry()
        XCTAssertFalse(shouldBlock(appExpiry, hasUpdateChannel: false))
    }

    func testChoosingToOnlyViewChatsStopsTheBlock() async {
        // 规则 1。
        let appExpiry = await serverRejectedAppExpiry()
        XCTAssertFalse(shouldBlock(appExpiry, viewChatsOnlyChosen: true))
    }

    func testTheSignalDeploymentKeepsTheUpstreamBehavior() async {
        let appExpiry = await serverRejectedAppExpiry()
        XCTAssertFalse(shouldBlock(appExpiry, isTellomiDeployment: false))
    }

    // MARK: - Update channel

    func testOnlyTheChannelWeConfiguredCountsAsAnUpdateChannel() {
        // taishi 审查 b15 启用前置 4：只认我们配的那一条（owner 2026-09-25：TestFlight 外部测试的公开链接），
        // 不再「App Store / TestFlight 的地址、只要不是 Signal 的都算」。
        let ourTestFlight = URL(string: "https://testflight.apple.com/join/AbCdEfGh")!
        func hasUpdateChannel(_ url: String, ourChannel: URL?) -> Bool {
            TellomiUpdateRequiredMonitoringManager.hasUpdateChannel(appStoreUrl: URL(string: url)!, ourChannel: ourChannel)
        }

        // 还没配渠道：什么都不算，iOS 不盖阻断页，只降成只读。
        XCTAssertFalse(hasUpdateChannel("https://testflight.apple.com/join/AbCdEfGh", ourChannel: nil))
        XCTAssertFalse(hasUpdateChannel(ourAppStoreListing.absoluteString, ourChannel: nil))

        // 配了：只有那一条算。
        XCTAssertTrue(hasUpdateChannel("https://testflight.apple.com/join/AbCdEfGh", ourChannel: ourTestFlight))
        XCTAssertFalse(hasUpdateChannel("https://testflight.apple.com/join/SomeoneElse", ourChannel: ourTestFlight))
        XCTAssertFalse(hasUpdateChannel("https://apps.apple.com/app/some-other-app/id1111111111", ourChannel: ourTestFlight))
        XCTAssertFalse(hasUpdateChannel("https://itunes.apple.com/us/app/signal-private-messenger/id874139669?mt=8", ourChannel: ourTestFlight))
        XCTAssertFalse(hasUpdateChannel("https://tellomi.app/download/", ourChannel: ourTestFlight))

        // 以后上架：App Store 条目同样照这个规则配。
        XCTAssertTrue(hasUpdateChannel(ourAppStoreListing.absoluteString, ourChannel: ourAppStoreListing))
    }

    func testViewChatsOnlyFromThePageUnblocksThisVersion() async throws {
        // taishi 审查 b15 启用前置 2：「暂不更新，只看聊天记录」从页面的确认一路接到「不再盖」、记下这个版本。
        // 走的是 WindowManager 里真的接线（makeUpdateRequiredBlockingViewController）和真的 MonitoringManager，只把窗口换成假的。
        let suiteName = "TellomiUpdateRequiredTest-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let ourTestFlight = URL(string: "https://testflight.apple.com/join/AbCdEfGh")!
        let host = FakeUpdateRequiredBlockHost()
        let manager = TellomiUpdateRequiredMonitoringManager(
            appExpiry: await serverRejectedAppExpiry(),
            windowManager: host,
            userDefaults: userDefaults,
            isTellomiDeployment: true,
            appStoreUrl: ourTestFlight,
            updateChannelUrl: ourTestFlight,
            currentAppVersion: "0.1.2.3",
            manifest: { nil },
            refreshManifest: { _ in },
        )
        manager.start()
        XCTAssertTrue(host.isUpdateRequiredBlockActive, "the server turned this version away and there is a channel: the page covers the app")

        let page = WindowManager.makeUpdateRequiredBlockingViewController(host: host)
        page.confirmViewChatsOnly()

        XCTAssertFalse(host.isUpdateRequiredBlockActive)
        XCTAssertTrue(TellomiUpdateRequiredMonitoringManager.viewChatsOnlyChosen(userDefaults: userDefaults, currentAppVersion: "0.1.2.3"))
        withExtendedLifetime(manager) {}
    }

    func testTheAppLockDoesNotPromptOverTheUpdatePage() {
        // taishi 审查 b15 启用前置 3：阻断页盖着时不自动弹 Face ID / 密码框；收起后照常弹。
        XCTAssertTrue(ScreenLockUI.shouldPresentAuthUI(desiredUIState: .screenLock, didLastUnlockAttemptFail: false, isUpdateRequiredBlockActive: false))
        XCTAssertFalse(ScreenLockUI.shouldPresentAuthUI(desiredUIState: .screenLock, didLastUnlockAttemptFail: false, isUpdateRequiredBlockActive: true))
        XCTAssertFalse(ScreenLockUI.shouldPresentAuthUI(desiredUIState: .screenLock, didLastUnlockAttemptFail: true, isUpdateRequiredBlockActive: false))
        XCTAssertFalse(ScreenLockUI.shouldPresentAuthUI(desiredUIState: .none, didLastUnlockAttemptFail: false, isUpdateRequiredBlockActive: false))
    }

    // MARK: - "Not now, just view my chats"

    func testTheChoiceIsRememberedForThisVersionOnly() {
        let suiteName = "TellomiUpdateRequiredTest-\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(TellomiUpdateRequiredMonitoringManager.viewChatsOnlyChosen(userDefaults: userDefaults, currentAppVersion: "0.1.2.3"))

        TellomiUpdateRequiredMonitoringManager.recordViewChatsOnly(userDefaults: userDefaults, currentAppVersion: "0.1.2.3")

        XCTAssertTrue(TellomiUpdateRequiredMonitoringManager.viewChatsOnlyChosen(userDefaults: userDefaults, currentAppVersion: "0.1.2.3"))
        // 装上新版本，这个选择作废。
        XCTAssertFalse(TellomiUpdateRequiredMonitoringManager.viewChatsOnlyChosen(userDefaults: userDefaults, currentAppVersion: "0.1.3.0"))
    }

    // MARK: - 更新清单（tellomi/tellomi#1491）

    private let ourNotes = URL(string: "https://www.tellomi.app/changelog/#ios")!

    private func manifest(url: URL?, required: UInt64 = 6) -> TellomiUpdateManifest {
        TellomiUpdateManifest(
            serial: 1,
            latest: .init(version: "0.1.1", build: 6, url: url),
            recommendedMinBuild: 0,
            requiredMinBuild: required,
            requiredReason: required > 0 ? .security : nil,
            requiredFrom: nil,
            notesUrl: ourNotes,
        )
    }

    private func startManager(appExpiry: AppExpiry, manifest: TellomiUpdateManifest?, host: FakeUpdateRequiredBlockHost) throws -> TellomiUpdateRequiredMonitoringManager {
        let suiteName = "TellomiUpdateRequiredTest-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { userDefaults.removePersistentDomain(forName: suiteName) }
        let manager = TellomiUpdateRequiredMonitoringManager(
            appExpiry: appExpiry,
            windowManager: host,
            userDefaults: userDefaults,
            isTellomiDeployment: true,
            appStoreUrl: URL(string: "https://tellomi.app/download/")!,
            updateChannelUrl: nil,
            currentAppVersion: "0.1.0.5",
            manifest: { manifest },
            refreshManifest: { _ in },
        )
        manager.start()
        return manager
    }

    func testTheTestFlightLinkInTheManifestIsTheUpdateChannel() async throws {
        // 链接到手以后不用发版：清单里验过签的 TestFlight 公开链接就是渠道，阻断页上的原因、版本和链接都跟着它
        let link = URL(string: "https://testflight.apple.com/join/AbCdEfGh")!
        let host = FakeUpdateRequiredBlockHost()
        let manager = try startManager(appExpiry: await serverRejectedAppExpiry(), manifest: manifest(url: link), host: host)

        XCTAssertTrue(host.isUpdateRequiredBlockActive)
        XCTAssertEqual(host.updateRequiredPageInfo, TellomiUpdateRequiredPageInfo(reason: .security, newVersion: "0.1.1", notesUrl: ourNotes, updateUrl: link))
        withExtendedLifetime(manager) {}
    }

    func testAManifestWithoutALinkIsStillNoUpdateChannel() async throws {
        // 规则 3 不变：没有 TestFlight 公开链接就不盖，只降成只读
        let host = FakeUpdateRequiredBlockHost()
        let manager = try startManager(appExpiry: await serverRejectedAppExpiry(), manifest: manifest(url: nil), host: host)

        XCTAssertFalse(host.isUpdateRequiredBlockActive)
        XCTAssertEqual(host.updateRequiredPageInfo.reason, .security)
        withExtendedLifetime(manager) {}
    }

    func testTheReasonOnlyComesFromAManifestThatRequiresThisBuild() {
        // 构建 7 已经高过门槛：清单写的原因不算数，阻断页（如果是 499 盖的）说的是服务端那一句
        let info = TellomiUpdateRequiredMonitoringManager.pageInfo(manifest: manifest(url: nil), build: 7, now: Date())
        XCTAssertNil(info.reason)
        XCTAssertNil(info.newVersion, "0.1.1 (6) is not newer than build 7")
        XCTAssertEqual(TellomiUpdateRequiredMonitoringManager.pageInfo(manifest: nil, build: 5, now: Date()), .serverRejected)
    }

    func testTheManifestReasonAndVersionAppearOnThePage() {
        let viewController = TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: {}, openNotes: { _ in }, viewChatsOnly: {})
        viewController.pageInfo = TellomiUpdateRequiredPageInfo(reason: .security, newVersion: "0.1.1", notesUrl: nil, updateUrl: nil)
        viewController.loadViewIfNeeded()

        let shown = labelTexts(in: viewController.view).joined(separator: "\n")
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_REASON_SECURITY", value: "This version has a security problem. To protect your account and messages, update to keep using Tellomi.", comment: "")), shown)
        XCTAssertTrue(shown.contains(String(format: OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_NEW_VERSION", value: "Version %@", comment: ""), "0.1.1")), shown)
        XCTAssertFalse(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_REASON_SERVER_REJECTED", value: "This version can no longer communicate with the server. Update to keep sending and receiving messages.", comment: "")), shown)

        viewController.pageInfo = TellomiUpdateRequiredPageInfo(reason: .other, newVersion: nil, notesUrl: nil, updateUrl: nil)
        XCTAssertTrue(viewController.subtitle.hasPrefix(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_REASON_OTHER", value: "This version needs an update to keep sending and receiving messages.", comment: "")), viewController.subtitle)
    }

    func testWhatsInThisUpdateShowsOnlyWithNotesAndOpensThem() {
        var opened: [URL] = []
        let viewController = TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: {}, openNotes: { opened.append($0) }, viewChatsOnly: {})
        viewController.loadViewIfNeeded()
        XCTAssertTrue(viewController.learnMoreButton.isHidden)

        viewController.pageInfo = TellomiUpdateRequiredPageInfo(reason: nil, newVersion: nil, notesUrl: ourNotes, updateUrl: nil)
        XCTAssertEqual(buttons(in: viewController.view), [viewController.updateButton, viewController.learnMoreButton, viewController.viewChatsOnlyButton])

        viewController.learnMoreButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(opened, [ourNotes])
    }

    // MARK: - The page

    private func labelTexts(in view: UIView) -> [String] {
        var result: [String] = []
        if let label = view as? UILabel, let text = label.text {
            result.append(text)
        }
        for subview in view.subviews {
            result += labelTexts(in: subview)
        }
        return result
    }

    /// 看得见的按钮（「了解更新内容」没有清单时是藏着的）。
    private func buttons(in view: UIView) -> [UIButton] {
        guard !view.isHidden else {
            return []
        }
        var result: [UIButton] = []
        if let button = view as? UIButton {
            result.append(button)
        }
        for subview in view.subviews {
            result += buttons(in: subview)
        }
        return result
    }

    func testThePageOffersUpdatingOrOnlyViewingTheChats() {
        // 期望文案带上和页面代码一样的 value:。不带的话，模拟器语言不是四种之一时，期望值会变成键名，
        // 而页面显示的是英文，用例假红（taishi 审查 b15 包 8 不阻塞 5）。
        var opened = 0
        let viewController = TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: { opened += 1 }, openNotes: { _ in }, viewChatsOnly: {})
        viewController.loadViewIfNeeded()

        let shown = labelTexts(in: viewController.view).joined(separator: "\n")
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_TITLE", value: "Update Tellomi to continue", comment: "")), shown)
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_REASON_SERVER_REJECTED", value: "This version can no longer communicate with the server. Update to keep sending and receiving messages.", comment: "")), shown)
        XCTAssertTrue(shown.contains(OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_CHATS_KEPT", value: "Updating keeps all the chats on this phone.", comment: "")), shown)

        // 规则 1：主按钮「立即更新」，另有「暂不更新，只看聊天记录」；没有别的。
        XCTAssertEqual(buttons(in: viewController.view), [viewController.updateButton, viewController.viewChatsOnlyButton])
        XCTAssertEqual(viewController.viewChatsOnlyButton.configuration?.title, OWSLocalizedString("APP_EXPIRED_TELLOMI_BLOCKING_VIEW_CHATS_ONLY_BUTTON", value: "Not now, just view my chats", comment: ""))

        viewController.updateButton.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(opened, 1)
    }

    // MARK: - 最大字号（taishi 审查 b15 不阻塞 4）

    private func subviews<T: UIView>(of type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { subviews(of: type, in: $0) }
    }

    /// 放进还在支持的最小屏幕之一（iPhone SE 第二、三代，375×667）排好版。
    private func laidOutPage(at category: UIContentSizeCategory) throws -> (TellomiUpdateRequiredAppBlockingViewController, UIWindow) {
        guard #available(iOS 17.0, *) else {
            throw XCTSkip("traitOverrides needs iOS 17")
        }
        let viewController = TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: {}, openNotes: { _ in }, viewChatsOnly: {})
        viewController.traitOverrides.preferredContentSizeCategory = category
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.rootViewController = viewController
        window.isHidden = false
        viewController.view.layoutIfNeeded()
        return (viewController, window)
    }

    func testWithTheLargestTextTheExplanationIsNotCutOffAndThePageScrolls() throws {
        // 改之前：上游的内容栈不在滚动视图里，两段说明被压到 94pt，「更新不会影响聊天记录」被裁掉。
        let (viewController, window) = try laidOutPage(at: .accessibilityExtraExtraExtraLarge)
        defer { window.isHidden = true }

        let explanation = try XCTUnwrap(subviews(of: UILabel.self, in: viewController.view).first { $0.text == TellomiUpdateRequiredAppBlockingViewController.subtitle(for: .serverRejected) })
        let needed = explanation.sizeThatFits(CGSize(width: explanation.bounds.size.width, height: .greatestFiniteMagnitude)).height
        XCTAssertGreaterThanOrEqual(explanation.bounds.size.height + 1, needed, "the explanation is cut off")

        let scrollView = try XCTUnwrap(subviews(of: UIScrollView.self, in: viewController.view).first)
        XCTAssertGreaterThan(scrollView.contentSize.height, scrollView.bounds.size.height, "at this size the page has to scroll")
        let update = viewController.updateButton.convert(viewController.updateButton.bounds, to: scrollView)
        let exit = viewController.viewChatsOnlyButton.convert(viewController.viewChatsOnlyButton.bounds, to: scrollView)
        XCTAssertLessThanOrEqual(explanation.convert(explanation.bounds, to: scrollView).maxY, update.minY)
        XCTAssertLessThanOrEqual(exit.maxY, scrollView.contentSize.height, "the way to the chats can be scrolled to")
    }

    func testWhenEverythingFitsTheButtonsStayAtTheBottom() throws {
        let (viewController, window) = try laidOutPage(at: .large)
        defer { window.isHidden = true }

        let scrollView = try XCTUnwrap(subviews(of: UIScrollView.self, in: viewController.view).first)
        XCTAssertLessThanOrEqual(scrollView.contentSize.height, scrollView.bounds.size.height + 0.5, "at the default size nothing scrolls")
        let exit = viewController.viewChatsOnlyButton.convert(viewController.viewChatsOnlyButton.bounds, to: viewController.view)
        XCTAssertEqual(exit.maxY, viewController.view.bounds.maxY - viewController.view.safeAreaInsets.bottom - 16, accuracy: 0.5)
    }

    func testVoiceOverStaysOnThePage() {
        // 没上锁时下面是会话列表，旁白不能读到、点到它（taishi 审查 b15 要改 2）。
        let viewController = TellomiUpdateRequiredAppBlockingViewController(openUpdatePage: {}, openNotes: { _ in }, viewChatsOnly: {})
        viewController.loadViewIfNeeded()
        XCTAssertTrue(viewController.view.accessibilityViewIsModal)
    }

    // MARK: - 只读模式的说法（#1143 需求 3.4，taishi 审查包 11）

    /// 服务端判定（499）时并没有过期：会话列表横幅说「需要更新才能继续收发消息」，不说「已过期」。
    func testReadOnlyBannerSaysAnUpdateIsNeededInsteadOfExpired() {
        let text = ExpirationNagView.ExpirationMessage.appExpired.text
        XCTAssertEqual(text, OWSLocalizedString("EXPIRATION_ERROR_TELLOMI", value: "Update Tellomi to keep sending and receiving messages.", comment: ""))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("expired"), text)
    }

    /// 会话输入框同理：「此版本需要更新才能收发消息。立即更新」，「立即更新」照旧是可点的链接。
    func testReadOnlyInputSaysAnUpdateIsNeededAndKeepsTheUpdateLink() {
        let text = ConversationViewController.appExpiredErrorText()
        let updateNow = OWSLocalizedString("APP_EXPIRED_BOTTOM_UPDATE", comment: "")
        XCTAssertFalse(text.string.localizedCaseInsensitiveContains("expired"), text.string)
        XCTAssertTrue(text.string.hasSuffix(updateNow), text.string)

        let linkRange = (text.string as NSString).range(of: updateNow)
        // UIColor.Signal.link 每次取都是新的动态颜色对象，要按同一种外观解析后再比
        let light = UITraitCollection(userInterfaceStyle: .light)
        let color = text.attribute(.foregroundColor, at: linkRange.location, effectiveRange: nil) as? UIColor
        XCTAssertEqual(color?.resolvedColor(with: light), UIColor.Signal.link.resolvedColor(with: light))
    }
}

private final class FakeUpdateRequiredBlockHost: TellomiUpdateRequiredBlockHost {
    var isUpdateRequiredBlockActive = false
    var updateRequiredViewChatsOnlyHandler: (@MainActor () -> Void)?
    var updateRequiredPageInfo: TellomiUpdateRequiredPageInfo = .serverRejected
}

/// Tellomi（tellomi/tellomi#1491）：更新清单的采信、判档和撤销（需求 app-update-and-version-policy.md §3.2.1）。和 Android 的
/// `UpdateManifestTest` / `UpdateManifestsTest` 同一套用例。
final class TellomiUpdateManifestTest: XCTestCase {

    /// 跨语言夹具：超级仓库 `scripts/release/update_manifest.py` 组装、`scripts/links/xeddsa.py` 用测试私钥 0x5c × 32 签的（不是发布密钥）。
    private static let fixtureKey = Data(hex: "05d3baf56cb00bfcbb41a459bd640f05a77ed6110809bf5f21be1a08e51dff7409")!
    private static let fixtureSignature = "7848bd983cb6a6d7a3d750d07e0ec9b2e1d373b43f45756357ae17c45ab654867745e313b1cb74752563d47d58f8721fb4746df3e74aaca6119746e45dbc1b09"
    private static let fixture = Data(
        (
            [
            #"{"#,
            #"  "channel": "testflight","#,
            #"  "issuedAt": "2026-10-13T12:00:00Z","#,
            #"  "latest": {"#,
            #"    "build": 6,"#,
            #"    "releaseDate": "2026-10-13T12:00:00Z","#,
            #"    "url": "https://testflight.apple.com/join/AbCdEfGh","#,
            #"    "version": "0.1.1""#,
            #"  },"#,
            #"  "name": "tellomi-update","#,
            #"  "notesUrl": "https://www.tellomi.app/changelog/#ios","#,
            #"  "platform": "ios","#,
            #"  "recommendedMinBuild": 6,"#,
            #"  "requiredFrom": "2026-10-20T00:00:00Z","#,
            #"  "requiredMinBuild": 5,"#,
            #"  "requiredReason": "security","#,
            #"  "schema": 1,"#,
            #"  "serial": 20261013120000"#,
            #"}"#,
            ].joined(separator: "\n") + "\n"
        ).utf8,
    )

    private func accept(
        _ data: Data,
        _ signature: String,
        key: Data = fixtureKey,
        platform: String = "ios",
        channel: String = "testflight",
        cachedSerial: UInt64 = 0,
    ) -> TellomiUpdateManifest? {
        TellomiUpdateManifest.accept(data: data, signatureHex: signature, publicKey: key, platform: platform, channel: channel, cachedSerial: cachedSerial)
    }

    func testAManifestSignedByTheReleaseScriptIsAcceptedWithEveryField() throws {
        let manifest = try XCTUnwrap(accept(Self.fixture, Self.fixtureSignature))

        XCTAssertEqual(manifest.serial, 20261013120000)
        XCTAssertEqual(manifest.latest, .init(version: "0.1.1", build: 6, url: URL(string: "https://testflight.apple.com/join/AbCdEfGh")))
        XCTAssertEqual(manifest.recommendedMinBuild, 6)
        XCTAssertEqual(manifest.requiredMinBuild, 5)
        XCTAssertEqual(manifest.requiredReason, .security)
        XCTAssertEqual(manifest.requiredFrom, ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z"))
        XCTAssertEqual(manifest.notesUrl, URL(string: "https://www.tellomi.app/changelog/#ios"))
    }

    func testOneChangedByteIsRejected() throws {
        var tampered = Self.fixture
        let range = try XCTUnwrap(tampered.range(of: Data(#""build": 6"#.utf8)))
        tampered[range.upperBound - 1] = UInt8(ascii: "7")

        XCTAssertNil(accept(tampered, Self.fixtureSignature))
    }

    func testOtherKeysAndMalformedSignaturesAreRejected() {
        XCTAssertNil(accept(Self.fixture, Self.fixtureSignature, key: TellomiUpdateManifests.publicKey), "the production key must not accept the test fixture")
        XCTAssertNil(accept(Self.fixture, Self.fixtureSignature, key: PrivateKey.generate().publicKey.serialize()))
        XCTAssertNil(accept(Self.fixture, "not hex"))
        XCTAssertNil(accept(Self.fixture, "abcd"))
        XCTAssertNil(accept(Self.fixture, ""))
    }

    func testAManifestForAnotherPlatformOrChannelIsRejected() {
        XCTAssertNil(accept(Self.fixture, Self.fixtureSignature, platform: "android"))
        XCTAssertNil(accept(Self.fixture, Self.fixtureSignature, channel: "appstore"))
    }

    func testAnOlderSerialIsRejectedAndTheSameOneIsAccepted() {
        XCTAssertNil(accept(Self.fixture, Self.fixtureSignature, cachedSerial: 20261013120001))
        XCTAssertNotNil(accept(Self.fixture, Self.fixtureSignature, cachedSerial: 20261013120000))
    }

    func testOnlyTestFlightOrAppStoreLinksBecomeTheUpdateChannel() {
        func signed(url: String) -> TellomiUpdateManifest? {
            let key = PrivateKey.generate()
            let data = Data(#"{"name":"tellomi-update","schema":1,"platform":"ios","channel":"testflight","serial":1,"latest":{"version":"0.1.1","build":6,"url":"\#(url)"},"recommendedMinBuild":0,"requiredMinBuild":0}"#.utf8)
            return TellomiUpdateManifest.accept(
                data: data,
                signatureHex: key.generateSignature(message: data).hexadecimalString,
                publicKey: key.publicKey.serialize(),
                platform: "ios",
                channel: "testflight",
                cachedSerial: 0,
            )
        }

        XCTAssertEqual(signed(url: "https://testflight.apple.com/join/AbCdEfGh")?.latest.url, URL(string: "https://testflight.apple.com/join/AbCdEfGh"))
        XCTAssertEqual(signed(url: "https://apps.apple.com/app/tellomi/id1234567890")?.latest.url, URL(string: "https://apps.apple.com/app/tellomi/id1234567890"))
        // 签名对、但链接不是 TestFlight / App Store：清单照收，链接不当渠道（不会把人送去装别的东西）
        XCTAssertNotNil(signed(url: "https://example.com/tellomi.ipa"))
        XCTAssertNil(signed(url: "https://example.com/tellomi.ipa")?.latest.url)
        XCTAssertNil(signed(url: "http://testflight.apple.com/join/AbCdEfGh")?.latest.url)
    }

    func testTiersFollowTheSpecOrder() {
        let now = Date()
        func manifest(recommended: UInt64 = 0, required: UInt64 = 0, requiredFrom: Date? = nil) -> TellomiUpdateManifest {
            TellomiUpdateManifest(
                serial: 1,
                latest: .init(version: "0.1.1", build: 8, url: nil),
                recommendedMinBuild: recommended,
                requiredMinBuild: required,
                requiredReason: required > 0 ? .security : nil,
                requiredFrom: requiredFrom,
                notesUrl: nil,
            )
        }

        XCTAssertEqual(manifest(required: 6).tier(build: 5, now: now), .required)
        XCTAssertEqual(manifest(required: 6, requiredFrom: now.addingTimeInterval(-.day)).tier(build: 5, now: now), .required)
        // 必须但还没到生效时间 → 先推荐（需求 3.1）
        XCTAssertEqual(manifest(required: 6, requiredFrom: now.addingTimeInterval(.day)).tier(build: 5, now: now), .recommended)
        XCTAssertEqual(manifest(recommended: 6).tier(build: 5, now: now), .recommended)
        XCTAssertEqual(manifest(recommended: 6, required: 5).tier(build: 6, now: now), .optional)
        XCTAssertEqual(manifest().tier(build: 8, now: now), .none)
        XCTAssertEqual(manifest(required: 6).tier(build: 6, now: now), .optional, "equal to the threshold is not below it")
    }

    // MARK: - Read-only state

    private func manifest(serial: UInt64, required: UInt64 = 0) -> TellomiUpdateManifest {
        TellomiUpdateManifest(
            serial: serial,
            latest: .init(version: "0.1.1", build: 8, url: nil),
            recommendedMinBuild: 0,
            requiredMinBuild: required,
            requiredReason: required > 0 ? .security : nil,
            requiredFrom: nil,
            notesUrl: nil,
        )
    }

    private func reconcile(_ manifest: TellomiUpdateManifest?, isReadOnly: Bool, since: UInt64?, isBuildTooOld: Bool = false) -> TellomiUpdateManifests.Reconciled {
        TellomiUpdateManifests.reconcile(manifest: manifest, build: 5, now: Date(), isReadOnly: isReadOnly, isBuildTooOld: isBuildTooOld, readOnlySinceSerial: since)
    }

    func testARequiredManifestMakesThisVersionReadOnly() {
        XCTAssertEqual(reconcile(manifest(serial: 10, required: 8), isReadOnly: false, since: nil), .init(action: .expire, readOnlySinceSerial: 10))
    }

    func testANewerManifestThatNoLongerRequiresTheUpdateReleasesTheBlock() {
        XCTAssertEqual(reconcile(manifest(serial: 11), isReadOnly: true, since: 10), .init(action: .release, readOnlySinceSerial: nil))
    }

    func testTheManifestCachedWhenTheServerBlockedUsDoesNotReleaseIt() {
        XCTAssertEqual(reconcile(manifest(serial: 10), isReadOnly: true, since: nil), .init(action: .none, readOnlySinceSerial: 10))
        XCTAssertEqual(reconcile(manifest(serial: 10), isReadOnly: true, since: 10), .init(action: .none, readOnlySinceSerial: 10))
    }

    func testAServerBlockWithNoManifestWaitsForTheFirstOne() {
        XCTAssertEqual(reconcile(nil, isReadOnly: true, since: nil), .init(action: .none, readOnlySinceSerial: 0))
        XCTAssertEqual(reconcile(manifest(serial: 1), isReadOnly: true, since: 0).action, .release)
    }

    func testANewerManifestThatStillRequiresTheUpdateKeepsTheBlock() {
        XCTAssertEqual(reconcile(manifest(serial: 12, required: 8), isReadOnly: true, since: 10), .init(action: .none, readOnlySinceSerial: 10))
    }

    func testAnExpiredBuildStaysReadOnlyWhateverTheManifestSays() {
        XCTAssertEqual(reconcile(manifest(serial: 99), isReadOnly: true, since: 10, isBuildTooOld: true).action, .none)
    }

    func testAWithdrawnRequirementLiftsAServerExpiryButNotAnOldBuild() async {
        let db = InMemoryDB()
        let appExpiry = AppExpiry.forUnitTests(buildDate: Date())
        await appExpiry.setHasAppExpiredAtCurrentVersion(db: db)
        XCTAssertTrue(appExpiry.isExpired(now: Date()))
        let released = await appExpiry.tellomiReleaseServerExpiry(now: Date(), db: db)
        XCTAssertTrue(released)
        XCTAssertFalse(appExpiry.isExpired(now: Date()))

        let oldBuild = AppExpiry.forUnitTests(buildDate: Date().addingTimeInterval(-AppExpiry.defaultExpirationInterval - .day))
        let releasedOld = await oldBuild.tellomiReleaseServerExpiry(now: Date(), db: db)
        XCTAssertFalse(releasedOld)
        XCTAssertTrue(oldBuild.isExpired(now: Date()))
    }

    func testChecksAreThrottledToSixHoursExceptWhileReadOnly() {
        let now = Date()
        XCTAssertFalse(TellomiUpdateManifests.shouldCheck(now: now, lastChecked: now.addingTimeInterval(-5 * .hour), isReadOnly: false))
        XCTAssertTrue(TellomiUpdateManifests.shouldCheck(now: now, lastChecked: now.addingTimeInterval(-6 * .hour), isReadOnly: false))
        XCTAssertTrue(TellomiUpdateManifests.shouldCheck(now: now, lastChecked: now, isReadOnly: true))
        XCTAssertTrue(TellomiUpdateManifests.shouldCheck(now: now, lastChecked: nil, isReadOnly: false))
        XCTAssertTrue(TellomiUpdateManifests.shouldCheck(now: now, lastChecked: now.addingTimeInterval(.hour), isReadOnly: false), "the clock went backwards")
    }

    func testTheBuildNumberIsTheFourthVersionComponent() {
        XCTAssertEqual(TellomiUpdateManifests.currentBuild(appVersion: "0.1.0.5"), 5)
        XCTAssertNil(TellomiUpdateManifests.currentBuild(appVersion: "0.1.0"))
    }

    func testTheEmbeddedPublicKeyIsTheReleaseKeyEveryClientTrusts() {
        // 与 clients/desktop/config/default.json 的 updatesPublicKey、超级仓库 update_manifest.py、安卓 UpdateManifests 同一把
        XCTAssertEqual(TellomiUpdateManifests.publicKey.hexadecimalString, "0569dca6fde7f7dd8e03eee459d54b385b4067230e4c0452eb0c6fc3d2644f914c")
    }
}
