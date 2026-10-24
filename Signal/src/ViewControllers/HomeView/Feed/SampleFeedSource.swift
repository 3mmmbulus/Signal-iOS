//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import UIKit

/// 本机样例：内部用户在内容引擎接上之前看界面用。人名、内容全是虚构的，守 `internal-beta-content-generator.md` 4.1
/// （不涉政、不点名真人与品牌、不编造新闻）。只在内存里，点赞和不感兴趣重启 App 就没了。和 Android `SampleFeedSource` 同一组样例。
final class SampleFeedSource: FeedSource {
    static let shared = SampleFeedSource()

    static let pageSize = 8

    private let lock = NSLock()
    private var liked = Set<String>()
    private var hidden = Set<String>()
    /// 自己在样例里发的，放在两栏最上面。
    private var mine = [FeedCard]()
    private var published = [String: FeedCreatePostResponse]()

    let now: () -> Date
    /// 样例取评论前先等一会儿，界面上才看得到「加载中」。单测传 0。
    private let commentsLatencyNanos: UInt64
    /// 已经让它失败过一次的帖子（见 `failsFirstCommentLoad`）：重试就成功。
    private var failedCommentLoads = Set<String>()
    /// 在样例里发出去、已经直接显示的评论（按帖子），接在样例评论后面。
    private var postedComments = [String: [FeedCard]]()

