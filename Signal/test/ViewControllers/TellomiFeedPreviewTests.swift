//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// TestFlight 动态预览（`TellomiFeedPreview`）：只有 TestFlight 装的包认、默认关、正式包里读写都没用、页面开关跟不跟着预览。
final class TellomiFeedPreviewTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TellomiFeedPreviewTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAvailableOnlyForTestFlightInstallsWithTheMainSwitchOn() {
        XCTAssertTrue(TellomiFeedPreview.isAvailable(compiledIn: true, isTestFlightInstall: true))
        XCTAssertFalse(TellomiFeedPreview.isAvailable(compiledIn: true, isTestFlightInstall: false))
        XCTAssertFalse(TellomiFeedPreview.isAvailable(compiledIn: false, isTestFlightInstall: true))
        XCTAssertFalse(TellomiFeedPreview.isAvailable(compiledIn: false, isTestFlightInstall: false))
    }

    /// 2026-10-24：TestFlight 构建默认开（没存过 = 开），商店版（不可用）永远关。
    func testOnByDefaultInTestFlightOffInStore() {
        XCTAssertTrue(TellomiFeedPreview.isEnabled(isAvailable: true, defaults: defaults))
        XCTAssertFalse(TellomiFeedPreview.isEnabled(isAvailable: false, defaults: defaults))
        XCTAssertNil(defaults.object(forKey: TellomiFeedPreview.storageKey))
    }

    func testTurnOnAndOffInTestFlight() {
        XCTAssertTrue(TellomiFeedPreview.setEnabled(true, isAvailable: true, defaults: defaults))
        XCTAssertTrue(TellomiFeedPreview.isEnabled(isAvailable: true, defaults: defaults))
        XCTAssertTrue(TellomiFeedPreview.setEnabled(false, isAvailable: true, defaults: defaults))
        XCTAssertFalse(TellomiFeedPreview.isEnabled(isAvailable: true, defaults: defaults))
    }

    /// App Store 包：存着 true（比如从 TestFlight 包的备份恢复过来）也不认。
    func testStoredValueIgnoredOutsideTestFlight() {
        defaults.set(true, forKey: TellomiFeedPreview.storageKey)
        XCTAssertFalse(TellomiFeedPreview.isEnabled(isAvailable: false, defaults: defaults))
    }

    /// App Store 包：写不进去。
    func testCannotTurnOnOutsideTestFlight() {
        XCTAssertFalse(TellomiFeedPreview.setEnabled(true, isAvailable: false, defaults: defaults))
        XCTAssertNil(defaults.object(forKey: TellomiFeedPreview.storageKey))
        XCTAssertFalse(TellomiFeedPreview.isEnabled(isAvailable: true, defaults: defaults))
    }

    func testGarbageStoredValueIsOff() {
        defaults.set("yes", forKey: TellomiFeedPreview.storageKey)
        XCTAssertFalse(TellomiFeedPreview.isEnabled(isAvailable: true, defaults: defaults))
    }

    /// 总闸跟构建走：只有 Info.plist `TellomiTestFlightFeed` 显式是 YES 才开；没设（build setting 展开成空）、别的值都关。
    func testMainSwitchFollowsInfoPlist() {
        XCTAssertEqual(TellomiFeedPreview.infoPlistKey, "TellomiTestFlightFeed")
        XCTAssertEqual(TellomiFeedPreview.storageKey, "TellomiFeed.testFlightPreview")
        XCTAssertTrue(TellomiFeedPreview.isCompiledIn(infoPlistValue: "YES"))
        XCTAssertTrue(TellomiFeedPreview.isCompiledIn(infoPlistValue: true))
        XCTAssertFalse(TellomiFeedPreview.isCompiledIn(infoPlistValue: nil))
        XCTAssertFalse(TellomiFeedPreview.isCompiledIn(infoPlistValue: ""))
        XCTAssertFalse(TellomiFeedPreview.isCompiledIn(infoPlistValue: "NO"))
        XCTAssertFalse(TellomiFeedPreview.isCompiledIn(infoPlistValue: "yes"))
        XCTAssertFalse(TellomiFeedPreview.isCompiledIn(infoPlistValue: "$(TELLOMI_TESTFLIGHT_FEED)"))
        XCTAssertFalse(TellomiFeedPreview.isCompiledIn(infoPlistValue: false))
    }

    /// 测试包（Debug，没设 TELLOMI_TESTFLIGHT_FEED）：总闸是关的，和商店版一样。
    func testMainSwitchIsOffInThisBuild() {
        XCTAssertFalse(TellomiFeedPreview.isCompiledIn)
    }

    /// 商店版（没标 TestFlight，不管是不是沙盒收据）：没有动态标签、不用样例、页面全关。
    func testStoreConfigHasNoFeed() {
        for isTestFlightInstall in [true, false] {
            let available = TellomiFeedPreview.isAvailable(compiledIn: TellomiFeedPreview.isCompiledIn(infoPlistValue: nil), isTestFlightInstall: isTestFlightInstall)
            XCTAssertFalse(available)
            defaults.set(true, forKey: TellomiFeedPreview.storageKey)
            let enabled = TellomiFeedPreview.isEnabled(isAvailable: available, defaults: defaults)
            XCTAssertFalse(enabled)
            XCTAssertFalse(TellomiFeedPreview.tabForced(internalForced: false, previewEnabled: enabled))
            XCTAssertFalse(TellomiFeedPreview.usesSampleData(previewEnabled: enabled, internalForced: false, internalUseSampleData: true))
            XCTAssertEqual(
                HomeTabBarController.tabsToShow(areStoriesEnabled: true, isFeedEnabled: TellomiFeed.isTabEnabled(remoteEnabled: false, engineVisible: false, forcedByInternalUser: enabled)),
                [.chatList, .calls, .stories],
            )
            for page in TellomiFeedPreview.Page.allCases {
                XCTAssertFalse(TellomiFeedPreview.isPageEnabled(page, internalBuild: false, internalValue: { true }, previewEnabled: enabled), "\(page)")
            }
        }
    }

    /// TestFlight 构建（标了 YES + 沙盒收据，没存过开关）：动态标签在最左、样例数据、不问引擎、跟着预览的页面全开、分享关。
    func testTestFlightConfigShowsFeedWithSampleDataAndNoShare() {
        let available = TellomiFeedPreview.isAvailable(compiledIn: TellomiFeedPreview.isCompiledIn(infoPlistValue: "YES"), isTestFlightInstall: true)
        XCTAssertTrue(available)
        let enabled = TellomiFeedPreview.isEnabled(isAvailable: available, defaults: defaults)
        XCTAssertTrue(enabled)
        XCTAssertTrue(TellomiFeedPreview.tabForced(internalForced: false, previewEnabled: enabled))
        XCTAssertTrue(TellomiFeedPreview.usesSampleData(previewEnabled: enabled, internalForced: false, internalUseSampleData: false))
        XCTAssertFalse(TellomiFeedPreview.shouldAskEngine(previewEnabled: enabled, remoteEnabled: true, internalForced: false, internalUseSampleData: false))
        // 动态在最左，后面聊天、通话；打开 App 默认选「聊天」（HomeTabBarController.viewDidLoad 里 selectedHomeTab = .chatList）
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: false, isFeedEnabled: TellomiFeed.isTabEnabled(remoteEnabled: false, engineVisible: false, engineHasFeed: false, forcedByInternalUser: enabled)),
            [.feed, .chatList, .calls],
        )
        XCTAssertEqual(
            HomeTabBarController.tabsToShow(areStoriesEnabled: true, isFeedEnabled: true),
            [.feed, .chatList, .calls, .stories],
        )
        for page in TellomiFeedPreview.Page.allCases {
            XCTAssertEqual(TellomiFeedPreview.isPageEnabled(page, internalBuild: false, internalValue: { false }, previewEnabled: enabled), page.followsPreview, "\(page)")
        }
        XCTAssertFalse(TellomiFeedPreview.isPageEnabled(.share, internalBuild: false, internalValue: { true }, previewEnabled: enabled))
        // 在「关于 Tellomi」里手动关掉之后没有动态
        TellomiFeedPreview.setEnabled(false, isAvailable: available, defaults: defaults)
        XCTAssertFalse(TellomiFeedPreview.isEnabled(isAvailable: available, defaults: defaults))
    }

    func testPagesThatFollowThePreview() {
        let following = TellomiFeedPreview.Page.allCases.filter(\.followsPreview)
        XCTAssertEqual(following, [.profile, .search, .notifications, .myPosts, .settings, .composeExtras, .lists, .articleReader, .detailExtras, .detailEvents])
        XCTAssertFalse(TellomiFeedPreview.Page.share.followsPreview)
        XCTAssertFalse(TellomiFeedPreview.Page.minorTime.followsPreview)
    }

    /// 正式包 / TestFlight（非内部构建）：预览关着时一页都不开，打开时只开跟着预览的页；内部开关的值不看。
    func testPagesOutsideInternalBuilds() {
        for page in TellomiFeedPreview.Page.allCases {
            XCTAssertFalse(TellomiFeedPreview.isPageEnabled(page, internalBuild: false, internalValue: { true }, previewEnabled: false), "\(page)")
            XCTAssertEqual(TellomiFeedPreview.isPageEnabled(page, internalBuild: false, internalValue: { false }, previewEnabled: true), page.followsPreview, "\(page)")
        }
    }

    /// 内部构建照旧：只看内部开关，预览不改它。
    func testInternalBuildsKeepTheirOwnSwitches() {
        for page in TellomiFeedPreview.Page.allCases {
            XCTAssertTrue(TellomiFeedPreview.isPageEnabled(page, internalBuild: true, internalValue: { true }, previewEnabled: false), "\(page)")
            XCTAssertFalse(TellomiFeedPreview.isPageEnabled(page, internalBuild: true, internalValue: { false }, previewEnabled: true), "\(page)")
        }
    }

    /// 预览打开时的入口和数据来源（`TellomiFeed` 里接线用的同一个式子）：标签显示、用样例、不去问引擎。
    func testPreviewForcesTabAndSampleData() {
        XCTAssertTrue(TellomiFeedPreview.tabForced(internalForced: false, previewEnabled: true))
        XCTAssertFalse(TellomiFeedPreview.tabForced(internalForced: false, previewEnabled: false))
        XCTAssertTrue(TellomiFeedPreview.tabForced(internalForced: true, previewEnabled: false))

        XCTAssertTrue(TellomiFeedPreview.usesSampleData(previewEnabled: true, internalForced: false, internalUseSampleData: false))
        XCTAssertTrue(TellomiFeedPreview.usesSampleData(previewEnabled: false, internalForced: true, internalUseSampleData: true))
        XCTAssertFalse(TellomiFeedPreview.usesSampleData(previewEnabled: false, internalForced: true, internalUseSampleData: false))
        XCTAssertFalse(TellomiFeedPreview.usesSampleData(previewEnabled: false, internalForced: false, internalUseSampleData: true))

        // 预览打开：即使远程开关开了也不问引擎（不发任何请求）
        XCTAssertFalse(TellomiFeedPreview.shouldAskEngine(previewEnabled: true, remoteEnabled: true, internalForced: true, internalUseSampleData: false))
        XCTAssertTrue(TellomiFeedPreview.shouldAskEngine(previewEnabled: false, remoteEnabled: true, internalForced: false, internalUseSampleData: true))
        XCTAssertTrue(TellomiFeedPreview.shouldAskEngine(previewEnabled: false, remoteEnabled: false, internalForced: true, internalUseSampleData: false))
        XCTAssertFalse(TellomiFeedPreview.shouldAskEngine(previewEnabled: false, remoteEnabled: false, internalForced: true, internalUseSampleData: true))
        XCTAssertFalse(TellomiFeedPreview.shouldAskEngine(previewEnabled: false, remoteEnabled: false, internalForced: false, internalUseSampleData: false))
    }
}
