//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedRecommendationSettings.swift (new file)
// "Feed settings → recommendation" state and actions without UI (I-9). Mirror of Android
// `settings/FeedRecommendationSettingsViewModel.kt` (preferences, interests, reset, keywords).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

/// 设置页里的一个屏蔽关键词。`expiresAt` 毫秒（Unix），nil = 永久。
struct FeedKeyword: Equatable {
    enum Mode: Equatable {
        /// 少推荐：服务端降权，换设备还在。
        case downrank
        /// 完全屏蔽：只在这台手机上，信息流里命中的不显示。
        case block
    }

    var keyword: String
    var mode: Mode
    var expiresAt: Int64?
}

struct FeedRecommendationSettingsState: Equatable {
    enum Notice: Equatable {
        case failed
        case reset
        case invalidKeyword
        case tooManyKeywords
    }

    var preferences: FeedPreferences?
    var interests: FeedInterests?
    var loading = false
    var loadFailed = false
    var resetting = false
    var notice: Notice?
    var keywords = [FeedKeyword]()
    var region: String?
    /// 引擎在按兴趣排序（`recommend_mode == scored`）时才有个性化开关；编辑精选阶段推荐本来就不按个人兴趣。
    var personalizationToggleVisible = false

    /// 敏感内容的档位：「更多」只给海外（R-1.6）。区域不知道时按大陆算。
    var sensitiveChoices: [String] {
        if let region, region != "cn" { return FeedPreferences.sensitiveValues }
        return FeedPreferences.sensitiveValues.filter { $0 != FeedPreferences.sensitiveMore }
    }
}

/// 开关和删除都先在界面上改过去，存不上再改回来。
@MainActor
final class FeedRecommendationSettingsStore {
    private let source: FeedSource
    private let blockedKeywords: FeedBlockedKeywords
    private let now: () -> Date
    private var tasks = [Task<Void, Never>]()

