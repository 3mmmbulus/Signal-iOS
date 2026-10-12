//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 官网卡标题后面的「官方」小徽标（card-visual §5.2；只有这张卡带，是防冒充的标记）：画出来的字和底在每一种外观下都要读得清（≥ 4.5:1）。
///
/// 徽标是个圆角小药丸，当作文字附件放进标题文字里（`CVLinkPreviewView.swift` 的 `TellomiOfficialBadge`）。它的取色不能只看「配置那一刻」的
/// `UITraitCollection.current`：设置 > 外观里 App 主题和系统外观可以不一样（窗口的 `overrideUserInterfaceStyle` 是 App 主题，
/// `UITraitCollection.current` 是系统外观），主题也可以在卡片配好以后再切；底也不能指望透出下面的卡片（自己发的卡盖在聊天色上）。
/// 这里按会话页同一条渲染路径（`CVLoader.buildStandaloneRenderItem` + `CVCellView`）排成**真实的消息 cell**，把这些组合都试一遍，
/// 量画出来的像素：底 = 出现最多的颜色，字 = 跟底对比最强的颜色。
///
/// 截图和读数只在 `TELLOMI_SHOTS=1` 时存（xcodebuild 用 `TEST_RUNNER_TELLOMI_SHOTS=1` 传进来），写到 `TELLOMI_SHOTS_DIR/badge/`。断言总是跑。
final class TellomiOfficialBadgeContrastTests: XCTestCase {

