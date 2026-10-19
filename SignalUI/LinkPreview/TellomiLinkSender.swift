//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

public import Foundation
public import SignalServiceKit

/// 客户端自己现成的查法（发送时联网没关系，渲染时才不行）：tell.cc 对象的信息，和 Signal 那样校验 / 重新编码预览图。
public protocol TellomiSendLookups: AnyObject {
    /// Signal 自己对 tell.cc 对象（`tellomi.group`、`tellomi.sticker`、`tellomi.call`）的查询。
    func firstParty(kind: String, url: URL) async -> TellomiLinkSender.FirstParty
    /// 校验并重新编码下载到的预览图（Signal 的规则：≤ 2400 px、jpeg / png）；不能用返回 nil。
    func thumbnail(from data: Data) async -> TellomiLinkSender.Thumbnail?
}

/// 输入框里的链接预览（有随包注册表时，ADR-0063 §4.2 / §4.4 / §5.2）：rust/links 决定抓什么、拼预览（快照 + `Preview.rich`），
/// `TellomiLinkFetcher` 做请求，tell.cc 的对象（群、贴纸包、通话）用 Signal 自己的查询。与 Android `TellomiLinkSender.kt`、Desktop `getTellomiPreview` 同一个流程。
///
/// 日志只记提供方、路由、级别、失败类别，从不记 URL（§6.5）。
public final class TellomiLinkSender: @unchecked Sendable {

    public struct Thumbnail: Equatable, Sendable {
        public var imageData: Data
        public var mimeType: String

        public init(imageData: Data, mimeType: String) {
            self.imageData = imageData
            self.mimeType = mimeType
        }
    }

    public enum FirstParty {
        /// Signal 的查询给出的预览：标题和图取它的。`count`：群有几位成员 / 贴纸包有几个贴纸（卡片副行用，§3.9）。
        case found(OWSLinkPreviewDraft, count: Int?)
        /// 这个群邀请链接肯定没激活。
        case inactive
        case notFound
    }

    public enum Result {
        case found(OWSLinkPreviewDraft)
        case notAvailable
        case groupLinkInactive
    }

    private let fetcher: TellomiLinkFetcher
    private let classifier: TellomiLinkClassifier
    private let expandShortLinks: @Sendable () -> Bool
    private let locale: @Sendable () -> Locale
    private let lookups: any TellomiSendLookups
    private let serverClient: (any TellomiServerLinkPreviewClient)?
    private let serverFetchEnabled: @Sendable () -> Bool
    private let serverGate: TellomiServerLinkPreviewGate

    /// `serverClient` / `serverFetchEnabled`：ADR-0063 §6.5 的服务端代抓（白名单那几家），默认不用。
    public init(
        fetcher: TellomiLinkFetcher = .shared,
        classifier: TellomiLinkClassifier = TellomiLinkRegistry.classifier,
        expandShortLinks: @escaping @Sendable () -> Bool,
        locale: @escaping @Sendable () -> Locale = { .current },
        lookups: any TellomiSendLookups,
        serverClient: (any TellomiServerLinkPreviewClient)? = nil,
        serverFetchEnabled: @escaping @Sendable () -> Bool = { false },
        serverGate: TellomiServerLinkPreviewGate = .shared,
    ) {
        self.fetcher = fetcher
        self.classifier = classifier
        self.expandShortLinks = expandShortLinks
        self.locale = locale
        self.lookups = lookups
        self.serverClient = serverClient
        self.serverFetchEnabled = serverFetchEnabled
        self.serverGate = serverGate
    }

    /// 这条链接这次要不要问服务端（§6.5.6）：有客户端、开关开着、白名单主机、最近没被告知别问。
    func usesServerFetch(for url: URL) -> Bool {
        guard serverClient != nil, serverGate.isOpen else { return false }
        return TellomiServerLinkPreview.isEligible(url, enabled: serverFetchEnabled())
    }

    /// 没有注册表时不能用（调用方照 Signal 原样）。
    public var isAvailable: Bool { classifier.isAvailable }

