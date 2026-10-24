//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit

/// 按 rust/links 定的级别改写一条已收到预览的显示（ADR-0063 §5.1，card-visual §3.7）：标题、副行、域名行都取
/// `TellomiLinkDisplay`（发送端写的描述从不显示），品牌壳、用户卡、官网卡、纯链接不显示发送端的图。
/// 包一层而不是改 `LinkPreviewSent`：群邀请卡、通话卡、抓取前的状态都不受影响。
///
/// 域名行里已经带了发布日期时（视频），`date` 返回 nil，气泡不会再加一遍。
public final class TellomiLinkPreviewCardState: LinkPreviewState {

    private let base: LinkPreviewState
    private let display: TellomiLinkDisplay
    private let showsImage: Bool

    /// 消息除了这条链接什么都没有（card-visual §3.5）：气泡只画卡片，不画链接文字；完整链接在长按菜单里能复制。
    public let isCardOnly: Bool

    /// 数据层按 rust/links 定的版式，以及从卡片自己的图取的颜色（card-visual §3.2 / §3.3）；没有决定时是 `.none`，照 Signal 原样。
    public let visual: TellomiLinkVisual.Visual

    /// Tellomi 自己对象的卡片（用户 / 群 / 贴纸包 / 官网，card-visual §5.2）：头像或封面 + 标题 + 副行 + 底部一个动作按钮。不是就是 nil。
    public let firstParty: TellomiFirstPartyCard.Display?

    /// 品牌壳的随包图标（card-visual §3.9）：卡片的“图”是它，不是发送端的图；没有就是 nil。
    public let bundledIcon: TellomiLinkIcon.Icon?

    /// 用户卡：本机认识这个人时，本地库里的头像（联系人照片 / 对方的资料头像 / 默认头像，card-visual §5.2）；不认识就是 nil（默认头像占位）。
    /// 在数据层（有事务的地方）就取好：会话页的 cell 配置阶段不许开数据库事务。
    public let userAvatar: UIImage?

    /// 不响应点击：还没接受的会话（消息请求）里的域名卡，陌生人发来的链接不能一点就打开
    /// （card-visual §7.3；同 Telegram iOS 对可疑发件人的 `isSuspiciousPeer`）。
    public let isInert: Bool

    /// 图标横条的底色：从卡片显示的那张小图（站点图标 / 方形小图 / 随包图标）取的主色（`TellomiLinkCardStyle.dominantColor`）。
    /// nil：没有图、取不到颜色（白底图标、透明图）——横条用中性灰。只对 `iconStrip` 有意义（产品经理 2026-10-19 定稿）。
    public let stripColor: TellomiLinkCardStyle.RGB?

    /// 认领档（`claimed`）的卡（`TellomiLinkCard.isClaimedTier`）。指南针只给只有域名的横条（产品经理 2026-10-24），这一项不再影响它。
    public let isClaimed: Bool

    public init(
        base: LinkPreviewState,
        display: TellomiLinkDisplay,
        showsImage: Bool,
        isCardOnly: Bool = false,
        visual: TellomiLinkVisual.Visual = .none,
        firstParty: TellomiFirstPartyCard.Display? = nil,
        bundledIcon: TellomiLinkIcon.Icon? = nil,
        userAvatar: UIImage? = nil,
        isInert: Bool = false,
        stripColor: TellomiLinkCardStyle.RGB? = nil,
        isClaimed: Bool = false,
    ) {
        self.base = base
        self.display = display
        self.showsImage = showsImage
        self.isCardOnly = isCardOnly
        self.visual = visual
        self.firstParty = firstParty
        self.bundledIcon = bundledIcon
        self.userAvatar = userAvatar
        self.isInert = isInert
        self.stripColor = stripColor
        self.isClaimed = isClaimed
    }

    // MARK: 统一样式（产品经理 2026-10-19，参照 iOS「信息」App）

    /// 这张卡用四种样式里的哪一种；第一方卡（用户 / 群 / 贴纸 / 官网）不走统一样式，是 nil。
    public var cardStyle: TellomiLinkCardStyle.Kind? {
        guard firstParty == nil else {
            return nil
        }
        let layout: TellomiLinkCardStyle.Layout? = switch visual.layout {
        case .largeImage: .largeImage
        case .icon: .icon
        case .noImage: .noImage
        case .firstParty, nil: nil
        }
        return TellomiLinkCardStyle.kind(
            layout: layout,
            hasImage: hasLoadedImageOrBlurHash,
            hasTitle: cardText?.title != nil,
            isPlainLink: isPlainLink,
        )
    }

