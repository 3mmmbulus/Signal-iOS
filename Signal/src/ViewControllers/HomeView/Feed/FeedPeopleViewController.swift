//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 四张名单共用的页面（`dynamic-feed.md` 第三节第 29、44 条，Android `FeedPeopleFragment`）：关注请求（同意 / 拒绝）、
/// 动态屏蔽列表（取消屏蔽，作者 / 来源 / 话题）、「不看 TA 的动态」和「不让 TA 看我的动态」（移出）。
/// 逻辑在 `FeedPeopleStore`：点了的那一行先从名单里拿掉，引擎说不行再放回原位并提示；对方已经撤回就当处理完了。
/// 从 `FeedListsViewController` 推进来（入口跟着 `TellomiFeed.isListsEnabled`，默认关）。
final class FeedPeopleViewController: OWSTableViewController2 {

    let mode: FeedPeopleMode
    let store: FeedPeopleStore

    /// 最近一次弹出的提示文字（单测 / 截图用）。
    private(set) var lastToastText: String?
    /// 页面已经（因为 `feed_hidden`）收起过（单测 / 截图用）。
    private(set) var didClose = false

    init(mode: FeedPeopleMode, source: FeedSource) {
        self.mode = mode
        self.store = FeedPeopleStore(mode: mode, source: source)
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.title(for: mode)
        store.onChange = { [weak self] state in self?.apply(state) }
        apply(store.state)
        store.start()
    }

    override func themeDidChange() {
        super.themeDidChange()
        apply(store.state)
    }

    // MARK: - Rendering

    private func apply(_ state: FeedPeopleState) {
        guard isViewLoaded else { return }
        updateTableContents(state)
        if state.notice != nil {
            // `apply` 是 store 改 `state` 的 didSet 里调进来的：提示在下一轮主线程里显示并清掉
            DispatchQueue.main.async { [weak self] in self?.consumeNotice() }
        }
        if state.feedHidden { closeBecauseFeedHidden() }
    }

    private func updateTableContents(_ state: FeedPeopleState) {
        let contents = OWSTableContents()
        let section = OWSTableSection()
        if state.failed {
            section.footerTitle = state.retryAfterSeconds.map { FeedProfileViewController.throttledText($0) }
            section.add(Self.noteItem(Self.loadFailedText))
            section.add(OWSTableItem(
                text: OWSLocalizedString("TELLOMI_FEED_RETRY", comment: "Feed: retry button."),
                textColor: UIColor.Signal.accent,
                actionBlock: { [weak self] in self?.store.refresh() },
                accessoryType: .none,
            ))
        } else if !state.loadedOnce {
            section.add(Self.noteItem(OWSLocalizedString("TELLOMI_FEED_SETTINGS_LOADING", comment: "Feed settings: shown while the settings are loading.")))
        } else {
            section.footerTitle = Self.explain(for: mode)
            if state.rows.isEmpty {
                section.add(Self.noteItem(Self.emptyText(for: mode)))
            }
            for row in state.rows {
                section.add(rowItem(row))
            }
        }
        contents.add(section)
        self.contents = contents
    }

    private func rowItem(_ row: FeedPeopleRow) -> OWSTableItem {
        let mode = self.mode
        return OWSTableItem(customCellBlock: { [weak self] in
            let cell = OWSTableItem.newCell()
            cell.selectionStyle = .none
            let (title, subtitle) = Self.texts(for: row.display)

            let avatar = FeedAvatarView(size: 40)
            avatar.configure(name: title)
            let titleLabel = UILabel()
            titleLabel.text = title
            titleLabel.font = .dynamicTypeBody
            titleLabel.textColor = UIColor.Signal.label
            titleLabel.numberOfLines = 0
            var labels: [UIView] = [titleLabel]
            if let subtitle {
                let subtitleLabel = UILabel()
                subtitleLabel.text = subtitle
                subtitleLabel.font = .dynamicTypeSubheadline
                subtitleLabel.textColor = UIColor.Signal.secondaryLabel
                subtitleLabel.numberOfLines = 0
                labels.append(subtitleLabel)
            }
            let texts = UIStackView(arrangedSubviews: labels)
            texts.axis = .vertical
            texts.spacing = 2

            var topViews: [UIView] = []
            if case .person = row.display { topViews.append(avatar) }
            topViews.append(texts)
            let top = UIStackView(arrangedSubviews: topViews)
            top.axis = .horizontal
            top.alignment = .center
            top.spacing = 12

            let stack = UIStackView(arrangedSubviews: [top])
            stack.axis = .vertical
            stack.spacing = 8
            cell.contentView.addSubview(stack)
            stack.autoPinEdgesToSuperviewMargins()

            switch mode {
            case .followRequests:
                let approve = Self.textButton(Self.approveTitle, color: UIColor.Signal.accent) { [weak self] in self?.store.answer(row, approve: true) }
                let decline = Self.textButton(Self.declineTitle, color: UIColor.Signal.red) { [weak self] in self?.store.answer(row, approve: false) }
                let buttons = UIStackView(arrangedSubviews: [approve, decline, UIView()])
                buttons.axis = .horizontal
                buttons.spacing = 24
                stack.addArrangedSubview(buttons)
            case .blocked:
                cell.accessoryView = Self.accessoryButton(Self.unblockTitle) { [weak self] in self?.store.unblock(row) }
            case .muted, .hiddenFrom:
                cell.accessoryView = Self.accessoryButton(Self.removeTitle) { [weak self] in self?.store.remove(row) }
            }
            return cell
        })
    }

