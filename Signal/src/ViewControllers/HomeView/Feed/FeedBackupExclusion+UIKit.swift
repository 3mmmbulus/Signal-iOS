//
// DRAFT — NOT COMPILED. PARSE-ONLY on Linux (Apple's `URLResourceValues.isExcludedFromBackup`; not exercised by the harness).
// Intended location: Signal/src/ViewControllers/HomeView/Feed/FeedBackupExclusion+UIKit.swift (new file).
// UNVERIFIED on a Mac: that the flag sticks on a directory under Application Support and that `.atomic` writes keep the
// directory's exclusion for new files (the code also marks every file after every write, so it does not rely on it).
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

struct URLResourceBackupExcluder: FeedBackupExcluding {
    func excludeFromBackup(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
    }
}

enum FeedLocalStorages {
    /// `Library/Application Support/TellomiFeedLocal`（目录标成不进备份）。
    static let backupExcluded: FeedLocalStorage = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return FileFeedStorage(
            directory: base.appendingPathComponent("TellomiFeedLocal", isDirectory: true),
            excluder: URLResourceBackupExcluder()
        )
    }()

    /// 启动时调一次（在第一次用四个 store 之前）：把旧版放在 `UserDefaults.standard` 里的搬过来。
    static func migrateLegacyFeedState() {
        FeedStorageMigration.run(legacy: UserDefaultsFeedStorage(defaults: .standard), target: backupExcluded)
    }
}
