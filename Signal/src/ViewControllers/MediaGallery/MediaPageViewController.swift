//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

class MediaPageViewController: UIPageViewController {
    private lazy var mediaInteractiveDismiss = MediaInteractiveDismiss(targetViewController: self)

    private let isShowingSingleMessage: Bool
    let mediaGallery: MediaGallery
    let spoilerState: SpoilerRenderState

    private let initialGalleryItem: MediaGalleryItem

    convenience init?(
        initialMediaAttachment: ReferencedAttachment,
        thread: TSThread,
        spoilerState: SpoilerRenderState,
        showingSingleMessage: Bool = false,
    ) {
        self.init(
            initialMediaAttachment: initialMediaAttachment,
            mediaGallery: MediaGallery(thread: thread, mediaCategory: .photoVideo, spoilerState: spoilerState),
            spoilerState: spoilerState,
            showingSingleMessage: showingSingleMessage,
        )
    }

    init?(
        initialMediaAttachment: ReferencedAttachment,
        mediaGallery: MediaGallery,
        spoilerState: SpoilerRenderState,
        showingSingleMessage: Bool = false,
    ) {
        self.mediaGallery = mediaGallery
        self.spoilerState = spoilerState
        self.isShowingSingleMessage = showingSingleMessage

        Logger.info("will ensureLoadedForDetailView")
        guard let initialItem = mediaGallery.ensureLoadedForDetailView(focusedAttachment: initialMediaAttachment) else {
            owsFailDebug("unexpectedly failed to build initialDetailItem.")
            return nil
        }
        Logger.info("ensureLoadedForDetailView done")

        // Tellomi (tellomi/tellomi#1263, spec R-1): opening a covered image / video (a tile in All Media, the row in
        // conversation settings) uncovers it; in the chat it's uncovered by the tap before this.
        if initialItem.isTellomiSpoilerCovered {
            TellomiMediaSpoiler.reveal(initialItem.referencedAttachment.reference)
        }

        self.initialGalleryItem = initialItem

        super.init(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 20],
        )

        extendedLayoutIncludesOpaqueBars = true
        modalPresentationStyle = .overFullScreen
        modalPresentationCapturesStatusBarAppearance = true
        dataSource = self
        delegate = self
        transitioningDelegate = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(Self.newAttachmentsAvailable(_:)),
            name: MediaGalleryChangeInfo.newAttachmentsAvailableNotification,
            object: nil,
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Controls

