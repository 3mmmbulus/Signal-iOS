//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import PureLayout
import SignalServiceKit

public class ToastController: NSObject, ToastViewDelegate {

    static var currentToastController: ToastController?

    private weak var toastView: ToastView?
    private var isDismissing: Bool
    private let toastText: String
    private let toastIcon: UIImage?

    // MARK: Initializers

    public init(text: String, image: UIImage? = nil) {
        self.toastText = text
        self.toastIcon = image
        isDismissing = false

        super.init()

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide), name: UIResponder.keyboardDidHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidAppear), name: UIResponder.keyboardDidShowNotification, object: nil)
    }

    // MARK: Public

    public func presentToastView(
        from edge: ALEdge,
        of view: UIView,
        inset: CGFloat,
        dismissAfter: DispatchTimeInterval = .seconds(4),
    ) {
        let toastView = ToastView()
        toastView.text = self.toastText
        toastView.tellomiEmphasize(tellomiBoldTexts)
        if let tellomiAction {
            toastView.tellomiSetAction(title: tellomiAction.title) { [weak self] in
                self?.dismissToastView()
                tellomiAction.handler()
            }
        }
        toastView.image = self.toastIcon
        toastView.delegate = self
        self.toastView = toastView

        owsAssertDebug(edge == .bottom || edge == .top)
        // Tellomi（交互审计 A-30）：拖着滑走时，往贴着的那条边是「走」的方向。
        toastView.tellomiTowardEdgeSign = (edge == .top) ? -1 : 1
        if tellomiAction != nil {
            // 可撤销的：左边倒计时，走完就收起
            toastView.tellomiStartCountdown(duration: dismissAfter.tellomiSeconds)
        }
        let offset = (edge == .top) ? inset : -inset

        // Add to the first non-scrollview in the hierarchy, but still pin to the original view.
        // We don't want the toast to be a subview of any scrollview or it will be subject to scrolling.
        var parentView = view
        while parentView is UIScrollView, let superview = view.superview {
            parentView = superview
        }

        Logger.debug("")
        parentView.addSubview(toastView)
        toastView.setCompressionResistanceHigh()

        self.viewToPinTo = view
        self.offset = offset
        if
            edge == .bottom,
            // If keyboard is closed, its layout guide height is equivalent to the bottom safe area inset.
            view.keyboardLayoutGuide.layoutFrame.height > view.safeAreaInsets.totalHeight
        {
            let constraint = keyboardConstraint(toastView: toastView, viewOwningKeyboard: view)
            NSLayoutConstraint.activate([constraint])
            self.toastBottomConstraint = constraint
        } else {
            self.toastBottomConstraint = toastView.autoPinEdge(edge, to: edge, of: view, withOffset: offset)
        }

        // As wide as possible, not exceeding 512 pt, and not exceeding superview width
        toastView.autoSetDimension(.width, toSize: 512, relation: .lessThanOrEqual)
        toastView.centerXAnchor.constraint(equalTo: parentView.safeAreaLayoutGuide.centerXAnchor).isActive = true

        toastView.autoPinEdge(toSuperviewSafeArea: .leading, withInset: 8, relation: .greaterThanOrEqual)
        toastView.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 8, relation: .greaterThanOrEqual)
        toastView.autoPinEdge(toSuperviewSafeArea: .leading, withInset: 8).priority = .defaultHigh
        toastView.autoPinEdge(toSuperviewSafeArea: .trailing, withInset: 8).priority = .defaultHigh

        if let currentToastController = type(of: self).currentToastController {
            currentToastController.dismissToastView()
            type(of: self).currentToastController = nil
        }
        type(of: self).currentToastController = self

        toastView.animateIn()

        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + dismissAfter) {
            // intentional strong reference to self.
            // As with an AlertController, the caller likely expects toast to
            // be presented and dismissed without maintaining a strong reference to ToastController
            self.dismissToastView()
        }
    }

    // MARK: - Keyboard

    private var toastBottomConstraint: NSLayoutConstraint?
    private var viewToPinTo: UIView?
    private var offset: CGFloat?

    private func keyboardConstraint(toastView: ToastView, viewOwningKeyboard: UIView) -> NSLayoutConstraint {
        return NSLayoutConstraint(
            item: toastView,
            attribute: .bottom,
            relatedBy: .equal,
            toItem: viewOwningKeyboard.keyboardLayoutGuide,
            attribute: .top,
            multiplier: 1.0,
            constant: -8,
        )
    }

    @objc
    private func keyboardDidAppear() {
        keyboardPresenceDidChange(isPresent: true)
    }

    @objc
    private func keyboardDidHide() {
        keyboardPresenceDidChange(isPresent: false)
    }

    private func keyboardPresenceDidChange(isPresent: Bool) {
        if
            let constraint = self.toastBottomConstraint,
            let view = self.viewToPinTo,
            let offset,
            let toastView
        {
            NSLayoutConstraint.deactivate([constraint])
            let newConstraint: NSLayoutConstraint
            if isPresent {
                newConstraint = keyboardConstraint(toastView: toastView, viewOwningKeyboard: view)
            } else {
                newConstraint = toastView.autoPinEdge(.bottom, to: .bottom, of: view, withOffset: offset)
            }
            NSLayoutConstraint.activate([newConstraint])
            self.toastBottomConstraint = newConstraint
        }
    }

    // MARK: ToastViewDelegate

    func didTapToastView(_ toastView: ToastView) {
        Logger.debug("")
        self.dismissToastView()
        tellomiOnTap?()
    }

    /// Tellomi：点提示条时额外做的事（「已收藏，点击查看」打开「我的收藏」，#1174）。
    public var tellomiOnTap: (() -> Void)?

    /// Tellomi：提示条里要加粗的片段（「已转发给 **小林**」，#1259）。
    public var tellomiBoldTexts: [String] = []

    /// Tellomi（交互审计 A-24）：提示条右边的操作键（「撤销」）。点它先收起提示条再执行；点提示条别处只收起。
    public var tellomiAction: (title: String, handler: () -> Void)?

    func didSwipeToastView(_ toastView: ToastView) {
        Logger.debug("")
        self.dismissToastView()
    }

    /// Tellomi（交互审计 A-30）：手指把提示条甩出去了（飞出去的动画提示条自己播完）：直接拿掉，不再播收起动画。
    func tellomiToastViewDidFlingAway(_ toastView: ToastView) {
        guard !isDismissing else {
            return
        }
        isDismissing = true
        if type(of: self).currentToastController == self {
            type(of: self).currentToastController = nil
        }
        toastView.removeFromSuperview()
        self.toastView = nil
    }

    /// Tellomi（tellomi/tellomi#1263 P-4）：「碰一下屏幕就消失」的提示由调用方收起（同 Telegram iOS `TooltipInfoScreen`）。
    public func tellomiDismiss() {
        dismissToastView()
    }

    // MARK: Internal

    func dismissToastView() {
        Logger.debug("")

        guard !isDismissing, let toastView else {
            return
        }
        // Tellomi（交互审计 A-30）：手指正拖着：等松手再收（松手弹回就收起，甩出去就跟着飞走）。
        if toastView.tellomiIsDragging {
            toastView.tellomiDismissWhenReleased = true
            return
        }
        isDismissing = true

        if type(of: self).currentToastController == self {
            type(of: self).currentToastController = nil
        }

        toastView.animateOut {
            toastView.removeFromSuperview()
            self.toastView = nil
        }
    }
}

