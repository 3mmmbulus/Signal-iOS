//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import CoreMedia
import SDWebImage
import SignalServiceKit
import SignalUI

protocol MediaItemViewControllerDelegate: AnyObject {
    func mediaItemViewControllerDidTapMedia(_ viewController: MediaItemViewController)
    func mediaItemViewControllerWillBeginZooming(_ viewController: MediaItemViewController)
    func mediaItemViewControllerFullyZoomedOut(_ viewController: MediaItemViewController)
    /// Tellomi（#1257，照 Telegram）：超过 30 秒、不循环的视频放完了（查看器把控件叫出来，中间是播放键）。
    func mediaItemViewControllerVideoDidPlayToEnd(_ viewController: MediaItemViewController)
    /// Tellomi（#1263，spec R-2）：这一页的实况开始 / 停止带声循环（查看器的「实况」按钮跟着变）。
    func mediaItemViewController(_ viewController: MediaItemViewController, tellomiLiveActiveDidChange isActive: Bool)
}

protocol VideoPlaybackStatusProvider: AnyObject {
    var videoPlaybackStatusObserver: VideoPlaybackStatusObserver? { get set }
}

protocol VideoPlaybackStatusObserver: AnyObject {
    func videoPlayerStatusChanged(_ videoPlayer: VideoPlayer)
}

class MediaItemViewController: OWSViewController, VideoPlaybackStatusProvider {

    weak var delegate: MediaItemViewControllerDelegate?

    private(set) var galleryItem: MediaGalleryItem

    init(galleryItem: MediaGalleryItem) {
        self.galleryItem = galleryItem

        super.init()
    }

    deinit {
        stopVideoIfPlaying()
    }

    // MARK: - Layout

    private var scrollView: ZoomableMediaView!

    private var progressView: CVAttachmentProgressView?
    private(set) var mediaView: UIView!
    private var mediaViewBottomConstraint: NSLayoutConstraint?
    private var mediaViewLeadingConstraint: NSLayoutConstraint?
    private var mediaViewTopConstraint: NSLayoutConstraint?
    private var mediaViewTrailingConstraint: NSLayoutConstraint?

    var videoPlayerView: VideoPlayerView? { mediaView as? VideoPlayerView }
    var videoPlayer: VideoPlayer? { videoPlayerView?.videoPlayer }

    private var downloadTask: Task<Void, Never>?

    func zoomOut(animated: Bool) {
        scrollView.zoomOut(animated: animated)
    }

    // Tellomi（#1257，照 Telegram）：上游每页一个、只在没播时出现的 92 播放键去掉了，
    // 换成查看器正中跟着四角按钮一起出现的播放 / 暂停（MediaVideoCenterControlsView）。

    /// Tellomi（#1257，照 Telegram，同 Android 的 LOOP_MAX_DURATION_MS）：30 秒以内的视频循环播放。
    static let loopMaxDuration: TimeInterval = 30

    // MARK: - Media Views

    func replaceGalleryItem(item: MediaGalleryItem) {
        zoomOut(animated: false)
        stopVideoIfPlaying()

        mediaView.removeFromSuperview()
        mediaView = nil
        scrollView.removeFromSuperview()
        scrollView.delegate = nil
        scrollView = nil

        galleryItem = item
        configureMediaView()

        view.addSubview(scrollView)
        scrollView.autoPinEdgesToSuperviewEdges()
        scrollView.layoutIfNeeded()

        // Video Playback controls
        if isVideo {
            if shouldAutoPlayVideo, !hasAutoPlayedVideo {
                playVideo()
                hasAutoPlayedVideo = true
            }
            layoutMediaView()
        }
    }

