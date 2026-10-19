//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import PhotosUI
import SignalServiceKit
import SignalUI
import UIKit

/// 动态的发布页（`dynamic-feed.md` 第三节第 22、23、39 条）。全屏，从动态页右下角的发布按钮进来。
/// 顶部「动态 / 长文」，正文，图片（最多 10 张），底部可见范围和字数。和 Android `FeedComposeScreen` 同一套行为。
///
/// 草稿、校验、发布 / 编辑请求和失败分类都在 `FeedComposeStore`（有单测）；这个页面只负责画和转交。
/// 「发布页扩展」（`TellomiFeed.isComposeExtrasEnabled`，默认关）打开时多三样：编辑自己 15 分钟内的帖子（`editTarget`）、
/// 长文草稿存在本机并在再次打开时接回来、「只给谁看 / 不给谁看」的选人页。关着时和之前一样：草稿只在内存里，
/// 两档选人的入口显示「还不能选」。发出去之后带着服务端给的 `state` 关掉，
/// 动态页据此提示「已发布」或「审核中」（R-2.2）。
final class FeedComposeViewController: OWSViewController {

    /// 字数剩这么多时开始显示计数（Threads 也是快到上限才显示）。
    static let counterVisibleRemaining = 50
    static let thumbnailSize: CGFloat = 96

    private let source: FeedSource
    private let onPublished: (String) -> Void
    private let store: FeedComposeStore
    private let features: FeedFeatureGate?
    private let audienceCandidates: FeedAudienceCandidateSource?
    private let extrasEnabled: Bool
    private var finished = false
    /// 未成年人时限（I-15）：锁着时发布按钮不能点、导航栏上面一行（`navigationItem.prompt`）说为什么，草稿留在这一页（长文照样存在本机），解锁后接着发。
    /// 发布页也算「在用动态」（计时）。时限关着时是 nil。
    let minorSession: FeedMinorSession?
    private var minorObservation: FeedMinorObservation?

    /// 这条草稿的去重号（契约 7.2 `client_nonce`）：点了发布、网络断了再点，服务端只收一次。
    var clientNonce: String { store.clientNonce }

    var draft: FeedDraft { store.state.draft }
    var limits: FeedLimits { store.state.limits }
    var minorMode: Bool { store.state.minorMode }
    var isPublishing: Bool { store.state.publishing }
    var isEditingPost: Bool { store.state.editing != nil }

    private let kindSwitch = FeedKindSwitch()
    private let editTitleLabel = UILabel()
    private lazy var publishButton = UIBarButtonItem(
        title: OWSLocalizedString("TELLOMI_FEED_COMPOSE_PUBLISH", comment: "Feed publish page: the button that publishes the post."),
        style: .done,
        target: self,
        action: #selector(publish),
    )
    private let scrollView = UIScrollView()
    private let titleField = UITextField()
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let imagesScrollView = UIScrollView()
    private let imagesRow = UIStackView()
    private let photoButton = UIButton(type: .system)
    private let visibilityButton = UIButton(type: .system)
    let counterLabel = UILabel()
    private var bottomBarBottom: NSLayoutConstraint?

    /// - Parameters:
    ///   - editTarget: 编辑这一条（只改正文和长文标题；`FeedEditTarget.of(...)` 给）。nil = 新写一条。
    ///   - articleDrafts: 长文草稿存哪里。nil：扩展开着用本机存储（不进备份），关着只放内存（不会接回来）。
    ///   - features: 问引擎有没有 `audience_tokens`；nil = 不问（两档选人显示「还不能选」）。
    ///   - audienceCandidates: 选人页的候选人来源；nil = 没有（同上）。
    init(
        source: FeedSource,
        editTarget: FeedEditTarget? = nil,
        articleDrafts: FeedArticleDrafts? = nil,
        features: FeedFeatureGate? = nil,
        audienceCandidates: FeedAudienceCandidateSource? = nil,
        extrasEnabled: Bool = TellomiFeed.isComposeExtrasEnabled,
        minorSession: FeedMinorSession? = FeedMinorSession.current,
        onPublished: @escaping (String) -> Void,
    ) {
        self.source = source
        self.onPublished = onPublished
        self.features = features
        self.audienceCandidates = audienceCandidates
        self.extrasEnabled = extrasEnabled
        let drafts: FeedArticleDrafts
        if let articleDrafts {
            drafts = articleDrafts
        } else if extrasEnabled {
            drafts = StoredFeedArticleDrafts(storage: FeedLocalStorages.backupExcluded)
        } else {
            drafts = InMemoryFeedArticleDrafts()
        }
        store = FeedComposeStore(editTarget: editTarget, source: source, articleDrafts: drafts)
        self.minorSession = minorSession
        super.init()
        store.onChange = { [weak self] state in self?.stateChanged(state) }
        if let minorSession {
            store.setMinorLocked(minorSession.isLocked)
            minorObservation = minorSession.observe { [weak self] lock in self?.store.setMinorLocked(lock != nil) }
        }
    }

