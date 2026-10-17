//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import Foundation

/// rust/links 的注册表对外的两个动作，抽出来是为了不依赖 libsignal 也能测（`LinkRegistry` 遵守它，测试里用假的）。
protocol TellomiLinkClassifying: AnyObject {
    var version: UInt64 { get }
    func classify(preview: String, body: String, message: String) throws -> String
    /// 收到一条带预览的消息、写库之前：要不要留预览、要不要留 `rich`（`{"keep_preview":…,"keep_rich":…}`）。假的注册表不需要。
    func receiveCheck(preview: String, body: String, message: String) throws -> String
    func openPlan(_ url: String) throws -> String
    /// 发送端：开一条链接的作业（ADR-0063 §4.2）。假的注册表不需要。
    func beginSendJob(url: String, context: String) throws -> any TellomiSendJob
    /// 哪个平台认领这个 URL（JSON，有 `provider`）；nil = 注册表里没有平台认领。假的注册表不需要。
    func identify(_ url: String, location: Bool) throws -> String?
}

extension TellomiLinkClassifying {
    func identify(_ url: String, location: Bool) throws -> String? {
        nil
    }

    func receiveCheck(preview: String, body: String, message: String) throws -> String {
        throw OWSGenericError("This registry cannot check a received preview")
    }

    func beginSendJob(url: String, context: String) throws -> any TellomiSendJob {
        throw OWSGenericError("This registry cannot start a send job")
    }
}

/// 接收端的判定（ADR-0063 §5.1 第 4 条）：拿一条收到的预览、消息正文和消息的上下文问 rust/links，得到要画的卡片。
/// 在数据层做，不在 view 绑定里；按「注册表版本 + 预览 + 正文 + 上下文」缓存，热更新换了版本就自然失效。
/// 没有注册表（没装上、解不开）就什么都不判，预览照 Signal 原样显示。
///
/// 日志只记级别、提供方、路由、原因，从不记 URL（§6.5）。
public final class TellomiLinkClassifier: @unchecked Sendable {

    /// 一条收到的 `Preview`：上游的 1–5 号字段，加 1000 号字段的原始字节（`rust/links` 的 `PreviewInput`）。
    public struct PreviewInput: Equatable, Sendable {
        public var url: String
        public var title: String?
        public var description: String?
        public var hasImage: Bool
        public var date: Date?
        public var rich: Data?

        public init(
            url: String,
            title: String? = nil,
            description: String? = nil,
            hasImage: Bool = false,
            date: Date? = nil,
            rich: Data? = nil,
        ) {
            self.url = url
            self.title = title
            self.description = description
            self.hasImage = hasImage
            self.date = date
            self.rich = rich
        }
    }

    private final class CachedCard {
        let card: TellomiLinkCard?
        init(_ card: TellomiLinkCard?) { self.card = card }
    }

    private let registry: (any TellomiLinkClassifying)?
    private let cards = NSCache<NSString, CachedCard>()
    private let log: @Sendable (String) -> Void

    init(registry: (any TellomiLinkClassifying)?, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.registry = registry
        self.log = log
        cards.countLimit = 500
    }

    public var isAvailable: Bool { registry != nil }

    /// 一条收到的预览的卡片；nil 是「没有判定」（没有注册表、判定失败、级别本机不认识）。
    public func classify(
        _ preview: PreviewInput,
        body: String,
        isStory: Bool,
        attachmentContentTypes: [String],
    ) -> TellomiLinkCard? {
        guard let registry else {
            return nil
        }
        let body = bodyForRegistry(body, previewUrl: preview.url)
        guard
            let previewJson = Self.json(Self.previewObject(preview)),
            let messageJson = Self.json([
                "is_story": isStory,
                "attachment_content_types": attachmentContentTypes,
            ])
        else {
            return nil
        }
        let key = [String(registry.version), previewJson, body, messageJson].joined(separator: "\u{0}") as NSString
        if let cached = cards.object(forKey: key) {
            return cached.card
        }
        let card: TellomiLinkCard?
        do {
            card = TellomiLinkCard.parse(try registry.classify(preview: previewJson, body: body, message: messageJson))
        } catch {
            log("classify failed: \(type(of: error))")
            card = nil
        }
        if let card, let reason = card.reason {
            log("card \(card.provider ?? "-")/\(card.route ?? "-") \(card.level.rawValue) (\(reason))")
        }
        cards.setObject(CachedCard(card), forKey: key)
        return card
    }

