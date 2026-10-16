//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI

protocol ConversationHeaderViewDelegate: AnyObject {
    func didTapConversationHeaderView(_ conversationHeaderView: ConversationHeaderView)
    func didTapConversationHeaderViewAvatar(_ conversationHeaderView: ConversationHeaderView)
}

class ConversationHeaderView: UIView {

    weak var delegate: ConversationHeaderViewDelegate?

    var titleIcon: UIImage? {
        get {
            return titleIconView.image
        }
        set {
            titleIconView.image = newValue
            titleIconView.isHidden = newValue == nil
        }
    }

    let titleLabel: UILabel = {
        let label = UILabel()
        label.textColor = UIColor.Signal.label
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.setContentHuggingHigh()
        return label
    }()

    let subtitleLabel: UILabel = {
        let label = UILabel()
        label.textColor = .Signal.label
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.setContentHuggingHigh()
        return label
    }()

    private let titleIconView: UIImageView = {
        let titleIconView = UIImageView()
        titleIconView.isHidden = true
        titleIconView.contentMode = .scaleAspectFit
        titleIconView.setCompressionResistanceHigh()
        return titleIconView
    }()

    private var titleIconSizeConstraint: NSLayoutConstraint!

    private var avatarSizeClass: ConversationAvatarView.Configuration.SizeClass {
        // One size for the navigation bar on iOS 26.
        guard #unavailable(iOS 26) else { return .forty }

        return traitCollection.verticalSizeClass == .compact && !UIDevice.current.isPlusSizePhone
            ? .twentyFour
            : .thirtySix
    }

    private(set) lazy var avatarView = ConversationAvatarView(
        sizeClass: avatarSizeClass,
        localUserDisplayMode: .noteToSelf,
    )

    override init(frame: CGRect) {
        super.init(frame: frame)

        translatesAutoresizingMaskIntoConstraints = false

        let titleColumns = UIStackView(arrangedSubviews: [titleLabel, titleIconView])
        titleColumns.spacing = 5
        titleColumns.translatesAutoresizingMaskIntoConstraints = false
        // There is a strange bug where an initial height of 0
        // breaks the layout, so set an initial height.
        titleColumns.heightAnchor.constraint(greaterThanOrEqualToConstant: titleLabel.font.lineHeight.rounded(.up)).isActive = true

        let textRows = UIStackView(arrangedSubviews: [titleColumns, subtitleLabel])
        tellomiTextRows = textRows
        textRows.axis = .vertical
        textRows.alignment = .leading
        textRows.distribution = .fillProportionally

        let rootStack = UIStackView(arrangedSubviews: [avatarView, textRows])
        rootStack.directionalLayoutMargins = .init(hMargin: 0, vMargin: 4)
        if #available(iOS 26, *) {
            // Default iOS 26 spacing between round back button and this view's leading edge is 12 pts.
            // We want 16 pts between back button and profile picture.
            rootStack.directionalLayoutMargins.leading = 4
        }
        rootStack.isLayoutMarginsRelativeArrangement = true
        rootStack.axis = .horizontal
        rootStack.alignment = .center
        // Larger profile picture on iOS 26 requires larger padding on both sides.
        rootStack.spacing = if #available(iOS 26, *) { 12 } else { 8 }

        addSubview(rootStack)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        titleIconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleIconView.heightAnchor.constraint(equalToConstant: 16),
            titleIconView.widthAnchor.constraint(equalTo: titleIconView.heightAnchor),

            rootStack.topAnchor.constraint(equalTo: topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Embed a small glass view behind the avatar so that it's never visible to the user.
        // Glass views react to content underneath and update appearance (light / dark)
        // automatically. Using newer API for detecting trait collection changes it's now
        // possible to attach a small handler that will force UILabels to have
        // the same light or dark style as the glass view.
        if
            #available(iOS 26, *),
            CurrentAppContext().appUserDefaults().bool(forKey: "DisableChatHeaderContentTracking") == false
        {
            let glassTrackingView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
            rootStack.insertSubview(glassTrackingView, at: 0)
            glassTrackingView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                glassTrackingView.widthAnchor.constraint(equalToConstant: 10),
                glassTrackingView.heightAnchor.constraint(equalToConstant: 10),
                glassTrackingView.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
                glassTrackingView.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            ])

