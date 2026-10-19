//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 动态设置页的界面检查（UIKit）：从动态页右上角的齿轮进来，样例数据（`SampleFeedSource+Settings.swift`，设置存在内存里）。
/// 读失败 / 存失败 / 限速 / `feed_hidden` / 海外区 / 个性化开关用 `source.simulation` 的 `settings…` 开关切，截图方法见报告。
final class TellomiFeedSettingsUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
        let source: SampleFeedSource
        let keywords: InMemoryFeedBlockedKeywords

        func openSettings() async -> FeedRecommendationSettingsViewController {
            let page = FeedRecommendationSettingsViewController(source: source, blockedKeywords: keywords)
            navigation.pushViewController(page, animated: false)
            page.loadViewIfNeeded()
            await page.store.waitForTasks()
            window.layoutIfNeeded()
            return page
        }
    }

    @MainActor
    private func makeHarness(settingsEnabled: Bool = true, searchEnabled: Bool = false) async -> Harness {
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let keywords = InMemoryFeedBlockedKeywords()
        let feed = FeedViewController(source: source, profilePageEnabled: false, searchEnabled: searchEnabled, notificationsEnabled: false, myPostsEnabled: false, settingsEnabled: settingsEnabled, blockedKeywords: keywords)
        let navigation = OWSNavigationController(rootViewController: feed)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        await feed.store.loadConfig()
        await feed.store.waitForLoad(.recommend)
        window.layoutIfNeeded()
        return Harness(feed: feed, navigation: navigation, window: window, source: source, keywords: keywords)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<60 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - 入口

    @MainActor
    func testEverythingIsOffByDefault() async throws {
        XCTAssertFalse(TellomiFeed.isSettingsEnabled, "默认关（测试里没人打开过）")
        let source = SampleFeedSource(now: { Date() }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source, profilePageEnabled: false, searchEnabled: false, notificationsEnabled: false, myPostsEnabled: false)
        XCTAssertFalse(feed.settingsEnabled)
        XCTAssertNil(feed.settingsItem)
        XCTAssertNil(feed.blockedKeywords, "关着：信息流不读本机词表、不过滤")
        feed.loadViewIfNeeded()
        XCTAssertNil(feed.navigationItem.rightBarButtonItem, "关着：动态页上没有多出任何按钮")
        XCTAssertNil(feed.navigationItem.rightBarButtonItems)
        feed.openSettings()   // 关着：什么也不做（没有导航栏也不崩）
    }

    @MainActor
    func testWhenOnTheFeedHasAGearThatOpensTheSettings() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let gear = try XCTUnwrap(harness.feed.settingsItem)
        XCTAssertEqual(harness.feed.navigationItem.rightBarButtonItem, gear)
        XCTAssertEqual(gear.accessibilityLabel, FeedRecommendationSettingsViewController.title)
        XCTAssertNotNil(gear.image)
        XCTAssertNotNil(gear.primaryAction)
        harness.feed.openSettings()   // 按钮的动作就是它
        XCTAssertTrue(harness.navigation.topViewController is FeedRecommendationSettingsViewController)
    }

    @MainActor
    func testTheGearIsLeftOfSearchWhenBothAreOn() async throws {
        let harness = await makeHarness(searchEnabled: true)
        defer { harness.window.isHidden = true }
        let items = try XCTUnwrap(harness.feed.navigationItem.rightBarButtonItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[1] === harness.feed.settingsItem, "第一个是最右的：搜索在最右，齿轮在左")
        XCTAssertEqual(harness.feed.navigationItem.rightBarButtonItem?.accessibilityLabel, items[0].accessibilityLabel)
    }

    @MainActor
    func testTheFeedAndTheSettingsShareOneKeywordList() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        XCTAssertTrue((harness.feed.blockedKeywords as AnyObject) === harness.keywords)
        let victim = try XCTUnwrap(harness.feed.store.tab(.recommend).cards.first)
        let word = String(try XCTUnwrap(victim.text).prefix(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(word.isEmpty)
        let page = await harness.openSettings()
        page.store.addKeyword(word, mode: .block, days: 0)
        XCTAssertEqual(harness.keywords.active(now: Date()).map(\.keyword), [word])
        harness.feed.store.refresh(.recommend)
        await harness.feed.store.waitForLoad(.recommend)
        XCTAssertFalse(harness.feed.store.tab(.recommend).cards.contains { $0.id == victim.id }, "下一次刷新就认设置页加的「完全屏蔽」词")
    }

    // MARK: - 页面

    @MainActor
    func testTheMainlandPageShowsTheEditorialNoteAndNoMoreSensitiveChoice() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        XCTAssertEqual(page.title, FeedRecommendationSettingsViewController.title)
        let sections = page.contents.sections
        // 个性化说明 / 最近看的 / 风格 / 敏感内容 / 按类别 / 兴趣说明 / 话题 / 人 / 来源 / 关键词 / 暂停与重置
        XCTAssertEqual(sections.map(\.itemCount), [1, 4, 2, 2, 1, 1, 5, 2, 1, 3, 2])
        XCTAssertEqual(sections[1].headerTitle, OWSLocalizedString("TELLOMI_FEED_SETTINGS_RECENT", comment: ""))
        XCTAssertEqual(FeedSettingsPresentation.personalization(page.store.state), .editorialNote)
        XCTAssertFalse(page.store.state.sensitiveChoices.contains(FeedPreferences.sensitiveMore))
        XCTAssertFalse(page.categoriesOpen)
    }

    @MainActor
    func testOverseasWithScoringHasTheSwitchAndThreeSensitiveChoices() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.settingsRegion = "us"
        harness.source.simulation.settingsPersonalizationToggleVisible = true
        let page = await harness.openSettings()
        XCTAssertEqual(FeedSettingsPresentation.personalization(page.store.state), .toggle(on: true))
        XCTAssertEqual(page.contents.sections[3].itemCount, 3)
    }

    @MainActor
    func testPickingStyleAndSensitiveSavesAndTheCheckmarksFollow() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        let explore = try XCTUnwrap(page.contents.sections[2].items.last)
        explore.actionBlock?()
        await page.store.waitForTasks()
        XCTAssertEqual(page.store.state.preferences?.style, FeedPreferences.styleExplore)
        let saved = try await harness.source.preferences()
        XCTAssertEqual(saved.style, FeedPreferences.styleExplore)

        let reduce = try XCTUnwrap(page.contents.sections[3].items.first)
        reduce.actionBlock?()
        await page.store.waitForTasks()
        XCTAssertEqual(page.store.state.preferences?.sensitive, FeedPreferences.sensitiveReduce)
    }

    @MainActor
    func testTheCategoryRowOpensAllThirtySixCategories() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        XCTAssertEqual(page.contents.sections[4].itemCount, 1)
        page.toggleCategories()
        XCTAssertTrue(page.categoriesOpen)
        XCTAssertEqual(page.contents.sections[4].itemCount, 1 + 36)
        page.toggleCategories()
        XCTAssertEqual(page.contents.sections[4].itemCount, 1)
        // 点第一行（展开）不会动已存的设置
        let preferences = try await harness.source.preferences()
        XCTAssertEqual(preferences.categories.count, 2)
    }

    @MainActor
    func testDeletingAnInterestTagAndResettingGoThroughTheStore() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        page.store.deleteInterest(dimension: FeedInterests.dimTopic, interest: FeedInterest(key: "tech"))
        await page.store.waitForTasks()
        XCTAssertEqual(page.contents.sections[6].itemCount, 4)
        let after = try await harness.source.interests()
        XCTAssertFalse(after.topics.contains { $0.key == "tech" })

        page.store.reset()
        await page.store.waitForTasks()
        // 兴趣全清：说明 + 「还没有兴趣标签」，没有分组
        XCTAssertEqual(page.contents.sections.count, 11 - 3)
        await waitUntil { page.lastToastText != nil }
        XCTAssertEqual(page.lastToastText, FeedRecommendationSettingsViewController.toastText(for: .reset))
    }

    @MainActor
    func testPauseAsksFirstAndThenTheRowTurnsIntoResume() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        let before = page.contents.sections.last
        XCTAssertEqual(before?.itemCount, 2)
        page.presentPauseConfirmation()
        let alert = try XCTUnwrap(page.lastAlert)
        XCTAssertEqual(alert.actions.map(\.style), [.cancel, .default])
        XCTAssertEqual(FeedSettingsPresentation.pause(page.store.state.preferences ?? FeedPreferences(), now: Date()), .notPaused, "确认之前没发请求")

        page.store.pause()
        await page.store.waitForTasks()
        guard case .paused = FeedSettingsPresentation.pause(page.store.state.preferences ?? FeedPreferences(), now: Date()) else { return XCTFail("暂停了") }
        page.store.resume()
        await page.store.waitForTasks()
        XCTAssertEqual(FeedSettingsPresentation.pause(page.store.state.preferences ?? FeedPreferences(), now: Date()), .notPaused)
    }

    @MainActor
    func testResetAsksTwiceAndIsRefusedWhileResetting() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        page.presentResetConfirmation()
        let first = try XCTUnwrap(page.lastAlert)
        XCTAssertEqual(first.actions.map(\.style), [.cancel, .default])
        page.presentSecondResetConfirmation()
        let second = try XCTUnwrap(page.lastAlert)
        XCTAssertEqual(second.actions.map(\.style), [.cancel, .destructive])
        XCTAssertNotEqual(first.title, second.title)
        let interests = try await harness.source.interests()
        XCTAssertFalse(interests.isEmpty, "只是弹框，没重置")
    }

    // MARK: - 关键词

    @MainActor
    func testTheKeywordFormOnlyEnablesAddForAValidWordAndSubmitsWhatWasPicked() async throws {
        let form = FeedKeywordFormViewController()
        let navigation = OWSNavigationController(rootViewController: form)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        defer { window.isHidden = true }
        form.loadViewIfNeeded()
        XCTAssertEqual(form.addItem?.isEnabled, false, "还没填词")
        XCTAssertEqual(form.contents.sections.map(\.itemCount), [1, 2, 3])

        var submitted = [FeedKeywordForm]()
        form.onSubmit = { submitted.append($0) }
        form.submit()
        XCTAssertEqual(submitted, [], "无效不交")

        form.textField.text = String(repeating: "字", count: 21)
        form.textChanged()
        XCTAssertEqual(form.addItem?.isEnabled, false)
        form.textField.text = "  剧透 "
        form.textChanged()
        XCTAssertEqual(form.addItem?.isEnabled, true)
        form.select(block: true)
        form.select(days: 30)
        form.select(days: 99)   // 不在选项里：忽略
        XCTAssertEqual(form.form.days, 30)
        form.submit()
        XCTAssertEqual(submitted.count, 1)
        XCTAssertEqual(submitted[0].trimmed, "剧透")
        XCTAssertEqual(submitted[0].mode, .block)
        XCTAssertEqual(submitted[0].days, 30)
        XCTAssertEqual(form.textField.text, "  剧透 ", "改选项重画表格不丢已经输入的词")
    }

    @MainActor
    func testSubmittingTheFormAddsTheWordToTheRightPlace() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        var phoneOnly = FeedKeywordForm()
        phoneOnly.text = "phone-only"
        phoneOnly.block = true
        page.keywordFormSubmitted(phoneOnly)
        var server = FeedKeywordForm()
        server.text = "剧透"
        server.days = 7
        page.keywordFormSubmitted(server)
        page.keywordFormSubmitted(FeedKeywordForm())   // 无效：什么也不做
        await page.store.waitForTasks()
        XCTAssertEqual(harness.keywords.active(now: Date()).map(\.keyword), ["phone-only"], "完全屏蔽只存在手机上")
        let onServer = try await harness.source.keywords()
        XCTAssertTrue(onServer.contains { $0.keyword == "剧透" })
        XCTAssertFalse(onServer.contains { $0.keyword == "phone-only" })
        XCTAssertEqual(page.store.state.keywords.map(\.keyword), ["phone-only", "剧透", "spoiler", "ads"])
        XCTAssertEqual(page.contents.sections[9].itemCount, 4 + 1)
    }

    @MainActor
    func testKeywordSubtitlesSayTheModeAndWhenItEnds() async throws {
        let block = FeedSettingsPresentation.KeywordRow(keyword: "a", mode: .block, expiresAt: nil, source: FeedKeyword(keyword: "a", mode: .block, expiresAt: nil))
        let until = Date(timeIntervalSince1970: 1_800_000_000)
        let downrank = FeedSettingsPresentation.KeywordRow(keyword: "b", mode: .downrank, expiresAt: until, source: FeedKeyword(keyword: "b", mode: .downrank, expiresAt: nil))
        XCTAssertTrue(FeedRecommendationSettingsViewController.keywordSubtitle(block).contains(" · "))
        XCTAssertNotEqual(FeedRecommendationSettingsViewController.keywordSubtitle(block), FeedRecommendationSettingsViewController.keywordSubtitle(downrank))
        XCTAssertTrue(FeedRecommendationSettingsViewController.keywordSubtitle(downrank).contains(FeedRecommendationSettingsViewController.dateText(until)))
    }

    // MARK: - 失败

    @MainActor
    func testALoadFailureShowsRetryRowsAndTappingRetryLoads() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.failsSettingsLoad = true
        let page = await harness.openSettings()
        XCTAssertTrue(page.store.state.loadFailed)
        XCTAssertEqual(page.contents.sections.count, 1)
        XCTAssertEqual(page.contents.sections[0].itemCount, 2, "说一句失败 + 点按重试")
        harness.source.simulation.failsSettingsLoad = false
        let retry = try XCTUnwrap(page.contents.sections[0].items.last)
        retry.actionBlock?()
        await page.store.waitForTasks()
        XCTAssertNotNil(page.store.state.preferences)
        XCTAssertEqual(page.contents.sections.count, 11)
    }

    @MainActor
    func testAThrottledLoadSaysHowLongToWait() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.settingsThrottledRetryAfterSeconds = 12
        let page = await harness.openSettings()
        XCTAssertEqual(page.contents.sections[0].footerTitle, FeedProfileViewController.throttledText(12))
    }

    @MainActor
    func testAFailedSaveIsRolledBackAndSaysSo() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        harness.source.simulation.failsSettingsWrites = true
        page.store.setStyle(FeedPreferences.styleExplore)
        await page.store.waitForTasks()
        await waitUntil { page.lastToastText != nil }
        XCTAssertEqual(page.store.state.preferences?.style, FeedPreferences.styleKeep)
        XCTAssertEqual(page.lastToastText, FeedRecommendationSettingsViewController.toastText(for: .actionFailed))
    }

    @MainActor
    func testAThrottledSaveSaysHowLongToWait() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let page = await harness.openSettings()
        harness.source.simulation.settingsThrottledRetryAfterSeconds = 7
        page.store.setStyle(FeedPreferences.styleExplore)
        await page.store.waitForTasks()
        await waitUntil { page.lastToastText != nil }
        XCTAssertEqual(page.lastToastText, FeedProfileViewController.throttledText(7))
    }

    @MainActor
    func testKeywordsFailingToLoadStillShowsThePageWithThePhoneOnlyWords() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.keywords.add(keyword: "phone-only", expiresAt: nil)
        harness.source.simulation.failsSettingsKeywordsLoad = true
        let page = await harness.openSettings()
        XCTAssertEqual(page.contents.sections.count, 11)
        XCTAssertEqual(page.store.state.keywords.map(\.keyword), ["phone-only"])
    }

    @MainActor
    func testFeedHiddenClosesThePage() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        harness.source.simulation.feedHidden = true
        let page = await harness.openSettings()
        await waitUntil { page.didClose }
        XCTAssertTrue(page.didClose)
        await waitUntil { harness.navigation.topViewController === harness.feed }
        XCTAssertTrue(harness.navigation.topViewController === harness.feed)
    }

    // MARK: - 文字

    @MainActor
    func testEveryTopicHasALocalizedNameAndNoKeyLeaksThrough() {
        var names = Set<String>()
        for slug in FeedTopicSlug.allCases {
            let name = FeedRecommendationSettingsViewController.topicName(slug)
            XCTAssertFalse(name.isEmpty, slug.rawValue)
            XCTAssertFalse(name.hasPrefix("TELLOMI_FEED_"), "\(slug.rawValue) 没有翻译，露出了 key")
            names.insert(name)
        }
        XCTAssertEqual(names.count, 36, "名字互不相同")
        XCTAssertEqual(FeedRecommendationSettingsViewController.name(of: .text("#x")), "#x")
    }

    @MainActor
    func testNoSettingsTextIsAMissingKey() {
        let texts = [
            FeedRecommendationSettingsViewController.title,
            FeedRecommendationSettingsViewController.loadFailedText,
            FeedRecommendationSettingsViewController.personalizedTitle,
            FeedRecommendationSettingsViewController.deleteTitle,
            FeedRecommendationSettingsViewController.styleTitle(FeedPreferences.styleKeep),
            FeedRecommendationSettingsViewController.styleTitle(FeedPreferences.styleExplore),
            FeedRecommendationSettingsViewController.sensitiveTitle(.reduce),
            FeedRecommendationSettingsViewController.sensitiveTitle(.standard),
            FeedRecommendationSettingsViewController.sensitiveTitle(.more),
            FeedKeywordFormViewController.daysTitle(0),
            FeedKeywordFormViewController.daysTitle(7),
            FeedKeywordFormViewController.daysTitle(30),
        ] + FeedCategoryChoice.allCases.map(FeedRecommendationSettingsViewController.categoryTitle)
            + [
                FeedSettingsPresentation.Toast.reset, .invalidKeyword, .tooManyKeywords, .actionFailed, .throttled(retryAfterSeconds: 5), .throttled(retryAfterSeconds: nil),
            ].map(FeedRecommendationSettingsViewController.toastText(for:))
        for text in texts {
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.hasPrefix("TELLOMI_FEED_"), text)
        }
        XCTAssertEqual(Set(texts.prefix(12)).count, 12 - 0, "前 12 条互不相同")
    }
}
