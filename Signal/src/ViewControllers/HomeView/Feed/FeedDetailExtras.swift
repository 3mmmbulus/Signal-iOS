//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit

// 详情页补全（`TellomiFeed.isDetailExtrasEnabled`，默认关）的纯逻辑，没有 UIKit：
// 投票 / 转发 / 收藏那几行画不画、等着批准的回复显示什么、语音评论的播放状态。界面（`FeedPollCell` / `FeedDetailActionsCell` / `FeedCommentCell`）照着画。
// 对应 Android `detail/FeedPostDetailScreen.kt`、`detail/FeedVoiceComment.kt`、`FeedPostCard.kt`（`remoteUrlOrNull`）。

// MARK: - 帖子下面多出来的几行

enum FeedDetailExtraRow: Equatable {
    /// 投票。
    case poll
    /// 转发 / 收藏按钮。
    case actions
}

/// 转发 / 收藏那一行：哪几个按钮、各自什么状态。
struct FeedDetailActions: Equatable {
    var repost: Bool
    var reposted: Bool
    var save: Bool
    var saved: Bool
}

extension FeedPostDetailPresentation {

    /// 帖子那一行下面该多哪几行，按顺序：投票（有 `poll`），然后转发 / 收藏。
    static func extraRows(for post: FeedCard, saveAvailable: Bool) -> [FeedDetailExtraRow] {
        var rows = [FeedDetailExtraRow]()
        if post.poll != nil, post.kind != FeedCard.kindComment { rows.append(.poll) }
        if actions(for: post, saveAvailable: saveAvailable) != nil { rows.append(.actions) }
        return rows
    }

    /// 转发：只有 `shareable`（私密账号和非公开动态没有外链，第 29 条）的帖子才有，评论没有；
    /// 收藏：要有「我的收藏」的实现（`saveAvailable`，iOS 的那个要在 Mac 上接）才给，免得点了只会失败。两个都没有就没有这一行。
    static func actions(for post: FeedCard, saveAvailable: Bool) -> FeedDetailActions? {
        let repost = post.shareable && post.kind != FeedCard.kindComment
        guard repost || saveAvailable else { return nil }
        return FeedDetailActions(repost: repost, reposted: post.viewer.reposted, save: saveAvailable, saved: post.viewer.saved)
    }

    /// 一条等着批准的回复（第 40 条）：作者看到「批准 / 拒绝」，写的人看到「等作者批准」，不是 `held` 的什么都没有。
    enum Moderation: Equatable {
        case nothing
        /// 帖子作者这边：等你批准（有批准 / 拒绝两个按钮）。
        case forYou
        /// 写回复的人这边：作者批准后才公开。
        case waiting
    }

    static func moderation(of comment: FeedCard, post: FeedCard) -> Moderation {
        guard comment.held else { return .nothing }
        return post.viewer.isAuthor ? .forYou : .waiting
    }

    /// 语音评论的音频（第一段 `type == "audio"`）；文字评论是 nil。
    static func voice(of comment: FeedCard) -> FeedMedia? {
        return comment.media.first { $0.isAudio }
    }

    /// 一条评论在 `rows` 里的位置（定位到评论用）；不在是 nil。
    static func index(ofComment id: String, in rows: [CommentRow]) -> Int? {
        return rows.firstIndex { $0.comment.id == id }
    }
}

// MARK: - 媒体地址

enum FeedMediaURL {
    /// 引擎的媒体 key 拼到 `media_base_url`（契约 3.2，引擎保证以 `/` 结尾）后面（Android `remoteUrlOrNull`）。只认 https 的基址；
    /// key 像完整地址、以 `/` 开头或带 `..` 的不拼，免得一张卡片把请求带到别的主机或路径上。
    static func remote(key: String, baseUrl: String?) -> URL? {
        guard let baseUrl, baseUrl.hasPrefix("https://"), baseUrl.hasSuffix("/") else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !key.contains("://"), !key.hasPrefix("/") else { return nil }
        guard !key.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        return URL(string: baseUrl + key)
    }

    /// 样例来源里本机的语音用 `file://` 当 key；其余走 `media_base_url`。
    static func playback(for media: FeedMedia, baseUrl: String?) -> URL? {
        if media.key.hasPrefix("file://") { return URL(string: media.key) }
        return remote(key: media.key, baseUrl: baseUrl)
    }
}

// MARK: - 语音评论播放

/// 评论区里同一时间只放一条语音：放着哪条、放没放、放到哪。
struct FeedVoicePlayback: Equatable {
    var key: String?
    var loading = false
    var playing = false
    var positionMs = 0
    var failedKey: String?

    func isActive(_ key: String) -> Bool {
        return self.key == key
    }

    /// 进度条 0…1：不是这一条在放、或不知道时长是 0。
    func progress(for media: FeedMedia) -> Double {
        guard isActive(media.key), media.durationMs > 0 else { return 0 }
        return min(1, max(0, Double(positionMs) / Double(media.durationMs)))
    }

