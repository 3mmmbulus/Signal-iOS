//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import XCTest
@testable import SignalServiceKit

/// ADR-0063 §5.1 第 4 条（tellomi/tellomi#1423）：接收端的判定——给 rust/links 的输入长什么样、缓存、失败时怎么办、日志不带 URL。
/// 用假的注册表，不依赖 libsignal 的原生库。与 Android `TellomiLinkRegistry.classify`、Desktop `classifyLinkPreview` 同一套约定。
final class TellomiLinkClassifierTest: XCTestCase {

    private final class FakeRegistry: TellomiLinkClassifying {
        var version: UInt64 = 1
        var classifyResult: Result<String, Error> = .success(#"{"level":"generic","domain":"bilibili.com"}"#)
        var openPlanResult: Result<String, Error> = .success(#"{"steps":[],"label":"x"}"#)
        var identifyResult: String?
        private(set) var classifyCalls = [(preview: String, body: String, message: String)]()
        private(set) var identifyCalls = [String]()

        func classify(preview: String, body: String, message: String) throws -> String {
            classifyCalls.append((preview, body, message))
            return try classifyResult.get()
        }

        func openPlan(_ url: String) throws -> String {
            try openPlanResult.get()
        }

        func identify(_ url: String, location: Bool) throws -> String? {
            identifyCalls.append(url)
            return identifyResult
        }
    }

    private struct Boom: Error {}

    /// 分类器的 `log` 是 `@Sendable`：收集日志行要加锁。
    private final class LogSink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = [String]()

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            storage.append(line)
        }

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private let url = "https://www.bilibili.com/video/BV1YDhJ6ZEL6"
    private var logged = [String]()

    private func makeClassifier(_ registry: FakeRegistry?) -> TellomiLinkClassifier {
        TellomiLinkClassifier(registry: registry, log: { _ in })
    }

