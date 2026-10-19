//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 会话里第三方链接卡片的统一样式（产品经理 2026-10-19 定稿，参照 iOS「信息」App；TestFlight 0.1.0 (30) 真机截图里
/// 同一会话出现三四种样式：大图卡、按 logo 染色的图标卡、「平台名 / 网页 / 域名」的无图卡、只有域名 + 链接图标的小条）。
/// 只剩四种：
///
/// - `largeImage`：有大图——图在上，下面标题 + 域名；
/// - `iconStrip`：有小图（站点图标 / 方形小图 / 品牌壳的随包图标）——一条横条，左边标题（粗）+ 域名（灰），右边图标，
///   底色取图标的主色，字用黑或白（WCAG 对比度高的那个）；取不到颜色用中性灰；
/// - `textStrip`：没有图、有标题——中性灰横条，标题 + 域名，右边指南针（认领档的卡不画指南针，见 `showsCompass`）；
/// - `domainStrip`：什么都没抓到——中性灰横条，只有域名，右边指南针。
///
/// 大图 / 小图的分界仍由 rust/links 的 `layout` 定（照 Telegram：短边 ≥ 300、长边 ≥ 600 才是大图）。
/// 副行（发送端写的描述、kind 的名字「网页」等）在这四种里都不显示。第一方卡、群邀请、通话卡不走这里。
/// 纯逻辑：Android `TellomiLinkCardStyle.kt`、Desktop `linkCardStyle.std.ts` 之后照这一份对齐。
public enum TellomiLinkCardStyle {

    public enum Kind: String, Equatable, Sendable {
        case largeImage
        case iconStrip
        case textStrip
        case domainStrip
    }

    /// 数据层给的版式（`TellomiLinkVisual.Layout` 的原始值），这里只认其中三种；不认识 / 没有决定时传 nil。
    public enum Layout: Equatable, Sendable {
        case largeImage
        case icon
        case noImage
    }

    /// 卡片上显示的两行字。`title` 为 nil 时只显示域名（`domainStrip`），或大图下只有域名一行。
    public struct Text: Equatable, Sendable {
        public let title: String?
        public let domain: String

        public init(title: String?, domain: String) {
            self.title = title
            self.domain = domain
        }
    }

    /// 四种样式怎么选。
    /// - `hasImage`：现在真有图可画（已下载或有 blurHash 占位；品牌壳的随包图标也算）；
    /// - `layout`：rust/links 定的版式，nil 表示没有决定（桥失败）——有图就当小图，不猜大图。
    /// - `isPlainLink`：只用 URL 画的卡（没有预览，或 rust/links 判成纯链接），永远是只有域名的那一种。
    public static func kind(layout: Layout?, hasImage: Bool, hasTitle: Bool, isPlainLink: Bool) -> Kind {
        if isPlainLink {
            return .domainStrip
        }
        if hasImage {
            switch layout {
            case .largeImage:
                return .largeImage
            case .icon, nil:
                return .iconStrip
            case .noImage:
                break
            }
        }
        return hasTitle ? .textStrip : .domainStrip
    }

    /// 横条右边画不画指南针（产品经理 2026-10-19 晚）：指南针只给「完全没信息」的卡。
    /// 图标横条右边是图标；认领档（`claimed`）的卡没有图时是标题（或平台名）+ 域名的横条，右边什么都不画；
    /// 其余没有图的横条照 2026-10-19 定稿，右边是指南针。
    public static func showsCompass(kind: Kind, isClaimed: Bool) -> Bool {
        switch kind {
        case .largeImage, .iconStrip:
            return false
        case .textStrip:
            return !isClaimed
        case .domainStrip:
            return true
        }
    }

    /// 两行字怎么来：标题取页面的 `og:title` / `<title>`（数据层已经定好，传进来）；空白、和域名一样的标题不显示。
    /// 域名缺失时用 URL 的 host（去掉 `www.`）；连 host 都没有就是 nil，调用方不画卡片。
    public static func text(title: String?, domain: String?, urlString: String?) -> Text? {
        let cleanDomain = domain.flatMap(clean) ?? urlString.flatMap(hostForDisplay)
        guard let cleanDomain else {
            return nil
        }
        var cleanTitle = title.flatMap(clean)
        if let candidate = cleanTitle, candidate.caseInsensitiveCompare(cleanDomain) == .orderedSame {
            cleanTitle = nil
        }
        return Text(title: cleanTitle, domain: cleanDomain)
    }

