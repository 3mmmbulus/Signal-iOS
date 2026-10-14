//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import Photos
import SignalServiceKit
import SignalUI
import UIKit.UIGestureRecognizerSubclass

protocol TellomiPhotoPickerDelegate: AnyObject {
    /// ✕（有选中时先确认）。
    func photoPickerDidCancel(_ picker: TellomiPhotoPickerViewController)

    /// 点了「最近」第一格的相机（有选中时先确认）：打开相机。
    func photoPickerDidRequestCamera(_ picker: TellomiPhotoPickerViewController)

    /// 发送：网格里直接发（P-10）、「···」里立即发（P-5），或从上游预览 / 编辑页发。
    /// 附件按勾的顺序；画质只管这一次（D9）；`separately` 时一张一条、说明挂最后一条。发完由接收方把面板收起。
    /// `captionAboveMedia`（#1263，ADR-0068 §4.7）：说明文字画在媒体上方（「···」里切的）。
    func photoPicker(
        _ picker: TellomiPhotoPickerViewController,
        send approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
        separately: Bool,
        captionAboveMedia: Bool,
    )

    /// 说明和会话输入框是同一段字（同上游的预览页）。
    func photoPicker(_ picker: TellomiPhotoPickerViewController, didChangeMessageBody messageBody: MessageBody?)

    /// Tellomi（#1115）：附件 Sheet 底部 dock 点了「相册」以外的格子（文件 / 位置 / 投票 / 联系人 / GIF）。接收方先收起 Sheet，再打开对应的页面。
    func photoPicker(_ picker: TellomiPhotoPickerViewController, didSelectDockItem item: TellomiAttachmentDockItem)

    /// Tellomi（#1115）：没有照片权限时，占位里点了「照片」：用系统选择器选（不要照片权限）。接收方先收起 Sheet，再弹系统选择器。
    /// 已发布的《系统权限调用清单》TLM-LEGAL-PERMISSIONS-CN 1.0.2 §7.2 承诺了这个入口，所以不给默认实现，接收方必须接上。
    func photoPickerDidRequestSystemPicker(_ picker: TellomiPhotoPickerViewController)
}

extension TellomiPhotoPickerDelegate {
    func photoPicker(_ picker: TellomiPhotoPickerViewController, didSelectDockItem item: TellomiAttachmentDockItem) {}
}

