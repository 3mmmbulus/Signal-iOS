//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 发送端抓链接预览的契约（超级仓库 `docs/adr/0063-link-system-rich-content.md` §4.4、§6.2；tellomi/tellomi#1423）。
/// 数字三端一样，改这里要同时改 Android / Desktop 的抓取器和 ADR。
public enum TellomiLinkFetchContract {
    /// UA 默认 `WhatsApp/2`（§3.4.1：不暴露设备型号和版本；注册表的 `fetch.ua` 禁用）。
    public static let userAgent = "WhatsApp/2"
    /// 唯一的例外（产品经理 2026-10-19 批准，ADR-0063 §3.4.1 / §4.4）：微信公众号文章对 `WhatsApp/2` 回验证码页，
    /// 对 Safari 才给 OG。这个值写死、所有用户一样，不是本机真实的系统和版本。
    public static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    /// 用 `browserUserAgent` 的主机：**精确匹配**，不含子域、不认通配。只在代码里，注册表和热更新加不了；
    /// 要加别的域名先问产品经理（再报 owner），三端（Android `TellomiLinkFetcher.kt`、Desktop `linkFetcher.node.ts`）一起改。
    public static let browserUserAgentHosts: Set<String> = ["mp.weixin.qq.com"]

    /// 这一跳带哪个 UA：只有页面步骤（`page` / `html`）、主机精确落在 `browserUserAgentHosts` 里才换；
    /// 图片、JSON、短链展开和其余主机一律 `WhatsApp/2`。按每一跳的主机判，重定向到别的主机就换回来。
    public static func userAgent(for url: URL, step: TellomiLinkFetchStep) -> String {
        switch step {
        case .page, .html:
            guard let host = url.host?.lowercased(), browserUserAgentHosts.contains(host) else {
                return userAgent
            }
            return browserUserAgent
        case .json, .image, .shortLink:
            return userAgent
        }
    }
    public static let acceptEncoding = "gzip, deflate, br"
    /// CFNetwork 在请求没带 `Accept-Language` 时会**自己补上系统语言列表**（本机实测：不设这个头，线上照样出现
    /// `Accept-Language: zh-CN,zh-Hans;q=0.9`；设成 nil 也一样）。URLSession 没有办法让它不发，所以写死一个不含任何信息、
    /// 所有用户都一样的值把它盖掉：RFC 9110 §12.5.4 里 `*` 与不带这个头同义。
    public static let neutralAcceptLanguage = "*"

    /// 每个请求最多跟 5 跳重定向，每跳重做 https / 域名 / 私网校验。
    public static let maxRedirectsPerRequest = 5
    /// 连接 5 s。URLSession 没有单独的连接超时，用「5 s 收不到任何字节就算超时」实现（覆盖 DNS / TCP / TLS 阶段）。
    public static let connectTimeout: TimeInterval = 5
    /// 单个请求（含它的重定向）总共 10 s。
    public static let requestTimeout: TimeInterval = 10
    /// 每条链接总预算 10 s。
    public static let perLinkBudget: TimeInterval = 10
    /// 每条链接最多 3 个元数据请求（短链展开算 1 个）+ 1 个图片请求。
    public static let maxMetadataRequestsPerLink = 3
    public static let maxImageRequestsPerLink = 1

    /// 体积上限按**解压后**的字节数算：HTML 2 MiB、JSON 256 KiB；图片沿用 iOS 现值 2 MiB。
    public static let maxHtmlBytes = 2 * 1024 * 1024
    public static let maxJsonBytes = 256 * 1024
    public static let maxImageBytes = 2 * 1024 * 1024
}

/// 一次抓取属于管线的哪一步。`Accept` 与 `Content-Type` 白名单按步骤定（§4.4）。
public enum TellomiLinkFetchStep: Equatable, Sendable {
    /// Generic（没有 provider）的页面：HTML；另外沿用上游，链接本身就是一张图时直接收图（按图片的上限算）。
    case page
    /// `og+jsonld`：只收 HTML。
    case html
    /// `public-api` / `oembed`：只收 JSON。
    case json
    /// 预览图 / 站点图标（每条链接那「+1 个图片请求」）。
    case image
    /// 短链展开：只读 `Location`，不读正文、不跟随。
    case shortLink

    public var isImageRequest: Bool { self == .image }

    var acceptHeader: String {
        switch self {
        case .page: return "text/html,application/xhtml+xml,image/*;q=0.8"
        case .html: return "text/html,application/xhtml+xml"
        case .json: return "application/json"
        case .image: return "image/*"
        case .shortLink: return "*/*"
        }
    }

