//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// card-visual §3.2 / §3.3 / §3.8（tellomi/tellomi#1423）：卡片的版式和按自己图片取的颜色由 rust/links 定
/// （`layout` / `tint`），客户端只读结果、不自己算。与 Android `TellomiLinkVisualTest`、Desktop `linkCardVisual_test` 同一批用例。
final class TellomiLinkVisualTest: XCTestCase {

    private let orange = """
    {"tinted":true,"source":"#FE7500","light":{"background":"#FE7500","text":"#000000"},"dark":{"background":"#994600","text":"#FFFFFF"}}
    """
    private let card = TellomiLinkCard(level: .generic, domain: "bilibili.com", tintable: true)

    private struct FakeBridge: TellomiLinkVisual.Bridge {
        var layoutName = "icon"
        var tintJson = ""
        var fails = false
        var onLayout: (UInt32, UInt32, String, String) -> Void = { _, _, _, _ in }
        var onTint: (String, UInt32, UInt32, Data) -> Void = { _, _, _, _ in }

        func layout(imageWidth: UInt32, imageHeight: UInt32, kind: String, level: String) throws -> String {
            struct Failure: Error {}
            if fails { throw Failure() }
            onLayout(imageWidth, imageHeight, kind, level)
            return layoutName
        }

        func tint(layout: String, width: UInt32, height: UInt32, rgba: Data) throws -> String {
            struct Failure: Error {}
            if fails { throw Failure() }
            onTint(layout, width, height, rgba)
            return tintJson
        }
    }

    func testTheFourShapesAreReadAnythingElseIsNoDecision() {
        XCTAssertEqual(TellomiLinkVisual.parseLayout("first_party"), .firstParty)
        XCTAssertEqual(TellomiLinkVisual.parseLayout("large_image"), .largeImage)
        XCTAssertEqual(TellomiLinkVisual.parseLayout("icon"), .icon)
        XCTAssertEqual(TellomiLinkVisual.parseLayout("no_image"), .noImage)
        XCTAssertNil(TellomiLinkVisual.parseLayout("hologram"))
        XCTAssertNil(TellomiLinkVisual.parseLayout(""))
        XCTAssertNil(TellomiLinkVisual.parseLayout("\"icon\""))
    }

    func testATintedResultHasALightAndADarkSetOfColours() {
        let tint = TellomiLinkVisual.parseTint(orange)
        XCTAssertEqual(
            tint,
            TellomiLinkVisual.Tint(
                tinted: true,
                light: .init(background: .init(red: 0xFE, green: 0x75, blue: 0x00), text: .init(red: 0, green: 0, blue: 0)),
                dark: .init(background: .init(red: 0x99, green: 0x46, blue: 0x00), text: .init(red: 0xFF, green: 0xFF, blue: 0xFF)),
            ),
        )
        XCTAssertEqual(tint?.colors(isDark: false)?.background, .init(red: 0xFE, green: 0x75, blue: 0x00))
        XCTAssertEqual(tint?.colors(isDark: true)?.background, .init(red: 0x99, green: 0x46, blue: 0x00))
        XCTAssertEqual(tint?.colors(isDark: true)?.text, .init(red: 0xFF, green: 0xFF, blue: 0xFF))
    }