    // Top Bar
    private lazy var topPanel: UIView = {
        let view = UIView()
        view.preservesSuperviewLayoutMargins = true

        // iOS 26: Transparent bar with glass backgrounds for controls.
        // Pre-iOS 26: blur background.
        if #unavailable(iOS 26) {
            let blurBackgroundView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            blurBackgroundView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(blurBackgroundView)
            NSLayoutConstraint.activate([
                blurBackgroundView.topAnchor.constraint(equalTo: view.topAnchor),
                blurBackgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                blurBackgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                blurBackgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        return view
    }()

    private var navigationBarVerticalPositionConstraint: NSLayoutConstraint?

    // Bottom Bar
    private lazy var bottomMediaPanel = MediaControlPanelView(
        mediaGallery: mediaGallery,
        delegate: self,
        spoilerState: spoilerState,
    )

    // Tellomi（tellomi/tellomi#1257，owner 2026-09-25「多个视频点开时完全参考 Telegram 的设计」）：
    // 屏幕正中的播放 / 暂停（30 秒以上两侧再有 ±15），跟着四角按钮一起出现、一起收起；翻页拖动时先隐去。
    private lazy var videoCenterControls = MediaVideoCenterControlsView()
    private var isPagingBetweenItems = false

    /// Tellomi（#1257，照 Telegram `GalleryController.playbackRate`）：这次查看器里选的倍速，翻到下一个视频沿用；不写任何设置。
    private var playbackSpeed: Float = 1 {
        didSet {
            (viewControllers?.first as? MediaItemViewController)?.videoPlayer?.playbackSpeed = playbackSpeed
            bottomMediaPanel.playbackSpeed = playbackSpeed
        }
    }

    private weak var playbackSpeedMenu: MediaPlaybackSpeedMenuView?

    /// Tellomi（#1257）：播放中控件自动收起的计时（见 updateAutoHideControlsTimer）。
    private var autoHideControlsTimer: Timer?
    private var autoHideControlsIdleSince = Date()
    private lazy var touchActivityObserver = TellomiTouchActivityObserver { [weak self] in
        self?.noteAutoHideControlsActivity()
    }

    // MARK: UIViewController

    override var preferredStatusBarStyle: UIStatusBarStyle {
        // Tellomi：查看器一律深色（见 viewDidLoad），状态栏也一律按上游「强制深色」时的规则走。
        if Theme.isDarkThemeEnabled {
            return .lightContent
        }

        let useDarkContentStatusBar: Bool
        if mediaInteractiveDismiss.interactionInProgress {
            useDarkContentStatusBar = true
        } else if isBeingDismissed, let transitionCoordinator {
            useDarkContentStatusBar = !transitionCoordinator.isCancelled
        } else {
            useDarkContentStatusBar = false
        }

        if useDarkContentStatusBar {
            return .darkContent
        }
        return .lightContent
    }

    override var prefersStatusBarHidden: Bool {
        return shouldHideStatusBar
    }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation {
        return .none
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Tellomi（#1257，照 Telegram）：查看器一律深色——底色黑、按钮是深色玻璃 + 白图标，不跟系统的浅色模式。
        // 上游在 iOS 26 起让查看器跟随系统（Theme.forceDarkThemeForMedia = false），浅色玻璃按钮放在亮的图片上看不清；
        // Telegram 的查看器按钮在浅色、深色模式下都是深色（GalleryTitleView / 底栏 GlassControlPanelComponent 都写死 isDark / 深色主题）。
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .Signal.mediaBackground

        mediaInteractiveDismiss.addGestureRecognizer(to: view)
        view.addGestureRecognizer(touchActivityObserver.recognizer)

        navigationItem.titleView = headerView

        // Top panel
        // Use UINavigation bar to ensure position of the < back button matches exactly of one in the presenting VC.
        let navigationBar = UINavigationBar()
        navigationBar.delegate = self
        navigationBar.tintColor = .Signal.label
        navigationBar.isUserInteractionEnabled = true
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        navigationBar.standardAppearance = appearance
        navigationBar.compactAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.setItems([UINavigationItem(title: ""), navigationItem], animated: false)
        if #available(iOS 26, *) {
            // Tellomi（#1257，照 Telegram）：系统的返回键是跟着背景变浅的玻璃，换成同样深色的返回键（点了照系统返回：关查看器）。
            navigationItem.hidesBackButton = true
            navigationItem.leftBarButtonItem = TellomiViewerGlass.barButtonItem(
                image: UIImage(systemName: "chevron.backward"),
                accessibilityLabel: CommonStrings.backButton,
                action: UIAction { [weak self] _ in self?.dismissSelf(animated: true) },
                menu: nil,
            )
        }
        navigationBar.translatesAutoresizingMaskIntoConstraints = false
        topPanel.addSubview(navigationBar)

        // See `viewSafeAreaInsetsDidChange` why this is needed.
        navigationBarVerticalPositionConstraint = navigationBar.topAnchor.constraint(equalTo: topPanel.topAnchor)
        NSLayoutConstraint.activate([
            navigationBarVerticalPositionConstraint!,
            navigationBar.bottomAnchor.constraint(equalTo: topPanel.bottomAnchor),
        ])

        // On iOS 26 navigation bar extends all the way to left and right screen edges even in landscape.
        if #available(iOS 26, *) {
            NSLayoutConstraint.activate([
                navigationBar.leadingAnchor.constraint(equalTo: topPanel.leadingAnchor),
                navigationBar.trailingAnchor.constraint(equalTo: topPanel.trailingAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                navigationBar.leadingAnchor.constraint(equalTo: topPanel.safeAreaLayoutGuide.leadingAnchor),
                navigationBar.trailingAnchor.constraint(equalTo: topPanel.safeAreaLayoutGuide.trailingAnchor),
            ])
        }

        // Add top panel and constrain it to view's leading, top and trailing edges.
        // Navigation bar (set up above) determines this panel's height.
        topPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topPanel)
        NSLayoutConstraint.activate([
            topPanel.topAnchor.constraint(equalTo: view.topAnchor),
            topPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Bottom panel
        bottomMediaPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomMediaPanel)
        NSLayoutConstraint.activate([
            bottomMediaPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomMediaPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomMediaPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Tellomi（#1257）：正中的播放 / 暂停在媒体之上、上下两块面板之下。
        videoCenterControls.translatesAutoresizingMaskIntoConstraints = false
        videoCenterControls.isHidden = true
        view.insertSubview(videoCenterControls, belowSubview: topPanel)
        NSLayoutConstraint.activate([
            videoCenterControls.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            videoCenterControls.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        // Load initial page and update all UI to reflect it.
        setCurrentItem(initialGalleryItem, direction: .forward, shouldAutoPlayVideo: true, animated: false)

        // Tellomi（#1257，owner 2026-09-25，对照 Telegram）：打开时什么都不显示（四角按钮、缩略条、视频控件），轻点才一起出现；
        // 开着 VoiceOver 时照常显示，不然找不到转发 / 保存。
        if !UIAccessibility.isVoiceOverRunning {
            setShouldHideToolbars(true, animated: false)
        }

        mediaGallery.addDelegate(self)
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        setNeedsStatusBarAppearanceUpdate()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.verticalSizeClass != previousTraitCollection?.verticalSizeClass {
            updateControlsForCurrentOrientation()
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        if let navigationBarVerticalPositionConstraint {
            // On iPhones with a Dynamic Island standard position of a navigation bar is bottom of the status bar,
            // which is ~5 dp smaller than the top safe area inset (https://useyourloaf.com/blog/iphone-14-screen-sizes/) .
            // Since it is not possible to constrain top edge of our manually maintained navigation bar to that position
            // the workaround is to detect when top safe area inset is larger than the status bar height and adjust as needed.
            var topInset = view.safeAreaInsets.top
            if
                #unavailable(iOS 26),
                let statusBarHeight = view.window?.windowScene?.statusBarManager?.statusBarFrame.height,
                statusBarHeight < topInset
            {
                topInset = statusBarHeight
                if #available(iOS 18, *) {
                    topInset += (2 + hairlineWidth)
                } else if #available(iOS 16, *) {
                    topInset -= hairlineWidth
                }
            }
            // On iOS 26 in landscape the navigation bar is offset 24 dp from the screen top edge.
            if #available(iOS 26, *), topInset.isZero {
                topInset = 24
            }
            navigationBarVerticalPositionConstraint.constant = topInset
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        cachedPages.removeAll()
    }

    // MARK: Paging

    private var cachedPages: [MediaGalleryItem: MediaItemViewController] = [:]

    private func buildGalleryPage(galleryItem: MediaGalleryItem) -> MediaItemViewController {
        if let cachedPage = cachedPages[galleryItem] {
            return cachedPage
        }
        let viewController = MediaItemViewController(galleryItem: galleryItem)
        viewController.delegate = self
        cachedPages[galleryItem] = viewController
        return viewController
    }

    private func replaceCurrentItem(item: MediaGalleryItem) {
        guard let currentViewController else { return }
        currentViewController.replaceGalleryItem(item: item)
        updateControlsForCurrentOrientation()
        didTransitionToNewPage(
            animated: true,
            direction: nil,
        )
    }

    private var currentViewController: MediaItemViewController? {
        let viewController = viewControllers?.first as? MediaItemViewController
        owsAssertBeta(viewController != nil)
        return viewController
    }

    private var currentItem: MediaGalleryItem! {
        return currentViewController?.galleryItem
    }

    private var currentPageSwipeDirection: UIPageViewController.NavigationDirection = .forward

    private func setCurrentItem(
        _ item: MediaGalleryItem,
        direction: UIPageViewController.NavigationDirection,
        shouldAutoPlayVideo: Bool = false,
        animated: Bool,
    ) {
        if let previousPage = viewControllers?.first as? MediaItemViewController {
            previousPage.videoPlaybackStatusObserver = nil
            previousPage.zoomOut(animated: false)
            previousPage.stopVideoIfPlaying()
            previousPage.tellomiDidResignCurrentPage()
        }

        let mediaPage = buildGalleryPage(galleryItem: item)
        mediaPage.shouldAutoPlayVideo = item.isVideoReadyToPlay
        setViewControllers([mediaPage], direction: direction, animated: animated) { _ in
            self.didTransitionToNewPage(animated: animated, direction: direction)
        }
    }

    private func didTransitionToNewPage(animated: Bool, direction: UIPageViewController.NavigationDirection?) {
        guard let currentViewController else {
            owsFailBeta("No MediaItemViewController")
            return
        }

        bottomMediaPanel.configureWithMediaItem(
            currentViewController.galleryItem,
            videoPlayer: currentViewController.videoPlayer,
            transitionDirection: direction,
            animated: animated,
        )

        // Tellomi（#1257）：倍速沿用到这个视频；正中的播放键换成这个视频的。
        currentViewController.videoPlayer?.playbackSpeed = playbackSpeed
        bottomMediaPanel.playbackSpeed = playbackSpeed
        videoCenterControls.bind(
            currentViewController.videoPlayer,
            showsSkipButtons: Self.showsSkipButtons(for: currentViewController.galleryItem),
        )

        updateScreenTitle(using: currentViewController.galleryItem)
        currentViewController.videoPlaybackStatusObserver = bottomMediaPanel
        showOrHideTopAndBottomPanelsAsNecessary(animated: animated)
        updateControlsForCurrentOrientation()

        // Tellomi（#1257）：翻到视频就播（手指横滑、缩略条跳转一样），见 tellomiDidBecomeCurrentPage。
        currentViewController.tellomiDidBecomeCurrentPage()
    }

    // MARK: Show / hide toolbars

    private var _shouldHideToolbars: Bool = false

    private var shouldHideToolbars: Bool {
        get { _shouldHideToolbars }
        set { setShouldHideToolbars(newValue, animated: false) }
    }

    private func setShouldHideToolbars(_ shouldHide: Bool, animated: Bool = false) {
        _shouldHideToolbars = shouldHide
        showOrHideTopAndBottomPanelsAsNecessary(animated: animated)
        setNeedsStatusBarAppearanceUpdate()
        updateAutoHideControlsTimer()
    }

    private func showOrHideTopAndBottomPanelsAsNecessary(animated: Bool) {
        topPanel.setIsHidden(shouldHideToolbars, animated: animated)
        bottomMediaPanel.setIsHidden(shouldHideToolbars || bottomMediaPanel.shouldBeHidden, animated: animated)
        updateVideoCenterControlsVisibility(animated: animated)
        if #available(iOS 26, *) {
            let targetColor: UIColor = shouldHideToolbars ? .black : .Signal.mediaBackground
            if animated {
                let animator = UIViewPropertyAnimator(duration: 0.2, curve: .easeInOut)
                animator.addAnimations {
                    self.view.backgroundColor = targetColor
                }
                animator.startAnimation()
            } else {
                view.backgroundColor = targetColor
            }
        }
    }

    private func updateVideoCenterControlsVisibility(animated: Bool) {
        let isPlayableVideo = (viewControllers?.first as? MediaItemViewController)?.videoPlayer != nil
        videoCenterControls.setIsHidden(shouldHideToolbars || !isPlayableVideo || isPagingBetweenItems, animated: animated)
    }

    // MARK: - Tellomi（#1257）：播放中控件自动收起

    /// 照 Telegram iOS（`UniversalVideoGalleryItem` 的 `shouldHideControlsSignal`：正在播、没在交互、控件显示着，4 秒后收起；
    /// 菜单开着、说明展开时不收）。这里按「连续 4 秒没被打断」算：控件显示着时每 0.5 秒看一次，没在播、正在拖进度条、
    /// 「···」或倍速菜单开着、上面盖着别的页面、开着 VoiceOver、正在翻页都算打断，计时从头来；碰一下屏幕也从头来。
    /// 这样菜单、弹出页不管怎么关掉，关掉后都再等满 4 秒，不会一关就收。照片不收（只对正在播的视频）。
    static var autoHideControlsDelay: TimeInterval = 4
    static var autoHideControlsTickInterval: TimeInterval = 0.5
    static var isVoiceOverRunning: () -> Bool = { UIAccessibility.isVoiceOverRunning }

    private func updateAutoHideControlsTimer() {
        autoHideControlsIdleSince = Date()
        guard !shouldHideToolbars, viewIfLoaded?.window != nil else {
            autoHideControlsTimer?.invalidate()
            autoHideControlsTimer = nil
            return
        }
        guard autoHideControlsTimer == nil else { return }
        autoHideControlsTimer = Timer.scheduledTimer(withTimeInterval: Self.autoHideControlsTickInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.autoHideControlsTick()
        }
    }

    private func noteAutoHideControlsActivity() {
        autoHideControlsIdleSince = Date()
    }

    private var isAutoHideControlsBlocked: Bool {
        guard let videoPlayer = currentViewController?.videoPlayer, videoPlayer.isPlaying else { return true }
        if viewIfLoaded?.window == nil || presentedViewController != nil || isPagingBetweenItems { return true }
        if bottomMediaPanel.isScrubbingVideo { return true }
        if playbackSpeedMenu?.window != nil { return true }
        if (navigationItem.rightBarButtonItems ?? []).contains(where: { ($0.customView as? TellomiViewerMenuButton)?.isMenuVisible == true }) {
            return true
        }
        return Self.isVoiceOverRunning()
    }

    private func autoHideControlsTick() {
        guard !shouldHideToolbars, viewIfLoaded?.window != nil else {
            updateAutoHideControlsTimer()
            return
        }
        if isAutoHideControlsBlocked {
            autoHideControlsIdleSince = Date()
            return
        }
        if Date().timeIntervalSince(autoHideControlsIdleSince) >= Self.autoHideControlsDelay {
            setShouldHideToolbars(true, animated: true)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateAutoHideControlsTimer()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        updateAutoHideControlsTimer()
    }

    /// 同上游 VideoPlaybackControlView：30 秒以上的视频才有 ±15（Telegram 是 ≥ 30 秒）。
    private static func showsSkipButtons(for item: MediaGalleryItem) -> Bool {
        guard item.isVideo, let duration = item.referencedAttachment.asReferencedStream?.attachmentStream.cachedVideoDuration else {
            return false
        }
        return duration > 30
    }

    private var shouldHideStatusBar: Bool {
        guard traitCollection.userInterfaceIdiom == .phone else { return shouldHideToolbars }
        return shouldHideToolbars || traitCollection.verticalSizeClass == .compact
    }

    private func updateControlsForCurrentOrientation() {
        // Bottom bar might be hidden while in landscape and visible in portrait, for the same media.
        showOrHideTopAndBottomPanelsAsNecessary(animated: false)

        if traitCollection.verticalSizeClass == .compact {
            // Order of buttons is reversed: first button in array is the outermost in the navbar.
            navigationItem.rightBarButtonItems = [buildContextMenuBarButton(), barButtonForwardMedia, barButtonShareMedia]
            if #available(iOS 26, *) {
                navigationItem.rightBarButtonItems = navigationItem.rightBarButtonItems?.map(TellomiViewerGlass.barButtonItem(from:))
            }
        } else {
            navigationItem.rightBarButtonItems = [buildContextMenuBarButton()]
            if #available(iOS 26, *) {
                navigationItem.rightBarButtonItems = navigationItem.rightBarButtonItems?.map(TellomiViewerGlass.barButtonItem(from:))
            }
        }
    }

    // MARK: Context Menu

    private func buildContextMenuBarButton() -> UIBarButtonItem {
        .contextMenuButton(actions: [
            // TODO: Video Playback Speed
            // TODO: Edit
            UIAction(
                title: OWSLocalizedString(
                    "MEDIA_VIEWER_SAVE_MEDIA_ACTION",
                    comment: "Context menu item in media viewer. Refers to saving currently displayed photo/video to the Photos app.",
                ),
                image: Theme.iconImage(.contextMenuSave),
                attributes:
                currentItem.referencedAttachment.asReferencedStream == nil ? .disabled : [],
                handler: { [weak self] _ in
                    self?.saveCurrentMediaToPhotos()
                },
            ),
            // Tellomi（#1257，照 Telegram）：底栏的分享位让给了删除，分享挪到这里。
            UIAction(
                title: OWSLocalizedString(
                    "MEDIA_VIEWER_TELLOMI_SHARE_ACTION",
                    comment: "Context menu item in media viewer: share the photo or video on screen to other apps.",
                ),
                image: Theme.iconImage(.contextMenuShare),
                attributes:
                currentItem.referencedAttachment.asReferencedStream == nil ? .disabled : [],
                handler: { [weak self] _ in
                    self?.shareCurrentMedia(fromNavigationBar: false)
                },
            ),
            UIAction(
                title: OWSLocalizedString(
                    "MEDIA_VIEWER_GO_TO_MESSAGE_ACTION",
                    comment: "Context menu item in media viewer. Refers to scrolling the conversation to the currently displayed photo/video.",
                ),
                image: Theme.iconImage(.buttonMessage),
                handler: { [weak self] _ in
                    self?.presentConversationForCurrentMedia()
                },
            ),
        ] + replyActionIfAvailable() + [
            UIAction(
                title: OWSLocalizedString(
                    "MEDIA_VIEWER_DELETE_MEDIA_ACTION",
                    comment: "Context menu item in media viewer. Refers to deleting currently displayed photo/video.",
                ),
                image: Theme.iconImage(.contextMenuDelete),
                attributes: .destructive,
                handler: { [weak self] _ in
                    self?.deleteCurrentMedia()
                },
            ),
        ])
    }

    // MARK: Bar Buttons

    private lazy var barButtonShareMedia: UIBarButtonItem = {
        let button = UIBarButtonItem.button(icon: .buttonShare) { [weak self] in
            self?.didPressShare()
        }
        button.landscapeImagePhone = UIImage(imageLiteralResourceName: "share-20")
        return button
    }()

    private lazy var barButtonForwardMedia: UIBarButtonItem = {
        let button = UIBarButtonItem.button(icon: .buttonForward) { [weak self] in
            self?.didPressForward()
        }
        button.landscapeImagePhone = UIImage(imageLiteralResourceName: "forward-20")
        return button
    }()

    // MARK: Helpers

    private func dismissSelf(animated isAnimated: Bool, completion: (() -> Void)? = nil) {
        guard let currentViewController else { return }

        // Swapping mediaView for presentationView will be perceptible if we're not zoomed out all the way.
        currentViewController.zoomOut(animated: true)

        // Tellomi（#1257）：下拉关闭拖一半又放回去（#75 以后常见）——视频接着原处播。拖动开始时只暂停，
        // 真关掉了才照上游 stop（回到开头）。上游一开始就 stop：取消后视频停在 0:00，而这里的控件是收起的
        // （每页的播放键已去掉），画面上什么都点不到。
        let wasPlaying = currentViewController.videoPlayer?.isPlaying == true
        currentViewController.videoPlayer?.pause()

        navigationController?.setNavigationBarHidden(false, animated: false)

        dismiss(animated: isAnimated, completion: completion)

        guard let transitionCoordinator else {
            currentViewController.stopVideoIfPlaying()
            return
        }
        transitionCoordinator.animate(alongsideTransition: nil) { [weak currentViewController] context in
            guard let currentViewController else { return }
            if context.isCancelled {
                if wasPlaying {
                    currentViewController.videoPlayer?.play()
                }
            } else {
                currentViewController.stopVideoIfPlaying()
            }
        }
    }

    // MARK: Actions

    private func didTapBackButton(_ sender: Any) {
        Logger.debug("")
        dismissSelf(animated: true)
    }

    private func didPressShare() {
        shareCurrentMedia(fromNavigationBar: true)
    }

    /// Forwards all media from the message containing the currently gallery
    /// item.
    ///
    /// Skips any media that we do not have downloaded.
    private func didPressForward() {
        forwardCurrentMedia()
    }

    /// Tellomi（#1257，owner 2026-09-25，照 Telegram）：相册里的一张先问「这一张 / 全部 N 张」。
    private func forwardCurrentMedia() {
        presentAlbumChoice(
            isDestructive: false,
            onThisItem: { [weak self] in self?.forwardMedia(onlyCurrentItem: true) },
            onAllItems: { [weak self] in self?.forwardMedia(onlyCurrentItem: false) },
        )
    }

    private func forwardMedia(onlyCurrentItem: Bool) {
        let messageForCurrentItem = currentItem.message
        let currentAttachmentId = currentItem.referencedAttachment.attachment.id

        let mediaAttachments: [ReferencedAttachment] = SSKEnvironment.shared.databaseStorageRef.read { transaction in
            guard let rowId = messageForCurrentItem.sqliteRowId else { return [] }
            return DependenciesBridge.shared.attachmentStore
                .fetchReferencedAttachments(for: .messageBodyAttachment(messageRowId: rowId), tx: transaction)
        }

        let mediaAttachmentStreams: [ReferencedAttachmentStream] = mediaAttachments.compactMap { attachment in
            guard let attachmentStream = attachment.asReferencedStream else {
                // Our current media item should always be an attachment
                // stream (downloaded). However, we can't guarantee that the
                // same is true for other media in the message to forward. For
                // example, another piece of media in this message may have
                // failed to download.
                //
                // If so, we should continue trying to forward the ones we can.

                Logger.warn("Skipping attachment that is not an attachment stream. Did this attachment fail to download?")
                return nil
            }

            return attachmentStream
        }.filter { !onlyCurrentItem || $0.attachment.id == currentAttachmentId }

        let mediaCount = mediaAttachmentStreams.count

        switch mediaCount {
        case 0:
            // Tellomi（#1257）：「这一张」可能点在还没下载完的那一张上（横屏时导航栏上的转发键不按下载状态变灰），
            // 这时没有可转发的——不动。上游这里是 owsFail，发布版也会崩。
            Logger.warn("Nothing to forward: the current item has not been downloaded yet.")
        case 1:
            ForwardMessageViewController.present(
                forAttachmentStreams: mediaAttachmentStreams,
                fromMessage: messageForCurrentItem,
                from: self,
                delegate: self,
            )
        case _ where !onlyCurrentItem && mediaGallery.album(for: currentItem).items.count > 1:
            // 已经在「这一张 / 全部」里选了全部，不再二次确认
            ForwardMessageViewController.present(
                forAttachmentStreams: mediaAttachmentStreams,
                fromMessage: messageForCurrentItem,
                from: self,
                delegate: self,
            )
        default:
            // If we are forwarding multiple items, warn the user first.

            let titleFormatString = OWSLocalizedString(
                "MEDIA_PAGE_FORWARD_MEDIA_CONFIRM_TITLE_%d",
                tableName: "PluralAware",
                comment: "Text confirming the user wants to forward media. Embeds {{ %1$@ the number of media to be forwarded }}.",
            )

            OWSActionSheets.showConfirmationAlert(
                message: OWSLocalizedString(
                    "MEDIA_PAGE_FORWARD_MEDIA_CONFIRM_MESSAGE",
                    comment: "Text explaining that the user will forward all media from a message.",
                ),
                proceedTitle: String.localizedStringWithFormat(
                    titleFormatString,
                    mediaCount,
                ),
                proceedAction: { [weak self] _ in
                    guard let self else { return }

                    ForwardMessageViewController.present(
                        forAttachmentStreams: mediaAttachmentStreams,
                        fromMessage: messageForCurrentItem,
                        from: self,
                        delegate: self,
                    )
                },
            )
        }
    }

    private func shareCurrentMedia(fromNavigationBar: Bool) {
        guard let currentViewController else { return }
        guard let stream = currentViewController.galleryItem.referencedAttachment.asReferencedStream else {
            // TODO: [MediaGallery]: Handle undownloaded media
            owsFailDebug("Cannot share undownloaded media")
            return
        }
        guard
            let attachmentStream = (try? [stream].asShareableAttachments())?.first
        else {
            return
        }
        let sender = fromNavigationBar ? barButtonShareMedia : bottomMediaPanel
        AttachmentSharing.showShareUI(for: attachmentStream, sender: sender)
    }

    @objc
    private func newAttachmentsAvailable(_ notification: Notification) {
        AssertIsOnMainThread()
        let incomingNewAttachments = notification.object as! [MediaGalleryChangeInfo]
        guard
            incomingNewAttachments.first(where: {
                $0.referenceId == currentItem.referencedAttachment.reference.referenceId
            }) != nil
        else {
            return
        }

        if
            let newItem = mediaGallery.reloadGalleryItem(item: currentItem),
            newItem.referencedAttachment.reference.referenceId == currentItem.referencedAttachment.reference.referenceId
        {
            replaceCurrentItem(item: newItem)
        }
    }

    // MARK: -

    private func saveCurrentMediaToPhotos() {
        guard let mediaItem = currentItem else { return }
        guard let stream = mediaItem.referencedAttachment.asReferencedStream else {
            // TODO: [MediaGallery]: Handle undownloaded media
            owsFailDebug("Cannot share undownloaded media")
            return
        }
        AttachmentSaving.saveToPhotoLibrary(
            referencedAttachmentStreams: [stream],
        )
    }

    private func presentConversationForCurrentMedia() {
        guard let mediaItem = currentItem else { return }

        dismissSelf(animated: true) {
            SignalApp.shared.presentConversationForThread(
                threadUniqueId: mediaItem.message.uniqueThreadId,
                focusMessageId: mediaItem.message.uniqueId,
                animated: true,
            )
        }
    }

    /// Tellomi（#1257，owner 2026-09-25，照 Telegram）：相册里的一张先问「这一张 / 全部 N 张」；
    /// 「全部」走会话里长按删除的同一个面板（仅自己 / 所有人）。
    private func deleteCurrentMedia() {
        guard let mediaItem = currentItem else { return }

        guard mediaGallery.album(for: mediaItem).items.count > 1 else {
            confirmDeleteSingleMedia(mediaItem)
            return
        }
        presentAlbumChoice(
            isDestructive: true,
            onThisItem: { [weak self] in
                guard let self else { return }
                self.mediaGallery.delete(items: [mediaItem], initiatedBy: self)
            },
            onAllItems: { [weak self] in
                guard let self else { return }
                mediaItem.message.presentDeletionActionSheet(from: self, forceDarkTheme: true)
            },
        )
    }

    private func confirmDeleteSingleMedia(_ mediaItem: MediaGalleryItem) {
        let actionSheet = ActionSheetController(title: nil, message: nil)
        let deleteAction = ActionSheetAction(
            title: CommonStrings.deleteButton,
            style: .destructive,
        ) { _ in
            self.mediaGallery.delete(items: [mediaItem], initiatedBy: self)
        }
        actionSheet.addAction(OWSActionSheets.cancelAction)
        actionSheet.addAction(deleteAction)

        presentActionSheet(actionSheet)
    }

    // MARK: - Tellomi（#1257）：倍速面板

    private func presentPlaybackSpeedMenu(from sourceView: UIView) {
        playbackSpeedMenu?.dismiss(animated: false)
        let menu = MediaPlaybackSpeedMenuView(speed: playbackSpeed, sourceView: sourceView) { [weak self] speed in
            self?.playbackSpeed = speed
        }
        menu.present(in: view)
        playbackSpeedMenu = menu
    }

    // MARK: - Tellomi（#1257）：这一张 / 全部、回复这一张

    /// 相册（≥ 2 张）里：弹出「这张图片 / 这个视频」与「全部 N 张 / N 个 / N 项」；不是相册直接走「这一张」。
    private func presentAlbumChoice(isDestructive: Bool, onThisItem: @escaping () -> Void, onAllItems: @escaping () -> Void) {
        let items = mediaGallery.album(for: currentItem).items
        guard items.count > 1 else {
            onThisItem()
            return
        }

        let thisTitle = currentItem.isVideo
            ? OWSLocalizedString("MEDIA_VIEWER_TELLOMI_THIS_VIDEO", comment: "Media viewer: action on only the video on screen, when the message has several photos or videos.")
            : OWSLocalizedString("MEDIA_VIEWER_TELLOMI_THIS_PHOTO", comment: "Media viewer: action on only the photo on screen, when the message has several photos or videos.")
        let allFormat: String
        if items.allSatisfy({ $0.isVideo }) {
            allFormat = OWSLocalizedString("MEDIA_VIEWER_TELLOMI_ALL_VIDEOS_FORMAT", comment: "Media viewer: action on all videos of the message. Embeds {{ the number of videos }}.")
        } else if items.allSatisfy({ !$0.isVideo }) {
            allFormat = OWSLocalizedString("MEDIA_VIEWER_TELLOMI_ALL_PHOTOS_FORMAT", comment: "Media viewer: action on all photos of the message. Embeds {{ the number of photos }}.")
        } else {
            allFormat = OWSLocalizedString("MEDIA_VIEWER_TELLOMI_ALL_ITEMS_FORMAT", comment: "Media viewer: action on all photos and videos of the message. Embeds {{ the number of items }}.")
        }
        let allTitle = String.nonPluralLocalizedStringWithFormat(allFormat, OWSFormat.formatInt(items.count))

        let actionSheet = ActionSheetController(title: nil, message: nil)
        let style: ActionSheetAction.Style = isDestructive ? .destructive : .default
        actionSheet.addAction(ActionSheetAction(title: thisTitle, style: style) { _ in onThisItem() })
        actionSheet.addAction(ActionSheetAction(title: allTitle, style: style) { _ in onAllItems() })
        actionSheet.addAction(OWSActionSheets.cancelAction)
        presentActionSheet(actionSheet)
    }

    /// 从会话里打开、而且这个会话现在能发消息时，「···」里有「回复」（回复的是正在看的这一张）。
    private func replyActionIfAvailable() -> [UIAction] {
        guard let conversationViewController = conversationViewControllerForReply() else {
            return []
        }
        guard conversationViewController.inputToolbar != nil, !conversationViewController.hasPendingMessageRequest else {
            return []
        }
        return [
            UIAction(
                title: OWSLocalizedString(
                    "MEDIA_VIEWER_TELLOMI_REPLY_ACTION",
                    comment: "Context menu item in media viewer. Replies to the message that contains the currently displayed photo/video.",
                ),
                image: Theme.iconImage(.contextMenuReply),
                handler: { [weak self] _ in
                    self?.replyToCurrentMedia()
                },
            ),
        ]
    }

    private func replyToCurrentMedia() {
        guard let conversationViewController = conversationViewControllerForReply() else {
            return
        }
        guard let quotedReply = buildReplyDraft() else {
            owsFailDebug("Could not build quoted reply.")
            return
        }
        dismissSelf(animated: true) { [weak conversationViewController] in
            conversationViewController?.populateReply(withDraft: quotedReply)
        }
    }

    /// 「回复」的草稿：和聊天里长按回复一样引用整条消息，缩略图照上游取第一项（owner 2026-09-26：
    /// 不做「回复这一张」——协议只能引用整条消息，要让对方看到那一张就得放宽收件方的防伪）。
    private func buildReplyDraft() -> DraftQuotedReplyModel? {
        guard let message = currentItem?.message else {
            return nil
        }
        return SSKEnvironment.shared.databaseStorageRef.read { tx in
            DependenciesBridge.shared.quotedReplyManager.buildDraftQuotedReply(
                originalMessage: message,
                loadNormalizedImage: NormalizedImage.loadImage(imageSource:maxPixelSize:),
                tx: tx,
            )
        }
    }

    func replyDraftForTesting() -> DraftQuotedReplyModel? {
        return buildReplyDraft()
    }

    /// 打开这个查看器的会话页（同一个会话）；从「全部媒体」等别处打开时没有。
    private func conversationViewControllerForReply() -> ConversationViewController? {
        var pending: [UIViewController] = presentingViewController.map { [$0] } ?? []
        let threadUniqueId = currentItem.message.uniqueThreadId
        while let candidate = pending.popLast() {
            if let conversationViewController = candidate as? ConversationViewController {
                if conversationViewController.thread.uniqueId == threadUniqueId {
                    return conversationViewController
                }
                continue
            }
            pending.append(contentsOf: candidate.children)
        }
        return nil
    }

    // MARK: Dynamic Header

    private func senderName(from message: TSMessage) -> String {
        switch message {
        case let incomingMessage as TSIncomingMessage:
            return SSKEnvironment.shared.databaseStorageRef.read { tx in
                return SSKEnvironment.shared.contactManagerRef.displayName(for: incomingMessage.authorAddress, tx: tx).resolvedValue()
            }
        case is TSOutgoingMessage:
            return CommonStrings.you
        case is TSReleaseNotesMessage:
            return OWSLocalizedString(
                "RELEASE_NOTES_CHANNEL_NAME",
                comment: "Display name for the release notes channel",
            )
        default:
            owsFailDebug("Unknown message type: \(type(of: message))")
            return ""
        }
    }

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        return formatter
    }()

    private lazy var headerNameLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .Signal.label
        if #available(iOS 26, *) {
            // Tellomi（#1257）：胶囊是深色玻璃，字一律白色（不让玻璃按背后图的亮度改成黑字）。
            label.textColor = .white
            label.font = .dynamicTypeSubheadlineClamped.semibold()
            // "semibold" fonts aren't dynamic anymore - have to track changes manually.
            label.registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (label: UILabel, _) in
                label.font = .dynamicTypeSubheadlineClamped.semibold()
            }
        } else {
            label.font = UIFont.regularFont(ofSize: 15)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
        }
        return label
    }()

    private lazy var headerDateLabel: UILabel = {
        let label = UILabel()
        label.textAlignment = .center
        label.textColor = .Signal.label
        if #available(iOS 26, *) {
            // Tellomi（#1257）：胶囊是深色玻璃，字一律白色（不让玻璃按背后图的亮度改成黑字）。
            label.textColor = .white
            label.font = .dynamicTypeCaption1Clamped
            label.adjustsFontForContentSizeCategory = true
        } else {
            label.font = .regularFont(ofSize: 11)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.8
        }
        return label
    }()

    private lazy var headerView: UIView = {
        let stackView = UIStackView(arrangedSubviews: [headerNameLabel, headerDateLabel])
        stackView.axis = .vertical
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let containerView = UIView()
        if #available(iOS 26, *) {
            // Can't return `glassEffectView` as `headerView` because UINavigationBar stretches it to fill width.
            // Tellomi（#1257）：深色玻璃，白底的图上也看得清（TellomiViewerGlass）。
            let glassEffectView = UIVisualEffectView(effect: TellomiViewerGlass.effect())
            TellomiViewerGlass.darken(glassEffectView)
            glassEffectView.cornerConfiguration = .capsule()
            glassEffectView.translatesAutoresizingMaskIntoConstraints = false
            glassEffectView.contentView.addSubview(stackView)

            let contentInset = UIEdgeInsets(hMargin: 24, vMargin: 4)
            NSLayoutConstraint.activate([
                stackView.topAnchor.constraint(greaterThanOrEqualTo: glassEffectView.topAnchor, constant: contentInset.top),
                stackView.centerYAnchor.constraint(equalTo: glassEffectView.centerYAnchor),
                stackView.leadingAnchor.constraint(equalTo: glassEffectView.leadingAnchor, constant: contentInset.leading),
                stackView.trailingAnchor.constraint(equalTo: glassEffectView.trailingAnchor, constant: -contentInset.trailing),
            ])

            containerView.addSubview(glassEffectView)
            NSLayoutConstraint.activate([
                glassEffectView.topAnchor.constraint(equalTo: containerView.topAnchor),
                glassEffectView.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor),
                glassEffectView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
                glassEffectView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            ])

            // On iOS 26 navigation bar is transparent and can accomodate `titleView` of any height.
            // Set minimum height to default 44pts thus allowing it to grow with font size.
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        } else {
            containerView.addSubview(stackView)
            NSLayoutConstraint.activate([
                stackView.topAnchor.constraint(greaterThanOrEqualTo: containerView.topAnchor),
                stackView.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),

                stackView.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor),
                stackView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            ])
        }

        return containerView
    }()

    private func updateScreenTitle(using mediaItem: MediaGalleryItem) {
        headerNameLabel.text = senderName(from: mediaItem.message)

        // use sent date
        let date = Date(timeIntervalSince1970: Double(mediaItem.message.timestamp) / 1000)
        headerDateLabel.text = dateFormatter.string(from: date)
    }
}

