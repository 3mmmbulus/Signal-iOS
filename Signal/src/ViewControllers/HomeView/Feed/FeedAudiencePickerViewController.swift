//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 「只给谁看 / 不给谁看」的选人页（第三节第 39 条）。从发布页的可见范围菜单进来，多选、可搜索、最多 500 人。
/// 点「完成」把名单交回发布页（`FeedComposeStore.onAudiencePicked`）；取消不改任何东西。
/// 选谁、能不能选的规则都在 `FeedAudiencePickerStore`（有单测），这里只画。
final class FeedAudiencePickerViewController: OWSViewController {

    private let store: FeedAudiencePickerStore
    private let onDone: ([FeedAudienceMember]) -> Void
    private var rows = [FeedAudienceCandidate]()

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let hintLabel = UILabel()
    private let countLabel = UILabel()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let statusStack = UIStackView()
    private let searchController = UISearchController(searchResultsController: nil)
    private lazy var doneButton = UIBarButtonItem(
        title: CommonStrings.doneButton,
        style: .done,
        target: self,
        action: #selector(done),
    )

    init(
        visibility: FeedVisibility,
        preselected: [FeedAudienceMember],
        source: FeedAudienceCandidateSource,
        maxMembers: Int = FeedDraft.maxAudience,
        onDone: @escaping ([FeedAudienceMember]) -> Void,
    ) {
        store = FeedAudiencePickerStore(visibility: visibility, preselected: preselected, source: source, maxMembers: maxMembers)
        self.onDone = onDone
        super.init()
        store.onChange = { [weak self] state in self?.render(state) }
    }

    /// 单测直接按。
    func toggle(recipientId: Int64) {
        store.toggle(recipientId: recipientId)
    }

    var selectedCount: Int { store.state.selected.count }
    var candidateCount: Int { store.state.candidates.count }

