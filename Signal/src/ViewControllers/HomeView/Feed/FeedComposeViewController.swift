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
/// 话题、投票、评论权限在后面的 PR 加；没做的入口不画。发出去之后带着服务端给的 `state` 关掉，
/// 动态页据此提示「已发布」或「审核中」（R-2.2）。
final class FeedComposeViewController: OWSViewController {

    /// 字数剩这么多时开始显示计数（Threads 也是快到上限才显示）。
    static let counterVisibleRemaining = 50
    static let thumbnailSize: CGFloat = 96

    private let source: FeedSource
    private let onPublished: (String) -> Void

    /// 这条草稿的去重号（契约 7.2 `client_nonce`）：点了发布、网络断了再点，服务端只收一次。
    let clientNonce = UUID().uuidString

    private(set) var draft = FeedDraft()
    private(set) var limits = FeedLimits()
    private(set) var minorMode = false
    private(set) var isPublishing = false

    private let kindSwitch = FeedKindSwitch()
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

    init(source: FeedSource, onPublished: @escaping (String) -> Void) {
        self.source = source
        self.onPublished = onPublished
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.Signal.background

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(named: "x"),
            primaryAction: UIAction { [weak self] _ in self?.requestClose() },
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = CommonStrings.dismissButton
        navigationItem.titleView = kindSwitch
        navigationItem.rightBarButtonItem = publishButton
        kindSwitch.onSelect = { [weak self] kind in self?.setKind(kind) }

        buildLayout()
        presentationController?.delegate = self
        render()

        Task { [weak self] in
            guard let self else { return }
            do {
                let config = try await self.source.config()
                self.limits = config.limits
                self.minorMode = config.minorMode
                if self.draft.isEmpty {
                    self.draft.visibility = FeedVisibility.defaultValue(minorMode: config.minorMode)
                }
                self.render()
            } catch {
                Logger.warn("feed compose config failed, using defaults: \(error)")
            }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if draft.kind == .article, draft.title.isEmpty {
            titleField.becomeFirstResponder()
        } else {
            textView.becomeFirstResponder()
        }
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
        return draft.problem(limits: limits, minorMode: minorMode)
    }

    var canAddImages: Bool {
        return draft.kind == .post && draft.images.count < limits.postImages
    }

    private func render() {
        guard isViewLoaded else { return }
        kindSwitch.selected = draft.kind

        titleField.isHidden = draft.kind != .article
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
        photoButton.isHidden = draft.kind != .post
        photoButton.isEnabled = canAddImages

        visibilityButton.configuration?.title = draft.visibility.title
        visibilityButton.menu = visibilityMenu()

        let remaining = draft.textLimit(limits) - draft.textLength
        counterLabel.isHidden = remaining > Self.counterVisibleRemaining
        counterLabel.text = OWSFormat.formatInt(remaining)
        counterLabel.textColor = remaining < 0 ? UIColor.Signal.red : UIColor.Signal.secondaryLabel

        publishButton.isEnabled = problem == nil && !isPublishing
        isModalInPresentation = !draft.isEmpty
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

    /// 可见范围五档。「部分可见」「不给谁看」选人组件接上之前不能选；未成年人只有「仅好友 / 仅自己」。
    private func visibilityMenu() -> UIMenu {
        let actions = FeedVisibility.allowed(minorMode: minorMode).map { visibility in
            let enabled = !visibility.needsAudience
            let subtitle = enabled
                ? visibility.subtitle
                : OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_COMING_SOON", comment: "Feed publish page: shown under the two visibility options that need picking people, which is not available yet.")
            let action = UIAction(
                title: visibility.title,
                subtitle: subtitle,
                attributes: enabled ? [] : .disabled,
                state: visibility == draft.visibility ? .on : .off,
            ) { [weak self] _ in
                self?.setVisibility(visibility)
            }
            return action
        }
        let title = minorMode
            ? OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_MINOR_MODE", comment: "Feed publish page: note in minor mode that only friends or yourself can see posts.")
            : OWSLocalizedString("TELLOMI_FEED_COMPOSE_VISIBILITY_TITLE", comment: "Feed publish page: title of the visibility menu.")
        return UIMenu(title: title, options: .singleSelection, children: actions)
    }

    // MARK: - Editing

    func setKind(_ kind: FeedDraftKind) {
        draft.kind = kind
        render()
        if kind == .article, draft.title.isEmpty {
            titleField.becomeFirstResponder()
        }
    }

    func setText(_ text: String) {
        draft.text = text
        render()
    }

    func setTitle(_ title: String) {
        draft.title = title
        render()
    }

    func setVisibility(_ visibility: FeedVisibility) {
        guard FeedVisibility.selectable(minorMode: minorMode).contains(visibility) else { return }
        draft.visibility = visibility
        render()
    }

    /// 加图，超出上限的部分不要（选图器本身也限了张数，这里兜底）。
    func addImages(_ images: [UIImage]) {
        let room = max(limits.postImages - draft.images.count, 0)
        draft.images += images.prefix(room).map { FeedDraftImage(image: $0) }
        render()
    }

    func removeImage(id: String) {
        draft.images.removeAll { $0.id == id }
        render()
    }

    private func titleChanged() {
        draft.title = titleField.text ?? ""
        render()
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
        guard !draft.isEmpty, !isPublishing else {
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

    @objc
    func publish() {
        guard !isPublishing, problem == nil else { return }
        isPublishing = true
        render()
        let draft = self.draft
        Task { [weak self, source, clientNonce] in
            do {
                let response = try await source.publish(draft: draft, clientNonce: clientNonce)
                guard let self else { return }
                self.isPublishing = false
                self.onPublished(response.state)
                self.dismiss(animated: true)
            } catch {
                Logger.warn("feed publish failed: \(error)")
                guard let self else { return }
                self.isPublishing = false
                self.render()
                self.presentToast(text: OWSLocalizedString("TELLOMI_FEED_COMPOSE_PUBLISH_FAILED", comment: "Feed publish page: toast when publishing failed."))
            }
        }
    }
}

extension FeedComposeViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        draft.text = textView.text
        render()
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