/// Tellomi（tellomi/tellomi#1261，需求 docs/product/specs/media-album-forward-picker.md 第三节，照 Telegram 选图面板）：
/// 会话「+ → 照片」打开的选图网格，替换上游直接弹出的系统 PHPickerViewController。
///
/// - 顶栏（P-1、P-2）：左 ✕；一有选中，✕ 右边出现强调色胶囊「✓N」（高 44、数字等宽，缩放 + 淡入；照 Telegram `SelectedButtonNode`）；
///   中间「最近 ⌄」换相册；一有选中，右边出现「···」（P-5：以高清 / 标准质量发送、单独发送，点了立即发出）。
///   点「✓N」切到「只看已选」（P-3，`TellomiPhotoPickerSelectedView`）：✕ 变返回、「✓N」与「最近 ⌄」隐藏；
///   在那里取消的弹「已取消选择 N 张 · 撤销」（4 秒），全部取消自动回网格。
/// - 网格（P-8）：竖屏 3 列、横屏 5 列、间距 1、正方形（`TellomiPhotoPickerGridLayout`）；编号勾、视频时长见 `TellomiPhotoPickerCell`；
///   「最近」里左上角是一格宽、两行高的相机实时取景（`TellomiPhotoPickerCamera`），点了打开相机；
///   横着滑过格子连续多选（照 Telegram `MediaPickerGridSelectionGesture` 的机制，见 `TellomiSwipeSelectGestureRecognizer`）。
/// - 受限访问横幅（P-7）：「你已限制 Tellomi 访问照片。」+「管理」（选择更多照片… / 前往设置），在网格里、跟着网格滚走。
/// - 底部（P-9、P-10）：一有选中就出现「添加说明…」+ 表情键 + 发送；会话输入框里已打的字带过来；在网格里直接发，不必经过预览页。
///   表情键照 Telegram `AttachmentTextInputPanelNode`：说明框右下角笑脸 ↔ 键盘，切的是说明框的 inputView（`TellomiCaptionEmojiKeyboard`）。
/// - 上限（P-11）：一次最多 32 张，超出提示「一次最多选 32 张」。
///
/// Telegram 的实现只读机制、一行都没搬（GPLv2）。
final class TellomiPhotoPickerViewController: OWSViewController, UICollectionViewDataSource, UICollectionViewDelegate,
    BodyRangesTextViewDelegate, AttachmentApprovalViewControllerDelegate, UIAdaptivePresentationControllerDelegate
{

    private enum Metrics {
        static let topBarHeight: CGFloat = 56
        static let roundButtonSize: CGFloat = 44
        static let countPillHeight: CGFloat = 44
        static let gridSpacing: CGFloat = 1
        static let bannerHeight: CGFloat = 56
        static let captionMinHeight: CGFloat = 40
        static let captionMaxHeight: CGFloat = 110
        static let captionEmojiButtonSize: CGFloat = 32
    }

    /// P-5 的「···」里有哪几项。
    enum MoreMenuItem: Equatable {
        /// #1263：以文件发送（多张时「以文件发送（N 个）」）。
        case sendAsFile
        case sendHighQuality
        case sendStandardQuality
        case sendSeparately
        /// M-2（#1263，ADR-0068 §4.7）：说明文字上移 / 下移（开关，不发送）。
        case moveCaptionUp
        case moveCaptionDown

        var isToggle: Bool {
            self == .moveCaptionUp || self == .moveCaptionDown
        }
    }

    weak var delegate: TellomiPhotoPickerDelegate?

    /// 相机格打开的相机怎么走（`TellomiPickerCameraRoute`）；相机那边的 delegate 是 weak，由面板留着。
    var cameraRoute: SendMediaNavDelegate?

    private let library: TellomiPhotoPickerLibrary
    private let defaultImageQuality: ImageQuality
    private let canSendSeparately: Bool
    /// #1263：「以文件发送」「说明文字上移 / 下移」只给会话（同「单独发送」，由会话页发）。
    private let canSendAsFile: Bool
    /// M-2（ADR-0068 §4.7）：这一次的说明在媒体上方。只管这一次打开的面板。
    private var isCaptionAboveMedia = false {
        didSet { updateSendMenus() }
    }
    private let hasQuotedReplyDraft: Bool
    private let maxSelection: Int
    let attachmentLimits: OutgoingAttachmentLimits
    private let initialMessageBody: MessageBody?
    /// 会话页：@ 的候选人、上游预览页要的收件人名字等。
    private weak var approvalDataSource: AttachmentApprovalViewControllerDataSource?
    private weak var stickerSheetDelegate: StickerPickerSheetDelegate?

    private var albums = [TellomiPhotoPickerAlbum]()
    private var currentAlbum: TellomiPhotoPickerAlbum?
    private var showsLimitedAccessBanner = false

    /// 勾的顺序就是发出去的顺序。
    private var selectedIds = [String]()
    private var selectedItems = [String: TellomiPhotoPickerItem]()

    /// 进上游预览页时每张附件对应网格里的哪一项：在那里删掉一张，网格里也取消勾选。
    private var editingItems = [(itemId: String, attachment: SignalAttachment)]()
    /// 正开着的上游预览 / 编辑页：它的发送键也挂长按菜单（#1263 P3）。
    private weak var editingApproval: AttachmentApprovalViewController?
    /// E-6：每张照片在上游预览 / 编辑页里的编辑项（裁剪、涂鸦、视频剪辑都在里面）。回到网格再进来、从网格直接发送都用这一份；
    /// 取消选中也留着，再选上时编辑还在（同 Telegram 的编辑上下文）。关掉选图面板就没了。
    private var approvalItems = [String: AttachmentApprovalItem]()

    /// P-3：网格还是「只看已选」。
    enum DisplayMode {
        case all
        case selected
    }

    private(set) var displayMode = DisplayMode.all
    private let chatBackground: UIView?
    private let bubbleColor: ColorOrGradientValue?
    private let camera: TellomiPhotoPickerCamera?
    /// Tellomi（#1115）：从「+」打开时是附件 Sheet 的「相册」页，底部带 dock；空 = 没有 dock（旧的整页打开）。
    private let dockItems: [TellomiAttachmentDockItem]

    /// 「只看已选」里取消的（按取消的先后，带原来的位置）：撤销时倒着放回原位。
    private var undoableDeselections = [(item: TellomiPhotoPickerItem, index: Int)]()
    private var undoTimer: Timer?
    private static let undoDuration: TimeInterval = 4

    init(
        library: TellomiPhotoPickerLibrary,
        initialMessageBody: MessageBody?,
        defaultImageQuality: ImageQuality,
        canSendSeparately: Bool,
        canSendAsFile: Bool = false,
        hasQuotedReplyDraft: Bool,
        attachmentLimits: OutgoingAttachmentLimits,
        approvalDataSource: AttachmentApprovalViewControllerDataSource,
        stickerSheetDelegate: StickerPickerSheetDelegate?,
        chatBackground: UIView? = nil,
        bubbleColor: ColorOrGradientValue? = nil,
        camera: TellomiPhotoPickerCamera? = nil,
        maxSelection: Int = SignalAttachment.maxAttachmentsAllowed,
        dockItems: [TellomiAttachmentDockItem] = [],
    ) {
        self.library = library
        self.initialMessageBody = initialMessageBody
        self.defaultImageQuality = defaultImageQuality
        self.canSendSeparately = canSendSeparately
        self.canSendAsFile = canSendAsFile
        self.hasQuotedReplyDraft = hasQuotedReplyDraft
        self.attachmentLimits = attachmentLimits
        self.approvalDataSource = approvalDataSource
        self.stickerSheetDelegate = stickerSheetDelegate
        self.chatBackground = chatBackground
        self.bubbleColor = bubbleColor
        self.camera = camera
        self.maxSelection = maxSelection
        self.dockItems = dockItems
        super.init()
    }

    // MARK: - Views

    private let topBar = UIView()

    private lazy var closeButton: UIButton = {
        var configuration = UIButton.Configuration.gray()
        configuration.image = Theme.iconImage(.buttonX)
        configuration.baseForegroundColor = .Signal.label
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.didTapClose() })
        button.accessibilityLabel = CommonStrings.dismissButton
        return button
    }()

    private lazy var countPill: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = .Signal.accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.image = Theme.iconImage(.checkmark).withRenderingMode(.alwaysTemplate)
        configuration.imagePadding = 2
        configuration.contentInsets = .init(top: 0, leading: 10, bottom: 0, trailing: 16)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.showSelectedOnly() })
        button.isHidden = true
        return button
    }()

    private lazy var titleButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .Signal.label
        configuration.image = Theme.iconImage(.chevronDown)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 4
        configuration.titleLineBreakMode = .byTruncatingTail
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.albumMenuActions() ?? [])
        }])
        return button
    }()

    private lazy var moreButton: UIButton = {
        var configuration = UIButton.Configuration.gray()
        configuration.image = Theme.iconImage(.buttonMore)
        configuration.baseForegroundColor = .Signal.label
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = OWSLocalizedString("IMAGE_PICKER_TELLOMI_MORE", comment: "Accessibility label for the more-options button in the photo picker.")
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.moreMenuActions() ?? [])
        }])
        button.isHidden = true
        return button
    }()

    private lazy var layout: TellomiPhotoPickerGridLayout = {
        let layout = TellomiPhotoPickerGridLayout()
        layout.spacing = Metrics.gridSpacing
        return layout
    }()

    private lazy var collectionView: UICollectionView = {
        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .Signal.background
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.alwaysBounceVertical = true
        collectionView.register(TellomiPhotoPickerCell.self, forCellWithReuseIdentifier: TellomiPhotoPickerCell.reuseIdentifier)
        collectionView.register(
            TellomiPhotoPickerLimitedAccessHeader.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: TellomiPhotoPickerLimitedAccessHeader.reuseIdentifier,
        )
        collectionView.register(
            TellomiPhotoPickerCameraCell.self,
            forSupplementaryViewOfKind: TellomiPhotoPickerCameraCell.kind,
            withReuseIdentifier: TellomiPhotoPickerCameraCell.reuseIdentifier,
        )
        return collectionView
    }()

    private lazy var swipeSelectGesture: TellomiSwipeSelectGestureRecognizer = {
        let gesture = TellomiSwipeSelectGestureRecognizer()
        gesture.itemAt = { [weak self] point in self?.swipeTarget(at: point) }
        gesture.setSelected = { [weak self] id, selected in self?.setSelection(itemId: id, selected: selected) }
        gesture.setScrollEnabled = { [weak self] enabled in self?.collectionView.isScrollEnabled = enabled }
        return gesture
    }()

    private lazy var selectedView: TellomiPhotoPickerSelectedView = {
        let selectedView = TellomiPhotoPickerSelectedView(library: library, chatBackground: chatBackground, bubbleColor: bubbleColor)
        selectedView.onDeselect = { [weak self] id in self?.deselectInSelectedView(id) }
        selectedView.onOpen = { [weak self] itemId in self?.openSelectionForEditing(startingAt: itemId, tool: nil) }
        selectedView.onReorder = { [weak self] ids in self?.applyReorder(ids) }
        selectedView.isHidden = true
        return selectedView
    }()

    private lazy var undoBar: TellomiPhotoPickerUndoBar = {
        let undoBar = TellomiPhotoPickerUndoBar()
        undoBar.onUndo = { [weak self] in self?.undoDeselections() }
        undoBar.isHidden = true
        return undoBar
    }()

    private let sendBar = UIView()
    private let captionContainer = UIView()
    private let captionTextView = BodyRangesTextView()
    private let captionPlaceholder = UILabel()
    private var captionHeightConstraint: NSLayoutConstraint?

    /// P-9 表情键：说明框用文字键盘还是表情键盘。收起键盘就回到文字（同 Telegram）。
    private enum CaptionInputMode {
        case text
        case emoji
    }

    private var captionInputMode = CaptionInputMode.text

    private lazy var captionEmojiKeyboard: TellomiCaptionEmojiKeyboard = {
        let keyboard = TellomiCaptionEmojiKeyboard()
        keyboard.onSelectEmoji = { [weak self] emoji in
            self?.captionTextView.insertText(emoji)
        }
        keyboard.onDeleteBackward = { [weak self] in
            self?.captionTextView.deleteBackward()
        }
        keyboard.onSwitchToText = { [weak self] in
            self?.setCaptionInputMode(.text)
        }
        return keyboard
    }()

    private lazy var captionEmojiButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.baseForegroundColor = .Signal.secondaryLabel
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.toggleCaptionInputMode()
        })
        return button
    }()

    private lazy var sendButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = .Signal.accent
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.image = Theme.iconImage(.arrowUp)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.send(quality: self.defaultImageQuality, separately: false)
        })
        button.accessibilityLabel = MessageStrings.sendButton
        return button
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .Signal.background

        setUpTopBar()
        setUpCollectionView()
        setUpSelectedView()
        setUpSendBar()
        setUpNoAccessView()
        setUpDock()
        view.addSubview(undoBar)

        library.onChange = { [weak self] in self?.reloadLibrary() }
        reloadLibrary()
        updateSelectionChrome(animated: false)
        presentationController?.delegate = self
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        camera?.stopPreview()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if showsCamera, !collectionView.visibleSupplementaryViews(ofKind: TellomiPhotoPickerCameraCell.kind).isEmpty {
            camera?.startPreview()
        }
    }

    override func viewDidLayoutSubviews() {
        let showsIllustration = view.bounds.width < view.bounds.height
        if noAccessIllustration.isHidden == showsIllustration {
            noAccessIllustration.isHidden = !showsIllustration
        }
        super.viewDidLayoutSubviews()
        updateItemSize()
        // 说明框的高度要按排好之后的真实宽度算（一开始宽度是 0）。
        updateCaptionPlaceholderAndHeight()
        layoutUndoBar()
    }

    private func setUpTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        let leading = UIStackView(arrangedSubviews: [closeButton, countPill])
        leading.axis = .horizontal
        leading.spacing = 8
        leading.alignment = .center

        for subview in [leading, titleButton, moreButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: Metrics.topBarHeight),

            closeButton.widthAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            closeButton.heightAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            countPill.heightAnchor.constraint(equalToConstant: Metrics.countPillHeight),
            leading.leadingAnchor.constraint(equalTo: topBar.layoutMarginsGuide.leadingAnchor),
            leading.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            titleButton.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: 180),

            moreButton.widthAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            moreButton.heightAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            moreButton.trailingAnchor.constraint(equalTo: topBar.layoutMarginsGuide.trailingAnchor),
            moreButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])
    }

    private func setUpCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(collectionView, belowSubview: topBar)
        collectionView.addGestureRecognizer(swipeSelectGesture)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setUpSelectedView() {
        selectedView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(selectedView, belowSubview: topBar)
        NSLayoutConstraint.activate([
            selectedView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            selectedView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectedView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            selectedView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - No photo access (#1115)

    /// 拒绝了照片权限：网格整块换成一句说明 +「设置」（上游附件面板同一句话、同一个按钮），有相机时旁边再给「相机」——
    /// 照 Telegram（没权限时网格换成占位，占位里能去设置、也能直接拍）；相机格这时不在网格里，免得说明压在它上面。
    /// 最前面还有「照片」：用系统选择器选，不要照片权限——已发布的《系统权限调用清单》（TLM-LEGAL-PERMISSIONS-CN 1.0.2 §7.2）
    /// 承诺「拒绝照片读取权限，附件面板仍然提供“全部相册”入口，通过系统选择器完成选择与发送」（Telegram 的占位里没有这一个）。
    private lazy var noAccessSystemPickerButton = Self.noAccessButton(
        title: OWSLocalizedString("ATTACHMENT_KEYBOARD_PHOTOS", comment: "A button to open the photo picker from the Attachment Keyboard"),
    ) { [weak self] in
        guard let self else { return }
        self.delegate?.photoPickerDidRequestSystemPicker(self)
    }

    private lazy var noAccessSettingsButton = Self.noAccessButton(title: CommonStrings.openSystemSettingsButton) {
        UIApplication.shared.openSystemSettings()
    }

    private lazy var noAccessCameraButton = Self.noAccessButton(
        title: OWSLocalizedString("CAMERA_BUTTON_LABEL", comment: "Accessibility label for camera button."),
    ) { [weak self] in
        self?.didTapCamera()
    }

    private static func noAccessButton(title: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.cornerStyle = .capsule
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    /// G-1（tellomi/tellomi#1521）：说明上面一张插画（照 Telegram iOS `MediaPickerPlaceholderNode` / 安卓 `GalleryEmptyView` 的贴纸位置；
    /// 画是 Signal 安卓自己的 `permission_gallery`，和 Tellomi 安卓同一张）。横屏放不下时不显示（同 Telegram iOS：宽大于高时没有图）。
    private let noAccessIllustration: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "tellomi-permission-gallery"))
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = false
        return imageView
    }()

    private lazy var noAccessView: UIView = {
        let label = UILabel()
        label.text = OWSLocalizedString("ATTACHMENT_KEYBOARD_NO_PHOTO_ACCESS", comment: "Text in the attachment keyboard when the user has not granted access to photos.")
        label.font = .dynamicTypeSubheadline
        label.textColor = .Signal.secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0

        let buttons = UIStackView(arrangedSubviews: [noAccessSystemPickerButton, noAccessSettingsButton, noAccessCameraButton])
        buttons.axis = .horizontal
        buttons.spacing = 12

        let stack = UIStackView(arrangedSubviews: [noAccessIllustration, label, buttons])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(20, after: noAccessIllustration)
        stack.isHidden = true
        return stack
    }()

    private func setUpNoAccessView() {
        noAccessView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(noAccessView)
        NSLayoutConstraint.activate([
            noAccessView.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            noAccessView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            noAccessView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Dock (#1115)

    /// 底部 dock：没选照片时在，选了就换成说明 + 发送（同 Telegram：dock 与说明栏占同一个位置）；「只看已选」时也不在。
    private lazy var dock: TellomiAttachmentDock? = {
        guard !dockItems.isEmpty else { return nil }
        let dock = TellomiAttachmentDock(items: dockItems, selectedItem: .gallery)
        dock.onSelect = { [weak self] item in self?.didSelectDockItem(item) }
        return dock
    }()

    private func setUpDock() {
        guard let dock else { return }
        dock.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dock)
        NSLayoutConstraint.activate([
            dock.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: TellomiAttachmentDock.sideMargin),
            dock.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -TellomiAttachmentDock.sideMargin),
            dock.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -TellomiAttachmentDock.bottomMargin),
            dock.heightAnchor.constraint(equalToConstant: TellomiAttachmentDock.height),
        ])
    }

    private var isDockVisible: Bool {
        dock != nil && selectedIds.isEmpty && displayMode == .all
    }

    private func didSelectDockItem(_ item: TellomiAttachmentDockItem) {
        guard item != .gallery else {
            // 重复点「相册」：回到网格最上面并展开到全屏（同 Telegram：重复点当前格 = requestAttachmentMenuExpansion + 回到顶部）
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
            if let sheet = sheetPresentationController, sheet.selectedDetentIdentifier != .large {
                sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
            }
            return
        }
        delegate?.photoPicker(self, didSelectDockItem: item)
    }

    private func setUpSendBar() {
        sendBar.backgroundColor = .Signal.background
        sendBar.translatesAutoresizingMaskIntoConstraints = false
        sendBar.isHidden = true
        view.addSubview(sendBar)

        captionContainer.backgroundColor = .Signal.secondaryFill
        captionContainer.layer.cornerRadius = Metrics.captionMinHeight / 2
        captionContainer.translatesAutoresizingMaskIntoConstraints = false
        sendBar.addSubview(captionContainer)

        captionTextView.bodyRangesDelegate = self
        captionTextView.font = .dynamicTypeBody
        captionTextView.backgroundColor = .clear
        // 右边让出表情键（离框 4、键 32、再空 4）。
        captionTextView.textContainerInset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: Metrics.captionEmojiButtonSize + 8)
        captionTextView.translatesAutoresizingMaskIntoConstraints = false
        captionContainer.addSubview(captionTextView)
        if let initialMessageBody, !initialMessageBody.text.isEmpty {
            captionTextView.setMessageBody(initialMessageBody, txProvider: DependenciesBridge.shared.db.readTxProvider)
        }

        captionPlaceholder.text = OWSLocalizedString("IMAGE_PICKER_TELLOMI_CAPTION_PLACEHOLDER", comment: "Placeholder of the caption field at the bottom of the photo picker.")
        captionPlaceholder.font = .dynamicTypeBody
        captionPlaceholder.textColor = .Signal.secondaryLabel
        captionPlaceholder.isUserInteractionEnabled = false
        captionPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        captionContainer.addSubview(captionPlaceholder)

        updateCaptionEmojiButton()
        captionEmojiButton.translatesAutoresizingMaskIntoConstraints = false
        captionContainer.addSubview(captionEmojiButton)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendBar.addSubview(sendButton)

        let captionHeight = captionTextView.heightAnchor.constraint(equalToConstant: Metrics.captionMinHeight)
        captionHeightConstraint = captionHeight
        // 说明栏的底色铺到屏幕底（盖住 Home 条那一截），输入框跟着键盘走。
        NSLayoutConstraint.activate([
            sendBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sendBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sendBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            captionContainer.topAnchor.constraint(equalTo: sendBar.topAnchor, constant: 10),
            captionContainer.leadingAnchor.constraint(equalTo: sendBar.layoutMarginsGuide.leadingAnchor),
            captionContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -10),
            captionContainer.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),

            captionTextView.topAnchor.constraint(equalTo: captionContainer.topAnchor),
            captionTextView.leadingAnchor.constraint(equalTo: captionContainer.leadingAnchor),
            captionTextView.trailingAnchor.constraint(equalTo: captionContainer.trailingAnchor),
            captionTextView.bottomAnchor.constraint(equalTo: captionContainer.bottomAnchor),
            captionHeight,

            captionPlaceholder.leadingAnchor.constraint(equalTo: captionContainer.leadingAnchor, constant: 17),
            captionPlaceholder.trailingAnchor.constraint(lessThanOrEqualTo: captionEmojiButton.leadingAnchor, constant: -4),
            captionPlaceholder.centerYAnchor.constraint(equalTo: captionContainer.topAnchor, constant: Metrics.captionMinHeight / 2),

            // 多行时贴着最后一行（同 Telegram 的键在输入框右下角）。
            captionEmojiButton.widthAnchor.constraint(equalToConstant: Metrics.captionEmojiButtonSize),
            captionEmojiButton.heightAnchor.constraint(equalToConstant: Metrics.captionEmojiButtonSize),
            captionEmojiButton.trailingAnchor.constraint(equalTo: captionContainer.trailingAnchor, constant: -4),
            captionEmojiButton.bottomAnchor.constraint(equalTo: captionContainer.bottomAnchor, constant: -(Metrics.captionMinHeight - Metrics.captionEmojiButtonSize) / 2),

            sendButton.widthAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            sendButton.heightAnchor.constraint(equalToConstant: Metrics.roundButtonSize),
            sendButton.trailingAnchor.constraint(equalTo: sendBar.layoutMarginsGuide.trailingAnchor),
            sendButton.bottomAnchor.constraint(equalTo: captionContainer.bottomAnchor, constant: 2),
        ])
        updateCaptionPlaceholderAndHeight()
    }

    // MARK: - Library

    private func reloadLibrary() {
        albums = library.albums()
        if let currentAlbum, let refreshed = albums.first(where: { $0.id == currentAlbum.id }) {
            self.currentAlbum = refreshed
        } else {
            currentAlbum = albums.first
        }
        showsLimitedAccessBanner = library.isAccessLimited
        noAccessView.isHidden = !library.isAccessDenied
        noAccessCameraButton.isHidden = (camera?.access ?? .unavailable) == .unavailable
        titleButton.configuration?.title = currentAlbum?.title
        updateGridLayout()
        collectionView.reloadData()
    }

    private func switchAlbum(to album: TellomiPhotoPickerAlbum) {
        guard album.id != currentAlbum?.id else { return }
        currentAlbum = album
        titleButton.configuration?.title = album.title
        updateGridLayout()
        collectionView.reloadData()
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
    }

    private func albumMenuActions() -> [UIMenuElement] {
        albums.map { album in
            let action = UIAction(title: album.title, state: album.id == currentAlbum?.id ? .on : .off) { [weak self] _ in
                self?.switchAlbum(to: album)
            }
            if #available(iOS 16, *) {
                action.subtitle = OWSFormat.formatInt(album.count)
            }
            return action
        }
    }

    // MARK: - Grid

    private var columnCount: Int {
        view.bounds.width > view.bounds.height ? 5 : 3
    }

    /// 相机格只在「最近」里、而且有相机（没被拒）时才有；没有照片权限时网格换成占位，相机在占位的按钮里。
    private var showsCamera: Bool {
        guard let camera, currentAlbum?.isRecents == true, !library.isAccessDenied else { return false }
        return camera.access != .unavailable
    }

    private func updateGridLayout() {
        layout.columns = columnCount
        layout.screenScale = view.window?.screen.scale ?? UIScreen.main.scale
        layout.headerHeight = showsLimitedAccessBanner ? Metrics.bannerHeight : 0
        layout.showsCamera = showsCamera
    }

    private func updateItemSize() {
        updateGridLayout()
    }

    private var thumbnailSize: CGSize {
        let scale = view.window?.screen.scale ?? 3
        let side = max(layout.itemSide, 1)
        return CGSize(width: side * scale, height: side * scale)
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard let currentAlbum else { return 0 }
        return library.itemCount(in: currentAlbum)
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TellomiPhotoPickerCell.reuseIdentifier, for: indexPath)
        guard let cell = cell as? TellomiPhotoPickerCell, let currentAlbum else {
            return cell
        }
        let item = library.item(at: indexPath.item, in: currentAlbum)
        cell.configure(
            item: item,
            selectionNumber: selectionNumber(for: item.id),
            accentColor: .Signal.accent,
            library: library,
            thumbnailSize: thumbnailSize,
        )
        cell.onCheckTapped = { [weak self] in
            self?.toggleSelection(item)
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath,
    ) -> UICollectionReusableView {
        if kind == TellomiPhotoPickerCameraCell.kind {
            let view = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: TellomiPhotoPickerCameraCell.reuseIdentifier, for: indexPath)
            if let cameraCell = view as? TellomiPhotoPickerCameraCell, let camera {
                cameraCell.configure(camera: camera)
                cameraCell.onTap = { [weak self] in self?.didTapCamera() }
            }
            return view
        }
        let header = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: TellomiPhotoPickerLimitedAccessHeader.reuseIdentifier,
            for: indexPath,
        )
        (header as? TellomiPhotoPickerLimitedAccessHeader)?.presentingViewController = self
        return header
    }

    // 相机格露出来才取景，滚走 / 换相册 / 面板收起就停。
    func collectionView(_ collectionView: UICollectionView, willDisplaySupplementaryView view: UICollectionReusableView, forElementKind elementKind: String, at indexPath: IndexPath) {
        if elementKind == TellomiPhotoPickerCameraCell.kind {
            camera?.startPreview()
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplayingSupplementaryView view: UICollectionReusableView, forElementOfKind elementKind: String, at indexPath: IndexPath) {
        if elementKind == TellomiPhotoPickerCameraCell.kind {
            camera?.stopPreview()
        }
    }

    /// 点照片本身（不是勾）：打开整本相册的查看器，从点的那张开始看，不自动选中（V-1）。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard let currentAlbum else { return }
        presentAlbumViewer(album: currentAlbum, startingAt: indexPath.item)
    }

    private func presentAlbumViewer(album: TellomiPhotoPickerAlbum, startingAt index: Int) {
        let viewer = TellomiPhotoPickerAlbumViewer(library: library, album: album, initialIndex: index)
        viewer.selectionNumber = { [weak self] itemId in self?.selectionNumber(for: itemId) }
        viewer.selectedCount = { [weak self] in self?.selectedIds.count ?? 0 }
        viewer.onToggle = { [weak self] item in self?.toggleSelection(item) }
        viewer.onShowSelected = { [weak self, weak viewer] in
            viewer?.dismiss(animated: true) { self?.showSelectedOnly() }
        }
        viewer.onEdit = { [weak self, weak viewer] item, tool in
            viewer?.dismiss(animated: false) { self?.editFromAlbumViewer(item, tool: tool) }
        }
        viewer.onClose = { [weak viewer] in viewer?.dismiss(animated: true) }
        viewer.modalPresentationStyle = .overFullScreen
        present(viewer, animated: true)
    }

    private func editFromAlbumViewer(_ item: TellomiPhotoPickerItem, tool: TellomiApprovalEditTool?) {
        if selectionNumber(for: item.id) == nil {
            guard setSelection(item: item, selected: true) else { return }
        }
        openSelectionForEditing(startingAt: item.id, tool: tool)
    }

    // MARK: - Selection

    private func selectionNumber(for itemId: String) -> Int? {
        selectedIds.firstIndex(of: itemId).map { $0 + 1 }
    }

    private func toggleSelection(_ item: TellomiPhotoPickerItem) {
        setSelection(item: item, selected: selectionNumber(for: item.id) == nil)
    }

    /// 选上或取消一项。选满时提示上限并返回 false。
    @discardableResult
    private func setSelection(item: TellomiPhotoPickerItem, selected: Bool) -> Bool {
        if selected {
            guard selectionNumber(for: item.id) == nil else { return true }
            guard selectedIds.count < maxSelection else {
                showSelectionLimitToast()
                return false
            }
            selectedIds.append(item.id)
            selectedItems[item.id] = item
        } else {
            selectedIds.removeAll { $0 == item.id }
            selectedItems[item.id] = nil
        }
        refreshVisibleSelectionNumbers(animatedItemId: selected ? item.id : nil)
        updateSelectionChrome(animated: true)
        if displayMode == .selected {
            refreshSelectedView(animated: true)
            if selectedIds.isEmpty {
                returnToGridAfterLastDeselection()
            }
        }
        return true
    }

    private func setSelection(itemId: String, selected: Bool) {
        guard let currentAlbum else { return }
        if let item = selectedItems[itemId] {
            setSelection(item: item, selected: selected)
            return
        }
        for indexPath in collectionView.indexPathsForVisibleItems {
            let item = library.item(at: indexPath.item, in: currentAlbum)
            if item.id == itemId {
                setSelection(item: item, selected: selected)
                return
            }
        }
    }

    private func refreshVisibleSelectionNumbers(animatedItemId: String?) {
        for case let cell as TellomiPhotoPickerCell in collectionView.visibleCells {
            guard let itemId = cell.itemId else { continue }
            cell.setSelectionNumber(selectionNumber(for: itemId), accentColor: .Signal.accent, animated: itemId == animatedItemId)
        }
    }

    private func showSelectionLimitToast() {
        let text = String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_AT_MOST_FORMAT", comment: "Toast when trying to select more photos than allowed. Embeds {{ the maximum }}."),
            OWSFormat.formatInt(maxSelection),
        )
        let host: UIView = presentedViewController?.view ?? view
        ToastController(text: text).presentToastView(from: .bottom, of: host, inset: view.safeAreaInsets.bottom + 80)
    }

    /// G-6（tellomi/tellomi#1521）：dock 和说明栏占同一个位置，换的时候照 Telegram `AttachmentPanel.update`：
    /// 选上第一张时 dock 0.1 s 淡出、0.25 s 缩到 0.85，说明栏 0.25 s 淡入、从下面 44 pt 升上来；全部取消时反过来（淡入 / 淡出都是 0.25 s）。
    /// 消失的那一个用截图做动画，本身照旧立刻隐藏，显隐状态和网格的让位不跟着动画走。
    private func animateBottomBarSwap(_ bar: UIView, wasShown: Bool, snapshot: UIView?, fadeOutDuration: TimeInterval, hiddenTransform: CGAffineTransform) {
        let isShown = !bar.isHidden
        guard isShown != wasShown else { return }
        if isShown {
            bar.layer.removeAllAnimations()
            bar.alpha = 0
            bar.transform = hiddenTransform
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
                bar.alpha = 1
                bar.transform = .identity
            }
        } else if let snapshot {
            bar.alpha = 1
            bar.transform = .identity
            snapshot.frame = bar.frame
            snapshot.isUserInteractionEnabled = false
            view.insertSubview(snapshot, aboveSubview: bar)
            bottomBarSnapshots.append(snapshot)
            UIView.animate(withDuration: fadeOutDuration, delay: 0, options: .curveEaseInOut) {
                snapshot.alpha = 0
            }
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
                snapshot.transform = hiddenTransform
            } completion: { [weak self] _ in
                snapshot.removeFromSuperview()
                self?.bottomBarSnapshots.removeAll { $0 === snapshot }
            }
        }
    }

    /// 正在淡出的 dock / 说明栏截图（G-6）。
    private var bottomBarSnapshots = [UIView]()

    /// 「✓N」「···」、底部说明栏跟着选中的数量出现 / 收起。
    private func updateSelectionChrome(animated: Bool) {
        let count = selectedIds.count
        let hasSelection = count > 0

        countPill.configuration?.attributedTitle = AttributedString(
            OWSFormat.formatInt(count),
            attributes: AttributeContainer([.font: UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium)]),
        )
        countPill.accessibilityLabel = String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_SELECTED_FORMAT", comment: "Accessibility label of the selected-count pill in the photo picker. Embeds {{ number selected }}."),
            OWSFormat.formatInt(count),
        )
        isModalInPresentation = hasSelection

        let showMore = hasSelection && !moreMenuItems().isEmpty
        let showPill = hasSelection && displayMode == .all
        let pillAppears = showPill && countPill.isHidden
        // G-6：dock 与说明栏换位前记下谁在，要消失的那一个先截图（隐藏以后就截不到了）。
        let dockWasShown = dock.map { !$0.isHidden } ?? false
        let sendBarWasShown = !sendBar.isHidden
        let dockSnapshot = animated && dockWasShown && !isDockVisible ? dock?.snapshotView(afterScreenUpdates: false) : nil
        let sendBarSnapshot = animated && sendBarWasShown && !hasSelection ? sendBar.snapshotView(afterScreenUpdates: false) : nil
        let changes = {
            self.countPill.isHidden = !showPill
            self.moreButton.isHidden = !showMore
            self.sendBar.isHidden = !hasSelection
            self.dock?.isHidden = !self.isDockVisible
            self.countPill.alpha = showPill ? 1 : 0
            self.countPill.transform = .identity
        }
        if animated {
            if pillAppears {
                countPill.alpha = 0
                countPill.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0, animations: changes)
        } else {
            changes()
        }

        view.layoutIfNeeded()
        if animated {
            if let dock {
                animateBottomBarSwap(dock, wasShown: dockWasShown, snapshot: dockSnapshot, fadeOutDuration: 0.1, hiddenTransform: CGAffineTransform(scaleX: 0.85, y: 0.85))
            }
            animateBottomBarSwap(sendBar, wasShown: sendBarWasShown, snapshot: sendBarSnapshot, fadeOutDuration: 0.25, hiddenTransform: CGAffineTransform(translationX: 0, y: 44))
        }
        // 网格本来就会让出底部安全区，这里只补说明栏高出安全区的那一截；有 dock 时让出 dock（#1115）。
        let dockInset = isDockVisible ? TellomiAttachmentDock.height + TellomiAttachmentDock.bottomMargin : 0
        let bottomInset = hasSelection ? max(0, sendBar.frame.height - view.safeAreaInsets.bottom) : dockInset
        collectionView.contentInset.bottom = bottomInset
        collectionView.verticalScrollIndicatorInsets.bottom = bottomInset
        selectedView.bottomInset = hasSelection ? sendBar.frame.height : view.safeAreaInsets.bottom
        layoutUndoBar()
        updateSendMenus()
    }

    // MARK: - Selected only (P-3)

    /// 点「✓N」：网格换成「只看已选」，✕ 变返回，「✓N」「最近 ⌄」隐藏。
    private func showSelectedOnly() {
        guard !selectedIds.isEmpty, displayMode == .all else { return }
        displayMode = .selected
        refreshSelectedView(animated: false)
        selectedView.isHidden = false
        selectedView.alpha = 0
        UIView.animate(withDuration: 0.25, animations: {
            self.selectedView.alpha = 1
            self.collectionView.alpha = 0
        }, completion: { _ in
            if self.displayMode == .selected {
                self.collectionView.isHidden = true
            }
        })
        updateTopBarForDisplayMode()
        updateSelectionChrome(animated: true)
    }

    /// 返回（或全取消了）：回到网格，编号按新的顺序。
    private func showAll() {
        guard displayMode == .selected else { return }
        displayMode = .all
        collectionView.isHidden = false
        UIView.animate(withDuration: 0.25, animations: {
            self.selectedView.alpha = 0
            self.collectionView.alpha = 1
        }, completion: { _ in
            if self.displayMode == .all {
                self.selectedView.isHidden = true
            }
        })
        refreshVisibleSelectionNumbers(animatedItemId: nil)
        updateTopBarForDisplayMode()
        updateSelectionChrome(animated: true)
    }

    private func updateTopBarForDisplayMode() {
        let isSelected = displayMode == .selected
        closeButton.configuration?.image = isSelected ? UIImage(named: "chevron-left-26") : Theme.iconImage(.buttonX)
        closeButton.accessibilityLabel = isSelected ? CommonStrings.backButton : CommonStrings.dismissButton
        titleButton.isHidden = isSelected
    }

    private func refreshSelectedView(animated: Bool) {
        selectedView.update(
            items: selectedIds.compactMap { selectedItems[$0] },
            caption: messageBodyForSending?.text,
            animated: animated,
        )
    }

    /// 「只看已选」里点了某张的勾：取消它，弹「已取消选择 N 张 · 撤销」。
    private func deselectInSelectedView(_ itemId: String) {
        guard let index = selectedIds.firstIndex(of: itemId), let item = selectedItems[itemId] else { return }
        undoableDeselections.append((item, index))
        setSelection(item: item, selected: false)
        showUndoBar()
    }

    /// 同 Telegram：卡片先淡出，0.3 秒后回网格。
    private func returnToGridAfterLastDeselection() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.selectedIds.isEmpty else { return }
            self.showAll()
        }
    }

    /// 拖动排序：新的顺序就是发出去的顺序。
    private func applyReorder(_ ids: [String]) {
        guard Set(ids) == Set(selectedIds) else { return }
        selectedIds = ids
        refreshVisibleSelectionNumbers(animatedItemId: nil)
    }

    private func showUndoBar() {
        undoBar.count = undoableDeselections.count
        undoTimer?.invalidate()
        undoTimer = Timer.scheduledTimer(withTimeInterval: Self.undoDuration, repeats: false) { [weak self] _ in
            self?.hideUndoBar()
        }
        // 可能正在淡出（上一轮到时间了）：从当前透明度接着淡入。
        if undoBar.isHidden {
            undoBar.isHidden = false
            undoBar.alpha = 0
        }
        layoutUndoBar()
        UIView.animate(withDuration: 0.2, delay: 0, options: .beginFromCurrentState) { self.undoBar.alpha = 1 }
    }

    private func hideUndoBar() {
        undoTimer?.invalidate()
        undoTimer = nil
        undoableDeselections.removeAll()
        guard !undoBar.isHidden else { return }
        UIView.animate(withDuration: 0.2, animations: { self.undoBar.alpha = 0 }, completion: { _ in
            if self.undoableDeselections.isEmpty {
                self.undoBar.isHidden = true
            }
        })
    }

    /// 撤销：倒着把取消的放回原来的位置（选满了就放不回去）。
    private func undoDeselections() {
        for (item, index) in undoableDeselections.reversed() {
            guard selectionNumber(for: item.id) == nil, selectedIds.count < maxSelection else { continue }
            selectedIds.insert(item.id, at: min(index, selectedIds.count))
            selectedItems[item.id] = item
        }
        hideUndoBar()
        refreshVisibleSelectionNumbers(animatedItemId: nil)
        updateSelectionChrome(animated: true)
        if displayMode == .selected {
            refreshSelectedView(animated: true)
        }
    }

    /// 撤销条在说明栏上面；说明栏收起了（全取消）就在屏幕底部。
    private func layoutUndoBar() {
        guard !undoBar.isHidden else { return }
        let margins = view.layoutMargins
        let height = TellomiPhotoPickerUndoBar.height
        let bottom = sendBar.isHidden ? view.safeAreaLayoutGuide.layoutFrame.maxY : sendBar.frame.minY
        undoBar.frame = CGRect(x: margins.left, y: bottom - 8 - height, width: view.bounds.width - margins.left - margins.right, height: height)
    }

    // MARK: - More menu (P-5)

    /// 按这个顺序：「以文件发送」（#1263，会话里、有选中）；已选全是静态图时「以高清质量发送」（默认已是高时换成「以标准质量发送」）；
    /// 已选 ≥ 2 且是单个会话时「单独发送」。网格里没有一次性查看（那在预览页），遮罩那一刀再加「开了遮罩就没有以文件发送」。
    private func moreMenuItems() -> [MoreMenuItem] {
        var items = [MoreMenuItem]()
        if canSendAsFile, !selectedIds.isEmpty {
            items.append(.sendAsFile)
        }
        // V-7 / O4（tellomi/tellomi#1518，取 Telegram 安卓 `ChatAttachAlertPhotoLayout` 的规则：已选数 = `getSelectedPhotosCount()`）：
        // 选的全是静态图才有高清项，里面有视频或动图就没有；裁剪、画过的照片照样算。
        if !selectedItems.isEmpty, selectedItems.values.allSatisfy({ !$0.isVideo && !$0.isAnimatedImage }) {
            items.append(defaultImageQuality == .high ? .sendStandardQuality : .sendHighQuality)
        }
        if selectedIds.count >= 2, canSendSeparately {
            items.append(.sendSeparately)
        }
        // M-2：写了说明才有（同 Telegram iOS `isCaptionAboveMediaAvailable = hasCaption`），放在分隔线下面。
        if canMoveCaption {
            items.append(isCaptionAboveMedia ? .moveCaptionDown : .moveCaptionUp)
        }
        return items
    }

    /// 「说明文字上移 / 下移」现在给不给（「···」和长按发送里同一个条件）：会话里、有选中、写了说明。
    private var canMoveCaption: Bool {
        canSendAsFile && !selectedIds.isEmpty && messageBodyForSending != nil
    }

    // MARK: - Long-press send (#1263 P3, #1519 M-5)

    /// 发送键长按菜单里的项（ADR-0068 §4.7 P3）：照 Telegram iOS `ChatSendMessageContextScreen` 的第一项「说明文字上移 / 下移」（captionPosition），
    /// 条件同「···」里那项。Tellomi iOS 的长按菜单现在只有这一项（定时发送是 M-4，还没做），没有可给的就不挂长按。
    private func sendMenuItems() -> [MoreMenuItem] {
        guard canMoveCaption else { return [] }
        return [isCaptionAboveMedia ? .moveCaptionDown : .moveCaptionUp]
    }

    private func sendPreviewActions() -> [TellomiSendPreviewViewController.Action] {
        sendMenuItems().map { item in
            TellomiSendPreviewViewController.Action(
                title: Self.title(for: item, selectedCount: selectedIds.count),
                image: Self.image(for: item),
                keepsPresented: true,
            ) { [weak self] in
                self?.toggleCaptionFromSendMenu()
            }
        }
    }

    private func toggleCaptionFromSendMenu() {
        isCaptionAboveMedia.toggle()
    }

    /// #1519 M-5：网格的发送键和上游预览 / 编辑页的发送键挂同一个长按：弹「发出去是什么样」的预览和菜单（照 Telegram）。
    /// 预览开着时就地跟着变（说明换位置、菜单换字）。
    private func updateSendMenus() {
        guard isViewLoaded else { return }
        let handler: ((UIButton) -> Void)? = sendMenuItems().isEmpty ? nil : { [weak self] button in
            self?.presentSendPreview(from: button)
        }
        TellomiSendLongPressGestureRecognizer.install(on: sendButton, handler: handler)
        editingApproval?.tellomiSetSendLongPress(handler)
        presentedSendPreview?.update(captionAboveMedia: isCaptionAboveMedia, actions: sendPreviewActions())
    }

    private weak var sendPreview: TellomiSendPreviewViewController?

    /// 正开着的预览（收起了就是 nil）。
    private var presentedSendPreview: TellomiSendPreviewViewController? {
        sendPreview?.presentingViewController == nil ? nil : sendPreview
    }

    private func presentSendPreview(from button: UIButton) {
        let items = selectedIds.compactMap { selectedItems[$0] }
        guard presentedSendPreview == nil, !items.isEmpty, !sendMenuItems().isEmpty else { return }
        let library = self.library
        let tiles: [TellomiSendPreviewViewController.Tile] = items.map { item in
            let aspectRatio: CGFloat = item.pixelSize.height > 0 ? item.pixelSize.width / item.pixelSize.height : 1
            let loadImage: (CGSize, @escaping (UIImage?) -> Void) -> TellomiPhotoPickerRequest? = { size, completion in
                library.requestThumbnail(for: item, targetSize: size, completion: completion)
            }
            return TellomiSendPreviewViewController.Tile(aspectRatio: aspectRatio, loadImage: loadImage)
        }
        // 说明照输入框里看到的样子（@ 的是名字），有没有说明按要发的那份算。
        let caption: String? = messageBodyForSending == nil ? nil : captionTextView.textStorage.string.ows_stripped()
        let onSend: () -> Void = { [weak button] in
            button?.sendActions(for: .primaryActionTriggered)
        }
        let preview = TellomiSendPreviewViewController(
            tiles: tiles,
            caption: caption,
            captionAboveMedia: isCaptionAboveMedia,
            bubbleColor: bubbleColor,
            actions: sendPreviewActions(),
            sourceButton: button,
            onSend: onSend,
        )
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        presenter.present(preview, animated: false)
        sendPreview = preview
    }

    private func moreMenuActions() -> [UIMenuElement] {
        let actions = moreMenuItems().map { item in
            (item, UIAction(title: Self.title(for: item, selectedCount: selectedIds.count), image: Self.image(for: item)) { [weak self] _ in
                self?.perform(item)
            })
        }
        // 开关类的项单独成一节，前面系统画一条分隔线（同 Telegram 的 `.separator`）。
        let sendActions: [UIMenuElement] = actions.filter { !$0.0.isToggle }.map(\.1)
        let toggleActions: [UIMenuElement] = actions.filter { $0.0.isToggle }.map(\.1)
        guard !toggleActions.isEmpty else { return sendActions }
        return sendActions + [UIMenu(title: "", options: .displayInline, children: toggleActions)]
    }

    private static func title(for item: MoreMenuItem, selectedCount: Int) -> String {
        switch item {
        case .sendAsFile where selectedCount > 1:
            String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("IMAGE_PICKER_TELLOMI_SEND_AS_FILES_FORMAT", comment: "Photo picker more-menu item when several items are selected: send them right away as files (original quality, original file names). Embeds {{number of selected items}}."),
                OWSFormat.formatInt(selectedCount),
            )
        case .sendAsFile:
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_SEND_AS_FILE", comment: "Photo picker more-menu item when one item is selected: send it right away as a file (original quality, original file name).")
        case .sendHighQuality:
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_SEND_HIGH_QUALITY", comment: "Photo picker more-menu item: send the selection right away in high quality (this time only).")
        case .sendStandardQuality:
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_SEND_STANDARD_QUALITY", comment: "Photo picker more-menu item: send the selection right away in standard quality (this time only).")
        case .sendSeparately:
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_SEND_SEPARATELY", comment: "Photo picker more-menu item: send each selected photo as its own message.")
        case .moveCaptionUp:
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_MOVE_CAPTION_UP", comment: "Photo picker more-menu item: show the caption above the photos in the sent message.")
        case .moveCaptionDown:
            OWSLocalizedString("IMAGE_PICKER_TELLOMI_MOVE_CAPTION_DOWN", comment: "Photo picker more-menu item: show the caption below the photos in the sent message (the default).")
        }
    }

    private static func image(for item: MoreMenuItem) -> UIImage? {
        switch item {
        case .sendAsFile: UIImage(named: "file-28")
        case .sendHighQuality: UIImage(named: "hd")
        case .sendStandardQuality: UIImage(named: "hd-slash")
        case .sendSeparately: Theme.iconImage(.buttonPhotoLibrary)
        case .moveCaptionUp: UIImage(named: "arrow-up")
        case .moveCaptionDown: UIImage(named: "arrow-down")
        }
    }

    private func perform(_ item: MoreMenuItem) {
        switch item {
        case .sendAsFile:
            sendAsFiles()
        case .sendHighQuality:
            send(quality: .high, separately: false)
        case .sendStandardQuality:
            send(quality: .standard, separately: false)
        case .sendSeparately:
            send(quality: defaultImageQuality, separately: true)
        case .moveCaptionUp, .moveCaptionDown:
            // 菜单自己收起，下次打开换成另一项（同 Telegram：点了先收起再切）。长按发送里的那项跟着换（didSet）。
            isCaptionAboveMedia.toggle()
        }
    }

    // MARK: - 以文件发送（#1263）

    /// 「是否把照片转成 JPEG？」等着用户选（测试里直接选）。
    private var heicChoice: ((Bool) -> Void)?
    /// 「文件太大」提示点了「好」之后发剩下的（测试里直接点）。
    private var sendAfterTooLarge: (() -> Void)?

    /// P-5「以文件发送」：原图按文件发（不压缩、原文件名），一个一条、说明挂最后一条。已选里有没编辑过的 HEIC 先问要不要转成 JPEG
    /// （电脑端不认 HEIC）：保留 HEIC / 转成 JPEG / 取消。
    private func sendAsFiles() {
        let items = selectedIds.compactMap { selectedItems[$0] }
        guard !items.isEmpty else { return }
        let hasHeic = items.contains { !hasImageEdits($0) && library.isHeic($0) }
        guard hasHeic else {
            sendAsFiles(items, convertHeicToJpeg: false)
            return
        }
        let choose: (Bool) -> Void = { [weak self] convert in
            self?.heicChoice = nil
            self?.sendAsFiles(items, convertHeicToJpeg: convert)
        }
        heicChoice = choose
        let actionSheet = ActionSheetController(message: OWSLocalizedString(
            "IMAGE_PICKER_TELLOMI_CONVERT_TO_JPEG_QUESTION",
            comment: "Asked before sending photos as files when some of them are HEIC: whether to convert them to JPEG first.",
        ))
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("IMAGE_PICKER_TELLOMI_KEEP_HEIC", comment: "Option when sending photos as files: send the HEIC photos as they are."),
            handler: { _ in choose(false) },
        ))
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString("IMAGE_PICKER_TELLOMI_CONVERT_TO_JPEG", comment: "Option when sending photos as files: convert the HEIC photos to JPEG first."),
            handler: { _ in choose(true) },
        ))
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.cancelButton, style: .cancel, handler: { [weak self] _ in
            self?.heicChoice = nil
        }))
        presentActionSheet(actionSheet)
    }

    /// 在预览 / 编辑页里改过这张照片（裁剪、涂鸦、模糊……）。改过的按编辑后的图发，不然打码的地方会原样发出去（同 Telegram 安卓）。
    private func hasImageEdits(_ item: TellomiPhotoPickerItem) -> Bool {
        approvalItems[item.id].map(AttachmentApprovalViewController.tellomiHasImageEdits) ?? false
    }

    private func sendAsFiles(_ items: [TellomiPhotoPickerItem], convertHeicToJpeg: Bool) {
        let messageBody = messageBodyForSending
        let library = self.library
        let attachmentLimits = self.attachmentLimits
        let editedItems = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            hasImageEdits(item) ? approvalItems[item.id].map { (item.id, $0) } : nil
        })
        ModalActivityIndicatorViewController.present(
            fromViewController: self,
            title: CommonStrings.preparingModal,
            canCancel: true,
            asyncBlock: { [weak self] modal in
                let result = await Result<[TellomiPhotoPickerFile], Error> {
                    var files = [TellomiPhotoPickerFile]()
                    for item in items {
                        try Task.checkCancellation()
                        if let editItem = editedItems[item.id] {
                            files.append(try await Self.editedFile(for: item, editItem: editItem, library: library, attachmentLimits: attachmentLimits))
                        } else {
                            // 视频的剪辑不带：按文件发的是原文件（同 Telegram 安卓 forceDocument 丢掉 videoEditedInfo）。
                            files.append(try await library.fileAttachment(for: item, convertHeicToJpeg: convertHeicToJpeg, attachmentLimits: attachmentLimits))
                        }
                    }
                    return files
                }
                modal.dismissIfNotCanceled(completionIfNotCanceled: {
                    switch result {
                    case .success(let files):
                        self?.finishSendingAsFiles(files, messageBody: messageBody)
                    case .failure(let error):
                        Logger.warn("failed to prepare files. error: \(error)")
                        OWSActionSheets.showActionSheet(title: OWSLocalizedString("IMAGE_PICKER_FAILED_TO_PROCESS_ATTACHMENTS", comment: "alert title"))
                    }
                })
            },
        )
    }

    /// 编辑过的照片：编辑后的图按文件发，文件名沿用原图（后缀跟着格式改，IMG_1234.HEIC → IMG_1234.JPG）。
    private static func editedFile(
        for item: TellomiPhotoPickerItem,
        editItem: AttachmentApprovalItem,
        library: TellomiPhotoPickerLibrary,
        attachmentLimits: OutgoingAttachmentLimits,
    ) async throws -> TellomiPhotoPickerFile {
        let output = try await AttachmentApprovalViewController.tellomiOutputAttachment(for: editItem, attachmentLimits: attachmentLimits)
        let dataSource = output.dataSource
        let fileName = TellomiHeicConversion.fileName(
            library.originalFileName(for: item) ?? dataSource.sourceFilename ?? "IMG",
            matching: output.dataUTI,
        )
        dataSource.sourceFilename = fileName
        do {
            return .attachment(try PreviewableAttachment.tellomiAsFileAttachment(dataSource: dataSource, dataUTI: output.dataUTI, attachmentLimits: attachmentLimits))
        } catch SignalAttachmentError.fileSizeTooLarge {
            return .tooLarge(fileName: fileName)
        }
    }

    /// 超过上限的不发：先提示「文件太大」并写明上限，点了「好」再发剩下的（一个都不剩就不发）。
    private func finishSendingAsFiles(_ files: [TellomiPhotoPickerFile], messageBody: MessageBody?) {
        var attachments = [PreviewableAttachment]()
        var tooLarge = [String]()
        for file in files {
            switch file {
            case .attachment(let attachment): attachments.append(attachment)
            case .tooLarge(let fileName): tooLarge.append(fileName)
            }
        }
        let send = { [weak self] in
            guard let self else { return }
            self.sendAfterTooLarge = nil
            guard !attachments.isEmpty else { return }
            self.delegate?.photoPicker(
                self,
                send: ApprovedAttachments(nonViewOnceAttachments: attachments, imageQuality: self.defaultImageQuality),
                messageBody: messageBody,
                separately: true,
                // 按文件发的不适用（ADR-0068 §4.7）。
                captionAboveMedia: false,
            )
        }
        guard let name = tooLarge.first else {
            send()
            return
        }
        let limitText = ByteCountFormatter.string(fromByteCount: Int64(clamping: attachmentLimits.maxPlaintextBytes), countStyle: .file)
        let actionSheet = ActionSheetController(title: String.nonPluralLocalizedStringWithFormat(
            OWSLocalizedString("ATTACHMENT_FILES_TELLOMI_TOO_LARGE_FORMAT", comment: "Alert when a picked file is over the size limit. Embeds {{file name}} and {{maximum size of one file}}."),
            name,
            limitText,
        ))
        actionSheet.addAction(ActionSheetAction(title: CommonStrings.okButton, handler: { _ in send() }))
        sendAfterTooLarge = send
        presentActionSheet(actionSheet)
    }

    // MARK: - Sending / editing

    private var messageBodyForSending: MessageBody? {
        let body = captionTextView.messageBodyForSending
        return body.text.ows_stripped().isEmpty ? nil : body
    }

    private func send(quality: ImageQuality, separately: Bool) {
        let items = selectedIds.compactMap { selectedItems[$0] }
        guard !items.isEmpty else { return }
        let messageBody = messageBodyForSending
        prepareAttachments(for: items, applyingEditsFrom: approvalItems) { [weak self] attachments in
            guard let self else { return }
            self.delegate?.photoPicker(
                self,
                send: ApprovedAttachments(nonViewOnceAttachments: attachments, imageQuality: quality),
                messageBody: messageBody,
                separately: separately,
                captionAboveMedia: self.isCaptionAboveMedia,
            )
        }
    }

    /// P-10：进上游的预览 / 编辑页（裁剪、涂鸦、文字、模糊、画质、一次性查看都在那里），盖在网格上面：
    /// 在那里取消就回到网格、选中的都还在；在那里发送就照常发出。点的是哪张，进来先看到哪张（上游默认从第一张开始）。
    /// `tool` 有值时（查看器底部的「裁剪」「绘制」）页面出来后直接打开对应的工具。
    private func openSelectionForEditing(startingAt itemId: String, tool: TellomiApprovalEditTool?) {
        let items = selectedIds.compactMap { selectedItems[$0] }
        guard !items.isEmpty, let approvalDataSource else { return }
        let messageBody = messageBodyForSending
        let unprepared = items.filter { approvalItems[$0.id] == nil }
        prepareAttachments(for: unprepared, applyingEditsFrom: [:]) { [weak self] attachments in
            guard let self else { return }
            for (item, attachment) in zip(unprepared, attachments) {
                self.approvalItems[item.id] = AttachmentApprovalItem(attachment: attachment, canSave: false)
            }
            let editItems = items.compactMap { self.approvalItems[$0.id] }
            let approval = AttachmentApprovalViewController.wrappedInNavController(
                attachmentApprovalItems: editItems,
                initialMessageBody: messageBody,
                hasQuotedReplyDraft: self.hasQuotedReplyDraft,
                attachmentLimits: self.attachmentLimits,
                approvalDelegate: self,
                approvalDataSource: approvalDataSource,
                stickerSheetDelegate: self.stickerSheetDelegate,
            )
            approval.modalPresentationStyle = .overFullScreen
            let page = approval.viewControllers.first as? AttachmentApprovalViewController
            if let index = items.firstIndex(where: { $0.id == itemId }) {
                page?.tellomiShowItem(at: index)
            }
            self.editingApproval = page
            page?.tellomiSetSendLongPress(self.sendMenuItems().isEmpty ? nil : { [weak self] button in
                self?.presentSendPreview(from: button)
            })
            self.editingItems = zip(items, editItems).map { ($0.id, $1.attachment.rawValue) }
            self.present(approval, animated: true) {
                if let tool {
                    page?.tellomiActivateTool(tool)
                }
            }
        }
    }

    /// 一张一张地把选中的变成附件（视频要压缩，慢），期间显示「正在准备…」，可取消。
    /// 在预览 / 编辑页里改过的（`edits` 里有它的编辑项），按改过的样子出附件（E-6）。
    private func prepareAttachments(
        for items: [TellomiPhotoPickerItem],
        applyingEditsFrom edits: [String: AttachmentApprovalItem],
        completion: @escaping ([PreviewableAttachment]) -> Void,
    ) {
        guard !items.isEmpty else {
            completion([])
            return
        }
        let library = self.library
        let attachmentLimits = self.attachmentLimits
        ModalActivityIndicatorViewController.present(
            fromViewController: self,
            title: CommonStrings.preparingModal,
            canCancel: true,
            asyncBlock: { modal in
                let result = await Result<[PreviewableAttachment], Error> {
                    var attachments = [PreviewableAttachment]()
                    for item in items {
                        try Task.checkCancellation()
                        if let editItem = edits[item.id] {
                            attachments.append(try await AttachmentApprovalViewController.tellomiOutputAttachment(for: editItem, attachmentLimits: attachmentLimits))
                        } else {
                            attachments.append(try await library.attachment(for: item, attachmentLimits: attachmentLimits))
                        }
                    }
                    return attachments
                }
                modal.dismissIfNotCanceled(completionIfNotCanceled: {
                    switch result {
                    case .success(let attachments):
                        completion(attachments)
                    case .failure(SignalAttachmentError.fileSizeTooLarge):
                        OWSActionSheets.showActionSheet(title: OWSLocalizedString(
                            "ATTACHMENT_ERROR_FILE_SIZE_TOO_LARGE",
                            comment: "Attachment error message for attachments whose data exceed file size limits",
                        ))
                    case .failure(let error):
                        Logger.warn("failed to prepare attachments. error: \(error)")
                        OWSActionSheets.showActionSheet(title: OWSLocalizedString("IMAGE_PICKER_FAILED_TO_PROCESS_ATTACHMENTS", comment: "alert title"))
                    }
                })
            },
        )
    }

    private func didTapClose() {
        if displayMode == .selected {
            showAll()
            return
        }
        guard !selectedIds.isEmpty else {
            delegate?.photoPickerDidCancel(self)
            return
        }
        confirmDiscardingSelection()
    }

    /// 相机格：打开相机（上游的相机流程，自己问权限、自己发；拍到的在相机自己的预览页里发，不进这里的已选，同 Telegram）。
    /// 相机盖在面板上面，取消回来已选都还在，所以不用先问「丢弃媒体」。
    /// 两个取景会抢同一个相机，先停网格里的，相机关掉后（`cameraDidClose`）再接着取景。
    private func didTapCamera() {
        camera?.stopPreview()
        delegate?.photoPickerDidRequestCamera(self)
    }

    /// 盖在面板上面的相机关掉了：「最近」的相机格还露着就接着取景。
    func cameraDidClose() {
        if showsCamera, !collectionView.visibleSupplementaryViews(ofKind: TellomiPhotoPickerCameraCell.kind).isEmpty {
            camera?.startPreview()
        }
    }

    /// 在盖在上面的相机里改了说明：面板的说明框跟着变（会话输入框那边由会话页自己更新，这里不再往回报）。
    func updateCaptionFromCamera(_ messageBody: MessageBody?) {
        captionTextView.setMessageBody(messageBody, txProvider: DependenciesBridge.shared.db.readTxProvider)
        updateCaptionPlaceholderAndHeight()
        if displayMode == .selected {
            refreshSelectedView(animated: false)
        }
    }

    /// 有选中时关面板（✕ 或下拉）先问一句，照 Telegram `MediaPickerScreen.requestDismiss`；文案用上游 Signal 选图流程的「丢弃媒体」。
    private func confirmDiscardingSelection() {
        let actionSheet = ActionSheetController()
        actionSheet.addAction(ActionSheetAction(
            title: OWSLocalizedString(
                "SEND_MEDIA_CONFIRM_ABANDON_ALBUM",
                comment: "alert action, confirming the user wants to exit the media flow and abandon any photos they've taken",
            ),
            style: .destructive,
            handler: { [weak self] _ in
                guard let self else { return }
                self.delegate?.photoPickerDidCancel(self)
            },
        ))
        actionSheet.addAction(OWSActionSheets.cancelAction)
        presentActionSheet(actionSheet)
    }

    // MARK: - UIAdaptivePresentationControllerDelegate

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        confirmDiscardingSelection()
    }

    // MARK: - Swipe to select

    private func swipeTarget(at point: CGPoint) -> (id: String, isSelected: Bool)? {
        guard let currentAlbum, let indexPath = collectionView.indexPathForItem(at: point) else { return nil }
        let item = library.item(at: indexPath.item, in: currentAlbum)
        return (item.id, selectionNumber(for: item.id) != nil)
    }

    // MARK: - Caption

    private func toggleCaptionInputMode() {
        setCaptionInputMode(captionInputMode == .text ? .emoji : .text)
        if !captionTextView.isFirstResponder {
            captionTextView.becomeFirstResponder()
        }
    }

    private func setCaptionInputMode(_ mode: CaptionInputMode) {
        captionInputMode = mode
        updateCaptionEmojiButton()
        let desiredInputView: UIView?
        switch mode {
        case .text:
            desiredInputView = nil
        case .emoji:
            captionEmojiKeyboard.updateHeightForPresentation()
            desiredInputView = captionEmojiKeyboard
        }
        guard captionTextView.inputView !== desiredInputView else { return }
        captionTextView.inputView = desiredInputView
        if captionTextView.isFirstResponder {
            captionTextView.reloadInputViews()
        }
    }

    /// 文字键盘时显示笑脸（点了切表情），表情键盘时显示键盘（点了切回文字）。
    private func updateCaptionEmojiButton() {
        switch captionInputMode {
        case .text:
            captionEmojiButton.configuration?.image = Theme.iconImage(.emojiSmiley)
            captionEmojiButton.accessibilityLabel = OWSLocalizedString(
                "IMAGE_PICKER_TELLOMI_CAPTION_EMOJI_BUTTON",
                comment: "Accessibility label of the button in the photo picker caption field that switches to the emoji keyboard.",
            )
        case .emoji:
            captionEmojiButton.configuration?.image = UIImage(imageLiteralResourceName: "keyboard")
            captionEmojiButton.accessibilityLabel = OWSLocalizedString(
                "INPUT_TOOLBAR_KEYBOARD_BUTTON_ACCESSIBILITY_LABEL",
                comment: "accessibility label for the button which shows the regular keyboard instead of sticker picker",
            )
        }
    }

    private func updateCaptionPlaceholderAndHeight() {
        captionPlaceholder.isHidden = !captionTextView.isEmpty
        let width = captionTextView.bounds.width
        guard width > 0 else { return }
        let fitting = captionTextView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitting, Metrics.captionMinHeight), Metrics.captionMaxHeight)
        captionTextView.isScrollEnabled = fitting > Metrics.captionMaxHeight
        if captionHeightConstraint?.constant != height {
            captionHeightConstraint?.constant = height
        }
    }

    // MARK: - BodyRangesTextViewDelegate

    func textViewDidBeginTypingMention(_ textView: BodyRangesTextView) {}

    func textViewDidEndTypingMention(_ textView: BodyRangesTextView) {}

    func textViewMentionPickerParentView(_ textView: BodyRangesTextView) -> UIView? { view }

    func textViewMentionPickerReferenceView(_ textView: BodyRangesTextView) -> UIView? { sendBar }

    func textViewMentionPickerPossibleAcis(_ textView: BodyRangesTextView, tx: DBReadTransaction) -> [Aci] {
        approvalDataSource?.attachmentApprovalMentionableAcis(tx: tx) ?? []
    }

    func textViewMentionCacheInvalidationKey(_ textView: BodyRangesTextView) -> String {
        approvalDataSource?.attachmentApprovalMentionCacheInvalidationKey() ?? UUID().uuidString
    }

    func textViewDisplayConfiguration(_ textView: BodyRangesTextView) -> HydratedMessageBody.DisplayConfiguration {
        .composing(textViewColor: textView.textColor)
    }

    func mentionPickerStyle(_ textView: BodyRangesTextView) -> MentionPickerStyle { .composingAttachment }

    func textViewDidEndEditing(_ textView: UITextView) {
        setCaptionInputMode(.text)
    }

    func textViewDidChange(_ textView: UITextView) {
        updateCaptionPlaceholderAndHeight()
        updateSendMenus()
        delegate?.photoPicker(self, didChangeMessageBody: captionTextView.messageBodyForSending)
        if displayMode == .selected {
            refreshSelectedView(animated: false)
        }
    }

    // MARK: - AttachmentApprovalViewControllerDelegate（点照片进的上游预览 / 编辑页）

    func attachmentApproval(
        _ attachmentApproval: AttachmentApprovalViewController,
        didApproveAttachments approvedAttachments: ApprovedAttachments,
        messageBody: MessageBody?,
    ) {
        delegate?.photoPicker(self, send: approvedAttachments, messageBody: messageBody, separately: false, captionAboveMedia: isCaptionAboveMedia)
    }

    func attachmentApprovalDidCancel() {
        dismiss(animated: true)
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didChangeMessageBody newMessageBody: MessageBody?) {
        captionTextView.setMessageBody(newMessageBody, txProvider: DependenciesBridge.shared.db.readTxProvider)
        updateCaptionPlaceholderAndHeight()
        updateSendMenus()
        delegate?.photoPicker(self, didChangeMessageBody: newMessageBody)
        if displayMode == .selected {
            refreshSelectedView(animated: false)
        }
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didChangeViewOnceState isViewOnce: Bool) {}

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didRemoveAttachment attachmentApprovalItem: AttachmentApprovalItem) {
        guard
            let entry = editingItems.first(where: { $0.attachment === attachmentApprovalItem.attachment.rawValue }),
            let item = selectedItems[entry.itemId]
        else {
            return
        }
        setSelection(item: item, selected: false)
    }

    func attachmentApprovalDidTapAddMore(_ attachmentApproval: AttachmentApprovalViewController) {
        dismiss(animated: true)
    }
}