extension MediaPageViewController: UIPageViewControllerDelegate {

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController],
    ) {
        // Tellomi（#1257）：翻页拖动时正中的播放键先隐去，停下后按新的一页再决定。
        isPagingBetweenItems = true
        updateVideoCenterControlsVisibility(animated: true)
        playbackSpeedMenu?.dismiss(animated: false)

        guard
            let currentPage = pageViewController.viewControllers?.first as? MediaItemViewController,
            let newPage = pendingViewControllers.first as? MediaItemViewController
        else {
            return
        }
        if currentPage.galleryItem.orderingKey < newPage.galleryItem.orderingKey {
            currentPageSwipeDirection = .forward
        } else {
            currentPageSwipeDirection = .reverse
        }
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted: Bool,
    ) {
        isPagingBetweenItems = false

        if let previousPage = previousViewControllers.first as? MediaItemViewController {
            previousPage.zoomOut(animated: false)
            previousPage.stopVideoIfPlaying()
            previousPage.videoPlaybackStatusObserver = nil
            previousPage.tellomiDidResignCurrentPage()
        }

        if transitionCompleted {
            didTransitionToNewPage(animated: true, direction: currentPageSwipeDirection)
        } else {
            // Tellomi（#1257）：横滑到一半又放回去——上面照上游把这一页的视频停了、观察者也摘了；上游每页有播放键兜底，
            // 这里没有，停着的视频画面上没东西可点。重新接上这一页，和刚翻到时一样（视频从头播）。
            didTransitionToNewPage(animated: true, direction: nil)
        }
    }
}

