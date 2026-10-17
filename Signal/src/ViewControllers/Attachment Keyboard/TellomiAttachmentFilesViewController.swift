//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Tellomi（tellomi/tellomi#1121 F-6）：「最近发送的文件」里的一项——本机数据库里我发出的一个文件类附件，
/// 同一份内容只留最新的一次。
struct TellomiRecentFile: Hashable {
    /// 去重键：附件行号（同一份内容只有一行 `Attachment`，按它去重就是按内容去重）。
    let id: String
    let attachmentRowId: Int64
    /// 这一次是哪条消息带的（再发时从这条消息的附件引用里取原文件名等）。
    let messageRowId: Int64
    let fileName: String
    let byteCount: UInt64
    let sentAt: Date
    /// 本机还有这份文件（没被存储管理清掉），才能再发。
    let isOnDevice: Bool
}

/// Tellomi（#1121 F-6、F-10）：「文件」页的数据——只查本机（端到端加密，服务端没有明文，不能照 Telegram 去服务端查）。
protocol TellomiRecentFilesSource: AnyObject {
    /// 新的在前、按内容去重，最多 [limit] 条；后台读，主线程回调。
    func loadRecentFiles(limit: Int, completion: @escaping ([TellomiRecentFile]) -> Void)
}

protocol TellomiAttachmentFilesDelegate: AnyObject {
    func filesPageDidCancel(_ page: TellomiAttachmentFilesViewController)
    /// dock 里点了「文件」以外的格子（「相册」换回选图页；别的交给会话页）。
    func filesPage(_ page: TellomiAttachmentFilesViewController, didSelectDockItem item: TellomiAttachmentDockItem)
    /// 从系统文件选择器挑的（可多选，F-4）或扫描合成的 PDF（F-5）：立即发送，每个一条；超过上限的提示「文件太大」。
    func filesPage(_ page: TellomiAttachmentFilesViewController, sendFilesAt urls: [URL])
    /// 立即发送（F-7：点一行；F-8：多选后说明挂在最后一个），发完关掉 Sheet。
    func filesPage(_ page: TellomiAttachmentFilesViewController, send files: [TellomiRecentFile], messageBody: MessageBody?)
    /// 「从相册中选择」（F-3，tellomi/tellomi#1263）：会话页先收起 Sheet，再整屏推出相册网格（owner 2026-10-13 照 Telegram）。
    func filesPageDidSelectGallery(_ page: TellomiAttachmentFilesViewController)
}

/// Tellomi（tellomi/tellomi#1121，需求 `docs/product/specs/attachment-files-location.md` §二，照 Telegram iOS
/// `AttachmentFileController` / `AttachmentFileSearchItem` 的结构与交互，只读机制、一行没搬）：附件 Sheet 的「文件」页。
///
/// - 顶栏：左 ✕、中间「文件」、右 🔍（最近文件 > 10 条或加载中才有，F-10）。
/// - 一张卡三行（F-2）：从相册中选择（= 原图按文件发送，F-3：会话页收起 Sheet 后推出 [TellomiFilesGalleryViewController]）/ 从文件中选择 /
///   扫描文件（能扫描的设备才有）。
/// - 「最近发送的文件」（F-6）：加载中是骨架；一条都没有时是一句说明，上限读服务端配置（F-9）；点一行立即发送并关闭（F-7），
///   已不在本机的置灰、点了只提示；长按「选择」进多选（F-8），底栏换成「说明 + 发送」、藏 🔍。
/// - 搜索（F-10）：藏 dock、展开全屏、搜索框贴底；本机文件名、大小写与全半角不敏感、0.6 秒防抖；分组「我发送的文件」；
///   超过 4 条先显示 3 条 +「显示更多」；搜不到写「没有找到」（不照 Telegram 骨架一直闪的缺陷）。
final class TellomiAttachmentFilesViewController: UIViewController, TellomiAttachmentDockClient {

    enum Entry: Equatable {
        case gallery
        case files
        case scan
    }

    private enum Metrics {
        static let topBarHeight: CGFloat = 56
        static let roundButtonSize: CGFloat = 44
        static let recentLimit = 100
        static let searchDebounce: TimeInterval = 0.6
        static let searchCollapsedCount = 3
        static let searchCollapseThreshold = 4
        static let searchButtonThreshold = 10
        static let skeletonRows = 6
    }

    weak var delegate: TellomiAttachmentFilesDelegate?

