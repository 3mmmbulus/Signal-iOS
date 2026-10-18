//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import PhotosUI
import SignalServiceKit
import SignalUI
import UIKit

/// 举报页（`dynamic-feed.md` 第三节第 32 条）。从详情页帖子或评论的「···」里进来，包在导航控制器里弹出。
/// 两步：先选原因（四组），再补充说明 / 关系 / 截图并提交。逻辑在 `FeedReportStore`，画什么在 `FeedReportPresentation`，
/// 这里只负责把它们画出来、把操作转给 store。
///
/// 提交成功就关掉并告诉详情页（`.sent`，详情页提示「已提交」）；引擎说这个区域的动态关了（`feed_hidden`）
/// 也关掉并告诉详情页（`.feedHidden`，详情页跟着收起）。其它错误提示一句，表单留着让用户再点。
final class FeedReportViewController: OWSViewController {

    enum Outcome: Equatable {
        case sent
        case feedHidden
        case cancelled
    }

    static let thumbnailSize: CGFloat = 80

    let store: FeedReportStore
    private let onFinished: (Outcome) -> Void

    private(set) var presentation: FeedReportPresentation
    private(set) var lastToastText: String?
    private(set) var finishedOutcome: Outcome?

    let reasonsTable = UITableView(frame: .zero, style: .insetGrouped)
    let formScroll = UIScrollView()
    private let reasonTitleLabel = UILabel()
    private let emergencyLabel = UILabel()
    let detailTextView = UITextView()
    private var detailHeightConstraint: NSLayoutConstraint?
    private var lastDetailWidth: CGFloat = 0
    private let detailPlaceholder = UILabel()
    let detailCounterLabel = UILabel()
    let relationshipField = UITextField()
    private let evidenceTitleLabel = UILabel()
    private let evidenceScroll = UIScrollView()
    let evidenceRow = UIStackView()
    private let hotlineLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    lazy var submitButton = UIBarButtonItem.prominentButton(
        title: OWSLocalizedString("TELLOMI_FEED_REPORT_SUBMIT", comment: "Feed report page: the button that submits the report."),
        action: { [weak self] in self?.submit() },
    )