    // MARK: - Actions

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
        lastToastText = Self.toastText(for: notice)
        if let text = lastToastText, viewIfLoaded?.window != nil { presentToast(text: text) }
        store.onNoticeShown()
    }

    // MARK: - Cells

    private static func noteItem(_ text: String) -> OWSTableItem {
        return OWSTableItem(text: text, textColor: UIColor.Signal.secondaryLabel, actionBlock: nil, accessoryType: .none)
    }

    private static func textButton(_ title: String, color: UIColor, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(color, for: .normal)
        button.titleLabel?.font = .dynamicTypeBody
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    /// 右边的一个文字按钮（accessoryView 要自己定好大小）。
    private static func accessoryButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let button = textButton(title, color: UIColor.Signal.accent, action: action)
        button.sizeToFit()
        return button
    }

    // MARK: - Texts

    /// 一行的标题和小字：人是名字和 @ID，来源 / 话题 / 不认识的写「类型：名字」。
    static func texts(for display: FeedPeopleRow.Display) -> (title: String, subtitle: String?) {
        switch display {
        case .person(let name, let handle, _):
            let shownHandle = handle.flatMap { $0.isEmpty ? nil : "@\($0)" }
            if name.isEmpty { return (shownHandle ?? "?", nil) }
            return (name, shownHandle)
        case .source(let id):
            return (String(format: OWSLocalizedString("TELLOMI_FEED_PEOPLE_BLOCKED_SOURCE", comment: "Feed blocked list: a blocked source. Embeds {{the source}}."), id), nil)
        case .topic(let id):
            let name = FeedTopicSlug(rawValue: id).map { FeedRecommendationSettingsViewController.topicName($0) } ?? id
            return (String(format: OWSLocalizedString("TELLOMI_FEED_PEOPLE_BLOCKED_TOPIC", comment: "Feed blocked list: a blocked topic. Embeds {{the topic}}."), name), nil)
        case .other(let id):
            return (String(format: OWSLocalizedString("TELLOMI_FEED_PEOPLE_BLOCKED_OTHER", comment: "Feed blocked list: a blocked entry of an unknown kind. Embeds {{its id}}."), id), nil)
        }
    }

    static func title(for mode: FeedPeopleMode) -> String {
        switch mode {
        case .followRequests:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_REQUESTS_TITLE", comment: "Feed lists: title of the follow requests list.")
        case .blocked:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_BLOCKED_TITLE", comment: "Feed lists: title of the list of people, sources and topics blocked in Feed.")
        case .muted:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_MUTED_TITLE", comment: "Feed lists: title of the list of people whose posts you don't see.")
        case .hiddenFrom:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_HIDDEN_FROM_TITLE", comment: "Feed lists: title of the list of people your posts are hidden from.")
        }
    }

    static func explain(for mode: FeedPeopleMode) -> String? {
        switch mode {
        case .followRequests:
            return nil
        case .blocked:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_BLOCKED_EXPLAIN", comment: "Feed lists: says blocking in Feed doesn't block anyone in chats.")
        case .muted:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_MUTED_EXPLAIN", comment: "Feed lists: says their posts won't show in Following or Recommended, they won't know, you can still open their profile.")
        case .hiddenFrom:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_HIDDEN_FROM_EXPLAIN", comment: "Feed lists: says they can't see any of your posts, public ones included, and won't know.")
        }
    }

    static func emptyText(for mode: FeedPeopleMode) -> String {
        switch mode {
        case .followRequests:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_REQUESTS_EMPTY", comment: "Feed lists: shown when there are no follow requests.")
        case .blocked:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_BLOCKED_EMPTY", comment: "Feed lists: shown when nothing is blocked in Feed.")
        case .muted:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_MUTED_EMPTY", comment: "Feed lists: shown when the don't-show-their-posts list is empty.")
        case .hiddenFrom:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_HIDDEN_FROM_EMPTY", comment: "Feed lists: shown when the hide-my-posts-from list is empty.")
        }
    }

    static var loadFailedText: String {
        return OWSLocalizedString("TELLOMI_FEED_PEOPLE_LOAD_FAILED", comment: "Feed lists: shown when a list could not be loaded.")
    }

    static var approveTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_PEOPLE_APPROVE", comment: "Feed lists: button that approves a follow request.")
    }

    static var declineTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_PEOPLE_DECLINE", comment: "Feed lists: button that declines a follow request.")
    }

    static var unblockTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_PEOPLE_UNBLOCK", comment: "Feed lists: button that removes a block in Feed.")
    }

    static var removeTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_PEOPLE_REMOVE", comment: "Feed lists: button that removes a person from a list.")
    }

    static func toastText(for notice: FeedPeopleNotice) -> String {
        switch notice {
        case .approved:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_APPROVED", comment: "Feed lists: toast after a follow request was approved.")
        case .declined:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_DECLINED", comment: "Feed lists: toast after a follow request was declined.")
        case .unblocked:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_UNBLOCKED", comment: "Feed lists: toast after a block in Feed was removed.")
        case .removed:
            return OWSLocalizedString("TELLOMI_FEED_PEOPLE_REMOVED", comment: "Feed lists: toast after a person was removed from a list.")
        case .failed:
            return OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed.")
        case .throttled(let seconds):
            return FeedProfileViewController.throttledText(seconds)
        }
    }
}
