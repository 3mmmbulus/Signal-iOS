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

/// card-visual §3.3 / §7.3、ADR-0063 §8.1 第 6 行：还没接受的会话（消息请求）里，收到的链接只画「域名卡」——
/// 链接图标 + 可注册域名，不染色、不响应点击、不显示发送端写的任何东西、不读预览图、正文里的链接文字也不隐藏；接受以后才完整显示。
/// 跑的是会话页同一条构建路径（`CVLoader.buildStandaloneComponentState` → `CVComponentState.build`），不是只测一个函数。
final class TellomiMessageRequestCardTest: SignalBaseTest {

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    // MARK: - 夹具

    private struct Preview {
        var title: String?
        var description: String?
        var rich: Data?
        var url: String
    }

    /// 发送端写的、想骗人的东西：这些字任何一个出现在域名卡上都是错的。
    private static let forged = ["冒充：Tellomi 官方客服，请立即回复验证码", "点击领取奖励", "淘宝商品标题", "发送端写的群名", "冒充：京东客服退款，请点击"]

    private func makeThread(accepted: Bool) -> TSContactThread {
        return write { tx in
            let thread = ContactThreadFactory().create(transaction: tx)
            if accepted, let aci = thread.contactAddress.aci {
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(&recipient, userProfileWriter: .debugging, tx: tx)
            }
            return thread
        }
    }

    /// 会话页用的是从库里重新取出来的线程（发消息之后 `shouldThreadBeVisible` 才为真），这里也一样。
    private func isPendingRequest(_ thread: TSThread) -> Bool {
        return read { tx in
            guard let latest = TSThread.anyFetch(uniqueId: thread.uniqueId, transaction: tx) else {
                return false
            }
            return ThreadViewModel(thread: latest, forChatList: false, transaction: tx).hasPendingMessageRequest
        }
    }

    @discardableResult
    private func insertIncoming(body: String, preview: Preview?, thread: TSContactThread) throws -> TSIncomingMessage {
        let authorAci = try XCTUnwrap(thread.contactAddress.aci)
        return write { tx in
            let messageBody = DependenciesBridge.shared.attachmentContentValidator.truncatedMessageBodyForInlining(
                MessageBody(text: body, ranges: .empty),
                tx: tx,
            )
            let linkPreview = preview.map {
                OWSLinkPreview(urlString: $0.url, title: $0.title, previewDescription: $0.description, date: nil, rich: $0.rich)
            }
            let builder: TSIncomingMessageBuilder = .withDefaultValues(
                thread: thread,
                timestamp: Date.ows_millisecondTimestamp(),
                authorAci: authorAci,
                messageBody: messageBody,
                linkPreview: linkPreview,
            )
            let message = builder.build()
            message.anyInsert(transaction: tx)
            return message
        }
    }