    private func addProgressViewIfNeeded() {
        guard progressView == nil else {
            return
        }
        guard let attachmentPointer = galleryItem.referencedAttachment.attachment.asAnyPointer() else {
            return
        }
        self.progressView = MediaGallery.addDownloadProgressView(
            attachmentPointer: attachmentPointer,
            toView: view,
        )
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(didTapProgressView))
        progressView?.addGestureRecognizer(tapGesture)
    }

    @objc
    private func didTapProgressView() {
        if
            let downloadTask,
            !downloadTask.isCancelled
        {
            downloadTask.cancel()
        } else if galleryItem.referencedAttachment.asReferencedStream == nil {
            downloadFullsizeIfNeeded(userInitiated: true)
        }
    }

    private func configureMediaView() {
        buildMediaView()
        mediaView.contentMode = .scaleAspectFit
        mediaView.isUserInteractionEnabled = true
        mediaView.clipsToBounds = true
        mediaView.layer.allowsEdgeAntialiasing = true
        // Use trilinear filters for better scaling quality at
        // some performance cost.
        mediaView.layer.minificationFilter = .trilinear
        mediaView.layer.magnificationFilter = .trilinear

        configureTellomiLivePhoto()

        scrollView = ZoomableMediaView(mediaView: mediaView, onSingleTap: { [weak self] in
            guard let self else { return }
            delegate?.mediaItemViewControllerDidTapMedia(self)
        })
        scrollView.delegate = self
    }

    private func buildMediaView() {
        guard mediaView == nil else { return }

        image = galleryItem.referencedAttachment.getThumbnailImageSync(quality: .large)

        let view: UIView
        let referencedAttachmentStream = galleryItem.referencedAttachment.asReferencedStream
        if
            let referencedAttachmentStream,
            referencedAttachmentStream.attachmentStream.contentType.isVideo,
            galleryItem.renderingFlag == .shouldLoop
        {
            if let loopingVideoPlayerView = buildLoopingVideoPlayerView(attachmentStream: referencedAttachmentStream.attachmentStream) {
                loopingVideoPlayerView.delegate = self
                view = loopingVideoPlayerView
            } else {
                view = buildPlaceholderView()
            }
        } else if
            let referencedAttachmentStream,
            let imageMetadata = referencedAttachmentStream.attachmentStream.imageMetadata(),
            imageMetadata.isAnimated
        {
            if let animatedGif = try? referencedAttachmentStream.attachmentStream.decryptedSDAnimatedImage() {
                view = SDAnimatedImageView(image: animatedGif)
            } else {
                view = buildPlaceholderView()
            }
        } else if
            let referencedAttachmentStream,
            isVideo, // TODO: Separate isVideo from isVideoPlayable
            let videoPlayerView = buildVideoPlayerView(referencedAttachmentStream: referencedAttachmentStream)
        {
            videoPlayerView.delegate = self
            videoPlayerView.videoPlayer?.delegate = self

            view = videoPlayerView
        } else if let image {
            // Present the static image using standard UIImageView
            view = UIImageView(image: image)
        } else {
            // Still loading thumbnail.
            view = buildPlaceholderView()
        }

        mediaView = view
    }

    private func buildPlaceholderView() -> UIView {
        let view = UIView()
        view.backgroundColor = Theme.washColor
        return view
    }

    private func buildLoopingVideoPlayerView(attachmentStream: AttachmentStream) -> LoopingVideoView? {
        guard let loopingVideo = LoopingVideo(attachmentStream) else {
            owsFailBeta("Invalid looping video")
            return nil
        }
        let videoView = LoopingVideoView()
        videoView.video = loopingVideo
        return videoView
    }

    private func buildVideoPlayerView(referencedAttachmentStream: ReferencedAttachmentStream) -> VideoPlayerView? {
        guard let videoPlayer = try? VideoPlayer(attachment: referencedAttachmentStream) else {
            owsFailBeta("Invalid attachment")
            return nil
        }

        videoPlayer.seek(to: .zero)

        let videoPlayerView = VideoPlayerView()
        videoPlayerView.videoPlayer = videoPlayer

        return videoPlayerView
    }

    private func layoutMediaView() {
        // HACK: Setting the frame to itself *seems* like it should be a no-op, but
        // it ensures the content is drawn at the right frame. In particular I was
        // reproducibly seeing some images squished (they were EXIF rotated, maybe
        // related). similar to this report:
        // https://stackoverflow.com/questions/27961884/swift-uiimageview-stretched-aspect
        view.layoutIfNeeded()
        mediaView.frame = mediaView.frame

        scrollView.updateZoomScaleForLayout()
        scrollView.zoomScale = scrollView.minimumZoomScale
    }

    private func downloadFullsizeIfNeeded(userInitiated: Bool) {
        guard galleryItem.referencedAttachment.asReferencedStream == nil else { return }

        addProgressViewIfNeeded()

        downloadTask?.cancel()

        downloadTask = MediaGallery.createGalleryItemDownloadTask(
            item: galleryItem,
            priority: userInitiated ? .userInitiated : .default,
        )
        Task {
            await downloadTask?.value
            downloadTask = nil
        }
    }

    // MARK: - UIViewController

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .clear

        configureMediaView()

        view.addSubview(scrollView)
        scrollView.autoPinEdgesToSuperviewEdges()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        layoutMediaView()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if isVideo, shouldAutoPlayVideo, !hasAutoPlayedVideo {
            playVideo()
            hasAutoPlayedVideo = true
        }

        let timestamp = Date().ows_millisecondsSince1970
        let attachmentId = galleryItem.referencedAttachment.attachment.id

        Task {
            await DependenciesBridge.shared.db.awaitableWrite { tx in
                DependenciesBridge.shared.attachmentStore.markViewedFullscreen(
                    attachmentId: attachmentId,
                    timestamp: timestamp,
                    tx: tx,
                )
            }
        }

        downloadFullsizeIfNeeded(userInitiated: false)
    }

    override func viewDidDisappear(_ animated: Bool) {
        if isVideo {
            downloadTask?.cancel()
        }
        super.viewDidDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        scrollView.updateZoomScaleForLayout()
    }

    // MARK: - Helpers

    private var image: UIImage?

    // MARK: - Video Playback

    var shouldAutoPlayVideo: Bool = false

    private var hasAutoPlayedVideo = false

    private var isVideo: Bool {
        galleryItem.isVideo
    }

    private func playVideo() {
        guard let videoPlayerView else {
            owsFailBeta("videoPlayer is nil")
            return
        }

        videoPlayerView.play()
    }

    func stopVideoIfPlaying() {
        if let videoPlayerView {
            videoPlayerView.stop()
        }
    }

    /// Tellomi（#1257，照 Telegram iOS `UniversalVideoGalleryItemNode.centralityUpdated`：视频成为当前那一项、文件在本地就直接播）：
    /// 这一页成了查看器的当前页——刚打开、手指横滑、缩略条跳转都走这里。下载好的视频直接播；还没下载完的，下载完（`replaceGalleryItem`）再播。
    /// 上游翻页不自动播，靠每页正中的播放键；那个键换成跟着四角按钮一起出现的播放 / 暂停以后，停着的视频看上去和图片一样、画面上也没有能点的。
    func tellomiDidBecomeCurrentPage() {
        tellomiAutoplayLiveIfNeeded()
        guard isVideo else { return }
        shouldAutoPlayVideo = true
        guard !hasAutoPlayedVideo, isViewLoaded, videoPlayerView != nil, galleryItem.isVideoReadyToPlay else { return }
        playVideo()
        hasAutoPlayedVideo = true
    }

    /// 不再是当前页：之后下载完也不自己播；翻回来时再算一次「刚翻到」。
    func tellomiDidResignCurrentPage() {
        shouldAutoPlayVideo = false
        hasAutoPlayedVideo = false
        tellomiLiveView?.stop(animated: false)
        setTellomiLiveActive(false)
    }

    // MARK: - Tellomi live photo (#1263, spec R-2)

    private var tellomiLiveView: TellomiLivePhotoView?
    private var hasAutoplayedTellomiLive = false
    private(set) var isTellomiLiveActive = false

    var isTellomiLivePhoto: Bool { tellomiLiveView != nil }

    /// A live photo's moving half sits inside the still (so it zooms with it), shown in full like the still. Holding the
    /// picture plays it with sound until let go (Telegram iOS gallery: hold 0.3 s anywhere).
    private func configureTellomiLivePhoto() {
        tellomiLiveView = nil
        guard galleryItem.tellomiLiveVideo != nil, mediaView is UIImageView else { return }
        let liveView = TellomiLivePhotoView(fill: false)
        mediaView.addSubview(liveView)
        liveView.autoPinEdgesToSuperviewEdges()
        liveView.onStopped = { [weak self] in
            self?.setTellomiLiveActive(false)
        }
        tellomiLiveView = liveView

        let hold = UILongPressGestureRecognizer(target: self, action: #selector(didHoldTellomiLive(_:)))
        hold.minimumPressDuration = 0.3
        mediaView.addGestureRecognizer(hold)
    }

    /// Plays once, muted, the first time this page shows (Telegram iOS `playLivePhotoAutoplayIfNeeded`).
    private func tellomiAutoplayLiveIfNeeded() {
        guard let video = galleryItem.tellomiLiveVideo, let liveView = tellomiLiveView, !hasAutoplayedTellomiLive, !isTellomiLiveActive else {
            return
        }
        hasAutoplayedTellomiLive = true
        Task { [weak self, weak liveView] in
            guard let url = try? await TellomiLivePhoto.fetchVideo(video) else { return }
            guard let self, let liveView, !self.isTellomiLiveActive else { return }
            liveView.play(url, loopWithSound: false)
        }
    }

    /// The viewer's live button: plays looping with sound, or stops.
    func toggleTellomiLive() {
        if isTellomiLiveActive {
            stopTellomiLive()
        } else {
            startTellomiLive()
        }
    }

    private func startTellomiLive() {
        guard let video = galleryItem.tellomiLiveVideo, let liveView = tellomiLiveView else { return }
        setTellomiLiveActive(true)
        Task { [weak self, weak liveView] in
            guard let self else { return }
            guard let url = try? await TellomiLivePhoto.fetchVideo(video) else {
                self.setTellomiLiveActive(false)
                return
            }
            guard let liveView, self.isTellomiLiveActive else { return }
            liveView.play(url, loopWithSound: true)
        }
    }

    private func stopTellomiLive() {
        tellomiLiveView?.stop(animated: true)
        setTellomiLiveActive(false)
    }

    private func setTellomiLiveActive(_ isActive: Bool) {
        guard isTellomiLiveActive != isActive else { return }
        isTellomiLiveActive = isActive
        delegate?.mediaItemViewController(self, tellomiLiveActiveDidChange: isActive)
    }

    @objc
    private func didHoldTellomiLive(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            startTellomiLive()
        case .ended, .cancelled, .failed:
            stopTellomiLive()
        default:
            break
        }
    }

    // MARK: - VideoPlaybackStatusProvider

    weak var videoPlaybackStatusObserver: VideoPlaybackStatusObserver?
}

