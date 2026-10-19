//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// 链接卡片统一样式（产品经理 2026-10-19 定稿，参照 iOS「信息」App）：四种样式怎么选、两行字怎么来、
/// 横条底色怎么从图标取、字用黑还是白、文字 + 卡片时正文里怎么去掉链接。
final class TellomiLinkCardStyleTest: XCTestCase {

    typealias Style = TellomiLinkCardStyle

    // MARK: - 四种样式

    // MARK: - 指南针只给完全没信息的卡（产品经理 2026-10-19 晚）

    func testTheCompassIsOnlyForACardWithNothingAndNeverForAClaimedCardWithATitle() {
        // 认领档：抓到网站图标是图标横条（右边图标）；什么都没抓到是标题 + 域名，右边不画指南针。
        XCTAssertFalse(Style.showsCompass(kind: .iconStrip, isClaimed: true))
        XCTAssertFalse(Style.showsCompass(kind: .textStrip, isClaimed: true))
        // 其余卡照 2026-10-19 定稿。
        XCTAssertTrue(Style.showsCompass(kind: .textStrip, isClaimed: false))
        XCTAssertTrue(Style.showsCompass(kind: .domainStrip, isClaimed: false))
        XCTAssertTrue(Style.showsCompass(kind: .domainStrip, isClaimed: true), "连标题都没有：完全没信息")
        XCTAssertFalse(Style.showsCompass(kind: .iconStrip, isClaimed: false))
        XCTAssertFalse(Style.showsCompass(kind: .largeImage, isClaimed: false))
    }

