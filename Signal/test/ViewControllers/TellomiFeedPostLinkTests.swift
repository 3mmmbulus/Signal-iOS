//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedPostLinkTests.swift (new file)
// I-16: post link building / parsing and the landing state. Mirrors Android TellomiLinksTest (post link cases) and FeedPostLinkViewModelTest.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

private struct Boom: Error {}

private let id = "0b8f7c52-93aa-4d6e-8c1b-7f2e6a4d9c10"

final class TellomiFeedPostLinkParseTests: XCTestCase {
    func testBuildsLowercaseLinks() {
        XCTAssertEqual(FeedPostLink.postLink(contentId: id.uppercased()), "https://tell.cc/m#\(id)")
        XCTAssertEqual(FeedPostLink.parsePostId(FeedPostLink.postLink(contentId: id)), id, "自己发出去的能自己认回来")
    }

    func testAcceptsBothShapesATrailingSlashAndAnyCase() {
        XCTAssertEqual(FeedPostLink.parsePostId("https://tell.cc/m#\(id)"), id)
        XCTAssertEqual(FeedPostLink.parsePostId("tellomi://tell.cc/m#\(id)"), id)
        XCTAssertEqual(FeedPostLink.parsePostId("https://tell.cc/m/#\(id)"), id)
        XCTAssertEqual(FeedPostLink.parsePostId("HTTPS://TELL.CC/M#\(id.uppercased())"), id, "大小写都认，结果小写")
        XCTAssertEqual(FeedPostLink.parsePostId("  https://tell.cc/m#\(id)\n"), id, "首尾空白去掉")
    }

    func testRejectsEverythingThatIsNotExactlyAPostLink() {
        let bad: [String?] = [
            nil, "", "tell.cc/m#\(id)", "http://tell.cc/m#\(id)", "sgnl://tell.cc/m#\(id)",
            "https://tell.cc/m", "https://tell.cc/m#", "https://tell.cc/m#not-a-uuid",
            "https://tell.cc/m#\(id)x", "https://tell.cc/m#x\(id)", "https://tell.cc/m#\(id.dropLast())",
            "https://tell.cc/m#\(id)&utm=1", "https://tell.cc/m?x=1#\(id)", "https://tell.cc/m//#\(id)",
            "https://tell.cc/u#\(id)", "https://tell.cc/e#\(id)", "https://tell.cc/mm#\(id)", "https://tell.cc/m/x#\(id)",
            "https://tell.cc.evil.com/m#\(id)", "https://evil.com/https://tell.cc/m#\(id)", "https://sub.tell.cc/m#\(id)",
            "https://tell.cc/m#\(id)\nhttps://tell.cc/m#\(id)", "https://tell.cc/m#\(id)\n#x",
            "https://tell.cc/m#0b8f7c52-93aa-4d6e-8c1b-7f2e6a4d9c1g",
        ]
        for link in bad {
            XCTAssertNil(FeedPostLink.parsePostId(link), "不该认: \(link ?? "nil")")
        }
    }
}

private final class LinkSource: FeedSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = [String]()
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }
    var value: FeedCard?
    var error: Error?
    var firstCallGate: Gate?
    private var first = true
    func config() async throws -> FeedConfig { FeedConfig() }
    func timeline(tab: FeedTab, cursor: String?) async throws -> FeedTimelinePage { FeedTimelinePage() }
    func setLiked(contentId: String, liked: Bool) async throws {}
    func notInterested(contentId: String) async throws {}
    func undoNotInterested(contentId: String) async throws {}
    func publish(draft: FeedDraft, clientNonce: String) async throws -> FeedCreatePostResponse { throw Boom() }
    func reportEvents(_ events: [FeedEventPayload]) async throws {}
    func card(contentId: String) async throws -> FeedCard? {
        let (gate, snapshot) = lock.locked {
            _calls.append(contentId)
            let gate = first ? firstCallGate : nil
            first = false
            return (gate, (value, error))
        }
        // 第一次调用在门口等；放行后返回它开始时看到的结果（不理会取消）
        if let gate {
            await gate.wait()
            return snapshot.0
        }
        if let error { throw error }
        return value
    }
}