extension MediaPageViewController: UIPageViewControllerDataSource {
    private func itemIsAllowed(_ item: MediaGalleryItem) -> Bool {
        // Normally, we can show any media item, but if we're limited
        // to showing a single message, don't page beyond that message
        return !isShowingSingleMessage || currentItem.message == item.message
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        Logger.debug("")

        guard let currentPage = viewController as? MediaItemViewController else {
            owsFailDebug("unexpected viewController: \(viewController)")
            return nil
        }

        guard let precedingItem = mediaGallery.galleryItem(before: currentPage.galleryItem), itemIsAllowed(precedingItem) else {
            return nil
        }

        return buildGalleryPage(galleryItem: precedingItem)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        Logger.debug("")

        guard let currentPage = viewController as? MediaItemViewController else {
            owsFailDebug("unexpected viewController: \(viewController)")
            return nil
        }

        guard let nextItem = mediaGallery.galleryItem(after: currentPage.galleryItem), itemIsAllowed(nextItem) else {
            // no more pages
            return nil
        }

        return buildGalleryPage(galleryItem: nextItem)
    }
}

extension MediaPageViewController: InteractivelyDismissableViewController {
    func performInteractiveDismissal(animated: Bool) {
        dismissSelf(animated: true)
    }
}

extension MediaPageViewController: MediaGalleryDelegate {
    func mediaGallery(_ mediaGallery: MediaGallery, applyUpdate update: MediaGallery.Update) {
        Logger.debug("")
    }

