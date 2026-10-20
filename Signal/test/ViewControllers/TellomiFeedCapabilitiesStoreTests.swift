//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// capabilities 存本机（按账号 + 引擎地址），24 小时内冷启动先用；问失败退回到存的；退出登录清掉。
/// 另：任何模式下能看到内容就有举报入口（信息流卡片的「···」）。
final class TellomiFeedCapabilitiesStoreTests: XCTestCase {
    private let suite = "TellomiFeedCapabilitiesStoreTests"
    private var defaults: UserDefaults!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func stored(_ features: [String], at date: Date) -> FeedEngineCapabilities.Stored {
        return FeedEngineCapabilities.Stored(features: features, fetchedAt: date)
    }

    func testSeparateScopesPerAccountAndEngine() {
        let a = FeedEngineCapabilities.scope(account: "aci-a", engine: "https://feed.cn")
        let b = FeedEngineCapabilities.scope(account: "aci-b", engine: "https://feed.cn")
        let c = FeedEngineCapabilities.scope(account: "aci-a", engine: "https://feed.hk")
        XCTAssertEqual(Set([a, b, c]).count, 3)
        FeedEngineCapabilities.save(stored(["feed"], at: t0), scope: a, defaults: defaults)
        FeedEngineCapabilities.save(stored(["posting"], at: t0), scope: b, defaults: defaults)
        XCTAssertEqual(FeedEngineCapabilities.load(scope: a, defaults: defaults)?.features, ["feed"])
        XCTAssertEqual(FeedEngineCapabilities.load(scope: b, defaults: defaults)?.features, ["posting"])
        XCTAssertNil(FeedEngineCapabilities.load(scope: c, defaults: defaults), "换引擎地址不认别的地址的")
    }

    func testUsableOnlyWithin24Hours() {
        let s = stored(["feed", "reports"], at: t0)
        XCTAssertEqual(FeedEngineCapabilities.usable(s, now: t0), ["feed", "reports"])
        XCTAssertEqual(FeedEngineCapabilities.usable(s, now: t0.addingTimeInterval(24 * 3600 - 1)), ["feed", "reports"])
        XCTAssertNil(FeedEngineCapabilities.usable(s, now: t0.addingTimeInterval(24 * 3600)), "满 24 小时就按拿不到")
        XCTAssertNil(FeedEngineCapabilities.usable(s, now: t0.addingTimeInterval(-1)), "时钟被调回去算过期")
        XCTAssertNil(FeedEngineCapabilities.usable(nil, now: t0), "从没成功过")
    }

    func testFailedRefreshFallsBackToStoredWithin24Hours() {
        let s = stored(["feed"], at: t0)
        let fresh = FeedCapabilitiesSnapshot.available(FeedCapabilities(features: ["feed", "posting"]))
        XCTAssertEqual(FeedEngineCapabilities.next(after: fresh, stored: s, now: t0), ["feed", "posting"], "问到了用新的")
        XCTAssertEqual(FeedEngineCapabilities.next(after: .unavailable(.timeout), stored: s, now: t0.addingTimeInterval(3600)), ["feed"])
        XCTAssertNil(FeedEngineCapabilities.next(after: .unavailable(.timeout), stored: s, now: t0.addingTimeInterval(25 * 3600)))
        XCTAssertNil(FeedEngineCapabilities.next(after: .unavailable(.notFound), stored: nil, now: t0))
    }

    func testClearRemovesEveryScope() {
        FeedEngineCapabilities.save(stored(["feed"], at: t0), scope: "a", defaults: defaults)
        FeedEngineCapabilities.save(stored(["feed"], at: t0), scope: "b", defaults: defaults)
        FeedEngineCapabilities.clearStored(defaults: defaults)
        XCTAssertNil(FeedEngineCapabilities.load(scope: "a", defaults: defaults))
        XCTAssertNil(FeedEngineCapabilities.load(scope: "b", defaults: defaults))
    }

    func testGarbageStoredValueIsIgnored() {
        defaults.set(["a": Data("nope".utf8)], forKey: FeedEngineCapabilities.storageKey)
        XCTAssertNil(FeedEngineCapabilities.load(scope: "a", defaults: defaults))
        defaults.set("not a dictionary", forKey: FeedEngineCapabilities.storageKey)
        XCTAssertNil(FeedEngineCapabilities.load(scope: "a", defaults: defaults))
    }

    // MARK: - 举报入口

    /// 信息流卡片「···」：别人的帖子总有举报（不看 capabilities / 预览 / 样例），自己的没有「···」。
    func testFeedCardMenuAlwaysOffersReportOnOthersPosts() {
        var card = FeedCard(id: "c1", text: "hi")
        XCTAssertEqual(FeedPostCell.menuItems(for: card), [.notInterested, .report])
        card.viewer.isAuthor = true
        XCTAssertEqual(FeedPostCell.menuItems(for: card), [])
    }

    /// 详情页：别人的帖子和评论都有举报；举报不在 capabilities 拦的入口里（缺 `reports` 是整个动态藏）。
    func testDetailMenusOfferReport() {
        let post = FeedCard(id: "p", text: "hi")
        XCTAssertTrue(FeedDetailMenu.shown(FeedDetailMenu.items(forPost: post), reportAvailable: true).contains(.report))
        let comment = FeedCard(id: "c", kind: FeedCard.kindComment, text: "x")
        XCTAssertEqual(FeedDetailMenu.items(forComment: comment), [.report])
        XCTAssertTrue(FeedEngineCapabilities.tabFeatures.contains(FeedFeature.reports))
    }

    /// 样例数据（TestFlight 预览、内部强制 + 样例）下能看到内容：样例源也要能接举报（不会因为不连网就没有入口）。
    @MainActor
    func testSampleSourceAcceptsReports() {
        let store = FeedReportStore(target: .content("sample-1"), source: SampleFeedSource.shared)
        XCTAssertNotNil(store)
    }
}
