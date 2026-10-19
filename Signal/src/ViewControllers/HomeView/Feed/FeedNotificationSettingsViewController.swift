//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 动态通知设置（`dynamic-feed.md` 第三节第 30、43 条）：接收谁的通知（所有人 / 我关注的人 / 好友 / 都不接收）+ 赞、评论和回复、新关注者三个开关。
/// 逻辑在 `FeedNotificationSettingsStore`：打开页面读一次，改了立刻存（先在界面上改过去，存不上改回来）；没有公开主页时提示先建主页。
/// 从通知页右上角进来（入口跟着 `TellomiFeed.isNotificationsEnabled`，默认关）。
final class FeedNotificationSettingsViewController: OWSTableViewController2 {

    let store: FeedNotificationSettingsStore

    /// 最近一次弹出的提示文字（单测 / 截图用）。
    private(set) var lastToastText: String?
    /// 页面已经（因为 `feed_hidden`）收起过（单测 / 截图用）。
    private(set) var didClose = false

    init(source: FeedSource) {
        self.store = FeedNotificationSettingsStore(source: source)
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tellomiApplyFeedPreviewPrompt()
        title = Self.title
        store.onChange = { [weak self] state in self?.apply(state) }
        apply(store.state)
        store.load()
    }

    override func themeDidChange() {
        super.themeDidChange()
        apply(store.state)
    }

    // MARK: - Rendering

    private func apply(_ state: FeedNotificationSettingsState) {
        guard isViewLoaded else { return }
        updateTableContents(state)
        if state.notice != nil {
            // `apply` 是 store 改 `state` 的 didSet 里调进来的：提示在下一轮主线程里显示并清掉
            DispatchQueue.main.async { [weak self] in self?.consumeNotice() }
        }
        if state.feedHidden { closeBecauseFeedHidden() }
    }

    private func updateTableContents(_ state: FeedNotificationSettingsState) {
        let contents = OWSTableContents()
        let section = OWSTableSection()
        if let settings = state.settings {
            section.headerTitle = OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_FROM_WHOM", comment: "Feed notification settings: header of the choice of whose notifications to get.")
            for value in FeedNotificationSettings.fromValues {
                section.add(FeedChoiceRow.item(
                    text: Self.fromTitle(value),
                    selected: settings.fromWhom == value,
                    action: { [weak self] in self?.store.setFromWhom(value) },
                ))
            }
            contents.add(section)

            let switches = OWSTableSection()
            switches.footerTitle = OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_SYSTEM_NOTE", comment: "Feed notification settings: footer saying notices about your own posts always come through.")
            let enabled = state.categoriesEnabled
            switches.add(FeedSwitchRow.item(
                text: OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_LIKES", comment: "Feed notification settings: switch for like notifications."),
                isOn: settings.likes,
                isEnabled: enabled,
                action: { [weak self] isOn in self?.store.setLikes(isOn) },
            ))
            switches.add(FeedSwitchRow.item(
                text: OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_COMMENTS", comment: "Feed notification settings: switch for comment and reply notifications."),
                isOn: settings.comments,
                isEnabled: enabled,
                action: { [weak self] isOn in self?.store.setComments(isOn) },
            ))
            switches.add(FeedSwitchRow.item(
                text: OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_FOLLOWS", comment: "Feed notification settings: switch for new follower notifications."),
                isOn: settings.follows,
                isEnabled: enabled,
                action: { [weak self] isOn in self?.store.setFollows(isOn) },
            ))
            contents.add(switches)
        } else if state.loadFailed {
            section.footerTitle = state.retryAfterSeconds.map { FeedProfileViewController.throttledText($0) }
            section.add(OWSTableItem(
                text: OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_LOAD_FAILED", comment: "Feed notification settings: shown when the settings could not be loaded."),
                actionBlock: { [weak self] in self?.store.load() },
                accessoryType: .none,
            ))
            section.add(OWSTableItem(
                text: OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_RETRY", comment: "Feed notification settings: tap to load the settings again."),
                textColor: UIColor.Signal.accent,
                actionBlock: { [weak self] in self?.store.load() },
                accessoryType: .none,
            ))
            contents.add(section)
        } else {
            section.add(OWSTableItem(
                text: OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_LOADING", comment: "Feed notification settings: shown while the settings are loading."),
                textColor: UIColor.Signal.secondaryLabel,
                actionBlock: nil,
                accessoryType: .none,
            ))
            contents.add(section)
        }
        self.contents = contents
    }

    private func closeBecauseFeedHidden() {
        guard !didClose else { return }
        didClose = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let navigationController = self.navigationController else { return }
            if navigationController.topViewController === self {
                navigationController.popViewController(animated: true)
            } else {
                navigationController.viewControllers.removeAll { $0 === self }
            }
        }
    }

    private func consumeNotice() {
        guard let notice = store.state.notice else { return }
        lastToastText = Self.toastText(for: notice, retryAfterSeconds: store.state.retryAfterSeconds)
        if let text = lastToastText, viewIfLoaded?.window != nil { presentToast(text: text) }
        store.onNoticeShown()
    }

    // MARK: - Texts

    static var title: String {
        return OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_TITLE", comment: "Feed notification settings: page title, also the accessibility label of the button that opens it.")
    }

    static func fromTitle(_ value: String) -> String {
        switch value {
        case FeedNotificationSettings.fromFollowing:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_FOLLOWING", comment: "Feed notification settings: get notifications only from people I follow.")
        case FeedNotificationSettings.fromFriends:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_FRIENDS", comment: "Feed notification settings: get notifications only from friends.")
        case FeedNotificationSettings.fromNone:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_NONE", comment: "Feed notification settings: get no notifications from anyone.")
        default:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_EVERYONE", comment: "Feed notification settings: get notifications from everyone.")
        }
    }

    static func toastText(for notice: FeedNotificationSettingsState.Notice, retryAfterSeconds: Int? = nil) -> String {
        switch notice {
        case .profileRequired:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_PROFILE_REQUIRED", comment: "Feed notification settings: toast when saving needs the user to set up their public profile first.")
        case .saveFailed:
            return OWSLocalizedString("TELLOMI_FEED_NOTIF_SETTINGS_SAVE_FAILED", comment: "Feed notification settings: toast when saving a change failed.")
        case .throttled:
            return FeedProfileViewController.throttledText(retryAfterSeconds)
        }
    }
}