    private(set) var state = FeedRecommendationSettingsState() {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedRecommendationSettingsState) -> Void)?

    init(source: FeedSource, blockedKeywords: FeedBlockedKeywords, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.blockedKeywords = blockedKeywords
        self.now = now
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
    }

    // MARK: - Load

    func load() {
        state.loading = true
        state.loadFailed = false
        tasks.append(Task { [weak self, source] in
            do {
                let config = try await source.config()
                let preferences = try await source.preferences()
                let interests = try await source.interests()
                // 关键词拿不到不挡整页，本机的照样显示
                var server: [FeedKeyword]?
                do {
                    server = try await source.keywords().map { k in
                        FeedKeyword(keyword: k.keyword, mode: .downrank, expiresAt: k.expiresAt.flatMap(FeedDates.parse).map(InMemoryFeedBlockedKeywords.millis))
                    }
                } catch {
                    Logger.warn("feed keywords failed: \(error)")
                }
                guard let self else { return }
                self.state.loading = false
                self.state.keywords = self.mergeKeywords(server)
                self.state.preferences = preferences
                self.state.interests = interests
                self.state.region = config.region
                self.state.personalizationToggleVisible = config.personalizationToggleVisible
            } catch {
                Logger.warn("feed recommendation settings failed: \(error)")
                self?.state.loading = false
                self?.state.loadFailed = true
            }
        })
    }

    // MARK: - Preferences

    func setPersonalized(_ on: Bool) {
        save(FeedPreferencesUpdate(personalized: on)) { var p = $0; p.personalized = on; return p }
    }

    /// 推荐风格：保持现状 / 探索更多。
    func setStyle(_ style: String) {
        guard FeedPreferences.styles.contains(style) else { return }
        save(FeedPreferencesUpdate(style: style)) { var p = $0; p.style = style; return p }
    }

    /// 敏感内容：减少 / 标准；「更多」只有海外（引擎在大陆回 `not_available_in_region`）。
    func setSensitive(_ sensitive: String) {
        guard state.sensitiveChoices.contains(sensitive) else { return }
        save(FeedPreferencesUpdate(sensitive: sensitive)) { var p = $0; p.sensitive = sensitive; return p }
    }

    /// 某个类别减少 / 默认 / 增加。引擎的 `categories` 是整张表替换，所以发完整的一张。
    func setCategory(slug: String, value: String) {
        guard let before = state.preferences, FeedPreferences.categoryValues.contains(value) else { return }
        var categories = before.categories
        if value == FeedPreferences.categoryDefault {
            categories.removeValue(forKey: slug)
        } else {
            categories[slug] = value
        }
        save(FeedPreferencesUpdate(categories: categories)) { var p = $0; p.categories = categories; return p }
    }

    /// 暂停推荐 30 天；等服务端回来再改界面。
    func pause() {
        save(FeedPreferencesUpdate(pauseDays: FeedPreferences.pauseDays), optimistic: nil)
    }

    func resume() {
        save(FeedPreferencesUpdate(pauseDays: 0)) { var p = $0; p.pausedUntil = nil; return p }
    }

    /// 先在界面上改过去（`optimistic` 为 nil 时等服务端回来再改），存上了用服务端回的，存不上改回原来的。
    private func save(_ update: FeedPreferencesUpdate, optimistic: ((FeedPreferences) -> FeedPreferences)?) {
        guard let before = state.preferences else { return }
        let after = optimistic?(before)
        if after == before { return }
        if let after { state.preferences = after }
        tasks.append(Task { [weak self, source] in
            do {
                let saved = try await source.savePreferences(update)
                guard let self else { return }
                // recent_topics 只在 GET 里有，PUT 回来的没有，留着原来的
                var merged = saved
                merged.recentTopics = self.state.preferences?.recentTopics ?? []
                self.state.preferences = merged
            } catch {
                Logger.warn("feed save preferences failed: \(error)")
                guard let self else { return }
                if after == nil || self.state.preferences == after { self.state.preferences = before }
                self.state.notice = .failed
            }
        })
    }

    // MARK: - Interests

    func deleteInterest(dimension: String, interest: FeedInterest) {
        guard let before = state.interests else { return }
        state.interests = before.without(dimension: dimension, key: interest.key)
        tasks.append(Task { [weak self, source] in
            do {
                try await source.deleteInterest(dimension: dimension, key: interest.key)
            } catch {
                Logger.warn("feed delete interest failed: \(error)")
                self?.state.interests = before
                self?.state.notice = .failed
            }
        })
    }

    /// 界面上已经确认过两次。
    func reset() {
        if state.resetting { return }
        state.resetting = true
        tasks.append(Task { [weak self, source] in
            do {
                try await source.resetInterests()
                let interests = try await source.interests()
                self?.state.resetting = false
                self?.state.interests = interests
                self?.state.notice = .reset
            } catch {
                Logger.warn("feed reset failed: \(error)")
                self?.state.resetting = false
                self?.state.notice = .failed
            }
        })
    }

    // MARK: - Keywords

    /// 加一个屏蔽关键词（第三节第 12 条）：「少推荐」交给服务端降权；「完全屏蔽」只存在手机上，信息流里直接不显示。
    /// `days` 0 = 永久，30，7。长度按 Unicode 码点算（和 Android `codePointCount` 一致），不是 Character。
    func addKeyword(_ keyword: String, mode: FeedKeyword.Mode, days: Int) {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty || k.unicodeScalars.count > FeedKeywordRequest.maxChars || !FeedKeywordRequest.allowedDays.contains(days) {
            state.notice = .invalidKeyword
            return
        }
        let expiresAt = days == 0 ? nil : now().addingTimeInterval(TimeInterval(days) * 86_400)
        let expiresMillis = expiresAt.map(InMemoryFeedBlockedKeywords.millis)
        switch mode {
        case .block:
            blockedKeywords.add(keyword: k, expiresAt: expiresAt)
            state.keywords = mergeKeywords(state.keywords)
        case .downrank:
            let downranked = state.keywords.filter { $0.mode == .downrank }
            if downranked.count >= FeedKeywordRequest.maxKeywords && !downranked.contains(where: { $0.keyword == k }) {
                state.notice = .tooManyKeywords
                return
            }
            tasks.append(Task { [weak self, source] in
                do {
                    try await source.putKeyword(k, days: days)
                    guard let self else { return }
                    let server = self.state.keywords.filter { $0.mode == .downrank && $0.keyword != k }
                    self.state.keywords = self.mergeKeywords([FeedKeyword(keyword: k, mode: .downrank, expiresAt: expiresMillis)] + server)
                } catch {
                    Logger.warn("feed add keyword failed: \(error)")
                    let code = (error as? FeedAPIError)?.code
                    self?.state.notice = code == "too_many_keywords" ? .tooManyKeywords : (code == "invalid_keyword" ? .invalidKeyword : .failed)
                }
            })
        }
    }

    func removeKeyword(_ keyword: FeedKeyword) {
        switch keyword.mode {
        case .block:
            blockedKeywords.remove(keyword: keyword.keyword)
            state.keywords = mergeKeywords(state.keywords)
        case .downrank:
            let before = state.keywords
            state.keywords = before.filter { $0 != keyword }
            tasks.append(Task { [weak self, source] in
                do {
                    try await source.deleteKeyword(keyword.keyword)
                } catch {
                    Logger.warn("feed delete keyword failed: \(error)")
                    self?.state.keywords = before
                    self?.state.notice = .failed
                }
            })
        }
    }

    /// 本机「完全屏蔽」的放前面，再接服务端「少推荐」的（`server` 为 nil 时沿用当前列表里的）。
    private func mergeKeywords(_ server: [FeedKeyword]?) -> [FeedKeyword] {
        let date = now()
        let nowMillis = InMemoryFeedBlockedKeywords.millis(date)
        let local = blockedKeywords.active(now: date).map { FeedKeyword(keyword: $0.keyword, mode: .block, expiresAt: $0.expiresAt) }
        let remote = (server ?? state.keywords).filter { $0.mode == .downrank && ($0.expiresAt.map { $0 > nowMillis } ?? true) }
        return local + remote
    }

    func onNoticeShown() {
        state.notice = nil
    }
}