    /// 给人看界面 / 截图用的开关（只在样例里有，默认全是 0 / false：行为和以前一样）。可以随时改。
    struct Simulation {
        /// 这些帖子当成「我发的」（`viewer.isAuthor`）：列表和 Card API 都这样回，详情页换成最新卡片之后「···」里仍是自己帖子的菜单（截图用）。
        var ownPostIds = Set<String>()
        /// 取最新卡片（Card API）前先等一会儿：帖子详情页打开后这么久才知道「已不可见」，能截到中间那一帧。
        var cardLatencyNanos: UInt64 = 0
        /// 点赞 / 取消赞的请求先等一会儿：能截到「已经点亮、请求还在路上」那一帧。
        var likeLatencyNanos: UInt64 = 0
        /// 点赞请求失败（界面会先点亮、再改回来、提示一句）。
        var failsLikes = false
        /// 发评论的请求先等一会儿：能截到「发送中」那一帧。
        var postCommentLatencyNanos: UInt64 = 0
        /// 发评论失败（输入框保留文字，提示一句）。
        var failsComments = false
        /// 发评论时引擎回的错误码（`comments_closed`、`reply_not_allowed`、`profile_required`、`invalid_parent`…）；nil = 不报错。
        var commentErrorCode: String?
        /// 发评论成功后引擎回的状态：直接显示（`published`）或先审后显（`pending`，大陆区一律这样）。
        var commentPublishState = FeedCreatePostResponse.statePublished
        /// 删评论（自己的）/ 举报 / 不感兴趣的请求先等一会儿：能截到「在路上」那一帧。
        var deleteLatencyNanos: UInt64 = 0
        var reportLatencyNanos: UInt64 = 0
        var notInterestedLatencyNanos: UInt64 = 0
        /// 这三个动作失败（界面提示「操作失败」，评论 / 帖子留着）。
        var failsDeletes = false
        var failsReports = false
        var failsNotInterested = false
        /// 这三个动作被限速（429）：非 nil 时回 429 并带这么多秒的 `Retry-After`（界面说「请 N 秒后再试」）。
        var throttledRetryAfterSeconds: Int?
        /// 这三个动作回 404 `feed_hidden`（这个区域的动态被关了，页面该收起）。主页的各个请求也认它。
        var feedHidden = false
        /// 作者主页：取主页 / 取帖子 / 关注 / 屏蔽 / 不看·不让看 的请求先等一会儿：能截到「加载中」「在路上」那一帧。
        var profileLatencyNanos: UInt64 = 0
        var profilePostsLatencyNanos: UInt64 = 0
        var followLatencyNanos: UInt64 = 0
        /// 取主页 / 取帖子 / 关注 / 屏蔽 / 不看·不让看 失败（整页「加载失败」、列表「重试」、按钮改回来并提示「操作失败」）。
        var failsProfile = false
        var failsProfilePosts = false
        var failsFollow = false
        var failsBlock = false
        var failsHideLists = false
        /// 取主页被限速：非 nil 时回 429 并带这么多秒的 `Retry-After`（加载失败页说「请 N 秒后再试」）。
        var profileThrottledRetryAfterSeconds: Int?
        /// 搜索请求先等一会儿（搜索中那一帧）。
        var searchLatencyNanos: UInt64 = 0
        /// 搜索失败（第一页）；`failsSearchMore` 只让翻页失败（结果留着，末尾给重试）。
        var failsSearch = false
        var failsSearchMore = false
        /// 搜索被限速：回 429 带这么多秒的 `Retry-After`；nil = 不限速。
        var searchThrottledRetryAfterSeconds: Int?
        /// 话题页的同样几个开关。
        var topicLatencyNanos: UInt64 = 0
        var failsTopic = false
        var failsTopicMore = false
        var topicThrottledRetryAfterSeconds: Int?
        var failsTopicFollow = false
        /// 通知页（见 `SampleFeedSource+Notifications.swift`）：请求先等一会儿（加载中那一帧）。
        var notificationsLatencyNanos: UInt64 = 0
        /// 取通知失败（第一页）；`failsNotificationsMore` 只让翻页失败（已有的留着，末尾给重试）。
        var failsNotifications = false
        var failsNotificationsMore = false
        /// 取通知被限速：回 429 带这么多秒的 `Retry-After`；nil = 不限速。
        var notificationsThrottledRetryAfterSeconds: Int?
        /// 标已读 / 删一条 / 不再通知 失败（行放回来并提示「操作失败」）；`notificationActionsGone` 让它们回 404（当删成了 / 提示帖子已不可见）。
        var failsNotificationActions = false
        var notificationActionsGone = false
        /// 通知设置：读 / 存失败；存时回 409 `profile_required`；存时被限速。
        var failsNotificationSettingsLoad = false
        var failsNotificationSettingsSave = false
        var notificationSettingsNeedProfile = false
        var notificationSettingsThrottledRetryAfterSeconds: Int?
        /// 「我的动态」页（见 `SampleFeedSource+MyPosts.swift`）：请求先等一会儿（加载中那一帧）。
        var myPostsLatencyNanos: UInt64 = 0
        /// 取列表失败（第一页）；`failsMyPostsMore` 只让翻页失败（已有的留着，末尾给重试）。
        var failsMyPosts = false
        var failsMyPostsMore = false
        /// 取列表 / 申诉被限速：回 429 带这么多秒的 `Retry-After`；nil = 不限速。
        var myPostsThrottledRetryAfterSeconds: Int?
        /// 申诉请求先等一会儿（发送中那一帧）；失败（提示「操作失败」）。
        var appealLatencyNanos: UInt64 = 0
        var failsAppeals = false
        /// 编辑保存：失败（提示「操作失败」）；回 409 `edit_window_closed`（已过 15 分钟）/ `not_editable`；先等一会儿（保存中那一帧）。
        var failsEdits = false
        /// 名单页（见 `SampleFeedSource+Lists.swift`）：请求先等一会儿（加载中那一帧）；读名单 / 处理一行失败；被限速（429 带这么多秒）；
        /// 回应关注请求时对方已撤回（404）；关心的人：满 3 个（409 `close_people_full`）/ 还没建主页（409 `profile_required`）。
        var listsLatencyNanos: UInt64 = 0
        var failsListsLoad = false
        var failsListsActions = false
        var listsThrottledRetryAfterSeconds: Int?
        var followRequestWithdrawn = false
        var closePeopleFull = false
        var closePeopleProfileRequired = false
        var editsWindowClosed = false
        var editsNotEditable = false
        var editLatencyNanos: UInt64 = 0
        /// 申诉时引擎回 409 `already_appealed` / `not_rejected`（行标成复核中 / 重新拉列表）。
        var appealsAlreadyAppealed = false
        var appealsNotRejected = false
        /// 「动态设置」页（见 `SampleFeedSource+Settings.swift`）：请求先等一会儿（加载中那一帧）。
        var settingsLatencyNanos: UInt64 = 0
        /// 读偏好 / 兴趣标签失败（整页「加载失败」）；`failsSettingsKeywordsLoad` 只让读关键词失败（页面照出，只有本机的词）。
        var failsSettingsLoad = false
        var failsSettingsKeywordsLoad = false
        /// 存偏好 / 删兴趣标签 / 重置 / 加删关键词 失败（界面改回来并提示「操作失败」）。
        var failsSettingsWrites = false
        /// 设置页的请求被限速：回 429 带这么多秒的 `Retry-After`；nil = 不限速。
        var settingsThrottledRetryAfterSeconds: Int?
        /// 设置页的区域：`cn`（默认；敏感内容没有「更多」，选了回 400 `not_available_in_region`）或海外（比如 `us`）。
        var settingsRegion = "cn"
        /// 引擎在按兴趣打分（出个性化开关）还是编辑精选阶段（只有一句说明，默认）。
        var settingsPersonalizationToggleVisible = false
    }