    private let source: TellomiRecentFilesSource
    private let maxFileSizeText: String
    private let entries: [Entry]
    private let dockItems: [TellomiAttachmentDockItem]

    /// nil = 还在读。
    private(set) var files: [TellomiRecentFile]?
    /// 多选里勾的顺序（F-8）；nil = 不在多选。
    private var selection: [String]?
    /// 搜索框里的字（F-10）；nil = 不在搜索。
    private var searchQuery: String?
    private var searchResults: [TellomiRecentFile] = []
    private var showsAllResults = false
    private var searchWorkItem: DispatchWorkItem?

    init(
        source: TellomiRecentFilesSource,
        maxFileSizeText: String,
        canScan: Bool,
        dockItems: [TellomiAttachmentDockItem],
    ) {
        self.source = source
        self.maxFileSizeText = maxFileSizeText
        self.entries = canScan ? [.gallery, .files, .scan] : [.gallery, .files]
        self.dockItems = dockItems
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Views

    private let topBar = UIView()
    /// 搜索时顶栏收起（高度 0），结果从 Sheet 顶上开始，不留一截空白。
    private var topBarHeightConstraint: NSLayoutConstraint?

    private lazy var closeButton = Self.roundButton(icon: .buttonX, accessibilityLabel: CommonStrings.dismissButton) { [weak self] in
        self?.didTapClose()
    }

    private lazy var searchButton = Self.roundButton(icon: .buttonSearch, accessibilityLabel: CommonStrings.searchPlaceholder) { [weak self] in
        self?.beginSearch()
    }

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.dynamicTypeHeadlineClamped
        label.textColor = .Signal.label
        label.text = OWSLocalizedString("ALL_MEDIA_FILE_TYPE_FILES", comment: "Title of the files page in the attachment sheet.")
        return label
    }()

