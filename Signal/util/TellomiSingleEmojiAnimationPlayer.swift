//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import QuartzCore
import UIKit

/// Audit item 4.2 (UI wiring): plays `TellomiSingleEmojiAnimation` on a view and
/// remembers, in memory only, which messages already played their appear animation,
/// so scrolling back to a message does not replay it. Tapping always replays.
public final class TellomiSingleEmojiAnimationPlayer {

    public static let shared = TellomiSingleEmojiAnimationPlayer()

    public static let animationKey = "tellomiSingleEmojiPop"

    private var playedOnAppear = Set<String>()

    public init() {}

    public func hasPlayedOnAppear(messageId: String) -> Bool {
        playedOnAppear.contains(messageId)
    }

    /// Returns true when the appear animation should play now, and records it as played.
    public func consumeAppear(messageId: String, jumbomojiCount: UInt?, reduceMotion: Bool) -> Bool {
        let shouldPlay = TellomiSingleEmojiAnimation.shouldAnimate(
            jumbomojiCount: jumbomojiCount,
            trigger: .appeared,
            reduceMotion: reduceMotion,
            alreadyPlayedOnAppear: hasPlayedOnAppear(messageId: messageId),
        )
        if shouldPlay {
            playedOnAppear.insert(messageId)
        }
        return shouldPlay
    }

    public func shouldPlayOnTap(jumbomojiCount: UInt?, reduceMotion: Bool) -> Bool {
        TellomiSingleEmojiAnimation.shouldAnimate(
            jumbomojiCount: jumbomojiCount,
            trigger: .tapped,
            reduceMotion: reduceMotion,
            alreadyPlayedOnAppear: true,
        )
    }

    public static func makeAnimation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = TellomiSingleEmojiAnimation.keyframes.map { NSNumber(value: $0.scale) }
        animation.keyTimes = TellomiSingleEmojiAnimation.keyframes.map { NSNumber(value: $0.relativeTime) }
        animation.duration = TellomiSingleEmojiAnimation.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        animation.isRemovedOnCompletion = true
        return animation
    }

    public static func play(on view: UIView) {
        view.layer.removeAnimation(forKey: animationKey)
        view.layer.add(makeAnimation(), forKey: animationKey)
    }
}