            glassTrackingView.contentView.registerForTraitChanges(
                [UITraitUserInterfaceStyle.self],
                handler: { [weak textRows] (view: UIView, _) in
                    textRows?.overrideUserInterfaceStyle = view.traitCollection.userInterfaceStyle
                },
            )
        }

        if #available(iOS 26, *) {
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(didTapView))
        rootStack.addGestureRecognizer(tapGesture)

        tellomiConfigurePressFeedback(on: rootStack)
    }

    // MARK: - Tellomi：按下态（交互审计 A-09「顶栏标题没有按下态」）

    /// 名字和副标题那一列（按下时变淡）。
    private var tellomiTextRows: UIView?
    private let tellomiPressObserver = TellomiPressTouchObserver(target: nil, action: nil)
    private weak var tellomiPressedView: UIView?
    private var tellomiPressStart: CGPoint?

    /// 按下时变到这个透明度、松开 0.2 s 淡回（照 Telegram iOS `ChatTitleView`：标题、副标题按下 0.4，松开 0.2 s）。
    static let tellomiPressedAlpha: CGFloat = 0.4
    static let tellomiReleaseDuration: TimeInterval = 0.2

    private func tellomiConfigurePressFeedback(on rootStack: UIView) {
        tellomiPressObserver.onBegan = { [weak self, weak rootStack] touch in
            guard let self, let rootStack else {
                return
            }
            self.tellomiPressBegan(at: touch.location(in: rootStack), in: rootStack)
        }
        tellomiPressObserver.onMoved = { [weak self] touch in
            guard let self, let start = self.tellomiPressStart else {
                return
            }
            let point = touch.location(in: nil)
            if hypot(point.x - start.x, point.y - start.y) > TellomiPressFeedback.moveSlop {
                self.tellomiPressEnded()
            }
        }
        tellomiPressObserver.onEnded = { [weak self] in
            self?.tellomiPressEnded()
        }
        rootStack.addGestureRecognizer(tellomiPressObserver)
    }

    /// 按在头像上淡头像（点头像是另一件事），按在别处淡名字那一列（点了进会话设置）。
    func tellomiPressBegan(at point: CGPoint, in rootStack: UIView) {
        let target: UIView? = avatarView.frame.contains(point) ? avatarView : tellomiTextRows
        guard let target else {
            return
        }
        tellomiPressEnded(animated: false)
        tellomiPressedView = target
        tellomiPressStart = rootStack.convert(point, to: nil)
        target.layer.removeAnimation(forKey: "opacity")
        target.alpha = Self.tellomiPressedAlpha
    }

    func tellomiPressEnded(animated: Bool = true) {
        guard let view = tellomiPressedView else {
            return
        }
        tellomiPressedView = nil
        tellomiPressStart = nil
        guard animated else {
            view.alpha = 1
            return
        }
        UIView.animate(withDuration: Self.tellomiReleaseDuration, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            view.alpha = 1
        }
    }

    var tellomiTextRowsForTesting: UIView? { tellomiTextRows }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(threadViewModel: ThreadViewModel) {
        avatarView.updateWithSneakyTransactionIfNecessary { config in
            if threadViewModel.threadRecord.isReleaseNotesThread {
                config.dataSource = .asset(avatar: AvatarBuilder.releaseNotesIcon(), badge: nil)
            } else {
                config.dataSource = .thread(threadViewModel.threadRecord)
            }

            config.storyConfiguration = .autoUpdate()
            config.applyConfigurationSynchronously()
        }
    }

    override var intrinsicContentSize: CGSize {
        // Grow to fill as much of the navbar as possible.
        return .init(width: .greatestFiniteMagnitude, height: UIView.noIntrinsicMetric)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        // One size for the navigation bar on iOS 26.
        guard #unavailable(iOS 26) else { return }

        guard traitCollection.verticalSizeClass != previousTraitCollection?.verticalSizeClass else { return }
        avatarView.updateWithSneakyTransactionIfNecessary { config in
            config.sizeClass = avatarSizeClass
        }
    }

    // MARK: Spinning Title

    func updateTitleSpinning() {
        let key = "spin"
        if InMemorySettings.spinningConversationTitle {
            guard layer.animation(forKey: key) == nil else { return }
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.toValue = NSNumber(value: Double.pi * 2)
            animation.duration = 1
            animation.isCumulative = true
            animation.repeatCount = .greatestFiniteMagnitude
            layer.add(animation, forKey: key)
        } else {
            layer.removeAnimation(forKey: key)
        }
    }

    // MARK: Delegate Methods

    @objc
    private func didTapView(tapGesture: UITapGestureRecognizer) {
        guard tapGesture.state == .recognized else {
            return
        }

        if avatarView.bounds.contains(tapGesture.location(in: avatarView)) {
            self.delegate?.didTapConversationHeaderViewAvatar(self)
        } else {
            self.delegate?.didTapConversationHeaderView(self)
        }
    }
}