    func mediaGallery(_ mediaGallery: MediaGallery, willDelete items: [MediaGalleryItem], initiatedBy: AnyObject) {
        Logger.debug("")

        guard items.contains(currentItem) else {
            Logger.debug("irrelevant item")
            return
        }

        // If we setCurrentItem with (animated: true) while this VC is in the background, then
        // the next/previous cache isn't expired, and we're able to swipe back to the just-deleted vc.
        // So to get the correct behavior, we should only animate these transitions when this
        // vc is in the foreground
        let isAnimated = initiatedBy === self

        if isShowingSingleMessage {
            // In message details, which doesn't use the slider, so don't swap pages.
        } else if let nextItem = mediaGallery.galleryItem(after: currentItem) {
            setCurrentItem(nextItem, direction: .forward, animated: isAnimated)
        } else if let previousItem = mediaGallery.galleryItem(before: currentItem) {
            setCurrentItem(previousItem, direction: .reverse, animated: isAnimated)
        } else {
            // else we deleted the last piece of media, return to the conversation view
            dismissSelf(animated: true)
        }
    }

    func mediaGalleryDidDeleteItem(_ mediaGallery: MediaGallery) {
        // Either this is an internal deletion, in which case willDelete would have been called already,
        // or it's an external deletion, in which case mediaGalleryDidReloadItems would have been called already.
    }