protocol ToastViewDelegate: AnyObject {
    func didTapToastView(_ toastView: ToastView)
    func didSwipeToastView(_ toastView: ToastView)
    func tellomiToastViewDidFlingAway(_ toastView: ToastView)
}

class ToastView: UIView {

    var text: String? {
        get {
            return label.text
        }
        set {
            label.text = newValue
        }
    }

    var image: UIImage? {
        didSet {
            imageView.image = image
            imageView.isHiddenInStackView = (image == nil)
        }
    }

    /// Tellomi（#1259）：把文字里的这些片段加粗
    func tellomiEmphasize(_ boldTexts: [String]) {
        guard !boldTexts.isEmpty, let text = label.text, let font = label.font else {
            return
        }
        let attributedText = NSMutableAttributedString(string: text, attributes: [.font: font])
        let boldFont = font.semibold()
        for boldText in boldTexts where !boldText.isEmpty {
            let range = (text as NSString).range(of: boldText)
            if range.location != NSNotFound {
                attributedText.addAttribute(.font, value: boldFont, range: range)
            }
        }
        label.attributedText = attributedText
    }

    var tellomiAttributedTextForTesting: NSAttributedString? { label.attributedText }

    private var tellomiActionHandler: (() -> Void)?
    private(set) var tellomiActionButton: UIButton?