    /// `receive_check` 的答案（ADR-0063 §7.4）：预览留不留、`rich` 留不留。
    public struct ReceiveCheck: Equatable, Sendable, Decodable {
        public var keepPreview: Bool
        public var keepRich: Bool

        public init(keepPreview: Bool, keepRich: Bool) {
            self.keepPreview = keepPreview
            self.keepRich = keepRich
        }

        private enum CodingKeys: String, CodingKey {
            case keepPreview = "keep_preview"
            case keepRich = "keep_rich"
        }

        static func parse(_ json: String) -> ReceiveCheck? {
            guard let data = json.data(using: .utf8) else {
                return nil
            }
            return try? JSONDecoder().decode(ReceiveCheck.self, from: data)
        }
    }

    /// 收到一条带预览的消息、写库之前的判定（ADR-0063 §5.1 铁律 4、§6.1「超大、畸形的 RichContent」、§7.4）：
    /// 整个预览留不留（URL 合法、在正文里，Story 除外），`rich` 留不留（不超长、解得开）。
    /// nil 是「没有判定」（没有注册表、rust/links 出错、答案读不懂）：调用方退回改动前的行为，绝不能因为这里出错让收消息失败。
    /// 日志只记失败类别，不记 URL。
    public func receiveCheck(
        _ preview: PreviewInput,
        body: String,
        isStory: Bool,
        attachmentContentTypes: [String],
    ) -> ReceiveCheck? {
        guard let registry else {
            return nil
        }
        let body = bodyForRegistry(body, previewUrl: preview.url)
        guard
            let previewJson = Self.json(Self.previewObject(preview)),
            let messageJson = Self.json([
                "is_story": isStory,
                "attachment_content_types": attachmentContentTypes,
            ])
        else {
            return nil
        }
        do {
            guard let check = ReceiveCheck.parse(try registry.receiveCheck(preview: previewJson, body: body, message: messageJson)) else {
                log("receiveCheck gave an answer that cannot be read")
                return nil
            }
            return check
        } catch {
            log("receiveCheck failed: \(type(of: error))")
            return nil
        }
    }

    /// 发送端：开这条链接的作业；没有注册表、或 rust/links 出错是 nil（那就没有 Tellomi 的预览，照 Signal 原样）。
    public func beginSendJob(url: String, context: String) -> (any TellomiSendJob)? {
        guard let registry else {
            return nil
        }
        do {
            return try registry.beginSendJob(url: url, context: context)
        } catch {
            log("begin failed: \(type(of: error))")
            return nil
        }
    }

    /// 点开这条链接的计划（§4.9、§5.5）；没有注册表、或 rust/links 出错、或计划读不懂时是 nil（照 Signal 原样打开）。
    public func openPlan(forUrl url: String) -> TellomiOpenPlan? {
        guard let registry else {
            return nil
        }
        do {
            return TellomiOpenPlan.parse(try registry.openPlan(url))
        } catch {
            log("openPlan failed: \(type(of: error))")
            return nil
        }
    }

    /// 这个 URL 是否冒充某个知名域名（§6.1）：点开前那次提醒用的同一个判断（`open_plan` 的 `lookalike`），
    /// 所以域名标红和点开前的提醒总是一起出现。
    public func lookalike(forUrl url: String) -> String? {
        guard let registry else {
            return nil
        }
        do {
            let plan = try registry.openPlan(url)
            guard
                let data = plan.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return object["lookalike"] as? String
        } catch {
            log("openPlan failed: \(type(of: error))")
            return nil
        }
    }

    // MARK: - http:// 和没写协议的链接（2026-10-17）