    func mediaGalleryDidReloadItems(_ mediaGallery: MediaGallery) {
        didReloadAllSectionsInMediaGallery(mediaGallery)
    }

    func didAddSectionInMediaGallery(_ mediaGallery: MediaGallery) {
        // Does not affect the current item.
    }

    func didReloadAllSectionsInMediaGallery(_ mediaGallery: MediaGallery) {
        let attachment = currentItem.referencedAttachment
        guard let reloadedItem = mediaGallery.ensureLoadedForDetailView(focusedAttachment: attachment) else {
            // Assume the item was deleted.
            dismissSelf(animated: true)
            return
        }
        setCurrentItem(reloadedItem, direction: .forward, animated: false)
    }

    func mediaGalleryShouldDeferUpdate(_ mediaGallery: MediaGallery) -> Bool {
        return false
    }
}

extension MediaPageViewController: MediaItemViewControllerDelegate {

    func mediaItemViewControllerDidTapMedia(_ viewController: MediaItemViewController) {
        setShouldHideToolbars(!shouldHideToolbars, animated: true)
    }

    func mediaItemViewControllerWillBeginZooming(_ viewController: MediaItemViewController) {
        setShouldHideToolbars(true, animated: true)
    }

    func mediaItemViewControllerFullyZoomedOut(_ viewController: MediaItemViewController) {
        setShouldHideToolbars(false, animated: true)
    }

