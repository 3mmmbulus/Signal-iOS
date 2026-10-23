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
        XCTAssertEqual(FeedEngineCapabilities.tabFeatures, [FeedFeature.feed, FeedFeature.reports], "举报后端没部署就整个动态藏")
        XCTAssertEqual(FeedEngineCapabilities.commentFeatures, [FeedFeature.comments])
        XCTAssertEqual(FeedEngineCapabilities.likeFeatures, [FeedFeature.reactions])
        XCTAssertEqual(FeedEngineCapabilities.pollFeatures, [FeedFeature.polls])
        XCTAssertEqual(FeedEngineCapabilities.voiceCommentFeatures, [FeedFeature.voiceComments])
        XCTAssertEqual(FeedEngineCapabilities.composeFeatures, [FeedFeature.posting])
    }

    func testTabNeedsFeedCapabilityUnlessForced() {
        XCTAssertTrue(TellomiFeed.isTabEnabled(remoteEnabled: true, engineVisible: true, engineHasFeed: true, forcedByInternalUser: false))
        XCTAssertFalse(TellomiFeed.isTabEnabled(remoteEnabled: true, engineVisible: true, engineHasFeed: false, forcedByInternalUser: false))
        XCTAssertTrue(TellomiFeed.isTabEnabled(remoteEnabled: false, engineVisible: false, engineHasFeed: false, forcedByInternalUser: true))
    }

    /// 举报入口不藏：只要 `feed` 在而 `reports` 不在，整个动态不出现。
    func testMissingReportsHidesTheWholeFeed() {
        let noReports: Set<String> = [FeedFeature.feed, FeedFeature.posting, FeedFeature.comments]
        XCTAssertFalse(FeedEngineCapabilities.allows(FeedEngineCapabilities.tabFeatures, features: noReports, usesSampleData: false))
        XCTAssertTrue(FeedEngineCapabilities.allows(FeedEngineCapabilities.tabFeatures, features: noReports.union([FeedFeature.reports]), usesSampleData: false))
    }

    /// 评论、点赞、投票、语音评论各按自己的能力名藏。
    func testSubEntriesFollowTheirOwnCapability() {
        let features: Set<String> = [FeedFeature.feed, FeedFeature.reports, FeedFeature.posting, FeedFeature.comments]
        XCTAssertTrue(FeedEngineCapabilities.allows(FeedEngineCapabilities.commentFeatures, features: features, usesSampleData: false))
        XCTAssertFalse(FeedEngineCapabilities.allows(FeedEngineCapabilities.likeFeatures, features: features, usesSampleData: false))
        XCTAssertFalse(FeedEngineCapabilities.allows(FeedEngineCapabilities.pollFeatures, features: features, usesSampleData: false))
        XCTAssertFalse(FeedEngineCapabilities.allows(FeedEngineCapabilities.voiceCommentFeatures, features: features, usesSampleData: false))
    }

    /// I-2：发布页加图按 `media_upload` 藏；样例数据不拦。
    func testComposeImagesFollowMediaUpload() {
        XCTAssertEqual(FeedEngineCapabilities.mediaUploadFeatures, [FeedFeature.mediaUpload])
        let posting: Set<String> = [FeedFeature.feed, FeedFeature.reports, FeedFeature.posting]
        XCTAssertFalse(FeedEngineCapabilities.allows(FeedEngineCapabilities.mediaUploadFeatures, features: posting, usesSampleData: false))
        XCTAssertTrue(FeedEngineCapabilities.allows(FeedEngineCapabilities.mediaUploadFeatures, features: posting.union([FeedFeature.mediaUpload]), usesSampleData: false))
        XCTAssertTrue(FeedEngineCapabilities.allows(FeedEngineCapabilities.mediaUploadFeatures, features: nil, usesSampleData: true))
    }

    /// 没在问引擎时（标签本身不出现）子入口不拦；在问引擎但没拿到时一律藏。
    func testNotAskingTheEngineDoesNotRestrictSubEntries() {
        XCTAssertTrue(FeedEngineCapabilities.allows(FeedEngineCapabilities.likeFeatures, features: nil, usesSampleData: false, asksEngine: false))
        XCTAssertFalse(FeedEngineCapabilities.allows(FeedEngineCapabilities.likeFeatures, features: nil, usesSampleData: false, asksEngine: true))
        XCTAssertFalse(TellomiFeed.isTabEnabled(remoteEnabled: false, engineVisible: false, engineHasFeed: true, forcedByInternalUser: false), "不问引擎时远程开关是关的，标签不出现")
    }

    /// 商店包（不是 TestFlight 收据、不是内部构建）：预览和内部「强制 + 样例」都是关的，入口看不到，capabilities 也照常管。
    func testAppStoreInstallHasNoPreviewOrInternalBypass() {
        let defaults = UserDefaults(suiteName: "TellomiFeedEngineCapabilitiesGateTests")!
        defaults.removePersistentDomain(forName: "TellomiFeedEngineCapabilitiesGateTests")
        defaults.set(true, forKey: TellomiFeedPreview.storageKey)

        let available = TellomiFeedPreview.isAvailable(compiledIn: true, isTestFlightInstall: false)
        XCTAssertFalse(available, "总闸开着也不行：要 TestFlight 收据")
        XCTAssertFalse(TellomiFeedPreview.isEnabled(isAvailable: available, defaults: defaults), "存过 true 也不认")
        XCTAssertFalse(TellomiFeedPreview.setEnabled(true, isAvailable: available, defaults: defaults))

        for page in TellomiFeedPreview.Page.allCases {
            XCTAssertFalse(TellomiFeedPreview.isPageEnabled(page, internalBuild: false, internalValue: { true }, previewEnabled: false), "\(page)")
        }
        // 商店包里内部强制永远是 false（`DebugFlags.internalSettings` 在 Release = `.production` 时为 false）
        XCTAssertFalse(TellomiFeedPreview.tabForced(internalForced: false, previewEnabled: false))
        let sample = TellomiFeedPreview.usesSampleData(previewEnabled: false, internalForced: false, internalUseSampleData: true)
        XCTAssertFalse(sample)
        XCTAssertFalse(FeedEngineCapabilities.allows(FeedEngineCapabilities.tabFeatures, features: nil, usesSampleData: sample))
        XCTAssertFalse(TellomiFeed.isTabEnabled(remoteEnabled: true, engineVisible: true, engineHasFeed: false, forcedByInternalUser: false))
        defaults.removePersistentDomain(forName: "TellomiFeedEngineCapabilitiesGateTests")
    }
}