    /// 动态页和「我的动态」页打开发布页的统一入口：样例数据下（内部开发）接上样例的好友和 `audience_tokens`，
    /// 其余情况两档选人照旧「还不能选」（好友来源还没定，见报告「需要 erel 决定」）。
    static func make(source: FeedSource, editTarget: FeedEditTarget? = nil, onPublished: @escaping (String) -> Void) -> FeedComposeViewController {
        let extras = TellomiFeed.isComposeExtrasEnabled
        let sample = extras && TellomiFeed.isSampleDataEnabled && editTarget == nil
        return FeedComposeViewController(
            source: source,
            editTarget: editTarget,
            features: sample ? StaticFeedFeatureGate([FeedFeature.audienceTokens]) : nil,
            audienceCandidates: sample ? StaticFeedAudienceCandidates(FeedAudienceSamples.candidates()) : nil,
            extrasEnabled: extras,
            onPublished: onPublished,
        )
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Signal.background

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(named: "x"),
            primaryAction: UIAction { [weak self] _ in self?.requestClose() },
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = CommonStrings.dismissButton
        navigationItem.rightBarButtonItem = publishButton
        kindSwitch.onSelect = { [weak self] kind in self?.setKind(kind) }
        editTitleLabel.font = UIFont.dynamicTypeHeadlineClamped.semibold()
        editTitleLabel.textColor = UIColor.Signal.label
        editTitleLabel.adjustsFontSizeToFitWidth = true
        editTitleLabel.minimumScaleFactor = 0.7

        buildLayout()
        presentationController?.delegate = self
        render()

        store.start()
        if let features { store.refreshFeatures(features) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        minorSession?.screenWillAppear(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        minorSession?.screenDidDisappear(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if draft.kind == .article, draft.title.isEmpty {
            titleField.becomeFirstResponder()
        } else {
            textView.becomeFirstResponder()
        }
        consumeNotices(store.state)
    }

    // MARK: - Layout

    private func buildLayout() {
        titleField.font = .dynamicTypeTitle2.semibold()
        titleField.textColor = UIColor.Signal.label
        titleField.placeholder = OWSLocalizedString("TELLOMI_FEED_COMPOSE_TITLE_HINT", comment: "Feed publish page: placeholder of the article title.")
        titleField.addAction(UIAction { [weak self] _ in self?.titleChanged() }, for: .editingChanged)

        textView.font = .dynamicTypeBody
        textView.textColor = UIColor.Signal.label
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.autoSetDimension(.height, toSize: 120, relation: .greaterThanOrEqual)

        placeholderLabel.font = .dynamicTypeBody
        placeholderLabel.textColor = UIColor.Signal.tertiaryLabel
        placeholderLabel.numberOfLines = 0
        textView.addSubview(placeholderLabel)
        placeholderLabel.autoPinEdge(toSuperviewEdge: .top)
        placeholderLabel.autoPinEdge(toSuperviewEdge: .leading)
        placeholderLabel.autoMatch(.width, to: .width, of: textView)

        imagesRow.axis = .horizontal
        imagesRow.spacing = 8
        imagesScrollView.showsHorizontalScrollIndicator = false
        imagesScrollView.addSubview(imagesRow)
        imagesRow.autoPinEdgesToSuperviewEdges()
        imagesRow.autoMatch(.height, to: .height, of: imagesScrollView)
        imagesScrollView.autoSetDimension(.height, toSize: Self.thumbnailSize)

        let column = UIStackView(arrangedSubviews: [titleField, textView, imagesScrollView])
        column.axis = .vertical
        column.spacing = 12
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.addSubview(column)
        column.autoPinEdgesToSuperviewEdges(with: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16))
        column.autoMatch(.width, to: .width, of: scrollView, withOffset: -32)

        photoButton.setImage(UIImage(named: "album-tilt"), for: .normal)
        photoButton.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_COMPOSE_ADD_IMAGES", comment: "Feed publish page: button that adds photos.")
        photoButton.addAction(UIAction { [weak self] _ in self?.pickImages() }, for: .touchUpInside)
        photoButton.autoSetDimensions(to: CGSize(square: 44))

        var visibilityConfig = UIButton.Configuration.plain()
        visibilityConfig.image = UIImage(systemName: "eye")
        visibilityConfig.imagePadding = 6
        visibilityConfig.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
        visibilityConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.dynamicTypeSubheadlineClamped
            return attributes
        }
        visibilityButton.configuration = visibilityConfig
        visibilityButton.showsMenuAsPrimaryAction = true

        counterLabel.font = .dynamicTypeSubheadlineClamped.monospaced()
        counterLabel.textAlignment = .right

        let bottomBar = UIStackView(arrangedSubviews: [photoButton, visibilityButton, UIView.hStretchingSpacer(), counterLabel])
        bottomBar.axis = .horizontal
        bottomBar.alignment = .center
        bottomBar.spacing = 4
        bottomBar.isLayoutMarginsRelativeArrangement = true
        bottomBar.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 16)

        let divider = UIView()
        divider.backgroundColor = UIColor.Signal.opaqueSeparator
        divider.autoSetDimension(.height, toSize: 1 / max(UIScreen.main.scale, 1))

        view.addSubview(scrollView)
        view.addSubview(divider)
        view.addSubview(bottomBar)
        scrollView.autoPinEdge(toSuperviewSafeArea: .top)
        scrollView.autoPinEdge(toSuperviewEdge: .leading)
        scrollView.autoPinEdge(toSuperviewEdge: .trailing)
        scrollView.autoPinEdge(.bottom, to: .top, of: divider)
        divider.autoPinEdge(toSuperviewEdge: .leading)
        divider.autoPinEdge(toSuperviewEdge: .trailing)
        divider.autoPinEdge(.bottom, to: .top, of: bottomBar)
        bottomBar.autoPinEdge(toSuperviewEdge: .leading)
        bottomBar.autoPinEdge(toSuperviewEdge: .trailing)
        // 底栏贴着键盘
        bottomBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
    }

