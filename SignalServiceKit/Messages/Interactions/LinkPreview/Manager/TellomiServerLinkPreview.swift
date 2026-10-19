//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// ADR-0063 §6.5（owner 2026-10-19）：手机端抓不到的几家（公众号、知乎含专栏、微博、小红书；产品经理同日加了抖音、
/// 淘宝 / 天猫商品页）由服务端代抓，只拿回标题、缩略图、域名。这里是**不联网的那一半**：哪些链接走服务端、
/// 请求体、回包怎么读、失败以后多久不再问。真正发请求的是 SignalUI 里的 `SignalServerLinkPreviewClient`。
///
/// 什么时候走服务端（§6.5.6）——三条都满足：
/// 1. 远程配置 `global.linkPreview.serverFetch` 开着（默认关，`RemoteConfig.isTellomiServerLinkPreviewEnabled`）；
/// 2. 链接的主机**精确**在 ``hosts`` 里（与服务端 `LinkPreviewProviders` 同一张表），https、默认端口、没有 userinfo；
/// 3. 最近没被服务端告知「没部署 / 忙 / 限流」（``TellomiServerLinkPreviewGate``）。
/// 用户关了「生成链接预览」时调用方根本不会走到这里。走服务端时客户端**不自己去抓这个站**（短链也不展开），
/// 站点和图床都看不到用户的 IP；服务端没给卡片就照现在的做法（品牌壳）。
public enum TellomiServerLinkPreview {

    public static let path = "v1/tellomi/link-preview"
    /// 服务端单条链接预算 10 s，加上来回。
    public static let requestTimeout: TimeInterval = 12
    public static let maxTitleLength = 200
    /// 服务端缩略图 ≤ 800 px JPEG（或 ≤ 512 KiB 的 WebP 原图），超过这个数就不是我们的服务端发的。
    public static let maxImageBytes = 1024 * 1024
    public static let allowedImageMimeTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif"]

    /// 页面主机 → provider id。改这张表要 owner / 产品经理批准，并且和服务端 `LinkPreviewProviders` 一起改。
    public static let hosts: [String: String] = [
        "mp.weixin.qq.com": "weixin-mp",
        "www.zhihu.com": "zhihu",
        "zhihu.com": "zhihu",
        "zhuanlan.zhihu.com": "zhihu",
        "weibo.com": "weibo",
        "www.weibo.com": "weibo",
        "m.weibo.cn": "weibo",
        "www.xiaohongshu.com": "xiaohongshu",
        "xiaohongshu.com": "xiaohongshu",
        "xhslink.com": "xiaohongshu",
        "www.douyin.com": "douyin",
        "douyin.com": "douyin",
        "www.iesdouyin.com": "douyin",
        "iesdouyin.com": "douyin",
        "v.douyin.com": "douyin",
        "live.douyin.com": "douyin",
        "item.taobao.com": "taobao",
        "h5.m.taobao.com": "taobao",
        "main.m.taobao.com": "taobao",
        "market.m.taobao.com": "taobao",
        "detail.tmall.com": "tmall",
        "detail.m.tmall.com": "tmall",
        "chaoshi.detail.tmall.com": "tmall",
    ]

    /// 这条链接归服务端代抓的哪一家；不归就是 nil。
    public static func providerId(for url: URL) -> String? {
        guard
            url.scheme?.lowercased() == "https",
            url.user == nil, url.password == nil,
            url.port == nil || url.port == 443,
            let host = url.host?.lowercased()
        else {
            return nil
        }
        return hosts[host]
    }

    public static func isEligible(_ url: URL, enabled: Bool) -> Bool {
        return enabled && providerId(for: url) != nil
    }

    /// 发给服务端的那条链接：去掉 `#` 片段（片段从不出设备，§2.4）。分享者参数由服务端去掉。
    public static func requestUrlString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    /// 服务端给的卡片。域名不用服务端的：卡片上的域名永远由客户端从正文 URL 算（§4.1）。
    public struct Card: Equatable, Sendable {
        public var title: String
        public var provider: String
        public var imageData: Data?
        public var imageMimeType: String?

