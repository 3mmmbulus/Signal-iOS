//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalServiceKit
import SignalUI

/// 转发面板：Telegram 式头像网格（tellomi/tellomi#1259，需求 `docs/product/specs/media-album-forward-picker.md` 第二节）。
///
/// 长按「转发」、多选「转发」、查看器「转发」都打开它（F-1）。这里只管选聊天和写附言；发送仍走
/// `ForwardMessageViewController` 那一套（同样的检查、同样的发送、同样的安全码确认）。
///
/// 形态（F-2）：浮动卡片（宽 = min(屏宽, 440) − 20，圆角 16）+ 下面独立的「取消 / 发送」（高 57，间距 8），背后压暗 50%，点压暗处关闭。
/// 网格是一个整屏高的滚动视图：内容顶端留出空白，一开始只露出约三行；上拉网格，标题区跟着上去、到顶后停住（= 展开）；
/// 标题区往下拉超过 30 pt 松手 = 关闭。
final class TellomiForwardGridViewController: UIViewController {

    struct Actions {
        /// 选好的聊天（按勾选顺序）+ 附言 → 发出去。true = 已发出（面板由发起方收起并提示）；false = 没发出（错误提示已弹出）
        var send: @MainActor (_ items: [ConversationItem], _ comment: String?) async -> Bool
        /// 右上角「分享到其他 App」（F-10）；nil = 这条内容不能分享，不显示按钮
        var share: (@MainActor (_ sourceView: UIView) -> Void)?
        /// 没发、关掉面板
        var cancel: @MainActor () -> Void
    }

    /// 同上游 `kMaxPickerSelection`：Signal 一次最多转给 5 个聊天（owner D4 保留）
    static let maxSelection = 5

    enum Colors {
        static var card: UIColor { UIColor.Signal.secondaryGroupedBackground }
        static var field: UIColor { UIColor.Signal.secondaryFill }
        static let dim = UIColor.black.withAlphaComponent(0.5)
    }

    /// 几何（F-2 / F-4），与 Telegram iOS 分享面板同一组数（独立实现）。
    struct Metrics: Equatable {
        static let maxCardWidth: CGFloat = 440
        static let cardSideInset: CGFloat = 10
        static let gridSideInset: CGFloat = 12
        static let minItemWidth: CGFloat = 70
        static let titleAreaHeight: CGFloat = 64
        static let buttonHeight: CGFloat = 57
        static let buttonSpacing: CGFloat = 8
        static let cornerRadius: CGFloat = 16
        static let initialRevealRows: CGFloat = 3.7
        static let revealBottomPadding: CGFloat = 14
        static let dismissPullDistance: CGFloat = 30
        static let commentBarHeight: CGFloat = 56
        static let cardTopSpacing: CGFloat = 8

        let cardWidth: CGFloat
        let columns: Int
        let itemWidth: CGFloat

        var itemHeight: CGFloat { itemWidth + 25 }
        var gridWidth: CGFloat { itemWidth * CGFloat(columns) }
        var gridLeadingInset: CGFloat { floor((cardWidth - gridWidth) / 2) }
        /// 一开始露出的网格高度（不含标题区）
        var initialRevealHeight: CGFloat { floor(Self.initialRevealRows * itemWidth) + Self.revealBottomPadding }

        init(containerWidth: CGFloat) {
            cardWidth = min(containerWidth, Self.maxCardWidth) - 2 * Self.cardSideInset
            let effectiveWidth = cardWidth - 2 * Self.gridSideInset
            columns = max(1, Int(effectiveWidth / Self.minItemWidth))
            itemWidth = floor(effectiveWidth / CGFloat(columns))
        }
    }

    private enum Section {
        case grid
        case recent
        case savedMessages
        case chats
        case contacts
        case groups
    }

    private let actions: Actions
    private let forceDarkTheme: Bool
    private var presentationTime = Date()

    /// 选中时预取对方身份密钥（同上游 `shouldBatchUpdateIdentityKeys`），发送前的安全码确认才能拿到最新的变化
    var prefetchIdentityKeys: ([ServiceId]) -> Void = { serviceIds in
        guard !serviceIds.isEmpty else { return }
        Task {
            do {
                try await DependenciesBridge.shared.identityManager.batchUpdateIdentityKeys(for: serviceIds)
            } catch {
                Logger.warn("Failed to batch update identity keys: \(error)")
            }
        }
    }

    // MARK: 数据

    private var allTargets: [TellomiForwardTarget] = []
    private var promotedIds: [String] = []
    private var targetsById: [String: TellomiForwardTarget] = [:]
    private var gridTargets: [TellomiForwardTarget] = []
    private var selectedIds: [String] = []

    private var isSearching = false
    private var searchQuery = ""
    private var searchResults = TellomiForwardSearchResults.empty
    private var recentContacts: [TellomiForwardTarget] = []

    private var sections: [(Section, [TellomiForwardTarget])] = []

    // MARK: 状态

    private var metrics = Metrics(containerWidth: 402)
    private var keyboardHeight: CGFloat = 0
    private var isSending = false
    private var isDismissingByPull = false

    // MARK: 视图

