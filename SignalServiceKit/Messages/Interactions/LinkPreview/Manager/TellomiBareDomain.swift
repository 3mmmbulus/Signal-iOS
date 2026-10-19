//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 用户 2026-10-19 定（§5.6 的例外，同 iOS「信息」App）：正文里没写协议的**裸域名**（`baidu.com`、`www.jd.com/`）
/// 不归注册表也出卡片：发送端按 https 抓，接收端按 https 认。
///
/// 只认「一个域名，后面最多一个 `/`」：带路径、查询、片段、端口、用户名的没写协议链接照旧只有注册表认领的才出卡片（§5.6 原样）。
/// 安全限制：
/// - 只认 ASCII 域名（每段 1–63 个 `a-z 0-9 -`、不以 `-` 开头结尾，至少两段，总长 ≤ 253）；国际化域名不在例外里；
/// - 顶级域必须是字母（或 `xn--` 开头的 punycode），至少两位——数字结尾的（IPv4）一律不算，IPv6 的 `[` `]` 也不算；
/// - 内网、保留、测试用的后缀不算（`local`、`localhost`、`internal`、`lan`、`home`、`corp`、`arpa`……）；
/// - `.zip`、`.mov` 不算：这两个顶级域和文件名一模一样，正是钓鱼常用的混淆；
/// - `example.com/.org/.net` 不算（同上游 `LinkPreviewHelper`）。
/// 发送端抓取的大小、超时、SSRF 限制不变（rust/links 的作业照样拒内网地址、只抓 https）。
public enum TellomiBareDomain {

    static let maxHostLength = 253
    static let maxLabelLength = 63

    /// 不算裸域名的顶级域：内网 / 保留 / 测试（RFC 2606、RFC 6761、RFC 6762、RFC 8375 及常见内网写法），和像文件名的两个。
    static let deniedTopLevelDomains: Set<String> = [
        "local", "localhost", "localdomain", "internal", "intranet", "lan", "home", "corp", "private",
        "arpa", "test", "example", "invalid", "onion", "i2p", "alt",
        "zip", "mov",
    ]

    static let deniedDomains: Set<String> = ["example.com", "example.org", "example.net"]

    /// 用户敲的那段文字（没写协议）是不是一个裸域名；是就给出 https 形式（`https://baidu.com`），不是返回 nil。
    public static func httpsUrl(forTypedText text: String) -> String? {
        var host = Substring(text)
        if host.hasSuffix("/") {
            host = host.dropLast()
        }
        guard isBareDomainHost(String(host)) else {
            return nil
        }
        return "https://" + host.lowercased()
    }

    /// 一个 https URL 是不是裸域名的形式（`https://baidu.com` 或 `https://baidu.com/`）：接收端判「正文里那个没写协议的域名」时用。
    public static func isBareDomainUrl(_ urlString: String) -> Bool {
        guard let scheme = urlString.range(of: "https://", options: [.anchored, .caseInsensitive]) else {
            return false
        }
        var host = urlString[scheme.upperBound...]
        if host.hasSuffix("/") {
            host = host.dropLast()
        }
        return isBareDomainHost(String(host))
    }

    static func isBareDomainHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= maxHostLength, host.allSatisfy(\.isASCII) else {
            return false
        }
        let lowered = host.lowercased()
        let labels = lowered.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else {
            return false
        }
        for label in labels {
            guard
                (1...maxLabelLength).contains(label.count),
                label.first != "-",
                label.last != "-",
                label.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
            else {
                return false
            }
        }
        let tld = String(labels[labels.count - 1])
        let isAlphabeticTld = tld.count >= 2 && tld.allSatisfy { ("a"..."z").contains($0) }
        let isPunycodeTld = tld.hasPrefix("xn--") && tld.count > 4
        guard isAlphabeticTld || isPunycodeTld else {
            return false
        }
        guard !deniedTopLevelDomains.contains(tld) else {
            return false
        }
        let registrable = labels.suffix(2).joined(separator: ".")
        return !deniedDomains.contains(registrable)
    }
}
