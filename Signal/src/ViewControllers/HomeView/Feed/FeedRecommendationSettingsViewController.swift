//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 动态设置（`dynamic-feed.md` 第三节第 12、28、47 条；《算法推荐管理规定》第 17 条）：个性化推荐开关、最近看的内容、推荐风格、敏感内容、按类别调整、
/// 兴趣标签（只有自己看得到，能删）、屏蔽关键词（少推荐 / 完全屏蔽）、暂停推荐 30 天、重置推荐（确认两次）。
/// 逻辑在 `FeedRecommendationSettingsStore`，要画什么在 `FeedSettingsPresentation`：打开页面读一次，改了立刻存（先在界面上改过去，存不上改回来）。
/// 从动态页右上角的齿轮进来（入口跟着 `TellomiFeed.isSettingsEnabled`，默认关）。
final class FeedRecommendationSettingsViewController: OWSTableViewController2 {

    let store: FeedRecommendationSettingsStore
    private let now: () -> Date
    private typealias P = FeedSettingsPresentation

    /// 最近一次弹出的提示文字（单测 / 截图用）。
    private(set) var lastToastText: String?
    /// 页面已经（因为 `feed_hidden`）收起过（单测 / 截图用）。
    private(set) var didClose = false
    /// 最近一次弹出的对话框（单测 / 截图用）。
    private(set) var lastAlert: UIAlertController?
    /// 「按类别调整」展开了没有。
    private(set) var categoriesOpen = false