    // MARK: - Rendering

    var problem: FeedDraft.Problem? {
        return store.state.problem
    }

    var canAddImages: Bool {
        return store.state.canAddImages
    }

    /// 发布页现在的样子（哪些控件显示、可见范围每一档能不能选），由 `FeedComposeLayout` 算。
    var layout: FeedComposeLayout {
        return FeedComposeLayout.make(store.state, pickerAvailable: audienceCandidates != nil)
    }

    private func stateChanged(_ state: FeedComposeState) {
        render()
        consumeNotices(state)
    }

    private func render() {
        guard isViewLoaded else { return }
        let layout = self.layout
        switch layout.title {
        case .kindSwitch:
            navigationItem.titleView = kindSwitch
        case .editPost:
            editTitleLabel.text = OWSLocalizedString("TELLOMI_FEED_COMPOSE_EDIT_POST", comment: "Feed publish page: title when editing a post that was just published.")
            navigationItem.titleView = editTitleLabel
        case .editArticle:
            editTitleLabel.text = OWSLocalizedString("TELLOMI_FEED_COMPOSE_EDIT_ARTICLE", comment: "Feed publish page: title when editing an article that was just published.")
            navigationItem.titleView = editTitleLabel
        }
        publishButton.title = layout.publishButton == .save
            ? OWSLocalizedString("TELLOMI_FEED_COMPOSE_SAVE", comment: "Feed publish page: the button that saves the edit of a published post.")
            : OWSLocalizedString("TELLOMI_FEED_COMPOSE_PUBLISH", comment: "Feed publish page: the button that publishes the post.")
        kindSwitch.selected = draft.kind

        titleField.isHidden = !layout.showsTitleField
        if titleField.text != draft.title {
            titleField.text = draft.title
        }
        if textView.text != draft.text {
            textView.text = draft.text
        }
        placeholderLabel.text = draft.kind == .article
            ? OWSLocalizedString("TELLOMI_FEED_COMPOSE_ARTICLE_HINT", comment: "Feed publish page: placeholder of the article body.")
            : OWSLocalizedString("TELLOMI_FEED_COMPOSE_POST_HINT", comment: "Feed publish page: placeholder of the post text.")
        placeholderLabel.isHidden = !draft.text.isEmpty

        renderImages()
        photoButton.isHidden = !layout.showsPhotoButton
        photoButton.isEnabled = canAddImages

        visibilityButton.isHidden = !layout.showsVisibilityButton
        visibilityButton.configuration?.title = visibilityButtonTitle(layout)
        visibilityButton.menu = visibilityMenu(layout)

        let remaining = draft.textLimit(limits) - draft.textLength
        counterLabel.isHidden = remaining > Self.counterVisibleRemaining
        counterLabel.text = OWSFormat.formatInt(remaining)
        counterLabel.textColor = remaining < 0 ? UIColor.Signal.red : UIColor.Signal.secondaryLabel

        publishButton.isEnabled = store.state.canPublish
        // 锁着：导航栏上面一行写原因（夜间 / 当日用满的标题），解锁就拿掉
        let minorLock = store.state.minorLocked ? minorSession?.lock : nil
        let prompt = minorLock.map { FeedMinorLockView.title($0) }
        if navigationItem.prompt != prompt { navigationItem.prompt = prompt }
        isModalInPresentation = needsCloseConfirmation
    }

