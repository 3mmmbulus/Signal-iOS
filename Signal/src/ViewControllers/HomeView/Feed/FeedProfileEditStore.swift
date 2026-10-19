//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedProfileEditStore.swift (new file)
// Edit-my-public-profile page, without UI (I-5 / I-20): display name (32) and bio (200) with the Telegram-style input limit —
// typing at the limit is blocked, a paste is cut to the limit by code point, the screen shows `nameRemaining` / `bioRemaining`.
// Mirror of the rules the engine enforces on `PUT /v1/feed/me/profile` (`MaxNameChars`, `MaxBioChars`).
//
// Not wired to any screen: the profile editor view controller calls `onNameEdit` / `onBioEdit` from its
// `shouldChangeCharactersIn` / `shouldChangeTextIn` hook (see `FeedInputLimit`).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct FeedProfileEditState: Equatable {
    var loading = true
    /// 读不到自己的主页（网络等）；这时不让存，免得把空的盖上去。
    var loadFailed = false
    /// 还没建过公开主页：存的时候是「建」，名字必填。
    var isNew = true
    var name = ""
    var bio = ""
    /// 刚才输入/粘贴碰到了上限（被挡住或剪短了），界面可以让计数闪一下（I-20）。
    var nameLimitHit = false
    var bioLimitHit = false
    var saving = false
    var failed = false
    /// 引擎 400 `display_name_required`。
    var nameRequired = false
    /// 引擎 400 `invalid_field`（超长、含不允许的字符等）。
    var invalidField = false
    /// 存成功了，界面可以关页面。
    var saved = false
    fileprivate var original: (name: String, bio: String)?

    static func == (lhs: FeedProfileEditState, rhs: FeedProfileEditState) -> Bool {
        lhs.loading == rhs.loading && lhs.loadFailed == rhs.loadFailed && lhs.isNew == rhs.isNew
            && lhs.name == rhs.name && lhs.bio == rhs.bio && lhs.nameLimitHit == rhs.nameLimitHit
            && lhs.bioLimitHit == rhs.bioLimitHit && lhs.saving == rhs.saving && lhs.failed == rhs.failed
            && lhs.nameRequired == rhs.nameRequired && lhs.invalidField == rhs.invalidField && lhs.saved == rhs.saved
    }

    /// 名字还能输几个字（按码点，I-20）。输入法拼写中可能是负数。
    var nameRemaining: Int { FeedInputLimit.remaining(name, limit: FeedInputLimit.profileName) }
    var bioRemaining: Int { FeedInputLimit.remaining(bio, limit: FeedInputLimit.profileBio) }

    private var nameChanged: Bool { name.trimmed != (original?.name ?? "").trimmed }
    private var bioChanged: Bool { bio.trimmed != (original?.bio ?? "").trimmed }

    var canSave: Bool {
        if loading || loadFailed || saving { return false }
        if nameRemaining < 0 || bioRemaining < 0 { return false }
        if name.trimmed.isEmpty { return false }
        return isNew || nameChanged || bioChanged
    }

    var hasUnsavedChanges: Bool { !saved && (isNew ? !(name.trimmed.isEmpty && bio.trimmed.isEmpty) : (nameChanged || bioChanged)) }
}

@MainActor
final class FeedProfileEditStore {
    private let source: FeedSource
    private var tasks = [Task<Void, Never>]()

    private(set) var state = FeedProfileEditState() {
        didSet { onChange?(state) }
    }
    var onChange: ((FeedProfileEditState) -> Void)?

    init(source: FeedSource) {
        self.source = source
    }

    func waitForTasks() async {
        while let task = tasks.first {
            await task.value
            tasks.removeFirst()
        }
    }

    func start() {
        tasks.append(Task { [weak self, source] in
            do {
                let mine = try await source.myProfile()
                guard let self else { return }
                var next = self.state
                next.loading = false
                next.loadFailed = false
                if let mine {
                    next.isNew = false
                    next.name = mine.displayName
                    next.bio = mine.bio ?? ""
                    next.original = (mine.displayName, mine.bio ?? "")
                }
                // 还没建过：一直是空的，用户在加载期间打的字不丢
                self.state = next
            } catch {
                Logger.warn("feed profile edit load failed: \(error)")
                self?.state.loading = false
                self?.state.loadFailed = true
            }
        })
    }

    // MARK: 名字

    /// 整段替换名字（恢复、粘贴整段）：超过 32 个码点就剪到 32；拼写中（`composing`）先放行，拼完再来一次（I-20）。
    func onNameChanged(_ text: String, composing: Bool = false) {
        let clipped = FeedInputLimit.clip(text, limit: FeedInputLimit.profileName, composing: composing)
        state.name = clipped.text
        state.nameLimitHit = clipped.clipped
        state.nameRequired = false
        state.invalidField = false
    }

    /// 名字输入框的 `shouldChangeCharactersIn` 里调：`accepted` 为真就让系统照常改，否则返回 NO，
    /// 并在 `clipped` 时由界面把文字设成 `store.state.name`（I-20）。
    @discardableResult
    func onNameEdit(range: NSRange, replacement: String, composing: Bool = false) -> FeedInputEdit {
        let edit = FeedInputLimit.edit(current: state.name, range: range, replacement: replacement,
                                       limit: FeedInputLimit.profileName, composing: composing)
        if edit.changed {
            state.name = edit.text
            state.nameRequired = false
            state.invalidField = false
        }
        state.nameLimitHit = edit.limitHit
        return edit
    }

    // MARK: 简介

    func onBioChanged(_ text: String, composing: Bool = false) {
        let clipped = FeedInputLimit.clip(text, limit: FeedInputLimit.profileBio, composing: composing)
        state.bio = clipped.text
        state.bioLimitHit = clipped.clipped
        state.invalidField = false
    }

    @discardableResult
    func onBioEdit(range: NSRange, replacement: String, composing: Bool = false) -> FeedInputEdit {
        let edit = FeedInputLimit.edit(current: state.bio, range: range, replacement: replacement,
                                       limit: FeedInputLimit.profileBio, composing: composing)
        if edit.changed {
            state.bio = edit.text
            state.invalidField = false
        }
        state.bioLimitHit = edit.limitHit
        return edit
    }

    // MARK: 保存

    /// 只发改了的字段（`nil` 引擎当作不变）；新建时名字必带。简介清空要发 `""`。
    func save() {
        let current = state
        guard current.canSave else { return }
        state.saving = true
        state.failed = false
        state.nameRequired = false
        state.invalidField = false
        var update = FeedProfileUpdate()
        let name = current.name.trimmed
        let bio = current.bio.trimmed
        if current.isNew || name != (current.original?.name ?? "").trimmed { update.displayName = name }
        if bio != (current.original?.bio ?? "").trimmed || (current.isNew && !bio.isEmpty) { update.bio = bio }
        tasks.append(Task { [weak self, source, update] in
            do {
                let saved = try await source.saveProfile(update)
                guard let self else { return }
                var next = self.state
                next.saving = false
                next.saved = true
                next.isNew = false
                next.name = saved.displayName
                next.bio = saved.bio ?? ""
                next.original = (saved.displayName, saved.bio ?? "")
                self.state = next
            } catch {
                guard let self else { return }
                var next = self.state
                next.saving = false
                if let error = error as? FeedAPIError, error.status == 400, error.code == "display_name_required" {
                    next.nameRequired = true
                } else if let error = error as? FeedAPIError, error.status == 400, error.code == "invalid_field" {
                    next.invalidField = true
                } else {
                    Logger.warn("feed profile save failed: \(error)")
                    next.failed = true
                }
                self.state = next
            }
        })
    }
}
