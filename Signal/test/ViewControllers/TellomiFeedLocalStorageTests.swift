//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedLocalStorageTests.swift (new file)
// I-18: phone-only feed state is kept out of iCloud / iTunes backups. `isExcludedFromBackup` is Apple-only, so these tests use a
// fake `FeedBackupExcluding` and check WHEN things get marked; the Apple implementation is parse-only.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

private struct Denied: Error {}

private final class FakeExcluder: FeedBackupExcluding, @unchecked Sendable {
    private let lock = NSLock()
    private var _marked = [String]()
    private var _failing = false
    private var _failingNames = Set<String>()
    var marked: [String] { lock.lock(); defer { lock.unlock() }; return _marked }
    var failing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failing }
        set { lock.lock(); _failing = newValue; lock.unlock() }
    }
    /// 只让这些名字的标记失败（别的照常成功）。
    var failingNames: Set<String> {
        get { lock.lock(); defer { lock.unlock() }; return _failingNames }
        set { lock.lock(); _failingNames = newValue; lock.unlock() }
    }
    func count(of name: String) -> Int { marked.filter { $0 == name }.count }
    func excludeFromBackup(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        _marked.append(url.lastPathComponent)
        if _failing || _failingNames.contains(url.lastPathComponent) { throw Denied() }
    }
}

private final class Errors: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    func add() { lock.lock(); _count += 1; lock.unlock() }
}

/// 写进去读不回来的存储（模拟磁盘写失败）。
private final class DroppingStorage: FeedLocalStorage, @unchecked Sendable {
    func data(forKey key: String) -> Data? { nil }
    func set(_ data: Data, forKey key: String) {}
    func removeValue(forKey key: String) {}
}

final class TellomiFeedLocalStorageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tellomi-feed-local-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var dir: URL { root.appendingPathComponent("TellomiFeedLocal", isDirectory: true) }

    private func make(_ excluder: FakeExcluder) -> FileFeedStorage {
        FileFeedStorage(directory: dir, excluder: excluder)
    }

    func testRoundTripOverwriteAndRemove() {
        let storage = make(FakeExcluder())
        XCTAssertNil(storage.data(forKey: "k"))
        storage.set(Data("one".utf8), forKey: "k")
        XCTAssertEqual(storage.data(forKey: "k"), Data("one".utf8))
        storage.set(Data("two".utf8), forKey: "k")
        XCTAssertEqual(storage.data(forKey: "k"), Data("two".utf8))
        // 另一个实例（重启）也读得到
        XCTAssertEqual(make(FakeExcluder()).data(forKey: "k"), Data("two".utf8))
        storage.removeValue(forKey: "k")
        XCTAssertNil(storage.data(forKey: "k"))
        storage.removeValue(forKey: "never-written")
    }

    func testReadingNeverCreatesOrMarksTheDirectory() {
        let excluder = FakeExcluder()
        let storage = make(excluder)
        XCTAssertNil(storage.data(forKey: "k"))
        storage.removeValue(forKey: "k")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(excluder.marked, [])
    }

    func testDirectoryIsMarkedOnceAndEveryFileAfterEveryWrite() {
        let excluder = FakeExcluder()
        let storage = make(excluder)
        storage.set(Data("1".utf8), forKey: "a")
        XCTAssertEqual(excluder.count(of: "TellomiFeedLocal"), 1, "目录第一次写时标")
        XCTAssertEqual(excluder.count(of: FileFeedStorage.fileName(forKey: "a")), 1)
        storage.set(Data("2".utf8), forKey: "a")   // 原子写换了新文件，要再标
        storage.set(Data("3".utf8), forKey: "b")
        XCTAssertEqual(excluder.count(of: "TellomiFeedLocal"), 1, "目录不重复标")
        XCTAssertEqual(excluder.count(of: FileFeedStorage.fileName(forKey: "a")), 2, "覆盖写之后文件再标一次")
        XCTAssertEqual(excluder.count(of: FileFeedStorage.fileName(forKey: "b")), 1)
        XCTAssertTrue(storage.isFullyExcluded)
    }

    func testAFailedMarkStillKeepsTheDataReportsItAndRetriesOnTheNextWrite() {
        let excluder = FakeExcluder()
        excluder.failing = true
        let storage = make(excluder)
        let errors = Errors()
        storage.onError = { _ in errors.add() }
        storage.set(Data("draft".utf8), forKey: "a")
        XCTAssertEqual(storage.data(forKey: "a"), Data("draft".utf8), "标失败也不丢数据")
        XCTAssertEqual(errors.count, 2, "目录和文件各报一次")
        XCTAssertFalse(storage.isFullyExcluded)

        excluder.failing = false
        storage.set(Data("draft2".utf8), forKey: "a")
        XCTAssertTrue(storage.isFullyExcluded, "下次写把目录和文件补标上")
        XCTAssertEqual(excluder.count(of: "TellomiFeedLocal"), 2)
        let before = excluder.marked.count
        storage.set(Data("draft3".utf8), forKey: "a")
        XCTAssertEqual(excluder.marked.count, before + 1, "标上之后，目录不再重试，只标这一次写的文件")
    }

    func testOneFileThatCouldNotBeMarkedKeepsTheStorageNotFullyExcludedUntilRetried() {
        let excluder = FakeExcluder()
        let name = FileFeedStorage.fileName(forKey: "a")
        excluder.failingNames = [name]
        let storage = make(excluder)
        storage.set(Data("1".utf8), forKey: "a")
        storage.set(Data("2".utf8), forKey: "b")
        XCTAssertFalse(storage.isFullyExcluded, "目录标上了，但 a 的文件没标上")
        excluder.failingNames = []
        storage.set(Data("3".utf8), forKey: "b")
        XCTAssertFalse(storage.isFullyExcluded, "只重写了 b，a 还没标")
        storage.set(Data("4".utf8), forKey: "a")
        XCTAssertTrue(storage.isFullyExcluded)
        // 删掉没标上的文件之后不再算没标上
        excluder.failingNames = [name]
        storage.set(Data("5".utf8), forKey: "a")
        XCTAssertFalse(storage.isFullyExcluded)
        storage.removeValue(forKey: "a")
        XCTAssertTrue(storage.isFullyExcluded)
    }

    func testKeysCannotEscapeTheDirectory() throws {
        let excluder = FakeExcluder()
        let storage = make(excluder)
        storage.set(Data("x".utf8), forKey: "../escape")
        storage.set(Data("y".utf8), forKey: "a/b/c")
        storage.set(Data("z".utf8), forKey: "")
        let inside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(inside.count, 3)
        XCTAssertTrue(inside.allSatisfy { !$0.contains("/") && $0.hasSuffix(".bin") })
        let outside = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(outside, ["TellomiFeedLocal"], "目录外什么也没多出来")
        XCTAssertEqual(storage.data(forKey: "../escape"), Data("x".utf8))
    }

    // MARK: 四个 store 真的走这条路

    func testTheFourStoresWriteThroughTheExcludedFiles() throws {
        let excluder = FakeExcluder()
        let storage = make(excluder)

        let history = StoredFeedSearchHistory(storage: storage)
        history.addQuery("猫")
        let drafts = StoredFeedArticleDrafts(storage: storage)
        drafts.save(FeedSavedArticle(title: "t", text: "body"))
        let keywords = StoredFeedBlockedKeywords(storage: storage)
        keywords.add(keyword: "剧透", expiresAt: nil)
        let friends = StoredFeedFriendSyncState(storage: storage)
        friends.save(engineKey: "k", acis: ["a"])
        friends.checkedAt = Date(timeIntervalSince1970: 1_791_000_000)

        for key in [StoredFeedSearchHistory.queriesKey, StoredFeedArticleDrafts.key, StoredFeedBlockedKeywords.key,
                    StoredFeedFriendSyncState.reportedKey, StoredFeedFriendSyncState.checkedAtKey] {
            XCTAssertGreaterThanOrEqual(excluder.count(of: FileFeedStorage.fileName(forKey: key)), 1, "\(key) 的文件要标上")
        }
        XCTAssertTrue(storage.isFullyExcluded)

        // 重启后都读得回来
        let again = make(FakeExcluder())
        XCTAssertEqual(StoredFeedSearchHistory(storage: again).queries(), ["猫"])
        XCTAssertEqual(StoredFeedArticleDrafts(storage: again).load(), FeedSavedArticle(title: "t", text: "body"))
        XCTAssertEqual(StoredFeedBlockedKeywords(storage: again).active(now: Date()).map(\.keyword), ["剧透"])
        XCTAssertEqual(StoredFeedFriendSyncState(storage: again).reported(engineKey: "k"), ["a"])
        XCTAssertEqual(StoredFeedFriendSyncState(storage: again).checkedAt, Date(timeIntervalSince1970: 1_791_000_000))
    }

    // MARK: 迁移

    private func legacySuite() throws -> (UserDefaults, String, UserDefaultsFeedStorage) {
        let suite = "tellomi-feed-local-legacy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, suite, UserDefaultsFeedStorage(defaults: defaults))
    }

    func testMigrationMovesEveryKeyOutOfUserDefaultsAndIsIdempotent() throws {
        let (defaults, suite, legacy) = try legacySuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in FeedStorageMigration.keys where key != StoredFeedFriendSyncState.checkedAtKey {
            legacy.set(Data("v-\(key)".utf8), forKey: key)
        }
        defaults.set(1_791_000_000.0, forKey: StoredFeedFriendSyncState.checkedAtKey)   // 旧版存的是 Double

        let excluder = FakeExcluder()
        let target = make(excluder)
        XCTAssertEqual(FeedStorageMigration.run(legacy: legacy, target: target), FeedStorageMigration.keys.count - 1)
        for key in FeedStorageMigration.keys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) 要从 UserDefaults 里删掉")
            if key != StoredFeedFriendSyncState.checkedAtKey {
                XCTAssertEqual(target.data(forKey: key), Data("v-\(key)".utf8))
            }
        }
        XCTAssertNil(target.data(forKey: StoredFeedFriendSyncState.checkedAtKey), "Double 的 checkedAt 不搬")
        XCTAssertTrue(target.isFullyExcluded)
        XCTAssertEqual(FeedStorageMigration.run(legacy: legacy, target: target), 0, "再跑什么也不做")
    }

    func testMigrationKeepsTheNewerValueAndKeepsLegacyWhenTheWriteDidNotStick() throws {
        let (defaults, suite, legacy) = try legacySuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = StoredFeedArticleDrafts.key
        legacy.set(Data("old".utf8), forKey: key)
        let target = make(FakeExcluder())
        target.set(Data("new".utf8), forKey: key)
        XCTAssertEqual(FeedStorageMigration.run(legacy: legacy, target: target, keys: [key]), 0)
        XCTAssertEqual(target.data(forKey: key), Data("new".utf8), "新的为准")
        XCTAssertNil(legacy.data(forKey: key))

        legacy.set(Data("old".utf8), forKey: key)
        XCTAssertEqual(FeedStorageMigration.run(legacy: legacy, target: DroppingStorage(), keys: [key]), 0)
        XCTAssertEqual(legacy.data(forKey: key), Data("old".utf8), "新存法没存上就留着旧的，下次再试")
    }

    func testMigratedDataIsReadByTheStores() throws {
        let (defaults, suite, legacy) = try legacySuite()
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = StoredFeedArticleDrafts(storage: legacy)
        old.save(FeedSavedArticle(title: "旧", text: "没写完"))
        let target = make(FakeExcluder())
        FeedStorageMigration.run(legacy: legacy, target: target)
        XCTAssertEqual(StoredFeedArticleDrafts(storage: target).load(), FeedSavedArticle(title: "旧", text: "没写完"))
        XCTAssertNil(StoredFeedArticleDrafts(storage: legacy).load())
    }
}