    // Tellomi（#1257，照 Telegram）：不循环的视频放完了，把控件叫出来（正中是播放键）。
    func mediaItemViewControllerVideoDidPlayToEnd(_ viewController: MediaItemViewController) {
        guard viewController === viewControllers?.first else { return }
        videoCenterControls.updatePlayPauseButton()
        setShouldHideToolbars(false, animated: true)
    }
}

extension MediaGalleryItem: GalleryRailItem {
    public func buildRailItemView() -> UIView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.image = thumbnailImageSync()
        return imageView
    }
}

extension MediaGalleryAlbum: GalleryRailItemProvider {
    var railItems: [GalleryRailItem] {
        return self.stripItems
    }
}

extension MediaPageViewController: MediaControlPanelDelegate {

    func mediaControlPanelDidRequestForwardMedia(_ panel: MediaControlPanelView) {
        forwardCurrentMedia()
    }

    func mediaControlPanelDidRequestDeleteMedia(_ panel: MediaControlPanelView) {
        deleteCurrentMedia()
    }

    func mediaControlPanel(_ panel: MediaControlPanelView, didRequestPlaybackSpeedMenuFrom sourceView: UIView) {
        presentPlaybackSpeedMenu(from: sourceView)
    }

    func mediaControlPanel(_ panel: MediaControlPanelView, didSelectAlbumItem item: MediaGalleryItem) {
        guard item != currentItem else {
            return
        }
        // 拖缩略条时跟手：直接换页，不做翻页动画
        let direction: UIPageViewController.NavigationDirection = currentItem.albumIndex < item.albumIndex ? .forward : .reverse
        setCurrentItem(item, direction: direction, animated: false)
    }

    func galleryRailView(_ galleryRailView: GalleryRailView, didTapItem imageRailItem: GalleryRailItem) {
        guard let targetItem = imageRailItem as? MediaGalleryItem else {
            owsFailDebug("unexpected imageRailItem: \(imageRailItem)")
            return
        }

        let direction: UIPageViewController.NavigationDirection
        direction = currentItem.albumIndex < targetItem.albumIndex ? .forward : .reverse
        setCurrentItem(targetItem, direction: direction, animated: true)
    }
}

extension MediaPageViewController: MediaPresentationContextProvider {

    func mediaPresentationContext(item: Media, in coordinateSpace: UICoordinateSpace) -> MediaPresentationContext? {
        guard let mediaView = currentViewController?.mediaView else { return nil }

        guard nil != mediaView.superview else {
            owsFailDebug("superview was unexpectedly nil")
            return nil
        }

        view.layoutIfNeeded()

        // Tellomi（#1257）：查看器一律深色（viewDidLoad），开合动画的底色也一律黑。上游 iOS 26 起给 mediaBackground
        // （浅色模式下是白）——动画在转场容器里按系统的浅色取值，浅色模式下开合时会闪一下白。
        let backgroundColor: UIColor = .black
        return MediaPresentationContext(
            mediaView: mediaView,
            presentationFrame: mediaView.frame,
            backgroundColor: backgroundColor,
        )
    }

