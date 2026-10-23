//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit

final class AppExpiryTest: XCTestCase {
    private var appVersion: AppVersionNumber4!
    private var buildDate: Date!
    private var db: (any DB)!
    private var keyValueStore: KeyValueStore!

    private var appExpiry: AppExpiry!

    // Tellomi（tellomi/tellomi#1142）：兜底有效期 180 天（上游 90 天）。
    private var defaultExpiry: Date { buildDate.addingTimeInterval(180 * .day) }

    private func loadPersistedExpirationDate() -> Date {
        let newAppExpiry = AppExpiry(appVersion: appVersion, buildDate: buildDate)
        db.read { newAppExpiry.warmCaches(with: $0) }
        return newAppExpiry.expirationDate
    }

    override func setUp() {
        appVersion = try! AppVersionNumber4(AppVersionNumber("1.2.3.4"))
        buildDate = Date()
        db = InMemoryDB()
        keyValueStore = KeyValueStore(
            collection: AppExpiry.keyValueCollection,
        )

        appExpiry = AppExpiry(appVersion: appVersion, buildDate: buildDate)
    }

    func testDefaultExpiry() {
        XCTAssertEqual(appExpiry.expirationDate, defaultExpiry)

        XCTAssertFalse(appExpiry.isExpired(now: buildDate))
        XCTAssertFalse(appExpiry.isExpired(now: defaultExpiry))
        XCTAssertTrue(appExpiry.isExpired(now: defaultExpiry.addingTimeInterval(1)))
    }

    func testTestFlightBuildsExpireAfterNinetyDays() {
        // owner 2026-09-25：TestFlight 构建 90 天后被 TestFlight 停用；App 内按 90 天算，「14 天后过期」第 76 天起出现。
        let testFlight = AppExpiry(appVersion: appVersion, buildDate: buildDate, isTestFlightBuild: true)
        let ninetyDays = buildDate.addingTimeInterval(90 * .day)
        XCTAssertEqual(testFlight.expirationDate, ninetyDays)
        XCTAssertFalse(testFlight.isExpired(now: ninetyDays))
        XCTAssertTrue(testFlight.isExpired(now: ninetyDays.addingTimeInterval(1)))
        XCTAssertTrue(testFlight.isBuildTooOld(now: ninetyDays.addingTimeInterval(1)))

        // 别的装法（App Store、Xcode 直接装）照旧 180 天。
        XCTAssertEqual(appExpiry.expirationDate, defaultExpiry)
    }

    func testOnlyASandboxReceiptThatExistsMeansTestFlight() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sandboxReceipt = directory.appendingPathComponent("sandboxReceipt")
        let appStoreReceipt = directory.appendingPathComponent("receipt")
        try Data("receipt".utf8).write(to: sandboxReceipt)
        try Data("receipt".utf8).write(to: appStoreReceipt)

