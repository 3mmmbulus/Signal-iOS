//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// M11 动态第三刀：发布页（`dynamic-feed.md` 第三节第 22、23、39 条；契约 7.2）。与 Android `FeedDraftTest` / `FeedComposeScreenTest` 同口径。
final class TellomiFeedComposeTests: XCTestCase {

    private let limits = FeedLimits()

    // MARK: - 草稿规则

    /// 动态 500 字、长文 1 万字，按码点数（一个汉字、一个 emoji 码点都算 1）。
    func testTextLimitsCountCodePoints() {
        var draft = FeedDraft()
        draft.text = String(repeating: "云", count: 500)
        XCTAssertEqual(draft.textLength, 500)
        XCTAssertNil(draft.problem(limits: limits, minorMode: false))
        draft.text += "😀"
        XCTAssertEqual(draft.textLength, 501)
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .tooLong)

        draft.kind = .article
        draft.title = "标题"
        XCTAssertNil(draft.problem(limits: limits, minorMode: false), "长文上限 1 万")
        draft.text = String(repeating: "字", count: 10_001)
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .tooLong)
    }

    /// 空的发不了；长文要标题；只有图的动态能发；最多 10 张。
    func testWhatCanBePublished() {
        var draft = FeedDraft()
        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .empty)
        draft.text = "   \n"
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .empty)

        draft.images = [FeedDraftImage(image: UIImage())]
        XCTAssertNil(draft.problem(limits: limits, minorMode: false))
        draft.images = (0..<11).map { _ in FeedDraftImage(image: UIImage()) }
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .tooManyImages)

        // 长文 P1 不带图：切过去图不算（切回来还在），要标题
        draft.kind = .article
        XCTAssertTrue(draft.attachedImages.isEmpty)
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .missingTitle)
        draft.title = "标题"
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .empty)
        draft.kind = .post
        XCTAssertEqual(draft.attachedImages.count, 11)
    }

    /// 五档可见范围；「部分可见」「不给谁看」现在不能选；未成年人只有「仅好友 / 仅自己」，默认仅好友。
    func testVisibility() {
        XCTAssertEqual(FeedVisibility.allCases.map(\.apiName), ["public", "friends", "include", "exclude", "only_me"])
        XCTAssertEqual(FeedVisibility.selectable(minorMode: false), [.public, .friends, .onlyMe])
        XCTAssertEqual(FeedVisibility.allowed(minorMode: true), [.friends, .onlyMe])
        XCTAssertEqual(FeedVisibility.defaultValue(minorMode: false), .public)
        XCTAssertEqual(FeedVisibility.defaultValue(minorMode: true), .friends)

        var draft = FeedDraft()
        draft.text = "hi"
        draft.visibility = .include
        XCTAssertEqual(draft.problem(limits: limits, minorMode: false), .missingAudience)
        draft.visibility = .public
        XCTAssertEqual(draft.problem(limits: limits, minorMode: true), .visibilityNotAllowed)
    }

    /// 请求体只放引擎认的字段（契约 7.2）：动态不带 title；长文的标题去首尾空白。
    func testRequestBody() throws {
        var draft = FeedDraft()
        draft.text = "  今天的云  "
        draft.title = "不该发"
        XCTAssertEqual(
            String(decoding: try FeedAPI.encoder.encode(draft.request), as: UTF8.self),
            #"{"comments_closed":false,"kind":"post","text":"今天的云","visibility":"public"}"#,
        )
        draft.kind = .article
        draft.title = " 标题 "
        draft.visibility = .onlyMe
        XCTAssertEqual(
            String(decoding: try FeedAPI.encoder.encode(draft.request), as: UTF8.self),
            #"{"comments_closed":false,"kind":"article","text":"今天的云","title":"标题","visibility":"only_me"}"#,
        )
    }

    // MARK: - 来源

    /// 样例：同一个 nonce 只发一次；发的出现在两栏最上面，自己的帖子没有「···」。
    func testSamplePublishIsIdempotentAndShowsOnTop() async throws {
        let sample = SampleFeedSource()
        var draft = FeedDraft()
        draft.text = "第一条"
        draft.images = [FeedDraftImage(image: UIImage.image(color: .red, size: CGSize(width: 40, height: 30)))]
        let first = try await sample.publish(draft: draft, clientNonce: "n1")
        let again = try await sample.publish(draft: draft, clientNonce: "n1")
        XCTAssertEqual(first, again)
        XCTAssertEqual(first.state, FeedCreatePostResponse.statePublished)

        for tab in FeedTab.allCases {
            let top = try await sample.timeline(tab: tab, cursor: nil).cards[0]
            XCTAssertEqual(top.id, first.id)
            XCTAssertEqual(top.text, "第一条")
            XCTAssertTrue(top.viewer.isAuthor)
            XCTAssertEqual(top.media.count, 1)
            XCTAssertNotNil(FeedLocalImages.shared.image(for: top.media[0].key), "本机样例能显示自己选的图")
        }
    }

    /// 内容引擎：带图的帖子在媒体上传接上之前不发；纯文字走 `POST /v1/feed/posts`，返回 `pending`。
    func testRemotePublish() async throws {
        let transport = RecordingTransport()
        let source = RemoteFeedSource(api: FeedAPI(baseURL: URL(string: "https://feed.example")!, transport: transport, tokens: StaticTokens()))
        var draft = FeedDraft()
        draft.text = "hi"
        draft.images = [FeedDraftImage(image: UIImage())]
        do {
            _ = try await source.publish(draft: draft, clientNonce: "n")
            XCTFail("should throw")
        } catch FeedPublishError.mediaUploadNotAvailable {}
        XCTAssertTrue(transport.sent.isEmpty)

        draft.images = []
        transport.next = (201, #"{"id":"p1","state":"pending","version":1}"#)
        let response = try await source.publish(draft: draft, clientNonce: "n")
        XCTAssertEqual(response, FeedCreatePostResponse(id: "p1", state: FeedCreatePostResponse.statePending))
        XCTAssertEqual(transport.sent.map { "\($0.httpMethod!) \($0.url!.path)" }, ["POST /v1/feed/posts"])

        do {
            _ = try await EmptyFeedSource.shared.publish(draft: draft, clientNonce: "n")
            XCTFail("should throw")
        } catch FeedPublishError.feedNotAvailable {}
    }

    // MARK: - 页面

    /// 顶部切换、计数、发布键可用性、可见范围菜单、发出去带回 state 并只发一次。
    @MainActor
    func testComposePage() async throws {
        let sample = SampleFeedSource()
        var publishedStates = [String]()
        let compose = FeedComposeViewController(source: sample) { publishedStates.append($0) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = OWSNavigationController(rootViewController: compose)
        window.isHidden = false
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        XCTAssertTrue(compose.navigationItem.titleView is FeedKindSwitch)
        let publish = try XCTUnwrap(compose.navigationItem.rightBarButtonItem)
        XCTAssertFalse(publish.isEnabled, "空的不能发")

        compose.setText(String(repeating: "云", count: 449))
        XCTAssertTrue(publish.isEnabled)
        let counter = compose.counterLabel
        XCTAssertTrue(counter.isHidden, "剩 51 个字时还不显示计数")
        compose.setText(String(repeating: "云", count: 501))
        XCTAssertFalse(counter.isHidden)
        XCTAssertEqual(counter.text, "-1")
        XCTAssertFalse(publish.isEnabled)

        compose.setKind(.article)
        XCTAssertFalse(publish.isEnabled, "长文要标题")
        compose.setTitle("标题")
        XCTAssertTrue(publish.isEnabled)
        compose.setKind(.post)

        compose.setVisibility(.include)
        XCTAssertEqual(compose.draft.visibility, .public, "部分可见还不能选")
        compose.setVisibility(.onlyMe)
        XCTAssertEqual(compose.draft.visibility, .onlyMe)

        compose.setText("发一条")
        compose.publish()
        compose.publish()
        for _ in 0..<100 where publishedStates.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(publishedStates, [FeedCreatePostResponse.statePublished])
        let top = try await sample.timeline(tab: .recommend, cursor: nil).cards
        XCTAssertEqual(top.filter { $0.viewer.isAuthor }.count, 1, "连点两次只发一条")
    }

    /// 动态页右下角有发布按钮，列表底部留出它的位置。
    @MainActor
    func testFeedHasComposeButton() {
        let feed = FeedViewController(source: SampleFeedSource())
        feed.loadViewIfNeeded()
        XCTAssertEqual(feed.composeButton.superview, feed.view)
        XCTAssertNotNil(feed.composeButton.accessibilityLabel)
        XCTAssertGreaterThanOrEqual(feed.pages[0].tableView.contentInset.bottom, FeedViewController.composeButtonSize)
    }

    /// 给人看的截图（TELLOMI_SHOTS=1 时才跑）：发布页（动态 + 两张图 + 计数）、长文、带发布按钮的动态页。
    @MainActor
    func testShotsOfComposePage() async throws {
        guard ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1" else {
            throw XCTSkip("只在 TELLOMI_SHOTS=1 时截图")
        }
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(UIScreen.main.bounds.size.width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func shoot(_ viewController: UIViewController, _ name: String, prepare: () -> Void = {}) async throws {
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = OWSNavigationController(rootViewController: viewController)
            window.isHidden = false
            prepare()
            window.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 600_000_000)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
            window.isHidden = true
            window.rootViewController = nil
        }

        let post = FeedComposeViewController(source: SampleFeedSource()) { _ in }
        try await shoot(post, "compose-post") {
            post.loadViewIfNeeded()
            post.setText(String(repeating: "今天的云很低，像是伸手就能摸到。", count: 30))
            post.addImages([
                UIImage.image(color: .systemTeal, size: CGSize(width: 300, height: 400)),
                UIImage.image(color: .systemOrange, size: CGSize(width: 400, height: 300)),
            ])
        }

        let article = FeedComposeViewController(source: SampleFeedSource()) { _ in }
        try await shoot(article, "compose-article") {
            article.loadViewIfNeeded()
            article.setKind(.article)
            article.setTitle("周末去山里住了一晚")
        }

        let feed = FeedViewController(source: SampleFeedSource())
        try await shoot(feed, "feed-with-compose-button") {
            feed.loadViewIfNeeded()
        }
    }
}

private final class StaticTokens: FeedTokenSource {
    func token(forceRefresh: Bool) async throws -> String { "t" }
}

private final class RecordingTransport: FeedHTTPTransport {
    var next: (Int, String) = (500, "")
    private(set) var sent = [URLRequest]()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: next.0, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (Data(next.1.utf8), response)
    }
}