    init(store: FeedReportStore, onFinished: @escaping (Outcome) -> Void) {
        self.store = store
        self.onFinished = onFinished
        self.presentation = FeedReportPresentation(state: store.state)
        super.init()
        title = OWSLocalizedString("TELLOMI_FEED_REPORT_TITLE", comment: "Feed report page: title.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Signal.groupedBackground
        buildReasons()
        buildForm()
        store.onChange = { [weak self] _ in self?.storeChanged() }
        render()
    }

    // MARK: - Layout

    private func buildReasons() {
        reasonsTable.dataSource = self
        reasonsTable.delegate = self
        reasonsTable.backgroundColor = .clear
        reasonsTable.register(UITableViewCell.self, forCellReuseIdentifier: "reason")
        view.addSubview(reasonsTable)
        reasonsTable.autoPinEdgesToSuperviewEdges()
    }

    private func buildForm() {
        reasonTitleLabel.font = .dynamicTypeTitle3.semibold()
        reasonTitleLabel.textColor = UIColor.Signal.label
        reasonTitleLabel.numberOfLines = 0

        emergencyLabel.font = .dynamicTypeSubheadline
        emergencyLabel.textColor = UIColor.Signal.red
        emergencyLabel.numberOfLines = 0
        emergencyLabel.text = OWSLocalizedString("TELLOMI_FEED_REPORT_EMERGENCY", comment: "Feed report page: shown first for reasons about someone's safety; tells the user to call the emergency number if someone is in danger.")

        detailTextView.font = .dynamicTypeBody
        detailTextView.textColor = UIColor.Signal.label
        detailTextView.backgroundColor = UIColor.Signal.secondaryGroupedBackground
        detailTextView.layer.cornerRadius = 10
        detailTextView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        detailTextView.isScrollEnabled = false
        detailTextView.delegate = self
        detailHeightConstraint = detailTextView.autoSetDimension(.height, toSize: FeedReportPresentation.detailMinHeight)

        detailPlaceholder.font = .dynamicTypeBody
        detailPlaceholder.textColor = UIColor.Signal.tertiaryLabel
        detailPlaceholder.numberOfLines = 0
        detailPlaceholder.text = OWSLocalizedString("TELLOMI_FEED_REPORT_DETAIL_PLACEHOLDER", comment: "Feed report page: placeholder of the optional details box.")
        detailPlaceholder.isUserInteractionEnabled = false
        detailTextView.addSubview(detailPlaceholder)
        detailPlaceholder.autoPinEdge(toSuperviewEdge: .top, withInset: 12)
        detailPlaceholder.autoPinEdge(toSuperviewEdge: .leading, withInset: 17)
        detailPlaceholder.autoMatch(.width, to: .width, of: detailTextView, withOffset: -34)

        detailCounterLabel.font = .dynamicTypeSubheadlineClamped.monospaced()
        detailCounterLabel.textAlignment = .right
        detailCounterLabel.textColor = UIColor.Signal.secondaryLabel

        relationshipField.font = .dynamicTypeBody
        relationshipField.textColor = UIColor.Signal.label
        relationshipField.backgroundColor = UIColor.Signal.secondaryGroupedBackground
        relationshipField.layer.cornerRadius = 10
        relationshipField.placeholder = OWSLocalizedString("TELLOMI_FEED_REPORT_RELATIONSHIP_PLACEHOLDER", comment: "Feed report page: placeholder of the box for the user's relationship to the person whose rights were violated.")
        relationshipField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        relationshipField.leftViewMode = .always
        relationshipField.autoSetDimension(.height, toSize: 44)
        relationshipField.addAction(UIAction { [weak self] _ in self?.relationshipChanged() }, for: .editingChanged)

        evidenceTitleLabel.font = .dynamicTypeSubheadlineClamped.semibold()
        evidenceTitleLabel.textColor = UIColor.Signal.secondaryLabel
        evidenceTitleLabel.text = OWSLocalizedString("TELLOMI_FEED_REPORT_EVIDENCE_TITLE", comment: "Feed report page: title above the screenshots the user must attach for some reasons.")

        evidenceRow.axis = .horizontal
        evidenceRow.spacing = 8
        evidenceScroll.showsHorizontalScrollIndicator = false
        evidenceScroll.addSubview(evidenceRow)
        evidenceRow.autoPinEdgesToSuperviewEdges()
        evidenceRow.autoMatch(.height, to: .height, of: evidenceScroll)
        evidenceScroll.autoSetDimension(.height, toSize: Self.thumbnailSize)

        hotlineLabel.font = .dynamicTypeFootnote
        hotlineLabel.textColor = UIColor.Signal.secondaryLabel
        hotlineLabel.numberOfLines = 0
        hotlineLabel.text = OWSLocalizedString("TELLOMI_FEED_REPORT_HOTLINE", comment: "Feed report page: for users in mainland China, a pointer to the national reporting website 12377.cn.")

        let counterRow = UIStackView(arrangedSubviews: [UIView.hStretchingSpacer(), detailCounterLabel])
        let column = UIStackView(arrangedSubviews: [
            reasonTitleLabel, emergencyLabel, detailTextView, counterRow, relationshipField,
            evidenceTitleLabel, evidenceScroll, hotlineLabel,
        ])
        column.axis = .vertical
        column.spacing = 12
        column.setCustomSpacing(4, after: detailTextView)
        formScroll.keyboardDismissMode = .interactive
        formScroll.alwaysBounceVertical = true
        formScroll.addSubview(column)
        column.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        column.autoMatch(.width, to: .width, of: formScroll, withOffset: -32)
        view.addSubview(formScroll)
        formScroll.autoPinEdge(toSuperviewSafeArea: .top)
        formScroll.autoPinEdge(toSuperviewEdge: .leading)
        formScroll.autoPinEdge(toSuperviewEdge: .trailing)
        formScroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
    }

    // MARK: - Rendering

    private func storeChanged() {
        let previous = presentation
        presentation = FeedReportPresentation(state: store.state)
        render()
        if presentation.isSent, !previous.isSent {
            finish(.sent)
        } else if let error = presentation.error {
            show(error)
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        presentation = FeedReportPresentation(state: store.state)
        let inForm = presentation.phase == .form
        reasonsTable.isHidden = inForm
        formScroll.isHidden = !inForm
        reasonsTable.reloadData()

        if inForm {
            navigationItem.leftBarButtonItem = .button(
                title: CommonStrings.backButton,
                action: { [weak self] in self?.store.backToReasons() },
            )
            navigationItem.rightBarButtonItem = submitButton
        } else {
            navigationItem.leftBarButtonItem = .cancelButton { [weak self] in self?.finish(.cancelled) }
            navigationItem.rightBarButtonItem = nil
        }
        submitButton.isEnabled = presentation.canSubmit
        if presentation.isSending {
            spinner.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        } else {
            spinner.stopAnimating()
        }

        reasonTitleLabel.text = presentation.reason.map { Self.reasonTitle($0) }
        emergencyLabel.isHidden = !presentation.showsEmergencyNotice
        relationshipField.isHidden = !presentation.showsRelationship
        evidenceTitleLabel.isHidden = !presentation.showsEvidence
        evidenceScroll.isHidden = !presentation.showsEvidence
        hotlineLabel.isHidden = !presentation.showsMainlandHotline
        detailTextView.isEditable = presentation.isEditable
        relationshipField.isEnabled = presentation.isEditable
        if detailTextView.text != store.state.detail, !detailTextView.isFirstResponder || detailTextView.markedTextRange == nil {
            detailTextView.text = store.state.detail
        }
        if relationshipField.text != store.state.relationship, relationshipField.markedTextRange == nil {
            relationshipField.text = store.state.relationship
        }
        detailPlaceholder.isHidden = !store.state.detail.isEmpty
        detailCounterLabel.text = OWSFormat.formatInt(presentation.detailRemaining)
        detailCounterLabel.textColor = presentation.counterIsRed ? UIColor.Signal.red : UIColor.Signal.secondaryLabel
        updateDetailHeight()
        renderEvidence()
    }

    /// 说明框随文字长高，到 `detailMaxHeight` 为止，再多在框里滚动（不然 500 字时计数和 12377 提示被推到屏幕外）。
    func updateDetailHeight() {
        let width = detailTextView.bounds.width > 0 ? detailTextView.bounds.width : max(view.bounds.width - 32, 100)
        let fitting = detailTextView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)).height
        let box = FeedReportPresentation.detailBoxHeight(fitting: fitting)
        detailTextView.isScrollEnabled = box.scrolls
        if detailHeightConstraint?.constant != box.height {
            detailHeightConstraint?.constant = box.height
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 宽度变了（转屏、分屏）说明框一行能放的字数变了，重新算高度
        if detailTextView.bounds.width != lastDetailWidth {
            lastDetailWidth = detailTextView.bounds.width
            updateDetailHeight()
        }
    }

    private func renderEvidence() {
        evidenceRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard presentation.showsEvidence else { return }
        for item in store.state.evidence {
            evidenceRow.addArrangedSubview(thumbnail(for: item))
        }
        if presentation.canAddEvidence {
            let add = UIButton(type: .system)
            add.backgroundColor = UIColor.Signal.secondaryFill
            add.layer.cornerRadius = 10
            add.setImage(UIImage(named: "plus"), for: .normal)
            add.tintColor = UIColor.Signal.secondaryLabel
            add.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_COMPOSE_ADD_IMAGES", comment: "Feed publish page: button that adds photos.")
            add.addAction(UIAction { [weak self] _ in self?.pickEvidence() }, for: .touchUpInside)
            add.autoSetDimensions(to: CGSize(square: Self.thumbnailSize))
            evidenceRow.addArrangedSubview(add)
        }
    }

    private func thumbnail(for item: FeedDraftImage) -> UIView {
        let imageView = UIImageView(image: item.image)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 10
        imageView.backgroundColor = UIColor.Signal.secondaryFill
        imageView.isUserInteractionEnabled = true
        imageView.autoSetDimensions(to: CGSize(square: Self.thumbnailSize))

        let remove = UIButton(type: .system)
        remove.setImage(UIImage(named: "x-compact"), for: .normal)
        remove.tintColor = .white
        remove.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        remove.layer.cornerRadius = 12
        remove.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_COMPOSE_REMOVE_IMAGE", comment: "Feed publish page: button on a photo that removes it.")
        remove.isEnabled = presentation.isEditable
        remove.addAction(UIAction { [weak self] _ in self?.store.removeEvidence(item) }, for: .touchUpInside)
        imageView.addSubview(remove)
        remove.autoSetDimensions(to: CGSize(square: 24))
        remove.autoPinEdge(toSuperviewEdge: .top, withInset: 4)
        remove.autoPinEdge(toSuperviewEdge: .trailing, withInset: 4)
        return imageView
    }

    // MARK: - Actions

    /// 选一个原因（点列表的一行）。单测 / 截图直接调它。
    func pick(_ reason: FeedReportReason) {
        store.pick(reason)
    }

    func submit() {
        guard presentation.canSubmit else { return }
        view.endEditing(true)
        store.submit()
    }

    private func relationshipChanged() {
        store.onRelationshipChanged(relationshipField.text ?? "")
    }

    private func pickEvidence() {
        guard presentation.canAddEvidence else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = max(1, FeedReportReason.maxEvidence - presentation.evidenceCount)
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func finish(_ outcome: Outcome) {
        guard finishedOutcome == nil else { return }
        finishedOutcome = outcome
        onFinished(outcome)
    }

    private func show(_ error: FeedReportState.ReportError) {
        store.onErrorShown()
        if error == .feedHidden {
            finish(.feedHidden)
            return
        }
        let text = Self.toastText(for: error)
        lastToastText = text
        presentToast(text: text)
    }

    static func toastText(for error: FeedReportState.ReportError) -> String {
        switch error {
        case .gone:
            return OWSLocalizedString("TELLOMI_FEED_REPORT_GONE", comment: "Feed report page: toast when the post or comment being reported no longer exists.")
        case .throttled(let seconds):
            return FeedPostDetailViewController.toastText(for: .throttled, retryAfterSeconds: seconds) ?? ""
        case .failed, .feedHidden:
            return OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: "Feed: toast when liking or another action on a post failed.")
        }
    }
}

// MARK: - Reasons list

extension FeedReportViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int {
        return presentation.groups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return presentation.groups[section].reasons.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return Self.groupTitle(presentation.groups[section])
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "reason", for: indexPath)
        let reason = presentation.groups[indexPath.section].reasons[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = Self.reasonTitle(reason)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.backgroundColor = UIColor.Signal.secondaryGroupedBackground
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        pick(presentation.groups[indexPath.section].reasons[indexPath.row])
    }