        XCTAssertTrue(AppExpiry.isTestFlightInstall(receiptURL: sandboxReceipt))
        XCTAssertFalse(AppExpiry.isTestFlightInstall(receiptURL: appStoreReceipt))
        // Xcode 直接装的开发包：收据地址照样叫 sandboxReceipt，但文件不存在。
        XCTAssertFalse(AppExpiry.isTestFlightInstall(receiptURL: directory.appendingPathComponent("missing/sandboxReceipt")))
        XCTAssertFalse(AppExpiry.isTestFlightInstall(receiptURL: nil))
    }

    /// TestFlight 动态用的判断：只看文件名，不要求文件存在（TestFlight 真机上收据文件常常还没写到本地）。
    func testFeedTestFlightCheckOnlyLooksAtTheReceiptName() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(AppExpiry.hasSandboxReceiptURL(directory.appendingPathComponent("missing/sandboxReceipt")))
        XCTAssertFalse(AppExpiry.hasSandboxReceiptURL(directory.appendingPathComponent("receipt")))
        XCTAssertFalse(AppExpiry.hasSandboxReceiptURL(nil))
    }

    func testWarmCachesWithInvalidDataInDatabase() throws {
        let data = Data([1, 2, 3])
        db.write { tx in
            keyValueStore.setData(data, key: AppExpiry.keyValueKey, transaction: tx)
        }

        db.read { self.appExpiry.warmCaches(with: $0) }

        XCTAssertEqual(appExpiry.expirationDate, defaultExpiry)
    }

    func testWarmCachesWithNothingPersisted() {
        db.read { self.appExpiry.warmCaches(with: $0) }

        XCTAssertEqual(appExpiry.expirationDate, defaultExpiry)
    }

    func testWarmCachesIgnoresPersistedValueWithDifferentVersion() {
        let savedJson = #"{"appVersion":"6.5.4.3","mode":"immediately"}"#.data(using: .utf8)!
        db.write { tx in
            keyValueStore.setData(savedJson, key: AppExpiry.keyValueKey, transaction: tx)
        }

        db.read { self.appExpiry.warmCaches(with: $0) }

        XCTAssertEqual(appExpiry.expirationDate, defaultExpiry)
    }

    func testWarmCachesIgnoresPersistedValueWithOldKeyName() throws {
        let savedJson = #"{"version4":"6.5.4.3","mode":"immediately"}"#.data(using: .utf8)!
        db.write { tx in
            keyValueStore.setData(savedJson, key: AppExpiry.keyValueKey, transaction: tx)
        }

        db.read { self.appExpiry.warmCaches(with: $0) }

        XCTAssertEqual(appExpiry.expirationDate, defaultExpiry)
    }

    func testWarmCachesWithPersistedDefault() throws {
        let savedJson = try JSONEncoder().encode([
            "appVersion": appVersion.wrappedValue.rawValue,
            "mode": "default",
        ])
        db.write { tx in
            keyValueStore.setData(savedJson, key: AppExpiry.keyValueKey, transaction: tx)
        }

        db.read { self.appExpiry.warmCaches(with: $0) }

        XCTAssertEqual(appExpiry.expirationDate, defaultExpiry)
    }

    func testWarmCachesWithPersistedImmediateExpiry() throws {
        let savedJson = try JSONEncoder().encode([
            "appVersion": appVersion.wrappedValue.rawValue,
            "mode": "immediately",
        ])
        db.write { tx in
            keyValueStore.setData(savedJson, key: AppExpiry.keyValueKey, transaction: tx)
        }

        db.read { self.appExpiry.warmCaches(with: $0) }

        XCTAssertEqual(appExpiry.expirationDate, .distantPast)
    }

    func testWarmCachesWithPersistedExpirationDate() {
        let expirationDate = defaultExpiry.addingTimeInterval(-1234)

        let savedJson = """
        {
            "appVersion": "\(appVersion.wrappedValue.rawValue)",
            "mode": "atDate",
            "expirationDate": \(expirationDate.timeIntervalSinceReferenceDate)
        }
        """.data(using: .utf8)!
        db.write { tx in
            keyValueStore.setData(savedJson, key: AppExpiry.keyValueKey, transaction: tx)
        }

        db.read { self.appExpiry.warmCaches(with: $0) }

        XCTAssertEqual(appExpiry.expirationDate, expirationDate)
    }

    func testSetHasAppExpiredAtCurrentVersion() async {
        await appExpiry.setHasAppExpiredAtCurrentVersion(db: db)

        XCTAssertEqual(appExpiry.expirationDate, .distantPast)
        XCTAssertTrue(appExpiry.isExpired(now: buildDate))

        XCTAssertEqual(loadPersistedExpirationDate(), .distantPast)
    }

    func testClearingExpirationDateForCurrentVersion() async {
        await appExpiry.setExpirationDateForCurrentVersion(nil, now: buildDate, db: db)

        XCTAssertEqual(appExpiry.expirationDate, defaultExpiry)
        XCTAssertFalse(appExpiry.isExpired(now: buildDate))

        XCTAssertEqual(loadPersistedExpirationDate(), defaultExpiry)
    }

    func testSetHasExpirationDateForCurrentVersion() async {
        let expirationDate = defaultExpiry.addingTimeInterval(-1234)

        await appExpiry.setExpirationDateForCurrentVersion(expirationDate, now: buildDate, db: db)

        XCTAssertEqual(appExpiry.expirationDate, expirationDate)

        XCTAssertEqual(loadPersistedExpirationDate(), expirationDate)
    }
}
