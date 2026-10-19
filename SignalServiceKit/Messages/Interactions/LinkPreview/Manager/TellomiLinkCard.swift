//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import Foundation

/// ADR-0063 §4.2 / §5.1 / §5.3：rust/links 的 `classify` 给一条收到的预览定的卡片
/// （JSON 形状是 `rust/links/src/classify.rs` 的 `Card`，与 Android `TellomiLinkCard.kt`、Desktop `LinkCardType` 同一份）。
/// 发送端写的东西已经按本机注册表和消息正文里的 URL 重新校验过。
public struct TellomiLinkCard: Equatable, Sendable {
    public enum Level: String, Equatable, Sendable {
        case plainLink = "plain_link"
        case generic
        case brand
        case structured
        case firstParty = "first_party"
    }

    /// 注册表给平台起的名字：zh-Hans，可选 zh-Hant，en。
    public struct LocalizedName: Equatable, Sendable {
        public let zhHans: String
        public let zhHant: String?
        public let en: String

        public init(zhHans: String, zhHant: String? = nil, en: String) {
            self.zhHans = zhHans
            self.zhHant = zhHant
            self.en = en
        }

        public func forLocale(_ locale: Locale) -> String {
            guard locale.languageCode == "zh" else {
                return en
            }
            let isTraditional = locale.scriptCode == "Hant" || ["HK", "MO", "TW"].contains(locale.regionCode ?? "")
            return isTraditional ? (zhHant ?? zhHans) : zhHans
        }
    }

    public struct Attr: Equatable, Sendable {
        public let key: String
        public let value: String

        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    /// `type`：user、group、call、sticker 或 official；其余字段随它变。
    public struct FirstParty: Equatable, Sendable {
        public let type: String
        public let display: String?
        public let username: String?
        public let title: String?
        public let memberCount: Int64?
        public let stickerCount: Int64?
        public let path: String?

        public init(
            type: String,
            display: String? = nil,
            username: String? = nil,
            title: String? = nil,
            memberCount: Int64? = nil,
            stickerCount: Int64? = nil,
            path: String? = nil,
        ) {
            self.type = type
            self.display = display
            self.username = username
            self.title = title
            self.memberCount = memberCount
            self.stickerCount = stickerCount
            self.path = path
        }
    }

    public var level: Level
    public var provider: String?
    public var providerName: LocalizedName?
    public var kind: String?
    public var route: String?
    public var title: String?
    public var description: String?
    public var attrs: [Attr]
    public var domain: String?
    public var officialBadge: Bool
    public var firstParty: FirstParty?
    public var lookalike: String?
    public var showImage: Bool
    /// 品牌壳的随包图标文件名（`taobao.png`；只有 brand 级才有）。图标从 App 包里读，不联网（ADR-0063 §九.6）。
    public var icon: String?
    public var tintable: Bool
    public var payment: Bool
    public var reason: String?

    /// 认领档（`claimed`，links-2026101901）的卡：rust/links 的 `reason` 是 `claimed`（抓页面的卡）或
    /// `claimed_no_title`（抓不到标题，退回平台的品牌壳）。
    public var isClaimedTier: Bool { reason == "claimed" || reason == "claimed_no_title" }

    public init(
        level: Level,
        provider: String? = nil,
        providerName: LocalizedName? = nil,
        kind: String? = nil,
        route: String? = nil,
        title: String? = nil,
        description: String? = nil,
        attrs: [Attr] = [],
        domain: String? = nil,
        officialBadge: Bool = false,
        firstParty: FirstParty? = nil,
        lookalike: String? = nil,
        showImage: Bool = true,
        icon: String? = nil,
        tintable: Bool = false,
        payment: Bool = false,
        reason: String? = nil,
    ) {
        self.level = level
        self.provider = provider
        self.providerName = providerName
        self.kind = kind
        self.route = route
        self.title = title
        self.description = description
        self.attrs = attrs
        self.domain = domain
        self.officialBadge = officialBadge
        self.firstParty = firstParty
        self.lookalike = lookalike
        self.showImage = showImage
        self.icon = icon
        self.tintable = tintable
        self.payment = payment
        self.reason = reason
    }

    /// `classify` 返回的 JSON；认不出（新版注册表里旧客户端没有的级别等）就是 nil，气泡照 Signal 原样显示。
    public static func parse(_ json: String) -> TellomiLinkCard? {
        guard let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TellomiLinkCard.self, from: data)
    }
}

// MARK: - JSON

extension TellomiLinkCard.LocalizedName: Decodable {
    private enum CodingKeys: String, CodingKey {
        case zhHans = "zh-Hans"
        case zhHant = "zh-Hant"
        case en
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            zhHans: try container.decode(String.self, forKey: .zhHans),
            zhHant: try container.decodeIfPresent(String.self, forKey: .zhHant),
            en: try container.decode(String.self, forKey: .en),
        )
    }
}

extension TellomiLinkCard.Attr: Decodable {}

extension TellomiLinkCard.FirstParty: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case display
        case username
        case title
        case path
        case memberCount = "member_count"
        case stickerCount = "sticker_count"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try container.decode(String.self, forKey: .type),
            display: try container.decodeIfPresent(String.self, forKey: .display),
            username: try container.decodeIfPresent(String.self, forKey: .username),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            memberCount: try container.decodeIfPresent(Int64.self, forKey: .memberCount),
            stickerCount: try container.decodeIfPresent(Int64.self, forKey: .stickerCount),
            path: try container.decodeIfPresent(String.self, forKey: .path),
        )
    }
}

extension TellomiLinkCard: Decodable {
    private enum CodingKeys: String, CodingKey {
        case level
        case provider
        case kind
        case route
        case title
        case description
        case attrs
        case domain
        case lookalike
        case icon
        case payment
        case reason
        case tintable
        case providerName = "provider_name"
        case officialBadge = "official_badge"
        case firstParty = "first_party"
        case showImage = "show_image"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            level: try container.decode(Level.self, forKey: .level),
            provider: try container.decodeIfPresent(String.self, forKey: .provider),
            providerName: try container.decodeIfPresent(LocalizedName.self, forKey: .providerName),
            kind: try container.decodeIfPresent(String.self, forKey: .kind),
            route: try container.decodeIfPresent(String.self, forKey: .route),
            title: try container.decodeIfPresent(String.self, forKey: .title),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            attrs: try container.decodeIfPresent([Attr].self, forKey: .attrs) ?? [],
            domain: try container.decodeIfPresent(String.self, forKey: .domain),
            officialBadge: try container.decodeIfPresent(Bool.self, forKey: .officialBadge) ?? false,
            firstParty: try container.decodeIfPresent(FirstParty.self, forKey: .firstParty),
            lookalike: try container.decodeIfPresent(String.self, forKey: .lookalike),
            showImage: try container.decodeIfPresent(Bool.self, forKey: .showImage) ?? true,
            icon: try container.decodeIfPresent(String.self, forKey: .icon),
            tintable: try container.decodeIfPresent(Bool.self, forKey: .tintable) ?? false,
            payment: try container.decodeIfPresent(Bool.self, forKey: .payment) ?? false,
            reason: try container.decodeIfPresent(String.self, forKey: .reason),
        )
    }
}

extension TellomiLinkCard.Level: Decodable {}