    private lazy var tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.keyboardDismissMode = .onDrag
        tableView.register(TellomiRecentFileCell.self, forCellReuseIdentifier: TellomiRecentFileCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.plainCellIdentifier)
        tableView.register(TellomiRecentFileSkeletonCell.self, forCellReuseIdentifier: TellomiRecentFileSkeletonCell.reuseIdentifier)
        return tableView
    }()

    private static let plainCellIdentifier = "plain"

    /// 在附件 Sheet 里时用 Sheet 那一条共用的 dock（2026-10-17 第二版）；单独打开时自己建一条。
    private var dock: TellomiAttachmentDock? { sharedAttachmentDock ?? ownDock }

    private lazy var ownDock: TellomiAttachmentDock? = {
        guard sharedAttachmentDock == nil, !dockItems.isEmpty else { return nil }
        let dock = TellomiAttachmentDock(items: dockItems, selectedItem: .file)
        dock.onSelect = { [weak self] item in self?.didSelectDockItem(item) }
        return dock
    }()

    // MARK: TellomiAttachmentDockClient

    var sharedAttachmentDock: TellomiAttachmentDock?
    var isActiveAttachmentPage = true
    var attachmentDockItem: TellomiAttachmentDockItem { .file }
    var wantsAttachmentDock: Bool { !isSelecting && !isSearching }

    func attachmentDockDidSelect(_ item: TellomiAttachmentDockItem) {
        didSelectDockItem(item)
    }

    private lazy var captionField: UITextField = {
        let field = UITextField()
        field.placeholder = OWSLocalizedString("IMAGE_PICKER_TELLOMI_CAPTION_PLACEHOLDER", comment: "Placeholder of the caption field in the photo picker's send bar.")
        field.font = .dynamicTypeBodyClamped
        field.returnKeyType = .default
        return field
    }()

    private lazy var sendButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.image = Theme.iconImage(.arrowUp)
        configuration.baseBackgroundColor = .Signal.accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.sendSelection() })
        button.accessibilityLabel = MessageStrings.sendButton
        return button
    }()

    private lazy var sendBarRow: UIStackView = {
        let capsule = UIView()
        capsule.backgroundColor = .Signal.secondaryFill
        capsule.layer.cornerRadius = 20
        capsule.addSubview(captionField)
        captionField.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(hMargin: 14, vMargin: 0))
        let row = UIStackView(arrangedSubviews: [capsule, sendButton])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        capsule.autoSetDimension(.height, toSize: 40)
        sendButton.autoSetDimensions(to: CGSize(square: 40))
        return row
    }()

    /// 底色铺到 Sheet 底（盖住 Home 条那一截，列表不从下面露出来），输入行跟着键盘走（同选图页）。
    private lazy var sendBar: UIView = Self.bottomBar(containing: sendBarRow)

    private lazy var searchField: UITextField = {
        let field = UITextField()
        field.placeholder = CommonStrings.searchPlaceholder
        field.font = .dynamicTypeBodyClamped
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .search
        field.leftView = UIImageView(image: Theme.iconImage(.buttonSearch).withTintColor(.Signal.secondaryLabel, renderingMode: .alwaysOriginal))
        field.leftViewMode = .always
        field.addTarget(self, action: #selector(searchTextChanged), for: .editingChanged)
        return field
    }()

    private lazy var searchCloseButton = Self.roundButton(icon: .buttonX, accessibilityLabel: CommonStrings.cancelButton) { [weak self] in
        self?.endSearch()
    }

    private lazy var searchBarRow: UIStackView = {
        let capsule = UIView()
        capsule.backgroundColor = .Signal.secondaryFill
        capsule.layer.cornerRadius = 24
        capsule.addSubview(searchField)
        searchField.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(hMargin: 14, vMargin: 0))
        let row = UIStackView(arrangedSubviews: [capsule, searchCloseButton])
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        capsule.autoSetDimension(.height, toSize: 48)
        searchCloseButton.autoSetDimensions(to: CGSize(square: 48))
        return row
    }()

    private lazy var searchBar: UIView = Self.bottomBar(containing: searchBarRow)

    private static func bottomBar(containing row: UIView) -> UIView {
        let background = UIView()
        background.backgroundColor = .Signal.background
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        background.isHidden = true
        return background
    }

    private static func roundButton(icon: ThemeIcon, accessibilityLabel: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.image = Theme.iconImage(icon)
        configuration.baseForegroundColor = .Signal.label
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        button.accessibilityLabel = accessibilityLabel
        return button
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.groupedBackground

        for subview in [tableView, topBar, sendBar, searchBar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        for subview in [closeButton, titleLabel, searchButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(subview)
        }
        let topBarHeight = topBar.heightAnchor.constraint(equalToConstant: Metrics.topBarHeight)
        topBarHeightConstraint = topBarHeight
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarHeight,
            closeButton.leadingAnchor.constraint(equalTo: topBar.layoutMarginsGuide.leadingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            searchButton.trailingAnchor.constraint(equalTo: topBar.layoutMarginsGuide.trailingAnchor),
            searchButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            searchButton.widthAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            searchButton.heightAnchor.constraint(equalToConstant: Metrics.roundButtonSize),

            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

        ])
        for (bar, row) in [(sendBar, sendBarRow), (searchBar, searchBarRow)] {
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
                row.leadingAnchor.constraint(equalTo: bar.layoutMarginsGuide.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: bar.layoutMarginsGuide.trailingAnchor),
                row.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            ])
        }
        if sharedAttachmentDock == nil, let dock = ownDock {
            dock.install(in: view)
        }
        updateChrome()

        source.loadRecentFiles(limit: Metrics.recentLimit) { [weak self] files in
            guard let self else { return }
            self.files = files
            self.tableView.reloadData()
            self.updateChrome()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBottomInset()
    }

    // MARK: - State

    private var isSelecting: Bool { selection != nil }
    private var isSearching: Bool { searchQuery != nil }

    /// 🔍 只在最近文件 > 10 条或加载中时出现，多选中藏起（F-8、F-10）。
    private var showsSearchButton: Bool {
        guard !isSelecting, !isSearching else { return false }
        guard let files else { return true }
        return files.count > Metrics.searchButtonThreshold
    }

    private func updateChrome() {
        searchButton.isHidden = !showsSearchButton
        // 只有当前页能动 dock（Sheet 里共用的那一条）
        if isActiveAttachmentPage {
            dock?.isHidden = !wantsAttachmentDock
        }
        sendBar.isHidden = !isSelecting
        searchBar.isHidden = !isSearching
        topBar.isHidden = isSearching
        topBarHeightConstraint?.constant = isSearching ? 0 : Metrics.topBarHeight
        let selectedCount = selection?.count ?? 0
        sendButton.isEnabled = selectedCount > 0
        titleLabel.text = isSelecting && selectedCount > 0
            ? String.nonPluralLocalizedStringWithFormat(OWSLocalizedString("IMAGE_PICKER_TELLOMI_SELECTED_FORMAT", comment: "Accessibility label of the selected-count pill in the photo picker. Embeds {{ number selected }}."), OWSFormat.formatInt(selectedCount))
            : OWSLocalizedString("ALL_MEDIA_FILE_TYPE_FILES", comment: "Title of the files page in the attachment sheet.")
        view.setNeedsLayout()
    }

    private func updateBottomInset() {
        let bottom: CGFloat
        if isSelecting {
            bottom = sendBar.frame.height
        } else if isSearching {
            bottom = searchBar.frame.height
        } else if dock != nil {
            bottom = TellomiAttachmentDock.height + TellomiAttachmentDock.bottomMargin
        } else {
            bottom = 0
        }
        if tableView.contentInset.bottom != bottom {
            tableView.contentInset.bottom = bottom
            tableView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    // MARK: - Actions

    private func didTapClose() {
        if isSelecting {
            selection = nil
            tableView.reloadData()
            updateChrome()
            captionField.resignFirstResponder()
            return
        }
        delegate?.filesPageDidCancel(self)
    }

    private func didSelectDockItem(_ item: TellomiAttachmentDockItem) {
        guard item != .file else {
            // 重复点「文件」：回到顶部并展开到全屏（同 Telegram 重复点当前格）
            tableView.setContentOffset(CGPoint(x: 0, y: -tableView.adjustedContentInset.top), animated: true)
            expandSheet()
            return
        }
        delegate?.filesPage(self, didSelectDockItem: item)
    }

    private func expandSheet() {
        if let sheet = sheetPresentationController, sheet.selectedDetentIdentifier != .large {
            sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
        }
    }

    private func didTap(entry: Entry) {
        switch entry {
        case .gallery:
            delegate?.filesPageDidSelectGallery(self)
        case .files:
            presentDocumentPicker()
        case .scan:
            presentScanner()
        }
    }

    /// F-4：系统文件选择器，可多选；复制一份到本机再给我们（iCloud 上没下载的由系统下完），不申请别的权限。
    /// Sheet 留在下面：取消了回到这一页。
    private func presentDocumentPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    /// F-5：系统文档扫描器；扫完所有页合成一个 PDF 立即发送。
    private func presentScanner() {
        guard VNDocumentCameraViewController.isSupported else { return }
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = self
        present(scanner, animated: true)
    }

    private func didTap(file: TellomiRecentFile) {
        guard file.isOnDevice else {
            presentToast(text: OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_NOT_ON_DEVICE_CANT_SEND", comment: "Toast shown when tapping a recently sent file whose local copy was deleted."))
            return
        }
        if var selection {
            if let index = selection.firstIndex(of: file.id) {
                selection.remove(at: index)
            } else {
                selection.append(file.id)
            }
            self.selection = selection
            tableView.reloadData()
            updateChrome()
            return
        }
        delegate?.filesPage(self, send: [file], messageBody: nil)
    }

    private func beginSelection(with file: TellomiRecentFile) {
        guard file.isOnDevice else { return }
        selection = [file.id]
        tableView.reloadData()
        updateChrome()
    }

    private func sendSelection() {
        guard let selection, !selection.isEmpty, let files else { return }
        let chosen = selection.compactMap { id in files.first { $0.id == id } }
        let text = captionField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = text.isEmpty ? nil : MessageBody(text: text, ranges: .empty)
        delegate?.filesPage(self, send: chosen, messageBody: body)
    }

    private func presentToast(text: String) {
        ToastController(text: text).presentToastView(from: .bottom, of: view, inset: view.safeAreaInsets.bottom + TellomiAttachmentDock.height + 16)
    }

    // MARK: - Search (F-10)

    // 分组随状态变（搜索中只有结果一组），所以改完状态**先** reloadData，再做会同步排版的事（展开 Sheet、弹 / 收键盘）：
    // 否则排版时表格还按旧的分组数取格子，越界崩溃（半屏点 🔍 实测）。

    private func beginSearch() {
        searchQuery = ""
        searchResults = []
        showsAllResults = false
        tableView.reloadData()
        updateChrome()
        expandSheet()
        searchField.text = nil
        searchField.becomeFirstResponder()
    }

    private func endSearch() {
        searchWorkItem?.cancel()
        searchQuery = nil
        tableView.reloadData()
        updateChrome()
        searchField.resignFirstResponder()
    }

    @objc
    private func searchTextChanged() {
        let text = searchField.text ?? ""
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runSearch(text) }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.searchDebounce, execute: work)
    }

    private func runSearch(_ text: String) {
        searchQuery = text
        showsAllResults = false
        searchResults = Self.search(files ?? [], for: text)
        tableView.reloadData()
    }

    /// 本机文件名，大小写、全半角、变音符号都不敏感。
    static func search(_ files: [TellomiRecentFile], for query: String) -> [TellomiRecentFile] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        return files.filter { fold($0.fileName).contains(needle) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: .current)
    }

    private var visibleSearchResults: [TellomiRecentFile] {
        if !showsAllResults, searchResults.count > Metrics.searchCollapseThreshold {
            return Array(searchResults.prefix(Metrics.searchCollapsedCount))
        }
        return searchResults
    }

    private var showsShowMoreRow: Bool {
        !showsAllResults && searchResults.count > Metrics.searchCollapseThreshold
    }
}