    /// 标题最多两行，放不下末尾省略号（视图层用 `numberOfLines = 2` + `.byTruncatingTail`）。
    public static let maxTitleLines = 2

    private static func clean(_ text: String) -> String? {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// `https://www.Baidu.com/s?wd=1` → `baidu.com`；没有协议的（`jd.com/x`）按 https 解析。
    public static func hostForDisplay(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard var host = URLComponents(string: withScheme)?.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("www."), host.count > 4 {
            host.removeFirst(4)
        }
        return host
    }

    // MARK: - 颜色

    public struct RGB: Equatable, Sendable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8

        public init(red: UInt8, green: UInt8, blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        public static let white = RGB(red: 255, green: 255, blue: 255)
        public static let black = RGB(red: 0, green: 0, blue: 0)
    }

    /// WCAG 2.x 相对亮度（sRGB → 线性）。
    public static func relativeLuminance(_ color: RGB) -> Double {
        func channel(_ value: UInt8) -> Double {
            let c = Double(value) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    /// WCAG 对比度 (L1 + 0.05) / (L2 + 0.05)，1…21。
    public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 染色横条上的字色：白和黑里与底色对比度高的那个（相等时用白）。
    public static func textColor(on background: RGB) -> RGB {
        contrastRatio(background, .white) >= contrastRatio(background, .black) ? .white : .black
    }

    /// 取图标的主色当横条底色（照「信息」App 的观感：看图标的底色，不是 logo 本身的颜色）。
    ///
    /// `rgba`：`width × height` 个像素，每像素 R G B A 一字节，不预乘，原点在左上（数据层把图缩成 32 × 32 再给）。
    /// 1. 先看外圈两圈像素（图标的底）：不透明（alpha ≥ 128）的占一半以上就只用它们；否则（透明底的 logo）用全图不透明的像素；
    /// 2. 每个通道按 16 档分桶，取像素最多的那一桶，返回桶里像素的平均色；
    /// 3. 取到的是接近白的颜色（白底图标，比如 qq.com、外圈白边的豆瓣）时返回 nil，用中性灰——白底横条在浅色模式下和背景分不开。
    /// 没有不透明像素、尺寸不对，也返回 nil。
    public static func dominantColor(rgba: [UInt8], width: Int, height: Int) -> RGB? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else {
            return nil
        }
        let ringDepth = min(2, (min(width, height) + 1) / 2)
        var ring = [Int]()
        var ringTotal = 0
        var all = [Int]()
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let isRing = x < ringDepth || y < ringDepth || x >= width - ringDepth || y >= height - ringDepth
                let isOpaque = rgba[index + 3] >= 128
                if isRing {
                    ringTotal += 1
                    if isOpaque { ring.append(index) }
                }
                if isOpaque { all.append(index) }
            }
        }
        let candidates = ringTotal > 0 && ring.count * 2 > ringTotal ? ring : all
        guard !candidates.isEmpty else {
            return nil
        }
        var buckets = [Int: (count: Int, red: Int, green: Int, blue: Int)]()
        for index in candidates {
            let r = Int(rgba[index]), g = Int(rgba[index + 1]), b = Int(rgba[index + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let current = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (current.count + 1, current.red + r, current.green + g, current.blue + b)
        }
        // 数量相同时取键小的那桶，结果不依赖字典顺序。
        guard let best = buckets.max(by: { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key })?.value else {
            return nil
        }
        let color = RGB(
            red: UInt8(best.red / best.count),
            green: UInt8(best.green / best.count),
            blue: UInt8(best.blue / best.count),
        )
        return isNearWhite(color) ? nil : color
    }

    /// 亮度高、几乎没有彩度：当白色处理。
    static func isNearWhite(_ color: RGB) -> Bool {
        let maxChannel = max(color.red, color.green, color.blue)
        let minChannel = min(color.red, color.green, color.blue)
        return relativeLuminance(color) > 0.8 && Int(maxChannel) - Int(minChannel) < 24
    }

    // MARK: - 正文里的链接文字

    /// 文字 + 卡片的消息：卡片单独一块放在文字气泡下面，文字里不再显示这条链接（产品经理 2026-10-19）。
    /// 去掉正文里第一处这条链接（写成 https://、http:// 或没写协议都认，末尾的一个「/」可以没有），再把多出来的空白收拢。
    /// 找不到这条链接、或去掉以后什么都不剩，返回 nil（调用方照原样显示正文 / 只显示卡片）。
    public static func bodyRemovingLink(_ body: String, previewUrl: String) -> String? {
        var forms = [String]()
        let lower = previewUrl.lowercased()
        var rest = previewUrl
        if lower.hasPrefix("https://") {
            rest = String(previewUrl.dropFirst("https://".count))
        } else if lower.hasPrefix("http://") {
            rest = String(previewUrl.dropFirst("http://".count))
        }
        guard !rest.isEmpty else {
            return nil
        }
        var restForms = [rest]
        if rest.hasSuffix("/"), rest.count > 1 {
            restForms.append(String(rest.dropLast()))
        }
        for form in restForms {
            forms.append("https://" + form)
            forms.append("http://" + form)
        }
        forms.append(contentsOf: restForms)

        for form in forms {
            var searchStart = body.startIndex
            while let found = body.range(of: form, options: [.caseInsensitive], range: searchStart..<body.endIndex) {
                searchStart = found.upperBound
                // 前后紧挨着链接里能出现的字符：是别的更长的链接的一段（`evil-jd.com`、`jd.com/abc` 里找 `jd.com/a`）。
                if let before = body[..<found.lowerBound].unicodeScalars.last, isLinkPrefixCharacter(before) {
                    continue
                }
                if continuesLink(body, at: found.upperBound) {
                    continue
                }
                var result = body
                result.replaceSubrange(found, with: " ")
                let collapsed = collapseSpaces(result)
                return collapsed.isEmpty ? nil : collapsed
            }
        }
        return nil
    }

    /// 前面紧挨着这些字符：这一处是更长的链接或邮箱的一段。括号、冒号、引号之类在前面没关系（「(jd.com)」「链接:jd.com」）。
    private static func isLinkPrefixCharacter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else {
            return false
        }
        return CharacterSet.alphanumerics.contains(scalar) || "-_.~/@%".unicodeScalars.contains(scalar)
    }

    private static func isLinkCharacter(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else {
            return false
        }
        if CharacterSet.alphanumerics.contains(scalar) {
            return true
        }
        return "-._~:/?#[]@!$&'()*+,;=%".unicodeScalars.contains(scalar)
    }

    /// 这一处后面还接着链接吗。字母数字和 `- _ ~ / %` 一定是；句末标点（`. , ; : ! ? ) '` 等）只有后面还跟着链接字符时才是
    /// （`jd.com.evil`、`jd.com?x=1`），否则是句子的标点（「看 jd.com，很好」「打开 jd.com.」）。
    private static func continuesLink(_ text: String, at index: String.Index) -> Bool {
        let scalars = text.unicodeScalars
        guard index < text.endIndex else {
            return false
        }
        let position = index.samePosition(in: scalars) ?? scalars.startIndex
        guard position < scalars.endIndex else {
            return false
        }
        let next = scalars[position]
        guard isLinkCharacter(next) else {
            return false
        }
        if CharacterSet.alphanumerics.contains(next) || "-_~/%".unicodeScalars.contains(next) {
            return true
        }
        let following = scalars.index(after: position)
        guard following < scalars.endIndex else {
            return false
        }
        return isLinkCharacter(scalars[following])
    }

    /// 每行里的连续空白收成一个空格，去掉每行首尾空白和首尾空行；换行保留。
    private static func collapseSpaces(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        var result = lines
        while let first = result.first, first.isEmpty { result.removeFirst() }
        while let last = result.last, last.isEmpty { result.removeLast() }
        return result.joined(separator: "\n")
    }
}