    /// 横条右边画不画指南针（`TellomiLinkCardStyle.showsCompass`）；不走统一样式的卡是 false。
    public var showsCompass: Bool {
        guard let cardStyle else {
            return false
        }
        return TellomiLinkCardStyle.showsCompass(kind: cardStyle, isClaimed: isClaimed)
    }

    /// 卡片上的两行字：标题（页面的 og:title / title；品牌壳是平台名）+ 域名。副行一律不显示。
    public var cardText: TellomiLinkCardStyle.Text? {
        TellomiLinkCardStyle.text(
            title: isPlainLink ? nil : display.title?.filterForDisplay,
            domain: display.domain?.filterForDisplay ?? (isPlainLink ? display.title?.filterForDisplay : nil),
            urlString: urlString,
        )
    }

    /// 版式；图片没有显示（品牌壳、用户卡……）或没有决定时是 nil。
    public var layout: TellomiLinkVisual.Layout? { visual.layout }

    /// 染色卡的底色和字色（浅 / 深两套，跟着系统外观走）；不染色是 nil。
    public var tintColors: (background: UIColor, text: UIColor)? {
        guard
            let tint = visual.tint,
            tint.tinted,
            let light = tint.light,
            let dark = tint.dark
        else {
            return nil
        }
        func color(_ rgb: TellomiLinkVisual.RGB) -> UIColor {
            UIColor(red: CGFloat(rgb.red) / 255, green: CGFloat(rgb.green) / 255, blue: CGFloat(rgb.blue) / 255, alpha: 1)
        }
        func dynamic(light: TellomiLinkVisual.RGB, dark: TellomiLinkVisual.RGB) -> UIColor {
            UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) }
        }
        return (
            background: dynamic(light: light.background, dark: dark.background),
            text: dynamic(light: light.text, dark: dark.text),
        )
    }

    /// 无图卡（card-visual §3.5 / §3.7）：域名当标题，行尾一个链接图标，没有别的行。
    public var isPlainLink: Bool { display.isPlainLink }

    /// 域名冒充知名域名（ADR-0063 §6.1）：标题用危险色。
    public var isLookalike: Bool { display.isLookalike }

    // MARK: LinkPreviewState

    public var isLoaded: Bool { base.isLoaded }

    public var urlString: String? { base.urlString }

    public var displayDomain: String? { display.domain?.filterForDisplay.nilIfEmpty }

    public var title: String? { display.title?.filterForDisplay.nilIfEmpty }

    public var previewDescription: String? { display.description?.filterForDisplay.nilIfEmpty }

    public var date: Date? { nil }

    public var imageState: LinkPreviewImageState {
        if bundledIcon != nil {
            return .loaded
        }
        return showsImage ? base.imageState : .none
    }

    public func imageAsync(thumbnailQuality: AttachmentThumbnailQuality, completion: @escaping (UIImage) -> Void) {
        if let bundledIcon {
            completion(UIImage(cgImage: bundledIcon.image))
            return
        }
        guard showsImage else {
            owsFailDebug("Should not be called.")
            return
        }
        base.imageAsync(thumbnailQuality: thumbnailQuality, completion: completion)
    }

    public func imageCacheKey(thumbnailQuality: AttachmentThumbnailQuality) -> LinkPreviewImageCacheKey? {
        if let bundledIcon {
            return LinkPreviewImageCacheKey(id: nil, urlString: "tellomi-icon:\(bundledIcon.name)", thumbnailQuality: thumbnailQuality)
        }
        return showsImage ? base.imageCacheKey(thumbnailQuality: thumbnailQuality) : nil
    }

    public var imagePixelSize: CGSize {
        if let bundledIcon {
            return CGSize(width: bundledIcon.pixelWidth, height: bundledIcon.pixelHeight)
        }
        return showsImage ? base.imagePixelSize : .zero
    }

    public var isGroupInviteLink: Bool { base.isGroupInviteLink }

    public var isCallLink: Bool { base.isCallLink }

    public var conversationStyle: ConversationStyle? { base.conversationStyle }
}
