//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 搜索页要画什么（纯逻辑，没有界面）：由 `FeedSearchState` 算出来，界面只照着画。
struct FeedSearchPresentation: Equatable {
    enum Status: Equatable {
        case loading
        /// 第一页搜失败；限速时带还要等几秒。
        case failed(retryAfterSeconds: Int?)
        /// 搜了，没有结果。
        case noResults(query: String)
        /// 什么都没输入、也没有搜索历史。
        case hint
        case loadingMore
        case loadMoreFailed(retryAfterSeconds: Int?)
    }

    enum Row: Equatable {
        case recentQueriesHeader
        case recentQuery(String)
        case recentPeopleHeader
        case recentPerson(id: String)
        case usersHeader
        case user(id: String)
        case postsHeader
        case post(id: String)
        case status(Status)
    }

    /// 范围只在输入了搜索词以后给（空的时候下面是最近搜索）。
    var showsScopeBar: Bool
    var scope: String
    var rows: [Row]
    /// 滚到底该不该再翻页：有下一页、没有在加载、上一次翻页没失败（失败了只在点「重试」时再来，免得一直重试）。
    var canLoadMore: Bool
    /// 在搜新的词，下面还留着上一份结果（不闪空）。
    var isRefreshing: Bool
    /// 引擎说动态被关了：页面该收起。
    var feedHidden: Bool
    var users: [FeedSearchUser]
    var posts: [FeedCard]
    var recentPeople: [FeedPersonSummary]

    init(state: FeedSearchState) {
        let trimmed = state.query.trimmingCharacters(in: .whitespacesAndNewlines)
        showsScopeBar = !trimmed.isEmpty
        scope = state.scope
        feedHidden = state.feedHidden
        recentPeople = state.recentPeople
        users = state.results?.users ?? []
        posts = state.results?.posts ?? []
        isRefreshing = state.loading && state.results != nil
        let results = state.results
        canLoadMore = results?.cursor != nil && !state.loading && !state.loadingMore && !state.loadMoreFailed && !state.failed

        if state.feedHidden {
            rows = []
        } else if trimmed.isEmpty {
            var rows = [Row]()
            if !state.recentQueries.isEmpty {
                rows.append(.recentQueriesHeader)
                rows += state.recentQueries.map { .recentQuery($0) }
            }
            if !state.recentPeople.isEmpty {
                rows.append(.recentPeopleHeader)
                rows += state.recentPeople.map { .recentPerson(id: $0.id) }
            }
            self.rows = rows.isEmpty ? [.status(.hint)] : rows
        } else if state.failed {
            rows = [.status(.failed(retryAfterSeconds: state.retryAfterSeconds))]
        } else if let results {
            var rows = [Row]()
            // 「全部」里分两段加标题；「用户」「动态」只有一种，不加
            let titled = results.scope == FeedAPI.searchAll
            if !results.users.isEmpty {
                if titled { rows.append(.usersHeader) }
                rows += results.users.map { .user(id: $0.id) }
            }
            if !results.posts.isEmpty {
                if titled, !results.users.isEmpty { rows.append(.postsHeader) }
                rows += results.posts.map { .post(id: $0.id) }
            }
            if rows.isEmpty {
                rows = [.status(.noResults(query: results.query))]
            } else if state.loadingMore {
                rows.append(.status(.loadingMore))
            } else if state.loadMoreFailed {
                rows.append(.status(.loadMoreFailed(retryAfterSeconds: state.retryAfterSeconds)))
            }
            self.rows = rows
        } else if state.loading {
            rows = [.status(.loading)]
        } else {
            rows = []
        }
    }
}

/// 话题页要画什么（纯逻辑）：由 `FeedTopicState` 算出来。
struct FeedTopicPresentation: Equatable {
    enum Page: Equatable {
        case loading
        case failed
        case gone
        case feedHidden
        case content
    }

    enum FollowButton: Equatable {
        case hidden
        case follow
        case following
    }

    enum Status: Equatable {
        case loading
        case failed(retryAfterSeconds: Int?)
        case gone
        case empty
        case loadingMore
        case loadMoreFailed(retryAfterSeconds: Int?)
    }

    enum Row: Equatable {
        case header
        case post(id: String)
        case status(Status)
    }

    var slug: String
    /// 标题：帖子上带的话题名（`#标签`），没有就用进来时带的名字，再没有就是 slug。
    var title: String
    var page: Page
    var followButton: FollowButton
    var isFollowEnabled: Bool
    var posts: [FeedCard]
    var rows: [Row]
    var canLoadMore: Bool

    init(state: FeedTopicState, slug: String, labelHint: String? = nil) {
        self.slug = slug
        let label = state.posts.lazy.flatMap(\.topics).first { $0.slug == slug }?.label ?? labelHint.flatMap { $0.isEmpty ? nil : $0 } ?? slug
        title = "#\(label)"
        posts = state.posts
        canLoadMore = state.cursor != nil && !state.loading && !state.loadMoreFailed && !state.failed

        if state.feedHidden {
            page = .feedHidden
        } else if state.gone {
            page = .gone
        } else if !state.loadedOnce, state.loading {
            page = .loading
        } else if state.failed {
            page = .failed
        } else {
            page = .content
        }

        followButton = page == .content ? (state.following ? .following : .follow) : .hidden
        isFollowEnabled = page == .content && state.loadedOnce

        switch page {
        case .feedHidden:
            rows = []
        case .loading:
            rows = [.status(.loading)]
        case .failed:
            rows = [.status(.failed(retryAfterSeconds: state.retryAfterSeconds))]
        case .gone:
            rows = [.status(.gone)]
        case .content:
            var rows: [Row] = [.header]
            if state.posts.isEmpty {
                rows.append(.status(state.loading ? .loading : .empty))
            } else {
                rows += state.posts.map { .post(id: $0.id) }
                if state.loadingMore {
                    rows.append(.status(.loadingMore))
                } else if state.loadMoreFailed {
                    rows.append(.status(.loadMoreFailed(retryAfterSeconds: state.retryAfterSeconds)))
                }
            }
            self.rows = rows
        }
    }
}

/// 帖子上那一行 `#话题  #话题`：文字怎么排、点到的字符属于哪个话题（纯逻辑；界面里按点击位置换成字符位置再问这里）。
enum FeedTopicChips {
    static let separator = "  "

    static func label(_ topic: FeedTopic) -> String {
        return "#\(topic.label)"
    }

    static func text(for topics: [FeedTopic]) -> String {
        return topics.map(label).joined(separator: separator)
    }

    /// 每个话题在 `text(for:)` 里的范围（UTF-16 位置，和 `NSRange` / `NSLayoutManager` 一致）。
    static func ranges(for topics: [FeedTopic]) -> [NSRange] {
        var location = 0
        var result = [NSRange]()
        for topic in topics {
            let length = label(topic).utf16.count
            result.append(NSRange(location: location, length: length))
            location += length + separator.utf16.count
        }
        return result
    }

    /// 点到的字符位置属于第几个话题；点在两个话题之间的空格上算前一个（手指不用点得很准），点在最前面 / 最后面之外是 nil。
    static func index(atCharacter character: Int, in topics: [FeedTopic]) -> Int? {
        let ranges = ranges(for: topics)
        guard let first = ranges.first, let last = ranges.last, character >= first.location, character < last.location + last.length else {
            return nil
        }
        return ranges.lastIndex { $0.location <= character }
    }
}
