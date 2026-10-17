//
// Copyright 2019 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreMedia
import SDWebImage
import SignalServiceKit
import SignalUI

class ViewOnceMessageViewController: OWSViewController {

    typealias Content = ViewOnceContent

    private enum AttachmentLoadingError: LocalizedError {
        case invalidImageSize

        var errorDescription: String? {
            switch self {
            case .invalidImageSize:
                return "Attachment has invalid size."
            }
        }
    }

    // MARK: - Properties

    private let content: Content

    private var mediaView: UIView!
    private var accessoryView: UIView?
    private var scrollView: ZoomableMediaView!

    /// Tellomi（tellomi/tellomi#1714，ADR-0079 §4.3）：计时的一次性查看只开这么久（照片 N 秒，视频 max(时长, N)），右上角倒计时环，
    /// 到点自己关。打开那一刻照 Signal 的流程已经「看过」了，提前关也一样没了。nil = 普通一次性查看（不限时）。
    var tellomiOpenDuration: TimeInterval? {
        tellomiSeconds.map { TellomiViewOnceTimer.viewerDuration(seconds: $0, videoDuration: tellomiVideoDuration) }
    }
    private let tellomiSeconds: UInt32?
    private var tellomiVideoDuration: TimeInterval?
    private let tellomiCountdownView = TellomiViewOnceCountdownView()
    private var tellomiCloseTimer: Timer?

    // MARK: - Initializers

    init?(interaction: TSInteraction) {
        guard
            let message = interaction as? TSMessage,
            let content = DependenciesBridge.shared.attachmentViewOnceManager.prepareViewOnceContentForDisplay(message)
        else {
            return nil
        }

        self.content = content
        self.tellomiSeconds = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiViewOnceTimer.seconds(messageUniqueId: message.uniqueId, tx: tx)
        }

        super.init()