    /// 原因、分组的文案。键是 `FeedReportReasons` 拼出来的，所以这里按键查（缺键回落英文，英文也没有才显示键本身），
    /// 所以新加原因要同时加文案（`known` 里没有的原因不会显示，见 `FeedReportReasons.groups`）。
    static func reasonTitle(_ reason: FeedReportReason) -> String {
        return localized(reason.labelKey)
    }

    static func groupTitle(_ group: FeedReportGroup) -> String {
        return localized(group.labelKey)
    }

    private static func localized(_ key: String) -> String {
        return OWSLocalizedString(key, value: key, comment: "Feed report page: a reason or group name; the key is built from the reason code in FeedReportReasons.")
    }
}

extension FeedReportViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        guard textView === detailTextView else { return }
        // store 按码点截断；输入法组字中 `render` 不回写文字（见 `render`），免得打断组字
        store.onDetailChanged(textView.text ?? "")
    }
}

extension FeedReportViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let providers = results.map(\.itemProvider).filter { $0.canLoadObject(ofClass: UIImage.self) }
        guard !providers.isEmpty else { return }
        Task { [weak self] in
            var images = [FeedDraftImage]()
            for provider in providers {
                if let image = await Self.loadImage(provider) {
                    images.append(FeedDraftImage(image: image))
                }
            }
            self?.store.addEvidence(images)
        }
    }

    private static func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                continuation.resume(returning: object as? UIImage)
            }
        }
    }
}