extension MediaItemViewController: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return mediaView
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        delegate?.mediaItemViewControllerWillBeginZooming(self)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        if scale <= scrollView.minimumZoomScale {
            delegate?.mediaItemViewControllerFullyZoomedOut(self)
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        (scrollView as? ZoomableMediaView)?.updateZoomScaleForLayout()
        view.layoutIfNeeded()
    }
}

extension MediaItemViewController: LoopingVideoViewDelegate {
    func loopingVideoViewChangedPlayerItem() {
        scrollView.updateZoomScaleForLayout()
        scrollView.zoomScale = scrollView.minimumZoomScale
    }
}

extension MediaItemViewController: VideoPlayerDelegate {

    func videoPlayerDidPlayToCompletion(_ videoPlayer: VideoPlayer) {
        guard isVideo, let videoPlayerView else { return }

        // Tellomi（#1257）：30 秒以内的循环；更长的停回开头，并让查看器把控件叫出来。
        if
            let duration = videoPlayer.avPlayer.currentItem?.asset.duration.seconds,
            duration.isFinite, duration > 0, duration <= Self.loopMaxDuration
        {
            videoPlayer.seek(to: .zero)
            videoPlayer.play()
            return
        }

        videoPlayerView.stop()
        delegate?.mediaItemViewControllerVideoDidPlayToEnd(self)
    }
}

extension MediaItemViewController: VideoPlayerViewDelegate {

    func videoPlayerViewStatusDidChange(_ view: VideoPlayerView) {
        if let videoPlaybackStatusObserver, let videoPlayer = view.videoPlayer {
            videoPlaybackStatusObserver.videoPlayerStatusChanged(videoPlayer)
        }
        scrollView.updateZoomScaleForLayout()
    }

    func videoPlayerViewPlaybackTimeDidChange(_ view: VideoPlayerView) {
    }
}