    func mediaWillPresent(toContext: MediaPresentationContext) {
        view.backgroundColor = .clear
    }

    func mediaDidPresent(toContext: MediaPresentationContext) {
        showOrHideTopAndBottomPanelsAsNecessary(animated: false)
        if #unavailable(iOS 26) {
            view.backgroundColor = .Signal.mediaBackground
        }
    }

    func mediaWillDismiss(fromContext: MediaPresentationContext) {
        view.backgroundColor = .clear
    }

    func mediaDidDismiss(fromContext: MediaPresentationContext) {
        view.backgroundColor = .Signal.mediaBackground
    }
}

extension MediaPageViewController: UIViewControllerTransitioningDelegate {
    func animationController(
        forPresented presented: UIViewController,
        presenting: UIViewController,
        source: UIViewController,
    ) -> UIViewControllerAnimatedTransitioning? {
        guard self == presented else {
            owsFailDebug("unexpected presented: \(presented)")
            return nil
        }

        return MediaZoomAnimationController(galleryItem: currentItem)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        guard self == dismissed else {
            owsFailDebug("unexpected dismissed: \(dismissed)")
            return nil
        }

        let animationController = MediaDismissAnimationController(
            galleryItem: currentItem,
            interactionController: mediaInteractiveDismiss,
        )
        mediaInteractiveDismiss.interactiveDismissDelegate = animationController

        return animationController
    }

    func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        guard
            let animationController = animator as? MediaDismissAnimationController,
            animationController.interactionController.interactionInProgress
        else {
            return nil
        }
        return animationController.interactionController
    }
}

extension MediaPageViewController: ForwardMessageDelegate {
    func forwardMessageFlowDidComplete(items: [ForwardMessageItem], recipientThreads: [TSThread]) {
        dismiss(animated: true) {
            ForwardMessageViewController.finalizeForward(
                items: items,
                recipientThreads: recipientThreads,
                fromViewController: self,
            )
        }
    }

    func forwardMessageFlowDidCancel() {
        dismiss(animated: true)
    }
}

extension MediaPageViewController: UINavigationBarDelegate {

    func navigationBar(_ navigationBar: UINavigationBar, shouldPop item: UINavigationItem) -> Bool {
        dismissSelf(animated: true)
        return false
    }

    func navigationBar(_ navigationBar: UINavigationBar, didPop item: UINavigationItem) {
        dismissSelf(animated: true)
    }
}

#if TESTABLE_BUILD

// Tellomi（#1257）：给查看器判据用的入口（SignalTests/AlbumViewerScreenshotTests）。
extension MediaPageViewController {
    var areToolbarsHiddenForTesting: Bool { shouldHideToolbars }

    var isAutoHideControlsBlockedForTesting: Bool { isAutoHideControlsBlocked }

    var contextMenuButtonForTesting: TellomiViewerMenuButton? {
        (navigationItem.rightBarButtonItems ?? []).lazy.compactMap { $0.customView as? TellomiViewerMenuButton }.first
    }

    /// 走真实的那条路：在查看器根视图上找挂着的「碰过屏幕」识别器，像系统送触摸时那样问它的代理。
    /// 找不到（识别器没挂上 / 代理没接）就返回 false，计时也不会从头来。
    func noteTouchForTesting() -> Bool {
        guard
            let recognizer = view.gestureRecognizers?.first(where: { $0.delegate is TellomiTouchActivityObserver }),
            let delegate = recognizer.delegate
        else {
            return false
        }
        _ = delegate.gestureRecognizer?(recognizer, shouldReceive: UITouch())
        return true
    }

    /// 标题胶囊（iOS 26 上是容器里的那块玻璃）与底栏的删除键，量它们在白底图上是不是深色。
    var headerViewForTesting: UIView { headerView.subviews.first ?? headerView }
    var deleteButtonForTesting: UIButton { bottomMediaPanel.deleteButtonForTesting }
    var leftBarButtonItemForTesting: UIBarButtonItem? { navigationItem.leftBarButtonItem }
    var rightBarButtonItemsForTesting: [UIBarButtonItem] { navigationItem.rightBarButtonItems ?? [] }

    var currentItemForTesting: MediaGalleryItem { currentItem }

    var albumScrubberForTesting: MediaAlbumScrubberView { bottomMediaPanel.albumScrubberForTesting }

    func tapMediaForTesting() {
        if let currentViewController {
            mediaItemViewControllerDidTapMedia(currentViewController)
        }
    }

    func requestForwardForTesting() {
        forwardCurrentMedia()
    }

    func requestDeleteForTesting() {
        deleteCurrentMedia()
    }

    var bottomPanelForTesting: MediaControlPanelView { bottomMediaPanel }

    var videoCenterControlsForTesting: MediaVideoCenterControlsView { videoCenterControls }

    var isShowingVideoCenterControlsForTesting: Bool { !videoCenterControls.isHidden && videoCenterControls.alpha > 0 }

    var currentVideoPlayerForTesting: VideoPlayer? { currentViewController?.videoPlayer }

    var playbackSpeedForTesting: Float { playbackSpeed }

    var playbackSpeedMenuForTesting: MediaPlaybackSpeedMenuView? { playbackSpeedMenu }

    func openPlaybackSpeedMenuForTesting() {
        presentPlaybackSpeedMenu(from: bottomMediaPanel.playbackSpeedButtonForTesting)
    }

    /// 右上角「···」里的各项标题（按顺序）。
    var contextMenuTitlesForTesting: [String] {
        (navigationItem.rightBarButtonItems?.first?.menu?.children ?? []).compactMap { ($0 as? UIAction)?.title }
    }

    /// 模拟一次手指横滑到下一页，顺序同 UIKit：从数据源取下一页 → willTransitionTo → 换上去 → didFinishAnimating。
    func swipeToNextPageForTesting() {
        guard let current = viewControllers?.first, let next = pageViewController(self, viewControllerAfter: current) else {
            return
        }
        pageViewController(self, willTransitionTo: [next])
        setViewControllers([next], direction: .forward, animated: false)
        pageViewController(self, didFinishAnimating: true, previousViewControllers: [current], transitionCompleted: true)
    }
}

#endif

/// Tellomi（#1257）：只用来知道「刚碰过屏幕」（播放中自动收起控件的计时从头来）。这个手势识别器一个触摸都不收
/// （`shouldReceive` 里记一下就返回 false），所以不影响任何按钮、滑动和别的手势。
private final class TellomiTouchActivityObserver: NSObject, UIGestureRecognizerDelegate {
    let recognizer = UIGestureRecognizer()
    private let onTouch: () -> Void

    init(onTouch: @escaping () -> Void) {
        self.onTouch = onTouch
        super.init()
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        onTouch()
        return false
    }
}