    /// owner 2026-10-17 定（ADR-0063 补充「http 与无协议链接」）：正文里写成 `http://…` 或没写协议（`b23.tv/abc`）的链接，
    /// 它的 https 形式归注册表里某个平台（品牌、短链）时，按 https 出卡片；不归注册表的照旧是纯链接。
    /// 第一方（tell.cc、官网）不算：官网徽标、用户卡只认正文里写明的 https（§4.8）。
    /// 发送端只抓 https，从不抓明文 http（`LinkValidator.tellomiHttpsUpgrade`）。
    public func claimsHttpsUpgrade(of httpsUrl: String) -> Bool {
        guard let registry, httpsUrl.range(of: "https://", options: [.anchored, .caseInsensitive]) != nil else {
            return false
        }
        do {
            guard
                let json = try registry.identify(httpsUrl, location: false),
                let data = json.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let provider = object["provider"] as? String
            else {
                return false
            }
            return provider != Self.firstPartyProvider
        } catch {
            log("identify failed: \(type(of: error))")
            return false
        }
    }

    /// rust/links 里第一方的 provider（`limits.rs` 的 `TELLOMI`）。
    static let firstPartyProvider = "tellomi"

    /// 交给 rust/links 判定用的正文：预览是 https、正文里这条链接写成 `http://…` 或没写协议、注册表又认领它时，
    /// 把正文里那一处换成 https 写法，rust/links 的「链接在正文里」（`url_appears_in_body`）才找得到；别的情况原样返回。
    /// 只换判定用的这一份，显示的正文不动。
    func bodyForRegistry(_ body: String, previewUrl: String) -> String {
        Self.body(body, upgradingLinkTo: previewUrl, claims: claimsHttpsUpgrade(of:))
    }

    static func body(_ body: String, upgradingLinkTo previewUrl: String, claims: (String) -> Bool) -> String {
        guard
            let scheme = previewUrl.range(of: "https://", options: [.anchored, .caseInsensitive]),
            !body.contains(previewUrl)
        else {
            return body
        }
        // 同 rust/links：预览 URL 末尾的一个「/」正文里可以没有
        var needle = previewUrl[scheme.upperBound...]
        if needle.hasSuffix("/"), !needle.dropLast().hasSuffix("/"), !needle.dropLast().hasSuffix(":") {
            needle = needle.dropLast()
        }
        guard !needle.isEmpty else {
            return body
        }
        // 每一处都换（后面紧跟的是不是链接的结尾由 rust/links 判，`b23.tv/abcdef` 那一处它不认，后面的 `b23.tv/abc` 还在）
        var replaced = [Range<String.Index>]()
        var searchFrom = body.startIndex
        while let found = body.range(of: needle, range: searchFrom..<body.endIndex) {
            searchFrom = body.index(after: found.lowerBound)
            let before = body[..<found.lowerBound]
            if let http = before.range(of: "http://", options: [.backwards, .anchored, .caseInsensitive]) {
                replaced.append(http.lowerBound..<found.upperBound)
            } else if let last = before.unicodeScalars.last, isPartOfLink(last) {
                // 前面紧挨着字母数字或 URL 里的标点：是另一条更长的链接（`evil-b23.tv`、`https://x/b23.tv`）或邮箱的一段
                continue
            } else {
                replaced.append(found)
            }
        }
        guard !replaced.isEmpty, claims(previewUrl) else {
            return body
        }
        var result = body
        for range in replaced.reversed() {
            result.replaceSubrange(range, with: "https://" + needle)
        }
        return result
    }

    /// 同 rust/links `url_appears_in_body` 的「前面不能是」：ASCII 字母数字和 `-._~:/?#@$&*+=%`。
    private static func isPartOfLink(_ scalar: Unicode.Scalar) -> Bool {
        guard scalar.isASCII else {
            return false
        }
        return ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            || "-._~:/?#@$&*+=%".unicodeScalars.contains(scalar)
    }

    // MARK: - JSON

    static func previewObject(_ preview: PreviewInput) -> [String: Any] {
        var object: [String: Any] = ["url": preview.url, "has_image": preview.hasImage]
        if let title = preview.title, !title.isEmpty {
            object["title"] = title
        }
        if let description = preview.description, !description.isEmpty {
            object["description"] = description
        }
        if let date = preview.date {
            let millis = date.timeIntervalSince1970 * 1000
            if millis >= 1 {
                object["date"] = UInt64(millis)
            }
        }
        if let rich = preview.rich {
            object["rich"] = rich.map { String(format: "%02x", $0) }.joined()
        }
        return object
    }

    static func json(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
