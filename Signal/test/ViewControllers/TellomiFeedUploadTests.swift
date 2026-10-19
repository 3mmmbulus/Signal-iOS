//
// DRAFT — NOT COMPILED ON A MAC. Intended location: Signal/test/ViewControllers/TellomiFeedUploadTests.swift (new file)
// tus upload (mirror of Android `FeedImageUploaderTest`) and `RemoteFeedSource.publish` with images, against a scripted fake transport.
//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest

@testable import Signal

/// 按顺序回预先写好的响应；记下每个请求。`.drop` = 没拿到答复（断线）。
private final class ScriptedTransport: FeedHTTPTransport, @unchecked Sendable {
    enum Reply {
        case status(Int, headers: [String: String] = [:], body: String = "")
        case drop
    }

    private let lock = NSLock()
    private var script = [Reply]()
    private var _requests = [URLRequest]()

    func enqueue(_ replies: Reply...) {
        lock.lock(); script += replies; lock.unlock()
    }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    private func next(_ request: URLRequest) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        return script.isEmpty ? nil : script.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        switch next(request) {
        case .status(let code, let headers, let body)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        case .drop?:
            throw URLError(.networkConnectionLost)
        case nil:
            XCTFail("unexpected extra request \(request.httpMethod ?? "?") \(request.url?.path ?? "")")
            throw URLError(.badServerResponse)
        }
    }
}

private struct FixedTokens: FeedTokenSource {
    func token(forceRefresh: Bool) async throws -> String { "t" }
}

private func makeAPI(_ transport: ScriptedTransport) -> FeedAPI {
    return FeedAPI(baseURL: URL(string: "https://feed.example.test")!, transport: transport, tokens: FixedTokens())
}

