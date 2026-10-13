//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

class CVMediaView: ManualLayoutViewWithLayer {

    // MARK: -

    private let mediaCache: CVMediaCache
    let attachment: CVAttachment
    private let interaction: TSInteraction
    private let conversationStyle: ConversationStyle
    private let maxMessageWidth: CGFloat
    private let isBorderless: Bool
    private let isLoopingVideo: Bool
    private let thumbnailQuality: AttachmentThumbnailQuality
    private let isBroken: Bool
    private var reusableMediaView: ReusableMediaView?
    private var progressView: CVAttachmentProgressView?
    /// Tellomi (tellomi/tellomi#1263, spec R-1): over a covered (spoiler) image / video until it's uncovered.
    private var tellomiSpoilerCover: TellomiSpoilerCoverView?
    /// Tellomi (tellomi/tellomi#1263, spec R-2): a live photo's moving half, its player and its badge.
    private var tellomiLiveVideo: TellomiLivePhoto.Video?
    private var tellomiLiveView: TellomiLivePhotoView?
    /// Counted as on screen in `TellomiLivePhoto.appeared` / `disappeared` (between `loadMedia` and `unloadMedia`).
    private var isTellomiLiveShowing = false

    // Circular Play / Pause / Download progress etc
    private static let centerButtonSize: CGFloat = 44

    // MARK: - Public

    init(
        mediaCache: CVMediaCache,
        attachment: CVAttachment,
        interaction: TSInteraction,
        maxMessageWidth: CGFloat,
        isBorderless: Bool,
        isLoopingVideo: Bool,
        isBroken: Bool,
        isTellomiSpoilerCovered: Bool = false,
        tellomiLiveVideo: TellomiLivePhoto.Video? = nil,
        thumbnailQuality: AttachmentThumbnailQuality,
        conversationStyle: ConversationStyle,
    ) {
        self.mediaCache = mediaCache
        self.attachment = attachment
        self.interaction = interaction
        self.maxMessageWidth = maxMessageWidth
        self.isBorderless = isBorderless
        self.isLoopingVideo = isLoopingVideo
        self.isBroken = isBroken
        self.thumbnailQuality = thumbnailQuality
        self.conversationStyle = conversationStyle

        super.init(name: "CVMediaView")

        backgroundColor = isBorderless ? .clear : Theme.washColor
        clipsToBounds = true

        createContents()

        if let tellomiLiveVideo {
            self.tellomiLiveVideo = tellomiLiveVideo
            let liveView = TellomiLivePhotoView(fill: true)
            addSubviewToFillSuperviewEdges(liveView)
            tellomiLiveView = liveView

            // Top-left, 8 from the corner (Telegram: `livePhotoIconNode` at (8, 8))
            let badge = CVImageView(image: TellomiLivePhotoView.badgeImage(diameter: Self.tellomiLiveBadgeSize))
            badge.accessibilityLabel = OWSLocalizedString(
                "ATTACHMENT_TYPE_TELLOMI_LIVE_PHOTO",
                comment: "Short text label for a live photo (a still with a few seconds of video), used for thread preview, on the lock screen and on its badge",
            )
            addSubview(badge)
            addLayoutBlock { view in
                let inset: CGFloat = 8
                let x = CurrentAppContext().isRTL ? view.width - (Self.tellomiLiveBadgeSize + inset) : inset
                badge.frame = CGRect(x: x, y: inset, width: Self.tellomiLiveBadgeSize, height: Self.tellomiLiveBadgeSize)
            }
        }

        if isTellomiSpoilerCovered {
            let cover = TellomiSpoilerCoverView()
            addSubviewToFillSuperviewEdges(cover)
            cover.cover(attachment.attachment)
            tellomiSpoilerCover = cover
            // Download / upload progress stays on top (the play button doesn't: it shows once uncovered).
            if let progressView {
                bringSubviewToFront(progressView)
            }
        }
    }

    // MARK: - Tellomi spoiler

    /// Still covered (or being uncovered): a tap uncovers instead of opening the viewer.
    var isTellomiSpoilerCovering: Bool {
        tellomiSpoilerCover?.isCovering == true
    }

