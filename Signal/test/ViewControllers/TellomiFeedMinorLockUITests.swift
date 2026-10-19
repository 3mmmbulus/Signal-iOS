//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 未成年人时限（I-15）的界面接线（UIKit）：提示页盖上 / 拿掉、顶栏和发布按钮不能点、推进去的页面退回来、计时器在不在用时暂停。
/// 计时和判定在 `TellomiFeedMinorGateTests` / `TellomiFeedMinorTimeTests`。
final class TellomiFeedMinorLockUITests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: hour, minute: minute))!
    }

    @MainActor
    private func makeFeed(now: Date, minor: Bool?, usedMillis: Int64 = 0) -> (FeedViewController, FeedMinorGate, UIWindow) {
        let usage = InMemoryFeedMinorUsage()
        usage.add(day: FeedMinorTime.dayKey(now, calendar: calendar), millis: usedMillis)
        let gate = FeedMinorGate(memory: InMemoryFeedMinorModeMemory(lastKnown: minor), usage: usage, clock: { now }, monotonicMillis: { 0 }, calendar: calendar)
        let feed = FeedViewController(source: SampleFeedSource(), searchEnabled: true, minorTimeEnabled: true, minorGate: gate)
        let navigation = OWSNavigationController(rootViewController: feed)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        feed.loadViewIfNeeded()
        window.layoutIfNeeded()
        return (feed, gate, window)
    }

    @MainActor
    func testTheSwitchIsOffByDefaultAndOffMeansNoGate() {
        XCTAssertFalse(TellomiFeed.isMinorTimeEnabled)
        let feed = FeedViewController(source: SampleFeedSource())
        feed.loadViewIfNeeded()
        XCTAssertNil(feed.minorGate)
        XCTAssertTrue(feed.minorLockView.isHidden)
        XCTAssertFalse(feed.composeButton.isHidden)
    }

    @MainActor
    func testAtNightTheLockPageCoversTheFeed() {
        let (feed, _, window) = makeFeed(now: date(23), minor: true)
        defer { window.isHidden = true }
        XCTAssertFalse(feed.minorLockView.isHidden)
        XCTAssertEqual(feed.minorLockView.lock, .night)
        XCTAssertEqual(feed.minorLockView.titleLabel.text, FeedMinorLockView.title(.night))
        XCTAssertEqual(feed.minorLockView.bodyLabel.text, FeedMinorLockView.body(.night))
        XCTAssertEqual(feed.minorLockView.bodyLabel.numberOfLines, 0, "大字号不截断")
        XCTAssertTrue(feed.composeButton.isHidden)
        XCTAssertTrue(feed.navigationItem.rightBarButtonItems?.allSatisfy { !$0.isEnabled } ?? feed.navigationItem.rightBarButtonItem?.isEnabled == false)
        XCTAssertTrue(feed.view.subviews.last === feed.minorLockView, "盖在最上面")
    }

    @MainActor
    func testFortyMinutesUsedShowsTheDailyPage() {
        let (feed, _, window) = makeFeed(now: date(12), minor: true, usedMillis: FeedMinorTime.dailyLimitMillis)
        defer { window.isHidden = true }
        XCTAssertEqual(feed.minorLockView.lock, .daily)
        XCTAssertEqual(feed.minorLockView.titleLabel.text, FeedMinorLockView.title(.daily))
    }

    @MainActor
    func testDaytimeWithTimeLeftAndNotMinorAreNotLocked() {
        let (day, _, dayWindow) = makeFeed(now: date(12), minor: true, usedMillis: 60_000)
        defer { dayWindow.isHidden = true }
        XCTAssertTrue(day.minorLockView.isHidden)
        let (adult, _, adultWindow) = makeFeed(now: date(23), minor: false)
        defer { adultWindow.isHidden = true }
        XCTAssertTrue(adult.minorLockView.isHidden)
    }

    @MainActor
    func testAConfigSayingNotMinorLiftsTheLock() {
        let (feed, gate, window) = makeFeed(now: date(23), minor: true)
        defer { window.isHidden = true }
        gate.configLoaded(minorMode: false)
        XCTAssertTrue(feed.minorLockView.isHidden)
        XCTAssertFalse(feed.composeButton.isHidden)
        XCTAssertTrue(feed.navigationItem.rightBarButtonItems?.allSatisfy(\.isEnabled) ?? feed.navigationItem.rightBarButtonItem?.isEnabled == true)
    }

    @MainActor
    func testLockingWhileAPostIsOpenGoesBackToTheFeed() {
        let (feed, gate, window) = makeFeed(now: date(23), minor: false)
        defer { window.isHidden = true }
        let pushed = UIViewController()
        feed.navigationController?.pushViewController(pushed, animated: false)
        XCTAssertTrue(feed.navigationController?.topViewController === pushed)
        gate.configLoaded(minorMode: true)
        XCTAssertTrue(feed.navigationController?.topViewController === feed)
        XCTAssertFalse(feed.minorLockView.isHidden)
    }

    @MainActor
    func testTheTimerPausesWhenTheFeedTabIsNotInUse() {
        let (feed, gate, window) = makeFeed(now: date(12), minor: true)
        defer { window.isHidden = true }
        var active = true
        feed.isFeedTabActive = { active }
        feed.minorTimerFired()
        XCTAssertTrue(gate.isRunning)
        active = false
        feed.minorTimerFired()
        XCTAssertFalse(gate.isRunning)
        active = true
        feed.minorTimerFired()
        XCTAssertTrue(gate.isRunning)
    }

    @MainActor
    func testBackgroundPausesTheTimer() {
        let (feed, gate, window) = makeFeed(now: date(12), minor: true)
        defer { window.isHidden = true }
        feed.isFeedTabActive = { true }
        feed.minorTimerFired()
        XCTAssertTrue(gate.isRunning)
        NotificationCenter.default.post(name: .OWSApplicationDidEnterBackground, object: nil)
        XCTAssertFalse(gate.isRunning)
    }
}
