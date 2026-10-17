//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Lottie
import UIKit
import XCTest

@testable import Signal

/// 回应条上会动的表情（交互审计 A-06）：素材在包里、静止帧对、出场从静止帧播一圈回到静止帧、许可页有署名。
final class TellomiReactionAnimationsTest: XCTestCase {

    /// Signal 默认 6 个和补第 7 个的 🙏🔥🎉👏 都有动画，每个文件都带 Noto 的 `rest` 标记，60 fps。
    func testEveryDefaultBarEmojiHasABundledAnimationWithItsRestFrame() throws {
        let expectedRestFrames: [String: AnimationFrameTime] = [
            "❤️": 75, "👍": 0, "👎": 0, "😂": 116, "😮": 0, "😢": 61,
            "🙏": 0, "🔥": 0, "🎉": 25, "👏": 0,
        ]
        for (emoji, restFrame) in expectedRestFrames {
            let animation = try XCTUnwrap(TellomiReactionAnimations.animation(for: emoji), "\(emoji) 没打进包里")
            XCTAssertEqual(animation.frameTime(forMarker: TellomiReactionAnimations.restMarker), restFrame, emoji)
            XCTAssertEqual(TellomiReactionAnimations.restFrame(of: animation), restFrame, emoji)
            XCTAssertEqual(animation.framerate, 60, emoji)
        }
        XCTAssertEqual(TellomiReactionAnimations.animatedEmoji.count, expectedRestFrames.count)
    }

    /// 有没有 U+FE0F 都一样；带肤色的、没有素材的、组合表情照旧是静态字形。
    func testLookupIgnoresTheVariationSelectorOnly() {
        XCTAssertEqual(TellomiReactionAnimations.fileName(for: "❤️"), "tellomi_reaction_2764_fe0f")
        XCTAssertEqual(TellomiReactionAnimations.fileName(for: "❤"), "tellomi_reaction_2764_fe0f")
        XCTAssertNil(TellomiReactionAnimations.fileName(for: "👍🏽"))
        XCTAssertNil(TellomiReactionAnimations.fileName(for: "🤔"))
        XCTAssertNil(TellomiReactionAnimations.fileName(for: "❤️‍🔥"))
    }

    /// 从静止帧播一整圈回到静止帧：静止帧在开头时一段，否则两段（静止帧 → 尾、头 → 静止帧）。
    func testAppearPlaysOneFullTurnFromTheRestFrameBackToIt() {
        XCTAssertEqual(TellomiReactionAnimations.appearSegments(restFrame: 0, startFrame: 0, lastFrame: 71), [0...71])
        XCTAssertEqual(TellomiReactionAnimations.appearSegments(restFrame: 75, startFrame: 0, lastFrame: 109), [75...109, 0...75])
        XCTAssertEqual(TellomiReactionAnimations.appearSegments(restFrame: 109, startFrame: 0, lastFrame: 109), [0...109])

        let heart = try? XCTUnwrap(TellomiReactionAnimations.animation(for: "❤️"))
        // ❤️ 110 帧（0–109），静止帧 75。
        XCTAssertEqual(heart.map(TellomiReactionAnimations.appearSegments(of:)), [75...109, 0...75])
    }

    /// 条上有素材的表情换成动画，没有素材的照旧是字形（这里 🤔）。
    @MainActor
    func testBarItemsWithAnAnimationUseIt() throws {
        try XCTSkipUnless(TellomiReactionAnimations.isPlaybackAllowed, "模拟器开着减弱动态效果或低电量")
        let bar = TellomiReactionBar(emojis: ["❤️", "👍", "👎", "😂", "😮", "😢", "🤔"], selectedEmoji: "😂", delegate: nil)
        bar.frame = CGRect(x: 0, y: 0, width: 356, height: 46)
        bar.layoutIfNeeded()

        let animationViews = bar.descendants(of: LottieAnimationView.self)
        XCTAssertEqual(animationViews.count, 6)
        XCTAssertTrue(animationViews.allSatisfy { !$0.isAnimationPlaying })
        // 已选中的 😂 和字形一样缩到 0.8。
        XCTAssertEqual(animationViews.filter { $0.transform != .identity }.count, 1)
    }

    /// CC BY 4.0：「开源许可」页（和系统设置里的同一份清单）有 Noto Emoji Animation 的署名和许可链接。
    func testTheLicensesPageCreditsNotoEmojiAnimation() throws {
        let entry = try XCTUnwrap(TellomiAcknowledgements.load().first { $0.title == "Noto Emoji Animation" })
        XCTAssertTrue(entry.text.contains("Google"))
        XCTAssertTrue(entry.text.contains("CC BY 4.0"))
        XCTAssertTrue(entry.text.contains("https://creativecommons.org/licenses/by/4.0/"))
    }
}

private extension UIView {
    func descendants<T: UIView>(of type: T.Type) -> [T] {
        subviews.flatMap { subview -> [T] in
            (subview as? T).map { [$0] } ?? subview.descendants(of: type)
        }
    }
}
