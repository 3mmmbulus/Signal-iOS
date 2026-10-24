//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 底栏图标：动态 / 聊天 / 通话 / 好友 / 我 未选中描边、选中实心（`.fill`），同一套符号配置。
final class TellomiHomeTabIconsTests: XCTestCase {

    private let fiveTabs: [HomeTabBarController.Tabs] = [.feed, .chatList, .calls, .friends, .me]

    func testSelectedImageIsTheFilledVariantOfTheUnselectedOne() {
        XCTAssertEqual(fiveTabs.map(\.symbolName), ["newspaper", "bubble.left", "phone", "person.2", "person.crop.circle"])
        for tab in fiveTabs {
            let name = try! XCTUnwrap(tab.symbolName)
            XCTAssertEqual(tab.selectedSymbolName, name + ".fill", "\(tab)")
            XCTAssertFalse(name.hasSuffix(".fill"), "\(tab)")
        }
    }

    func testEachTabHasDistinctUnselectedAndSelectedImages() {
        for tab in fiveTabs {
            let image = try! XCTUnwrap(tab.image, "\(tab)")
            let selected = try! XCTUnwrap(tab.selectedImage, "\(tab)")
            XCTAssertNotEqual(image, selected, "\(tab)")
            XCTAssertNotEqual(image.pngData(), selected.pngData(), "\(tab)")
            XCTAssertEqual(image.symbolConfiguration, selected.symbolConfiguration, "same weight and size: \(tab)")
        }
    }

    func testTabBarItemCarriesTheSelectedImage() {
        for tab in fiveTabs {
            let item = tab.tabBarItem
            XCTAssertNotEqual(item.image?.pngData(), item.selectedImage?.pngData(), "\(tab)")
        }
    }
}