    /// 响应的 MIME 类型是否在这一步的白名单里；在的话按哪种正文算上限。
    func bodyKind(forMimeType rawMimeType: String?) -> TellomiLinkFetchBodyKind? {
        guard let mimeType = rawMimeType?.lowercased().trimmingCharacters(in: .whitespaces).nilIfEmpty else {
            return nil
        }
        let isHtml = mimeType == "text/html" || mimeType == "application/xhtml+xml"
        // rust/links 的 JSON 请求列的就是这四种（`content_types`）：iTunes 的接口回的是 `text/javascript`。
        let isJson = ["application/json", "text/json", "text/javascript", "application/javascript"].contains(mimeType)
            || (mimeType.hasPrefix("application/") && mimeType.hasSuffix("+json"))
        let isImage = MimeTypeUtil.isSupportedImageMimeType(mimeType)
        switch self {
        case .page:
            if isHtml { return .html }
            if isImage { return .image }
            return nil
        case .html:
            return isHtml ? .html : nil
        case .json:
            return isJson ? .json : nil
        case .image:
            return isImage ? .image : nil
        case .shortLink:
            return nil
        }
    }
}

public enum TellomiLinkFetchBodyKind: Equatable, Sendable {
    case html
    case json
    case image
}

/// §4.3 区域先验。P1 固定传 `global`：两端的 RegionProfile 还没接进抓取（#1055 / #1056），而且 CN 档备案前本来就不启用。
public enum TellomiLinkRegionPrior {
    public static let current: TellomiRegionId = .global

    /// provider 的 `unreachable_in` 含当前区域 → 跳过所有要联网的步骤（直接出品牌壳）。
    public static func skipsNetwork(unreachableIn: Set<TellomiRegionId>, region: TellomiRegionId = current) -> Bool {
        return unreachableIn.contains(region)
    }
}

// MARK: - 私网地址（§6.2）

/// 一个已经解析出来的 IP 地址（网络字节序）。
public enum TellomiLinkIPAddress: Equatable, Sendable, CustomStringConvertible {
    case v4([UInt8])
    case v6([UInt8])

    /// 只认字面量（`10.0.0.1`、`::1`；IPv6 不带方括号），不做解析。
    public init?(literal rawLiteral: String) {
        var literal = rawLiteral
        if literal.hasPrefix("["), literal.hasSuffix("]") {
            literal = String(literal.dropFirst().dropLast())
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, literal, &v4) == 1 {
            self = .v4(withUnsafeBytes(of: &v4) { Array($0) })
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, literal, &v6) == 1 {
            self = .v6(withUnsafeBytes(of: &v6) { Array($0) })
            return
        }
        return nil
    }

    public var description: String {
        switch self {
        case .v4(let bytes): return bytes.map(String.init).joined(separator: ".")
        case .v6(let bytes): return bytes.map { String(format: "%02x", $0) }.joined()
        }
    }
}

public enum TellomiLinkAddressPolicy {
    /// §6.2 拦的地址段。**不拦 `198.18.0.0/15`**：大陆常用的 fake-ip 代理（Clash、Surge、sing-box）把所有域名解析到这一段。
    public static func isBlocked(_ address: TellomiLinkIPAddress) -> Bool {
        switch address {
        case .v4(let b):
            return isBlockedV4(b)
        case .v6(let b):
            guard b.count == 16 else { return true }
            // ::1、::（未指定）以及已废弃的 IPv4-compatible（::a.b.c.d）：前 12 字节全 0，按后 4 字节当 IPv4 判（::1 → 0.0.0.1 落在 0/8）
            if b[0..<12].allSatisfy({ $0 == 0 }) {
                return isBlockedV4(Array(b[12..<16]))
            }
            // IPv4-mapped（::ffff:a.b.c.d）
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
                return isBlockedV4(Array(b[12..<16]))
            }
            // NAT64 众所周知前缀 64:ff9b::/96（收紧，ADR 未列）：IPv6-only 网络里系统会合成这种地址，内嵌的 IPv4 照样要判
            if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b, b[4..<12].allSatisfy({ $0 == 0 }) {
                return isBlockedV4(Array(b[12..<16]))
            }
            // fc00::/7（ULA）
            if b[0] & 0xfe == 0xfc {
                return true
            }
            // fe80::/10（链路本地）
            if b[0] == 0xfe, b[1] & 0xc0 == 0x80 {
                return true
            }
            return false
        }
    }

    private static func isBlockedV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }
        switch b[0] {
        case 0, 10, 127:
            return true // 0/8、10/8、127/8
        case 100:
            return b[1] & 0xc0 == 64 // 100.64/10（CGNAT，Tailscale 也用）
        case 169:
            return b[1] == 254 // 169.254/16
        case 172:
            return b[1] & 0xf0 == 16 // 172.16/12
        case 192:
            return b[1] == 168 // 192.168/16
        default:
            return false
        }
    }
}