    private let dimView = UIView()
    private let cardClipView = UIView()
    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: buildLayout())
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.keyboardDismissMode = .onDrag
        collectionView.delaysContentTouches = false
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(TellomiForwardGridCell.self, forCellWithReuseIdentifier: TellomiForwardGridCell.reuseIdentifier)
        collectionView.register(
            TellomiForwardSectionHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: TellomiForwardSectionHeader.reuseIdentifier,
        )
        return collectionView
    }()

    private let cardBackgroundView = UIView()
    private let headerView = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let searchButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    private let searchBarView = UIView()
    private let searchFieldBackground = UIView()
    private let searchField = UITextField()
    private let searchCancelButton = UIButton(type: .system)

    private let emptyResultsLabel = UILabel()

    private let commentBar = UIView()
    private let commentSeparator = UIView()
    private let commentFieldBackground = UIView()
    private let commentField = UITextField()

    private let actionButton = UIButton(type: .custom)
    private let actionTitleLabel = UILabel()
    private let badgeLabel = UILabel()
    private let badgeView = UIView()

    // MARK: -

    init(forceDarkTheme: Bool, actions: Actions) {
        self.forceDarkTheme = forceDarkTheme
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        transitioningDelegate = self
        if forceDarkTheme {
            overrideUserInterfaceStyle = .dark
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        forceDarkTheme ? .lightContent : .default
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear

        dimView.backgroundColor = Colors.dim
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapOutside)))
        view.addSubview(dimView)

        cardClipView.clipsToBounds = true
        cardClipView.layer.cornerRadius = Metrics.cornerRadius
        cardClipView.layer.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        view.addSubview(cardClipView)

        cardBackgroundView.backgroundColor = Colors.card
        cardBackgroundView.layer.cornerRadius = Metrics.cornerRadius
        cardBackgroundView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        cardBackgroundView.layer.zPosition = -1
        cardBackgroundView.isUserInteractionEnabled = false

        cardClipView.addSubview(collectionView)
        collectionView.addSubview(cardBackgroundView)
        buildHeader()
        headerView.layer.zPosition = 100
        collectionView.addSubview(headerView)
        cardClipView.addSubview(searchBarView)

        let outsideTap = UITapGestureRecognizer(target: self, action: #selector(didTapOutside))
        outsideTap.cancelsTouchesInView = false
        outsideTap.delegate = self
        collectionView.addGestureRecognizer(outsideTap)

        emptyResultsLabel.font = .dynamicTypeSubheadline
        emptyResultsLabel.textColor = UIColor.Signal.secondaryLabel
        emptyResultsLabel.textAlignment = .center
        emptyResultsLabel.numberOfLines = 0
        emptyResultsLabel.isHidden = true
        cardClipView.addSubview(emptyResultsLabel)

        buildCommentBar()
        cardClipView.addSubview(commentBar)

        buildActionButton()
        view.addSubview(actionButton)

        reloadTargets()
        updateSelectionChrome(animated: false)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil,
        )
    }

    /// 第一次出现在屏幕上时调一次：转发流程用它弹新功能提示卡（`TellomiFeatureIntro`）。
    var onFirstAppear: ((TellomiForwardGridViewController) -> Void)?
    private var hasAppeared = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationTime = Date()
        if !hasAppeared {
            hasAppeared = true
            onFirstAppear?(self)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutCard()
    }

    override func accessibilityPerformEscape() -> Bool {
        // 发送中面板已经藏起来了，同点空白处、下拉一样不响应；不然发完以后发起方去收一个已经关掉的面板
        guard !isSending else { return true }
        if isSearching {
            endSearch()
        } else {
            cancel()
        }
        return true
    }

    // MARK: - 搭界面

    private func buildHeader() {
        // 标题区自己铺卡片底色、上面两个角和卡片一样圆：贴顶以后格子从它下面滚过去，不能透出来（taishi 审查 #70）
        headerView.backgroundColor = Colors.card
        headerView.layer.cornerRadius = Metrics.cornerRadius
        headerView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        titleLabel.text = OWSLocalizedString("FORWARD_MESSAGE_TITLE", comment: "Title for the 'forward message(s)' view.")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = UIColor.Signal.label
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        headerView.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = UIColor.Signal.secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingTail
        headerView.addSubview(subtitleLabel)

        searchButton.setImage(Theme.iconImage(.buttonSearch), for: .normal)
        searchButton.tintColor = UIColor.Signal.accent
        searchButton.accessibilityLabel = CommonStrings.searchPlaceholder
        searchButton.addTarget(self, action: #selector(didTapSearch), for: .touchUpInside)
        headerView.addSubview(searchButton)

        shareButton.setImage(Theme.iconImage(.buttonShare), for: .normal)
        shareButton.tintColor = UIColor.Signal.accent
        shareButton.accessibilityLabel = Strings.shareToOtherApps
        shareButton.addTarget(self, action: #selector(didTapShare), for: .touchUpInside)
        shareButton.isHidden = actions.share == nil
        headerView.addSubview(shareButton)

        searchFieldBackground.backgroundColor = Colors.field
        searchFieldBackground.layer.cornerRadius = 10
        searchBarView.addSubview(searchFieldBackground)

        let magnifier = UIImageView(image: Theme.iconImage(.buttonSearch))
        magnifier.tintColor = UIColor.Signal.secondaryLabel
        magnifier.contentMode = .scaleAspectFit
        magnifier.frame = CGRect(x: 0, y: 0, width: 18, height: 18)
        let magnifierContainer = UIView(frame: CGRect(x: 0, y: 0, width: 26, height: 18))
        magnifierContainer.addSubview(magnifier)
        searchField.leftView = magnifierContainer
        searchField.leftViewMode = .always
        searchField.placeholder = CommonStrings.searchPlaceholder
        searchField.font = .systemFont(ofSize: 17)
        searchField.textColor = UIColor.Signal.label
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchTextDidChange), for: .editingChanged)
        searchBarView.addSubview(searchField)

        searchCancelButton.setTitle(CommonStrings.cancelButton, for: .normal)
        searchCancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        searchCancelButton.tintColor = UIColor.Signal.accent
        searchCancelButton.addTarget(self, action: #selector(didTapSearchCancel), for: .touchUpInside)
        searchBarView.addSubview(searchCancelButton)

        // 搜索栏固定在卡片顶、不放进滚动视图：搜索框在集合视图的 contentInset.top 那一块里时，成为第一响应者会被
        // 系统当成「被挡住」往下滚 50（taishi 审查 #70：搜索态比设计低 50 pt）。搜索态本来也不跟着结果滚。
        searchBarView.backgroundColor = Colors.card
        searchBarView.layer.cornerRadius = Metrics.cornerRadius
        searchBarView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        searchBarView.isHidden = true
    }

    private func buildCommentBar() {
        commentBar.backgroundColor = Colors.card
        commentSeparator.backgroundColor = UIColor.Signal.opaqueSeparator
        commentBar.addSubview(commentSeparator)

        commentFieldBackground.backgroundColor = Colors.field
        commentFieldBackground.layer.cornerRadius = 18
        commentBar.addSubview(commentFieldBackground)

        commentField.placeholder = Strings.commentPlaceholder
        commentField.font = .systemFont(ofSize: 17)
        commentField.textColor = UIColor.Signal.label
        commentField.returnKeyType = .send
        commentField.delegate = self
        commentBar.addSubview(commentField)

        commentBar.isHidden = true
    }

    private func buildActionButton() {
        actionButton.backgroundColor = Colors.card
        actionButton.layer.cornerRadius = Metrics.cornerRadius
        actionButton.clipsToBounds = true
        actionButton.addTarget(self, action: #selector(didTapActionButton), for: .touchUpInside)

        actionTitleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        actionTitleLabel.textColor = UIColor.Signal.accent
        actionTitleLabel.isUserInteractionEnabled = false
        actionButton.addSubview(actionTitleLabel)

        badgeView.backgroundColor = UIColor.Signal.accent
        badgeView.isUserInteractionEnabled = false
        actionButton.addSubview(badgeView)
        badgeLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeView.addSubview(badgeLabel)
    }

    private func buildLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
            guard let self, sectionIndex < self.sections.count else {
                return nil
            }
            return self.layoutSection(for: self.sections[sectionIndex].0)
        }
    }

    private func layoutSection(for section: Section) -> NSCollectionLayoutSection {
        let metrics = self.metrics
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .absolute(metrics.itemWidth),
            heightDimension: .absolute(metrics.itemHeight),
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let layoutSection: NSCollectionLayoutSection
        switch section {
        case .recent:
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: itemSize, subitems: [item])
            layoutSection = NSCollectionLayoutSection(group: group)
            layoutSection.orthogonalScrollingBehavior = .continuous
        case .grid, .savedMessages, .chats, .contacts, .groups:
            let groupSize = NSCollectionLayoutSize(
                widthDimension: .absolute(metrics.gridWidth),
                heightDimension: .absolute(metrics.itemHeight),
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: groupSize,
                subitems: Array(repeating: item, count: metrics.columns),
            )
            layoutSection = NSCollectionLayoutSection(group: group)
        }
        layoutSection.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: metrics.gridLeadingInset,
            bottom: section == .grid ? 0 : 8,
            trailing: metrics.gridLeadingInset,
        )
        if sectionTitle(section) != nil {
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(TellomiForwardSectionHeader.height),
                ),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top,
            )
            header.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: -metrics.gridLeadingInset, bottom: 0, trailing: -metrics.gridLeadingInset)
            layoutSection.boundarySupplementaryItems = [header]
        }
        return layoutSection
    }

    private func sectionTitle(_ section: Section) -> String? {
        switch section {
        case .grid, .savedMessages:
            return nil
        case .recent:
            return Strings.recentContacts
        case .chats:
            return Strings.sectionChats
        case .contacts:
            return Strings.sectionContacts
        case .groups:
            return Strings.sectionGroups
        }
    }

    // MARK: - 数据

    private func reloadTargets() {
        allTargets = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiForwardTargets.load(tx: tx)
        }
        for target in allTargets {
            targetsById[target.id] = target
        }
        recentContacts = TellomiForwardTargets.recentContacts(in: allTargets)
        rebuildGridTargets()
        rebuildSections()
    }

    /// 网格顺序：我的收藏 → 从搜索里选中的（新的在前，F-9）→ 其余候选
    private func rebuildGridTargets() {
        let promoted = promotedIds.compactMap { targetsById[$0] }
        let promotedSet = Set(promotedIds)
        var result: [TellomiForwardTarget] = []
        if let savedMessages = allTargets.first(where: \.isSavedMessages) {
            result.append(savedMessages)
        }
        result.append(contentsOf: promoted)
        result.append(contentsOf: allTargets.filter { !$0.isSavedMessages && !promotedSet.contains($0.id) })
        gridTargets = result
    }

    private func rebuildSections() {
        if !isSearching {
            sections = [(.grid, gridTargets)]
        } else if searchQuery.strippedOrNil == nil {
            sections = recentContacts.isEmpty ? [] : [(.recent, recentContacts)]
        } else {
            var result: [(Section, [TellomiForwardTarget])] = []
            if let savedMessages = searchResults.savedMessages {
                result.append((.savedMessages, [savedMessages]))
            }
            if !searchResults.chats.isEmpty {
                result.append((.chats, searchResults.chats))
            }
            if !searchResults.contacts.isEmpty {
                result.append((.contacts, searchResults.contacts))
            }
            if !searchResults.groups.isEmpty {
                result.append((.groups, searchResults.groups))
            }
            sections = result
        }
        let showsNoResults = isSearching && searchQuery.strippedOrNil != nil && searchResults.isEmpty
        emptyResultsLabel.isHidden = !showsNoResults
        if showsNoResults {
            let format = OWSLocalizedString(
                "HOME_VIEW_SEARCH_NO_RESULTS_FORMAT",
                comment: "Format string when search returns no results. Embeds {{search term}}",
            )
            emptyResultsLabel.text = String(format: format, searchQuery)
        }
    }

    private var selectedTargets: [TellomiForwardTarget] {
        selectedIds.compactMap { targetsById[$0] }
    }

    private func target(at indexPath: IndexPath) -> TellomiForwardTarget? {
        guard indexPath.section < sections.count else { return nil }
        let targets = sections[indexPath.section].1
        guard indexPath.item < targets.count else { return nil }
        return targets[indexPath.item]
    }

    // MARK: - 选择（F-6）

    /// 点一格：切换选中。超过上限不选、提示「最多选 5 个聊天」。返回这次点完是不是选中。
    @discardableResult
    private func toggle(_ target: TellomiForwardTarget) -> Bool {
        if let index = selectedIds.firstIndex(of: target.id) {
            selectedIds.remove(at: index)
            updateSelectionChrome(animated: true)
            return false
        }
        guard selectedIds.count < Self.maxSelection else {
            showSelectionLimitToast()
            return false
        }
        targetsById[target.id] = target
        selectedIds.append(target.id)
        let serviceIds: [ServiceId] = SSKEnvironment.shared.databaseStorageRef.read { tx in
            guard let thread = target.item.getExistingThread(transaction: tx) else {
                if case .contact(let address) = target.item.messageRecipient, let serviceId = address.serviceId {
                    return [serviceId]
                }
                return []
            }
            return thread.recipientAddresses(with: tx).compactMap(\.serviceId)
        }
        prefetchIdentityKeys(serviceIds)
        updateSelectionChrome(animated: true)
        return true
    }

    private func showSelectionLimitToast() {
        let text = String(format: Strings.selectionLimitFormat, Self.maxSelection)
        let extraInset = max(0, view.bounds.height - actionButton.frame.minY - view.safeAreaInsets.bottom)
        presentToast(text: text, extraVInset: extraInset)
    }

    private func updateSelectionChrome(animated: Bool) {
        let selected = selectedTargets
        if selected.isEmpty {
            subtitleLabel.text = Strings.chooseChats
            subtitleLabel.textColor = UIColor.Signal.secondaryLabel
        } else {
            subtitleLabel.text = selected.map(\.fullName).joined(separator: Strings.nameSeparator)
            subtitleLabel.textColor = UIColor.Signal.accent
        }

        for cell in collectionView.visibleCells {
            guard let cell = cell as? TellomiForwardGridCell, let targetId = cell.targetId else { continue }
            let shouldBeChosen = selectedIds.contains(targetId)
            if cell.isChosen != shouldBeChosen {
                cell.setChosen(shouldBeChosen, animated: animated)
            }
        }

        updateActionButton()
        let commentBarWasHidden = commentBar.isHidden
        commentBar.isHidden = selected.isEmpty || isSearching
        if commentBar.isHidden, commentField.isFirstResponder {
            commentField.resignFirstResponder()
        }
        if commentBarWasHidden != commentBar.isHidden {
            if animated {
                UIView.animate(withDuration: 0.25) {
                    self.layoutCard()
                }
            } else {
                layoutCard()
            }
        }
    }

    private func updateActionButton() {
        let count = selectedIds.count
        if count == 0 {
            actionTitleLabel.text = CommonStrings.cancelButton
            actionButton.accessibilityLabel = CommonStrings.cancelButton
            badgeView.isHidden = true
        } else {
            let sendTitle = OWSLocalizedString("SEND_BUTTON_TITLE", comment: "Label for the button to send a message")
            actionTitleLabel.text = sendTitle
            badgeLabel.text = OWSFormat.formatInt(count)
            actionButton.accessibilityLabel = sendTitle + " " + OWSFormat.formatInt(count)
            badgeView.isHidden = false
        }
        layoutActionButtonContents()
    }

    private func layoutActionButtonContents() {
        let bounds = actionButton.bounds
        let titleSize = actionTitleLabel.sizeThatFits(bounds.size)
        let badgeHeight: CGFloat = 22
        let badgeWidth = badgeView.isHidden ? 0 : max(badgeHeight, ceil(badgeLabel.sizeThatFits(bounds.size).width) + 12)
        let spacing: CGFloat = badgeView.isHidden ? 0 : 8
        let totalWidth = ceil(titleSize.width) + spacing + badgeWidth
        let originX = floor((bounds.width - totalWidth) / 2)
        actionTitleLabel.frame = CGRect(
            x: originX,
            y: floor((bounds.height - titleSize.height) / 2),
            width: ceil(titleSize.width),
            height: ceil(titleSize.height),
        )
        badgeView.frame = CGRect(
            x: actionTitleLabel.frame.maxX + spacing,
            y: floor((bounds.height - badgeHeight) / 2),
            width: badgeWidth,
            height: badgeHeight,
        )
        badgeView.layer.cornerRadius = badgeHeight / 2
        badgeLabel.frame = badgeView.bounds
    }

    // MARK: - 排版

    private func layoutCard() {
        let bounds = view.bounds
        guard bounds.width > 0 else { return }
        let safeInsets = view.safeAreaInsets

        let newMetrics = Metrics(containerWidth: bounds.width)
        if newMetrics != metrics {
            metrics = newMetrics
            collectionView.collectionViewLayout.invalidateLayout()
        }

        dimView.frame = bounds

        let cardX = floor((bounds.width - metrics.cardWidth) / 2)
        let bottomGap: CGFloat
        if keyboardHeight > 0 {
            bottomGap = keyboardHeight + Metrics.buttonSpacing
        } else {
            bottomGap = safeInsets.bottom > 0 ? safeInsets.bottom - 2 : 10
        }

        // 卡片和按钮有进出场 / 收起的位移（transform），不能设 frame：用 bounds + center
        let buttonY = bounds.height - bottomGap - Metrics.buttonHeight
        setUntransformedFrame(CGRect(x: cardX, y: buttonY, width: metrics.cardWidth, height: Metrics.buttonHeight), of: actionButton)
        actionButton.isHidden = isSearching
        layoutActionButtonContents()

        let cardTop = safeInsets.top + Metrics.cardTopSpacing
        let cardBottom = isSearching ? bounds.height - bottomGap : buttonY - Metrics.buttonSpacing
        setUntransformedFrame(CGRect(x: cardX, y: cardTop, width: metrics.cardWidth, height: max(0, cardBottom - cardTop)), of: cardClipView)
        let cardSize = cardClipView.bounds.size

        let commentHeight = commentBar.isHidden ? 0 : Metrics.commentBarHeight
        commentBar.frame = CGRect(x: 0, y: cardSize.height - commentHeight, width: cardSize.width, height: commentHeight)
        commentSeparator.frame = CGRect(x: 0, y: 0, width: cardSize.width, height: hairlineWidth)
        commentFieldBackground.frame = CGRect(x: 12, y: 10, width: cardSize.width - 24, height: 36)
        commentField.frame = commentFieldBackground.frame.insetBy(dx: 14, dy: 0)

        if collectionView.frame != cardClipView.bounds {
            collectionView.frame = cardClipView.bounds
        }

        let gridTop: CGFloat
        if isSearching {
            gridTop = Metrics.titleAreaHeight
        } else {
            gridTop = max(Metrics.titleAreaHeight, cardSize.height - metrics.initialRevealHeight - commentHeight)
        }
        let oldInsets = collectionView.contentInset
        let newInsets = UIEdgeInsets(top: gridTop, left: 0, bottom: commentHeight + 8, right: 0)
        if oldInsets != newInsets {
            // 保持「从停放位置上拉了多少」不变
            let scrolledDistance = collectionView.contentOffset.y + oldInsets.top
            collectionView.contentInset = newInsets
            if !isDismissingByPull {
                collectionView.contentOffset.y = max(0, scrolledDistance) - gridTop
            }
        }

        emptyResultsLabel.frame = CGRect(x: 16, y: Metrics.titleAreaHeight + 32, width: cardSize.width - 32, height: 60)

        layoutHeaderContents()
        updateHeaderPosition()
    }

    private func setUntransformedFrame(_ frame: CGRect, of view: UIView) {
        view.bounds = CGRect(origin: .zero, size: frame.size)
        view.center = CGPoint(x: frame.midX, y: frame.midY)
    }

    /// 没有位移时卡片的位置（用例与排版用；`frame` 含位移）
    private var restingCardFrame: CGRect {
        CGRect(
            x: cardClipView.center.x - cardClipView.bounds.width / 2,
            y: cardClipView.center.y - cardClipView.bounds.height / 2,
            width: cardClipView.bounds.width,
            height: cardClipView.bounds.height,
        )
    }

    private func layoutHeaderContents() {
        let width = metrics.cardWidth
        headerView.bounds = CGRect(x: 0, y: 0, width: width, height: Metrics.titleAreaHeight)
        searchButton.frame = CGRect(x: 6, y: 10, width: 44, height: 44)
        shareButton.frame = CGRect(x: width - 50, y: 10, width: 44, height: 44)
        let textWidth = width - 2 * (44 + 16)
        titleLabel.frame = CGRect(x: floor((width - textWidth) / 2), y: 13, width: textWidth, height: 22)
        subtitleLabel.frame = CGRect(x: floor((width - textWidth) / 2), y: 36, width: textWidth, height: 18)

        searchBarView.frame = CGRect(x: 0, y: 0, width: width, height: Metrics.titleAreaHeight)
        let cancelSize = searchCancelButton.sizeThatFits(CGSize(width: 200, height: 44))
        let cancelWidth = ceil(cancelSize.width)
        searchCancelButton.frame = CGRect(x: width - 12 - cancelWidth, y: 14, width: cancelWidth, height: 36)
        searchFieldBackground.frame = CGRect(x: 12, y: 14, width: searchCancelButton.frame.minX - 12 - 12, height: 36)
        searchField.frame = searchFieldBackground.frame.insetBy(dx: 8, dy: 0)
    }

    /// 标题区贴在网格内容上方，内容上拉到顶后停在卡片顶端；卡片底色从标题区顶端一直铺到底。
    private func updateHeaderPosition() {
        let offsetY = collectionView.contentOffset.y
        let headerY = max(-Metrics.titleAreaHeight, offsetY)
        headerView.frame = CGRect(x: 0, y: headerY, width: metrics.cardWidth, height: Metrics.titleAreaHeight)
        let visibleBottom = offsetY + collectionView.bounds.height
        cardBackgroundView.frame = CGRect(
            x: 0,
            y: headerY,
            width: metrics.cardWidth,
            height: max(0, visibleBottom - headerY) + 400,
        )
    }

    /// 卡片（标题区顶端）现在在屏幕上的 y（含收起时的位移）
    private var visibleCardTop: CGFloat {
        cardClipView.frame.minY + (headerView.frame.minY - collectionView.contentOffset.y)
    }

    /// 从停放位置往下拉了多少（> 0 = 往下拉）
    private var pullDistance: CGFloat {
        -(collectionView.contentOffset.y + collectionView.contentInset.top)
    }

    // MARK: - 键盘

    @objc
    private func keyboardWillChangeFrame(_ notification: Notification) {
        guard isViewLoaded, view.window != nil else { return }
        let userInfo = notification.userInfo ?? [:]
        var overlap: CGFloat = 0
        if
            notification.name != UIResponder.keyboardWillHideNotification,
            let endFrame = (userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        {
            let frameInView = view.convert(endFrame, from: nil)
            overlap = max(0, view.bounds.maxY - frameInView.minY)
        }
        guard overlap != keyboardHeight else { return }
        keyboardHeight = overlap
        let duration = (userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [UIView.AnimationOptions(rawValue: curveRaw << 16), .beginFromCurrentState],
        ) {
            self.layoutCard()
        }
    }

    // MARK: - 动作

    @objc
    private func didTapOutside() {
        guard !isSending else { return }
        cancel()
    }

    private func cancel() {
        view.endEditing(true)
        actions.cancel()
    }

    @objc
    private func didTapActionButton() {
        guard !isSending else { return }
        if selectedIds.isEmpty {
            cancel()
        } else {
            send()
        }
    }

    @objc
    private func didTapShare() {
        actions.share?(shareButton)
    }

    @objc
    private func didTapSearch() {
        beginSearch()
    }

    @objc
    private func didTapSearchCancel() {
        endSearch()
    }

    @objc
    private func searchTextDidChange() {
        let query = searchField.text ?? ""
        searchQuery = query
        if query.strippedOrNil == nil {
            searchResults = .empty
        } else {
            let chats = allTargets
            searchResults = SSKEnvironment.shared.databaseStorageRef.read { tx in
                (try? TellomiForwardTargets.search(query: query, chats: chats, tx: tx)) ?? .empty
            }
        }
        rebuildSections()
        collectionView.reloadData()
    }

    private func beginSearch() {
        guard !isSearching else { return }
        isSearching = true
        searchQuery = ""
        searchResults = .empty
        searchField.text = nil
        titleLabel.isHidden = true
        subtitleLabel.isHidden = true
        searchButton.isHidden = true
        shareButton.isHidden = true
        searchBarView.isHidden = false
        commentBar.isHidden = true
        commentField.resignFirstResponder()
        // 先换数据再排版：排版会按新的分组数取格子
        rebuildSections()
        collectionView.reloadData()
        UIView.animate(withDuration: 0.25) {
            self.layoutCard()
        }
        searchField.becomeFirstResponder()
    }

    private func endSearch() {
        guard isSearching else { return }
        isSearching = false
        searchQuery = ""
        searchResults = .empty
        searchField.text = nil
        titleLabel.isHidden = false
        subtitleLabel.isHidden = false
        searchButton.isHidden = false
        shareButton.isHidden = actions.share == nil
        searchBarView.isHidden = true
        rebuildGridTargets()
        rebuildSections()
        collectionView.reloadData()
        searchField.resignFirstResponder()
        updateSelectionChrome(animated: false)
        UIView.animate(withDuration: 0.25) {
            self.layoutCard()
            // 刚选中的放在「我的收藏」后面，回到网格停放位置让它露出来
            self.collectionView.contentOffset.y = -self.collectionView.contentInset.top
            self.updateHeaderPosition()
        }
    }

    private func didPick(_ target: TellomiForwardTarget, fromSection section: Section) {
        switch section {
        case .grid:
            toggle(target)
        case .recent, .savedMessages, .chats, .contacts, .groups:
            // 搜索里勾选：回到网格，插在「我的收藏」之后并保持选中（F-9）
            let wasSelected = selectedIds.contains(target.id)
            let isNowSelected = toggle(target)
            guard isNowSelected, !wasSelected else {
                collectionView.reloadData()
                return
            }
            if !target.isSavedMessages {
                promotedIds.removeAll { $0 == target.id }
                promotedIds.insert(target.id, at: 0)
            }
            endSearch()
        }
    }

    // MARK: - 发送（F-7 / F-8）

    private func send() {
        view.endEditing(true)
        tryToSend(untrustedThreshold: presentationTime.addingTimeInterval(-OWSIdentityManagerImpl.Constants.defaultUntrustedInterval))
    }

    private func tryToSend(untrustedThreshold: Date) {
        let items = selectedTargets.map(\.item)
        guard !items.isEmpty else { return }

        let addresses: [SignalServiceAddress] = SSKEnvironment.shared.databaseStorageRef.read { tx in
            items.flatMap { item -> [SignalServiceAddress] in
                if let thread = item.getExistingThread(transaction: tx) {
                    return thread.recipientAddresses(with: tx)
                }
                if case .contact(let address) = item.messageRecipient {
                    return [address]
                }
                return []
            }
        }
        // 对方安全码刚变过：先弹 Signal 现有的确认，确认后再从头检查一遍（同上游选择器）
        let newUntrustedThreshold = Date()
        let needsConfirmation = SafetyNumberConfirmationSheet.presentIfNecessary(
            for: addresses,
            from: self,
            confirmationText: SafetyNumberStrings.confirmSendButton,
            untrustedThreshold: untrustedThreshold,
            forceDarkTheme: forceDarkTheme,
        ) { [weak self] didConfirm in
            guard didConfirm else { return }
            self?.tryToSend(untrustedThreshold: newUntrustedThreshold)
        }
        guard !needsConfirmation else { return }

        let comment = commentField.text?.strippedOrNil
        isSending = true
        // 面板立即收起（F-8）；发出去以后由发起方关掉并提示，没发出去就回来
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn]) {
            self.applyHiddenState()
        }
        Task { @MainActor in
            let didSend = await self.actions.send(items, comment)
            guard !didSend else { return }
            self.isSending = false
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: []) {
                self.applyShownState()
            }
        }
    }

    // MARK: - 进出场

    fileprivate func applyHiddenState() {
        // 按整屏高度移出：之后标题区若再挪动（排版、键盘收起）也还在屏幕外
        let distance = view.bounds.height
        dimView.alpha = 0
        cardClipView.transform = CGAffineTransform(translationX: 0, y: distance)
        actionButton.transform = CGAffineTransform(translationX: 0, y: distance)
    }

    fileprivate func applyShownState() {
        dimView.alpha = 1
        cardClipView.transform = .identity
        actionButton.transform = .identity
    }

    // MARK: - 文案

    enum Strings {
        static var chooseChats: String {
            OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SUBTITLE", comment: "Tellomi: subtitle of the forward grid before any chat is selected.")
        }

        static var nameSeparator: String {
            OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_NAME_SEPARATOR", comment: "Tellomi: separator between selected chat names in the forward grid subtitle.")
        }

        static var commentPlaceholder: String {
            OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_COMMENT_PLACEHOLDER", comment: "Tellomi: placeholder of the message field that is sent before the forwarded content.")
        }

        static var shareToOtherApps: String {
            OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SHARE_TO_OTHER_APPS", comment: "Tellomi: accessibility label of the share button in the forward grid.")
        }

        static var selectionLimitFormat: String {
            OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SELECTION_LIMIT_%d", comment: "Tellomi: toast when trying to select more chats than allowed. Embeds {{the limit}}.")
        }

        static var recentContacts: String {
            OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SECTION_RECENT", comment: "Tellomi: section title of recent contacts in forward search.")
        }

        static var sectionChats: String {
            OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SECTION_CHATS", comment: "Tellomi: section title of matching chats in forward search.")
        }

        static var sectionContacts: String {
            OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SECTION_CONTACTS", comment: "Tellomi: section title of matching contacts in forward search.")
        }

        static var sectionGroups: String {
            OWSLocalizedString("FORWARD_MESSAGE_TELLOMI_GRID_SECTION_GROUPS", comment: "Tellomi: section title of matching groups in forward search.")
        }
    }
}