    /// 这条链接的预览。`nil` 表示没有注册表 / 作业开不了（调用方照 Signal 原样），`.notAvailable` 表示 rust/links 判定这条链接没有预览。
    public func preview(for url: URL) async throws -> Result? {
        let viaServer = usesServerFetch(for: url)
        let context = TellomiLinkSendJob.contextJson(
            unreachableHosts: fetcher.reachability.unreachableHosts(),
            // 走服务端时客户端不碰这个站：短链也由服务端展开（白名单几家的短链都跳回自己家）
            expandShortLinks: viaServer ? false : expandShortLinks(),
            locale: locale(),
        )
        guard let job = classifier.beginSendJob(url: url.absoluteString, context: context) else {
            return nil
        }
        return try await preview(job: job, url: url, viaServer: viaServer)
    }

    /// 作业已经开好（测试里换成假的）。`viaServer`：这条链接要问服务端（§6.5.6），本机作业只用来拿品牌壳的 `rich`。
    func preview(job: any TellomiSendJob, url: URL, viaServer: Bool = false) async throws -> Result {
        let (local, level) = try await localPreview(job: job, url: url)
        guard viaServer, let serverClient, TellomiServerLinkPreview.mayReplace(level: level) else {
            return local
        }
        if case .groupLinkInactive = local {
            return local
        }
        let answer = await serverClient.fetch(url: url)
        serverGate.record(answer)
        guard case .card(let card) = answer else {
            // 服务端没给卡片（没开、没部署、忙、站点挡了）：照本机的结果（品牌壳），不报错（§5.1 铁律 1、2）
            let providerId = TellomiServerLinkPreview.providerId(for: url) ?? "-"
            Logger.info("Link server-fetch \(providerId) \(Self.category(answer))")
            return local
        }
        // 服务端的缩略图也照 Signal 的规则再校验、重编码一次（和本机抓的图同一道关）
        var thumbnail: Thumbnail?
        if let imageData = card.imageData {
            thumbnail = await lookups.thumbnail(from: imageData)
        }
        let localDraft: OWSLinkPreviewDraft?
        if case .found(let draft) = local { localDraft = draft } else { localDraft = nil }
        Logger.info("Link server-fetch \(card.provider) card image=\(thumbnail != nil)")
        return .found(OWSLinkPreviewDraft(
            url: url,
            title: card.title,
            imageData: thumbnail?.imageData,
            imageMimeType: thumbnail?.mimeType,
            previewDescription: nil,
            date: nil,
            isForwarded: false,
            // 品牌壳的 `rich` 原样带上：还没升级的接收端照旧显示品牌壳，不会更差（§6.5.6）
            rich: localDraft?.rich,
        ))
    }

    static func category(_ answer: TellomiServerLinkPreview.Answer) -> String {
        switch answer {
        case .card: return "card"
        case .noCard: return "no-card"
        case .notDeployed: return "not-deployed"
        case .throttled: return "throttled"
        case .failed: return "failed"
        }
    }

