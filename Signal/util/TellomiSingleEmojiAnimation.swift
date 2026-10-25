//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Audit item 4.2: decides when a message made of exactly one emoji should
/// play a short "pop" animation, and describes that animation as plain
/// values. Pure logic; not wired into the conversation view yet.
public enum TellomiSingleEmojiAnimation {

    public struct Keyframe: Equatable {
        public let relativeTime: Double
        public let scale: Double
    }

    /// Total duration of the pop, in seconds.
    public static let duration: Double = 0.45

    /// Scale keyframes: grow from 0.6, overshoot to 1.15, settle at 1.0.
    public static let keyframes: [Keyframe] = [
        Keyframe(relativeTime: 0.0, scale: 0.6),
        Keyframe(relativeTime: 0.55, scale: 1.15),
        Keyframe(relativeTime: 0.8, scale: 0.95),
        Keyframe(relativeTime: 1.0, scale: 1.0),
    ]

    public enum Trigger: Equatable {
        /// The message first appears on screen (newly sent or received).
        case appeared
        /// The user tapped the emoji bubble.
        case tapped
    }

    /// - Parameters:
    ///   - jumbomojiCount: `DisplayableText.jumbomojiCount`, nil if the text is not jumbomoji.
    ///   - trigger: why the animation would play.
    ///   - reduceMotion: `UIAccessibility.isReduceMotionEnabled`.
    ///   - alreadyPlayedOnAppear: whether the appear animation already ran for this message.
    public static func shouldAnimate(
        jumbomojiCount: UInt?,
        trigger: Trigger,
        reduceMotion: Bool,
        alreadyPlayedOnAppear: Bool,
    ) -> Bool {
        guard jumbomojiCount == 1 else { return false }
        guard !reduceMotion else { return false }
        switch trigger {
        case .appeared: return !alreadyPlayedOnAppear
        case .tapped: return true
        }
    }
}