// MARK: - UICollectionViewDataSource / Delegate

extension TellomiForwardGridViewController: UICollectionViewDataSource, UICollectionViewDelegate {

    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        section < sections.count ? sections[section].1.count : 0
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TellomiForwardGridCell.reuseIdentifier, for: indexPath)
        if let cell = cell as? TellomiForwardGridCell, let target = target(at: indexPath) {
            cell.configure(target: target, isChosen: selectedIds.contains(target.id))
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath,
    ) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: TellomiForwardSectionHeader.reuseIdentifier,
            for: indexPath,
        )
        if let header = header as? TellomiForwardSectionHeader, indexPath.section < sections.count {
            header.label.text = sectionTitle(sections[indexPath.section].0)
        }
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard !isSending, let target = target(at: indexPath) else { return }
        didPick(target, fromSection: sections[indexPath.section].0)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView else { return }
        updateHeaderPosition()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>,
    ) {
        guard scrollView === collectionView, !isSearching, !isSending else { return }
        // 标题区往下拉超过 30 pt 松手 = 关闭（F-4）
        if pullDistance > Metrics.dismissPullDistance {
            isDismissingByPull = true
            targetContentOffset.pointee = scrollView.contentOffset
            cancel()
        }
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TellomiForwardGridViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 网格滚动视图上方的透明部分也算「压暗处」
        guard gestureRecognizer.view === collectionView else { return true }
        let location = gestureRecognizer.location(in: collectionView)
        return location.y < headerView.frame.minY
    }
}