    /// 右边显示的时间：放着就显示放到哪，没放（或还没出声）显示总时长。
    func shownMs(for media: FeedMedia) -> Int {
        return isActive(media.key) && positionMs > 0 ? positionMs : media.durationMs
    }
}

enum FeedVoiceDuration {
    /// 0:04、1:00；不足一秒按 0:00。
    static func format(_ ms: Int) -> String {
        let seconds = max(0, ms) / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// 一段已经下好、可以放的语音。界面那边用 `AVAudioPlayer` 实现；单测用假的。
@MainActor
protocol FeedVoiceClip: AnyObject {
    var onPosition: ((Int) -> Void)? { get set }
    var onFinished: (() -> Void)? { get set }
    func play()
    func pause()
    /// 放完 / 换了一条 / 页面走了：停掉并放掉。
    func stop()
}

/// 把地址变成能放的语音（下载到缓存、解码）；失败就抛。
protocol FeedVoiceLoader {
    @MainActor func load(url: URL) async throws -> FeedVoiceClip
}

/// 语音评论的播放（第三节第 4 条）：同一时间一条；点另一条停掉当前这条；放完回到没放；点放着的暂停、点暂停的继续。
/// 只读：不碰聊天的录音 / 播放器，也不改任何服务端数据。
@MainActor
final class FeedVoicePlayer {
    private(set) var playback = FeedVoicePlayback() {
        didSet { if playback != oldValue { onChange?(playback) } }
    }
    var onChange: ((FeedVoicePlayback) -> Void)?

    private let loader: FeedVoiceLoader
    private let baseUrl: () -> String?
    private var clip: FeedVoiceClip?
    private var loadTask: Task<Void, Never>?
    /// 每开始一次新的加载 / 放掉一次就 +1：过期的加载结果不能把现在的状态改掉。
    private var generation = 0

    init(loader: FeedVoiceLoader, baseUrl: @escaping () -> String?) {
        self.loader = loader
        self.baseUrl = baseUrl
    }

    func toggle(_ media: FeedMedia) {
        let key = media.key
        if playback.isActive(key), let clip {
            if playback.playing {
                clip.pause()
                playback.playing = false
            } else {
                clip.play()
                playback.playing = true
            }
            return
        }
        if playback.isActive(key), playback.loading { return }
        release()
        guard let url = FeedMediaURL.playback(for: media, baseUrl: baseUrl()) else {
            playback = FeedVoicePlayback(failedKey: key)
            return
        }
        playback = FeedVoicePlayback(key: key, loading: true)
        generation += 1
        let current = generation
        loadTask = Task { [weak self, loader] in
            do {
                let loaded = try await loader.load(url: url)
                guard let self, self.generation == current else {
                    loaded.stop()
                    return
                }
                loaded.onPosition = { [weak self] ms in
                    guard let self, self.generation == current else { return }
                    self.playback.positionMs = ms
                }
                loaded.onFinished = { [weak self] in
                    guard let self, self.generation == current else { return }
                    self.release()
                }
                self.clip = loaded
                loaded.play()
                self.playback = FeedVoicePlayback(key: key, playing: true)
            } catch {
                Logger.warn("feed voice comment playback failed: \(error)")
                guard let self, self.generation == current else { return }
                self.release()
                self.playback = FeedVoicePlayback(failedKey: key)
            }
        }
    }

    /// 页面退到后台：暂停（不放掉，回来可以接着放）。
    func pause() {
        guard let clip, playback.playing else { return }
        clip.pause()
        playback.playing = false
    }

    /// 页面走了 / 放完了：停掉、放掉、回到没放。
    func release() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        clip?.stop()
        clip = nil
        playback = FeedVoicePlayback()
    }

    /// 单测：等当前这次加载走完。
    func waitForLoad() async {
        await loadTask?.value
    }
}

// MARK: - 评论那一行多出来的东西

/// 评论那一行在详情页补全开着时多画的几样（`FeedCommentCell.configure`）：等批准的状态和按钮、语音、被定位到时的高亮。
struct FeedCommentExtras: Equatable {
    var moderation: FeedPostDetailPresentation.Moderation
    var voice: FeedMedia?
    var highlighted: Bool

    init(comment: FeedCard, post: FeedCard, highlighted: Bool) {
        moderation = FeedPostDetailPresentation.moderation(of: comment, post: post)
        voice = FeedPostDetailPresentation.voice(of: comment)
        self.highlighted = highlighted
    }

    /// 补全开着时评论正文怎么显示：语音评论的转写放在语音那一行下面（所以正文不再用转写顶替）；文字评论照旧。
    static func bodyText(of comment: FeedCard, hasVoiceRow: Bool) -> String? {
        guard hasVoiceRow else { return FeedPostDetailPresentation.displayText(of: comment) }
        let text = comment.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : comment.text
    }

    /// 语音那一行下面的转写；空白不显示。
    static func transcript(of comment: FeedCard) -> String? {
        let text = comment.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : comment.transcript
    }
}
