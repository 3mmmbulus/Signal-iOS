//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI
import UIKit

#if USE_DEBUG_UI

/// 只在调试构建里：往一个假联系人的会话里塞几条「收到的」链接预览，不用第二个账号就能看卡片（tellomi/tellomi#1423）。
/// 网址取自 `links/tests/corpus/` 里的真实样例，标题、作者和图是演示用的假值；第一方链接用合成值。
///
/// 按产品经理 2026-10-19 定稿的四种样式排（参照 iOS「信息」App）：大图卡、图标横条（页面图标 / 认领平台的随包图标）、
/// 文字横条、只有域名的横条；再加上裸域名（没打协议）、认领但抓页面的平台、品牌壳、第一方卡和仿冒域名。
class DebugUITellomiLinkCards: DebugUIPage {

    let name = "Tellomi link cards"

    private struct Fixture {
        let title: String
        /// 消息正文；不写就是这条链接本身（「只有一条链接」的情形）。
        var body: String?
        let url: String
        var previewTitle: String?
        var previewDescription: String?
        var rich: Rich?
        /// false：只发正文，不带预览（预览关了或没抓到）。
        var hasPreview = true
        /// 发送端带来的预览图（合成的纯色 + 字）：像素尺寸和色相。短边 ≥ 300 且长边 ≥ 600 是大图卡，否则是图标横条。
        var image: (size: CGSize, hue: CGFloat)?

        struct Rich {
            let kind: String
            let provider: String
            var canonicalUrl: String?
            let level: UInt32
            var attrs: [(String, String)] = []
        }
    }

    private static let fixtures: [Fixture] = [
        Fixture(
            title: "大图卡（中性灰底）",
            url: "https://www.wikipedia.org/",
            previewTitle: "Wikipedia",
            previewDescription: "Wikipedia is a free online encyclopedia, created and edited by volunteers.",
            image: (CGSize(width: 1200, height: 630), 0.58),
        ),
        Fixture(
            title: "图标横条（页面图标，主色染底）",
            url: "https://item.jd.com/100012043978.html",
            previewTitle: "Apple iPhone 15 (A3092) 128GB 黑色",
            image: (CGSize(width: 180, height: 180), 0.0),
        ),
        Fixture(
            title: "图标横条（认领平台的随包图标）",
            url: "https://www.taobao.com/",
            previewTitle: "淘宝",
        ),
        Fixture(
            title: "文字横条（没有图：标题 + 域名，没有指南针）",
            url: "https://www.wikipedia.org/wiki/Tellomi",
            previewTitle: "Tellomi - Wikipedia",
        ),
        Fixture(
            title: "只有域名的横条（没有预览）",
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            hasPreview: false,
        ),
        Fixture(
            title: "裸域名（打 baidu.com，卡片代替气泡）",
            body: "baidu.com",
            url: "https://baidu.com",
            previewTitle: "百度一下，你就知道",
            image: (CGSize(width: 180, height: 180), 0.62),
        ),
        Fixture(
            title: "裸域名 + 别的字（卡片在气泡下面）",
            body: "看 baidu.com 吧",
            url: "https://baidu.com",
            previewTitle: "百度一下，你就知道",
        ),
        Fixture(
            title: "正文还有别的字 + 链接（卡片在气泡下面）",
            body: "看看这个 https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: "【演示】给朋友发一条视频链接会长什么样",
            rich: .init(kind: "video", provider: "bilibili", level: 2, attrs: [("author", "演示UP主"), ("duration_ms", "257000")]),
            image: (CGSize(width: 1280, height: 720), 0.55),
        ),
        Fixture(
            title: "B 站视频（结构化，大图卡）",
            url: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
            previewTitle: "【演示】给朋友发一条视频链接会长什么样",
            previewDescription: "发送端写的描述——不该出现在卡片上",
            rich: .init(
                kind: "video",
                provider: "bilibili",
                canonicalUrl: "https://www.bilibili.com/video/BV1YDhJ6ZEL6",
                level: 2,
                attrs: [("author", "演示UP主"), ("duration_ms", "257000"), ("published_at", "2025-03-14T10:00:00Z")],
            ),
            image: (CGSize(width: 1280, height: 720), 0.55),
        ),
        Fixture(
            title: "网易云单曲（结构化，图标横条）",
            url: "https://music.163.com/song?id=1901371647",
            previewTitle: "演示歌曲",
            rich: .init(kind: "music.track", provider: "netease-music", level: 2, attrs: [("artist", "演示歌手"), ("album", "演示专辑"), ("duration_ms", "213000")]),
            image: (CGSize(width: 300, height: 300), 0.0),
        ),
        Fixture(
            title: "淘宝商品（旧客户端发来的品牌壳）",
            url: "https://item.taobao.com/item.htm?id=674169489573",
            previewTitle: "登录",
            rich: .init(kind: "product", provider: "taobao", level: 1),
        ),
        Fixture(
            title: "京东商品（认领平台抓不到标题：品牌壳）",
            url: "https://item.jd.com/100012043978.html",
        ),
        Fixture(
            title: "支付宝（支付壳，不染色）",
            url: "https://render.alipay.com/p/f/fd-j5rqp49m/index.html",
            previewTitle: "支付宝",
            rich: .init(kind: "web", provider: "alipay", level: 1),
        ),
        Fixture(
            title: "Tellomi 用户（tell.cc/用户名）",
            url: "https://tell.cc/hk881qb",
            previewTitle: "Tellomi",
        ),
        Fixture(
            title: "Tellomi 官网",
            url: "https://tellomi.app/download",
            previewTitle: "Tellomi",
        ),
        Fixture(
            title: "仿冒域名（没有预览）",
            url: "https://www.bi1ibili.com/video/BV1YDhJ6ZEL6",
            hasPreview: false,
        ),
    ]