    /// 作者主页样例的关系状态（关注 / 屏蔽 / 不看·不让看），见 `SampleFeedSource+Profile.swift`。
    let profiles = SampleProfileState()
    let listsState = SampleListsState()
    let detailExtras = SampleDetailExtrasState()
    let topicFollows = SampleTopicState()
    let notificationState = SampleNotificationState()
    let myPostsState = SampleMyPostsState()
    let settingsState = SampleSettingsState()

    private var storedSimulation = Simulation()

    var simulation: Simulation {
        get { locked { storedSimulation } }
        set { locked { storedSimulation = newValue } }
    }

    init(now: @escaping () -> Date = Date.init, commentsLatencyNanos: UInt64 = 500_000_000) {
        self.now = now
        self.commentsLatencyNanos = commentsLatencyNanos
    }

    static let me = FeedAuthor(profileId: "s-me", displayName: "我", tellomiNumber: "1000000001")

    static let authors = [
        FeedAuthor(profileId: "s-1", displayName: "山风", handle: "shanfeng"),
        FeedAuthor(profileId: "s-2", displayName: "小满", tellomiNumber: "3820145967"),
        FeedAuthor(profileId: "s-3", displayName: "阿禾在路上", handle: "ahe"),
        FeedAuthor(profileId: "s-4", displayName: "周末烘焙", handle: "weekend_bake"),
        FeedAuthor(profileId: "s-5", displayName: "夜跑的猫", handle: "nightcat"),
    ]

    private static let texts = [
        "今天的云很低，像是伸手就能摸到。下班路上停下来看了五分钟。",
        "第一次自己做酸面包，外皮裂得刚刚好，就是有点酸过头了。",
        "楼下新开了一家修自行车的小铺，老板说他修了三十年车。",
        "雨后的石板路，踩上去会响。",
        "夜跑第 100 天，配速没变快，但心情变好了。",
        "整理旧照片，翻到小时候在外婆家院子里的那棵枇杷树。",
        "周末去山里住了一晚，早上被鸟叫醒，比闹钟好听多了。",
        "学会了一个新词：「回甘」。喝完这杯茶才懂。",
        "阳台的薄荷又长疯了，谁要来摘一点？",
        "地铁上看完一本小说，最后一页没舍得翻。",
        "今天试着一整天不看手机，坚持到了下午三点。",
        "给猫换了新猫砂，它研究了半个小时才肯进去。",
    ]

    static let topics = [
        FeedTopic(slug: "daily", label: "日常"),
        FeedTopic(slug: "food", label: "美食"),
        FeedTopic(slug: "outdoors", label: "户外"),
        FeedTopic(slug: "reading", label: "读书"),
    ]

    static let ipLabels = ["四川", "重庆", "浙江", "广东", "云南"]

    private static let commentTexts = [
        "拍得真好，我也想去看看。",
        "哈哈，我家楼下也有一家这样的小店。",
        "收藏了，周末试试。",
        "好久没看到这么安静的画面了。",
        "谢谢分享！",
        "同感，下班路上最治愈。",
        "能说说具体在哪儿吗？",
        "第二张最喜欢。",
    ]

    static let commentPageSize = 5

