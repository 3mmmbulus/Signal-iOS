//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedBlockedKeywords.swift (new file)
// Local "block completely" keywords (I-9). Mirror of Android `FeedBlockedKeywords.kt`.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 一个「完全屏蔽」的关键词；`expiresAt` 毫秒（Unix），nil = 永久。
struct FeedLocalKeyword: Codable, Equatable {
    var keyword: String
    var expiresAt: Int64?
}

/// 「完全屏蔽」的关键词（第三节第 12 条）：只存在手机上，不告诉服务器（引擎 `relations.go`：「完全屏蔽」的词不离开手机），
/// 信息流里命中的卡片直接不显示。只作用于信息流（推荐、关注），搜索、主页、详情照常。
protocol FeedBlockedKeywords: AnyObject {
    /// 还没过期的词。
    func active(now: Date) -> [FeedLocalKeyword]
    func add(keyword: String, expiresAt: Date?)
    func remove(keyword: String)
}

class InMemoryFeedBlockedKeywords: FeedBlockedKeywords {
    fileprivate(set) var list = [FeedLocalKeyword]()

    init() {}

    func active(now: Date) -> [FeedLocalKeyword] {
        let nowMillis = Self.millis(now)
        return list.filter { $0.expiresAt.map { $0 > nowMillis } ?? true }
    }

    /// 同一个词（不分大小写）再加一次：换成新的有效期，放到最前面。空白词不加。
    func add(keyword: String, expiresAt: Date?) {
        let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { return }
        let kept = list.filter { $0.keyword.caseInsensitiveCompare(k) != .orderedSame }
        list = [FeedLocalKeyword(keyword: k, expiresAt: expiresAt.map(Self.millis))] + kept
        onChanged()
    }

    /// 删除按原样匹配（Android 也是：`it.keyword == keyword`，设置页拿的就是列表里的原文）。
    func remove(keyword: String) {
        list = list.filter { $0.keyword != keyword }
        onChanged()
    }

    fileprivate func onChanged() {}

    static func millis(_ date: Date) -> Int64 {
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// 存在本机，第一次用到时才读；过期的在下次改动时顺手清掉。**不进 iCloud / iTunes 备份**
/// （tellomi测试 2026-10-16 定；和 Android 的 `SignalStore` 一致，换新手机要重新加）：
/// 传 `FeedLocalStorages.backupExcluded`（`I-18/`）。旧版放在 `UserDefaults` 里的由 `FeedStorageMigration` 搬过来。
/// 它不是服务器那份（「少推荐」的词在服务端，不在这里）。
final class StoredFeedBlockedKeywords: InMemoryFeedBlockedKeywords {
    static let key = "tellomiFeedBlockedKeywords"

    private let storage: FeedLocalStorage
    private var loaded = false

    /// 故意没有默认值：不要回到会进备份的 `UserDefaults`。
    init(storage: FeedLocalStorage) {
        self.storage = storage
        super.init()
    }

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        guard let data = storage.data(forKey: Self.key), !data.isEmpty else {
            list = []
            return
        }
        // 存坏了就当没有（Android：捕获异常 → emptyList）
        list = (try? JSONDecoder().decode([FeedLocalKeyword].self, from: data)) ?? []
    }

    override func active(now: Date) -> [FeedLocalKeyword] {
        ensureLoaded()
        return super.active(now: now)
    }

    override func add(keyword: String, expiresAt: Date?) {
        ensureLoaded()
        super.add(keyword: keyword, expiresAt: expiresAt)
    }

    override func remove(keyword: String) {
        ensureLoaded()
        super.remove(keyword: keyword)
    }

    override fileprivate func onChanged() {
        let keep = super.active(now: Date())
        if keep.isEmpty {
            storage.removeValue(forKey: Self.key)
        } else if let data = try? JSONEncoder().encode(keep) {
            storage.set(data, forKey: Self.key)
        }
    }
}

extension FeedCard {
    /// 标题或正文里出现了任何一个词（不分大小写）。
    func matchesAny(_ keywords: [FeedLocalKeyword]) -> Bool {
        if keywords.isEmpty { return false }
        return keywords.contains { k in
            (title?.range(of: k.keyword, options: .caseInsensitive) != nil)
                || (text?.range(of: k.keyword, options: .caseInsensitive) != nil)
        }
    }
}