    private func object(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testTheInputIsThePreviewsFieldsAndTheContext() throws {
        let registry = FakeRegistry()
        let classifier = makeClassifier(registry)
        let preview = TellomiLinkClassifier.PreviewInput(
            url: url,
            title: "Sender title",
            description: "Sender description",
            hasImage: true,
            date: Date(timeIntervalSince1970: 1_790_000_000.5),
            rich: Data([0x0a, 0xff, 0x00]),
        )

        let card = classifier.classify(preview, body: url, isStory: true, attachmentContentTypes: ["text/x-signal-plain"])

        XCTAssertEqual(card?.level, .generic)
        let call = try XCTUnwrap(registry.classifyCalls.first)
        XCTAssertEqual(call.body, url)
        let previewObject = try object(call.preview)
        XCTAssertEqual(previewObject["url"] as? String, url)
        XCTAssertEqual(previewObject["title"] as? String, "Sender title")
        XCTAssertEqual(previewObject["description"] as? String, "Sender description")
        XCTAssertEqual(previewObject["has_image"] as? Bool, true)
        XCTAssertEqual((previewObject["date"] as? NSNumber)?.uint64Value, 1_790_000_000_500)
        XCTAssertEqual(previewObject["rich"] as? String, "0aff00")
        let context = try object(call.message)
        XCTAssertEqual(context["is_story"] as? Bool, true)
        XCTAssertEqual(context["attachment_content_types"] as? [String], ["text/x-signal-plain"])
    }

    func testEmptyFieldsAreLeftOut() throws {
        let registry = FakeRegistry()
        _ = makeClassifier(registry).classify(
            TellomiLinkClassifier.PreviewInput(url: url, title: "", description: "", hasImage: false, date: Date(timeIntervalSince1970: 0), rich: nil),
            body: url,
            isStory: false,
            attachmentContentTypes: [],
        )
        let previewObject = try object(XCTUnwrap(registry.classifyCalls.first).preview)
        XCTAssertEqual(Set(previewObject.keys), ["url", "has_image"])
        XCTAssertEqual(previewObject["has_image"] as? Bool, false)
    }

    func testTheSameMessageIsDecidedOnceAndANewRegistryVersionDecidesAgain() {
        let registry = FakeRegistry()
        let classifier = makeClassifier(registry)
        let preview = TellomiLinkClassifier.PreviewInput(url: url, title: "T")

        _ = classifier.classify(preview, body: url, isStory: false, attachmentContentTypes: [])
        _ = classifier.classify(preview, body: url, isStory: false, attachmentContentTypes: [])
        XCTAssertEqual(registry.classifyCalls.count, 1)

        _ = classifier.classify(preview, body: url + " ", isStory: false, attachmentContentTypes: [])
        XCTAssertEqual(registry.classifyCalls.count, 2, "another body is another decision")

        registry.version = 2
        _ = classifier.classify(preview, body: url, isStory: false, attachmentContentTypes: [])
        XCTAssertEqual(registry.classifyCalls.count, 3, "a hot update applies to messages already stored")
    }

    func testNoRegistryDecidesNothing() {
        let classifier = makeClassifier(nil)
        XCTAssertFalse(classifier.isAvailable)
        XCTAssertNil(classifier.classify(.init(url: url), body: url, isStory: false, attachmentContentTypes: []))
        XCTAssertNil(classifier.lookalike(forUrl: url))
    }

    func testAFailureOrACardThisBuildDoesNotUnderstandDecidesNothing() {
        let registry = FakeRegistry()
        let classifier = makeClassifier(registry)

        registry.classifyResult = .failure(Boom())
        XCTAssertNil(classifier.classify(.init(url: url), body: url, isStory: false, attachmentContentTypes: []))

        registry.classifyResult = .success(#"{"level":"hologram"}"#)
        XCTAssertNil(classifier.classify(.init(url: url + "/2"), body: url, isStory: false, attachmentContentTypes: []))
    }

    func testTheLogNeverHasTheURL() {
        let registry = FakeRegistry()
        let sink = LogSink()
        let classifier = TellomiLinkClassifier(registry: registry, log: { sink.append($0) })

        registry.classifyResult = .success(#"{"level":"structured","provider":"bilibili","route":"video","kind":"video","reason":"structured"}"#)
        _ = classifier.classify(.init(url: url, title: "Secret title"), body: url, isStory: false, attachmentContentTypes: [])
        registry.classifyResult = .failure(Boom())
        _ = classifier.classify(.init(url: url + "#fragment"), body: url, isStory: false, attachmentContentTypes: [])
        registry.openPlanResult = .failure(Boom())
        _ = classifier.lookalike(forUrl: url + "#fragment")

        let lines = sink.lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("bilibili/video structured (structured)"))
        for line in lines {
            XCTAssertFalse(line.contains("bilibili.com"), line)
            XCTAssertFalse(line.contains("http"), line)
            XCTAssertFalse(line.contains("#"), line)
            XCTAssertFalse(line.contains("Secret"), line)
        }
    }

    func testTheLookalikeIsTheOpenPlansWarning() {
        let registry = FakeRegistry()
        let classifier = makeClassifier(registry)

        registry.openPlanResult = .success(#"{"steps":[],"label":"x","lookalike":"bilibili.com"}"#)
        XCTAssertEqual(classifier.lookalike(forUrl: "https://www.bi1ibili.com/v"), "bilibili.com")

        registry.openPlanResult = .success(#"{"steps":[],"label":"x"}"#)
        XCTAssertNil(classifier.lookalike(forUrl: url))

        registry.openPlanResult = .success("not json")
        XCTAssertNil(classifier.lookalike(forUrl: url))

        registry.openPlanResult = .failure(Boom())
        XCTAssertNil(classifier.lookalike(forUrl: url))
    }

    // MARK: - http:// 和没写协议的链接（owner 2026-10-17，ADR-0063 补充）

    private func upgraded(_ body: String, _ previewUrl: String = "https://b23.tv/abc", claimed: Bool = true) -> String {
        TellomiLinkClassifier.body(body, upgradingLinkTo: previewUrl, claims: { _ in claimed })
    }

    /// 正文里写成 http:// 或没写协议、注册表认领这条 https：判定用的正文里那一处换成 https 写法，rust/links 才找得到它。
    func testAnHttpOrSchemelessLinkTheRegistryClaimsIsGivenAsHttps() {
        XCTAssertEqual(upgraded("看 http://b23.tv/abc 很好"), "看 https://b23.tv/abc 很好")
        XCTAssertEqual(upgraded("看 HTTP://b23.tv/abc"), "看 https://b23.tv/abc")
        XCTAssertEqual(upgraded("看 b23.tv/abc 很好"), "看 https://b23.tv/abc 很好")
        XCTAssertEqual(upgraded("看这个b23.tv/abc很好"), "看这个https://b23.tv/abc很好", "前面紧贴中文不算链接的一段")
        XCTAssertEqual(upgraded("（b23.tv/abc）"), "（https://b23.tv/abc）")
        XCTAssertEqual(upgraded("b23.tv/abc", "https://b23.tv/abc/"), "https://b23.tv/abc", "同 rust/links：预览末尾的一个「/」正文里可以没有")
        XCTAssertEqual(upgraded("evil-b23.tv/abc 和 b23.tv/abc"), "evil-b23.tv/abc 和 https://b23.tv/abc", "跳过是别的链接一段的那一处")
        XCTAssertEqual(upgraded("b23.tv/abcdef 和 b23.tv/abc"), "https://b23.tv/abcdef 和 https://b23.tv/abc", "每一处都换，哪一处是链接结尾由 rust/links 判")
    }

    /// 不换的：注册表不认领；已经是 https；正文里那一处其实是另一条链接、邮箱的一段；预览本身不是 https。
    func testEverythingElseIsLeftAlone() {
        XCTAssertEqual(upgraded("看 b23.tv/abc", claimed: false), "看 b23.tv/abc")
        XCTAssertEqual(upgraded("看 https://b23.tv/abc"), "看 https://b23.tv/abc")
        XCTAssertEqual(upgraded("evil-b23.tv/abc"), "evil-b23.tv/abc")
        XCTAssertEqual(upgraded("xb23.tv/abc"), "xb23.tv/abc")
        XCTAssertEqual(upgraded("me@b23.tv/abc"), "me@b23.tv/abc")
        XCTAssertEqual(upgraded("ftp://b23.tv/abc"), "ftp://b23.tv/abc")
        XCTAssertEqual(upgraded("https://x.com/b23.tv/abc"), "https://x.com/b23.tv/abc")
        XCTAssertEqual(upgraded("没有链接"), "没有链接")
        XCTAssertEqual(upgraded("http://b23.tv/abc", "http://b23.tv/abc"), "http://b23.tv/abc")
    }

    /// 注册表只在真要换的时候问一次。
    func testTheRegistryIsAskedOnlyWhenThereIsSomethingToUpgrade() {
        var asked = [String]()
        let claims: (String) -> Bool = { asked.append($0); return true }
        _ = TellomiLinkClassifier.body("看 https://b23.tv/abc", upgradingLinkTo: "https://b23.tv/abc", claims: claims)
        _ = TellomiLinkClassifier.body("没有链接", upgradingLinkTo: "https://b23.tv/abc", claims: claims)
        XCTAssertEqual(asked, [])
        _ = TellomiLinkClassifier.body("b23.tv/abc http://b23.tv/abc", upgradingLinkTo: "https://b23.tv/abc", claims: claims)
        XCTAssertEqual(asked, ["https://b23.tv/abc"])
    }

    /// 判定（classify / receiveCheck）拿到的是换过的正文；认领看 `identify` 的 provider，第一方 Tellomi 不算。
    func testTheDecisionsSeeTheUpgradedBodyAndFirstPartyIsNotUpgraded() throws {
        let registry = FakeRegistry()
        registry.identifyResult = #"{"provider":"bilibili","short":true}"#
        let classifier = makeClassifier(registry)
        _ = classifier.classify(.init(url: "https://b23.tv/abc"), body: "看 b23.tv/abc", isStory: false, attachmentContentTypes: [])
        XCTAssertEqual(registry.classifyCalls.last?.body, "看 https://b23.tv/abc")
        XCTAssertTrue(classifier.claimsHttpsUpgrade(of: "https://b23.tv/abc"))

        registry.identifyResult = #"{"provider":"tellomi"}"#
        XCTAssertFalse(classifier.claimsHttpsUpgrade(of: "https://tell.cc/g/abc"))
        _ = classifier.classify(.init(url: "https://tell.cc/g/abc"), body: "看 tell.cc/g/abc", isStory: false, attachmentContentTypes: [])
        XCTAssertEqual(registry.classifyCalls.last?.body, "看 tell.cc/g/abc")

        registry.identifyResult = nil
        XCTAssertFalse(classifier.claimsHttpsUpgrade(of: "https://signal.org/x"))
        XCTAssertFalse(classifier.claimsHttpsUpgrade(of: "http://b23.tv/abc"), "只问 https")
        XCTAssertFalse(makeClassifier(nil).claimsHttpsUpgrade(of: "https://b23.tv/abc"), "没有注册表什么都不认领")
    }
}
