//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import SignalServiceKit
import SignalUI

/// Represents a voice note that's actively being recorded.
///
/// In most cases you'll immediately send (or discard) voice notes you
/// record. When this happens, an instance of this type will be passed to
/// the voice note sending logic.
///
/// In some cases, an external event may interrupt an active recording. When
/// that happens, we convert this object into a durable
/// ``VoiceMessageInterruptedDraft``. That draft is visible in the compose
/// box for the user to return to later.
final class VoiceMessageInProgressDraft: VoiceMessageSendableDraft {
    private let threadUniqueId: String
    private let audioFileUrl: URL
    private let audioActivity: AudioActivity
    private let audioSession: AudioSession
    private let sleepManager: any DeviceSleepManager

    init(thread: TSThread, audioSession: AudioSession, sleepManager: any DeviceSleepManager) {
        self.threadUniqueId = thread.uniqueId
        self.audioFileUrl = OWSFileSystem.temporaryFileUrl(
            fileExtension: "m4a",
            isAvailableWhileDeviceLocked: false,
        )
        self.audioActivity = AudioActivity(audioDescription: "Voice Message Recording", behavior: .recordAudio)
        self.audioSession = audioSession
        self.sleepManager = sleepManager
    }

    deinit {
        Task { [sleepManager, sleepBlockObject] in
            await sleepManager.removeBlock(blockObject: sleepBlockObject)
        }
    }

    private let sleepBlockObject = DeviceSleepBlockObject(blockReason: "voice message")

    private var audioRecorder: AVAudioRecorder?

    var isRecording: Bool { audioRecorder?.isRecording ?? false }

    /// Tellomi（Telegram 对照 3.3 / F12）：暂停 / 继续。暂停时 isRecording 为 false，isPaused 为 true。
    private var tellomiPauseClock = TellomiVoicePauseClock()
    private static func tellomiNow() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    var isPaused: Bool { audioRecorder != nil && tellomiPauseClock.isPaused }

    /// 录音中暂停；不在录音中什么也不做，返回 false。
    @discardableResult
    func pauseRecording() -> Bool {
        AssertIsOnMainThread()
        guard let audioRecorder, audioRecorder.isRecording else { return false }
        audioRecorder.pause()
        return tellomiPauseClock.pause(at: Self.tellomiNow())
    }

    /// 暂停中继续录（接在同一个文件后面）；不在暂停中返回 false。
    @discardableResult
    func resumeRecording() -> Bool {
        AssertIsOnMainThread()
        guard let audioRecorder, tellomiPauseClock.isPaused else { return false }
        guard audioRecorder.record() else { return false }
        return tellomiPauseClock.resume(at: Self.tellomiNow())
    }

    /// 有效录音时长（暂停期间不计），给计时标签用。
    var tellomiElapsed: TimeInterval { tellomiPauseClock.elapsed(at: Self.tellomiNow()) }

    /// Tellomi（交互审计 A-12）：现在的峰值电平（dBFS，-160…0），给录音按钮后面的光晕用；没在录返回 nil。
    func tellomiPeakPower() -> Float? {
        guard let audioRecorder, audioRecorder.isRecording else { return nil }
        audioRecorder.updateMeters()
        return audioRecorder.peakPower(forChannel: 0)
    }

    func startRecording() throws {
        AssertIsOnMainThread()

        guard !isRecording else {
            throw OWSAssertionError("Attempted to start recording while recording is in progress")
        }

        guard audioSession.startAudioActivity(audioActivity) else {
            throw OWSAssertionError("Couldn't configure audio session")
        }

        var recorderSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: DebugFlags.voiceMessageSampleRate.get(),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: DebugFlags.voiceMessageBitRate.get(),
        ]
        if let audioQuality = DebugFlags.voiceMessageAudioQuality.get()?.avAudioQuality {
            recorderSettings[AVEncoderAudioQualityKey] = audioQuality.rawValue
        }

        let audioRecorder: AVAudioRecorder
        do {
            audioRecorder = try AVAudioRecorder(
                url: audioFileUrl,
                settings: recorderSettings,
            )
            self.audioRecorder = audioRecorder
        } catch {
            throw OWSAssertionError("Couldn't create audioRecorder: \(error)")
        }

        MainActor.assumeIsolated {
            sleepManager.addBlock(blockObject: sleepBlockObject)
        }

        audioRecorder.isMeteringEnabled = true

        guard audioRecorder.prepareToRecord() else {
            throw OWSAssertionError("audioRecorder couldn't prepareToRecord.")
        }

        guard audioRecorder.record() else {
            throw OWSAssertionError("audioRecorder couldn't record.")
        }
        tellomiPauseClock.start(at: Self.tellomiNow())
    }

    func stopRecording() {
        AssertIsOnMainThread()

        MainActor.assumeIsolated {
            sleepManager.removeBlock(blockObject: sleepBlockObject)
        }

        guard let audioRecorder else { return }
        self.audioRecorder = nil

        // Tellomi：暂停后 currentTime 可能不可靠，取两者中较大的。
        let tellomiTotal = tellomiPauseClock.stop(at: Self.tellomiNow()) ?? 0
        self.duration = max(audioRecorder.currentTime, tellomiTotal)

        audioRecorder.stop()

        // This is expensive. We can safely do it in the background.
        DispatchQueue.sharedUserInteractive.async {
            self.audioSession.endAudioActivity(self.audioActivity)
        }
    }

    func stopRecordingAsync() {
        AssertIsOnMainThread()

        MainActor.assumeIsolated {
            sleepManager.removeBlock(blockObject: sleepBlockObject)
        }

        guard let audioRecorder else { return }
        self.audioRecorder = nil

        // Tellomi：暂停后 currentTime 可能不可靠，取两者中较大的。
        let tellomiTotal = tellomiPauseClock.stop(at: Self.tellomiNow()) ?? 0
        self.duration = max(audioRecorder.currentTime, tellomiTotal)

        // This is expensive. We can safely do it in the background
        // if we're not relying on the recorded audio (e.g. we canceled)
        DispatchQueue.sharedUserInteractive.async {
            audioRecorder.stop()
            self.audioSession.endAudioActivity(self.audioActivity)
        }
    }

    private(set) var duration: TimeInterval?

    func convertToDraft(transaction: DBWriteTransaction) -> VoiceMessageInterruptedDraft {
        let directoryUrl = VoiceMessageInterruptedDraftStore.saveDraft(
            audioFileUrl: audioFileUrl,
            threadUniqueId: threadUniqueId,
            transaction: transaction,
        )
        return VoiceMessageInterruptedDraft(threadUniqueId: threadUniqueId, directoryUrl: directoryUrl)
    }

    func prepareForSending() throws -> URL {
        return audioFileUrl
    }
}