    /// Uncovers from [location] (in this view); [completion] runs once the reveal has finished.
    func tellomiRevealSpoiler(from location: CGPoint, completion: @escaping () -> Void) {
        guard let tellomiSpoilerCover else { return }
        tellomiSpoilerCover.reveal(from: convert(location, to: tellomiSpoilerCover), completion: { [weak self] in
            completion()
            self?.tellomiAutoplayLivePhotoIfNeeded()
        })
    }

    // MARK: - Tellomi live photo

    private static let tellomiLiveBadgeSize: CGFloat = 22

    /// A live photo plays its moving half once, muted, every time it comes on screen, then fades back to the still
    /// (spec R-2, owner 2026-10-13 as Telegram: `ChatMessageInteractiveMediaNode` plays it without sound whenever the
    /// bubble becomes visible). The cell being rebuilt for an update isn't a new appearance (`TellomiLivePhoto.appeared`).
    /// Not while it is covered, and not before the still is here: then it plays once uncovered / downloaded, if still on
    /// screen. A tap still opens the viewer.
    private func tellomiAutoplayLivePhotoIfNeeded() {
        guard
            let video = tellomiLiveVideo,
            let liveView = tellomiLiveView,
            isTellomiLiveShowing,
            !isTellomiSpoilerCovering,
            case .stream = attachment,
            TellomiLivePhoto.claimAutoplay(video)
        else {
            return
        }
        Task { [weak self, weak liveView] in
            guard let url = try? await TellomiLivePhoto.fetchVideo(video) else { return }
            guard let self, let liveView, self.window != nil, !self.isTellomiSpoilerCovering else { return }
            liveView.play(url, loopWithSound: false)
        }
    }

    private func tellomiLiveDidAppear() {
        guard let tellomiLiveVideo, !isTellomiLiveShowing else { return }
        isTellomiLiveShowing = true
        TellomiLivePhoto.appeared(tellomiLiveVideo)
    }

    private func tellomiLiveDidDisappear() {
        guard let tellomiLiveVideo, isTellomiLiveShowing else { return }
        isTellomiLiveShowing = false
        TellomiLivePhoto.disappeared(tellomiLiveVideo)
    }

    deinit {
        // Dropped without being unloaded: still counts as leaving the screen
        if isTellomiLiveShowing, let tellomiLiveVideo {
            TellomiLivePhoto.disappeared(tellomiLiveVideo)
        }
    }

    func loadMedia() {
        AssertIsOnMainThread()
        defer {
            tellomiLiveDidAppear()
            tellomiAutoplayLivePhotoIfNeeded()
        }

        guard let reusableMediaView else {
            return
        }
        guard reusableMediaView.owner != nil else {
            Logger.warn("No longer owner of reusableMediaView.")
            return
        }
        guard reusableMediaView.owner === self else {
            owsFailDebug("No longer owner of reusableMediaView.")
            return
        }

        reusableMediaView.load()
    }

    func unloadMedia() {
        AssertIsOnMainThread()
        tellomiLiveView?.stop(animated: false)
        tellomiLiveDidDisappear()

        guard let reusableMediaView else {
            return
        }
        guard reusableMediaView.owner === self else {
            // No longer owner of reusableMediaView.
            return
        }

        reusableMediaView.unload()
    }

    // MARK: -

    private func createContents() {
        AssertIsOnMainThread()

        switch attachment {
        case .undownloadable(let attachment):
            configureForError(attachment: attachment.attachment)

        case .backupThumbnail(let thumbnail):
            configureForBackupThumbnailMedia(thumbnail.attachmentBackupThumbnail)

        case .pointer(let pointer, _):
            configureForUndownloadedMedia(pointer.attachment)

        case .stream(let attachmentStream, isUploading: _, let imageMetadata):
            let attachmentStream = attachmentStream.attachmentStream
            switch attachmentStream.contentType {
            case .image:
                if let imageMetadata, imageMetadata.isAnimated {
                    configureForAnimatedImage(attachmentStream: attachmentStream)
                } else {
                    configureForStillImage(attachmentStream: attachmentStream)
                }
            case .video where isLoopingVideo:
                configureForLoopingVideo(attachmentStream: attachmentStream)
            case .video:
                configureForVideo(attachmentStream: attachmentStream)
            case .audio, .file:
                owsFailDebug("Attachment has unexpected type.")
                configureForError(attachment: attachmentStream.attachment)
            }
        }
    }

