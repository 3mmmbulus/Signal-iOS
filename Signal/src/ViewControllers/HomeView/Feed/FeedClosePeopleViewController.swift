//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 「关心的人」（`dynamic-feed.md` 第三节第 42 条，Android `FeedClosePeopleFragment`）：最多设 3 个人展示在我的公开主页上，对方同意后才显示；
/// 搜 ID 或名字添加（和动态搜索的「用户」一样，只搜得到设了 ID 的人）；下面回应「设我为关心的人」的请求（同意 / 拒绝 / 撤回）。
/// 逻辑在 `FeedClosePeopleStore`：移除、回应都先在界面上改过去，失败再改回来。
/// 从 `FeedListsViewController` 推进来（入口跟着 `TellomiFeed.isListsEnabled`，默认关）。
final class FeedClosePeopleViewController: OWSTableViewController2 {

    let store: FeedClosePeopleStore

    /// 最近一次弹出的提示文字（单测 / 截图用）。
    private(set) var lastToastText: String?
    /// 页面已经（因为 `feed_hidden`）收起过（单测 / 截图用）。
    private(set) var didClose = false

    init(source: FeedSource) {
        self.store = FeedClosePeopleStore(source: source)
        super.init()
    }

    private(set) lazy var searchField: UITextField = {
        let field = UITextField()
        field.placeholder = Self.searchHint
        field.font = .dynamicTypeBody
        field.textColor = UIColor.Signal.label
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.addAction(UIAction { [weak self] _ in self?.searchChanged() }, for: .editingChanged)
        field.addAction(UIAction { [weak field] _ in field?.resignFirstResponder() }, for: .editingDidEndOnExit)
        return field
    }()

    /// 搜索框只建一次：状态变了重画表格时还是同一个，不丢输入。
    private lazy var searchFieldCell: UITableViewCell = {
        let cell = OWSTableItem.newCell()
        cell.selectionStyle = .none
        cell.contentView.addSubview(searchField)
        searchField.autoPinEdgesToSuperviewMargins()
        searchField.autoSetDimension(.height, toSize: 28, relation: .greaterThanOrEqual)
        return cell
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.title
        store.onChange = { [weak self] state in self?.apply(state) }
        apply(store.state)
        store.start()
    }

    override func themeDidChange() {
        super.themeDidChange()
        apply(store.state)
    }

    // MARK: - Rendering

    private func apply(_ state: FeedClosePeopleState) {
        guard isViewLoaded else { return }
        // 添加成功后 store 清了搜索词：输入框跟着清（一样就不碰，免得打断输入法）
        if searchField.text ?? "" != state.query { searchField.text = state.query }
        updateTableContents(state)
        if state.notice != nil {
            DispatchQueue.main.async { [weak self] in self?.consumeNotice() }
        }
        if state.feedHidden { closeBecauseFeedHidden() }
    }

    private func updateTableContents(_ state: FeedClosePeopleState) {
        let contents = OWSTableContents()
        if state.failed {
            let section = OWSTableSection()
            section.footerTitle = state.retryAfterSeconds.map { FeedProfileViewController.throttledText($0) }
            section.add(Self.noteItem(FeedPeopleViewController.loadFailedText))
            section.add(OWSTableItem(
                text: OWSLocalizedString("TELLOMI_FEED_RETRY", comment: "Feed: retry button."),
                textColor: UIColor.Signal.accent,
                actionBlock: { [weak self] in self?.store.refresh() },
                accessoryType: .none,
            ))
            contents.add(section)
            self.contents = contents
            return
        }
        guard state.loadedOnce else {
            let section = OWSTableSection()
            section.add(Self.noteItem(OWSLocalizedString("TELLOMI_FEED_SETTINGS_LOADING", comment: "Feed settings: shown while the settings are loading.")))
            contents.add(section)
            self.contents = contents
            return
        }
        addSearch(state, to: contents)
        addMine(state, to: contents)
        addRequests(state, to: contents)
        self.contents = contents
    }

