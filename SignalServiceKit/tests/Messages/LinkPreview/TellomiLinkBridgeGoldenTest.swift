//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest
@testable import SignalServiceKit

/// ADR-0063 §5.1 / §8.1（tellomi/tellomi#1423）：iOS 上真的 libsignal 原生库，对同一份注册表 `links-2026101901.json`，
/// 必须和 Android、Desktop 给出**一模一样**的答案。共享的黄金数据是 rust/links 的 `bridge_golden.rs` 生成的
/// `bridge-golden.json`（``TellomiLinkBridgeGolden``）：classify 53 条 + receive_check、identify、layout、open_plan、tint、send。
/// 发送端的 5 条经过 ``TellomiLinkSendJob/run`` 重放：客户端问的请求和最后的预览都必须和黄金一致。
final class TellomiLinkBridgeGoldenTest: XCTestCase {

    private var golden: [String: Any]!
    private var registry: LinkRegistry!

    override func setUpWithError() throws {
        try super.setUpWithError()
        golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(TellomiLinkBridgeGolden.json.utf8)) as? [String: Any])
        // 随包的那份注册表（和 App 里加载的是同一个文件），文件名黄金数据里写着
        let name = try XCTUnwrap((golden["registry"] as? String).map { ($0 as NSString).lastPathComponent as NSString })
        let bundle = Bundle(for: SSKEnvironment.self)
        let url = try XCTUnwrap(bundle.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension), "随包注册表 \(name)")
        registry = try LinkRegistry.load(Data(contentsOf: url))
        XCTAssertEqual(registry.version, (golden["registry_version"] as? NSNumber)?.uint64Value)
    }

    private func cases(_ key: String) throws -> [[String: Any]] {
        try XCTUnwrap(golden[key] as? [[String: Any]], key)
    }

    // MARK: - classify / receive_check

    func testEveryClassifyCaseGivesTheGoldenCard() throws {
        let cases = try cases("classify")
        XCTAssertEqual(cases.count, 53)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let preview = try XCTUnwrap(c["preview"] as? String, name)
            let body = try XCTUnwrap(c["body"] as? String, name)
            let message = try XCTUnwrap(c["message"] as? String, name)
            XCTAssertEqual(try registry.classify(preview: preview, body: body, message: message), c["card"] as? String, name)
            XCTAssertEqual(try registry.receiveCheck(preview: preview, body: body, message: message), c["receive_check"] as? String, "\(name)（receive_check）")
        }
    }

    // MARK: - identify / open_plan

    func testEveryIdentifyCaseGivesTheGoldenAnswer() throws {
        for c in try cases("identify") {
            let url = try XCTUnwrap(c["url"] as? String)
            let location = (c["location"] as? Bool) ?? false
            XCTAssertEqual(try registry.identify(url, location: location), c["result"] as? String, url)
        }
    }

    func testEveryOpenPlanCaseGivesTheGoldenPlan() throws {
        let cases = try cases("open_plan")
        XCTAssertEqual(cases.count, 7)
        for c in cases {
            let url = try XCTUnwrap(c["url"] as? String)
            XCTAssertEqual(try registry.openPlan(url), c["plan"] as? String, url)
        }
    }

    // MARK: - layout / tint

    func testEveryLayoutCaseGivesTheGoldenShape() throws {
        for c in try cases("layout") {
            let width = try XCTUnwrap((c["width"] as? NSNumber)?.uint32Value)
            let height = try XCTUnwrap((c["height"] as? NSNumber)?.uint32Value)
            let kind = try XCTUnwrap(c["kind"] as? String)
            let level = try XCTUnwrap(c["level"] as? String)
            XCTAssertEqual(try Links.layout(imageWidth: width, imageHeight: height, kind: kind, level: level), c["layout"] as? String, "\(width)x\(height) \(kind) \(level)")
        }
    }

    func testTheTintCaseGivesTheGoldenColours() throws {
        for c in try cases("tint") {
            let width = try XCTUnwrap((c["width"] as? NSNumber)?.uint32Value)
            let height = try XCTUnwrap((c["height"] as? NSNumber)?.uint32Value)
            let layout = try XCTUnwrap(c["layout"] as? String)
            let hex = try XCTUnwrap(c["rgba_hex"] as? String)
            let pixels = try XCTUnwrap(Data.data(fromHex: hex))
            XCTAssertEqual(try Links.tint(layout: layout, width: width, height: height, rgba: pixels), c["tint"] as? String)
        }
    }

    // MARK: - send

    /// 黄金里一条发送场景的脚本化回答。
    private final class ScriptedDeps: TellomiSendDeps {
        let script: [String: Any]
        var asked = [TellomiSendRequest]()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var isCancelled = false

        init(script: [String: Any]) {
            self.script = script
        }

        func fetch(_ request: TellomiSendRequest) async -> TellomiSendExchange {
            asked.append(request)
            let url: String
            switch request {
            case .fetch(_, let requestUrl, _, _, _, _, _), .expand(_, let requestUrl, _):
                url = requestUrl
            default:
                return .failure
            }
            if (script["network_error"] as? [String])?.contains(url) == true {
                return .networkError
            }
            guard let response = (script["responses"] as? [String: [String: Any]])?[url] else {
                return .failure
            }
            return .response(
                status: (response["status"] as? NSNumber)?.uint32Value ?? 0,
                finalUrl: response["final_url"] as? String ?? url,
                contentType: response["content_type"] as? String ?? "",
                location: response["location"] as? String,
                body: Data((response["body"] as? String ?? "").utf8),
            )
        }

        func image(_ request: TellomiSendRequest) async -> Bool {
            asked.append(request)
            return (script["image_ok"] as? Bool) ?? false
        }

        func firstParty(kind: String) async -> TellomiSendFirstPartyResult {
            asked.append(.firstParty(id: 0, kind: kind))
            guard
                let json = script["first_party"] as? String,
                let result = try? JSONDecoder().decode(TellomiSendFirstPartyResult.self, from: Data(json.utf8))
            else {
                return TellomiSendFirstPartyResult(ok: false)
            }
            return result
        }

        func now() -> Date { clock }
    }

    func testEverySendCaseAsksForTheGoldenRequestsAndEndsWithTheGoldenPreview() async throws {
        let cases = try cases("send")
        XCTAssertEqual(cases.count, 5)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let url = try XCTUnwrap(c["url"] as? String)
            let context = try XCTUnwrap(c["context"] as? String)
            let job = TellomiNativeSendJob(job: try registry.begin(url, context: context))
            let deps = ScriptedDeps(script: (c["script"] as? [String: Any]) ?? [:])
            var requests = [String]()

            let outcome = try await TellomiLinkSendJob.run(job: job, deps: deps) { requests.append($0) }

            XCTAssertEqual(requests, c["requests"] as? [String], name)
            XCTAssertEqual(outcome, TellomiLinkSendJob.parseOutcome(try XCTUnwrap(c["outcome"] as? String)), name)
            XCTAssertNotNil(outcome?.preview, "\(name)：应该有预览")
        }
    }

    func testTheNativeJobsFinishIsByteForByteTheGoldenOutcome() async throws {
        let c = try XCTUnwrap(try cases("send").first { ($0["name"] as? String) == "App Store public API + image" })
        let native = TellomiNativeSendJob(job: try registry.begin(try XCTUnwrap(c["url"] as? String), context: try XCTUnwrap(c["context"] as? String)))

        final class Recording: TellomiSendJob {
            let inner: any TellomiSendJob
            var finished: String?
            init(_ inner: any TellomiSendJob) { self.inner = inner }
            func nextRequest() throws -> String? { try inner.nextRequest() }
            func onResponse(id: UInt32, status: UInt32, finalUrl: String, contentType: String, location: String?, body: Data) throws {
                try inner.onResponse(id: id, status: status, finalUrl: finalUrl, contentType: contentType, location: location, body: body)
            }

            func onNetworkError(id: UInt32) throws { try inner.onNetworkError(id: id) }
            func onFailure(id: UInt32) throws { try inner.onFailure(id: id) }
            func onFirstParty(id: UInt32, result: String) throws { try inner.onFirstParty(id: id, result: result) }
            func onImage(id: UInt32, ok: Bool) throws { try inner.onImage(id: id, ok: ok) }
            func finish() throws -> String {
                let text = try inner.finish()
                finished = text
                return text
            }
        }

        let recording = Recording(native)
        _ = try await TellomiLinkSendJob.run(job: recording, deps: ScriptedDeps(script: (c["script"] as? [String: Any]) ?? [:]))
        XCTAssertEqual(recording.finished, c["outcome"] as? String)
    }
}