    private func configureForBackupThumbnailMedia(_ thumbnail: AttachmentBackupThumbnail) {
        configureForBackupThumbnail(attachmentBackupThumbnail: thumbnail)

        addProgressViewIfNeeded()
    }

    private func configureForUndownloadedMedia(_ attachment: Attachment) {
        if let thumbnail = attachment.asBackupThumbnail() {
            configureForBackupThumbnail(attachmentBackupThumbnail: thumbnail)
        } else {
            tryToConfigureForBlurHash(attachment: attachment)
        }

        addProgressViewIfNeeded()
    }

    @discardableResult
    private func addProgressViewIfNeeded() -> Bool {
        let direction: CVAttachmentProgressView.Direction
        switch CVAttachmentProgressView.progressType(
            cvAttachment: attachment,
        ) {
        case .none:
            removeProgressView()
            return false

        case .skipped:
            // We don't need to add a download indicator for pending
            // attachments; CVComponentBodyMedia will add a download
            // button if any media in the gallery is pending.
            removeProgressView()
            return false

        case .uploading:
            direction = .upload(attachmentID: attachment.attachmentID)

        case .downloading(let downloadState):
            direction = .download(
                attachmentID: attachment.attachmentID,
                downloadState: downloadState,
            )
        }

        let progressView = ensureProgressView(direction: direction)
        if progressView.superview == nil {
            addSubviewToCenterOnSuperview(progressView, size: .square(44))
        }

        return true
    }

    private func ensureProgressView(direction: CVAttachmentProgressView.Direction) -> CVAttachmentProgressView {
        if let progressView {
            return progressView
        }
        let progressView = CVAttachmentProgressView(
            direction: direction,
            configuration: .forMediaOverlay(),
        )
        self.progressView = progressView
        return progressView
    }

    private func removeProgressView() {
        guard let progressView else { return }

        progressView.removeFromSuperview()
        self.progressView = nil
    }

    private func configureImageView(_ imageView: UIImageView) {
        // We need to specify a contentMode since the size of the image
        // might not match the aspect ratio of the view.
        imageView.contentMode = .scaleAspectFill
        // Use trilinear filters for better scaling quality at
        // some performance cost.
        imageView.layer.minificationFilter = .trilinear
        imageView.layer.magnificationFilter = .trilinear
    }

    private func applyReusableMediaView(_ reusableMediaView: ReusableMediaView) {
        reusableMediaView.owner = self
        self.reusableMediaView = reusableMediaView
        let mediaView = reusableMediaView.mediaView

        mediaView.removeFromSuperview()
        mediaView.translatesAutoresizingMaskIntoConstraints = false
        addSubviewToFillSuperviewEdges(mediaView)

        if let imageView = mediaView as? UIImageView {
            configureImageView(imageView)
        }
        mediaView.backgroundColor = isBorderless ? .clear : Theme.washColor

        if addProgressViewIfNeeded() == false, reusableMediaView.isVideo {
            addVideoPlayButton()
        }
    }

    private func createNewReusableMediaView(mediaViewAdapter: MediaViewAdapter, isAnimated: Bool) {
        let reusableMediaView = ReusableMediaView(mediaViewAdapter: mediaViewAdapter, mediaCache: mediaCache)
        mediaCache.setMediaView(reusableMediaView, forKey: mediaViewAdapter.cacheKey, isAnimated: isAnimated)
        applyReusableMediaView(reusableMediaView)
    }

    private func tryToConfigureForBlurHash(attachment: Attachment) {
        guard let blurHash = attachment.blurHash?.nilIfEmpty else { return }

        // NOTE: in the blurhash case, we use the blurHash itself as the
        // cachekey to avoid conflicts with the actual attachment contents.
        let cacheKey = CVMediaCache.CacheKey.blurHash(blurHash)
        let isAnimated = false
        if let reusableMediaView = mediaCache.getMediaView(cacheKey, isAnimated: isAnimated) {
            applyReusableMediaView(reusableMediaView)
            return
        }

        let mediaViewAdapter = MediaViewAdapterBlurHash(blurHash: blurHash)
        createNewReusableMediaView(mediaViewAdapter: mediaViewAdapter, isAnimated: isAnimated)
    }