@MainActor
final class TellomiFeedPostLinkStoreTests: XCTestCase {
    private func card(kind: String = "post") -> FeedCard {
        FeedCard(id: id, kind: kind, author: FeedAuthor(profileId: "p", displayName: "Ann"), text: "hi")
    }

    private func loaded(_ link: String?, enabled: Bool = true, _ source: LinkSource) async -> FeedPostLinkStore {
        let store = FeedPostLinkStore(link: link, feedEnabled: enabled, source: { source })
        store.load()
        await store.waitForTasks()
        return store
    }

    func testAReadableCardOpensTheDetail() async {
        let source = LinkSource()
        source.value = card()
        let store = FeedPostLinkStore(link: "https://tell.cc/m#\(id.uppercased())", feedEnabled: true, source: { source })
        XCTAssertEqual(store.state, .loading)
        store.load()
        XCTAssertEqual(store.state, .loading)
        await store.waitForTasks()
        XCTAssertEqual(store.state, .ready(card()))
        XCTAssertEqual(source.calls, [id], "用小写 id 去问")
    }

    func testNotALinkOrFeedOffIsGoneWithoutAskingTheEngine() async {
        let source = LinkSource()
        source.value = card()
        let notLink = await loaded("https://tell.cc/m#nope", source)
        XCTAssertEqual(notLink.state, .gone)
        let off = await loaded("https://tell.cc/m#\(id)", enabled: false, source)
        XCTAssertEqual(off.state, .gone, "没开动态也说「不可见」，不泄露有这条")
        let nilLink = await loaded(nil, source)
        XCTAssertEqual(nilLink.state, .gone)
        XCTAssertEqual(source.calls, [], "不去问引擎")
    }

    func testMissingOrUnrenderableCardsAreGoneAndErrorsAreRetryable() async {
        let source = LinkSource()
        let link = "tellomi://tell.cc/m#\(id)"
        let missing = await loaded(link, source)
        XCTAssertEqual(missing.state, .gone, "已删 / 没权限看 / 被屏蔽：引擎不说是哪种")
        source.value = card(kind: "story")
        let story = await loaded(link, source)
        XCTAssertEqual(story.state, .gone, "客户端不渲染的类型也是不可见")

        source.value = card()
        source.error = Boom()
        let store = await loaded(link, source)
        XCTAssertEqual(store.state, .failed)
        source.error = nil
        store.load()
        XCTAssertEqual(store.state, .loading)
        await store.waitForTasks()
        XCTAssertEqual(store.state, .ready(card()))
    }

    func testAnOlderLookupThatFinishesLateDoesNotOverwriteTheRetry() async {
        let source = LinkSource()
        source.value = card()
        let gate = Gate()
        source.firstCallGate = gate
        let store = FeedPostLinkStore(link: "https://tell.cc/m#\(id)", feedEnabled: true, source: { source })
        store.load()   // 第一次：卡在门口，之后会返回一张卡
        for _ in 0..<2000 where await gate.arrivals == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
        let arrived = await gate.arrivals
        XCTAssertEqual(arrived, 1)
        source.error = Boom()
        store.load()   // 第二次：马上失败
        await Task.yield()
        await gate.open()
        await store.waitForTasks()
        XCTAssertEqual(store.state, .failed, "旧的结果不盖掉新的")
    }
}

private actor Gate {
    private var isOpen = false
    private var waiters = [CheckedContinuation<Void, Never>]()
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let all = waiters
        waiters = []
        all.forEach { $0.resume() }
    }
}

/// `NSLock.lock()` 在 async 函数里不让直接调（Swift 6）；临界区都不跨 `await`，放进同步闭包里。
private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