    /// `blockedKeywords` 要和动态页的 `FeedStore` 是同一份：设置页加的「完全屏蔽」词，信息流下一次刷新时就认。
    init(source: FeedSource, blockedKeywords: FeedBlockedKeywords, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.store = FeedRecommendationSettingsStore(source: source, blockedKeywords: blockedKeywords, now: now)
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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

    private func apply(_ state: FeedRecommendationSettingsState) {
        guard isViewLoaded else { return }
        updateTableContents(state)
        if state.notice != nil {
            // `apply` 是 store 改 `state` 的 didSet 里调进来的：提示在下一轮主线程里显示并清掉
            DispatchQueue.main.async { [weak self] in self?.consumeNotice() }
        }
        if state.feedHidden { closeBecauseFeedHidden() }
    }

    private func updateTableContents(_ state: FeedRecommendationSettingsState) {
        let contents = OWSTableContents()
        switch P.phase(state) {
        case .loading:
            let section = OWSTableSection()
            section.add(Self.noteItem(OWSLocalizedString("TELLOMI_FEED_SETTINGS_LOADING", comment: "Feed settings: shown while the settings are loading.")))
            contents.add(section)
        case .failed(let seconds):
            let section = OWSTableSection()
            section.footerTitle = seconds.map { FeedProfileViewController.throttledText($0) }
            section.add(OWSTableItem(
                text: Self.loadFailedText,
                actionBlock: { [weak self] in self?.store.load() },
                accessoryType: .none,
            ))
            section.add(OWSTableItem(
                text: OWSLocalizedString("TELLOMI_FEED_RETRY", comment: "Feed: retry button."),
                textColor: UIColor.Signal.accent,
                actionBlock: { [weak self] in self?.store.load() },
                accessoryType: .none,
            ))
            contents.add(section)
        case .content:
            guard let preferences = state.preferences, let interests = state.interests else { break }
            addPersonalization(state, to: contents)
            addRecentTopics(preferences, to: contents)
            addContentPreferences(state, preferences, to: contents)
            addInterests(interests, to: contents)
            addKeywords(state, to: contents)
            addPauseAndReset(state, preferences, to: contents)
        }
        self.contents = contents
    }

    private func addPersonalization(_ state: FeedRecommendationSettingsState, to contents: OWSTableContents) {
        guard let row = P.personalization(state) else { return }
        let section = OWSTableSection()
        switch row {
        case .toggle(let on):
            section.add(OWSTableItem.switch(
                withText: Self.personalizedTitle,
                subtitle: OWSLocalizedString("TELLOMI_FEED_SETTINGS_PERSONALIZED_DESCRIPTION", comment: "Feed settings: explains what the personalized recommendations switch does."),
                isOn: { on },
                actionBlock: { [weak self] uiSwitch in self?.store.setPersonalized(uiSwitch.isOn) },
            ))
        case .editorialNote:
            section.add(Self.noteItem(OWSLocalizedString("TELLOMI_FEED_SETTINGS_EDITORIAL_NOTE", comment: "Feed settings: says recommendations right now are editors' picks in time order, not based on interests.")))
        }
        contents.add(section)
    }

    private func addRecentTopics(_ preferences: FeedPreferences, to contents: OWSTableContents) {
        let rows = P.recentTopics(preferences)
        guard !rows.isEmpty else { return }
        let section = OWSTableSection()
        section.headerTitle = OWSLocalizedString("TELLOMI_FEED_SETTINGS_RECENT", comment: "Feed settings: header of the share of topics in what you viewed in the last 30 days.")
        for row in rows {
            section.add(OWSTableItem(customCellBlock: {
                Self.recentTopicCell(name: Self.name(of: row.label), share: row.share, percent: row.percent)
            }))
        }
        contents.add(section)
    }

    private func addContentPreferences(_ state: FeedRecommendationSettingsState, _ preferences: FeedPreferences, to contents: OWSTableContents) {
        let style = OWSTableSection()
        style.headerTitle = OWSLocalizedString("TELLOMI_FEED_SETTINGS_STYLE", comment: "Feed settings: header of the recommendation style choice (keep it as it is / explore more).")
        for value in FeedPreferences.styles {
            style.add(Self.choiceItem(
                text: Self.styleTitle(value),
                selected: preferences.style == value,
                action: { [weak self] in self?.store.setStyle(value) },
            ))
        }
        contents.add(style)

        let sensitive = OWSTableSection()
        sensitive.headerTitle = OWSLocalizedString("TELLOMI_FEED_SETTINGS_SENSITIVE", comment: "Feed settings: header of the sensitive content choice (less / standard / more).")
        for value in state.sensitiveChoices {
            sensitive.add(Self.choiceItem(
                text: Self.sensitiveTitle(FeedSensitiveChoice(value: value)),
                selected: preferences.sensitive == value,
                action: { [weak self] in self?.store.setSensitive(value) },
            ))
        }
        contents.add(sensitive)

        let categories = OWSTableSection()
        let adjusted = P.adjustedCategoryCount(preferences)
        let hint: String = adjusted > 0
            ? String(format: OWSLocalizedString("TELLOMI_FEED_SETTINGS_CATEGORIES_ADJUSTED", comment: "Feed settings: subtitle of 'adjust by category' when some are adjusted. Embeds {{number of adjusted categories}}."), OWSFormat.formatInt(adjusted))
            : OWSLocalizedString("TELLOMI_FEED_SETTINGS_CATEGORIES_HINT", comment: "Feed settings: subtitle of 'adjust by category' when none is adjusted.")
        categories.add(Self.textRow(
            title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_CATEGORIES", comment: "Feed settings: row that opens the per-category more/less choices."),
            subtitle: hint,
            accessoryType: categoriesOpen ? .none : .disclosureIndicator,
            action: { [weak self] in self?.toggleCategories() },
        ))
        if categoriesOpen {
            for row in P.categoryRows(preferences) {
                categories.add(OWSTableItem(customCellBlock: { [weak self] in
                    Self.categoryCell(name: Self.name(of: .topic(row.slug)), choice: row.choice) { choice in
                        self?.store.setCategory(slug: row.slug.rawValue, value: choice.apiValue)
                    }
                }))
            }
        }
        contents.add(categories)
    }

    private func addInterests(_ interests: FeedInterests, to contents: OWSTableContents) {
        let header = OWSTableSection()
        header.headerTitle = OWSLocalizedString("TELLOMI_FEED_SETTINGS_INTERESTS", comment: "Feed settings: header of the interest tags.")
        header.add(Self.noteItem(OWSLocalizedString("TELLOMI_FEED_SETTINGS_INTERESTS_DESCRIPTION", comment: "Feed settings: says interest tags are worked out from what you view and like, only you can see them, deleted tags are not used again.")))
        let sections = P.interestSections(interests)
        if sections.isEmpty {
            header.add(Self.noteItem(OWSLocalizedString("TELLOMI_FEED_SETTINGS_INTERESTS_EMPTY", comment: "Feed settings: shown when there are no interest tags yet.")))
        }
        contents.add(header)
        for group in sections {
            let section = OWSTableSection()
            switch group.kind {
            case .topics:
                section.headerTitle = OWSLocalizedString("TELLOMI_FEED_SETTINGS_TOPICS", comment: "Feed settings: group of interest tags that are topics.")
            case .authors:
                section.headerTitle = OWSLocalizedString("TELLOMI_FEED_SETTINGS_AUTHORS", comment: "Feed settings: group of interest tags that are people.")
            case .sources:
                section.headerTitle = OWSLocalizedString("TELLOMI_FEED_SETTINGS_SOURCES", comment: "Feed settings: group of interest tags that are sources.")
            }
            for row in group.rows {
                section.add(Self.textRow(
                    title: Self.name(of: row.label),
                    deleteAction: { [weak self] in self?.store.deleteInterest(dimension: row.dimension, interest: row.interest) },
                ))
            }
            contents.add(section)
        }
    }

    private func addKeywords(_ state: FeedRecommendationSettingsState, to contents: OWSTableContents) {
        let section = OWSTableSection()
        section.headerTitle = OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_TITLE", comment: "Feed settings: header of the muted words.")
        section.footerTitle = OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_DESCRIPTION", comment: "Feed settings: explains 'show less' (saved to the account) and 'hide completely' (this phone only) for muted words.")
        for row in P.keywordRows(state.keywords, now: now()) {
            section.add(Self.textRow(
                title: row.keyword,
                subtitle: Self.keywordSubtitle(row),
                deleteAction: { [weak self] in self?.store.removeKeyword(row.source) },
            ))
        }
        section.add(Self.textRow(
            title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_ADD", comment: "Feed settings: row that opens the form to add a muted word."),
            titleColor: UIColor.Signal.accent,
            action: { [weak self] in self?.presentKeywordForm() },
        ))
        contents.add(section)
    }

    private func addPauseAndReset(_ state: FeedRecommendationSettingsState, _ preferences: FeedPreferences, to contents: OWSTableContents) {
        let section = OWSTableSection()
        switch P.pause(preferences, now: now()) {
        case .paused(let until):
            section.add(Self.textRow(
                title: String(format: OWSLocalizedString("TELLOMI_FEED_SETTINGS_PAUSED", comment: "Feed settings: recommendations are paused. Embeds {{the date they resume}}."), Self.dateText(until)),
                subtitle: OWSLocalizedString("TELLOMI_FEED_SETTINGS_RESUME", comment: "Feed settings: tap to resume paused recommendations."),
                action: { [weak self] in self?.store.resume() },
            ))
        case .notPaused:
            section.add(Self.textRow(
                title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_PAUSE", comment: "Feed settings: row that pauses recommendations for 30 days."),
                subtitle: OWSLocalizedString("TELLOMI_FEED_SETTINGS_PAUSE_DESCRIPTION", comment: "Feed settings: says recommendations won't use your interests while paused."),
                action: { [weak self] in self?.presentPauseConfirmation() },
            ))
        }
        let busy = state.resetting
        let resetAction: (() -> Void)? = busy ? nil : { [weak self] in self?.presentResetConfirmation() }
        section.add(Self.textRow(
            title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_RESET", comment: "Feed settings: row that resets recommendations."),
            subtitle: OWSLocalizedString("TELLOMI_FEED_SETTINGS_RESET_DESCRIPTION", comment: "Feed settings: says resetting clears your interest tags and starts over."),
            titleColor: busy ? UIColor.Signal.secondaryLabel : UIColor.Signal.red,
            action: resetAction,
        ))
        contents.add(section)
    }

    // MARK: - Actions

    func toggleCategories() {
        categoriesOpen.toggle()
        apply(store.state)
    }

    /// 暂停推荐 30 天：先确认（单测 / 截图直接调它）。
    func presentPauseConfirmation() {
        let alert = UIAlertController(
            title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_PAUSE_TITLE", comment: "Feed settings: title of the confirmation before pausing recommendations."),
            message: OWSLocalizedString("TELLOMI_FEED_SETTINGS_PAUSE_BODY", comment: "Feed settings: says for 30 days recommendations won't use your interests, you can resume anytime."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: CommonStrings.cancelButton, style: .cancel))
        alert.addAction(UIAlertAction(title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_PAUSE_CONFIRM", comment: "Feed settings: button that pauses recommendations."), style: .default) { [weak self] _ in
            self?.store.pause()
        })
        lastAlert = alert
        present(alert, animated: true)
    }

    /// 重置推荐：确认两次（第一次「继续」，第二次「重置」）才发请求（单测 / 截图直接调它）。
    func presentResetConfirmation() {
        guard !store.state.resetting else { return }
        let alert = UIAlertController(
            title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_RESET_TITLE", comment: "Feed settings: title of the first confirmation before resetting recommendations."),
            message: OWSLocalizedString("TELLOMI_FEED_SETTINGS_RESET_BODY", comment: "Feed settings: says your interest tags will be cleared and recommendations start learning again."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: CommonStrings.cancelButton, style: .cancel))
        alert.addAction(UIAlertAction(title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_CONTINUE", comment: "Feed settings: button that goes on to the second reset confirmation."), style: .default) { [weak self] _ in
            self?.presentSecondResetConfirmation()
        })
        lastAlert = alert
        present(alert, animated: true)
    }

    func presentSecondResetConfirmation() {
        let alert = UIAlertController(
            title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_RESET_CONFIRM_TITLE", comment: "Feed settings: title of the second confirmation before resetting recommendations."),
            message: OWSLocalizedString("TELLOMI_FEED_SETTINGS_RESET_CONFIRM_BODY", comment: "Feed settings: says resetting can't be undone."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: CommonStrings.cancelButton, style: .cancel))
        alert.addAction(UIAlertAction(title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_RESET", comment: "Feed settings: row that resets recommendations."), style: .destructive) { [weak self] _ in
            self?.store.reset()
        })
        lastAlert = alert
        present(alert, animated: true)
    }

    /// 加关键词：推一个表单（词、少推荐 / 完全屏蔽、永久 / 30 天 / 7 天），点「新增」才存（单测 / 截图直接调它）。
    func presentKeywordForm() {
        let form = FeedKeywordFormViewController()
        form.onSubmit = { [weak self] submitted in self?.keywordFormSubmitted(submitted) }
        let navigation = OWSNavigationController(rootViewController: form)
        present(navigation, animated: true)
    }

    /// 表单里点了「新增」（单测直接调它）。
    func keywordFormSubmitted(_ form: FeedKeywordForm) {
        guard form.valid else { return }
        dismiss(animated: true)
        store.addKeyword(form.trimmed, mode: form.mode, days: form.days)
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
        guard let toast = P.toast(store.state) else { return }
        lastToastText = Self.toastText(for: toast)
        if let text = lastToastText, viewIfLoaded?.window != nil { presentToast(text: text) }
        store.onNoticeShown()
    }

    // MARK: - Cells

    /// 一行说明文字（灰色、不能点）。
    private static func noteItem(_ text: String) -> OWSTableItem {
        return OWSTableItem(text: text, textColor: UIColor.Signal.secondaryLabel, actionBlock: nil, accessoryType: .none)
    }

    /// 单选的一行：选中的有对勾。
    private static func choiceItem(text: String, selected: Bool, action: @escaping () -> Void) -> OWSTableItem {
        return FeedChoiceRow.item(text: text, selected: selected, action: action)
    }

    /// 标题（+ 小字）一行；`deleteAction` 非空时右边有个叉，点它删掉这一行。
    private static func textRow(
        title: String,
        subtitle: String? = nil,
        titleColor: UIColor = UIColor.Signal.label,
        accessoryType: UITableViewCell.AccessoryType = .none,
        action: (() -> Void)? = nil,
        deleteAction: (() -> Void)? = nil,
    ) -> OWSTableItem {
        return OWSTableItem(
            customCellBlock: {
                let cell = OWSTableItem.newCell()
                let titleLabel = UILabel()
                titleLabel.text = title
                titleLabel.font = .dynamicTypeBody
                titleLabel.textColor = titleColor
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
                let stack = UIStackView(arrangedSubviews: labels)
                stack.axis = .vertical
                stack.spacing = 2
                cell.contentView.addSubview(stack)
                stack.autoPinEdgesToSuperviewMargins()
                cell.accessoryType = accessoryType
                if let deleteAction {
                    let button = UIButton(type: .system)
                    button.setImage(UIImage(systemName: "xmark"), for: .normal)
                    button.tintColor = UIColor.Signal.secondaryLabel
                    button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
                    button.accessibilityLabel = Self.deleteTitle
                    button.addAction(UIAction { _ in deleteAction() }, for: .touchUpInside)
                    cell.accessoryView = button
                }
                if action == nil { cell.selectionStyle = .none }
                return cell
            },
            actionBlock: action,
        )
    }

    /// 最近看的内容里一个话题：名字 + 比例条 + 百分比。
    private static func recentTopicCell(name: String, share: Double, percent: Int) -> UITableViewCell {
        let cell = OWSTableItem.newCell()
        cell.selectionStyle = .none
        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .dynamicTypeBody
        nameLabel.textColor = UIColor.Signal.label
        nameLabel.numberOfLines = 0
        nameLabel.setCompressionResistanceHigh()
        let bar = UIProgressView(progressViewStyle: .default)
        bar.progress = Float(share)
        let percentLabel = UILabel()
        percentLabel.text = String(format: "%@%%", OWSFormat.formatInt(percent))
        percentLabel.font = .dynamicTypeSubheadline
        percentLabel.textColor = UIColor.Signal.secondaryLabel
        percentLabel.textAlignment = .right
        percentLabel.setCompressionResistanceHigh()
        let row = UIStackView(arrangedSubviews: [nameLabel, bar, percentLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        cell.contentView.addSubview(row)
        row.autoPinEdgesToSuperviewMargins()
        nameLabel.autoSetDimension(.width, toSize: 120, relation: .greaterThanOrEqual)
        return cell
    }

    /// 一个类别：名字 + 「减少 / 默认 / 增加」三段。
    private static func categoryCell(name: String, choice: FeedCategoryChoice, onChange: @escaping (FeedCategoryChoice) -> Void) -> UITableViewCell {
        let cell = OWSTableItem.newCell()
        cell.selectionStyle = .none
        let nameLabel = UILabel()
        nameLabel.text = name
        nameLabel.font = .dynamicTypeBody
        nameLabel.textColor = UIColor.Signal.label
        nameLabel.numberOfLines = 0
        let choices = FeedCategoryChoice.allCases
        let control = UISegmentedControl(items: choices.map { categoryTitle($0) })
        control.selectedSegmentIndex = choices.firstIndex(of: choice) ?? 1
        control.installFeedDynamicType()
        control.addAction(UIAction { [weak control] _ in
            guard let control, choices.indices.contains(control.selectedSegmentIndex) else { return }
            onChange(choices[control.selectedSegmentIndex])
        }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [nameLabel, control])
        stack.axis = .vertical
        stack.spacing = 8
        cell.contentView.addSubview(stack)
        stack.autoPinEdgesToSuperviewMargins()
        return cell
    }

    // MARK: - Texts

    static var title: String {
        return OWSLocalizedString("TELLOMI_FEED_SETTINGS_TITLE", comment: "Feed settings: page title, also the accessibility label of the button that opens it.")
    }

    static var loadFailedText: String {
        return OWSLocalizedString("TELLOMI_FEED_SETTINGS_LOAD_FAILED", comment: "Feed settings: shown when the settings could not be loaded.")
    }

    static var personalizedTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_SETTINGS_PERSONALIZED", comment: "Feed settings: switch for personalized recommendations.")
    }

    static var deleteTitle: String {
        return OWSLocalizedString("TELLOMI_FEED_SETTINGS_DELETE", comment: "Feed settings: accessibility label of the cross that deletes an interest tag or a muted word.")
    }

    static func styleTitle(_ value: String) -> String {
        switch value {
        case FeedPreferences.styleExplore:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_STYLE_EXPLORE", comment: "Feed settings: recommendation style, explore more.")
        default:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_STYLE_KEEP", comment: "Feed settings: recommendation style, keep it as it is.")
        }
    }

    static func sensitiveTitle(_ choice: FeedSensitiveChoice) -> String {
        switch choice {
        case .reduce:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_SENSITIVE_REDUCE", comment: "Feed settings: sensitive content, less.")
        case .standard:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_SENSITIVE_STANDARD", comment: "Feed settings: sensitive content, standard.")
        case .more:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_SENSITIVE_MORE", comment: "Feed settings: sensitive content, more (outside the mainland only).")
        }
    }

    static func categoryTitle(_ choice: FeedCategoryChoice) -> String {
        switch choice {
        case .reduce:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_CATEGORY_REDUCE", comment: "Feed settings: see less of a category.")
        case .default:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_CATEGORY_DEFAULT", comment: "Feed settings: default amount of a category.")
        case .increase:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_CATEGORY_INCREASE", comment: "Feed settings: see more of a category.")
        }
    }

    static func name(of label: FeedSettingsLabel) -> String {
        switch label {
        case .text(let text): return text
        case .topic(let slug): return topicName(slug)
        }
    }

    /// 「少推荐 / 完全屏蔽 · 永久 / 到哪天」。
    static func keywordSubtitle(_ row: FeedSettingsPresentation.KeywordRow) -> String {
        let mode: String
        switch row.mode {
        case .block:
            mode = OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_BLOCK", comment: "Feed settings: muted word mode, hide completely (this phone only).")
        case .downrank:
            mode = OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_DOWNRANK", comment: "Feed settings: muted word mode, show less.")
        }
        let until: String
        if let date = row.expiresAt {
            until = String(format: OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_UNTIL", comment: "Feed settings: a muted word lasts until {{a date}}."), dateText(date))
        } else {
            until = OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_FOREVER", comment: "Feed settings: a muted word lasts forever.")
        }
        return mode + " · " + until
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func toastText(for toast: FeedSettingsPresentation.Toast) -> String {
        switch toast {
        case .reset:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_RESET_DONE", comment: "Feed settings: toast after recommendations were reset.")
        case .invalidKeyword:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_INVALID", comment: "Feed settings: a muted word must be 1 to 20 characters.")
        case .tooManyKeywords:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_TOO_MANY", comment: "Feed settings: you can add up to 100 muted words.")
        case .actionFailed:
            return OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed.")
        case .throttled(let seconds):
            return FeedProfileViewController.throttledText(seconds)
        }
    }

    static func topicName(_ slug: FeedTopicSlug) -> String {
        switch slug {
        case .ai:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_AI", comment: "Feed settings: name of the topic category 'ai' (interest tags, recent views, adjust by category).")
        case .tech:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_TECH", comment: "Feed settings: name of the topic category 'tech' (interest tags, recent views, adjust by category).")
        case .dev:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_DEV", comment: "Feed settings: name of the topic category 'dev' (interest tags, recent views, adjust by category).")
        case .games:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_GAMES", comment: "Feed settings: name of the topic category 'games' (interest tags, recent views, adjust by category).")
        case .anime:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_ANIME", comment: "Feed settings: name of the topic category 'anime' (interest tags, recent views, adjust by category).")
        case .film:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_FILM", comment: "Feed settings: name of the topic category 'film' (interest tags, recent views, adjust by category).")
        case .music:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_MUSIC", comment: "Feed settings: name of the topic category 'music' (interest tags, recent views, adjust by category).")
        case .books:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_BOOKS", comment: "Feed settings: name of the topic category 'books' (interest tags, recent views, adjust by category).")
        case .photo:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_PHOTO", comment: "Feed settings: name of the topic category 'photo' (interest tags, recent views, adjust by category).")
        case .design:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_DESIGN", comment: "Feed settings: name of the topic category 'design' (interest tags, recent views, adjust by category).")
        case .food:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_FOOD", comment: "Feed settings: name of the topic category 'food' (interest tags, recent views, adjust by category).")
        case .baking:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_BAKING", comment: "Feed settings: name of the topic category 'baking' (interest tags, recent views, adjust by category).")
        case .explore:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_EXPLORE", comment: "Feed settings: name of the topic category 'explore' (interest tags, recent views, adjust by category).")
        case .travel:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_TRAVEL", comment: "Feed settings: name of the topic category 'travel' (interest tags, recent views, adjust by category).")
        case .camping:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_CAMPING", comment: "Feed settings: name of the topic category 'camping' (interest tags, recent views, adjust by category).")
        case .fitness:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_FITNESS", comment: "Feed settings: name of the topic category 'fitness' (interest tags, recent views, adjust by category).")
        case .running:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_RUNNING", comment: "Feed settings: name of the topic category 'running' (interest tags, recent views, adjust by category).")
        case .ballsports:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_BALLSPORTS", comment: "Feed settings: name of the topic category 'ballsports' (interest tags, recent views, adjust by category).")
        case .fashion:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_FASHION", comment: "Feed settings: name of the topic category 'fashion' (interest tags, recent views, adjust by category).")
        case .beauty:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_BEAUTY", comment: "Feed settings: name of the topic category 'beauty' (interest tags, recent views, adjust by category).")
        case .portrait:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_PORTRAIT", comment: "Feed settings: name of the topic category 'portrait' (interest tags, recent views, adjust by category).")
        case .pets:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_PETS", comment: "Feed settings: name of the topic category 'pets' (interest tags, recent views, adjust by category).")
        case .home:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_HOME", comment: "Feed settings: name of the topic category 'home' (interest tags, recent views, adjust by category).")
        case .parenting:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_PARENTING", comment: "Feed settings: name of the topic category 'parenting' (interest tags, recent views, adjust by category).")
        case .work:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_WORK", comment: "Feed settings: name of the topic category 'work' (interest tags, recent views, adjust by category).")
        case .frugal:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_FRUGAL", comment: "Feed settings: name of the topic category 'frugal' (interest tags, recent views, adjust by category).")
        case .cars:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_CARS", comment: "Feed settings: name of the topic category 'cars' (interest tags, recent views, adjust by category).")
        case .science:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_SCIENCE", comment: "Feed settings: name of the topic category 'science' (interest tags, recent views, adjust by category).")
        case .health:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_HEALTH", comment: "Feed settings: name of the topic category 'health' (interest tags, recent views, adjust by category).")
        case .mood:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_MOOD", comment: "Feed settings: name of the topic category 'mood' (interest tags, recent views, adjust by category).")
        case .funny:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_FUNNY", comment: "Feed settings: name of the topic category 'funny' (interest tags, recent views, adjust by category).")
        case .diy:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_DIY", comment: "Feed settings: name of the topic category 'diy' (interest tags, recent views, adjust by category).")
        case .plants:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_PLANTS", comment: "Feed settings: name of the topic category 'plants' (interest tags, recent views, adjust by category).")
        case .city:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_CITY", comment: "Feed settings: name of the topic category 'city' (interest tags, recent views, adjust by category).")
        case .campus:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_CAMPUS", comment: "Feed settings: name of the topic category 'campus' (interest tags, recent views, adjust by category).")
        case .news:
            return OWSLocalizedString("TELLOMI_FEED_TOPIC_NAME_NEWS", comment: "Feed settings: name of the topic category 'news' (interest tags, recent views, adjust by category).")
        }
    }
}