    private func addSearch(_ state: FeedClosePeopleState, to contents: OWSTableContents) {
        let section = OWSTableSection()
        section.footerTitle = String(format: Self.explainFormat, OWSFormat.formatInt(FeedClosePersonEntry.max))
        let cell = searchFieldCell
        section.add(OWSTableItem(customCellBlock: { cell }))
        if !state.canAdd {
            section.add(Self.noteItem(String(format: Self.fullFormat, OWSFormat.formatInt(FeedClosePersonEntry.max))))
        } else {
            let results = state.addableResults
            for user in results {
                section.add(searchResultItem(user, enabled: !state.adding))
            }
            let hasTerm = !FeedClosePeopleStore.searchTerm(state.query).isEmpty
            if hasTerm && !state.searching && state.results.isEmpty {
                section.add(Self.noteItem(OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_NO_RESULTS", comment: "Feed close people: shown when the search found no one.")))
            }
        }
        contents.add(section)
    }

    private func searchResultItem(_ user: FeedSearchUser, enabled: Bool) -> OWSTableItem {
        return OWSTableItem(customCellBlock: { [weak self] in
            let handle = user.handle.flatMap { $0.isEmpty ? nil : "@\($0)" }
            let action: (() -> Void)? = enabled ? { self?.store.add(user) } : nil
            return Self.personCell(name: user.displayName, subtitle: handle, buttons: [
                (title: Self.addTitle, color: UIColor.Signal.accent, action: action),
            ])
        })
    }

    private func addMine(_ state: FeedClosePeopleState, to contents: OWSTableContents) {
        let section = OWSTableSection()
        section.headerTitle = String(
            format: OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_MINE", comment: "Feed close people: header of the people I picked. Embeds {{how many I picked}} and {{the most I can pick}}."),
            OWSFormat.formatInt(state.mine.count),
            OWSFormat.formatInt(FeedClosePersonEntry.max),
        )
        if state.mine.isEmpty {
            section.add(Self.noteItem(OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_MINE_EMPTY", comment: "Feed close people: shown when I haven't picked anyone.")))
        }
        for entry in state.mine {
            section.add(OWSTableItem(customCellBlock: { [weak self] in
                let status = entry.accepted
                    ? OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_ACCEPTED", comment: "Feed close people: they agreed to be shown on my profile.")
                    : OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_PENDING", comment: "Feed close people: waiting for them to agree.")
                return Self.personCell(name: entry.displayName, subtitle: status, buttons: [
                    (title: Self.removeTitle, color: UIColor.Signal.red, action: { self?.store.remove(entry) }),
                ])
            }))
        }
        contents.add(section)
    }

    private func addRequests(_ state: FeedClosePeopleState, to contents: OWSTableContents) {
        let section = OWSTableSection()
        section.headerTitle = OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_REQUESTS", comment: "Feed close people: header of the people who picked me.")
        if state.requests.isEmpty {
            section.add(Self.noteItem(OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_REQUESTS_EMPTY", comment: "Feed close people: shown when no one picked me.")))
        }
        for entry in state.requests {
            section.add(OWSTableItem(customCellBlock: { [weak self] in
                if entry.accepted {
                    return Self.personCell(
                        name: entry.displayName,
                        subtitle: OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_REQUEST_ACCEPTED", comment: "Feed close people: I agreed, they show me on their profile."),
                        buttons: [(title: Self.withdrawTitle, color: UIColor.Signal.red, action: { self?.store.answer(entry, accept: false) })],
                    )
                }
                return Self.personCell(
                    name: entry.displayName,
                    subtitle: OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_REQUEST_PENDING", comment: "Feed close people: they want to show me on their profile."),
                    buttons: [
                        (title: Self.acceptTitle, color: UIColor.Signal.accent, action: { self?.store.answer(entry, accept: true) }),
                        (title: FeedPeopleViewController.declineTitle, color: UIColor.Signal.red, action: { self?.store.answer(entry, accept: false) }),
                    ],
                )
            }))
        }
        contents.add(section)
    }

    // MARK: - Actions

    private func searchChanged() {
        store.onQueryChanged(searchField.text ?? "")
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
        lastToastText = Self.toastText(for: notice)
        if let text = lastToastText, viewIfLoaded?.window != nil { presentToast(text: text) }
        store.onNoticeShown()
    }

    // MARK: - Cells

    private static func noteItem(_ text: String) -> OWSTableItem {
        return OWSTableItem(text: text, textColor: UIColor.Signal.secondaryLabel, actionBlock: nil, accessoryType: .none)
    }

    /// 头像 + 名字 + 小字，下面一排文字按钮（`action` 为空的按钮是灰的）。
    private static func personCell(
        name: String,
        subtitle: String?,
        buttons: [(title: String, color: UIColor, action: (() -> Void)?)],
    ) -> UITableViewCell {
        let cell = OWSTableItem.newCell()
        cell.selectionStyle = .none
        let avatar = FeedAvatarView(size: 40)
        avatar.configure(name: name)
        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .dynamicTypeBody
        nameLabel.textColor = UIColor.Signal.label
        nameLabel.numberOfLines = 0
        var labels: [UIView] = [nameLabel]
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
        let top = UIStackView(arrangedSubviews: [avatar, texts])
        top.axis = .horizontal
        top.alignment = .center
        top.spacing = 12

        var rows: [UIView] = [top]
        let buttonViews: [UIView] = buttons.map { item in
            let button = UIButton(type: .system)
            button.setTitle(item.title, for: .normal)
            button.setTitleColor(item.action == nil ? UIColor.Signal.secondaryLabel : item.color, for: .normal)
            button.titleLabel?.font = .dynamicTypeBody
            button.isEnabled = item.action != nil
            if let action = item.action {
                button.addAction(UIAction { _ in action() }, for: .touchUpInside)
            }
            return button
        }
        let buttonRow = UIStackView(arrangedSubviews: buttonViews + [UIView()])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 24
        rows.append(buttonRow)
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 8
        cell.contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewMargins()
        return cell
    }

    // MARK: - Texts

    static var title: String {
        return OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_TITLE", comment: "Feed close people: page title (up to 3 people shown on my public profile).")
    }

    static var searchHint: String {
        return OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_SEARCH_HINT", comment: "Feed close people: placeholder of the search field.")
    }

    static var explainFormat: String {
        return OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_EXPLAIN", comment: "Feed close people: explains the limit and that they only show after they agree. Embeds {{the most people I can pick}}.")
    }

    static var fullFormat: String {
        return OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_FULL", comment: "Feed close people: I already picked the most people. Embeds {{the most people I can pick}}.")
    }

    static var addTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_ADD", comment: "Feed close people: button that picks a person.")
    }

    static var removeTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_REMOVE", comment: "Feed close people: button that removes a person I picked.")
    }

    static var acceptTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_ACCEPT", comment: "Feed close people: button that agrees to be shown on their profile.")
    }

    static var withdrawTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_WITHDRAW", comment: "Feed close people: button that withdraws an agreement to be shown on their profile.")
    }

    static func toastText(for notice: FeedClosePeopleNotice) -> String {
        switch notice {
        case .added:
            return OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_ADDED", comment: "Feed close people: toast after the request was sent.")
        case .full:
            return String(format: fullFormat, OWSFormat.formatInt(FeedClosePersonEntry.max))
        case .profileRequired:
            return OWSLocalizedString("TELLOMI_FEED_PROFILE_REQUIRED", comment: "Feed: toast when an action needs the public profile first.")
        case .notAllowed:
            return OWSLocalizedString("TELLOMI_FEED_CLOSE_PEOPLE_NOT_ALLOWED", comment: "Feed close people: toast when this person can't be picked.")
        case .failed:
            return OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed.")
        case .throttled(let seconds):
            return FeedProfileViewController.throttledText(seconds)
        }
    }
}