    /// 关页面要不要先问：扩展关着，写了东西就问；开着，自动存在本机的长文不问（下滑就是「留着草稿」），编辑只在改过之后问。
    private var needsCloseConfirmation: Bool {
        return extrasEnabled ? store.state.hasUnsavedChanges : !draft.isEmpty
    }

    private func renderImages() {
        imagesRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let images = draft.attachedImages
        imagesScrollView.isHidden = images.isEmpty
        for item in images {
            imagesRow.addArrangedSubview(thumbnail(for: item))
        }
        if !images.isEmpty, canAddImages {
            let add = UIButton(type: .system)
            add.backgroundColor = UIColor.Signal.secondaryFill
            add.layer.cornerRadius = 10
            add.setImage(UIImage(named: "plus"), for: .normal)
            add.tintColor = UIColor.Signal.secondaryLabel
            add.accessibilityLabel = OWSLocalizedString("TELLOMI_FEED_COMPOSE_ADD_IMAGES", comment: "Feed publish page: button that adds photos.")
            add.addAction(UIAction { [weak self] _ in self?.pickImages() }, for: .touchUpInside)
            add.autoSetDimensions(to: CGSize(square: Self.thumbnailSize))
            imagesRow.addArrangedSubview(add)
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
        let id = item.id
        remove.addAction(UIAction { [weak self] _ in self?.removeImage(id: id) }, for: .touchUpInside)
        imageView.addSubview(remove)
        remove.autoSetDimensions(to: CGSize(square: 24))
        remove.autoPinEdge(toSuperviewEdge: .top, withInset: 4)
        remove.autoPinEdge(toSuperviewEdge: .trailing, withInset: 4)
        return imageView
    }

    /// 按钮上的字：选了人的两档带人数（「只给部分人 · 3 人」）。
    private func visibilityButtonTitle(_ layout: FeedComposeLayout) -> String {
        let title = draft.visibility.title
        guard let option = layout.visibilityOptions.first(where: \.selected),
              case .picksPeople(let count) = option.availability, count > 0 else { return title }
        return String(
            format: OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_WITH_COUNT", comment: "Feed publish page: visibility button when people were picked. Embeds {{visibility name}} and {{number of people, e.g. '3 people'}}."),
            title,
            Self.peopleText(count),
        )
    }

    static func peopleText(_ count: Int) -> String {
        if count == 1 {
            return OWSLocalizedString("TELLOMI_FEED_COMPOSE_PEOPLE_ONE", comment: "Feed publish page: one person was picked for the visibility.")
        }
        return String(
            format: OWSLocalizedString("TELLOMI_FEED_COMPOSE_PEOPLE_MANY", comment: "Feed publish page: several people were picked for the visibility. Embeds {{number of people}}."),
            OWSFormat.formatInt(count),
        )
    }

    /// 可见范围五档。「只给部分人」「不给谁看」要选人：有候选人来源和 `audience_tokens` 时点了进选人页，否则显示「还不能选」；
    /// 未成年人只有「仅好友 / 仅自己」。
    private func visibilityMenu(_ layout: FeedComposeLayout) -> UIMenu {
        let actions = layout.visibilityOptions.map { option -> UIAction in
            let visibility = option.visibility
            let enabled: Bool
            let subtitle: String
            switch option.availability {
            case .available:
                enabled = true
                subtitle = visibility.subtitle
            case .picksPeople(let count):
                enabled = true
                subtitle = count > 0
                    ? Self.peopleText(count)
                    : OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_PICK_PEOPLE", comment: "Feed publish page: shown under the two visibility options that need picking people, before anyone was picked.")
            case .comingSoon:
                enabled = false
                subtitle = OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_COMING_SOON", comment: "Feed publish page: shown under the two visibility options that need picking people, which is not available yet.")
            }
            return UIAction(
                title: visibility.title,
                subtitle: subtitle,
                attributes: enabled ? [] : .disabled,
                state: option.selected ? .on : .off,
            ) { [weak self] _ in
                if visibility.needsAudience {
                    self?.presentAudiencePicker(for: visibility)
                } else {
                    self?.setVisibility(visibility)
                }
            }
        }
        let title = minorMode
            ? OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_MINOR_MODE", comment: "Feed publish page: note in minor mode that only friends or yourself can see posts.")
            : OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_TITLE", comment: "Feed publish page: title of the visibility menu.")
        return UIMenu(title: title, options: .singleSelection, children: actions)
    }

    private func presentAudiencePicker(for visibility: FeedVisibility) {
        guard let audienceCandidates, !isEditingPost, visibility.needsAudience else { return }
        let current = draft.visibility == visibility ? draft.audience : []
        let picker = FeedAudiencePickerViewController(visibility: visibility, preselected: current, source: audienceCandidates) { [weak self] members in
            self?.store.onAudiencePicked(visibility, members)
        }
        present(OWSNavigationController(rootViewController: picker), animated: true)
    }

    // MARK: - Editing

    func setKind(_ kind: FeedDraftKind) {
        store.onKindChanged(kind)
        if draft.kind == .article, draft.title.isEmpty {
            titleField.becomeFirstResponder()
        }
    }

    func setText(_ text: String) {
        store.onTextChanged(text)
    }

    func setTitle(_ title: String) {
        store.onTitleChanged(title)
    }

    func setVisibility(_ visibility: FeedVisibility) {
        store.onVisibilityChanged(visibility)
    }

    /// 加图，超出上限的部分不要（选图器本身也限了张数，store 里兜底）。
    func addImages(_ images: [UIImage]) {
        store.onImagesPicked(images.map { FeedDraftImage(image: $0) })
    }

    func removeImage(id: String) {
        store.onImageRemoved(id: id)
    }

    /// 标题超过 100 个字时剪回 100（拼音输入中先放行，拼完再剪），和 Android 一致。
    private func titleChanged() {
        store.onTitleChanged(titleField.text ?? "", composing: titleField.markedTextRange != nil)
    }

    private func pickImages() {
        guard canAddImages else { return }
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = limits.postImages - draft.images.count
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: - Close / publish

    private func requestClose() {
        guard !isPublishing else {
            dismiss(animated: true)
            return
        }
        if extrasEnabled && layout.showsDiscardDraft {
            presentDraftSheet()
            return
        }
        guard needsCloseConfirmation else {
            dismiss(animated: true)
            return
        }
        let sheet = ActionSheetController(
            title: OWSLocalizedString("TELLOMI_FEED_COMPOSE_DISCARD_TITLE", comment: "Feed publish page: confirmation title when closing with something written."),
            message: OWSLocalizedString("TELLOMI_FEED_COMPOSE_DISCARD_BODY", comment: "Feed publish page: confirmation body when closing with something written."),
        )
        sheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("TELLOMI_FEED_COMPOSE_DISCARD", comment: "Feed publish page: button that throws away what was written."),
            style: .destructive,
        ) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        sheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("TELLOMI_FEED_COMPOSE_KEEP_EDITING", comment: "Feed publish page: button that goes back to writing."),
            style: .cancel,
        ))
        presentActionSheet(sheet)
    }

    /// 新写的长文有内容时点关闭：留着草稿（已经自动存在本机了）/ 放弃草稿 / 继续写。
    private func presentDraftSheet() {
        let sheet = ActionSheetController(
            title: OWSLocalizedString("TELLOMI_FEED_COMPOSE_DRAFT_TITLE", comment: "Feed publish page: title of the sheet asking what to do with an unfinished article when closing."),
            message: OWSLocalizedString("TELLOMI_FEED_COMPOSE_DRAFT_BODY", comment: "Feed publish page: body of that sheet; the article is already saved on this phone."),
        )
        sheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("TELLOMI_FEED_COMPOSE_DRAFT_KEEP", comment: "Feed publish page: button that closes the page and keeps the article draft on this phone."),
            style: .default,
        ) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        sheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("TELLOMI_FEED_COMPOSE_DRAFT_DISCARD", comment: "Feed publish page: button that deletes the article draft and closes the page."),
            style: .destructive,
        ) { [weak self] _ in
            self?.store.discardDraft()
            self?.dismiss(animated: true)
        })
        sheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("TELLOMI_FEED_COMPOSE_KEEP_EDITING", comment: "Feed publish page: button that goes back to writing."),
            style: .cancel,
        ))
        presentActionSheet(sheet)
    }

    @objc
    func publish() {
        store.publish()
    }

    /// 一次性的提示：发出去了关页面、失败、过了 15 分钟、还没建主页、接回了上次的长文。
    private func consumeNotices(_ state: FeedComposeState) {
        if let published = state.publishedState, !finished {
            finished = true
            onPublished(published)
            dismiss(animated: true)
            return
        }
        var text: String?
        if state.failed {
            text = state.editing != nil
                ? OWSLocalizedString("TELLOMI_FEED_COMPOSE_EDIT_FAILED", comment: "Feed publish page: toast when saving the edit failed.")
                : OWSLocalizedString("TELLOMI_FEED_COMPOSE_PUBLISH_FAILED", comment: "Feed publish page: toast when publishing failed.")
            store.onFailureShown()
        } else if state.editWindowClosed {
            text = OWSLocalizedString("TELLOMI_FEED_COMPOSE_EDIT_WINDOW_CLOSED", comment: "Feed publish page: toast when the post can't be edited anymore because the editing time is over.")
            store.onFailureShown()
        } else if state.profileRequired {
            text = OWSLocalizedString("TELLOMI_FEED_PROFILE_REQUIRED", comment: "Feed: toast when an action needs a public profile first.")
            store.onProfileRequiredShown()
        } else if state.restoredArticle, viewIfLoaded?.window != nil {
            text = OWSLocalizedString("TELLOMI_FEED_COMPOSE_ARTICLE_RESTORED", comment: "Feed publish page: toast when the unfinished article from last time was picked up again.")
            store.onRestoredArticleShown()
        }
        if let text, viewIfLoaded?.window != nil {
            presentToast(text: text)
        }
    }
}