// MARK: - UITextFieldDelegate

extension TellomiForwardGridViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === commentField {
            didTapActionButton()
        } else {
            textField.resignFirstResponder()
        }
        return false
    }
}

// MARK: - 进出场动画

extension TellomiForwardGridViewController: UIViewControllerTransitioningDelegate {
    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController,
    ) -> UIViewControllerAnimatedTransitioning? {
        TellomiForwardGridTransition(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        TellomiForwardGridTransition(isPresenting: false)
    }
}

private final class TellomiForwardGridTransition: NSObject, UIViewControllerAnimatedTransitioning {
    private let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        isPresenting ? 0.4 : 0.25
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let key: UITransitionContextViewControllerKey = isPresenting ? .to : .from
        guard let grid = transitionContext.viewController(forKey: key) as? TellomiForwardGridViewController else {
            transitionContext.completeTransition(false)
            return
        }
        let duration = transitionDuration(using: transitionContext)
        if isPresenting {
            let containerView = transitionContext.containerView
            grid.view.frame = transitionContext.finalFrame(for: grid)
            containerView.addSubview(grid.view)
            grid.view.layoutIfNeeded()
            UIView.performWithoutAnimation {
                grid.applyHiddenState()
            }
            UIView.animate(
                withDuration: duration,
                delay: 0,
                usingSpringWithDamping: 1,
                initialSpringVelocity: 0,
                options: [.allowUserInteraction],
                animations: { grid.applyShownState() },
                completion: { _ in transitionContext.completeTransition(!transitionContext.transitionWasCancelled) },
            )
        } else {
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: [.curveEaseIn],
                animations: { grid.applyHiddenState() },
                completion: { _ in
                    if !transitionContext.transitionWasCancelled {
                        grid.view.removeFromSuperview()
                    }
                    transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                },
            )
        }
    }
}

