//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import SignalUI
import UIKit

/// 动态正文里的网址（帖子、帖子详情、长文）：认出来、标成链接色加下划线，可以点。
///
/// 交互参考 Telegram 的行为（不用它的代码）：短按直接打开；长按弹出操作表，标题是网址，「打开链接」「复制」「取消」。
/// 打开一律走 `TellomiExternalLinkOpener`（和聊天里点链接同一个出口：注册表的 `open_plan`、仿冒域名先问、支付类只进浏览器）。
/// 这一版只做「可点」；链接卡片（`TellomiLinkCard`）按产品排期下一步再接，抓取规则跟聊天一致。
enum FeedTextLinks {

    struct Link: Equatable {
        /// 在原文（`NSString` / UTF-16）里的范围。
        var range: NSRange
        var url: URL
    }

    // NSDataDetector 建起来很贵：复用一个（聊天 `CVComponentState` 同样做法）。
    private static let detector: NSDataDetector? = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// 认出正文里的网址。只要 http(s)：`mailto:`、`tel:`、别的 scheme 不算（聊天里点也不走 `open_plan`）。
    /// 没写 scheme 的（`example.com/a`）补成 `https://`，不是 `http://`。
    static func detect(in text: String) -> [Link] {
        guard let detector, !text.isEmpty else { return [] }
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, options: [], range: whole).compactMap { match in
            // 链接在第一个全角中文标点 / 右括号前结束（产品 2026-10-24，和聊天同一个 `TellomiLinkPunctuation`）。
            guard
                let trimmed = TellomiLinkPunctuation.trimmedLink(range: match.range, url: match.url, in: text, detector: detector),
                let found = trimmed.url
            else { return nil }
            let original = (text as NSString).substring(with: trimmed.range)
            guard let url = normalized(found, original: original) else { return nil }
            return Link(range: trimmed.range, url: url)
        }
    }

    static func normalized(_ url: URL, original: String) -> URL? {
        let lowerOriginal = original.lowercased()
        let typedScheme = lowerOriginal.hasPrefix("http://") || lowerOriginal.hasPrefix("https://")
        if typedScheme {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return url
        }
        // 原文里写了别的 scheme（mailto:、tel:、ftp: …）：不算链接
        if original.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) != nil {
            return nil
        }
        // 识别器给没 scheme 的补了 http://；改成 https://。邮箱地址（被识别成 mailto:）不算。
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return URL(string: "https://" + original)
    }

    /// 某个字符落在哪条链接上。
    static func link(atCharacter index: Int, in links: [Link]) -> Link? {
        return links.first { NSLocationInRange(index, $0.range) }
    }

    /// 带链接样式的文字：链接色 + 下划线，再记一个 `.link` 属性（UITextView 直接认；UILabel 只看样式，点击靠 `FeedLinkLabel`）。
    static func attributed(_ text: String, font: UIFont, color: UIColor, links: [Link]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        apply(links, to: result)
        return result
    }

    /// 给已经排好字体的文字（长文）加上链接。
    static func apply(_ links: [Link], to text: NSMutableAttributedString) {
        for link in links where NSMaxRange(link.range) <= text.length {
            text.addAttributes([
                .link: link.url,
                .foregroundColor: UIColor.Signal.accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: link.range)
        }
    }

    // MARK: - 打开 / 长按

    /// 短按：直接打开。
    @MainActor
    static func open(_ url: URL, from presenter: UIViewController?) {
        guard let presenter = presenter ?? CurrentAppContext().frontmostViewController() else { return }
        TellomiExternalLinkOpener.open(url, from: presenter, inApp: .handOffToSystem)
    }

    /// 长按：操作表（标题是网址）：打开链接 / 复制 / 取消。
    @MainActor
    static func showMenu(for url: URL, from presenter: UIViewController?) {
        guard let presenter = presenter ?? CurrentAppContext().frontmostViewController() else { return }
        let sheet = ActionSheetController(title: url.absoluteString)
        sheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("MESSAGE_ACTION_LINK_OPEN_LINK", comment: "Label for button to open a link."),
            style: .default,
        ) { [weak presenter] _ in
            FeedTextLinks.open(url, from: presenter)
        })
        sheet.addAction(ActionSheetAction(title: CommonStrings.copyButton, style: .default) { [weak presenter] _ in
            UIPasteboard.general.string = url.absoluteString
            presenter?.presentToast(text: OWSLocalizedString("TELLOMI_LINKS_LINK_COPIED", comment: "Tellomi (ADR-0063 §5.5): toast after the link was copied because nothing could open it"))
        })
        sheet.addAction(OWSActionSheets.cancelAction)
        presenter.presentActionSheet(sheet)
    }
}

/// 正文用的 UILabel：只在点中链接时接手势，别的地方的点击照旧往上交（整行「打开帖子」不受影响）。
/// 支持 `numberOfLines` 截断（长文卡片只露开头几行）：排字时用同样的行数和断行方式。
final class FeedLinkLabel: UILabel {
    private(set) var links = [FeedTextLinks.Link]()
    /// 点 / 长按链接时用来弹浏览器和操作表；nil 时用最前面的页面。
    weak var presenter: UIViewController?
    /// 测试 / 宿主可以换掉默认的打开方式。
    var onOpen: ((URL) -> Void)?
    var onMenu: ((URL) -> Void)?

    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
    private lazy var press = UILongPressGestureRecognizer(target: self, action: #selector(didLongPress(_:)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(tap)
        addGestureRecognizer(press)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 设正文。没有链接时和普通 UILabel 一样（不接任何手势）。
    func setText(_ text: String?, font: UIFont, color: UIColor) {
        guard let text, !text.isEmpty else {
            links = []
            attributedText = nil
            isUserInteractionEnabled = false
            return
        }
        links = FeedTextLinks.detect(in: text)
        attributedText = FeedTextLinks.attributed(text, font: font, color: color, links: links)
        isUserInteractionEnabled = !links.isEmpty
        accessibilityTraits = links.isEmpty ? .staticText : [.staticText, .link]
    }

    func link(at point: CGPoint) -> FeedTextLinks.Link? {
        guard !links.isEmpty, let attributedText, attributedText.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: attributedText)
        let container = NSTextContainer(size: bounds.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = numberOfLines
        container.lineBreakMode = lineBreakMode
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphRange = layout.glyphRange(for: container)
        guard glyphRange.length > 0 else { return nil }
        // UILabel 把字竖着居中画：比字高的标签要把点挪回排字的坐标
        let used = layout.usedRect(for: container)
        let offset = max(0, (bounds.height - used.height) / 2)
        let point = CGPoint(x: point.x, y: point.y - offset)
        let glyph = layout.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        guard NSLocationInRange(glyph, glyphRange) else { return nil }
        // 点在字的外面（行尾空白、最后一行下面）不算
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.insetBy(dx: -6, dy: -4).contains(point) else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        return FeedTextLinks.link(atCharacter: character, in: links)
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === tap || gestureRecognizer === press else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        return link(at: gestureRecognizer.location(in: self)) != nil
    }

    @objc private func didTap(_ gesture: UITapGestureRecognizer) {
        guard let link = link(at: gesture.location(in: self)) else { return }
        if let onOpen {
            onOpen(link.url)
        } else {
            FeedTextLinks.open(link.url, from: presenter)
        }
    }

    @objc private func didLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let link = link(at: gesture.location(in: self)) else { return }
        if let onMenu {
            onMenu(link.url)
        } else {
            FeedTextLinks.showMenu(for: link.url, from: presenter)
        }
    }
}