extension FeedComposeViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        store.onTextChanged(textView.text)
    }
}

extension FeedComposeViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let providers = results.map(\.itemProvider).filter { $0.canLoadObject(ofClass: UIImage.self) }
        guard !providers.isEmpty else { return }
        Task { [weak self] in
            var images = [UIImage]()
            for provider in providers {
                if let image = await Self.loadImage(provider) {
                    images.append(image)
                }
            }
            self?.addImages(images)
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

extension FeedComposeViewController: UIAdaptivePresentationControllerDelegate {
    /// 写了东西时下滑不直接关，先问一句（`isModalInPresentation`）。
    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        requestClose()
    }
}

/// 发布页顶部「动态 / 长文」。
final class FeedKindSwitch: UIView {
    var onSelect: ((FeedDraftKind) -> Void)?
    var selected = FeedDraftKind.post {
        didSet { update() }
    }

    private var buttons = [UIButton]()

    init() {
        super.init(frame: .zero)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 4
        addSubview(stack)
        stack.autoPinEdgesToSuperviewEdges()
        for kind in FeedDraftKind.allCases {
            var config = UIButton.Configuration.plain()
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
            let button = UIButton(configuration: config)
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(kind) }, for: .touchUpInside)
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func update() {
        for (button, kind) in zip(buttons, FeedDraftKind.allCases) {
            let isSelected = kind == selected
            button.configuration?.attributedTitle = AttributedString(kind.title, attributes: AttributeContainer([
                .font: isSelected ? UIFont.dynamicTypeHeadlineClamped.semibold() : UIFont.dynamicTypeHeadlineClamped,
                .foregroundColor: isSelected ? UIColor.Signal.label : UIColor.Signal.secondaryLabel,
            ]))
            button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        }
        invalidateIntrinsicContentSize()
    }

    /// 按粗体算宽度，切换选中时不跳。
    override var intrinsicContentSize: CGSize {
        let font = UIFont.dynamicTypeHeadlineClamped.semibold()
        let width = FeedDraftKind.allCases.reduce(CGFloat(4)) { total, kind in
            total + (kind.title as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 24
        }
        return CGSize(width: width, height: 44)
    }
}