// MARK: - 用例

extension TellomiForwardGridViewController {
    var gridTargetIdsForTesting: [String] { gridTargets.map(\.id) }
    var gridTargetNamesForTesting: [String] { gridTargets.map(\.shortName) }
    var selectedIdsForTesting: [String] { selectedIds }
    var subtitleForTesting: String? { subtitleLabel.text }
    var actionTitleForTesting: String? { actionTitleLabel.text }
    var badgeTextForTesting: String? { badgeView.isHidden ? nil : badgeLabel.text }
    var isCommentBarVisibleForTesting: Bool { !commentBar.isHidden }
    var isShareButtonVisibleForTesting: Bool { !shareButton.isHidden }
    var isSearchingForTesting: Bool { isSearching }
    var metricsForTesting: Metrics { metrics }
    var cardFrameForTesting: CGRect { restingCardFrame }
    var actionButtonFrameForTesting: CGRect { actionButton.frame }
    var visibleCardTopForTesting: CGFloat { visibleCardTop }
    var collectionViewForTesting: UICollectionView { collectionView }
    var dimAlphaForTesting: CGFloat { dimView.alpha }
    var isNoResultsVisibleForTesting: Bool { !emptyResultsLabel.isHidden }
    var noResultsTextForTesting: String? { emptyResultsLabel.text }

