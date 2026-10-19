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

    func testOffByDefault() {
        XCTAssertFalse(TellomiFeedPreview.isEnabled(isAvailable: true, defaults: defaults))
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

    func testMainSwitchIsOnForTestFlight31() {
        // 提交 App Store 审核前要改成 false；改了这条测试会红，提醒同时改报告和 HANDOFF。
        XCTAssertTrue(TellomiFeedPreview.isCompiledIn)
        XCTAssertEqual(TellomiFeedPreview.storageKey, "TellomiFeed.testFlightPreview")
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