// MARK: - 解析

public enum TellomiLinkResolution: Equatable, Sendable {
    case addresses([TellomiLinkIPAddress])
    case failed
}

public protocol TellomiLinkHostResolving: Sendable {
    func resolve(host: String) async -> TellomiLinkResolution
}

/// iOS 的 URLSession 没有 DNS 钩子，只能每一跳先 `getaddrinfo` 预检（§6.2：有检查与使用之间的时间差，
/// 但 https 加证书校验让 DNS rebinding 拿不到好处）。
public struct TellomiSystemHostResolver: TellomiLinkHostResolving {
    public init() {}

    public func resolve(host: String) async -> TellomiLinkResolution {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.resolveBlocking(host: host))
            }
        }
    }

    private static func resolveBlocking(host: String) -> TellomiLinkResolution {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return .failed
        }
        defer { freeaddrinfo(first) }
        var addresses = [TellomiLinkIPAddress]()
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let sockaddr = info.pointee.ai_addr {
                switch Int32(sockaddr.pointee.sa_family) {
                case AF_INET:
                    sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        var addr = sin.pointee.sin_addr
                        addresses.append(.v4(withUnsafeBytes(of: &addr) { Array($0) }))
                    }
                case AF_INET6:
                    sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                        var addr = sin6.pointee.sin6_addr
                        addresses.append(.v6(withUnsafeBytes(of: &addr) { Array($0) }))
                    }
                default:
                    break
                }
            }
            cursor = info.pointee.ai_next
        }
        return addresses.isEmpty ? .failed : .addresses(addresses)
    }
}

// MARK: - 每一跳的 URL 校验

public enum TellomiLinkURLVerdict: Equatable, Sendable {
    case allowed
    /// 不是 https（§6.3：没有降级到 http 的路径）
    case schemeNotAllowed
    /// 带用户名密码、主机名不合法、保留域名等（`LinkPreviewHelper.isPermittedLinkPreviewUrl`）
    case shapeNotAllowed
    /// 主机是私网 / 回环 / 链路本地 / CGNAT 地址，或者解析到这些地址（§6.2）
    case blockedAddress
    /// 解析失败（网络层失败，要进可达性记录）
    case unresolvable
}

/// 首跳和每一跳重定向都过一遍。生产用 `.production`；测试可以换掉整个校验（例如把本进程测试服务的地址放进来），
/// 生产代码里没有任何「测试时放行」的分支。
public struct TellomiLinkURLGuard: Sendable {
    public var checkShape: @Sendable (URL) -> TellomiLinkURLVerdict
    public var checkAddress: @Sendable (URL) async -> TellomiLinkURLVerdict

    public init(
        checkShape: @escaping @Sendable (URL) -> TellomiLinkURLVerdict,
        checkAddress: @escaping @Sendable (URL) async -> TellomiLinkURLVerdict,
    ) {
        self.checkShape = checkShape
        self.checkAddress = checkAddress
    }

    public static let production = TellomiLinkURLGuard(resolver: TellomiSystemHostResolver())

    public init(resolver: any TellomiLinkHostResolving) {
        self.init(
            checkShape: Self.productionShapeCheck,
            checkAddress: { url in await Self.productionAddressCheck(url, resolver: resolver) },
        )
    }

    public static func productionShapeCheck(_ url: URL) -> TellomiLinkURLVerdict {
        guard url.scheme?.lowercased() == "https" else {
            return .schemeNotAllowed
        }
        guard LinkPreviewHelper.isPermittedLinkPreviewUrl(url) else {
            return .shapeNotAllowed
        }
        return .allowed
    }

    public static func productionAddressCheck(_ url: URL, resolver: any TellomiLinkHostResolving) async -> TellomiLinkURLVerdict {
        guard let host = url.host?.nilIfEmpty else {
            return .shapeNotAllowed
        }
        if let literal = TellomiLinkIPAddress(literal: host) {
            return TellomiLinkAddressPolicy.isBlocked(literal) ? .blockedAddress : .allowed
        }
        switch await resolver.resolve(host: host) {
        case .failed:
            return .unresolvable
        case .addresses(let addresses):
            // 解析出多个地址时只要有一个落在私网段就整跳作废（URLSession 连哪一个由系统决定）
            return addresses.contains(where: TellomiLinkAddressPolicy.isBlocked) ? .blockedAddress : .allowed
        }
    }
}