    /// 预览图已经下载好、躺在库里：域名卡也不能读它。
    @MainActor
    private func attachDownloadedPreviewImage(to message: TSMessage, thread: TSThread) async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { context in
            UIColor(hue: 0.1, saturation: 0.9, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }.pngData()!
        let pending = try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
            png,
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

    private func richBytes(kind: String, provider: String, level: UInt32 = 1) -> Data? {
        let builder = SSKProtoRichContent.builder()
        builder.setKind(kind)
        builder.setProvider(provider)
        builder.setSchema(1)
        builder.setLevel(level)
        return try? builder.buildSerializedData()
    }

    @MainActor
    private func componentState(_ message: TSMessage) throws -> CVComponentState {
        return try read { tx in
            let latest = try XCTUnwrap(TSMessage.anyFetch(uniqueId: message.uniqueId, transaction: tx) as? TSMessage)
            return try XCTUnwrap(CVLoader.buildStandaloneComponentState(
                interaction: latest,
                spoilerState: SpoilerRenderState(),
                transaction: tx,
            ))
        }
    }

    private func requireBundledRegistry() throws {
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
    }

    // MARK: - 断言

    /// 只有域名：标题位是可注册域名，没有副行、域名行、图、随包图标、第一方卡的东西，不染色，不响应点击，不隐藏正文。
    private func assertDomainCard(
        _ componentState: CVComponentState,
        domain: String,
        lookalike: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line,
    ) throws {
        let linkPreview = try XCTUnwrap(componentState.linkPreview, "应该有一张域名卡", file: file, line: line)
        let state = try XCTUnwrap(linkPreview.state as? TellomiLinkPreviewCardState, "\(linkPreview.state)", file: file, line: line)
        XCTAssertTrue(state.isPlainLink, file: file, line: line)
        XCTAssertEqual(state.title, domain, file: file, line: line)
        XCTAssertNil(state.displayDomain, "域名只写一次，放在标题位", file: file, line: line)
        XCTAssertNil(state.previewDescription, file: file, line: line)
        XCTAssertEqual(state.isLookalike, lookalike, file: file, line: line)
        // 没有图：不读预览图附件，也没有随包图标
        XCTAssertEqual(state.imageState, .none, file: file, line: line)
        XCTAssertEqual(state.imagePixelSize, .zero, file: file, line: line)
        XCTAssertNil(state.imageCacheKey(thumbnailQuality: .small), file: file, line: line)
        XCTAssertNil(state.bundledIcon, file: file, line: line)
        // 没有第一方卡的头像、名字、按钮
        XCTAssertNil(state.firstParty, file: file, line: line)
        // 不染色
        XCTAssertNil(state.tintColors, file: file, line: line)
        XCTAssertNil(state.layout, file: file, line: line)
        // 不响应点击；正文里的链接文字不隐藏
        XCTAssertTrue(state.isInert, file: file, line: line)
        XCTAssertFalse(CVComponentLinkPreview.respondsToTap(state), file: file, line: line)
        XCTAssertFalse(state.isCardOnly, file: file, line: line)
        XCTAssertNotNil(componentState.bodyText, "正文还在", file: file, line: line)
        // 统一样式（产品经理 2026-10-19）：只有域名的横条（域名 + 指南针），中性灰，不取图标主色；照原样留在气泡里（不代替气泡）
        XCTAssertEqual(state.cardStyle, .domainStrip, file: file, line: line)
        XCTAssertEqual(state.cardText?.title, nil, file: file, line: line)
        XCTAssertEqual(state.cardText?.domain, domain, file: file, line: line)
        XCTAssertNil(state.stripColor, file: file, line: line)
        XCTAssertEqual(componentState.tellomiLinkCardPlacement, .inBubble, file: file, line: line)
        // 发送端写的东西一个字都不在
        let texts = [state.title, state.previewDescription, state.displayDomain].compactMap { $0 }
        for word in Self.forged {
            XCTAssertFalse(texts.contains { $0.contains(word) }, "\(word)", file: file, line: line)
        }
    }

    // MARK: - 未接受：域名卡

    @MainActor
    func testAThirdPartyLinkIsJustItsDomainAndTheSendersWordsAreNotShown() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let url = "https://www.wikipedia.org/wiki/Tellomi"
        let message = try insertIncoming(
            body: url,
            preview: Preview(title: "冒充：Tellomi 官方客服，请立即回复验证码", description: "点击领取奖励", rich: nil, url: url),
            thread: thread,
        )
        XCTAssertTrue(isPendingRequest(thread), "夹具要真的是消息请求")
        try assertDomainCard(try componentState(message), domain: "wikipedia.org")
    }

