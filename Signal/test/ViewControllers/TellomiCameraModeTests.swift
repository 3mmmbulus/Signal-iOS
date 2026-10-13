//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1520 C-1，同 Tellomi 安卓 `MediaCaptureModeBar` / `CaptureButtonState`）：会话里的相机有「视频 | 照片」；
/// 录像模式里快门是红的，点一下开始录（不用按住），再点一下停；拍照模式点一下拍照。
@MainActor
final class TellomiCameraModeTests: SignalBaseTest {

    func testTheBarOffersVideoThenPhoto() {
        let bar = ComposerTypeSelectionControl(segmentTitles: [CommonStrings.attachmentTypeVideo, CommonStrings.attachmentTypePhoto])
        XCTAssertEqual(bar.numberOfSegments, 2)
        XCTAssertEqual(bar.titleForSegment(at: 0), CommonStrings.attachmentTypeVideo.uppercased())
        XCTAssertEqual(bar.titleForSegment(at: 1), CommonStrings.attachmentTypePhoto.uppercased())
    }

    func testTheStoryBarIsUnchanged() {
        let bar = ComposerTypeSelectionControl()
        XCTAssertEqual(bar.numberOfSegments, 2)
        XCTAssertEqual(
            bar.titleForSegment(at: 0),
            OWSLocalizedString("STORY_COMPOSER_CAMERA", comment: "").uppercased(),
        )
    }

    func testInPhotoModeATapTakesAPhoto() {
        let (control, delegate) = makeControl()
        control.tapForTesting()
        XCTAssertEqual(delegate.calls, ["photo"])
        XCTAssertEqual(control.recordingState, .notRecording)
        XCTAssertEqual(resolved(control.shutterInnerColorForTesting), resolved(.white))
    }

    func testInVideoModeATapStartsRecordingAndASecondTapStopsIt() {
        let (control, delegate) = makeControl()
        control.isVideoMode = true
        XCTAssertEqual(resolved(control.shutterInnerColorForTesting), resolved(UIColor.Signal.red), "录像模式快门是红的")

        control.tapForTesting()
        XCTAssertEqual(delegate.calls, ["start"])
        XCTAssertEqual(control.recordingState, .recordingUsingVoiceOver, "点着在录：显示停止键，不用按住")

        control.tapForTesting()
        XCTAssertEqual(delegate.calls, ["start", "finish"])
    }

    func testVideoFlashIsOnOrOff() {
        var mode = AVCaptureDevice.FlashMode.off
        var seen = [mode]
        for _ in 0..<2 {
            mode = CameraCaptureSession.nextFlashMode(after: mode, isVideoMode: true)
            seen.append(mode)
        }
        XCTAssertEqual(seen, [.off, .on, .off])
        XCTAssertEqual(CameraCaptureSession.nextFlashMode(after: .auto, isVideoMode: true), .off)
    }

    /// `.Signal.red` 是跟着深浅色变的颜色，每次取都是新对象：比较取出来的实际颜色。
    private func resolved(_ color: UIColor?) -> UIColor? {
        color?.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
    }

    private func makeControl() -> (CameraCaptureControl, RecordingDelegate) {
        let control = CameraCaptureControl(axis: .horizontal)
        let delegate = RecordingDelegate()
        control.delegate = delegate
        return (control, delegate)
    }
}

private final class RecordingDelegate: CameraCaptureControlDelegate {
    var calls = [String]()

    func cameraCaptureControlDidRequestCapturePhoto(_ control: CameraCaptureControl) { calls.append("photo") }
    func cameraCaptureControlDidRequestStartVideoRecording(_ control: CameraCaptureControl) { calls.append("start") }
    func cameraCaptureControlDidRequestFinishVideoRecording(_ control: CameraCaptureControl) { calls.append("finish") }
    func cameraCaptureControlDidRequestCancelVideoRecording(_ control: CameraCaptureControl) { calls.append("cancel") }
    var zoomScaleReferenceDistance: CGFloat? { 100 }
    func cameraCaptureControl(_ control: CameraCaptureControl, didUpdateZoomLevel zoomLevel: CGFloat) {}
}