    var searchSectionTitlesForTesting: [String?] { sections.map { sectionTitle($0.0) } }
    var searchSectionIdsForTesting: [[String]] { sections.map { $0.1.map(\.id) } }

    /// 按 id 点一格（走集合视图的选中回调，与手指点格子同一条路）
    func tapTargetForTesting(id: String) {
        for (sectionIndex, section) in sections.enumerated() {
            if let itemIndex = section.1.firstIndex(where: { $0.id == id }) {
                let indexPath = IndexPath(item: itemIndex, section: sectionIndex)
                collectionView.delegate?.collectionView?(collectionView, didSelectItemAt: indexPath)
                return
            }
        }
        owsFailDebug("no such target \(id)")
    }

    func tapActionButtonForTesting() { actionButton.sendActions(for: .touchUpInside) }
    func tapSearchButtonForTesting() { searchButton.sendActions(for: .touchUpInside) }
    func tapSearchCancelForTesting() { searchCancelButton.sendActions(for: .touchUpInside) }
    func tapShareButtonForTesting() { shareButton.sendActions(for: .touchUpInside) }

    /// 点压暗处（压暗层上的点按手势调的就是它）
    func tapDimForTesting() {
        didTapOutside()
    }

    func typeSearchForTesting(_ text: String) {
        searchField.text = text
        searchField.sendActions(for: .editingChanged)
    }

