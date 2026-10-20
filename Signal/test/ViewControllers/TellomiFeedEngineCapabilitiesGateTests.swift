//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 产品 2026-10-20：按 `GET /v1/capabilities` 隐藏没部署的功能入口；拿不到 capabilities 按「没部署」，入口隐藏。
final class TellomiFeedEngineCapabilitiesGateTests: XCTestCase {

    func testMissingCapabilitiesHideEverything() {
        XCTAssertFalse(FeedEngineCapabilities.allows([FeedFeature.feed], features: nil, usesSampleData: false))
        XCTAssertFalse(FeedEngineCapabilities.allows([], features: nil, usesSampleData: false), "没拿到时连「不要求能力」的入口也藏")
    }

    func testRequiresEveryListedFeature() {
        let features: Set<String> = [FeedFeature.feed, FeedFeature.follow]
        XCTAssertTrue(FeedEngineCapabilities.allows([FeedFeature.feed], features: features, usesSampleData: false))
        XCTAssertFalse(FeedEngineCapabilities.allows([FeedFeature.posting], features: features, usesSampleData: false))
        XCTAssertFalse(FeedEngineCapabilities.allows([FeedFeature.follow, FeedFeature.blocks], features: features, usesSampleData: false))
        XCTAssertTrue(FeedEngineCapabilities.allows([], features: features, usesSampleData: false))
    }

    func testSampleDataIgnoresCapabilities() {
        XCTAssertTrue(FeedEngineCapabilities.allows([FeedFeature.posting], features: nil, usesSampleData: true))
    }

    func testOnlyAnAvailableSnapshotIsRemembered() {
        let available = FeedCapabilitiesSnapshot.available(FeedCapabilities(features: [FeedFeature.feed]))
        XCTAssertEqual(FeedEngineCapabilities.features(from: available), [FeedFeature.feed])
        for error: FeedCapabilitiesError in [.notFound, .http(500), .throttled(retryAfterSeconds: 5), .malformed, .timeout, .transport] {
            XCTAssertNil(FeedEngineCapabilities.features(from: .unavailable(error)), "\(error)")
        }
        XCTAssertEqual(FeedEngineCapabilities.features(from: .available(FeedCapabilities(features: []))), [], "空表 ≠ 没拿到，但什么入口也放不出来")
    }

    func testPageMapping() {
        XCTAssertEqual(FeedEngineCapabilities.requiredFeatures(for: .search), [FeedFeature.search])
        XCTAssertEqual(FeedEngineCapabilities.requiredFeatures(for: .notifications), [FeedFeature.notifications])
        XCTAssertEqual(FeedEngineCapabilities.requiredFeatures(for: .profile), [FeedFeature.profiles])
        XCTAssertEqual(FeedEngineCapabilities.requiredFeatures(for: .myPosts), [FeedFeature.posting])
        XCTAssertEqual(FeedEngineCapabilities.requiredFeatures(for: .detailEvents), [FeedFeature.events])
        XCTAssertEqual(FeedEngineCapabilities.tabFeatures, [FeedFeature.feed])
        XCTAssertEqual(FeedEngineCapabilities.composeFeatures, [FeedFeature.posting])
    }

    func testTabNeedsFeedCapabilityUnlessForced() {
        XCTAssertTrue(TellomiFeed.isTabEnabled(remoteEnabled: true, engineVisible: true, engineHasFeed: true, forcedByInternalUser: false))
        XCTAssertFalse(TellomiFeed.isTabEnabled(remoteEnabled: true, engineVisible: true, engineHasFeed: false, forcedByInternalUser: false))
        XCTAssertTrue(TellomiFeed.isTabEnabled(remoteEnabled: false, engineVisible: false, engineHasFeed: false, forcedByInternalUser: true))
    }
}
