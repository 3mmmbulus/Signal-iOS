//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
public import UIKit

public class ConversationScrollButton: UIButton {

    let iconName: String

    var unreadCount: UInt = 0 {
        didSet {
            guard unreadCount != oldValue else { return }
            tellomiUpdateUnreadBadge(from: oldValue)
        }
    }

    /// Tellomi（交互审计 A-14，照 Telegram iOS `ChatHistoryNavigationButtonNode`：角标数字滚动、角标出现 / 消失有过渡）：
    /// 按钮看得见时，数字变了新数字从下面（变多）或上面（变少）推进来；从 0 变有数 / 变回 0 时角标从 0.5 倍弹出 / 缩回。
    /// 看不见、减弱动态效果时直接换（减弱动态效果只淡入淡出）。
    private func tellomiUpdateUnreadBadge(from oldValue: UInt) {
        let isVisible = window != nil && !isHidden && alpha > 0
        let reduceMotion = TellomiMotion.isReduceMotionEnabled
        let shouldHideBadge = unreadCount == 0

        if isVisible, oldValue != 0, unreadCount != 0 {
            let transition = CATransition()
            transition.duration = TellomiMotion.fadeInDuration
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if reduceMotion {
                transition.type = .fade
            } else {
                transition.type = .push
                transition.subtype = unreadCount > oldValue ? .fromTop : .fromBottom
            }
            unreadCountLabel.layer.add(transition, forKey: kCATransition)
        }
        if !shouldHideBadge {
            unreadCountLabel.text = String.localizedStringWithFormat("%u", unreadCount)
        }

        guard unreadBadge.isHidden != shouldHideBadge || unreadBadge.alpha != (shouldHideBadge ? 0 : 1) else { return }
        guard isVisible else {
            unreadBadge.isHidden = shouldHideBadge
            unreadBadge.alpha = 1
            unreadBadge.transform = .identity
            return
        }
        badgeAnimationGeneration += 1
        let generation = badgeAnimationGeneration
        let hiddenTransform: CGAffineTransform = reduceMotion ? .identity : .scale(0.5)
        if !shouldHideBadge, unreadBadge.isHidden {
            unreadBadge.alpha = 0
            unreadBadge.transform = hiddenTransform
            unreadBadge.isHidden = false
        }
        let animator = TellomiMotion.animator(TellomiMotion.snap) {
            self.unreadBadge.alpha = shouldHideBadge ? 0 : 1
            self.unreadBadge.transform = shouldHideBadge ? hiddenTransform : .identity
        }
        animator.addCompletion { [weak self] _ in
            guard let self, generation == self.badgeAnimationGeneration, shouldHideBadge else { return }
            self.unreadBadge.isHidden = true
            self.unreadBadge.alpha = 1
            self.unreadBadge.transform = .identity
        }
        animator.startAnimation()
    }

    private var badgeAnimationGeneration = 0

    var badgeTintColor: UIColor! {
        get { unreadBadge.backgroundColor ?? UIColor.Signal.accent }
        set { unreadBadge.backgroundColor = newValue ?? UIColor.Signal.accent }
    }

    init(iconName: String) {
        self.iconName = iconName
        super.init(frame: .zero)

        var configuration: UIButton.Configuration?
        if #available(iOS 26, *) {
            configuration = .glass()
        }
        if configuration == nil {
            configuration = .gray()
            configuration?.baseForegroundColor = UIColor(
                light: .ows_gray75,
                dark: .ows_gray15,
            )
            configuration?.baseBackgroundColor = UIColor(
                light: .ows_gray02,
                dark: .ows_gray65,
            )
            if #available(iOS 18, *) {
                configuration?.background.shadowProperties.offset = CGSize(width: 0, height: 4)
                configuration?.background.shadowProperties.color = .black
                configuration?.background.shadowProperties.radius = 12
                configuration?.background.shadowProperties.opacity = 0.3
            }
        }
        configuration?.cornerStyle = .capsule
        configuration?.image = UIImage(named: iconName)
        self.configuration = configuration

        addUnreadLabel()
    }

    override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyUnreadBadgeStroke()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public var intrinsicContentSize: CGSize {
        .square(ConversationScrollButton.circleDiameter)
    }

    private class var circleDiameter: CGFloat { 40 }

    private lazy var unreadCountLabel: UILabel = {
        let label = UILabel()
        label.font = .dynamicTypeFootnoteClamped.semibold()
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var unreadBadge: UIView = {
        let view = PillView()
        view.isUserInteractionEnabled = false
        view.clipsToBounds = true
        view.backgroundColor = .Signal.accent
        view.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(unreadCountLabel)
        NSLayoutConstraint.activate([
            unreadCountLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            unreadCountLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            unreadCountLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 2),
            unreadCountLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            view.widthAnchor.constraint(greaterThanOrEqualTo: view.heightAnchor, multiplier: 1),
        ])

        return view
    }()

    private func addUnreadLabel() {
        let pillViewOverlap: CGFloat = 8 // how much unread badge pill overlaps circle
        // Tellomi：一开始没有未读，角标先藏着（原来要等第一次设数才藏，`unreadCount` 现在只在数变了时才动）。
        unreadBadge.isHidden = true
        addSubview(unreadBadge)
        NSLayoutConstraint.activate([
            unreadBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            unreadBadge.bottomAnchor.constraint(equalTo: topAnchor, constant: pillViewOverlap),
        ])

        applyUnreadBadgeStroke()
    }

    private func applyUnreadBadgeStroke() {
        let strokeColor = switch traitCollection.userInterfaceStyle {
        case .dark: UIColor(white: 1, alpha: 0.1)
        default: UIColor(white: 0, alpha: 0.1)
        }
        unreadBadge.layer.borderWidth = 1
        unreadBadge.layer.borderColor = strokeColor.cgColor
    }
}

#if TESTABLE_BUILD

extension ConversationScrollButton {
    var isUnreadBadgeShownForTesting: Bool { !unreadBadge.isHidden }
    var unreadBadgeAlphaForTesting: CGFloat { unreadBadge.alpha }
    var unreadTextForTesting: String? { unreadCountLabel.text }
    /// 数字正在滚（新数字推进来）。
    var isRollingUnreadCountForTesting: Bool { unreadCountLabel.layer.animation(forKey: kCATransition) != nil }
}

#endif
