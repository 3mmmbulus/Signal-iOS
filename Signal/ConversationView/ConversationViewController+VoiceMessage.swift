//
// Copyright 2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import SignalUI

extension ConversationViewController {
    func checkPermissionsAndStartRecordingVoiceMessage() {
        AssertIsOnMainThread()

        // Cancel any ongoing audio playback.
        AppEnvironment.shared.cvAudioPlayerRef.stopAll()

        let inProgressVoiceMessage = VoiceMessageInProgressDraft(
            thread: thread,
            audioSession: SUIEnvironment.shared.audioSessionRef,
            sleepManager: DependenciesBridge.shared.deviceSleepManager!,
        )
        viewState.inProgressVoiceMessage = inProgressVoiceMessage

        // Delay showing the voice memo UI for N ms to avoid a jarring transition
        // when you just tap and don't hold.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            guard self.viewState.inProgressVoiceMessage === inProgressVoiceMessage else { return }
            self.configureScrollDownButtons()
            // Tellomi（交互审计 A-12）：录音按钮后面的光晕跟着这一条的电平变（还没开始录时是 nil，光晕不动）。
            self.inputToolbar?.tellomiVoiceLevelSource = { [weak self] in
                self?.viewState.inProgressVoiceMessage?.tellomiPeakPower()
            }
            self.inputToolbar?.showVoiceMemoUI()
        }

        ows_askForMicrophonePermissions { [weak self] granted in
            guard let self else { return }
            guard self.viewState.inProgressVoiceMessage === inProgressVoiceMessage else { return }

            guard granted else {
                self.cancelRecordingVoiceMessage()
                self.ows_showNoMicrophonePermissionActionSheet()
                return
            }

            self.startRecordingVoiceMessage(inProgressVoiceMessage)
        }
    }

    private func startRecordingVoiceMessage(_ inProgressVoiceMessage: VoiceMessageInProgressDraft) {
        AssertIsOnMainThread()

        // Tellomi（交互审计 A-12；动效标准第五节「长按触发」→ `.medium`，同 Android `LONG_PRESS`）
        ImpactHapticFeedback.impactOccurred(style: .medium)

        do {
            try inProgressVoiceMessage.startRecording()
        } catch {
            owsFailDebug("Failed to start recording voice message \(error)")
            cancelRecordingVoiceMessage()
        }
    }

    func cancelRecordingVoiceMessage() {
        AssertIsOnMainThread()

        viewState.inProgressVoiceMessage?.stopRecordingAsync()
        viewState.inProgressVoiceMessage = nil

        // Tellomi（交互审计 A-12）：不再在这里统一给警告震动。左滑过线由输入框给「越过阈值」，太短在下面给「错误」，
        // 点「取消」按钮、没给麦克风权限都不震（同 Android）。

        clearVoiceMessageDraft()
        inputToolbar?.hideVoiceMemoUI(animated: true)
        configureScrollDownButtons()
    }

    private static let minimumVoiceMessageDuration: TimeInterval = 1

    func finishRecordingVoiceMessage(sendImmediately: Bool = false) {
        AssertIsOnMainThread()

        guard let inProgressVoiceMessage = viewState.inProgressVoiceMessage else { return }
        viewState.inProgressVoiceMessage = nil

        inProgressVoiceMessage.stopRecording()

        guard let duration = inProgressVoiceMessage.duration, duration >= Self.minimumVoiceMessageDuration else {
            // Tellomi（交互审计 A-12；动效标准第五节「错误：录音太短」→ `.error`，同 Android `REJECT`）
            NotificationHapticFeedback().notificationOccurred(.error)
            inputToolbar?.showVoiceMemoTooltip()
            cancelRecordingVoiceMessage()
            return
        }

        // Tellomi（交互审计 A-12）：发出、存草稿不给触感（动效标准第五节「发送成功不给」，同 Android）。

        configureScrollDownButtons()

        if sendImmediately {
            sendVoiceMessageDraft(inProgressVoiceMessage)
        } else {
            SSKEnvironment.shared.databaseStorageRef.asyncWrite {
                let interruptedDraft = inProgressVoiceMessage.convertToDraft(transaction: $0)
                DispatchQueue.main.async {
                    self.inputToolbar?.showVoiceMemoDraft(interruptedDraft)
                }
            }
        }
    }

    func sendVoiceMessageDraft(_ voiceMemoDraft: VoiceMessageSendableDraft) {
        inputToolbar?.hideVoiceMemoUI(animated: true)

        let attachmentLimits = OutgoingAttachmentLimits.currentLimits()

        do {
            let attachment = try voiceMemoDraft.prepareAttachment(attachmentLimits: attachmentLimits)
            Task { @MainActor in
                await self.sendAttachments(
                    ApprovedAttachments(nonViewOnceAttachments: [attachment], imageQuality: .standard),
                    messageBody: nil,
                    from: self,
                    attachmentLimits: attachmentLimits,
                )
                clearVoiceMessageDraft()
            }
        } catch {
            self.showErrorAlert(attachmentError: error as? SignalAttachmentError)
        }
    }

    func clearVoiceMessageDraft() {
        SSKEnvironment.shared.databaseStorageRef.asyncWrite { [thread] in
            VoiceMessageInterruptedDraftStore.clearDraft(for: thread, transaction: $0)
        }
    }
}