// MARK: - Table

extension TellomiAttachmentFilesViewController: UITableViewDataSource, UITableViewDelegate {

    private enum Section {
        case entries
        case recent
        case searchResults
    }

    /// 多选时三行入口整组拿掉（不是留一个空组：空组的上下间距会在顶栏下面留一截空白）。
    private var sections: [Section] {
        if isSearching {
            return [.searchResults]
        }
        return isSelecting ? [.recent] : [.entries, .recent]
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .entries:
            return entries.count
        case .recent:
            guard let files else { return Metrics.skeletonRows }
            return files.count
        case .searchResults:
            guard let query = searchQuery, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
            if searchResults.isEmpty {
                return 1
            }
            return visibleSearchResults.count + (showsShowMoreRow ? 1 : 0)
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .entries:
            return nil
        case .recent:
            // 标题常驻：加载中、一条都没有时也在（owner 2026-09-28：原来空的时候不显示，看起来像没有这个功能）。
            return OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_RECENT_HEADER", comment: "Header above the list of files you recently sent, on the files page of the attachment sheet.")
        case .searchResults:
            guard !searchResults.isEmpty else { return nil }
            return OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_SEARCH_HEADER", comment: "Header above file search results; only files you sent on this device are searched.")
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard sections[section] == .recent, let files, files.isEmpty else { return nil }
        return String.nonPluralLocalizedStringWithFormat(OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_EMPTY_FORMAT", comment: "Shown on the files page when you haven't sent any files. Embeds {{maximum size of one file}}."), maxFileSizeText)
    }

    /// 一条都没有时：插画 + 说明（文字同 `titleForFooterInSection`，读屏也念它）。
    func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard let message = self.tableView(tableView, titleForFooterInSection: section) else { return nil }
        let view = TellomiRecentFilesEmptyView(message: message)
        view.isAccessibilityElement = true
        view.accessibilityLabel = message
        return view
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch sections[indexPath.section] {
        case .entries: return UITableView.automaticDimension
        case .recent, .searchResults: return TellomiRecentFileCell.rowHeight
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .entries:
            let cell = tableView.dequeueReusableCell(withIdentifier: Self.plainCellIdentifier, for: indexPath)
            configure(entryCell: cell, entry: entries[indexPath.row])
            return cell
        case .recent:
            guard let files else {
                return tableView.dequeueReusableCell(withIdentifier: TellomiRecentFileSkeletonCell.reuseIdentifier, for: indexPath)
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: TellomiRecentFileCell.reuseIdentifier, for: indexPath) as! TellomiRecentFileCell
            let file = files[indexPath.row]
            cell.configure(file: file, showsDate: true, selectionNumber: selectionNumber(of: file))
            return cell
        case .searchResults:
            if searchResults.isEmpty {
                let cell = tableView.dequeueReusableCell(withIdentifier: Self.plainCellIdentifier, for: indexPath)
                var content = cell.defaultContentConfiguration()
                content.text = String.nonPluralLocalizedStringWithFormat(OWSLocalizedString("HOME_VIEW_SEARCH_NO_RESULTS_FORMAT", comment: "Format string when search returns no results. Embeds {{search term}}"), searchQuery ?? "")
                content.textProperties.color = .Signal.secondaryLabel
                content.textProperties.alignment = .center
                cell.contentConfiguration = content
                cell.selectionStyle = .none
                return cell
            }
            let visible = visibleSearchResults
            if indexPath.row >= visible.count {
                let cell = tableView.dequeueReusableCell(withIdentifier: Self.plainCellIdentifier, for: indexPath)
                var content = cell.defaultContentConfiguration()
                content.text = OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_SHOW_MORE", comment: "Row at the end of shortened file search results that shows all of them.")
                content.textProperties.color = .Signal.accent
                content.image = Theme.iconImage(.chevronDown)
                content.imageProperties.tintColor = .Signal.accent
                cell.contentConfiguration = content
                cell.selectionStyle = .default
                return cell
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: TellomiRecentFileCell.reuseIdentifier, for: indexPath) as! TellomiRecentFileCell
            cell.configure(file: visible[indexPath.row], showsDate: false, selectionNumber: nil)
            return cell
        }
    }