    @MainActor
    func testTheBodyTextStaysEvenWhenTheMessageIsOnlyTheLink() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let url = "https://www.wikipedia.org/wiki/Tellomi"
        let message = try insertIncoming(body: url, preview: Preview(title: "标题", description: nil, rich: nil, url: url), thread: thread)
        let componentState = try componentState(message)
        let state = try XCTUnwrap(componentState.linkPreview?.state as? TellomiLinkPreviewCardState)
        XCTAssertFalse(state.isCardOnly, "整条消息只有这条链接时，接受以后只显示卡片；消息请求里正文文字保持原样")
        XCTAssertNotNil(componentState.bodyText)
    }

    @MainActor
    func testABrandShellIsJustItsDomainToo() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let url = "https://item.taobao.com/item.htm?id=674169489573"
        let message = try insertIncoming(
            body: "看看这个 \(url) 好东西",
            preview: Preview(title: "淘宝商品标题", description: nil, rich: richBytes(kind: "product", provider: "taobao"), url: url),
            thread: thread,
        )
        try assertDomainCard(try componentState(message), domain: "taobao.com")
    }

    /// 认领但抓页面的平台（京东，2026-10-19）：发送端不带 rich、带页面自己的标题；消息请求里一样只有域名，不带随包图标。
    @MainActor
    func testAClaimedPlatformLinkIsJustItsDomainToo() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let url = "https://item.jd.com/100012043978.html"
        let message = try insertIncoming(
            body: url,
            preview: Preview(title: "冒充：京东客服退款，请点击", description: nil, rich: nil, url: url),
            thread: thread,
        )
        try assertDomainCard(try componentState(message), domain: "jd.com")
    }

    /// 没打协议的裸域名（2026-10-19，§5.6 的例外）：消息请求里也只有域名卡。
    @MainActor
    func testABareDomainIsJustItsDomainToo() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let message = try insertIncoming(
            body: "baidu.com",
            preview: Preview(title: "冒充：Tellomi 官方客服，请立即回复验证码", description: nil, rich: nil, url: "https://baidu.com"),
            thread: thread,
        )
        try assertDomainCard(try componentState(message), domain: "baidu.com")
    }

    @MainActor
    func testAFirstPartyLinkIsJustItsDomainNotAProfileCard() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let url = "https://tell.cc/hk881qb"
        let message = try insertIncoming(
            body: url,
            preview: Preview(title: "发送端写的群名", description: nil, rich: richBytes(kind: "tellomi.user", provider: "tellomi"), url: url),
            thread: thread,
        )
        try assertDomainCard(try componentState(message), domain: "tell.cc")
    }

    @MainActor
    func testAPaymentLinkIsJustItsDomain() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let url = "https://render.alipay.com/p/s/i/"
        let message = try insertIncoming(
            body: url,
            preview: Preview(title: "淘宝商品标题", description: nil, rich: richBytes(kind: "payment", provider: "alipay"), url: url),
            thread: thread,
        )
        try assertDomainCard(try componentState(message), domain: "alipay.com")
    }

    @MainActor
    func testALookalikeDomainIsStillFlagged() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let url = "https://www.bi1ibili.com/video/BV1YDhJ6ZEL6"
        let message = try insertIncoming(body: url, preview: Preview(title: "标题", description: nil, rich: nil, url: url), thread: thread)
        try assertDomainCard(try componentState(message), domain: "bi1ibili.com", lookalike: true)
    }

    @MainActor
    func testAMessageThatIsOnlyALinkWithoutAPreviewGetsTheDomainCardToo() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let message = try insertIncoming(body: "https://www.wikipedia.org/wiki/Tellomi", preview: nil, thread: thread)
        try assertDomainCard(try componentState(message), domain: "wikipedia.org")
    }

    @MainActor
    func testNoPreviewAndMoreThanALinkMeansNoCard() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let message = try insertIncoming(body: "看这个 https://www.wikipedia.org/wiki/Tellomi 很好", preview: nil, thread: thread)
        XCTAssertNil(try componentState(message).linkPreview)
    }

    @MainActor
    func testAPreviewWhoseLinkIsNotInTheBodyMeansNoCard() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: false)
        let message = try insertIncoming(
            body: "hello",
            preview: Preview(title: "标题", description: nil, rich: nil, url: "https://www.wikipedia.org/wiki/Tellomi"),
            thread: thread,
        )
        XCTAssertNil(try componentState(message).linkPreview)
    }

    // MARK: - 不读预览图

    /// 同一条消息、图已经下载好躺在库里：消息请求里域名卡不显示、不读它；接受以后才是带图的完整卡片。
    @MainActor
    func testADownloadedPreviewImageIsNotReadInAMessageRequestButIsAfterAccepting() async throws {
        try requireBundledRegistry()
        let url = "https://www.wikipedia.org/wiki/Tellomi"
        let preview = Preview(title: "维基百科", description: nil, rich: nil, url: url)

        let pending = makeThread(accepted: false)
        let requestMessage = try insertIncoming(body: url, preview: preview, thread: pending)
        try await attachDownloadedPreviewImage(to: requestMessage, thread: pending)
        try assertDomainCard(try componentState(requestMessage), domain: "wikipedia.org")

        let accepted = makeThread(accepted: true)
        XCTAssertFalse(isPendingRequest(accepted))
        let acceptedMessage = try insertIncoming(body: url, preview: preview, thread: accepted)
        try await attachDownloadedPreviewImage(to: acceptedMessage, thread: accepted)
        let full = try XCTUnwrap(try componentState(acceptedMessage).linkPreview?.state as? TellomiLinkPreviewCardState)
        XCTAssertEqual(full.imageState, .loaded, "对照：同样的消息接受以后图是读了的，上面的断言才有意义")
    }

    // MARK: - 接受以后：完整显示

    @MainActor
    func testAfterAcceptingTheCardIsTheFullOne() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: true)
        XCTAssertFalse(isPendingRequest(thread))
        let url = "https://www.wikipedia.org/wiki/Tellomi"
        let message = try insertIncoming(body: url, preview: Preview(title: "维基百科", description: "发送端的描述", rich: nil, url: url), thread: thread)
        let componentState = try componentState(message)
        let state = try XCTUnwrap(componentState.linkPreview?.state as? TellomiLinkPreviewCardState)
        XCTAssertFalse(state.isPlainLink)
        XCTAssertEqual(state.title, "维基百科")
        XCTAssertEqual(state.displayDomain, "wikipedia.org")
        XCTAssertFalse(state.isInert)
        XCTAssertTrue(CVComponentLinkPreview.respondsToTap(state))
        XCTAssertTrue(state.isCardOnly, "只有这一条链接时只显示卡片")
        // 统一样式：没有图的文字横条（标题 + 域名 + 指南针），卡片代替气泡
        XCTAssertEqual(state.cardStyle, .textStrip)
        XCTAssertEqual(state.cardText?.title, "维基百科")
        XCTAssertEqual(state.cardText?.domain, "wikipedia.org")
        XCTAssertEqual(componentState.tellomiLinkCardPlacement, .replacesBubble)
    }

    @MainActor
    func testAfterAcceptingAFirstPartyLinkIsTheProfileCard() throws {
        try requireBundledRegistry()
        let thread = makeThread(accepted: true)
        let url = "https://tell.cc/hk881qb"
        let message = try insertIncoming(
            body: url,
            preview: Preview(title: nil, description: nil, rich: richBytes(kind: "tellomi.user", provider: "tellomi"), url: url),
            thread: thread,
        )
        let state = try XCTUnwrap(try componentState(message).linkPreview?.state as? TellomiLinkPreviewCardState)
        XCTAssertNotNil(state.firstParty)
        XCTAssertFalse(state.isInert)
    }

    // MARK: - 点击

    func testOnlyTheMessageRequestDomainCardIgnoresTaps() {
        let base = LinkPreviewSent(linkPreview: OWSLinkPreview(urlString: "https://www.wikipedia.org/"), imageAttachment: nil, isFailedImageAttachmentDownload: false, conversationStyle: nil)
        let display = TellomiLinkDisplay(title: "wikipedia.org", description: nil, domain: nil, officialBadge: false, isPlainLink: true)
        XCTAssertFalse(CVComponentLinkPreview.respondsToTap(TellomiLinkPreviewCardState(base: base, display: display, showsImage: false, isCardOnly: false, isInert: true)))
        XCTAssertTrue(CVComponentLinkPreview.respondsToTap(TellomiLinkPreviewCardState(base: base, display: display, showsImage: false, isCardOnly: true)))
        XCTAssertTrue(CVComponentLinkPreview.respondsToTap(base))
    }
}
