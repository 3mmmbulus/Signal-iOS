//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import XCTest

@testable import Signal
@testable import SignalUI

/// 交互审计 A-12（iOS 半边，同安卓 `TellomiVoiceLevelTest`）：电平 → 光晕大小，以及光晕的平滑和跟随。
final class TellomiVoiceLevelTests: XCTestCase {

    func testLevelMapsDecibelsAboveTheFloor() {
        XCTAssertEqual(TellomiVoiceLevel.level(decibels: -160), 0)
        XCTAssertEqual(TellomiVoiceLevel.level(decibels: -45), 0, "-45 dB 以下算没声音")
        XCTAssertEqual(TellomiVoiceLevel.level(decibels: -22.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TellomiVoiceLevel.level(decibels: 0), 1)
        XCTAssertEqual(TellomiVoiceLevel.level(decibels: 3), 1, "削顶也只算满")
        XCTAssertEqual(TellomiVoiceLevel.level(decibels: .nan), 0)
        XCTAssertEqual(TellomiVoiceLevel.haloScale(level: 0), 1)
        XCTAssertEqual(TellomiVoiceLevel.haloScale(level: 1), 1.6, accuracy: 0.0001)
        XCTAssertEqual(TellomiVoiceLevelHalo.targetScale(decibels: nil), 1, "没在录：光晕原大")
    }

    /// 临界阻尼：往目标走、不冲过头；帧率掉到 20 fps 一步走 50 ms 也稳。
    func testHaloSpringSettlesWithoutOvershoot() {
        let halo = TellomiVoiceLevelHalo(frame: CGRect(x: 0, y: 0, width: 88, height: 88))
        var maxScale: CGFloat = 0
        for _ in 0..<30 {
            halo.advance(towards: 1.6, by: 1.0 / 60)
            maxScale = max(maxScale, halo.levelScale)
        }
        XCTAssertLessThanOrEqual(maxScale, 1.6 + 0.0001, "不冲过头")
        XCTAssertEqual(halo.levelScale, 1.6, accuracy: 0.02, "半秒内基本到位")

        for _ in 0..<10 {
            halo.advance(towards: 1, by: 0.05)
        }
        XCTAssertEqual(halo.levelScale, 1, accuracy: 0.02)
    }

    /// 跟着下面的按钮：按钮变淡光晕一起淡，按钮平移光晕一起移；没有电平来源或减弱动态效果时不显示。
    @MainActor
    func testHaloFollowsTheButton() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        defer { window.isHidden = true }

        let button = UIView(frame: CGRect(x: 100, y: 700, width: 88, height: 88))
        let halo = TellomiVoiceLevelHalo(frame: button.frame)
        root.view.addSubview(halo)
        root.view.addSubview(button)

        halo.start(following: button)
        XCTAssertTrue(halo.isHidden, "没有电平来源不显示")

        halo.levelSource = { -10 }
        halo.start(following: button)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        XCTAssertFalse(halo.isHidden)

        button.alpha = 0.5
        button.transform = CGAffineTransform(translationX: -40, y: 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(halo.alpha, TellomiVoiceLevelHalo.haloAlpha * 0.5, accuracy: 0.001)
        XCTAssertEqual(halo.transform.tx, -40, accuracy: 0.5, "平移跟着按钮（缩放绕光晕自己的中心）")
        XCTAssertGreaterThan(halo.levelScale, 1.3, "-10 dB 时光晕明显变大")

        halo.removeFromSuperview()
        XCTAssertTrue(halo.isHidden, "离开窗口就停")
    }
}