    /// Tellomi（交互审计 A-24）：右边加一个操作键（「撤销」）。字用深色外观下的强调色（亮一些的蓝），在深色 / 玻璃底上看得清；
    /// 按钮自己接点按，不会再触发整条提示条的点按。
    func tellomiSetAction(title: String, handler: @escaping () -> Void) {
        tellomiActionHandler = handler
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([.font: label.font.semibold()]))
        configuration.baseForegroundColor = UIColor.Signal.accent.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 0)
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.tellomiActionHandler?()
        })
        button.setContentHuggingHorizontalHigh()
        button.setCompressionResistanceHorizontalHigh()
        // 文字先按一行排开，排不下（到提示条最宽）才折行；不然按钮的抗压更高，文字会被挤成一字一行。
        label.setContentCompressionResistancePriority(.required - 1, for: .horizontal)
        stackView.addArrangedSubview(button)
        tellomiActionButton = button
    }

    weak var delegate: ToastViewDelegate?

    private let backgroundView = UIVisualEffectView(effect: nil)
    private let stackView: UIStackView
    private let label: UILabel
    private let imageView = UIImageView()

    @available(iOS 26.3, *)
    private var glassEffect: UIGlassEffect {
        let glassEffect = UIGlassEffect(style: .regular)
        glassEffect.tintColor = UIColor(
            light: UIColor(rgbHex: 0x3C3C43, alpha: 0.64),
            dark: UIColor(rgbHex: 0xEBEBF5, alpha: 0.24),
        )
        return glassEffect
    }

    // MARK: Initializers

    override init(frame: CGRect) {
        label = UILabel()
        stackView = UIStackView(arrangedSubviews: [label])
        super.init(frame: frame)

        addSubview(backgroundView)

        // iOS 26.0 through 26.2 have a bug where the glass effect tint color
        // would not be present during animations. This was fixed in 26.3.
        if #available(iOS 26.3, *) {
            stackView.insertArrangedSubview(imageView, at: 0)
            imageView.autoSetDimensions(to: .square(24))

            backgroundView.effect = glassEffect
            backgroundView.contentView.layoutMargins = .init(hMargin: 20, vMargin: 14)
            backgroundView.cornerConfiguration = .capsule(maximumRadius: 26)

            backgroundView.autoPinHeightToSuperview()
            backgroundView.autoPinWidthToSuperview(relation: .lessThanOrEqual)
            backgroundView.autoHCenterInSuperview()

            label.font = .dynamicTypeBody
        } else {
            backgroundView.effect = UIBlurEffect(style: .dark)
            backgroundView.contentView.layoutMargins = .init(margin: 12)

            backgroundView.autoPinEdgesToSuperviewEdges()

            self.layer.cornerRadius = 12
            self.clipsToBounds = true

            label.font = UIFont.dynamicTypeSubheadline
        }

        if #unavailable(iOS 26.3) {
            let darkThemeBackgroundOverlay = UIView()
            addSubview(darkThemeBackgroundOverlay)
            darkThemeBackgroundOverlay.autoPinEdgesToSuperviewEdges()
            darkThemeBackgroundOverlay.backgroundColor = UIColor(
                light: .clear,
                dark: UIColor.white.withAlphaComponent(0.10),
            )
        }

        imageView.tintColor = .white

        label.textColor = .white
        label.numberOfLines = 0

        stackView.axis = .horizontal
        stackView.spacing = 12
        stackView.alignment = .center
        backgroundView.contentView.addSubview(stackView)
        stackView.autoPinEdgesToSuperviewMargins()

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(didTap(gesture:)))
        self.addGestureRecognizer(tapGesture)

        // Tellomi（交互审计 A-30）：滑走跟手（原来是离散的 UISwipeGestureRecognizer）。
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(tellomiDidPan(_:)))
        self.addGestureRecognizer(panGesture)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Gestures

    @objc
    private func didTap(gesture: UITapGestureRecognizer) {
        self.delegate?.didTapToastView(self)
    }

    // MARK: Tellomi：拖着滑走（交互审计 A-30）

    /// 贴底边 1、贴顶边 -1（`ToastController` 放上去时设）。
    var tellomiTowardEdgeSign: CGFloat = 1
    var tellomiIsDragging = false
    /// 拖着的时候到点了：松手再收。
    var tellomiDismissWhenReleased = false
    private var tellomiAnimator: UIViewPropertyAnimator?
    private(set) var tellomiCountdownView: TellomiToastCountdownView?

    func tellomiStartCountdown(duration: TimeInterval) {
        guard duration > 0 else {
            return
        }
        let countdownView = tellomiCountdownView ?? {
            let view = TellomiToastCountdownView()
            view.autoSetDimensions(to: .square(TellomiToastCountdownView.diameter))
            stackView.insertArrangedSubview(view, at: 0)
            tellomiCountdownView = view
            return view
        }()
        countdownView.start(duration: duration)
    }

    @objc
    private func tellomiDidPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: superview)
        switch gesture.state {
        case .began:
            tellomiIsDragging = true
            // 正在进场 / 弹回：落到终点，交给手指
            if let animator = tellomiAnimator, animator.state == .active {
                animator.stopAnimation(false)
                animator.finishAnimation(at: .end)
            }
            tellomiAnimator = nil
            tellomiDragChanged(translation: translation)
        case .changed:
            tellomiDragChanged(translation: translation)
        case .ended, .cancelled, .failed:
            tellomiIsDragging = false
            let velocity = gesture.state == .ended ? gesture.velocity(in: superview) : .zero
            tellomiDragEnded(translation: translation, velocity: velocity)
        default:
            break
        }
    }

    func tellomiDragChanged(translation: CGPoint) {
        let offset = TellomiToastDrag.displayedOffset(translation: translation, towardEdgeSign: tellomiTowardEdgeSign)
        transform = CGAffineTransform(translationX: offset.x, y: offset.y)
    }

    func tellomiDragEnded(translation: CGPoint, velocity: CGPoint, reduceMotion: Bool = TellomiMotion.isReduceMotionEnabled) {
        let offset = TellomiToastDrag.displayedOffset(translation: translation, towardEdgeSign: tellomiTowardEdgeSign)
        switch TellomiToastDrag.outcome(translation: translation, velocity: velocity, size: bounds.size, towardEdgeSign: tellomiTowardEdgeSign) {
        case .stay:
            let animator = TellomiMotion.animator(
                TellomiMotion.release,
                initialVelocity: TellomiMotion.relativeVelocity(velocity, remaining: CGVector(dx: -offset.x, dy: -offset.y)),
                reduceMotion: reduceMotion,
            ) {
                self.transform = .identity
            }
            animator.addCompletion { [weak self] _ in
                guard let self, self.tellomiDismissWhenReleased, !self.tellomiIsDragging else {
                    return
                }
                self.tellomiDismissWhenReleased = false
                self.delegate?.didSwipeToastView(self)
            }
            tellomiAnimator = animator
            animator.startAnimation()
        case .dismissHorizontally(let sign):
            tellomiFlingAway(to: CGPoint(x: sign * max(bounds.width, superview?.bounds.width ?? 0), y: offset.y), from: offset, velocity: velocity, reduceMotion: reduceMotion)
        case .dismissTowardEdge:
            let distance = bounds.height + (superview?.safeAreaInsets.bottom ?? 0) + 40
            tellomiFlingAway(to: CGPoint(x: offset.x, y: tellomiTowardEdgeSign * distance), from: offset, velocity: velocity, reduceMotion: reduceMotion)
        }
    }

    /// 从手指的速度接着飞出去（不回弹），飞完拿掉；减弱动态效果时原地淡掉。
    private func tellomiFlingAway(to target: CGPoint, from offset: CGPoint, velocity: CGPoint, reduceMotion: Bool) {
        let animator: UIViewPropertyAnimator
        if reduceMotion {
            animator = UIViewPropertyAnimator(duration: TellomiMotion.reducedMotionCrossfadeDuration, curve: .easeOut) {
                self.tellomiSetContentHidden(true)
            }
        } else {
            animator = TellomiMotion.animator(
                TellomiMotion.snap.withoutBounce,
                initialVelocity: TellomiMotion.relativeVelocity(velocity, remaining: CGVector(dx: target.x - offset.x, dy: target.y - offset.y)),
                reduceMotion: false,
            ) {
                self.transform = CGAffineTransform(translationX: target.x, y: target.y)
                self.tellomiSetContentHidden(true)
            }
        }
        animator.addCompletion { [weak self] _ in
            guard let self else {
                return
            }
            self.delegate?.tellomiToastViewDidFlingAway(self)
        }
        tellomiAnimator = animator
        animator.startAnimation()
    }

    /// 收起时怎么变没：iOS 26.3+ 是玻璃退回去、内容淡掉（不能给玻璃的父视图做透明度动画），更早的整条淡掉。
    private func tellomiSetContentHidden(_ hidden: Bool) {
        if #available(iOS 26.3, *) {
            stackView.alpha = hidden ? 0 : 1
            backgroundView.effect = hidden ? nil : glassEffect
        } else {
            alpha = hidden ? 0 : 1
        }
    }

    // MARK: Animations

    fileprivate func animateIn() {
        let animator = UIViewPropertyAnimator(duration: 0.35, springDamping: 1, springResponse: 0.35)
        // Tellomi（交互审计 A-30）：减弱动态效果时不缩放，只淡入。
        let reduceMotion = TellomiMotion.isReduceMotionEnabled
        tellomiAnimator = animator

        if #available(iOS 26.3, *) {
            UIView.performWithoutAnimation {
                self.stackView.alpha = 0
                self.transform = reduceMotion ? .identity : .scale(0.9)
                self.backgroundView.effect = nil
            }

            animator.addAnimations {
                self.stackView.alpha = 1
                self.transform = .identity
                self.backgroundView.effect = self.glassEffect
            }
        } else {
            self.alpha = 0
            animator.addAnimations {
                self.alpha = 1
            }
        }

        animator.startAnimation()
    }

    fileprivate func animateOut(completion: @escaping () -> Void) {
        let animator = UIViewPropertyAnimator(duration: 0.35, springDamping: 1, springResponse: 0.35)
        animator.addCompletion { _ in
            completion()
        }
        // Tellomi（交互审计 A-30）：在收了：不再接拖动、点按；倒计时停下。
        gestureRecognizers?.forEach { $0.isEnabled = false }
        tellomiCountdownView?.stop()

        if #available(iOS 26.3, *) {
            // Tellomi（交互审计 A-30）：减弱动态效果时不缩放，只淡出；拖过的从当前位置缩，不跳回原位。
            let reduceMotion = TellomiMotion.isReduceMotionEnabled
            animator.addAnimations {
                self.stackView.alpha = 0
                if !reduceMotion {
                    self.transform = self.transform.scaledBy(x: 0.9, y: 0.9)
                }
                self.backgroundView.effect = nil
            }
        } else {
            animator.addAnimations {
                self.alpha = 0
            }
        }
        animator.startAnimation()
    }
}

public class ToastViewHelper {
    public static func presentToastOnFrontmostViewController(text: String, image: UIImage? = nil) {
        guard let fromViewController = CurrentAppContext().frontmostViewController() else {
            owsFailDebug("frontmostViewController was unexpectedly nil")
            return
        }
        fromViewController.presentToast(text: text, image: image)
    }
}

// MARK: -

public extension UIView {
    func presentToast(text: String, image: UIImage? = nil, fromViewController: UIViewController) {
        fromViewController.presentToast(text: text, image: image)
    }
}

// MARK: -

public extension UIViewController {
    func presentToast(text: String, image: UIImage? = nil, extraVInset: CGFloat = 0) {
        let toastController = ToastController(text: text, image: image)
        let bottomInset = view.safeAreaInsets.bottom + 8 + extraVInset
        toastController.presentToastView(from: .bottom, of: view, inset: bottomInset)
    }
}