    /// 样例帖子详情页里能看到各个状态（内部用户在没有内容引擎时看界面用）：
    /// - 评论数是 0 的帖子（`sample-0`、`sample-4`…）：「还没有评论」
    /// - `sample-2`、`sample-6`…：第一次取评论失败，点「重试」后成功
    /// - `sample-7`：打开后 Card API 说这条看不到了（「已不可见」）
    /// - 评论多于一页的（如 `sample-3`、`sample-5`）：滑到底取下一页
    static let goneIds: Set<String> = ["sample-7"]
    /// 作者关了评论的帖子（`sample-9`）：详情页不显示评论输入框。
    static let closedCommentIds: Set<String> = ["sample-9"]

    static func failsFirstCommentLoad(postId: String) -> Bool {
        guard let index = sampleIndex(of: postId) else { return false }
        return index % 4 == 2
    }

    static func sampleIndex(of id: String) -> Int? {
        let prefix = "sample-"
        guard id.hasPrefix(prefix) else { return nil }
        return Int(id.dropFirst(prefix.count))
    }

    private lazy var recommend: [FeedCard] = (0..<24).map(sampleCard)
    private lazy var following: [FeedCard] = recommend.filter { ["s-1", "s-3"].contains($0.author?.profileId) }

    func config() async throws -> FeedConfig {
        var config = FeedConfig()
        config.enabled = true
        let simulation = self.simulation
        config.region = simulation.settingsRegion
        config.personalizationToggleVisible = simulation.settingsPersonalizationToggleVisible
        config.tabs = FeedTab.allCases.map(\.apiName)
        config.recommendMode = simulation.settingsPersonalizationToggleVisible ? FeedConfig.recommendModeScored : FeedConfig.recommendModeEditorial
        config.ipRegionVisible = true
        return config
    }

    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage {
        return locked {
            let base = tab == .recommend ? recommend : following
            let all = (mine + base).filter { !hidden.contains($0.id) }
            let start = min(max(cursor.flatMap { Int($0) } ?? 0, 0), all.count)
            let end = min(start + Self.pageSize, all.count)
            let cards = all[start..<end].map { card -> FeedCard in
                var card = card
                let isLiked = liked.contains(card.id)
                card.viewer.liked = isLiked
                card.stats.likes += isLiked ? 1 : 0
                card.stats.comments += postedComments[card.id]?.count ?? 0
                card.viewer.canComment = !Self.closedCommentIds.contains(card.id)
                if storedSimulation.ownPostIds.contains(card.id) { card.viewer.isAuthor = true }
                return card
            }
            return FeedTimelinePage(cards: cards, nextCursor: end < all.count ? String(end) : nil)
        }
    }

    func card(contentId: String) async throws -> FeedCard? {
        let latency = simulation.cardLatencyNanos
        if latency > 0 {
            try? await Task.sleep(nanoseconds: latency)
        }
        return locked {
            guard !Self.goneIds.contains(contentId) else { return nil }
            guard var card = (mine + recommend).first(where: { $0.id == contentId }) ?? sampleMyPostsCard(contentId) else { return nil }
            let isLiked = liked.contains(card.id)
            card.viewer.liked = isLiked
            card.stats.likes += isLiked ? 1 : 0
            card.stats.comments += postedComments[card.id]?.count ?? 0
            card.viewer.canComment = !Self.closedCommentIds.contains(card.id)
            if storedSimulation.ownPostIds.contains(card.id) { card.viewer.isAuthor = true }
            return card
        }
    }

