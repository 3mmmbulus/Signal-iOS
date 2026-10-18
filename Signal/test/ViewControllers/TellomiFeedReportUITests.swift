//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// 举报页的界面检查（UIKit）：在测试进程里放一个真的 `FeedViewController`（样例数据），点开一条帖子，从详情页的「···」进举报页。
/// 和 `TellomiFeedDetailUITests` 一样走真接线；样例的 `simulation` 能让举报失败 / 变慢 / 限速 / `feed_hidden`，截图见报告里的步骤。
final class TellomiFeedReportUITests: XCTestCase {

    @MainActor
    private struct Harness {
        let feed: FeedViewController
        let navigation: OWSNavigationController
        let window: UIWindow
        let source: SampleFeedSource

        func openDetail(of id: String) async throws -> FeedPostDetailViewController {
            let fetched = try await source.card(contentId: id)
            let card = try XCTUnwrap(fetched)
            let detail = FeedPostDetailViewController(post: card, source: source, showIpRegion: false, feed: feed.store)
            navigation.pushViewController(detail, animated: false)
            detail.loadViewIfNeeded()
            window.layoutIfNeeded()
            await detail.detailStore.waitForTasks()
            window.layoutIfNeeded()
            return detail
        }
    }

    @MainActor
    private func makeHarness() async -> Harness {
        let source = SampleFeedSource(now: { Date(timeIntervalSince1970: 1_791_889_200) }, commentsLatencyNanos: 0)
        let feed = FeedViewController(source: source)
        let navigation = OWSNavigationController(rootViewController: feed)
        let window = UIWindow.tellomiTestWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = navigation
        window.isHidden = false
        window.layoutIfNeeded()
        await feed.store.loadConfig()
        await feed.store.waitForLoad(.recommend)
        window.layoutIfNeeded()
        return Harness(feed: feed, navigation: navigation, window: window, source: source)
    }

    /// 从详情页的「···」点「举报」，拿到举报页（已经加载、原因表已取回）。
    @MainActor
    private func openReport(on detail: FeedPostDetailViewController, comment: FeedCard? = nil) async throws -> FeedReportViewController {
        detail.handleMenuItem(.report, comment: comment)
        let report = try XCTUnwrap(detail.presentedReport)
        report.loadViewIfNeeded()
        await report.store.waitForTasks()
        report.view.layoutIfNeeded()
        return report
    }

    @MainActor
    private func reason(_ code: String, in report: FeedReportViewController) throws -> FeedReportReason {
        return try XCTUnwrap(report.presentation.groups.flatMap(\.reasons).first { $0.code == code })
    }

    // MARK: - 进入和原因列表

    @MainActor
    func testTheMenuOpensTheReportPageForThePostWithFourGroupsOfReasons() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let detail = try await harness.openDetail(of: "sample-1")
        let report = try await openReport(on: detail)