    private var oldContext: (any AppContext)!
    private var report = ""

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
        // 让 Theme 回到「跟系统走」，别把强制的外观带给后面的用例
        Theme.setIsDarkThemeEnabledForTests(nil)
        MockSSKEnvironment.deactivate(oldContext: self.oldContext)
        super.tearDown()
    }

    private func read<T>(block: (DBReadTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.read(block: block)
    }

    private func write<T>(block: (DBWriteTransaction) throws -> T) rethrows -> T {
        return try SSKEnvironment.shared.databaseStorageRef.write(block: block)
    }

    // MARK: - 组合

    /// 文字对比度的及格线（WCAG AA，小字）。
    private static let minimumContrast: CGFloat = 4.5

    private static let cardWidth: CGFloat = 402

    private struct Scenario {
        let name: String
        var incoming = true
        /// 窗口的外观 = App 主题（设置 > 外观）。
        let window: UIUserInterfaceStyle
        /// 配置 cell 那一刻的 `UITraitCollection.current` = 系统外观。
        let configuredUnder: UIUserInterfaceStyle
        /// 配好以后把窗口切到这个外观（不重新配置），再量一次：主题在卡片配好以后切换。
        var flipTo: UIUserInterfaceStyle?
    }

    /// 外观一致（真机上的常态）。
    private static let matching: [Scenario] = [
        Scenario(name: "incoming, light / light", window: .light, configuredUnder: .light),
        Scenario(name: "incoming, dark / dark", window: .dark, configuredUnder: .dark),
    ]

    /// App 主题和系统外观不一样：系统浅色 + App 主题「深色」、系统深色 + App 主题「浅色」。
    private static let mismatched: [Scenario] = [
        Scenario(name: "incoming, app theme dark + system light", window: .dark, configuredUnder: .light),
        Scenario(name: "incoming, app theme light + system dark", window: .light, configuredUnder: .dark),
    ]

    /// 卡片配好以后主题才变（系统自动深色 / 在设置里切主题，屏幕上已经有的 cell 不重新配置）。
    private static let flipped: [Scenario] = [
        Scenario(name: "incoming, light then dark", window: .light, configuredUnder: .light, flipTo: .dark),
        Scenario(name: "incoming, dark then light", window: .dark, configuredUnder: .dark, flipTo: .light),
    ]

    /// 自己发出去的官网卡：底是默认聊天色（蓝）上再盖一层白，不是会话页的灰，徽标自己的底不能指望透出来的颜色。
    private static let outgoing: [Scenario] = [
        Scenario(name: "outgoing, light / light", incoming: false, window: .light, configuredUnder: .light),
        Scenario(name: "outgoing, dark / dark", incoming: false, window: .dark, configuredUnder: .dark),
        Scenario(name: "outgoing, app theme dark + system light", incoming: false, window: .dark, configuredUnder: .light),
        Scenario(name: "outgoing, app theme light + system dark", incoming: false, window: .light, configuredUnder: .dark),
    ]

    // MARK: - 用例

    @MainActor
    func testBadgeIsReadableWhenTheAppearancesMatch() throws {
        try check(Self.matching, label: "matching")
    }

    /// 设置 > 外观允许 App 主题和系统外观不一样；这时窗口是深色、`UITraitCollection.current` 是浅色（或反过来）。
    @MainActor
    func testBadgeIsReadableWhenTheAppThemeAndTheSystemAppearanceDiffer() throws {
        try check(Self.mismatched, label: "mismatched")
    }

    @MainActor
    func testBadgeFollowsAThemeChangeAfterTheCardIsConfigured() throws {
        try check(Self.flipped, label: "flipped")
    }

    @MainActor
    func testBadgeIsReadableOnAnOutgoingCard() throws {
        try check(Self.outgoing, label: "outgoing")
    }

    @MainActor
    private func check(_ scenarios: [Scenario], label: String) throws {
        let thread = write { tx -> TSContactThread in
            let thread = ContactThreadFactory().create(transaction: tx)
            if let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
        for scenario in scenarios {
            let message = try insert(thread: thread, incoming: scenario.incoming)
            let hosted = try host(message: message, thread: thread, scenario: scenario)
            defer { hosted.tearDown() }

            var readings = [(String, Reading?)]()
            let configured = try measure(hosted, name: scenario.name, suffix: "configured")
            readings.append(("configured", configured))
            if let flipTo = scenario.flipTo {
                hosted.window.overrideUserInterfaceStyle = flipTo
                hosted.window.backgroundColor = flipTo == .dark ? .black : .white
                Theme.setIsDarkThemeEnabledForTests(flipTo == .dark)
                hosted.window.layoutIfNeeded()
                let flipped = try measure(hosted, name: scenario.name, suffix: "flipped")
                readings.append(("after flip to \(flipTo == .dark ? "dark" : "light")", flipped))
            }
            for (when, reading) in readings {
                guard let reading else {
                    XCTFail("\(scenario.name) (\(when))：量不到徽标的像素")
                    continue
                }
                report += "\(scenario.name) [\(when)]: text \(Self.hex(reading.text)) on \(Self.hex(reading.pill)) = \(String(format: "%.2f", reading.ratio)):1\n"
                XCTAssertGreaterThanOrEqual(
                    reading.ratio,
                    Self.minimumContrast,
                    "\(scenario.name) (\(when))：「官方」徽标的字 \(Self.hex(reading.text)) 落在底 \(Self.hex(reading.pill)) 上只有 \(String(format: "%.2f", reading.ratio)):1，应 ≥ \(Self.minimumContrast):1",
                )
            }
        }
        if shooting {
            try writeReport(named: "badge-report-\(label).txt")
        }
    }

    // MARK: - 量

    private struct Reading {
        let pill: UIColor
        let text: UIColor
        let ratio: CGFloat
        /// 出现最多的颜色（药丸）占这一块像素的比例。
        let share: CGFloat
        /// 这一块矩形的四个角上的像素都不是药丸色（药丸是圆角的，角在它外面）。
        let cornersOutsidePill: Bool
    }

    /// 找到标题里带附件（徽标）的那个标签，算出附件在窗口里的位置，量那一块的像素。
    @MainActor
    private func measure(_ hosted: Hosted, name: String, suffix: String) throws -> Reading? {
        let found = try XCTUnwrap(Self.findBadge(in: hosted.cellView), "\(name)：标题里应该有「官方」徽标（官网卡）")
        let rect = Self.rect(of: found, inWindow: hosted.window)
        let image = render(hosted)
        if shooting {
            try save(image, name: "badge-\(Self.slug(name))-\(suffix).png")
        }
        let reading = Self.pixelContrast(in: image, rect: rect)
        // 位置算得对不对（量到别处也可能「对比度很高」，比如标题的黑字，所以要单独核）：
        // 这一块里出现最多的颜色应该是药丸（占大半），而矩形的四个角在药丸圆角的外面，是药丸外面的卡底，不是药丸色
        if let reading {
            XCTAssertGreaterThan(reading.share, 0.5, "\(name)：量的不是药丸（\(rect)），出现最多的颜色 \(Self.hex(reading.pill)) 只占 \(reading.share)")
            XCTAssertTrue(reading.cornersOutsidePill, "\(name)：量的不是药丸（\(rect)），矩形的四个角应该在药丸的圆角外面")
        }
        return reading
    }

    private static func slug(_ name: String) -> String {
        let mapped = name.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return mapped.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
    }

    private struct Badge {
        let label: UILabel
        let range: NSRange
        let attachment: NSTextAttachment
    }

    private static func findBadge(in view: UIView) -> Badge? {
        if let label = view as? UILabel, let attributed = label.attributedText {
            var found: Badge?
            attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, stop in
                if let attachment = value as? NSTextAttachment {
                    found = Badge(label: label, range: range, attachment: attachment)
                    stop.pointee = true
                }
            }
            if let found {
                return found
            }
        }
        for subview in view.subviews {
            if let found = findBadge(in: subview) {
                return found
            }
        }
        return nil
    }

    /// 徽标（文字附件）在窗口坐标里的矩形（点）：用标签自己的字体、行数、截断方式在 TextKit 里排一遍，取附件所在字形的基线位置，
    /// 再按附件的 `bounds`（原点是相对基线的偏移）摆出来；不用字形的外接矩形，那是整行的高度，比药丸高。
    @MainActor
    private static func rect(of badge: Badge, inWindow window: UIWindow) -> CGRect {
        let label = badge.label
        let storage = NSTextStorage(attributedString: label.attributedText ?? NSAttributedString())
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = label.numberOfLines
        container.lineBreakMode = label.lineBreakMode
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let glyphIndex = manager.glyphIndexForCharacter(at: badge.range.location)
        let line = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        let location = manager.location(forGlyphAt: glyphIndex)
        let bounds = badge.attachment.bounds
        let baseline = line.minY + location.y
        let rect = CGRect(x: line.minX + location.x, y: baseline - (bounds.origin.y + bounds.size.height), width: bounds.size.width, height: bounds.size.height)
        return label.convert(rect, to: window)
    }

    /// 一块像素里字和底的对比度：底 = 出现最多的颜色（药丸），字 = 跟底对比最强的颜色（抗锯齿的中间色比不过纯色字）。
    private static func pixelContrast(in image: UIImage, rect: CGRect) -> Reading? {
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
        guard let backgroundEntry = counts.max(by: { $0.value < $1.value }) else {
            return nil
        }
        let background = color(backgroundEntry.key)
        guard let textKey = counts.keys.max(by: { contrast(color($0), background) < contrast(color($1), background) }) else {
            return nil
        }
        func key(x: Int, y: Int) -> UInt32 {
            let index = (y * part.width + x) * 4
            return (UInt32(buffer[index]) << 16) | (UInt32(buffer[index + 1]) << 8) | UInt32(buffer[index + 2])
        }
        let corners = [key(x: 0, y: 0), key(x: part.width - 1, y: 0), key(x: 0, y: part.height - 1), key(x: part.width - 1, y: part.height - 1)]
        return Reading(
            pill: background,
            text: color(textKey),
            ratio: contrast(color(textKey), background),
            share: CGFloat(backgroundEntry.value) / CGFloat(buffer.count / 4),
            cornersOutsidePill: corners.allSatisfy { $0 != backgroundEntry.key },
        )
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

    private static func hex(_ color: UIColor) -> String {
        let (red, green, blue) = rgb(color)
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    // MARK: - 建消息

    private static let officialUrl = "https://tellomi.app/download"

    /// 官网卡（`tellomi.official`）：消息就是这条链接，预览标题随便写（卡片上显示的是固定文字，不用发送端写的）。
    @MainActor
    private func insert(thread: TSContactThread, incoming: Bool) throws -> TSMessage {
        let authorAci = try XCTUnwrap(thread.contactAddress.aci)
        return write { tx -> TSMessage in
            let body = DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                MessageBody(text: Self.officialUrl, ranges: .empty),
                tx: tx,
            )
            let linkPreview = OWSLinkPreview(
                urlString: Self.officialUrl,
                title: "Tellomi",
                previewDescription: nil,
                date: nil,
                rich: nil,
            )
            if incoming {
                let message = TSIncomingMessageBuilder.withDefaultValues(
                    thread: thread,
                    timestamp: Date.ows_millisecondTimestamp(),
                    authorAci: authorAci,
                    messageBody: body,
                    linkPreview: linkPreview,
                ).build()
                message.anyInsert(transaction: tx)
                return message
            }
            // 「已发出」的样子：当作另一台设备发的，画出来就是发完之后的稳定状态（同 AlbumViewerScreenshotTests）
            let message = TSOutgoingMessageBuilder.withDefaultValues(
                thread: thread,
                timestamp: Date.ows_millisecondTimestamp(),
                messageBody: body,
                wasNotCreatedLocally: true,
                linkPreview: linkPreview,
            ).build(transaction: tx)
            message.anyInsert(transaction: tx)
            message.updateWithSentRecipients([authorAci], wasSentByUD: false, tx: tx)
            return message
        }
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

    /// 窗口的外观 = App 主题，`Theme` 跟着它走（气泡、卡片底才和窗口一致）；配置 cell 那一刻的 `UITraitCollection.current` = 系统外观。
    /// 真机上 `OWSWindow` 把 App 主题设成窗口的 `overrideUserInterfaceStyle`，系统外观则是没有覆盖时的 `UITraitCollection.current`。
    @MainActor
    private func host(message: TSMessage, thread: TSThread, scenario: Scenario) throws -> Hosted {
        Theme.setIsDarkThemeEnabledForTests(scenario.window == .dark)
        var made: Result<Hosted, Error>?
        UITraitCollection(userInterfaceStyle: scenario.configuredUnder).performAsCurrent {
            made = Result { try makeHosted(message: message, thread: thread, window: scenario.window) }
        }
        return try XCTUnwrap(made).get()
    }

    @MainActor
    private func makeHosted(message: TSMessage, thread: TSThread, window style: UIUserInterfaceStyle) throws -> Hosted {
        let width = Self.cardWidth
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
        // y = 150：不压在屏幕顶部的安全区上（别的离屏测试也这样放）
        let window = UIWindow(frame: CGRect(x: 0, y: 150, width: width, height: cellHeight + 24))
        window.overrideUserInterfaceStyle = style
        window.backgroundColor = style == .dark ? .black : .white
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

    // MARK: - 存截图和读数

    private var shooting: Bool { ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" }

    private func shotsDirectory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let url = URL(fileURLWithPath: root).appendingPathComponent("badge")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func save(_ image: UIImage, name: String) throws {
        try XCTUnwrap(image.pngData()).write(to: shotsDirectory().appendingPathComponent(name))
    }

    private func writeReport(named name: String) throws {
        try report.write(to: shotsDirectory().appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
}