    func testAClaimedCardIsTheOneRustLinksSaysIsClaimed() {
        XCTAssertTrue(TellomiLinkCard(level: .generic, domain: "jd.com", reason: "claimed").isClaimedTier)
        XCTAssertTrue(TellomiLinkCard(level: .brand, provider: "jd", domain: "jd.com", showImage: false, reason: "claimed_no_title").isClaimedTier)
        XCTAssertFalse(TellomiLinkCard(level: .generic, domain: "wikipedia.org").isClaimedTier)
        XCTAssertFalse(TellomiLinkCard(level: .brand, provider: "meituan", domain: "meituan.com", showImage: false).isClaimedTier)
        let parsed = TellomiLinkCard.parse(##"{"level":"generic","title":"Apple iPhone 15","domain":"jd.com","show_image":false,"icon":null,"tintable":true,"payment":false,"reason":"claimed"}"##)
        XCTAssertEqual(parsed?.isClaimedTier, true)
    }

    func testLargeImageNeedsImageAndLargeLayout() {
        XCTAssertEqual(Style.kind(layout: .largeImage, hasImage: true, hasTitle: true, isPlainLink: false), .largeImage)
        XCTAssertEqual(Style.kind(layout: .largeImage, hasImage: true, hasTitle: false, isPlainLink: false), .largeImage)
    }

    func testLargeLayoutWithoutImageFallsBackToText() {
        // 图没了（下载失败、没有 blurHash）：不画空的大图框。
        XCTAssertEqual(Style.kind(layout: .largeImage, hasImage: false, hasTitle: true, isPlainLink: false), .textStrip)
        XCTAssertEqual(Style.kind(layout: .largeImage, hasImage: false, hasTitle: false, isPlainLink: false), .domainStrip)
    }

    func testSmallImageIsIconStrip() {
        XCTAssertEqual(Style.kind(layout: .icon, hasImage: true, hasTitle: true, isPlainLink: false), .iconStrip)
        // 只有图标没有标题（品牌壳没有平台名时）：还是横条，标题位置空着、只出域名。
        XCTAssertEqual(Style.kind(layout: .icon, hasImage: true, hasTitle: false, isPlainLink: false), .iconStrip)
    }

    func testUndecidedLayoutWithImageNeverGuessesLarge() {
        XCTAssertEqual(Style.kind(layout: nil, hasImage: true, hasTitle: true, isPlainLink: false), .iconStrip)
    }

    func testNoImage() {
        XCTAssertEqual(Style.kind(layout: .noImage, hasImage: false, hasTitle: true, isPlainLink: false), .textStrip)
        XCTAssertEqual(Style.kind(layout: nil, hasImage: false, hasTitle: true, isPlainLink: false), .textStrip)
        XCTAssertEqual(Style.kind(layout: .noImage, hasImage: false, hasTitle: false, isPlainLink: false), .domainStrip)
        // 版式说没有图、却有图（不该发生）：照没有图画。
        XCTAssertEqual(Style.kind(layout: .noImage, hasImage: true, hasTitle: true, isPlainLink: false), .textStrip)
    }

    func testPlainLinkIsAlwaysDomainStrip() {
        for layout: Style.Layout? in [.largeImage, .icon, .noImage, nil] {
            for hasImage in [true, false] {
                XCTAssertEqual(Style.kind(layout: layout, hasImage: hasImage, hasTitle: true, isPlainLink: true), .domainStrip)
            }
        }
    }

    // MARK: - 两行字

    func testTextKeepsTitleAndDomain() {
        XCTAssertEqual(
            Style.text(title: "百度一下，你就知道", domain: "baidu.com", urlString: "https://www.baidu.com/"),
            Style.Text(title: "百度一下，你就知道", domain: "baidu.com"),
        )
    }

    func testTextCollapsesWhitespaceAndDropsEmptyTitle() {
        XCTAssertEqual(
            Style.text(title: "  China UnionPay |\r\n   中国银联 ", domain: "unionpay.com", urlString: nil),
            Style.Text(title: "China UnionPay | 中国银联", domain: "unionpay.com"),
        )
        XCTAssertEqual(Style.text(title: " \n ", domain: "jd.com", urlString: nil), Style.Text(title: nil, domain: "jd.com"))
        XCTAssertEqual(Style.text(title: nil, domain: "jd.com", urlString: nil), Style.Text(title: nil, domain: "jd.com"))
    }

    func testTitleEqualToDomainIsNotRepeated() {
        // 以前的纯链接卡把域名当标题：现在只出一行域名。
        XCTAssertEqual(Style.text(title: "Baidu.com", domain: "baidu.com", urlString: nil), Style.Text(title: nil, domain: "baidu.com"))
    }

    func testDomainFallsBackToHost() {
        XCTAssertEqual(Style.text(title: "Apple", domain: nil, urlString: "https://www.Apple.com/cn/"), Style.Text(title: "Apple", domain: "apple.com"))
        XCTAssertEqual(Style.text(title: nil, domain: " ", urlString: "jd.com/abc"), Style.Text(title: nil, domain: "jd.com"))
        XCTAssertNil(Style.text(title: "x", domain: nil, urlString: nil))
        XCTAssertNil(Style.text(title: "x", domain: nil, urlString: "https://"))
    }

    func testHostForDisplay() {
        XCTAssertEqual(Style.hostForDisplay("https://WWW.163.com/news"), "163.com")
        XCTAssertEqual(Style.hostForDisplay("m.jd.com"), "m.jd.com")
        XCTAssertEqual(Style.hostForDisplay("https://www."), "www.")
        XCTAssertNil(Style.hostForDisplay(""))
    }

    // MARK: - 对比度和字色

    func testRelativeLuminanceEndpoints() {
        XCTAssertEqual(Style.relativeLuminance(.white), 1, accuracy: 1e-9)
        XCTAssertEqual(Style.relativeLuminance(.black), 0, accuracy: 1e-9)
    }

    func testContrastRatioMatchesWcag() {
        XCTAssertEqual(Style.contrastRatio(.white, .black), 21, accuracy: 1e-9)
        XCTAssertEqual(Style.contrastRatio(.black, .white), 21, accuracy: 1e-9)
        XCTAssertEqual(Style.contrastRatio(.white, .white), 1, accuracy: 1e-9)
        // WCAG 文档里的例子：#777777 对白约 4.48。
        XCTAssertEqual(Style.contrastRatio(RGB(0x77, 0x77, 0x77), .white), 4.48, accuracy: 0.01)
    }

    func testTextColorPicksHigherContrast() {
        XCTAssertEqual(Style.textColor(on: RGB(0x29, 0x32, 0xE1)), .white) // 百度蓝
        XCTAssertEqual(Style.textColor(on: RGB(0xC8, 0x1E, 0x1E)), .white) // 网易红
        XCTAssertEqual(Style.textColor(on: RGB(0xE1, 0x25, 0x1B)), .white) // 京东红
        XCTAssertEqual(Style.textColor(on: RGB(0xFF, 0xD1, 0x00)), .black) // 美团黄
        XCTAssertEqual(Style.textColor(on: RGB(0xE9, 0xE9, 0xEB)), .black) // 浅灰
        XCTAssertEqual(Style.textColor(on: RGB(0x26, 0x26, 0x28)), .white) // 深灰
        XCTAssertEqual(Style.textColor(on: .white), .black)
        XCTAssertEqual(Style.textColor(on: .black), .white)
    }

    func testChosenTextColorAlwaysMeetsLargeTextContrast() {
        // 黑白里取高的那个，对任何底色都 ≥ 4.5 不一定成立，但 ≥ 约 4.58（中灰附近最低）。
        var worst = 21.0
        for r in stride(from: 0, through: 255, by: 17) {
            for g in stride(from: 0, through: 255, by: 17) {
                for b in stride(from: 0, through: 255, by: 17) {
                    let bg = RGB(UInt8(r), UInt8(g), UInt8(b))
                    worst = min(worst, Style.contrastRatio(bg, Style.textColor(on: bg)))
                }
            }
        }
        XCTAssertGreaterThanOrEqual(worst, 4.5)
    }

    // MARK: - 取色

    private func RGB(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Style.RGB {
        Style.RGB(red: r, green: g, blue: b)
    }

    /// size × size 的图：外圈 `ring` 宽的一圈是 `border`，里面是 `fill`；alpha 都是 255，除非给了 nil（透明）。
    private func icon(size: Int = 32, ring: Int = 3, border: Style.RGB?, fill: Style.RGB?) -> [UInt8] {
        var pixels = [UInt8]()
        for y in 0..<size {
            for x in 0..<size {
                let isRing = x < ring || y < ring || x >= size - ring || y >= size - ring
                if let color = isRing ? border : fill {
                    pixels += [color.red, color.green, color.blue, 255]
                } else {
                    pixels += [0, 0, 0, 0]
                }
            }
        }
        return pixels
    }

    func testSolidBackgroundIconTakesBackgroundColor() {
        // 白色 logo 画在蓝底上（百度）：取蓝，不取白。
        let blue = RGB(0x29, 0x32, 0xE1)
        var pixels = icon(border: blue, fill: blue)
        // 中间画一块白色 logo，面积比底还大。
        for y in 6..<26 {
            for x in 6..<26 {
                let i = (y * 32 + x) * 4
                pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255
            }
        }
        XCTAssertEqual(Style.dominantColor(rgba: pixels, width: 32, height: 32), blue)
    }

    func testWhiteBackgroundIconGivesNeutral() {
        // 白底图标（qq.com）、外圈白边的图标（豆瓣）：返回 nil，用中性灰。
        XCTAssertNil(Style.dominantColor(rgba: icon(border: .white, fill: RGB(0x2E, 0x96, 0x3D)), width: 32, height: 32))
        XCTAssertNil(Style.dominantColor(rgba: icon(border: RGB(0xFA, 0xFA, 0xF8), fill: RGB(0, 0, 0)), width: 32, height: 32))
    }

    func testTransparentBackgroundUsesOpaquePixels() {
        // 透明底上的红色 logo：外圈几乎全透明，改看全图不透明的像素。
        let red = RGB(0xC8, 0x1E, 0x1E)
        XCTAssertEqual(Style.dominantColor(rgba: icon(border: nil, fill: red), width: 32, height: 32), red)
    }

    func testFullyTransparentOrBadSizeGivesNil() {
        XCTAssertNil(Style.dominantColor(rgba: icon(border: nil, fill: nil), width: 32, height: 32))
        XCTAssertNil(Style.dominantColor(rgba: [1, 2, 3], width: 32, height: 32))
        XCTAssertNil(Style.dominantColor(rgba: [], width: 0, height: 0))
    }

    func testAveragesWithinTheWinningBucket() {
        // 底色有轻微噪点（JPEG）：同一桶里取平均。
        var pixels = icon(border: RGB(0xE0, 0x20, 0x10), fill: RGB(0xE0, 0x20, 0x10))
        for i in stride(from: 0, to: pixels.count, by: 8) {
            pixels[i] = 0xE4
        }
        let color = Style.dominantColor(rgba: pixels, width: 32, height: 32)
        XCTAssertEqual(color?.red, 0xE2)
        XCTAssertEqual(color?.green, 0x20)
        XCTAssertEqual(color?.blue, 0x10)
    }

    func testDarkBackgroundIsKept() {
        let dark = RGB(0x10, 0x10, 0x10)
        XCTAssertEqual(Style.dominantColor(rgba: icon(border: dark, fill: .white), width: 32, height: 32), dark)
    }

    func testTinyImage() {
        let yellow = RGB(0xFF, 0xD1, 0x00)
        XCTAssertEqual(Style.dominantColor(rgba: [yellow.red, yellow.green, yellow.blue, 255], width: 1, height: 1), yellow)
    }

    // MARK: - 文字 + 卡片：正文里去掉链接

    func testRemovesLinkFromBody() {
        XCTAssertEqual(Style.bodyRemovingLink("看看这个 https://www.jd.com/ 很便宜", previewUrl: "https://www.jd.com/"), "看看这个 很便宜")
        XCTAssertEqual(Style.bodyRemovingLink("https://www.jd.com 很便宜", previewUrl: "https://www.jd.com/"), "很便宜")
        XCTAssertEqual(Style.bodyRemovingLink("看这个https://b23.tv/abc", previewUrl: "https://b23.tv/abc"), "看这个")
    }

    func testRemovesSchemelessAndHttpForms() {
        XCTAssertEqual(Style.bodyRemovingLink("去 b23.tv/abc 看", previewUrl: "https://b23.tv/abc"), "去 看")
        XCTAssertEqual(Style.bodyRemovingLink("去 http://b23.tv/abc 看", previewUrl: "https://b23.tv/abc"), "去 看")
    }

    func testSentencePunctuationAfterLinkStays() {
        XCTAssertEqual(Style.bodyRemovingLink("打开 https://jd.com, 很好", previewUrl: "https://jd.com"), "打开 , 很好")
        XCTAssertEqual(Style.bodyRemovingLink("打开 https://jd.com。", previewUrl: "https://jd.com"), "打开 。")
    }

    func testDoesNotCutLongerLinks() {
        XCTAssertNil(Style.bodyRemovingLink("看 https://jd.com/abcdef", previewUrl: "https://jd.com/abc"))
        XCTAssertNil(Style.bodyRemovingLink("看 evil-jd.com", previewUrl: "https://jd.com"))
        XCTAssertNil(Style.bodyRemovingLink("看 https://jd.com.evil.cn", previewUrl: "https://jd.com"))
        XCTAssertNil(Style.bodyRemovingLink("看 https://jd.com?x=1", previewUrl: "https://jd.com"))
    }

    func testKeepsNewlines() {
        XCTAssertEqual(Style.bodyRemovingLink("第一行\nhttps://jd.com\n第三行", previewUrl: "https://jd.com"), "第一行\n\n第三行")
    }

    func testOnlyLinkLeavesNothing() {
        XCTAssertNil(Style.bodyRemovingLink("  https://jd.com  ", previewUrl: "https://jd.com"))
        XCTAssertNil(Style.bodyRemovingLink("没有链接", previewUrl: "https://jd.com"))
        XCTAssertNil(Style.bodyRemovingLink("x", previewUrl: "https://"))
    }

    func testOnlyFirstOccurrenceRemoved() {
        XCTAssertEqual(Style.bodyRemovingLink("jd.com 和 jd.com", previewUrl: "https://jd.com"), "和 jd.com")
    }
}

/// 产品经理 2026-10-19 批准的 Safari UA 主机（等 `bot/link-cards-weixin-ua-r1` 合进来后并进精确白名单）。
final class TellomiLinkBrowserUserAgentPendingTest: XCTestCase {
    func testOnlyTheApprovedExactHostsAreListed() {
        let hosts = TellomiLinkBrowserUserAgentPending.approvedHosts
        XCTAssertEqual(hosts, [
            "jd.com", "www.jd.com", "m.jd.com", "item.jd.com", "item.m.jd.com",
            "m.douban.com",
            "m.dianping.com",
            "y.qq.com", "i.y.qq.com", "i2.y.qq.com",
            "v.youku.com", "m.youku.com",
            "www.kuaishou.com", "m.kuaishou.com",
            "www.iqiyi.com", "m.iqiyi.com", "iqiyi.com",
        ])
        XCTAssertFalse(hosts.contains { $0.contains("*") }, "精确匹配，不用通配")
        XCTAssertFalse(hosts.contains { $0.hasSuffix("baidu.com") }, "百度不需要换 UA")
        XCTAssertFalse(hosts.contains("mp.weixin.qq.com"), "公众号在 weixin-ua 分支的名单里，不重复列")
        XCTAssertFalse(hosts.contains("www.douban.com") || hosts.contains("movie.douban.com"), "豆瓣只批了移动版")
        XCTAssertFalse(hosts.contains("www.dianping.com"), "大众点评只批了移动版")
        XCTAssertFalse(hosts.contains("qq.com") || hosts.contains("www.qq.com"), "QQ 音乐之外的 qq.com 不在内")
    }
}