    private func localPreview(job: any TellomiSendJob, url: URL) async throws -> (Result, String?) {
        let deps = Deps(fetcher: fetcher, budget: fetcher.makeBudget(), lookups: lookups, url: url)
        guard let outcome = try await TellomiLinkSendJob.run(job: job, deps: deps) else {
            return (.notAvailable, nil)
        }
        Logger.info("Link \(outcome.provider ?? "-")/\(outcome.route ?? "-") \(outcome.level) [\(outcome.failures.joined(separator: ","))]")

        if outcome.groupLinkInvalid {
            return (.groupLinkInactive, outcome.level)
        }
        guard let preview = outcome.preview else {
            return (.notAvailable, outcome.level)
        }

        // 群头像、贴纸封面、通话头像来自客户端自己；其余的图是 rust/links 点名的那张、客户端校验过的。
        let thumbnail: Thumbnail?
        if let firstPartyThumbnail = deps.firstPartyThumbnail {
            thumbnail = firstPartyThumbnail
        } else if preview.imageUrl != nil {
            thumbnail = deps.thumbnail
        } else {
            thumbnail = nil
        }
        let title = preview.title.flatMap { $0.isEmpty ? nil : $0 }
        let description = preview.description.flatMap { $0.isEmpty ? nil : $0 }
        return (.found(OWSLinkPreviewDraft(
            url: url,
            title: title,
            imageData: thumbnail?.imageData,
            imageMimeType: thumbnail?.mimeType,
            previewDescription: description,
            date: preview.date.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0) / 1000) : nil },
            isForwarded: false,
            rich: preview.richHex.flatMap { Data.data(fromHex: $0) },
        )), outcome.level)
    }

    // MARK: - 请求怎么做

    /// 一次抓取报告给 rust/links 的结果。
    static func exchange(for error: TellomiLinkFetchError, requestUrl: String) -> TellomiSendExchange {
        switch error {
        case .network:
            // 网络层失败（DNS、连接、TLS）：rust/links 会把这个 host 记成不可达
            return .networkError
        case .httpStatus(let status):
            // rust/links 自己看状态码（页面不存在、短链没有跳转）
            return .response(status: UInt32(clamping: status), finalUrl: requestUrl, contentType: "", location: nil, body: Data())
        case .missingLocation:
            // 短链没有跳转（200 的脚本跳转页之类）
            return .response(status: 200, finalUrl: requestUrl, contentType: "", location: nil, body: Data())
        default:
            return .failure
        }
    }

    private final class Deps: TellomiSendDeps, @unchecked Sendable {
        private let fetcher: TellomiLinkFetcher
        private let budget: TellomiLinkFetchBudget
        private let lookups: any TellomiSendLookups
        private let url: URL

        private let lock = NSLock()
        private var _thumbnail: Thumbnail?
        private var _firstPartyThumbnail: Thumbnail?

        var thumbnail: Thumbnail? { lock.withLock { _thumbnail } }
        var firstPartyThumbnail: Thumbnail? { lock.withLock { _firstPartyThumbnail } }

        init(fetcher: TellomiLinkFetcher, budget: TellomiLinkFetchBudget, lookups: any TellomiSendLookups, url: URL) {
            self.fetcher = fetcher
            self.budget = budget
            self.lookups = lookups
            self.url = url
        }

        var isCancelled: Bool { Task.isCancelled }

        func now() -> Date { Date() }

        func fetch(_ request: TellomiSendRequest) async -> TellomiSendExchange {
            switch request {
            case .expand(_, let requestUrl, _):
                guard let target = URL(string: requestUrl) else { return .failure }
                do {
                    let location = try await fetcher.expandShortLink(target, budget: budget)
                    return .response(status: 302, finalUrl: requestUrl, contentType: "", location: location.absoluteString, body: Data())
                } catch {
                    return TellomiLinkSender.exchange(for: error, requestUrl: requestUrl)
                }
            case .fetch(_, let requestUrl, _, let contentTypes, _, _, _):
                guard let target = URL(string: requestUrl) else { return .failure }
                let step: TellomiLinkFetchStep = contentTypes.contains { $0 == "text/html" || $0 == "application/xhtml+xml" } ? .html : .json
                do {
                    let response = try await fetcher.fetch(target, step: step, budget: budget)
                    return .response(
                        status: 200,
                        finalUrl: response.finalUrl.absoluteString,
                        contentType: response.mimeType,
                        location: nil,
                        body: response.body,
                    )
                } catch {
                    return TellomiLinkSender.exchange(for: error, requestUrl: requestUrl)
                }
            case .firstParty, .image:
                return .failure
            }
        }

        func image(_ request: TellomiSendRequest) async -> Bool {
            guard case .image(_, let requestUrl, _, _) = request, let target = URL(string: requestUrl) else {
                return false
            }
            do {
                let response = try await fetcher.fetch(target, step: .image, budget: budget)
                guard !response.body.isEmpty, let thumbnail = await lookups.thumbnail(from: response.body) else {
                    return false
                }
                lock.withLock { _thumbnail = thumbnail }
                return true
            } catch {
                Logger.warn("Link preview image fetch failed: \(error.logCategory)")
                return false
            }
        }

        func firstParty(kind: String) async -> TellomiSendFirstPartyResult {
            switch await lookups.firstParty(kind: kind, url: url) {
            case .found(let draft, let count):
                if let imageData = draft.imageData, let mimeType = draft.imageMimeType {
                    lock.withLock { _firstPartyThumbnail = Thumbnail(imageData: imageData, mimeType: mimeType) }
                }
                // 只有大于 0 的数量才交给对方的卡片（card-visual §3.9）
                let positive = count.flatMap { $0 > 0 ? $0 : nil }
                return TellomiSendFirstPartyResult(
                    ok: true,
                    title: draft.title.flatMap { $0.isEmpty ? nil : $0 },
                    memberCount: kind == "tellomi.group" ? positive : nil,
                    stickerCount: kind == "tellomi.sticker" ? positive : nil,
                )
            case .inactive:
                return TellomiSendFirstPartyResult(ok: false, invalid: true)
            case .notFound:
                return TellomiSendFirstPartyResult(ok: false)
            }
        }
    }
}