    func section(thread: TSThread?) -> OWSTableSection? {
        var items = [OWSTableItem]()

        items.append(OWSTableItem(title: "新建假联系人会话（已接受）并塞入全部", actionBlock: {
            let thread = Self.makeFakeContactThread(accepted: true)
            Self.insertAll(into: thread)
        }))
        items.append(OWSTableItem(title: "新建假联系人会话（消息请求）并塞入全部", actionBlock: {
            let thread = Self.makeFakeContactThread(accepted: false)
            Self.insertAll(into: thread)
        }))

        if let contactThread = thread as? TSContactThread {
            items.append(OWSTableItem(title: "往当前会话塞入全部", actionBlock: {
                Self.insertAll(into: contactThread)
            }))
            for fixture in Self.fixtures {
                items.append(OWSTableItem(title: "当前会话：\(fixture.title)", actionBlock: {
                    Self.insert(fixture, into: contactThread)
                }))
            }
        }

        return OWSTableSection(title: name, items: items)
    }

    // MARK: -

    private static func makeFakeContactThread(accepted: Bool) -> TSContactThread {
        let aci = Aci(fromUUID: UUID())
        let thread = TSContactThread.getOrCreateThread(contactAddress: SignalServiceAddress(aci))
        if accepted {
            SSKEnvironment.shared.databaseStorageRef.write { tx in
                var recipient = DependenciesBridge.shared.recipientFetcher.fetchOrCreate(serviceId: aci, tx: tx)
                SSKEnvironment.shared.profileManagerRef.addRecipientToProfileWhitelist(
                    &recipient,
                    userProfileWriter: .debugging,
                    tx: tx,
                )
            }
        }
        return thread
    }

    private static func insertAll(into thread: TSContactThread) {
        for fixture in fixtures {
            insert(fixture, into: thread)
        }
    }

    private static func insert(_ fixture: Fixture, into thread: TSContactThread) {
        guard let authorAci = thread.contactAddress.aci else {
            owsFailDebug("The thread has no ACI.")
            return
        }
        let richBytes = fixture.rich.flatMap { rich -> Data? in
            let builder = SSKProtoRichContent.builder()
            builder.setKind(rich.kind)
            builder.setProvider(rich.provider)
            builder.setSchema(1)
            if let canonicalUrl = rich.canonicalUrl {
                builder.setCanonicalURL(canonicalUrl)
            }
            builder.setLevel(rich.level)
            for (key, value) in rich.attrs {
                let attr = SSKProtoAttr.builder()
                attr.setKey(key)
                attr.setValue(value)
                builder.addAttrs(attr.buildInfallibly())
            }
            return try? builder.buildSerializedData()
        }
        let message = SSKEnvironment.shared.databaseStorageRef.write { tx -> TSIncomingMessage in
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
        guard fixture.hasPreview, let image = fixture.image, let imageData = png(size: image.size, hue: image.hue) else {
            return
        }
        Task {
            do {
                let pending = try await DependenciesBridge.shared.attachmentContentValidator.validateDataContents(
                    imageData,
                    mimeType: "image/png",
                    renderingFlag: .default,
                    sourceFilename: nil,
                )
                try await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
                    guard let messageRowId = message.sqliteRowId, let threadRowId = thread.sqliteRowId else {
                        return
                    }
                    _ = try DependenciesBridge.shared.attachmentManager.createAttachmentStream(
                        from: OwnedAttachmentDataSource(
                            dataSource: .pendingAttachment(pending),
                            owner: .messageLinkPreview(.init(
                                messageRowId: messageRowId,
                                receivedAtTimestamp: message.receivedAtTimestamp,
                                threadRowId: threadRowId,
                                isPastEditRevision: false,
                            )),
                        ),
                        tx: tx,
                    )
                    // 会话页重排这条消息，把图带上
                    SSKEnvironment.shared.databaseStorageRef.touch(interaction: message, shouldReindex: false, tx: tx)
                }
            } catch {
                owsFailDebug("Could not attach the preview image: \(error)")
            }
        }
    }

    /// 合成的预览图：上浅下深的同色相渐变 + 居中的尺寸文字，像素尺寸就是 `size`（scale 1）。
    private static func png(size: CGSize, hue: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let top = UIColor(hue: hue, saturation: 0.75, brightness: 0.92, alpha: 1)
            let bottom = UIColor(hue: hue, saturation: 0.85, brightness: 0.7, alpha: 1)
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            let text = "\(Int(size.width))×\(Int(size.height))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: min(size.width, size.height) / 6),
                .foregroundColor: UIColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
        }.pngData()
    }
}

#endif