    override func viewDidLoad() {
        super.viewDidLoad()
        tellomiApplyFeedPreviewPrompt()
        view.backgroundColor = UIColor.Signal.groupedBackground
        title = Self.title(for: store.state.visibility)
        navigationItem.leftBarButtonItem = .cancelButton(dismissingFrom: self)
        navigationItem.rightBarButtonItem = doneButton

        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = OWSLocalizedString("TELLOMI_FEED_AUDIENCE_SEARCH", comment: "Feed people picker: placeholder of the search field.")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        hintLabel.font = UIFont.dynamicTypeSubheadlineClamped
        hintLabel.textColor = UIColor.Signal.secondaryLabel
        hintLabel.numberOfLines = 0
        hintLabel.text = Self.hint(for: store.state.visibility)
        countLabel.font = UIFont.dynamicTypeFootnoteClamped
        countLabel.textColor = UIColor.Signal.secondaryLabel
        countLabel.numberOfLines = 0
        let header = UIStackView(arrangedSubviews: [hintLabel, countLabel])
        header.axis = .vertical
        header.spacing = 4
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 8, right: 16)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = UIColor.Signal.groupedBackground
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellIdentifier)

        statusLabel.font = UIFont.dynamicTypeBodyClamped
        statusLabel.textColor = UIColor.Signal.secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        var retryConfig = UIButton.Configuration.plain()
        retryConfig.title = CommonStrings.retryButton
        retryButton.configuration = retryConfig
        retryButton.addAction(UIAction { [weak self] _ in self?.store.load() }, for: .touchUpInside)
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 12
        [spinner, statusLabel, retryButton].forEach { statusStack.addArrangedSubview($0) }

        view.addSubview(header)
        view.addSubview(tableView)
        view.addSubview(statusStack)
        header.autoPinEdge(toSuperviewSafeArea: .top)
        header.autoPinEdge(toSuperviewSafeArea: .leading)
        header.autoPinEdge(toSuperviewSafeArea: .trailing)
        tableView.autoPinEdge(.top, to: .bottom, of: header)
        tableView.autoPinEdge(toSuperviewEdge: .leading)
        tableView.autoPinEdge(toSuperviewEdge: .trailing)
        tableView.autoPinEdge(toSuperviewEdge: .bottom)
        statusStack.autoHCenterInSuperview()
        statusStack.autoPinEdge(.top, to: .bottom, of: header, withOffset: 48)
        statusStack.autoPinEdge(toSuperviewMargin: .leading, relation: .greaterThanOrEqual)
        statusStack.autoPinEdge(toSuperviewMargin: .trailing, relation: .greaterThanOrEqual)

        render(store.state)
        store.load()
    }

    // MARK: - Texts

    static func title(for visibility: FeedVisibility) -> String {
        if visibility == .exclude {
            return OWSLocalizedString("TELLOMI_FEED_AUDIENCE_TITLE_EXCLUDE", comment: "Feed people picker: title when picking people who must not see the post.")
        }
        return OWSLocalizedString("TELLOMI_FEED_AUDIENCE_TITLE_INCLUDE", comment: "Feed people picker: title when picking the only people who can see the post.")
    }

    static func hint(for visibility: FeedVisibility) -> String {
        if visibility == .exclude {
            return OWSLocalizedString("TELLOMI_FEED_AUDIENCE_HINT_EXCLUDE", comment: "Feed people picker: explains that everyone except the picked people can see the post.")
        }
        return OWSLocalizedString("TELLOMI_FEED_AUDIENCE_HINT_INCLUDE", comment: "Feed people picker: explains that only the picked people can see the post.")
    }

    static func countText(selected: Int, maximum: Int) -> String {
        return String(
            format: OWSLocalizedString("TELLOMI_FEED_AUDIENCE_COUNT", comment: "Feed people picker: how many people are picked out of the maximum. Embeds {{number picked}} and {{maximum}}."),
            OWSFormat.formatInt(selected),
            OWSFormat.formatInt(maximum),
        )
    }

    static func limitText(_ maximum: Int) -> String {
        return String(
            format: OWSLocalizedString("TELLOMI_FEED_AUDIENCE_LIMIT", comment: "Feed people picker: toast when trying to pick more people than allowed. Embeds {{maximum}}."),
            OWSFormat.formatInt(maximum),
        )
    }

    // MARK: - Rendering

    private static let cellIdentifier = "FeedAudiencePickerCell"

    private func render(_ state: FeedAudiencePickerState) {
        guard isViewLoaded else { return }
        rows = store.visibleCandidates
        tableView.reloadData()
        countLabel.text = Self.countText(selected: state.selected.count, maximum: store.maximum)
        doneButton.isEnabled = store.canConfirm

        spinner.isHidden = !state.loading
        if state.loading { spinner.startAnimating() } else { spinner.stopAnimating() }
        retryButton.isHidden = !state.loadFailed
        let status: String?
        if state.loading {
            status = nil
        } else if state.loadFailed {
            status = OWSLocalizedString("TELLOMI_FEED_AUDIENCE_LOAD_FAILED", comment: "Feed people picker: the friend list could not be loaded.")
        } else if state.candidates.isEmpty {
            status = OWSLocalizedString("TELLOMI_FEED_AUDIENCE_EMPTY", comment: "Feed people picker: there is nobody to pick from.")
        } else if rows.isEmpty {
            status = OWSLocalizedString("TELLOMI_FEED_AUDIENCE_NO_MATCH", comment: "Feed people picker: nobody matches the search.")
        } else {
            status = nil
        }
        statusLabel.text = status
        statusLabel.isHidden = status == nil
        statusStack.isHidden = state.loading ? false : (status == nil)

        if state.limitHit {
            store.onLimitShown()
            presentToast(text: Self.limitText(store.maximum))
        }
    }

    @objc
    private func done() {
        guard store.canConfirm else { return }
        let members = store.result
        dismiss(animated: true) { [onDone] in
            onDone(members)
        }
    }
}

extension FeedAudiencePickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        guard let candidate = rows[safe: indexPath.row] else { return cell }
        var content = cell.defaultContentConfiguration()
        content.text = candidate.displayName
        content.textProperties.font = UIFont.dynamicTypeBody
        content.textProperties.color = UIColor.Signal.label
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.backgroundColor = UIColor.Signal.secondaryGroupedBackground
        let selected = store.isSelected(candidate.recipientId)
        cell.accessoryType = selected ? .checkmark : .none
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let candidate = rows[safe: indexPath.row] else { return }
        store.toggle(recipientId: candidate.recipientId)
    }
}

extension FeedAudiencePickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        store.setQuery(searchController.searchBar.text ?? "")
    }
}
