//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import CryptoKit
import SignalServiceKit
import SignalUI
import UIKit

/// 语音评论的播放（只读）：把评论里的 `.m4a` 下到缓存目录再用 `AVAudioPlayer` 放。逻辑（同一时间一条、暂停 / 继续、失败）在 `FeedVoicePlayer`，这里只管下载和出声。
/// 不碰聊天的录音器 / 语音消息播放器：音频会话只通过 `AudioSession` 的 `AudioActivity`（`.playback`）申请、放完就还。
@MainActor
final class FeedAudioClip: NSObject, FeedVoiceClip, AVAudioPlayerDelegate {
    var onPosition: ((Int) -> Void)?
    var onFinished: (() -> Void)?

    private let player: AVAudioPlayer
    private let activity = AudioActivity(audioDescription: "FeedVoiceComment", behavior: .playback)
    private var timer: Timer?
    private var activityStarted = false

    init(file: URL) throws {
        player = try AVAudioPlayer(contentsOf: file)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }

    func play() {
        if !activityStarted {
            activityStarted = SUIEnvironment.shared.audioSessionRef.startAudioActivity(activity)
        }
        player.play()
        startTimer()
    }

    func pause() {
        player.pause()
        stopTimer()
    }

    func stop() {
        player.stop()
        stopTimer()
        if activityStarted {
            activityStarted = false
            SUIEnvironment.shared.audioSessionRef.endAudioActivity(activity)
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        onPosition?(Int(player.currentTime * 1000))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopTimer()
            self.onFinished?()
        }
    }

    deinit {
        timer?.invalidate()
    }
}

/// 下载（同一个地址只下一次，放在 `Caches/feed-voice/`，系统会清、不进备份）并交给 `FeedAudioClip`。本机文件（样例里自己录的）直接放。
struct FeedVoiceFileLoader: FeedVoiceLoader {
    struct DownloadError: Error {
        var status: Int
    }

    @MainActor
    func load(url: URL) async throws -> FeedVoiceClip {
        let file = try await Self.localFile(for: url)
        return try FeedAudioClip(file: file)
    }

    private static func localFile(for url: URL) async throws -> URL {
        if url.isFileURL { return url }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("feed-voice", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let target = directory.appendingPathComponent(name + ".m4a")
        if let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int), size > 0 {
            return target
        }
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: downloaded)
            throw DownloadError(status: status)
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: downloaded, to: target)
        return target
    }
}