        public init(title: String, provider: String, imageData: Data? = nil, imageMimeType: String? = nil) {
            self.title = title
            self.provider = provider
            self.imageData = imageData
            self.imageMimeType = imageMimeType
        }
    }

    public enum Answer: Equatable, Sendable {
        case card(Card)
        /// 204：站点没给卡片（登录墙、验证码、超时……）
        case noCard
        /// 404 / 405 / 501：服务端没开（默认关）或没部署这个接口
        case notDeployed
        /// 429 / 503：过一会儿再问；`retryAfter` 秒
        case throttled(retryAfter: TimeInterval?)
        /// 400 / 422 / 网络错误 / 回包读不懂
        case failed
    }

    public static func answer(status: Int, body: Data?, retryAfter: String?) -> Answer {
        switch status {
        case 200:
            guard let body, let card = parseCard(body) else { return .failed }
            return .card(card)
        case 204:
            return .noCard
        case 404, 405, 501:
            return .notDeployed
        case 429, 503:
            return .throttled(retryAfter: retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        default:
            return .failed
        }
    }

    private struct Wire: Decodable {
        var title: String?
        var provider: String?
        var image: String?
        var imageContentType: String?
    }

    static func parseCard(_ body: Data) -> Card? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: body) else { return nil }
        guard
            let rawTitle = wire.title?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTitle.isEmpty,
            let provider = wire.provider, hosts.values.contains(provider)
        else {
            return nil
        }
        let title = rawTitle.count > maxTitleLength ? String(rawTitle.prefix(maxTitleLength - 1)) + "…" : rawTitle
        var imageData: Data?
        var mimeType: String?
        if
            let image = wire.image,
            let type = wire.imageContentType?.lowercased(), allowedImageMimeTypes.contains(type),
            let data = Data(base64Encoded: image), !data.isEmpty, data.count <= maxImageBytes
        {
            imageData = data
            mimeType = type
        }
        return Card(title: title, provider: provider, imageData: imageData, imageMimeType: mimeType)
    }

    /// 本机作业落到这些级别时，服务端的卡片可以顶上去（结构化卡、第一方卡本来就更好，不换）。
    public static func mayReplace(level: String?) -> Bool {
        guard let level else { return true }
        return level == "brand" || level == "generic" || level == "plain_link"
    }
}

/// 服务端说「没开 / 忙 / 限流」之后多久不再问（只在内存，重启就清）。
public final class TellomiServerLinkPreviewGate: @unchecked Sendable {

    public static let shared = TellomiServerLinkPreviewGate()

    public static let notDeployedBackoff: TimeInterval = 10 * 60
    public static let defaultThrottle: TimeInterval = 60
    public static let maxThrottle: TimeInterval = 60 * 60

    private let clock: () -> Date
    private let lock = NSLock()
    private var closedUntil: Date?

    public init(clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
    }

    public var isOpen: Bool {
        lock.withLock {
            guard let closedUntil else { return true }
            let now = clock()
            // 时钟往回拨了（现在早于关上的时刻减掉最长等待）：当作已过期
            return now >= closedUntil || closedUntil.timeIntervalSince(now) > Self.maxThrottle
        }
    }

    public func record(_ answer: TellomiServerLinkPreview.Answer) {
        let wait: TimeInterval?
        switch answer {
        case .notDeployed:
            wait = Self.notDeployedBackoff
        case .throttled(let retryAfter):
            wait = min(max(retryAfter ?? Self.defaultThrottle, 1), Self.maxThrottle)
        case .card, .noCard, .failed:
            wait = nil
        }
        guard let wait else { return }
        lock.withLock { closedUntil = clock().addingTimeInterval(wait) }
    }
}

/// 真正发请求的那一半（SignalUI 的 `SignalServerLinkPreviewClient`；测试里换成假的）。
public protocol TellomiServerLinkPreviewClient: Sendable {
    func fetch(url: URL) async -> TellomiServerLinkPreview.Answer
}