    private func configureForLoopingVideo(attachmentStream: AttachmentStream) {
        if let reusableMediaView = mediaCache.getMediaView(.attachment(attachmentStream.id), isAnimated: true) {
            applyReusableMediaView(reusableMediaView)
            return
        }

        let mediaViewAdapter = MediaViewAdapterLoopingVideo(attachmentStream: attachmentStream)
        createNewReusableMediaView(mediaViewAdapter: mediaViewAdapter, isAnimated: true)
    }

    private func configureForAnimatedImage(attachmentStream: AttachmentStream) {
        let cacheKey = CVMediaCache.CacheKey.attachment(attachmentStream.id)
        if let reusableMediaView = mediaCache.getMediaView(cacheKey, isAnimated: true) {
            applyReusableMediaView(reusableMediaView)
            return
        }

        let mediaViewAdapter = MediaViewAdapterAnimated(attachmentStream: attachmentStream)
        createNewReusableMediaView(mediaViewAdapter: mediaViewAdapter, isAnimated: true)
    }

    private func configureForStillImage(attachmentStream: AttachmentStream) {
        let cacheKey = CVMediaCache.CacheKey.attachment(attachmentStream.id)
        if let reusableMediaView = mediaCache.getMediaView(cacheKey, isAnimated: false) {
            applyReusableMediaView(reusableMediaView)
            return
        }

        let mediaViewAdapter = MediaViewAdapterStill(
            attachmentStream: attachmentStream,
            thumbnailQuality: thumbnailQuality,
        )
        createNewReusableMediaView(mediaViewAdapter: mediaViewAdapter, isAnimated: false)
    }

    private func configureForVideo(attachmentStream: AttachmentStream) {
        let cacheKey = CVMediaCache.CacheKey.attachment(attachmentStream.id)
        if let reusableMediaView = mediaCache.getMediaView(cacheKey, isAnimated: false) {
            applyReusableMediaView(reusableMediaView)
            return
        }

        let mediaViewAdapter = MediaViewAdapterVideo(
            attachmentStream: attachmentStream,
            thumbnailQuality: thumbnailQuality,
        )
        createNewReusableMediaView(mediaViewAdapter: mediaViewAdapter, isAnimated: false)
    }

    private func configureForBackupThumbnail(attachmentBackupThumbnail: AttachmentBackupThumbnail) {
        let cacheKey = CVMediaCache.CacheKey.backupThumbnail(attachmentBackupThumbnail.id)
        if let reusableMediaView = mediaCache.getMediaView(cacheKey, isAnimated: false) {
            applyReusableMediaView(reusableMediaView)
            return
        }

        let mediaViewAdapter = MediaViewAdapterBackupThumbnail(attachmentBackupThumbnail: attachmentBackupThumbnail)
        createNewReusableMediaView(mediaViewAdapter: mediaViewAdapter, isAnimated: false)
    }

    private func addVideoPlayButton() {
        let playIconImage = isBroken ? UIImage(named: "play-slash-fill")! : UIImage(named: "play-fill")!
        addIconOverCircularBlurBackground(playIconImage)
    }

    private var hasBlurHash: Bool {
        return BlurHash.isValidBlurHash(attachment.attachment.attachment.blurHash)
    }

    private func configureForError(attachment: Attachment) {
        if attachment.blurHash != nil {
            tryToConfigureForBlurHash(attachment: attachment)
        } else {
            backgroundColor = (Theme.isDarkThemeEnabled ? .ows_gray90 : .ows_gray05)
        }

        addIconOverCircularBlurBackground(UIImage(named: "photo-slash")!)
    }

    private func addIconOverCircularBlurBackground(_ image: UIImage) {
        let circleView = ManualLayoutView.circleView(name: "circleView")
        circleView.clipsToBounds = true
        circleView.isUserInteractionEnabled = false
        addSubviewToCenterOnSuperview(circleView, size: CGSize(square: Self.centerButtonSize))

        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        circleView.addSubviewToFillSuperviewEdges(blurView)

        let iconView = CVImageView(image: image)
        iconView.tintColor = .Signal.label
        iconView.isUserInteractionEnabled = false
        circleView.addSubviewToCenterOnSuperview(iconView, size: image.size)

    }
}