// MARK: - Undo bar (P-3)

/// 「已取消选择 N 张 · 撤销」：深色圆角条，同 Telegram 的撤销提示（4 秒后自己消失）。
private final class TellomiPhotoPickerUndoBar: UIView {

    static let height: CGFloat = 48

    var onUndo: (() -> Void)?

    var count = 0 {
        didSet {
            label.text = String.nonPluralLocalizedStringWithFormat(
                OWSLocalizedString("IMAGE_PICKER_TELLOMI_DESELECTED_FORMAT", comment: "Undo bar in the photo picker after unselecting photos in the selected-only view. Embeds {{ number unselected }}."),
                OWSFormat.formatInt(count),
            )
        }
    }

    private let label = UILabel()

    private lazy var undoButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.title = OWSLocalizedString("IMAGE_PICKER_TELLOMI_UNDO", comment: "Button in the photo picker's undo bar that puts unselected photos back.")
        configuration.baseForegroundColor = UIColor(rgbHex: 0x8AB4FF)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.dynamicTypeSubheadlineClamped.semibold()
            return attributes
        }
        return UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onUndo?() })
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.12, alpha: 0.95)
        layer.cornerRadius = 12

        label.font = .dynamicTypeSubheadlineClamped
        label.textColor = .white

        let stack = UIStackView(arrangedSubviews: [label, undoButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 0, leading: 16, bottom: 0, trailing: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        label.setContentHuggingHorizontalLow()
        undoButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var textForTesting: String? { label.text }

    func tapUndoForTesting() {
        undoButton.sendActions(for: .primaryActionTriggered)
    }
}

// MARK: - Limited access banner (P-7)

private final class TellomiPhotoPickerLimitedAccessHeader: UICollectionReusableView {

    static let reuseIdentifier = "TellomiPhotoPickerLimitedAccessHeader"

    weak var presentingViewController: UIViewController?

    private let label = UILabel()

    private lazy var manageButton: UIButton = {
        var configuration = UIButton.Configuration.gray()
        configuration.title = OWSLocalizedString("ATTACHMENT_KEYBOARD_BUTTON_MANAGE", comment: "Button in chat attachment panel that allows to select photos Signal is allowed to access.")
        configuration.baseForegroundColor = .Signal.label
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 14
        configuration.contentInsets = .init(top: 4, leading: 12, bottom: 4, trailing: 12)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.dynamicTypeSubheadlineClamped.semibold()
            return attributes
        }
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIAction(
                title: OWSLocalizedString("ATTACHMENT_KEYBOARD_CONTEXT_MENU_BUTTON_SELECT_MORE", comment: "Button in a context menu from the 'manage' button in attachment panel that allows to select more photos/videos to give Signal access to"),
                image: Theme.iconImage(.contextMenuSelect),
            ) { [weak self] _ in
                guard let presenter = self?.presentingViewController else { return }
                PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
            },
            UIAction(
                title: OWSLocalizedString("ATTACHMENT_KEYBOARD_CONTEXT_MENU_BUTTON_SYSTEM_SETTINGS", comment: "Button in a context menu from the 'manage' button in attachment panel that opens the iOS system settings for Signal to update access permissions"),
                image: Theme.iconImage(.contextMenuSettings),
            ) { _ in
                CurrentAppContext().openSystemSettings()
            },
        ])
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.text = OWSLocalizedString("IMAGE_PICKER_TELLOMI_LIMITED_ACCESS", comment: "Banner at the top of the photo picker when the user gave Tellomi access to only some photos.")
        label.font = .dynamicTypeSubheadlineClamped
        label.textColor = .Signal.label
        label.numberOfLines = 2

        let stack = UIStackView(arrangedSubviews: [label, manageButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = .init(top: 8, leading: 16, bottom: 8, trailing: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            manageButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        label.setContentHuggingHorizontalLow()
        manageButton.setContentHuggingPriority(.required, for: .horizontal)
        manageButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var textForTesting: String? { label.text }
    var manageButtonFrameForTesting: CGRect { manageButton.convert(manageButton.bounds, to: self) }
}

// MARK: - Swipe to select (P-8)

/// 横着滑过格子连续多选，机制照 Telegram `MediaPickerGridSelectionGesture`（MediaPickerScreen.swift；独立实现）：
/// 左边 44 以内起手不算（留给返回手势，同其 `sideInset = 44`）；竖向先动超过 5 就放弃、让给滚动；横向先动超过 8 才开始，
/// 这时停住网格的滚动，由这一刻手指下那格决定方向（没选 → 一路选上，已选 → 一路取消），起手那格和之后经过的格子都照它。
/// 和 Telegram 不同的一处：开始后这个手势真的进入 began（Telegram 的始终不识别、只靠关滚动），
/// 这样 UICollectionView 收到 touchesCancelled，松手时不会把手指下那格当成「点了照片」去进编辑页，也顺带压住页面下拉关闭。
final class TellomiSwipeSelectGestureRecognizer: UIPanGestureRecognizer {

    enum Progress {
        case waiting
        case failed
        case swiping
    }

    var itemAt: (CGPoint) -> (id: String, isSelected: Bool)? = { _ in nil }
    var setSelected: (String, Bool) -> Void = { _, _ in }
    var setScrollEnabled: (Bool) -> Void = { _ in }
    var leadingDeadZone: CGFloat = 44

    private var startLocation: CGPoint?
    private var isSwiping = false
    private var selecting = true

    init() {
        super.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard numberOfTouches == 1, let location = touches.first?.location(in: view), location.x > leadingDeadZone else {
            state = .failed
            return
        }
        startLocation = location
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let startLocation, let location = touches.first?.location(in: view) else {
            state = .failed
            return
        }
        switch track(from: startLocation, to: location) {
        case .waiting:
            break
        case .failed:
            state = .failed
        case .swiping:
            state = state == .possible ? .began : .changed
        }
    }

    /// 手指从 `start` 动到了 `location`：选上 / 取消经过的格子，返回手势该怎么走（测试直接喂坐标）。
    func track(from start: CGPoint, to location: CGPoint) -> Progress {
        if !isSwiping {
            if abs(location.y - start.y) > 5 {
                return .failed
            }
            guard abs(location.x - start.x) > 8 else {
                return .waiting
            }
            isSwiping = true
            setScrollEnabled(false)
            selecting = !((itemAt(location) ?? itemAt(start))?.isSelected ?? false)
            if let first = itemAt(start), first.isSelected != selecting {
                setSelected(first.id, selecting)
            }
        }
        if let target = itemAt(location), target.isSelected != selecting {
            setSelected(target.id, selecting)
        }
        return .swiping
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        state = isSwiping ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = isSwiping ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        finishSwipe()
    }

    /// 松手 / 取消之后：恢复滚动，下一次重新判方向。
    func finishSwipe() {
        if isSwiping {
            setScrollEnabled(true)
        }
        isSwiping = false
        startLocation = nil
    }
}

#if TESTABLE_BUILD

extension TellomiPhotoPickerViewController {
    var selectedIdsForTesting: [String] { selectedIds }
    var isCountPillShownForTesting: Bool { !countPill.isHidden }
    var countPillTextForTesting: String? { countPill.configuration?.attributedTitle.map { String($0.characters) } }
    var countPillFrameForTesting: CGRect { countPill.convert(countPill.bounds, to: view) }
    var isMoreButtonShownForTesting: Bool { !moreButton.isHidden }
    var isSendBarShownForTesting: Bool { !sendBar.isHidden }
    /// G-6：正在淡出的截图数；dock / 说明栏身上有没有淡入动画。
    var bottomBarFadingOutCountForTesting: Int { bottomBarSnapshots.count }
    var isSendBarFadingInForTesting: Bool { sendBar.layer.animationKeys()?.isEmpty == false }
    var isDockFadingInForTesting: Bool { dock?.layer.animationKeys()?.isEmpty == false }
    var dockForTesting: TellomiAttachmentDock? { dock }
    var isDockShownForTesting: Bool { dock.map { !$0.isHidden } ?? false }
    var isNoAccessHintShownForTesting: Bool { !noAccessView.isHidden }
    var isNoAccessIllustrationShownForTesting: Bool { !noAccessView.isHidden && !noAccessIllustration.isHidden && noAccessIllustration.image != nil }
    var noAccessHintTextForTesting: String? { (noAccessView as? UIStackView)?.arrangedSubviews.compactMap { ($0 as? UILabel)?.text }.first }
    /// 占位里露着的按钮，按排列的先后。
    private var noAccessButtonsForTesting: [UIButton] {
        let rows = (noAccessView as? UIStackView)?.arrangedSubviews.compactMap { $0 as? UIStackView } ?? []
        return rows.flatMap { $0.arrangedSubviews }.compactMap { $0 as? UIButton }.filter { !$0.isHidden }
    }

    var noAccessButtonTitlesForTesting: [String] { noAccessButtonsForTesting.compactMap { $0.configuration?.title } }

    func tapNoAccessCameraForTesting() {
        noAccessCameraButton.sendActions(for: .primaryActionTriggered)
    }

    func tapNoAccessButtonForTesting(title: String) {
        noAccessButtonsForTesting.first { $0.configuration?.title == title }?.sendActions(for: .primaryActionTriggered)
    }

    var gridBottomInsetForTesting: CGFloat { collectionView.contentInset.bottom }
    var titleForTesting: String? { titleButton.configuration?.title }
    var captionTextForTesting: String { captionTextView.messageBodyForSending.text }
    var albumTitlesForTesting: [String] { albums.map(\.title) }
    var moreMenuItemsForTesting: [MoreMenuItem] { moreMenuItems() }
    /// #1263 P3：发送键长按菜单里的项（nil = 长按不弹）。
    /// 发送键长按弹出的菜单里有哪几项；长按不弹时 nil。
    var sendMenuTitlesForTesting: [String]? {
        guard TellomiSendLongPressGestureRecognizer.installed(on: sendButton)?.isEnabled == true else { return nil }
        return sendMenuItems().map { Self.title(for: $0, selectedCount: selectedIds.count) }
    }

    /// 同手指按住网格的发送键。
    func longPressSendForTesting() {
        TellomiSendLongPressGestureRecognizer.installed(on: sendButton)?.fireForTesting()
    }

    var sendPreviewForTesting: TellomiSendPreviewViewController? { presentedSendPreview }

    /// 网格发送键在窗口里的位置。
    var sendButtonFrameForTesting: CGRect { sendButton.convert(sendButton.bounds, to: nil) }

    func performSendMenuCaptionItemForTesting() {
        toggleCaptionFromSendMenu()
    }
    var moreMenuTitlesForTesting: [String] { moreMenuItems().map { Self.title(for: $0, selectedCount: selectedIds.count) } }
    /// #1263：「是否把照片转成 JPEG？」正在问。
    var isAskingAboutHeicForTesting: Bool { heicChoice != nil }

    /// 同真的选项：提问收起之后再选（这时才能接着弹「正在准备…」）。
    func chooseHeicForTesting(convert: Bool) {
        guard let choice = heicChoice else { return }
        guard let presented = presentedViewController else {
            choice(convert)
            return
        }
        presented.dismiss(animated: false) { choice(convert) }
    }

    /// #1263：「文件太大」提示正在显示。
    var isShowingTooLargeForTesting: Bool { sendAfterTooLarge != nil }

    func acknowledgeTooLargeForTesting() {
        guard let send = sendAfterTooLarge else { return }
        guard let presented = presentedViewController else {
            send()
            return
        }
        presented.dismiss(animated: false) { send() }
    }
    var collectionViewForTesting: UICollectionView { collectionView }
    var swipeSelectGestureForTesting: TellomiSwipeSelectGestureRecognizer { swipeSelectGesture }

    var limitedAccessBannerTextForTesting: String? {
        let header = collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader).first
        return (header as? TellomiPhotoPickerLimitedAccessHeader)?.textForTesting
    }

    var limitedAccessManageButtonFrameForTesting: CGRect? {
        let header = collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader).first
        return (header as? TellomiPhotoPickerLimitedAccessHeader)?.manageButtonFrameForTesting
    }

    var sendBarFrameForTesting: CGRect { sendBar.frame }
    var captionFieldHeightForTesting: CGFloat { captionTextView.frame.size.height }

    func cellForTesting(itemIndex: Int) -> TellomiPhotoPickerCell? {
        collectionView.cellForItem(at: IndexPath(item: itemIndex, section: 0)) as? TellomiPhotoPickerCell
    }

    func tapCheckForTesting(itemIndex: Int) {
        cellForTesting(itemIndex: itemIndex)?.tapCheckForTesting()
    }

    func tapItemForTesting(itemIndex: Int) {
        collectionView(collectionView, didSelectItemAt: IndexPath(item: itemIndex, section: 0))
    }

    func performMoreMenuItemForTesting(_ item: MoreMenuItem) {
        perform(item)
    }

    /// 这几个都走按钮本身的动作（不直接调内部方法），按钮接错了测试才会红。
    func tapCloseForTesting() {
        closeButton.sendActions(for: .primaryActionTriggered)
    }

    func tapSendForTesting() {
        sendButton.sendActions(for: .primaryActionTriggered)
    }

    func switchAlbumForTesting(title: String) {
        if let album = albums.first(where: { $0.title == title }) {
            switchAlbum(to: album)
        }
    }

    /// 手指从 `points[0]` 起手、依次经过其余各点（网格坐标）再松开；返回最后一步时手势的走向。
    @discardableResult
    func swipeForTesting(through points: [CGPoint]) -> TellomiSwipeSelectGestureRecognizer.Progress {
        var progress = TellomiSwipeSelectGestureRecognizer.Progress.waiting
        guard let first = points.first else { return progress }
        for point in points.dropFirst() {
            progress = swipeSelectGesture.track(from: first, to: point)
            if progress == .failed { break }
        }
        swipeSelectGesture.finishSwipe()
        return progress
    }

    var isGridScrollEnabledForTesting: Bool { collectionView.isScrollEnabled }

    var cameraCellForTesting: TellomiPhotoPickerCameraCell? {
        collectionView.visibleSupplementaryViews(ofKind: TellomiPhotoPickerCameraCell.kind).first as? TellomiPhotoPickerCameraCell
    }

    var cameraFrameForTesting: CGRect? {
        layout.layoutAttributesForSupplementaryView(ofKind: TellomiPhotoPickerCameraCell.kind, at: IndexPath(item: 0, section: 0))?.frame
    }

    var selectedViewForTesting: TellomiPhotoPickerSelectedView { selectedView }
    var isTitleShownForTesting: Bool { !titleButton.isHidden }
    var closeButtonAccessibilityLabelForTesting: String? { closeButton.accessibilityLabel }
    var undoBarTextForTesting: String? { undoBar.isHidden ? nil : undoBar.textForTesting }
    var undoBarFrameForTesting: CGRect { undoBar.frame }

    func tapCountPillForTesting() {
        countPill.sendActions(for: .primaryActionTriggered)
    }

    /// 在说明框里打了这些字。
    func typeCaptionForTesting(_ text: String) {
        captionTextView.setMessageBody(MessageBody(text: text, ranges: .empty), txProvider: DependenciesBridge.shared.db.readTxProvider)
        textViewDidChange(captionTextView)
    }

    func tapUndoForTesting() {
        undoBar.tapUndoForTesting()
    }

    func tapCaptionEmojiButtonForTesting() {
        captionEmojiButton.sendActions(for: .primaryActionTriggered)
    }

    var captionEmojiButtonAccessibilityLabelForTesting: String? { captionEmojiButton.accessibilityLabel }
    var captionEmojiButtonFrameForTesting: CGRect { captionEmojiButton.convert(captionEmojiButton.bounds, to: captionContainer) }
    var captionFieldFrameForTesting: CGRect { captionContainer.bounds }
    var captionTextContainerInsetForTesting: UIEdgeInsets { captionTextView.textContainerInset }
    var captionInputViewForTesting: UIView? { captionTextView.inputView }
    var isCaptionEditingForTesting: Bool { captionTextView.isFirstResponder }

    /// 表情键盘（没切过表情时是 nil，不为了测试提前建）。
    var captionEmojiKeyboardForTesting: TellomiCaptionEmojiKeyboard? { captionTextView.inputView as? TellomiCaptionEmojiKeyboard }

    func setCaptionCursorForTesting(_ location: Int) {
        captionTextView.selectedRange = NSRange(location: location, length: 0)
    }

    /// 收起键盘（点网格、进预览页等都会让说明框失去焦点）。
    func endCaptionEditingForTesting() {
        _ = captionTextView.resignFirstResponder()
    }

    /// 撤销条到时间了。
    func expireUndoForTesting() {
        hideUndoBar()
    }
}

#endif