    func typeCommentForTesting(_ text: String) {
        commentField.text = text
        commentField.sendActions(for: .editingChanged)
    }

    /// 模拟手指把标题区往下拉 `distance` 后松手
    func pullDownAndReleaseForTesting(distance: CGFloat) {
        let restingOffset = -collectionView.contentInset.top
        collectionView.contentOffset.y = restingOffset - distance
        var target = collectionView.contentOffset
        scrollViewWillEndDragging(collectionView, withVelocity: .zero, targetContentOffset: &target)
    }

    /// 模拟上拉网格 `distance`（同手指：最多拉到内容底）
    func scrollUpForTesting(distance: CGFloat) {
        collectionView.layoutIfNeeded()
        let maxOffset = max(
            -collectionView.contentInset.top,
            collectionView.contentSize.height + collectionView.contentInset.bottom - collectionView.bounds.height,
        )
        collectionView.contentOffset.y = min(-collectionView.contentInset.top + distance, maxOffset)
    }

    var headerFrameInCardForTesting: CGRect {
        headerView.frame.offsetBy(dx: 0, dy: -collectionView.contentOffset.y)
    }

    /// 搜索框（圆角底）在窗口里的位置
    var searchFieldFrameInWindowForTesting: CGRect {
        searchFieldBackground.convert(searchFieldBackground.bounds, to: nil)
    }

    var isSearchFieldFirstResponderForTesting: Bool { searchField.isFirstResponder }
}