    func comments(postId: String, cursor: String?) async throws -> FeedCommentsPage {
        if commentsLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: commentsLatencyNanos)
        }
        let failNow = locked { () -> Bool in
            guard cursor == nil, Self.failsFirstCommentLoad(postId: postId), !failedCommentLoads.contains(postId) else { return false }
            failedCommentLoads.insert(postId)
            return true
        }
        if failNow {
            throw SampleFeedError.simulatedCommentFailure
        }
        let all = sampleComments(postId: postId) + locked { postedComments[postId] ?? [] }
        let start = min(max(cursor.flatMap { Int($0) } ?? 0, 0), all.count)
        let end = min(start + Self.commentPageSize, all.count)
        return FeedCommentsPage(comments: Array(all[start..<end]), cursor: end < all.count ? String(end) : nil)
    }

    func setLiked(contentId: String, liked isLiked: Bool) async throws {
        let simulation = self.simulation
        if simulation.likeLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: simulation.likeLatencyNanos)
        }
        if simulation.failsLikes {
            throw SampleFeedError.simulatedActionFailure
        }
        locked {
            if isLiked {
                liked.insert(contentId)
            } else {
                liked.remove(contentId)
            }
        }
    }

    /// 发评论：直接显示的接在这个帖子的评论后面（卡片上的评论数也 +1）；`pending` 的别人看不到，不加。
    /// `simulation` 里的开关可以让它慢、失败、或回引擎的错误码。
    func postComment(postId: String, text: String, parentId: String?) async throws -> String {
        let simulation = self.simulation
        if simulation.postCommentLatencyNanos > 0 {
            try? await Task.sleep(nanoseconds: simulation.postCommentLatencyNanos)
        }
        if let code = simulation.commentErrorCode {
            throw FeedAPIError(status: 403, code: code)
        }
        if simulation.failsComments {
            throw SampleFeedError.simulatedActionFailure
        }
        if Self.closedCommentIds.contains(postId) {
            throw FeedAPIError(status: 403, code: "comments_closed")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return locked {
            guard simulation.commentPublishState != FeedCreatePostResponse.statePending else {
                return FeedCreatePostResponse.statePending
            }
            var list = postedComments[postId] ?? []
            var comment = FeedCard(
                id: "\(postId)-m\(list.count)",
                kind: FeedCard.kindComment,
                publishedAt: FeedDates.format(now()),
                author: Self.me,
                text: trimmed,
            )
            comment.rootId = postId
            comment.parentId = parentId
            comment.viewer.isAuthor = true
            list.append(comment)
            postedComments[postId] = list
            return FeedCreatePostResponse.statePublished
        }
    }

    func notInterested(contentId: String) async throws {
        let simulation = self.simulation
        try await simulatedAction(latency: simulation.notInterestedLatencyNanos, fails: simulation.failsNotInterested)
        _ = locked { hidden.insert(contentId) }
    }

    /// 样例里收到的举报（按收到的顺序），单测和内部用户在日志里看。
    private(set) var reports = [FeedReportRequest]()
    private(set) var uploadedImages = 0

    /// 举报要截图的原因（诈骗、「我的权益」）提交时先上传截图：样例直接给个键，让这条路能在本机跑通。
    func uploadImage(_ image: UIImage) async throws -> String {
        return locked {
            uploadedImages += 1
            return "sample-upload-\(uploadedImages)"
        }
    }

    func report(_ request: FeedReportRequest) async throws {
        let simulation = self.simulation
        try await simulatedAction(latency: simulation.reportLatencyNanos, fails: simulation.failsReports)
        locked { reports.append(request) }
    }

    /// 删自己的帖子 / 评论。样例里只有自己发的（`mine-…`、`…-m…`）能删，别人的 403 `not_author`；已经删了的 404。
    func deletePost(contentId: String) async throws {
        let simulation = self.simulation
        try await simulatedAction(latency: simulation.deleteLatencyNanos, fails: simulation.failsDeletes)
        try locked {
            if detailExtras.decline(contentId) { return }
            if let index = mine.firstIndex(where: { $0.id == contentId }) {
                mine.remove(at: index)
                return
            }
            for (postId, list) in postedComments {
                if let index = list.firstIndex(where: { $0.id == contentId }) {
                    var next = list
                    next.remove(at: index)
                    postedComments[postId] = next
                    return
                }
            }
            if myPostsState.delete(contentId) { return }
            if contentId.hasPrefix("mine-") || contentId.contains("-m") {
                throw FeedAPIError(status: 404, code: "not_found")
            }
            throw FeedAPIError(status: 403, code: "not_author")
        }
    }

    /// 这三个动作共用的模拟：先等、再按开关失败 / 限速 / 动态被关。
    private func simulatedAction(latency: UInt64, fails: Bool) async throws {
        let simulation = self.simulation
        if latency > 0 {
            try? await Task.sleep(nanoseconds: latency)
        }
        if simulation.feedHidden {
            throw FeedAPIError(status: 404, code: "feed_hidden")
        }
        if let seconds = simulation.throttledRetryAfterSeconds {
            throw FeedAPIError(status: 429, code: "rate_limited", retryAfterSeconds: seconds)
        }
        if fails {
            throw SampleFeedError.simulatedActionFailure
        }
    }

    func undoNotInterested(contentId: String) async throws {
        _ = locked { hidden.remove(contentId) }
    }

    /// 同一个 `clientNonce` 重复发只算一次（契约 7.2 的去重）。选的图只放在本机内存（`FeedLocalImages`），样例卡片能显示出来。
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse {
        return locked {
            if let existing = published[clientNonce] {
                return existing
            }
            let id = "mine-\(mine.count)"
            let media = draft.attachedImages.map { image -> FeedMedia in
                let key = FeedLocalImages.key(for: image.id)
                FeedLocalImages.shared.set(image.image, for: key)
                return FeedMedia(key: key, w: Int(image.image.size.width), h: Int(image.image.size.height))
            }
            let request = draft.request
            var card = FeedCard(
                id: id,
                kind: draft.kind.apiName,
                displayMode: draft.kind == .article ? FeedCard.displayArticleCard : (media.isEmpty ? FeedCard.displayText : FeedCard.displayTextImages),
                publishedAt: FeedDates.format(now()),
                author: Self.me,
                title: request.title,
                text: request.text,
                media: media,
                ipRegionLabel: Self.ipLabels[0],
            )
            card.viewer.isAuthor = true
            mine.insert(card, at: 0)
            let response = FeedCreatePostResponse(id: id, state: FeedCreatePostResponse.statePublished)
            published[clientNonce] = response
            return response
        }
    }

    /// 样例不连网：事件只记个数，方便内部用户在日志里看曝光有没有在算。
    private(set) var reportedEvents = [FeedEventPayload]()

    func reportEvents(_ events: [FeedEventPayload]) async throws {
        locked { reportedEvents += events }
        Logger.debug("feed sample events: \(events.count)")
    }

    /// 编辑自己的帖子（只改正文和长文标题）：样例里发的（`mine-N`）和自带的审核中那条（`mine-seed-p1`）。
    /// 和引擎一样：发布 / 创建后超过 `limits.edit_window_seconds`（900 秒）回 409 `edit_window_closed`，
    /// 未通过 / 已撤回回 409 `not_editable`，不是自己的 / 不存在回 404，正文空 / 长文标题空回 400 `invalid_text`。
    func editPost(contentId: String, draft: FeedDraft) async throws -> FeedCreatePostResponse {
        let simulation = self.simulation
        if simulation.editLatencyNanos > 0 { try? await Task.sleep(nanoseconds: simulation.editLatencyNanos) }
        if simulation.failsEdits { throw SampleFeedError.simulatedActionFailure }
        let request = draft.toEditRequest()
        if request.text.isEmpty || (draft.kind == .article && (request.title ?? "").isEmpty) {
            throw FeedAPIError(status: 400, code: "invalid_text")
        }
        let nowDate = now()
        func check(createdAt: String?, state: String) throws {
            if simulation.editsNotEditable || state == FeedMyPost.stateRejected || state == FeedMyPost.stateWithdrawn {
                throw FeedAPIError(status: 409, code: "not_editable")
            }
            let created = createdAt.flatMap(FeedDates.parse)
            let expired = created.map { nowDate.timeIntervalSince($0) > TimeInterval(FeedLimits().editWindowSeconds) } ?? false
            if simulation.editsWindowClosed || expired { throw FeedAPIError(status: 409, code: "edit_window_closed") }
        }
        let editedOwn: Bool = try locked {
            guard let index = mine.firstIndex(where: { $0.id == contentId }) else { return false }
            try check(createdAt: mine[index].publishedAt, state: FeedMyPost.statePublished)
            mine[index].text = request.text
            if draft.kind == .article { mine[index].title = request.title }
            mine[index].edited = true
            return true
        }
        if editedOwn { return FeedCreatePostResponse(id: contentId, state: FeedCreatePostResponse.statePublished) }
        guard let seed = SampleMyPostsState.seeds(base: nowDate).first(where: { $0.id == contentId }),
              !myPostsState.snapshot().deleted.contains(contentId) else {
            throw FeedAPIError(status: 404, code: "not_found")
        }
        try check(createdAt: seed.createdAt, state: seed.state)
        myPostsState.markEdited(contentId, title: draft.kind == .article ? request.title : nil, text: request.text)
        return FeedCreatePostResponse(id: contentId, state: seed.state)
    }

    /// 自己在样例里发的帖子（新的在前），「我的动态」要用。
    func ownLivePosts() -> [FeedCard] {
        return locked { mine }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// 一个样例帖子的评论，按时间正序（和引擎一样）。每三条一组：第 0 条直接评论帖子，第 1 条回复它，第 2 条回复第 1 条（楼中楼里「回复 @某人」）。
    /// 条数和帖子卡片上的评论数一致；找不到这个帖子（自己发的、别的 id）就没有评论。
    private func sampleComments(postId: String) -> [FeedCard] {
        guard let index = Self.sampleIndex(of: postId) else { return sampleDetailExtrasComments(postId: postId) }
        let count = (index * 3) % 12
        let current = now()
        return (0..<count).map { j -> FeedCard in
            var comment = FeedCard(
                id: "\(postId)-c\(j)",
                kind: FeedCard.kindComment,
                publishedAt: FeedDates.format(current.addingTimeInterval(-Double(count - j) * 7 * 60)),
                author: Self.authors[(index + j + 1) % Self.authors.count],
                text: Self.commentTexts[(index + j) % Self.commentTexts.count],
            )
            comment.rootId = postId
            if j % 3 != 0 {
                comment.parentId = "\(postId)-c\(j - 1)"
            }
            return comment
        }
    }

    /// 带链接的四条样例（都在没有配图的位置），在 TestFlight 里看得到链接卡片的三种样子：
    /// 大图卡（随包的示例图，我们自己画的，不是别人的品牌图）、图标横条、只有标题的横条、什么预览都没有的灰色指南针横条。
    /// 网址都用保留给示例的 example.* 域名。只在本机示例数据里：商店版不开动态，不会走到这里。
    static let sampleLinkImageName = "tellomi-feed-sample-link"
    /// 图标横条的随包示例图标（我们自己画的蓝底白圈，不是别人的品牌图）。
    static let sampleSiteIconName = "tellomi-feed-sample-site-icon"
    static let sampleLinks: [Int: (text: String, preview: FeedLinkCard.Preview?)] = [
        2: (
            "周末路线整理好了，日落那段最值得走：https://example.com/trail/sunset",
            FeedLinkCard.Preview(title: "山脊日落步道：全程 6 公里，适合新手", imageName: sampleLinkImageName, imagePixelSize: CGSize(width: 1200, height: 630)),
        ),
        4: (
            "这份酸面包配方比我之前用的稳多了 https://example.org/recipes/sourdough",
            FeedLinkCard.Preview(title: "家常酸面包：从养酵种到出炉"),
        ),
        6: ("有人去过这里吗？example.net/place/42", nil),
        8: (
            "收藏一个排版工具站 https://example.edu/tools/type",
            FeedLinkCard.Preview(title: "排版小工具：中英文间距一键整理", iconName: sampleSiteIconName),
        ),
    ]

    private func sampleCard(_ index: Int) -> FeedCard {
        let author = Self.authors[index % Self.authors.count]
        let imageCount: Int
        switch index % 4 {
        case 1: imageCount = 1
        case 3: imageCount = 3
        default: imageCount = 0
        }
        let link = Self.sampleLinks[index]
        var card = FeedCard(
            id: "sample-\(index)",
            kind: FeedCard.kindPost,
            displayMode: imageCount > 0 ? FeedCard.displayTextImages : FeedCard.displayText,
            publishedAt: FeedDates.format(now().addingTimeInterval(-Double(index * 37 + 5) * 60)),
            edited: index == 5,
            author: author,
            text: link?.text ?? Self.texts[index % Self.texts.count],
            media: (0..<imageCount).map { FeedMedia(key: "sample/\(index)/\($0)", w: 1080, h: $0 % 2 == 0 ? 1440 : 1080) },
            topics: [Self.topics[index % Self.topics.count]],
            ipRegionLabel: Self.ipLabels[index % Self.ipLabels.count],
            stats: FeedStats(likes: (index * 7) % 50, comments: (index * 3) % 12, reposts: index % 4),
        )
        card.linkPreview = link?.preview
        return card
    }
}

enum SampleFeedError: Error {
    /// 样例里「评论加载失败」的状态（只失败第一次，重试成功）。
    case simulatedCommentFailure
    /// 样例里「点赞失败」的状态（`Simulation.failsLikes`）。
    case simulatedActionFailure
}
