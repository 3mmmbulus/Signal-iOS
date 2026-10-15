//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1520 C-2，O2 照 Telegram 新相机）：竖屏时按住快门录像，往左拖到快门左边的锁上松手就锁住（免手持），
/// 往上拖变焦；按住 0.3 秒开始录。
@MainActor
final class TellomiCaptureLockTests: SignalBaseTest {

    func testTheLockIsBeforeTheShutter() {
        let (window, bar) = hostBottomBar()
        defer { window.isHidden = true }
        let control = bar.captureControl

        control.setRecordingState(.recording, isRecordingWithLongPress: true)
        bar.layoutIfNeeded()

        let shutter = control.shutterFrameForTesting
        let lock = control.lockFrameForTesting
        XCTAssertLessThan(lock.maxX, shutter.minX, "锁在快门左边")
        XCTAssertEqual(lock.midY, shutter.midY, accuracy: 0.5)

        // 快门照旧在底栏正中
        let shutterInBar = bar.convert(shutter, from: control)
        XCTAssertEqual(shutterInBar.midX, bar.layoutMarginsGuide.layoutFrame.midX, accuracy: 0.5)
        control.setRecordingState(.notRecording)
    }

    func testSlidingLeftLocksAndSlidingRightDoesNot() {
        let (window, bar) = hostBottomBar()
        defer { window.isHidden = true }
        let control = bar.captureControl
        control.setRecordingState(.recording, isRecordingWithLongPress: true)
        bar.layoutIfNeeded()

        XCTAssertEqual(control.slideHorizontallyForTesting(xOffset: 200), 0, "往右拖不去锁")
        XCTAssertEqual(control.slideHorizontallyForTesting(xOffset: -20), 0, "先有一段不算")
        let halfway = control.slideHorizontallyForTesting(xOffset: -60)
        XCTAssertGreaterThan(halfway, 0)
        XCTAssertLessThan(halfway, 1)
        XCTAssertEqual(control.slideHorizontallyForTesting(xOffset: -400), 1, "拖到锁上")
        control.setRecordingState(.notRecording)
    }

    /// 控件现在往左一直伸到页边（录像时锁在那里），相册键要还在它上面、点得到。
    func testThePhotoLibraryButtonStillGetsItsTaps() {
        let (window, bar) = hostBottomBar()
        defer { window.isHidden = true }
        let center = bar.convert(bar.photoLibraryButton.bounds.center, from: bar.photoLibraryButton)
        let hit = bar.hitTest(center, with: nil)
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit === bar.photoLibraryButton || hit?.isDescendant(of: bar.photoLibraryButton) == true, "\(String(describing: hit))")
    }

    /// tellomi/tellomi#1520（照 Telegram 两端的新相机）：按住录像时往右拖到切换摄像头键上（和锁隔着快门对称），换一次摄像头；
    /// 待在上面不再换，离开再回来又换一次；往左照旧是锁。
    func testDraggingRightWhileHoldingSwitchesTheCameraOncePerArrival() {
        let (window, bar) = hostBottomBar()
        defer { window.isHidden = true }
        let control = bar.captureControl
        var switches = 0
        control.onSwitchCamera = { switches += 1 }
        control.setRecordingState(.recording, isRecordingWithLongPress: true)
        bar.layoutIfNeeded()

        XCTAssertEqual(control.slideHorizontallyForTesting(xOffset: 400), 0, "往右不去锁")
        XCTAssertEqual(switches, 1)
        _ = control.slideHorizontallyForTesting(xOffset: 420)
        XCTAssertEqual(switches, 1, "到了只换一次")
        _ = control.slideHorizontallyForTesting(xOffset: 0)
        _ = control.slideHorizontallyForTesting(xOffset: 400)
        XCTAssertEqual(switches, 2, "离开再回来又换一次")
        XCTAssertEqual(control.slideHorizontallyForTesting(xOffset: -400), 1, "往左照旧是锁")
        XCTAssertEqual(switches, 2)
        control.setRecordingState(.notRecording)
    }

    /// 录像时相册键让给锁，切换摄像头键留着（点它也能换）。
    func testTheSwitchCameraButtonStaysWhileRecording() {
        let (window, bar) = hostBottomBar()
        defer { window.isHidden = true }
        bar.setIsRecordingVideo(true, animated: false)
        XCTAssertTrue(bar.photoLibraryButton.isHidden)
        XCTAssertFalse(bar.switchCameraButton.isHidden)
        bar.setIsRecordingVideo(false, animated: false)
    }

    func testHoldingStartsRecordingAfterAThirdOfASecond() {
        XCTAssertEqual(CameraCaptureControl.longPressDurationForTesting, 0.3, accuracy: 0.001)
    }

    private func hostBottomBar() -> (UIWindow, CameraBottomBar) {
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let bar = CameraBottomBar(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: root.view.bottomAnchor, constant: -40),
        ])
        window.layoutIfNeeded()
        return (window, bar)
    }
}
