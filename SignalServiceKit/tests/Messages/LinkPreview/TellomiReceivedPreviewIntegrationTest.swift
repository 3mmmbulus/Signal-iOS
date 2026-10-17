//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

@testable import SignalServiceKit

/// ADR-0063 §7.4，口径 S2，审计 M4 / M5：一条真的走完 `MessageReceiver` 的消息——
/// 预览图附件只在卡片确实要显示图的时候才建（判为纯链接或品牌壳的预览不建，也就不会下载），
/// 超长 / 畸形的 `rich` 收到时就丢、不落库；消息和 snapshot 照收，`rich` 原始字节照存。
final class TellomiReceivedPreviewIntegrationTest: SSKBaseTest {

    private let localE164Identifier = "+13235551234"
    private let localAci = Aci.randomForTesting()
    private let bobE164Identifier = "+18083235555"
    private var bobClient: TestSignalClient!
    private lazy var localClient = LocalSignalClient()
    private let runner = TestProtocolRunner()

    override func setUp() {
        super.setUp()
        let identityManager = DependenciesBridge.shared.identityManager
        identityManager.generateAndPersistNewIdentityKey(for: .aci)
        identityManager.generateAndPersistNewIdentityKey(for: .pni)
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .init(
                    aci: localAci,
                    pni: Pni.randomForTesting(),
                    e164: .init(localE164Identifier)!,
                ),
                tx: tx,
            )
            DependenciesBridge.shared.tsAccountManager.setRegistrationId(RegistrationIdGenerator.generate(), for: .aci, tx: tx)
            DependenciesBridge.shared.tsAccountManager.setRegistrationId(RegistrationIdGenerator.generate(), for: .pni, tx: tx)
        }
        bobClient = FakeSignalClient.generate(e164Identifier: bobE164Identifier)
    }

    override func tearDown() {
        try! SSKEnvironment.shared.databaseStorageRef.grdbStorage.testing_tearDownDatabaseChangeObserver()
        super.tearDown()
    }

    // MARK: - 发一条带预览的消息，走完接收

    private static func varint(_ value: Int) -> Data {
        var bytes = [UInt8]()
        var rest = value
        while rest >= 0x80 {
            bytes.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
        bytes.append(UInt8(rest))
        return Data(bytes)
    }

    private static func richBytes(kind: String, provider: String, level: UInt32) -> Data {
        let builder = SSKProtoRichContent.builder()
        builder.setKind(kind)
        builder.setProvider(provider)
        builder.setSchema(1)
        builder.setLevel(level)
        return try! builder.buildSerializedData()
    }

    private struct Sent {
        var url: String
        var title: String? = "某个标题"
        var rich: Data?
        var image = true
        /// nil = 「看这个 <url>」。
        var body: String?
    }

    private func imagePointer() -> SSKProtoAttachmentPointer {
        let image = SSKProtoAttachmentPointer.builder()
        image.setCdnKey("cdnKey-\(UUID().uuidString)")
        image.setCdnNumber(3)
        image.setKey(Randomness.generateRandomBytes(64))
        image.setDigest(Randomness.generateRandomBytes(32))
        image.setContentType(MimeType.imageJpeg.rawValue)
        image.setSize(1234)
        image.setWidth(400)
        image.setHeight(300)
        return image.buildInfallibly()
    }

    /// 走真实的接收管线（解密 → `MessageReceiver`），返回收到的那条消息。
    private func receive(_ sent: Sent) async throws -> TSIncomingMessage {
        let db = SSKEnvironment.shared.databaseStorageRef
        await db.awaitableWrite { tx in
            try! self.runner.initialize(senderClient: self.bobClient, recipientClient: self.localClient, transaction: tx)
        }

        let preview = SSKProtoPreview.builder(url: sent.url)
        if let title = sent.title {
            preview.setTitle(title)
        }
        if sent.image {
            preview.setImage(imagePointer())
        }
        var previewBytes = try preview.buildSerializedData()
        if let rich = sent.rich {
            previewBytes += Data([0xC2, 0x3E]) + Self.varint(rich.count) + rich
        }
        let timestamp = MessageTimestampGenerator.sharedInstance.generateTimestamp()
        let dataMessage = SSKProtoDataMessage.builder()
        dataMessage.setTimestamp(timestamp)
        dataMessage.setBody(sent.body ?? "看这个 \(sent.url)")
        dataMessage.addPreview(try SSKProtoPreview(serializedData: previewBytes))
        let content = SSKProtoContent.builder()
        content.setDataMessage(try dataMessage.build())
        let plaintext = try content.buildSerializedData()

        let cipherMessage: CiphertextMessage = await db.awaitableWrite { tx in
            try! self.runner.encrypt(
                plaintext,
                senderClient: self.bobClient,
                recipient: self.localClient.protocolAddress,
                context: tx,
            )
        }
        envelopeId += 1
        let envelope = SSKProtoEnvelope.builder(timestamp: envelopeId)
        envelope.setType(.ciphertext)
        envelope.setSourceDevice(bobClient.deviceId)
        envelope.setTimestamp(timestamp)
        envelope.setContent(cipherMessage.serialize())
        envelope.setSourceServiceIDBinary(bobClient.serviceId.serviceIdBinary)
        envelope.setServerTimestamp(NSDate.ows_millisecondTimeStamp())
        envelope.setServerGuidBinary(UUID().data)

        // 等到消息处理完（不然下一条用例会撞上没排空的队列）。
        let drained = expectation(description: "queue flushed")
        NotificationCenter.default.observe(once: MessageProcessor.messageProcessorDidDrainQueue).done { _ in
            drained.fulfill()
        }
        SSKEnvironment.shared.messageProcessorRef.enqueueReceivedEnvelopeData(
            try envelope.buildSerializedData(),
            serverDeliveryTimestamp: NSDate.ows_millisecondTimeStamp(),
            envelopeSource: .tests,
        ) {}
        await fulfillment(of: [drained], timeout: 20)

        return try XCTUnwrap(
            db.read { tx in TSMessage.anyFetchAll(transaction: tx).compactMap { $0 as? TSIncomingMessage }.first },
            "消息没有收下",
        )
    }

    private func previewImageReference(of message: TSMessage) -> ReferencedAttachment? {
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            message.sqliteRowId.flatMap { rowId in
                DependenciesBridge.shared.attachmentStore.fetchAnyReferencedAttachment(
                    for: .messageLinkPreview(messageRowId: rowId),
                    tx: tx,
                )
            }
        }
    }

    // MARK: - 用例

    /// 品牌壳的图是随包图标，不用发送端的：消息和 snapshot、rich 照收，图的附件指针不建。
    func testABrandShellPreviewIsReceivedWithoutItsImageAttachment() async throws {
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
        let rich = Self.richBytes(kind: "product", provider: "taobao", level: 1)
        let message = try await receive(Sent(url: "https://item.taobao.com/item.htm?id=674169489573", title: "商品标题", rich: rich))
        let preview = try XCTUnwrap(message.linkPreview, "预览照收")
        XCTAssertEqual(preview.title, "商品标题")
        XCTAssertEqual(preview.rich, rich, "rich 原始字节照存（§7.4）")
        XCTAssertNil(previewImageReference(of: message), "品牌壳不为发送端的图建附件指针，也就不会下载")
    }

    /// 没有 provider 的普通网页：卡片显示发送端的图，照旧建（对照：门控不是把所有图都拦了）。
    func testAnOrdinaryWebPagePreviewStillGetsItsImageAttachment() async throws {
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
        let message = try await receive(Sent(url: "https://www.wikipedia.org/wiki/Tellomi", title: "维基百科"))
        XCTAssertEqual(message.linkPreview?.title, "维基百科")
        XCTAssertNotNil(previewImageReference(of: message), "generic 卡显示发送端的图，要建")
    }

    /// 超长的 rich 收到时整个丢掉、不落库；snapshot 和图（这张卡显示图）照收。
    func testAnOversizedRichIsDroppedOnReceiveButTheMessageAndSnapshotStay() async throws {
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
        let rich = Self.richBytes(kind: String(repeating: "k", count: 33), provider: "bilibili", level: 2)
        let message = try await receive(Sent(url: "https://www.bilibili.com/video/BV1GJ411x7h7", title: "视频标题", rich: rich))
        let preview = try XCTUnwrap(message.linkPreview)
        XCTAssertEqual(preview.title, "视频标题")
        XCTAssertNil(preview.rich, "超长的 rich 不落库（§6.1 / §7.4）")
    }

    /// owner 2026-10-17（ADR-0063 补充）：正文里写的是没协议 / http:// 的短链，预览是它的 https——注册表认领，预览照收。
    func testAPreviewOfASchemelessLinkTheRegistryClaimsIsKept() async throws {
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
        for body in ["看这个 b23.tv/BV1GJ411x7h7", "看这个 http://b23.tv/BV1GJ411x7h7"] {
            let message = try await receive(Sent(url: "https://b23.tv/BV1GJ411x7h7", title: "视频标题", body: body))
            XCTAssertEqual(message.linkPreview?.title, "视频标题", body)
        }
    }

    /// 注册表不认领的网站，http:// 写法照上游丢掉预览（消息照收）。
    func testAPreviewOfAnHttpLinkTheRegistryDoesNotClaimIsDropped() async throws {
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
        let message = try await receive(Sent(url: "https://www.wikipedia.org/wiki/Tellomi", body: "看这个 http://www.wikipedia.org/wiki/Tellomi"))
        XCTAssertNil(message.linkPreview)
        XCTAssertEqual(message.body, "看这个 http://www.wikipedia.org/wiki/Tellomi")
    }

    /// 2026-10-17（build 18 复测报告第 5 条：接收端没有「收到紧贴中文的消息」的专门用例）：正文里链接后面紧贴中文或全角标点，
    /// 预览照收（rust/links 把非 ASCII 当链接的结尾）。
    func testAPreviewOfALinkWithTextGluedAfterItIsKept() async throws {
        try XCTSkipUnless(TellomiLinkRegistry.classifier.isAvailable, "随包注册表没加载")
        for body in ["看这个https://b23.tv/BV1GJ411x7h7很好", "看这个https://b23.tv/BV1GJ411x7h7，很好", "（https://b23.tv/BV1GJ411x7h7）"] {
            let message = try await receive(Sent(url: "https://b23.tv/BV1GJ411x7h7", title: "视频标题", body: body))
            XCTAssertEqual(message.linkPreview?.title, "视频标题", body)
        }
    }
}
