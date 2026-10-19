//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedLocalStorage.swift (new file).
// Phone-only feed state that must NOT go into iCloud / iTunes backups (decision by tellomi测试, 2026-10-16):
// search history (I-8), unfinished article draft (I-12), friend-sync state (I-11), blocked keywords (I-9).
// Cross-item helper: those four stores take a `FeedLocalStorage` instead of `UserDefaults` (no default value on purpose,
// so nobody can fall back to `UserDefaults.standard` by accident).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// 本机的小块数据，一个 key 对一块 `Data`。语义和 `UserDefaults` 的 `data(forKey:)` / `set` / `removeObject` 一样：
/// 不抛错（读不到就是 nil，写失败就是没存上），出错走各实现自己的 `onError`。
protocol FeedLocalStorage: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data, forKey key: String)
    func removeValue(forKey key: String)
}

/// 把一个文件或目录标成「不进备份」。苹果上用 `URLResourceValues.isExcludedFromBackup`（`FeedBackupExclusion+UIKit.swift`，
/// 只在 Mac 上编译）；Linux 测试里用假的，只测「什么时候标」「标失败怎么办」。
protocol FeedBackupExcluding: Sendable {
    func excludeFromBackup(_ url: URL) throws
}

/// 老做法（`UserDefaults`，会进 iCloud / iTunes 备份）。现在只在两处用：迁移时当来源，测试里当后端。
final class UserDefaultsFeedStorage: FeedLocalStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data, forKey key: String) { defaults.set(data, forKey: key) }
    func removeValue(forKey key: String) { defaults.removeObject(forKey: key) }
}

/// 只在内存里（测试、预览）。
final class InMemoryFeedStorage: FeedLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values = [String: Data]()

    init() {}

    func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return values[key] }
    func set(_ data: Data, forKey key: String) { lock.lock(); values[key] = data; lock.unlock() }
    func removeValue(forKey key: String) { lock.lock(); values[key] = nil; lock.unlock() }
}

/// 一个 key 一个文件，放在一个标成「不进备份」的目录里（Application Support 下的子目录；那里默认是进备份的，所以必须标）。
///
/// 标记的时机：
/// - 目录：第一次写之前建出来就标。读不会建目录，也不会标。
/// - 文件：**每次写完都再标一次**。`.atomic` 写是「写临时文件再换名」，换名后的是新文件，旧文件上的标记不会跟过来；
///   目录上的标记在苹果的系统上本来就管着里面的文件，逐个文件再标是第二道保险。
/// - 标失败（磁盘满、系统返回错误）：数据照样存（丢一篇没写完的长文比多进一次备份更糟），错误交给 `onError`，
///   这个目录 / 文件下次写时再试；`isFullyExcluded` 能查还有没有没标上的。
final class FileFeedStorage: FeedLocalStorage, @unchecked Sendable {
    private let directory: URL
    private let excluder: FeedBackupExcluding
    private let fileManager: FileManager
    private let lock = NSLock()
    private var directoryMarked = false
    private var unmarkedFiles = Set<String>()

    /// 存或标失败时调（可能在任意线程）。
    var onError: (@Sendable (Error) -> Void)?

    init(directory: URL, excluder: FeedBackupExcluding, fileManager: FileManager = .default) {
        self.directory = directory
        self.excluder = excluder
        self.fileManager = fileManager
    }

    /// key 里的 `/`、`..` 等都转掉，文件一定落在 `directory` 里面。
    static func fileName(forKey key: String) -> String {
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "key"
        return (encoded.isEmpty ? "key" : encoded) + ".bin"
    }

    private func url(forKey key: String) -> URL {
        return directory.appendingPathComponent(Self.fileName(forKey: key), isDirectory: false)
    }

    /// 目录和所有写过的文件都已经标上了。
    var isFullyExcluded: Bool {
        lock.lock(); defer { lock.unlock() }
        return directoryMarked && unmarkedFiles.isEmpty
    }

    func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: url(forKey: key))
    }

    func set(_ data: Data, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        do {
            try ensureDirectory()
        } catch {
            onError?(error)
            return
        }
        let file = url(forKey: key)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            onError?(error)
            return
        }
        mark(file)
    }

    func removeValue(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        let file = url(forKey: key)
        unmarkedFiles.remove(file.lastPathComponent)
        guard fileManager.fileExists(atPath: file.path) else { return }
        do {
            try fileManager.removeItem(at: file)
        } catch {
            onError?(error)
        }
    }

    // MARK: lock 内

    private func ensureDirectory() throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            directoryMarked = false
        }
        if !directoryMarked {
            do {
                try excluder.excludeFromBackup(directory)
                directoryMarked = true
            } catch {
                // 目录没标上：数据照存，下次写再试
                onError?(error)
            }
        }
    }

    private func mark(_ file: URL) {
        do {
            try excluder.excludeFromBackup(file)
            unmarkedFiles.remove(file.lastPathComponent)
        } catch {
            unmarkedFiles.insert(file.lastPathComponent)
            onError?(error)
        }
    }
}

/// 一次性迁移：把以前存在 `UserDefaults` 里的这几个 key 搬进新存法，然后从 `UserDefaults` 删掉。
///
/// 规则（逐个 key）：
/// - 旧的没有 → 只确保旧的这个 key 清掉（比如旧版存成 Double 的 `checkedAt`，读成 Data 是 nil；丢了只是多检查一次）。
/// - 旧的有、新的没有 → 写进新的，**读回来一致**才删旧的；不一致（写失败）就留着旧的，下次启动再试。
/// - 旧的有、新的也有 → 以新的为准（新的是用户后来改的），旧的删掉。
/// 可以重复跑，跑完再跑什么也不做。已经进过的备份删不掉；只管从现在起不再进。
enum FeedStorageMigration {
    /// 要迁的 key：四个 store 的全部 key。
    static let keys = [
        StoredFeedSearchHistory.queriesKey, StoredFeedSearchHistory.peopleKey,
        StoredFeedArticleDrafts.key,
        StoredFeedBlockedKeywords.key,
        StoredFeedFriendSyncState.checkedAtKey, StoredFeedFriendSyncState.reportedKey,
    ]

    /// 返回搬了几个 key。
    @discardableResult
    static func run(legacy: FeedLocalStorage, target: FeedLocalStorage, keys: [String] = FeedStorageMigration.keys) -> Int {
        var moved = 0
        for key in keys {
            guard let old = legacy.data(forKey: key) else {
                legacy.removeValue(forKey: key)
                continue
            }
            if target.data(forKey: key) == nil {
                target.set(old, forKey: key)
                guard target.data(forKey: key) == old else { continue }
                moved += 1
            }
            legacy.removeValue(forKey: key)
        }
        return moved
    }
}