        XCTAssertEqual(report.presentation.phase, .reasons)
        XCTAssertFalse(report.reasonsTable.isHidden)
        XCTAssertTrue(report.formScroll.isHidden)
        XCTAssertEqual(report.reasonsTable.numberOfSections, 4)
        XCTAssertEqual(
            (0..<4).map { report.reasonsTable.numberOfRows(inSection: $0) },
            [5, 5, 3, 4],
            "17 项：伤害他人 5、违法违规 5、不实或冒充 3、我的权益 4",
        )
        XCTAssertNotNil(report.navigationItem.leftBarButtonItem, "取消")
        XCTAssertNil(report.navigationItem.rightBarButtonItem)
        harness.window.isHidden = true
    }

    /// 四组和 17 项的名字都翻译过（不是键名）。
    @MainActor
    func testAllReasonAndGroupNamesAreLocalized() {
        let groups = FeedReportReasons.groups(fromConfig: [:])
        XCTAssertEqual(groups.flatMap(\.reasons).count, FeedReportReasons.known.count)
        for group in groups {
            XCTAssertFalse(FeedReportViewController.groupTitle(group).hasPrefix("TELLOMI_"), group.code)
            for reason in group.reasons {
                let title = FeedReportViewController.reasonTitle(reason)
                XCTAssertFalse(title.isEmpty)
                XCTAssertFalse(title.hasPrefix("TELLOMI_"), "\(reason.code) 的名字没有翻译")
            }
        }
        for error in [FeedReportState.ReportError.gone, .failed, .throttled(retryAfterSeconds: nil), .throttled(retryAfterSeconds: 9)] {
            XCTAssertFalse(FeedReportViewController.toastText(for: error).hasPrefix("TELLOMI_"))
        }
    }

    // MARK: - 选原因、填表

    @MainActor
    func testPickingAReasonShowsTheFormAndBackGoesToTheList() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let detail = try await harness.openDetail(of: "sample-1")
        let report = try await openReport(on: detail)

        report.tableView(report.reasonsTable, didSelectRowAt: IndexPath(row: 0, section: 0))
        report.view.layoutIfNeeded()
        XCTAssertEqual(report.presentation.reason?.code, "harassment")
        XCTAssertTrue(report.reasonsTable.isHidden)
        XCTAssertFalse(report.formScroll.isHidden)
        XCTAssertTrue(report.submitButton.isEnabled, "骚扰：说明可选，直接能提交")
        XCTAssertTrue(report.relationshipField.isHidden)
        XCTAssertFalse(report.presentation.showsEvidence)

        report.store.onDetailChanged("他一直发私信骚扰我")
        report.view.layoutIfNeeded()
        XCTAssertEqual(report.detailTextView.text, "他一直发私信骚扰我")
        XCTAssertEqual(report.detailCounterLabel.text, OWSFormat.formatInt(500 - 9))

        report.store.backToReasons()
        report.view.layoutIfNeeded()
        XCTAssertFalse(report.reasonsTable.isHidden)
        XCTAssertTrue(report.formScroll.isHidden)
        harness.window.isHidden = true
    }

    @MainActor
    func testFraudNeedsAScreenshotAndMyRightsAlsoNeedTheRelationship() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let detail = try await harness.openDetail(of: "sample-1")
        let report = try await openReport(on: detail)

        report.pick(try reason("fraud", in: report))
        report.view.layoutIfNeeded()
        XCTAssertFalse(report.submitButton.isEnabled, "诈骗要截图")
        XCTAssertFalse(report.evidenceRow.isHidden)
        XCTAssertEqual(report.evidenceRow.arrangedSubviews.count, 1, "只有「添加」")
        report.store.addEvidence([FeedDraftImage(image: UIImage())])
        report.view.layoutIfNeeded()
        XCTAssertTrue(report.submitButton.isEnabled)
        XCTAssertEqual(report.evidenceRow.arrangedSubviews.count, 2, "一张截图 + 「添加」")

        report.store.backToReasons()
        report.pick(try reason("copyright", in: report))
        report.view.layoutIfNeeded()
        XCTAssertFalse(report.relationshipField.isHidden)
        XCTAssertFalse(report.submitButton.isEnabled, "还差关系")
        report.store.onRelationshipChanged("本人")
        report.view.layoutIfNeeded()
        XCTAssertEqual(report.relationshipField.text, "本人")
        XCTAssertTrue(report.submitButton.isEnabled)
        harness.window.isHidden = true
    }

    @MainActor
    func testEmergencyReasonsShowTheNoticeAndTheCounterGoesRedPastTheLimit() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let detail = try await harness.openDetail(of: "sample-1")
        let report = try await openReport(on: detail)
        report.pick(try reason("self_harm", in: report))
        report.view.layoutIfNeeded()
        XCTAssertTrue(report.presentation.showsEmergencyNotice)
        report.store.onDetailChanged(String(repeating: "字", count: 600))
        report.view.layoutIfNeeded()
        XCTAssertEqual(report.detailTextView.text.count, 500, "超出的截掉")
        XCTAssertEqual(report.detailCounterLabel.text, OWSFormat.formatInt(0))
        harness.window.isHidden = true
    }

    // MARK: - 提交

    /// 举报帖子：交给 source 的是帖子 id + 原因；成功后举报页关掉，详情页提示「已提交」，帖子还在。
    @MainActor
    func testSubmittingReportsThePostClosesThePageAndTheDetailToasts() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let detail = try await harness.openDetail(of: "sample-1")
        let report = try await openReport(on: detail)
        report.pick(try reason("spam", in: report))
        report.store.onDetailChanged("广告")
        report.submit()
        XCTAssertTrue(report.presentation.isSending || report.store.state.sending)
        await report.store.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(report.finishedOutcome, .sent)
        XCTAssertNil(detail.presentedReport)
        let sent = try XCTUnwrap(harness.source.reports.first)
        XCTAssertEqual(sent.targetId, "sample-1")
        XCTAssertEqual(sent.reason, "spam")
        XCTAssertEqual(sent.detail, "广告")
        await detail.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(detail.lastToastText, OWSLocalizedString("TELLOMI_FEED_REPORT_SENT", comment: ""))
        XCTAssertNil(detail.closeReason, "举报后帖子还在")
        harness.window.isHidden = true
    }

    /// 举报评论：目标是评论的 id；带截图的原因提交时先上传。
    @MainActor
    func testReportingACommentTargetsTheCommentAndUploadsScreenshots() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let detail = try await harness.openDetail(of: "sample-1")
        let comment = try XCTUnwrap(detail.detailStore.state.comments.first)
        let report = try await openReport(on: detail, comment: comment)
        report.pick(try reason("fraud", in: report))
        report.store.addEvidence([FeedDraftImage(image: UIImage())])
        report.submit()
        await report.store.waitForTasks()
        XCTAssertEqual(report.finishedOutcome, .sent)
        let sent = try XCTUnwrap(harness.source.reports.first)
        XCTAssertEqual(sent.targetId, comment.id)
        XCTAssertEqual(sent.evidenceKeys, ["sample-upload-1"])
        harness.window.isHidden = true
    }

    @MainActor
    func testFailureKeepsTheFormAndShowsAToastThenRetryWorks() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let detail = try await harness.openDetail(of: "sample-1")
        let report = try await openReport(on: detail)
        report.pick(try reason("spam", in: report))
        report.store.onDetailChanged("写好的说明")

        harness.source.simulation.failsReports = true
        report.submit()
        await report.store.waitForTasks()
        XCTAssertNil(report.finishedOutcome)
        XCTAssertEqual(report.lastToastText, OWSLocalizedString("TELLOMI_FEED_ACTION_FAILED", comment: ""))
        XCTAssertEqual(report.store.state.detail, "写好的说明", "说明还在")
        XCTAssertTrue(report.submitButton.isEnabled, "能再点")
        XCTAssertNil(report.store.state.error, "提示过就清掉")

        harness.source.simulation.failsReports = false
        harness.source.simulation.throttledRetryAfterSeconds = 15
        report.submit()
        await report.store.waitForTasks()
        XCTAssertNil(report.finishedOutcome)
        XCTAssertTrue(report.lastToastText?.contains("15") ?? false, "限速：说要等几秒")

        harness.source.simulation.throttledRetryAfterSeconds = nil
        report.submit()
        await report.store.waitForTasks()
        XCTAssertEqual(report.finishedOutcome, .sent)
        XCTAssertEqual(harness.source.reports.count, 1, "只收到一次")
        harness.window.isHidden = true
    }

    /// 引擎说这个区域的动态关了：举报页关掉，详情页跟着收起。
    @MainActor
    func testFeedHiddenClosesTheReportAndTheDetailPage() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let detail = try await harness.openDetail(of: "sample-1")
        let report = try await openReport(on: detail)
        report.pick(try reason("spam", in: report))
        harness.source.simulation.feedHidden = true
        report.submit()
        await report.store.waitForTasks()
        XCTAssertEqual(report.finishedOutcome, .feedHidden)
        XCTAssertNil(detail.presentedReport)
        await detail.detailStore.waitForTasks()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(detail.closeReason, .feedHidden)
        harness.window.isHidden = true
    }

    @MainActor
    func testCancelClosesWithoutReporting() async throws {
        let harness = await makeHarness()
        defer { harness.window.isHidden = true }
        let detail = try await harness.openDetail(of: "sample-1")
        let report = try await openReport(on: detail)
        // 取消按钮的动作和「关掉」一样：详情页清掉引用、不提示
        detail.presentedReportFinished(.cancelled)
        XCTAssertNil(detail.presentedReport)
        XCTAssertTrue(harness.source.reports.isEmpty)
        XCTAssertNil(detail.lastToastText)
        _ = report
        harness.window.isHidden = true
    }
}