    private func configure(entryCell cell: UITableViewCell, entry: Entry) {
        var content = cell.defaultContentConfiguration()
        switch entry {
        case .gallery:
            content.text = OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_SELECT_FROM_GALLERY", comment: "Row on the files page: send photos or videos from the gallery as files, without compression.")
            content.image = UIImage(named: "album-tilt")
        case .files:
            content.text = OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_SELECT_FROM_FILES", comment: "Row on the files page that opens the system file picker.")
            content.image = UIImage(named: "file-28")
        case .scan:
            content.text = OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_SCAN_DOCUMENT", comment: "Row on the files page that scans paper documents into one PDF.")
            content.image = UIImage(systemName: "doc.viewfinder")
        }
        content.textProperties.color = .Signal.accent
        content.imageProperties.tintColor = .Signal.accent
        content.imageProperties.maximumSize = CGSize(square: 24)
        content.imageProperties.reservedLayoutSize = CGSize(square: 28)
        cell.contentConfiguration = content
        cell.accessibilityTraits = .button
    }

    private func selectionNumber(of file: TellomiRecentFile) -> Int? {
        guard let selection else { return nil }
        return selection.firstIndex(of: file.id).map { $0 + 1 } ?? 0
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .entries:
            didTap(entry: entries[indexPath.row])
        case .recent:
            guard let files else { return }
            didTap(file: files[indexPath.row])
        case .searchResults:
            guard !searchResults.isEmpty else { return }
            let visible = visibleSearchResults
            if indexPath.row >= visible.count {
                showsAllResults = true
                tableView.reloadData()
                return
            }
            didTap(file: visible[indexPath.row])
        }
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard sections[indexPath.section] == .recent, !isSelecting, let files, files[indexPath.row].isOnDevice else { return nil }
        let file = files[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: CommonStrings.selectButton, image: Theme.iconImage(.checkCircle)) { _ in
                self?.beginSelection(with: file)
            }])
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {}
}

