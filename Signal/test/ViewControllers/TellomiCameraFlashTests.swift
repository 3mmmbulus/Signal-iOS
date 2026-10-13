//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import XCTest

@testable import Signal

/// Tellomi（tellomi/tellomi#1520 C-5）：闪光灯键按一下换一档，关 → 开 → 自动 → 关（照 Telegram 新相机拍照时的顺序，同 Tellomi 安卓）。
final class TellomiCameraFlashTests: XCTestCase {

    func testFlashCyclesOffOnAuto() {
        var mode = AVCaptureDevice.FlashMode.off
        var seen = [mode]
        for _ in 0..<3 {
            mode = CameraCaptureSession.nextFlashMode(after: mode)
            seen.append(mode)
        }
        XCTAssertEqual(seen, [.off, .on, .auto, .off])
    }
}
