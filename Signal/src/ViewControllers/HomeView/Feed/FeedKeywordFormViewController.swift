//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 加屏蔽关键词的表单（Android `AddKeywordDialog`）：词（最多 20 个字）、少推荐（默认）/ 完全屏蔽、永久 / 30 天 / 7 天，点右上角「新增」才交出去。
/// 数据在 `FeedKeywordForm`（纯逻辑，码点计数在那里测）；由 `FeedRecommendationSettingsViewController` 模态推出。
final class FeedKeywordFormViewController: OWSTableViewController2 {

    private(set) var form = FeedKeywordForm()
    /// 点「新增」时调（表单当时是有效的）。
    var onSubmit: ((FeedKeywordForm) -> Void)?

    private(set) lazy var textField: UITextField = {
        let field = UITextField()
        field.placeholder = OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_HINT", comment: "Feed settings: placeholder of the muted word field.")
        field.font = .dynamicTypeBody
        field.textColor = UIColor.Signal.label
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.addAction(UIAction { [weak self] _ in self?.textChanged() }, for: .editingChanged)
        field.addAction(UIAction { [weak self] _ in self?.submit() }, for: .editingDidEndOnExit)
        return field
    }()

    /// 词的输入框只建一次：改选项重画表格时还是同一个，不丢输入。
    private lazy var textFieldCell: UITableViewCell = {
        let cell = OWSTableItem.newCell()
        cell.selectionStyle = .none
        cell.contentView.addSubview(textField)
        textField.autoPinEdgesToSuperviewMargins()
        textField.autoSetDimension(.height, toSize: 28, relation: .greaterThanOrEqual)
        return cell
    }()

    private(set) var addItem: UIBarButtonItem?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_ADD", comment: "Feed settings: row that opens the form to add a muted word.")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: CommonStrings.cancelButton,
            style: .plain,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) },
        )
        let add = UIBarButtonItem(
            title: OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_CONFIRM", comment: "Feed settings: button that adds the muted word."),
            style: .done,
            primaryAction: UIAction { [weak self] _ in self?.submit() },
        )
        add.isEnabled = form.valid
        navigationItem.rightBarButtonItem = add
        addItem = add
        updateTableContents()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textField.becomeFirstResponder()
    }

    override func themeDidChange() {
        super.themeDidChange()
        updateTableContents()
    }

    // MARK: - Form

    /// 输入框里的字变了（单测直接改 `textField.text` 再调它）。
    func textChanged() {
        form.text = textField.text ?? ""
        addItem?.isEnabled = form.valid
        textField.textColor = form.trimmed.isEmpty || form.valid ? UIColor.Signal.label : UIColor.Signal.red
    }

    func select(block: Bool) {
        form.block = block
        updateTableContents()
    }

    func select(days: Int) {
        guard FeedKeywordForm.dayChoices.contains(days) else { return }
        form.days = days
        updateTableContents()
    }

    func submit() {
        textChanged()
        guard form.valid else { return }
        onSubmit?(form)
    }

    private func updateTableContents() {
        let contents = OWSTableContents()

        let word = OWSTableSection()
        word.footerTitle = OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_INVALID", comment: "Feed settings: a muted word must be 1 to 20 characters.")
        word.add(OWSTableItem(customCellBlock: { [weak self] in self?.textFieldCell ?? UITableViewCell() }))
        contents.add(word)

        let mode = OWSTableSection()
        mode.add(OWSTableItem(
            text: OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_DOWNRANK", comment: "Feed settings: muted word mode, show less."),
            actionBlock: { [weak self] in self?.select(block: false) },
            accessoryType: form.block ? .none : .checkmark,
        ))
        mode.add(OWSTableItem(
            text: OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_BLOCK", comment: "Feed settings: muted word mode, hide completely (this phone only)."),
            actionBlock: { [weak self] in self?.select(block: true) },
            accessoryType: form.block ? .checkmark : .none,
        ))
        mode.footerTitle = form.block
            ? OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_BLOCK_DESCRIPTION", comment: "Feed settings: says matching posts never appear in your feed (this phone only).")
            : OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_DOWNRANK_DESCRIPTION", comment: "Feed settings: says matching posts are recommended less.")
        contents.add(mode)

        let duration = OWSTableSection()
        for days in FeedKeywordForm.dayChoices {
            duration.add(OWSTableItem(
                text: Self.daysTitle(days),
                actionBlock: { [weak self] in self?.select(days: days) },
                accessoryType: form.days == days ? .checkmark : .none,
            ))
        }
        contents.add(duration)

        self.contents = contents
    }

    static func daysTitle(_ days: Int) -> String {
        switch days {
        case 7:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_DAYS_7", comment: "Feed settings: a muted word lasts 7 days.")
        case 30:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_DAYS_30", comment: "Feed settings: a muted word lasts 30 days.")
        default:
            return OWSLocalizedString("TELLOMI_FEED_SETTINGS_KEYWORDS_FOREVER", comment: "Feed settings: a muted word lasts forever.")
        }
    }
}