private func created(id: String = "u1", key: String = "m/k1") -> ScriptedTransport.Reply {
    return .status(201, headers: ["Media-Key": key], body: #"{"id":"\#(id)","key":"\#(key)"}"#)
}

private func accepted(_ offset: Int) -> ScriptedTransport.Reply {
    return .status(204, headers: ["Upload-Offset": String(offset)])
}

final class TellomiFeedUploadTests: XCTestCase {
    func testUploadsInChunksAndReturnsTheMediaKey() async throws {
        let transport = ScriptedTransport()
        transport.enqueue(created(), accepted(4), accepted(8), accepted(10))

        let key = try await FeedImageUploader(api: makeAPI(transport), chunkSize: 4).upload(Data((0..<10).map { UInt8($0) }))

        XCTAssertEqual(key, "m/k1")
        let requests = transport.requests
        XCTAssertEqual(requests.count, 4)
        let start = requests[0]
        XCTAssertEqual(start.httpMethod, "POST")
        XCTAssertEqual(start.url?.path, "/v1/feed/media/uploads")
        XCTAssertEqual(start.value(forHTTPHeaderField: "Tus-Resumable"), "1.0.0")
        XCTAssertEqual(start.value(forHTTPHeaderField: "Upload-Length"), "10")
        XCTAssertEqual(start.value(forHTTPHeaderField: "Authorization"), "Bearer t")
        let chunks = Array(requests.dropFirst())
        XCTAssertEqual(chunks.map(\.httpMethod), ["PATCH", "PATCH", "PATCH"])
        XCTAssertEqual(chunks.map { $0.url?.path }, Array(repeating: "/v1/feed/media/uploads/u1", count: 3))
        XCTAssertEqual(chunks.map { $0.value(forHTTPHeaderField: "Upload-Offset") }, ["0", "4", "8"])
        XCTAssertEqual(chunks.map { $0.httpBody?.count }, [4, 4, 2])
        XCTAssertEqual(chunks[0].value(forHTTPHeaderField: "Content-Type"), "application/offset+octet-stream")
        XCTAssertEqual(chunks[1].httpBody, Data([4, 5, 6, 7]))
    }

    func testOffsetMismatchAsksTheServerAndResumesFromThere() async throws {
        let transport = ScriptedTransport()
        transport.enqueue(created(), .status(409, body: #"{"error":"offset_mismatch"}"#), .status(200, headers: ["Upload-Offset": "3"]), accepted(6))

        _ = try await FeedImageUploader(api: makeAPI(transport), chunkSize: 4).upload(Data(count: 6))

        let requests = transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[2].httpMethod, "HEAD")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Upload-Offset"), "3")
        XCTAssertEqual(requests[3].httpBody?.count, 3)
    }

    /// 没拿到答复（断线）也能续：和 Android 的 `IOException` 一样。
    func testConnectionDropResumes() async throws {
        let transport = ScriptedTransport()
        transport.enqueue(created(), accepted(4), .drop, .status(200, headers: ["Upload-Offset": "4"]), accepted(6))

        _ = try await FeedImageUploader(api: makeAPI(transport), chunkSize: 4).upload(Data(count: 6))

        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "PATCH", "PATCH", "HEAD", "PATCH"])
    }

    func testARejectedFileIsNotRetried() async {
        let transport = ScriptedTransport()
        transport.enqueue(created(), .status(415, body: #"{"error":"unsupported_media"}"#))
        do {
            _ = try await FeedImageUploader(api: makeAPI(transport), chunkSize: 4).upload(Data(count: 3))
            XCTFail("expected an error")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.code, "unsupported_media")
            XCTAssertEqual(error.status, 415)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(transport.requests.count, 2)
    }

    /// 引擎存储出错：PATCH 回 500 `internal`、偏移不动；HEAD 问到 4，同一块（偏移 4）再发一次就成了（引擎 #53 的集成测试同样的场景）。
    func testAStorageErrorOnAChunkResumesFromTheServersOffset() async throws {
        for status in [500, 502, 503, 504] {
            let transport = ScriptedTransport()
            transport.enqueue(created(), accepted(4), .status(status, body: #"{"error":"internal"}"#), .status(200, headers: ["Upload-Offset": "4"]), accepted(6))

            let key = try await FeedImageUploader(api: makeAPI(transport), chunkSize: 4).upload(Data((0..<6).map { UInt8($0) }))

            XCTAssertEqual(key, "m/k1", "status \(status)")
            XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "PATCH", "PATCH", "HEAD", "PATCH"], "status \(status)")
            let resent = transport.requests[4]
            XCTAssertEqual(resent.value(forHTTPHeaderField: "Upload-Offset"), "4")
            XCTAssertEqual(resent.httpBody, Data([4, 5]))
        }
    }

    /// 桶一直坏：只续 `maxResumes` 次，然后把 500 抛给调用方（不无限重试）。
    func testAPersistentStorageErrorEndsAfterTheMaximumNumberOfResumes() async {
        let transport = ScriptedTransport()
        let boom = ScriptedTransport.Reply.status(500, body: #"{"error":"internal"}"#)
        transport.enqueue(created(), boom, .status(200, headers: ["Upload-Offset": "0"]), boom, .status(200, headers: ["Upload-Offset": "0"]), boom)
        do {
            _ = try await FeedImageUploader(api: makeAPI(transport), chunkSize: 4, maxResumes: 2).upload(Data(count: 6))
            XCTFail("expected an error")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 500)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "PATCH", "HEAD", "PATCH", "HEAD", "PATCH"])
    }

    /// 别的 4xx（上传不存在、偏移头坏了）不是重试能解决的。
    func testOtherClientErrorsOnAChunkAreNotRetried() async {
        for (status, code) in [(404, "not_found"), (400, "upload_offset"), (415, "content_type")] {
            let transport = ScriptedTransport()
            transport.enqueue(created(), .status(status, body: #"{"error":"\#(code)"}"#))
            do {
                _ = try await FeedImageUploader(api: makeAPI(transport), chunkSize: 4).upload(Data(count: 3))
                XCTFail("expected an error")
            } catch let error as FeedAPIError {
                XCTAssertEqual(error.status, status)
            } catch {
                XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(transport.requests.count, 2, "status \(status)")
        }
    }

    func testTooLargeAndTooManyUploadsAreReportedFromTheStart() async {
        for (status, code) in [(413, "too_large"), (429, "too_many_uploads")] {
            let transport = ScriptedTransport()
            transport.enqueue(.status(status, headers: status == 429 ? ["Retry-After": "30"] : [:], body: #"{"error":"\#(code)"}"#))
            do {
                _ = try await FeedImageUploader(api: makeAPI(transport)).upload(Data(count: 3))
                XCTFail("expected an error")
            } catch let error as FeedAPIError {
                XCTAssertEqual(error.code, code)
                XCTAssertEqual(error.retryAfterSeconds, status == 429 ? 30 : nil)
            } catch {
                XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    /// 最多续 `maxResumes` 次，再失败就抛。
    func testGivesUpAfterTheMaximumNumberOfResumes() async {
        let transport = ScriptedTransport()
        transport.enqueue(created(), .drop, .status(200, headers: ["Upload-Offset": "0"]), .drop, .status(200, headers: ["Upload-Offset": "0"]), .drop)
        do {
            _ = try await FeedImageUploader(api: makeAPI(transport), chunkSize: 4, maxResumes: 2).upload(Data(count: 6))
            XCTFail("expected an error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "PATCH", "HEAD", "PATCH", "HEAD", "PATCH"])
    }

    /// 服务端回「收到了」却不往前走：不无限循环（Android 没有这个保护）。
    func testAStuckServerOffsetEndsInsteadOfLoopingForever() async {
        let transport = ScriptedTransport()
        transport.enqueue(created(), accepted(0), .status(200, headers: ["Upload-Offset": "0"]), accepted(0), .status(200, headers: ["Upload-Offset": "0"]), accepted(0))
        do {
            _ = try await FeedImageUploader(api: makeAPI(transport), chunkSize: 4, maxResumes: 2).upload(Data(count: 6))
            XCTFail("expected an error")
        } catch {
            // 抛的是内部的 "stuck" 错误；只要结束就行
        }
        XCTAssertEqual(transport.requests.count, 6)
    }

    /// 没带 `Upload-Offset` 头：按 offset + 块长算（Android 同）。
    func testMissingOffsetHeaderMeansTheChunkWasAccepted() async throws {
        let transport = ScriptedTransport()
        transport.enqueue(created(), .status(204), .status(204))
        _ = try await FeedImageUploader(api: makeAPI(transport), chunkSize: 4).upload(Data(count: 6))
        XCTAssertEqual(transport.requests.count, 3)
    }

    func testImageSizingKeepsSmallImagesAndShrinksTheLongEdge() {
        XCTAssertEqual(FeedImageSizing.targetSize(for: CGSize(width: 1000, height: 800)), CGSize(width: 1000, height: 800))
        XCTAssertEqual(FeedImageSizing.targetSize(for: CGSize(width: 2560, height: 1000)), CGSize(width: 2560, height: 1000))
        XCTAssertEqual(FeedImageSizing.targetSize(for: CGSize(width: 5120, height: 2560)), CGSize(width: 2560, height: 1280))
        XCTAssertEqual(FeedImageSizing.targetSize(for: CGSize(width: 3000, height: 6000)), CGSize(width: 1280, height: 2560))
        XCTAssertEqual(FeedImageSizing.targetSize(for: CGSize(width: 100_000, height: 1)), CGSize(width: 2560, height: 1), "never below one pixel")
    }
}

final class TellomiFeedPublishWithImagesTests: XCTestCase {
    private struct FakeEncoder: FeedImageEncoding {
        func jpegData(for image: UIImage) async throws -> Data { Data(repeating: 7, count: 5) }
    }

    private func draft(images: Int) -> FeedDraft {
        var draft = FeedDraft()
        draft.text = "hello"
        draft.images = (0..<images).map { FeedDraftImage(id: "img\($0)", image: UIImage()) }
        return draft
    }

    private func source(_ transport: ScriptedTransport, encoder: FeedImageEncoding? = FakeEncoder()) -> RemoteFeedSource {
        return RemoteFeedSource(api: makeAPI(transport), imageEncoder: encoder)
    }

    private func bodyJSON(_ request: URLRequest) throws -> [String: Any] {
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testTwoImagesAreUploadedInOrderAndTheirKeysGoIntoTheCreateRequest() async throws {
        let transport = ScriptedTransport()
        transport.enqueue(
            created(id: "u1", key: "m/a"), accepted(5),
            created(id: "u2", key: "m/b"), accepted(5),
            .status(201, body: #"{"id":"p1","state":"published","version":1}"#),
        )
        let response = try await source(transport).publish(draft: draft(images: 2), clientNonce: "nonce-1")

        XCTAssertEqual(response.id, "p1")
        XCTAssertEqual(transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "POST /v1/feed/media/uploads", "PATCH /v1/feed/media/uploads/u1",
            "POST /v1/feed/media/uploads", "PATCH /v1/feed/media/uploads/u2",
            "POST /v1/feed/posts",
        ])
        let body = try bodyJSON(try XCTUnwrap(transport.requests.last))
        XCTAssertEqual(body["media_keys"] as? [String], ["m/a", "m/b"])
        XCTAssertEqual(body["client_nonce"] as? String, "nonce-1")
    }

    /// 发帖失败后重试：图片不再上传一遍，client_nonce 不变；发成功后记忆清掉。
    func testRetryAfterAFailedCreateDoesNotUploadAgain() async throws {
        let transport = ScriptedTransport()
        transport.enqueue(
            created(key: "m/a"), accepted(5), .status(503, body: #"{"error":"internal"}"#),
            .status(200, body: #"{"id":"p1","state":"pending","version":1}"#),
            created(id: "u9", key: "m/z"), accepted(5), .status(201, body: #"{"id":"p2","state":"pending","version":1}"#),
        )
        let source = source(transport)
        let draft = draft(images: 1)

        do {
            _ = try await source.publish(draft: draft, clientNonce: "n1")
            XCTFail("expected the 503")
        } catch let error as FeedAPIError {
            XCTAssertEqual(error.status, 503)
        }
        let retry = try await source.publish(draft: draft, clientNonce: "n1")
        XCTAssertEqual(retry.id, "p1")
        XCTAssertEqual(transport.requests.count, 4, "2 for the upload + failed create + retried create, no second upload")
        XCTAssertEqual(try bodyJSON(transport.requests[3])["media_keys"] as? [String], ["m/a"])
        XCTAssertEqual(try bodyJSON(transport.requests[3])["client_nonce"] as? String, "n1")

        // 成功后记忆已清：同一个 nonce 再发（不会发生，但证明没有残留）要重新上传
        _ = try await source.publish(draft: draft, clientNonce: "n1")
        XCTAssertEqual(transport.requests.count, 7)
    }

    func testTextOnlyPostDoesNotTouchTheUploadEndpointOrSendMediaKeys() async throws {
        let transport = ScriptedTransport()
        transport.enqueue(.status(201, body: #"{"id":"p1","state":"published","version":1}"#))
        _ = try await source(transport).publish(draft: draft(images: 0), clientNonce: "n")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertNil(try bodyJSON(transport.requests[0])["media_keys"])
    }

    func testWithoutAnEncoderImagesStillCannotBeSent() async {
        let transport = ScriptedTransport()
        do {
            _ = try await source(transport, encoder: nil).publish(draft: draft(images: 1), clientNonce: "n")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? FeedPublishError, .mediaUploadNotAvailable)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// 长文不带图（`attachedImages` 为空），即使选过图。
    func testArticleDropsImages() async throws {
        let transport = ScriptedTransport()
        transport.enqueue(.status(201, body: #"{"id":"p1","state":"published","version":1}"#))
        var article = draft(images: 2)
        article.kind = .article
        article.title = "T"
        _ = try await source(transport).publish(draft: article, clientNonce: "n")
        XCTAssertEqual(transport.requests.count, 1)
    }
}