    func testANeutralImageKeepsTheDefaultColours() {
        let tint = TellomiLinkVisual.parseTint(##"{"tinted":false,"source":"#808082"}"##)
        XCTAssertEqual(tint, TellomiLinkVisual.Tint(tinted: false))
        XCTAssertNil(tint?.colors(isDark: false))
        XCTAssertNil(TellomiLinkVisual.Tint(tinted: true).colors(isDark: true))
    }

    func testAnythingItDoesNotUnderstandIsNoDecision() {
        XCTAssertNil(TellomiLinkVisual.parseTint("not json"))
        XCTAssertNil(TellomiLinkVisual.parseTint("{}"))
        XCTAssertNil(TellomiLinkVisual.parseTint(##"{"tinted":true}"##))
        // 不是 #RRGGBB 的颜色不用。
        XCTAssertNil(TellomiLinkVisual.parseTint(
            ##"{"tinted":true,"light":{"background":"red","text":"#000000"},"dark":{"background":"#994600","text":"#FFFFFF"}}"##,
        ))
        XCTAssertNil(TellomiLinkVisual.parseTint(
            ##"{"tinted":true,"light":{"background":"#FE750","text":"#000000"},"dark":{"background":"#994600","text":"#FFFFFF"}}"##,
        ))
    }

    /// 消息请求里的卡不染色，靠的是那里根本不建带图的卡（只画域名卡，见 `TellomiMessageRequestCardTest`），不是靠这个函数。
    func testOnlyThirdPartyCardsWithAnImageAreTinted() {
        XCTAssertTrue(TellomiLinkVisual.shouldTint(card: card, layout: .icon))
        XCTAssertTrue(TellomiLinkVisual.shouldTint(card: card, layout: .largeImage))
        var notTintable = card
        notTintable.tintable = false
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: notTintable, layout: .icon))
        var payment = card
        payment.payment = true
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: payment, layout: .icon))
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: card, layout: .firstParty))
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: card, layout: .noImage))
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: card, layout: nil))
        XCTAssertFalse(TellomiLinkVisual.shouldTint(card: nil, layout: .icon))
    }

    func testTheLayoutIsAskedForTheSizeOfTheImageTheCardShowsAndNoneForACardThatShowsNone() {
        var asked = [[String]]()
        var bridge = FakeBridge()
        bridge.onLayout = { asked.append(["\($0)", "\($1)", $2, $3]) }

        var structured = card
        structured.level = .structured
        structured.kind = "video"
        XCTAssertEqual(TellomiLinkVisual.layout(bridge: bridge, card: structured, imageWidth: 1200, imageHeight: 630), .icon)
        XCTAssertEqual(asked[0], ["1200", "630", "video", "structured"])

        var firstParty = card
        firstParty.level = .firstParty
        firstParty.kind = "tellomi.group"
        _ = TellomiLinkVisual.layout(bridge: bridge, card: firstParty, imageWidth: 1200, imageHeight: 630)
        XCTAssertEqual(asked[1], ["1200", "630", "tellomi.group", "first_party"])

        var noImage = card
        noImage.showImage = false
        _ = TellomiLinkVisual.layout(bridge: bridge, card: noImage, imageWidth: 1200, imageHeight: 630)
        XCTAssertEqual(asked[2], ["0", "0", "", "generic"], "不显示图的卡，问的时候没有图")

        var plain = card
        plain.level = .plainLink
        _ = TellomiLinkVisual.layout(bridge: bridge, card: plain, imageWidth: 0, imageHeight: 0)
        XCTAssertEqual(asked[3][3], "plain_link")
    }

    func testABridgeThatFailsIsNoDecision() {
        var failing = FakeBridge()
        failing.fails = true
        XCTAssertNil(TellomiLinkVisual.layout(bridge: failing, card: card, imageWidth: 100, imageHeight: 100))
        XCTAssertNil(TellomiLinkVisual.tint(bridge: failing, layout: .icon, rgba: Data(count: 32 * 32 * 4)))
    }

    func testTheTintIsAskedWithA32By32RGBAImage() {
        var seen: (String, UInt32, UInt32, Int)?
        var bridge = FakeBridge(tintJson: orange)
        bridge.onTint = { seen = ($0, $1, $2, $3.count) }

        XCTAssertNotNil(TellomiLinkVisual.tint(bridge: bridge, layout: .icon, rgba: Data(count: 32 * 32 * 4)))
        XCTAssertEqual(seen?.0, "icon")
        XCTAssertEqual(seen?.1, 32)
        XCTAssertEqual(seen?.2, 32)
        XCTAssertEqual(seen?.3, 32 * 32 * 4)

        // 不是 32×32×4 字节的像素不交给 rust/links。
        seen = nil
        XCTAssertNil(TellomiLinkVisual.tint(bridge: bridge, layout: .icon, rgba: Data(count: 10)))
        XCTAssertNil(seen)
    }

    func testACardGetsItsShapeAndTheColoursOfItsImage() {
        let bridge = FakeBridge(tintJson: orange)
        let visual = TellomiLinkVisual.decide(bridge: bridge, card: card, imageWidth: 100, imageHeight: 100) { Data(count: 32 * 32 * 4) }
        XCTAssertEqual(visual.layout, .icon)
        XCTAssertEqual(visual.tint?.colors(isDark: false)?.background, .init(red: 0xFE, green: 0x75, blue: 0x00))
    }

    func testNoCardNoDecision() {
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(), card: nil, imageWidth: 100, imageHeight: 100) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual.none,
        )
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(layoutName: "hologram"), card: card, imageWidth: 100, imageHeight: 100) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual.none,
        )
    }

    func testACardThatIsNotTintedNeverReadsItsImage() {
        var notTintable = card
        notTintable.tintable = false
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(), card: notTintable, imageWidth: 100, imageHeight: 100) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual(layout: .icon, tint: nil),
        )

        var firstParty = card
        firstParty.level = .firstParty
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(layoutName: "first_party"), card: firstParty, imageWidth: 100, imageHeight: 100) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual(layout: .firstParty, tint: nil),
        )

        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(layoutName: "no_image"), card: card, imageWidth: 0, imageHeight: 0) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual(layout: .noImage, tint: nil),
        )
    }

    func testAnImageThatIsNotOnTheDeviceYetGivesAShapeAndNoColours() {
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(), card: card, imageWidth: 100, imageHeight: 100) { nil },
            TellomiLinkVisual.Visual(layout: .icon, tint: nil),
        )
    }

    func testANeutralImageGivesNoColours() {
        let bridge = FakeBridge(tintJson: ##"{"tinted":false,"source":"#808082"}"##)
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: bridge, card: card, imageWidth: 100, imageHeight: 100) { Data(count: 32 * 32 * 4) },
            TellomiLinkVisual.Visual(layout: .icon, tint: nil),
        )
    }

    // MARK: - 品牌壳的随包图标（card-visual §3.9）

    private let taobao = TellomiLinkCard(level: .brand, provider: "taobao", kind: "product", domain: "taobao.com", showImage: false, icon: "taobao.png", tintable: true)

    func testTheCardKeepsTheIconNameClassifyGave() throws {
        let json = ##"{"level":"brand","provider":"taobao","provider_name":{"zh-Hans":"淘宝","en":"Taobao"},"kind":"product","icon":"taobao.png","tintable":true,"payment":false}"##
        XCTAssertEqual(TellomiLinkCard.parse(json)?.icon, "taobao.png")
        XCTAssertNil(TellomiLinkCard.parse(##"{"level":"brand","icon":null}"##)?.icon)
        XCTAssertNil(TellomiLinkCard.parse(##"{"level":"brand"}"##)?.icon, "旧版 rust/links 不带 icon")
    }

    func testOnlyTheShapeTheRegistryUsesIsAnIconName() {
        XCTAssertTrue(TellomiLinkIcon.isValidFileName("taobao.png"))
        XCTAssertTrue(TellomiLinkIcon.isValidFileName("weixin-mp.png"))
        XCTAssertTrue(TellomiLinkIcon.isValidFileName("a1.png"))
        for bad in ["", ".png", "taobao", "taobao.PNG", "Taobao.png", "../taobao.png", "a/b.png", "a\\b.png", "taobao.png/", "taobao.png ", "tao bao.png", "taobao.jpg", "淘宝.png", "a.b.png", "%2e%2e.png"] {
            XCTAssertFalse(TellomiLinkIcon.isValidFileName(bad), bad)
        }
    }

    func testTheBundledIconsAreReadFromThePackageAndABadNameIsNeverLookedUp() throws {
        let taobao = try XCTUnwrap(TellomiLinkIcon.icon(named: "taobao.png"))
        XCTAssertEqual(taobao.name, "taobao.png")
        XCTAssertEqual(taobao.pixelWidth, 114)
        XCTAssertEqual(taobao.pixelHeight, 114)
        for name in ["douban.png", "eleme.png", "iqiyi.png", "weixin-mp.png", "xiaohongshu.png", "zhihu.png"] {
            XCTAssertNotNil(TellomiLinkIcon.icon(named: name), name)
        }
        // 注册表里写了但包里没有（比如热更来的名字）：当没有图标。
        XCTAssertNil(TellomiLinkIcon.icon(named: "no-such-brand.png"))
        XCTAssertNil(TellomiLinkIcon.icon(named: "../taobao.png"))
        XCTAssertNil(TellomiLinkIcon.icon(named: "icons/taobao.png"))
    }

    func testABrandShellIsAskedWithTheSizeOfItsIconAndTintedFromTheIconPixels() {
        var asked = [[String]]()
        var tintedWith: (String, UInt32, UInt32, Int)?
        var bridge = FakeBridge(tintJson: orange)
        bridge.onLayout = { asked.append(["\($0)", "\($1)", $2, $3]) }
        bridge.onTint = { tintedWith = ($0, $1, $2, $3.count) }

        let visual = TellomiLinkVisual.decide(bridge: bridge, card: taobao, imageWidth: 114, imageHeight: 114) { Data(count: 32 * 32 * 4) }
        XCTAssertEqual(asked, [["114", "114", "product", "brand"]])
        XCTAssertEqual(visual.layout, .icon)
        XCTAssertEqual(visual.tint?.colors(isDark: false)?.background, .init(red: 0xFE, green: 0x75, blue: 0x00))
        XCTAssertEqual(tintedWith?.0, "icon")
        XCTAssertEqual(tintedWith?.3, 32 * 32 * 4)
    }

    func testABrandShellWithoutAReadableIconIsAskedWithNoImageAndNeverReadsPixels() {
        var asked = [[String]]()
        var bridge = FakeBridge(layoutName: "no_image")
        bridge.onLayout = { asked.append(["\($0)", "\($1)", $2, $3]) }

        // 有图标名但读不到：调用方传 0 × 0。
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: bridge, card: taobao, imageWidth: 0, imageHeight: 0) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual(layout: .noImage, tint: nil),
        )
        // 注册表没给图标名：和以前一样，问的时候没有图。
        var noIcon = taobao
        noIcon.icon = nil
        _ = TellomiLinkVisual.decide(bridge: bridge, card: noIcon, imageWidth: 0, imageHeight: 0) { XCTFail("not read"); return nil }
        XCTAssertEqual(asked[0], ["0", "0", "product", "brand"])
        XCTAssertEqual(asked[1], ["0", "0", "", "brand"], "没有图标名：不显示图，kind 也不传")
    }

    // MARK: - 认领档（claimed，2026-10-19）：页面没给图时用随包图标，不当无图卡

    private let claimedTaobao = TellomiLinkCard(level: .generic, domain: "taobao.com", showImage: false, icon: "taobao.png", tintable: true)

    func testAClaimedCardWithoutAPageImageIsAskedWithTheSizeOfItsIconAndTintedFromIt() {
        var asked = [[String]]()
        var tintedWith: (String, UInt32, UInt32, Int)?
        var bridge = FakeBridge(tintJson: orange)
        bridge.onLayout = { asked.append(["\($0)", "\($1)", $2, $3]) }
        bridge.onTint = { tintedWith = ($0, $1, $2, $3.count) }

        XCTAssertTrue(TellomiLinkVisual.usesBundledIcon(claimedTaobao))
        let visual = TellomiLinkVisual.decide(bridge: bridge, card: claimedTaobao, imageWidth: 114, imageHeight: 114) { Data(count: 32 * 32 * 4) }
        XCTAssertEqual(asked, [["114", "114", "", "generic"]], "随包图标的尺寸，不是 0 × 0（指南针）")
        XCTAssertEqual(visual.layout, .icon)
        XCTAssertEqual(visual.tint?.colors(isDark: false)?.background, .init(red: 0xFE, green: 0x75, blue: 0x00))
        XCTAssertEqual(tintedWith?.0, "icon")
    }

    func testAClaimedCardWithAPageImageUsesThePageImageAndAPlainGenericCardNeverUsesAnIcon() {
        var withImage = claimedTaobao
        withImage.showImage = true
        XCTAssertFalse(TellomiLinkVisual.usesBundledIcon(withImage), "页面给了图：用页面的图")

        var noIcon = claimedTaobao
        noIcon.icon = nil
        XCTAssertFalse(TellomiLinkVisual.usesBundledIcon(noIcon))
        var asked = [[String]]()
        var bridge = FakeBridge(layoutName: "no_image")
        bridge.onLayout = { asked.append(["\($0)", "\($1)", $2, $3]) }
        _ = TellomiLinkVisual.layout(bridge: bridge, card: noIcon, imageWidth: 1200, imageHeight: 630)
        XCTAssertEqual(asked[0], ["0", "0", "", "generic"], "什么都没有的 generic 卡才是无图卡")

        var structured = claimedTaobao
        structured.level = .structured
        XCTAssertFalse(TellomiLinkVisual.usesBundledIcon(structured))
    }

    func testAPaymentShellIsNeverTintedEvenWithAnIcon() {
        var payment = taobao
        payment.payment = true
        payment.tintable = false
        XCTAssertEqual(
            TellomiLinkVisual.decide(bridge: FakeBridge(), card: payment, imageWidth: 114, imageHeight: 114) { XCTFail("not read"); return nil },
            TellomiLinkVisual.Visual(layout: .icon, tint: nil),
        )
    }

    func testTheSendersImageNeverStandsInForTheIconOfABrandShell() {
        // 发送端的图即使带了尺寸也不会被问：品牌壳的 showImage 是 false，只有带图标名时才问图标的尺寸。
        var noIcon = taobao
        noIcon.icon = nil
        var asked = [[String]]()
        var bridge = FakeBridge(layoutName: "no_image")
        bridge.onLayout = { asked.append(["\($0)", "\($1)", $2, $3]) }
        _ = TellomiLinkVisual.layout(bridge: bridge, card: noIcon, imageWidth: 1200, imageHeight: 630)
        XCTAssertEqual(asked[0], ["0", "0", "", "brand"])
    }
}