        do {
            try buildMediaView()
        } catch {
            owsFailDebug("Could not present interaction")
            return nil
        }
    }

    // MARK: -

    @MainActor
    class func tryToPresent(interaction: TSInteraction, from fromViewController: UIViewController) {
        ModalActivityIndicatorViewController.present(
            fromViewController: fromViewController,
            canCancel: false,
        ) { modal in
            DispatchQueue.main.async {
                let viewController = ViewOnceMessageViewController(interaction: interaction)

                modal.dismiss {
                    guard let viewController else {
                        // TODO: Show an alert.
                        return
                    }
                    fromViewController.presentFullScreen(viewController, animated: true)
                }
            }
        }
    }

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .Signal.background

        if Theme.forceDarkThemeForMedia {
            overrideUserInterfaceStyle = .dark
        }

        // Scroll view.
        scrollView = ZoomableMediaView(mediaView: mediaView)
        scrollView.delegate = self
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Toolbar at the top.
        let toolbar = if #available(iOS 26, *) { UIToolbar() } else { UIToolbar.clear() }
        toolbar.tintColor = .Signal.label
        toolbar.items = [
            .closeButton { [weak self] in
                self?.dismissButtonPressed()
            },
            .flexibleSpace(),
        ]
        if tellomiOpenDuration != nil {
            tellomiCountdownView.frame = CGRect(origin: .zero, size: tellomiCountdownView.intrinsicContentSize)
            toolbar.items?.append(UIBarButtonItem(customView: tellomiCountdownView))
        }
        view.addSubview(toolbar)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Video playback timestamp in the toolbar.
        if let accessoryView {
            let accessoryViewContainer = UIView()
            accessoryViewContainer.addSubview(accessoryView)
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            accessoryViewContainer.addConstraints([
                accessoryView.topAnchor.constraint(equalTo: accessoryViewContainer.topAnchor),
                accessoryView.leadingAnchor.constraint(
                    equalToSystemSpacingAfter: accessoryViewContainer.leadingAnchor,
                    multiplier: 1,
                ),
                accessoryViewContainer.trailingAnchor.constraint(
                    equalToSystemSpacingAfter: accessoryView.trailingAnchor,
                    multiplier: 1,
                ),
                accessoryView.bottomAnchor.constraint(equalTo: accessoryViewContainer.bottomAnchor),
            ])
            toolbar.items?.append(UIBarButtonItem(customView: accessoryViewContainer))
        }

        if #available(iOS 26, *) {
            let interaction = UIScrollEdgeElementContainerInteraction()
            interaction.edge = .top
            interaction.scrollView = scrollView
            toolbar.addInteraction(interaction)
        }

        setupDatabaseObservation()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        scrollView.updateZoomScaleForLayout()
        scrollView.zoomScale = scrollView.minimumZoomScale
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        videoPlayer?.play()
        tellomiStartCountdownIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        tellomiCloseTimer?.invalidate()
        tellomiCloseTimer = nil
    }

    private func tellomiStartCountdownIfNeeded() {
        guard let tellomiOpenDuration, tellomiCloseTimer == nil else { return }
        tellomiCountdownView.start(duration: tellomiOpenDuration)
        tellomiCloseTimer = Timer.scheduledTimer(withTimeInterval: tellomiOpenDuration, repeats: false) { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        scrollView.updateZoomScaleForLayout()
    }

    // MARK: -

    private func buildMediaView() throws {
        switch content.type {
        case .loopingVideo:
            let asset = try content.loadAVAsset()
            let video = LoopingVideo(asset: asset)
            let view = LoopingVideoView()
            view.contentMode = .scaleAspectFit
            view.video = video

            mediaView = view

        case .animatedImage:
            let image = try content.loadYYImage()
            guard image.size.isNonEmpty else {
                throw AttachmentLoadingError.invalidImageSize
            }
            let animatedImageView = SDAnimatedImageView()
            // We need to specify a contentMode since the size of the image
            // might not match the aspect ratio of the view.
            animatedImageView.contentMode = .scaleAspectFit
            // Use trilinear filters for better scaling quality at
            // some performance cost.
            animatedImageView.layer.minificationFilter = .trilinear
            animatedImageView.layer.magnificationFilter = .trilinear
            animatedImageView.layer.allowsEdgeAntialiasing = true
            animatedImageView.image = image

            mediaView = animatedImageView

        case .stillImage:
            let image = try content.loadImage()
            guard image.size.isNonEmpty else {
                throw AttachmentLoadingError.invalidImageSize
            }

            let imageView = UIImageView()
            // We need to specify a contentMode since the size of the image
            // might not match the aspect ratio of the view.
            imageView.contentMode = .scaleAspectFit
            // Use trilinear filters for better scaling quality at
            // some performance cost.
            imageView.layer.minificationFilter = .trilinear
            imageView.layer.magnificationFilter = .trilinear
            imageView.layer.allowsEdgeAntialiasing = true
            imageView.image = image

            mediaView = imageView

        case .video:
            let asset = try content.loadAVAsset()
            // Tellomi（ADR-0079 §4.3）：计时的视频开 max(时长, N) 秒。
            let durationSeconds = asset.duration.seconds
            tellomiVideoDuration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : nil

            let player = VideoPlayer(avPlayer: .init(playerItem: .init(asset: asset)), shouldLoop: true)
            self.videoPlayer = player

            let playerView = VideoPlayerView()
            playerView.player = player.avPlayer

            let label = UILabel()
            label.textColor = .Signal.label
            label.font = UIFont.dynamicTypeBody.monospaced()

            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .positional
            formatter.allowedUnits = [.minute, .second]
            formatter.zeroFormattingBehavior = [.pad]

            let avPlayer = player.avPlayer
            self.videoPlayerProgressObserver = avPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.1, preferredTimescale: 100),
                queue: nil,
            ) { _ in
                guard let item = avPlayer.currentItem else {
                    owsFailDebug("item was unexpectedly nil")
                    label.text = "0:00"
                    return
                }

                let position = avPlayer.currentTime()
                let duration: CMTime = item.asset.duration
                let remainingTime = duration - position
                let remainingSeconds = CMTimeGetSeconds(remainingTime)

                guard let remainingString = formatter.string(from: remainingSeconds) else {
                    owsFailDebug("unable to format time remaining")
                    label.text = "0:00"
                    label.sizeToFit()
                    return
                }

                label.text = remainingString
                label.sizeToFit()
            }

            mediaView = playerView
            accessoryView = label
        }
    }

    // MARK: Video

    var videoPlayerProgressObserver: Any?
    var videoPlayer: VideoPlayer?

    func setupDatabaseObservation() {
        DependenciesBridge.shared.databaseChangeObserver.appendDatabaseChangeDelegate(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillEnterForeground),
            name: .OWSApplicationWillEnterForeground,
            object: nil,
        )
    }

    // Once open, this view only dismisses if the message is deleted
    // (e.g. by per-conversation expiration).
    private func dismissIfRemoved() {
        AssertIsOnMainThread()

        let shouldDismiss: Bool = SSKEnvironment.shared.databaseStorageRef.read { transaction in
            let uniqueId = self.content.messageId
            guard TSInteraction.fetchViaCache(uniqueId: uniqueId, transaction: transaction) != nil else {
                return true
            }
            return false
        }

        if shouldDismiss {
            dismiss(animated: true)
        }
    }

    // MARK: - Events

    @objc
    private func applicationWillEnterForeground() throws {
        dismissIfRemoved()
    }

    private func dismissButtonPressed() {
        dismiss(animated: true)
    }
}

extension ViewOnceMessageViewController: DatabaseChangeDelegate {

    func databaseChangesDidUpdate(databaseChanges: DatabaseChanges) {
        dismissIfRemoved()
    }

    func databaseChangesDidUpdateExternally() {
        dismissIfRemoved()
    }

    func databaseChangesDidReset() {
        dismissIfRemoved()
    }
}

extension ViewOnceMessageViewController: UIScrollViewDelegate {

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return mediaView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        (scrollView as? ZoomableMediaView)?.updateZoomScaleForLayout()
        view.layoutIfNeeded()
    }
}