// MARK: - File picker & scanner

extension TellomiAttachmentFilesViewController: UIDocumentPickerDelegate, VNDocumentCameraViewControllerDelegate {

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !urls.isEmpty else { return }
        delegate?.filesPage(self, sendFilesAt: urls)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
        let title = scan.title
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            do {
                let url = try TellomiScannedDocument.makePDF(pages: pages, title: title)
                self.delegate?.filesPage(self, sendFilesAt: [url])
            } catch {
                owsFailDebug("Couldn't make PDF from scan: \(error)")
            }
        }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        controller.dismiss(animated: true)
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        Logger.warn("Document scan failed: \(error)")
        controller.dismiss(animated: true)
    }
}

// MARK: - Testing

extension TellomiAttachmentFilesViewController {
    var isSearchButtonShownForTesting: Bool { !searchButton.isHidden }
    var isDockShownForTesting: Bool { dock.map { !$0.isHidden } ?? false }
    var isSendBarShownForTesting: Bool { !sendBar.isHidden }
    var isSearchBarShownForTesting: Bool { !searchBar.isHidden }
    var sendBarFrameForTesting: CGRect { sendBar.frame }
    var searchBarFrameForTesting: CGRect { searchBar.frame }
    var tableViewForTesting: UITableView { tableView }
    var entriesForTesting: [Entry] { entries }
    var dockForTesting: TellomiAttachmentDock? { dock }
    var selectedIdsForTesting: [String]? { selection }
    var titleForTesting: String? { titleLabel.text }

    func footerTextForTesting() -> String? {
        guard let recent = sections.firstIndex(of: .recent) else { return nil }
        return tableView(tableView, titleForFooterInSection: recent)
    }

    func recentHeaderTextForTesting() -> String? {
        guard let recent = sections.firstIndex(of: .recent) else { return nil }
        return tableView(tableView, titleForHeaderInSection: recent)
    }

    func recentEmptyViewForTesting() -> TellomiRecentFilesEmptyView? {
        guard let recent = sections.firstIndex(of: .recent) else { return nil }
        return tableView(tableView, viewForFooterInSection: recent) as? TellomiRecentFilesEmptyView
    }

    func tapEntryForTesting(_ entry: Entry) {
        guard let row = entries.firstIndex(of: entry) else { return }
        tableView(tableView, didSelectRowAt: IndexPath(row: row, section: 0))
    }

    func tapFileForTesting(row: Int) {
        tableView(tableView, didSelectRowAt: IndexPath(row: row, section: sections.firstIndex(of: .recent) ?? 0))
    }

    func beginSelectionForTesting(row: Int) {
        guard let files else { return }
        beginSelection(with: files[row])
    }

    func sendSelectionForTesting(caption: String?) {
        captionField.text = caption
        sendButton.sendActions(for: .primaryActionTriggered)
    }

    func tapCloseForTesting() {
        closeButton.sendActions(for: .primaryActionTriggered)
    }

    func tapSearchForTesting() {
        searchButton.sendActions(for: .primaryActionTriggered)
    }

    func tapSearchCloseForTesting() {
        searchCloseButton.sendActions(for: .primaryActionTriggered)
    }

    func searchForTesting(_ text: String) {
        searchField.text = text
        runSearch(text)
    }

    func tapSearchRowForTesting(row: Int) {
        tableView(tableView, didSelectRowAt: IndexPath(row: row, section: 0))
    }

    func searchRowCountForTesting() -> Int {
        tableView(tableView, numberOfRowsInSection: 0)
    }

    var presentedDocumentPickerForTesting: UIDocumentPickerViewController? {
        presentedViewController as? UIDocumentPickerViewController
    }
}

/// 加载中的骨架行（F-6）：灰色图标块 + 两条灰条。
final class TellomiRecentFileSkeletonCell: UITableViewCell {
    static let reuseIdentifier = "TellomiRecentFileSkeletonCell"

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        let block = UIView()
        block.backgroundColor = .Signal.secondaryFill
        block.layer.cornerRadius = 8
        let line1 = UIView()
        line1.backgroundColor = .Signal.secondaryFill
        line1.layer.cornerRadius = 4
        let line2 = UIView()
        line2.backgroundColor = .Signal.tertiaryFill
        line2.layer.cornerRadius = 4
        for subview in [block, line1, line2] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            block.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            block.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            block.widthAnchor.constraint(equalToConstant: TellomiFileTypeIcon.side),
            block.heightAnchor.constraint(equalToConstant: TellomiFileTypeIcon.side),
            line1.leadingAnchor.constraint(equalTo: block.trailingAnchor, constant: 12),
            line1.topAnchor.constraint(equalTo: block.topAnchor, constant: 6),
            line1.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.45),
            line1.heightAnchor.constraint(equalToConstant: 10),
            line2.leadingAnchor.constraint(equalTo: line1.leadingAnchor),
            line2.bottomAnchor.constraint(equalTo: block.bottomAnchor, constant: -6),
            line2.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.3),
            line2.heightAnchor.constraint(equalToConstant: 8),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 「最近发送的文件」一条都没有时，标题下面的插画 + 说明（owner 2026-09-28：原来只有一句说明、连标题都不显示，看起来像没有这个功能）。
/// 照 Telegram iOS `AttachmentFileEmptyItem` 的结构（一张图 + 一句话），图用系统符号，独立实现、一行没搬（GPLv2）。
final class TellomiRecentFilesEmptyView: UIView {

    private let illustration = UIImageView()
    private let messageLabel = UILabel()

    init(message: String) {
        super.init(frame: .zero)

        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .light)
        illustration.image = UIImage(systemName: "doc.on.doc", withConfiguration: symbolConfiguration)
        illustration.tintColor = .Signal.secondaryLabel
        illustration.contentMode = .center
        illustration.isAccessibilityElement = false

        messageLabel.text = message
        messageLabel.font = .dynamicTypeFootnote
        messageLabel.textColor = .Signal.secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [illustration, messageLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 20, leading: 24, bottom: 24, trailing: 24))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if TESTABLE_BUILD
    var illustrationForTesting: UIImageView { illustration }
    var messageTextForTesting: String? { messageLabel.text }
    #endif
}
