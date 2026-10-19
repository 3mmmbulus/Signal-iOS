//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import SignalServiceKit

public protocol LinkPreviewFetcher {
    func fetchLinkPreview(for url: URL) async throws -> OWSLinkPreviewDraft
}

#if TESTABLE_BUILD

class MockLinkPreviewFetcher: LinkPreviewFetcher {
    var fetchedURLs: [URL] { _fetchedURLs.get() }
    let _fetchedURLs = AtomicValue<[URL]>([], lock: .init())

    var fetchLinkPreviewBlock: ((URL) async throws -> OWSLinkPreviewDraft)?

    func fetchLinkPreview(for url: URL) async throws -> OWSLinkPreviewDraft {
        _fetchedURLs.update { $0.append(url) }
        return try await fetchLinkPreviewBlock!(url)
    }
}

#endif

public class LinkPreviewFetcherImpl: LinkPreviewFetcher {
    private let authCredentialManager: any AuthCredentialManager
    fileprivate let db: any DB
    private let groupsV2: any GroupsV2
    private let linkPreviewSettingStore: LinkPreviewSettingStore
    private let tsAccountManager: any TSAccountManager
    // Tellomi（ADR-0063 §4.4，tellomi/tellomi#1423）：第三方抓取一律经这个抓取器
    private let linkFetcher: TellomiLinkFetcher
    /// Tellomi（ADR-0063 §4.2）：有随包注册表时，预览由 rust/links 的作业驱动（`nil` = 不用，照 Signal 原样）。
    private let tellomiSenderFactory: ((LinkPreviewFetcherImpl) -> TellomiLinkSender)?
    private lazy var tellomiSender: TellomiLinkSender? = tellomiSenderFactory?(self)

    public init(
        authCredentialManager: any AuthCredentialManager,
        db: any DB,
        groupsV2: any GroupsV2,
        linkPreviewSettingStore: LinkPreviewSettingStore,
        tsAccountManager: any TSAccountManager,
        linkFetcher: TellomiLinkFetcher = .shared,
        usesTellomiSendJob: Bool = false,
    ) {
        self.authCredentialManager = authCredentialManager
        self.db = db
        self.groupsV2 = groupsV2
        self.linkPreviewSettingStore = linkPreviewSettingStore
        self.tsAccountManager = tsAccountManager
        self.linkFetcher = linkFetcher
        self.tellomiSenderFactory = usesTellomiSendJob ? { fetcher in
            TellomiLinkSender(
                fetcher: linkFetcher,
                expandShortLinks: { [db = fetcher.db] in db.read { TellomiLinkPreviewLocalSettings.isShortLinkExpansionEnabled(tx: $0) } },
                lookups: WeakLookups(fetcher),
                // ADR-0063 §6.5：白名单那几家由服务端代抓；远程配置 global.linkPreview.serverFetch 默认关
                serverClient: SignalServerLinkPreviewClient(),
                serverFetchEnabled: { RemoteConfig.current.isTellomiServerLinkPreviewEnabled },
            )
        } : nil
    }

    /// 发送端作业没给出预览时输入框看到的错误：群邀请链接确定失效单独一个（会提示），其余都是「没有预览」（静默）。
    static func previewError(for result: TellomiLinkSender.Result) -> LinkPreviewError {
        switch result {
        case .groupLinkInactive:
            return .groupLinkInactive
        case .found, .notAvailable:
            return .noPreview
        }
    }

    public func fetchLinkPreview(for url: URL) async throws -> OWSLinkPreviewDraft {
        let areLinkPreviewsEnabled: Bool = self.db.read(block: linkPreviewSettingStore.areLinkPreviewsEnabled(tx:))
        guard areLinkPreviewsEnabled else {
            throw LinkPreviewError.featureDisabled
        }

        // Tellomi（ADR-0063 §4.2）：有注册表时由 rust/links 决定抓什么、拼预览（含 `Preview.rich`）；没有就照下面 Signal 的做法
        if let sender = tellomiSender, sender.isAvailable, let result = try await sender.preview(for: url) {
            switch result {
            case .found(let draft):
                return draft
            case .notAvailable, .groupLinkInactive:
                throw Self.previewError(for: result)
            }
        }

        let linkPreviewDraft: OWSLinkPreviewDraft?
        if StickerPackInfo.isStickerPackShare(url) {
            linkPreviewDraft = try await self.linkPreviewDraft(forStickerShare: url)
        } else if let url = PossibleGroupInviteLinkUrl.parseFrom(url) {
            linkPreviewDraft = try await self.linkPreviewDraft(forGroupInviteLink: url)
        } else if let callLink = CallLink(url: url) {
            let linkName = try await self.fetchName(forCallLink: callLink)
            linkPreviewDraft = OWSLinkPreviewDraft(url: url, title: linkName, isForwarded: false)
        } else if let firstPartyShape = TellomiLinks.firstPartyShape(of: url) {
            linkPreviewDraft = try await self.linkPreviewDraft(forTellCCUrl: url, shape: firstPartyShape)
        } else {
            linkPreviewDraft = try await self.fetchLinkPreview(forGenericUrl: url)
        }
        guard let linkPreviewDraft else {
            throw LinkPreviewError.noPreview
        }
        return linkPreviewDraft
    }

    private func fetchLinkPreview(forGenericUrl url: URL) async throws -> OWSLinkPreviewDraft? {
        let normalizedTitle: String?
        let normalizedDescription: String?
        let previewThumbnail: PreviewThumbnail?
        let dateForLinkPreview: Date?

        let budget = linkFetcher.makeBudget()
        switch try await self.fetchStringOrImageResource(from: url, budget: budget) {
        case .string(let respondingUrl, let rawHtml):
            let content = HTMLMetadata.construct(parsing: rawHtml)
            let rawTitle = content.ogTitle ?? content.titleTag
            normalizedTitle = rawTitle.map { LinkPreviewHelper.normalizeString($0, maxLines: 2) }?.nilIfEmpty
            var rawDescription = content.ogDescription ?? content.description
            if rawDescription == rawTitle {
                rawDescription = nil
            }
            normalizedDescription = rawDescription.map { LinkPreviewHelper.normalizeString($0, maxLines: 3) }
            dateForLinkPreview = content.dateForLinkPreview

            if
                let imageUrlString = content.ogImageUrlString ?? content.faviconUrlString,
                let imageUrl = URL(string: imageUrlString, relativeTo: respondingUrl),
                LinkPreviewHelper.isPermittedLinkPreviewUrl(imageUrl),
                let imageData = try? await self.fetchImageResource(from: imageUrl, budget: budget)
            {
                previewThumbnail = await Self.previewThumbnail(srcImageData: imageData)
            } else {
                previewThumbnail = nil
            }

        case .image(let url, let contents):
            previewThumbnail = await Self.previewThumbnail(srcImageData: contents)
            normalizedDescription = nil
            dateForLinkPreview = nil
            normalizedTitle = if previewThumbnail != nil {
                // The best we can do for a title is the filename in the URL itself,
                // but that's no worse than the body of the message.
                url.lastPathComponent.filterStringForDisplay().nilIfEmpty
            } else {
                nil
            }
        }

        guard normalizedTitle != nil || previewThumbnail != nil else {
            return nil
        }

        return OWSLinkPreviewDraft(
            url: url,
            title: normalizedTitle,
            imageData: previewThumbnail?.imageData,
            imageMimeType: previewThumbnail?.mimetype,
            previewDescription: normalizedDescription,
            date: dateForLinkPreview,
            isForwarded: false,
        )
    }

    enum StringOrImageResource {
        case string(url: URL, contents: String)
        case image(url: URL, contents: Data)
    }

    func fetchStringOrImageResource(from url: URL) async throws -> StringOrImageResource {
        return try await fetchStringOrImageResource(from: url, budget: linkFetcher.makeBudget())
    }

    // Tellomi（ADR-0063 §4.4，tellomi/tellomi#1423）：原来经 OWSURLSession（会带上用户的 Accept-Language、不限跳数、
    // 不校验私网地址、不看 Content-Type），改成 §4.4 的抓取器。日志只记失败类别，不记 URL（§6.5）。
    private func fetchStringOrImageResource(from url: URL, budget: TellomiLinkFetchBudget) async throws -> StringOrImageResource {
        let response: TellomiLinkFetcher.Response
        do {
            response = try await linkFetcher.fetch(url, step: .page, budget: budget)
        } catch {
            Logger.warn("Link preview page fetch failed: \(error.logCategory)")
            throw LinkPreviewError.fetchFailure
        }
        switch response.kind {
        case .image:
            guard !response.body.isEmpty else {
                throw LinkPreviewError.invalidPreview
            }
            return .image(url: response.finalUrl, contents: response.body)
        case .html:
            guard let string = response.bodyString, !string.isEmpty else {
                Logger.warn("Link preview page could not be decoded")
                throw LinkPreviewError.invalidPreview
            }
            return .string(url: response.finalUrl, contents: string)
        case .json:
            throw LinkPreviewError.invalidPreview
        }
    }

    private func fetchImageResource(from url: URL, budget: TellomiLinkFetchBudget) async throws -> Data {
        let response: TellomiLinkFetcher.Response
        do {
            response = try await linkFetcher.fetch(url, step: .image, budget: budget)
        } catch {
            Logger.warn("Link preview image fetch failed: \(error.logCategory)")
            throw LinkPreviewError.fetchFailure
        }
        guard !response.body.isEmpty else {
            throw LinkPreviewError.invalidPreview
        }
        return response.body
    }

    /// 短链展开（§4.4：只对注册表声明的 `short_domains`，只读 `Location`）。「展开短链接」关着就不发请求、返回 nil。
    /// 由 `rust/links` 的 Planner 决定什么时候调；crate 就绪前没有调用方。
    func expandShortLinkIfEnabled(_ url: URL, budget: TellomiLinkFetchBudget) async -> URL? {
        let isEnabled = db.read { TellomiLinkPreviewLocalSettings.isShortLinkExpansionEnabled(tx: $0) }
        guard isEnabled else {
            return nil
        }
        do {
            return try await linkFetcher.expandShortLink(url, budget: budget)
        } catch {
            Logger.info("Short link expansion failed: \(error.logCategory)")
            return nil
        }
    }

    // MARK: - tell.cc（ADR-0063 §4.8）

    /// tell.cc 不放网页：认得出的对象走 Signal 现有的取数，认不出的（以及用户卡、预留路径）**不抓取、不出卡片**。
    /// 以前会按 generic 去抓落地页，把 `/用户名` 送进 CDN 日志（§6.5）；用户卡在接收端按 URL 本地画，随 §8.1 第 4 / 6 行做。
    private func linkPreviewDraft(forTellCCUrl url: URL, shape: TellomiLinks.FirstPartyShape) async throws -> OWSLinkPreviewDraft? {
        switch shape {
        case .stickerPack:
            // 上游的 StickerPackInfo 只认 signal.art：换算后解析，草稿里仍放正文里那条 tell.cc 链接
            let legacyUrl = TellomiLinks.legacyEquivalent(of: url)
            guard StickerPackInfo.isStickerPackShare(legacyUrl) else {
                throw LinkPreviewError.noPreview
            }
            return try await self.linkPreviewDraft(forStickerShare: legacyUrl, draftUrl: url)
        case .user, .userEncryptedLink, .userPhoneNumber, .group, .call, .reservedPath, .notAnObject:
            // 群邀请、通话在上面已经按 Signal 现有的取数处理；走到这里的都不抓
            throw LinkPreviewError.noPreview
        }
    }

    // MARK: - Preview Thumbnails

    struct PreviewThumbnail {
        let imageData: Data
        let mimetype: String
    }

    static func previewThumbnail(srcImageData: Data?) async -> PreviewThumbnail? {
        guard let srcImageData else {
            return nil
        }
        let imageSource = DataImageSource(srcImageData)
        let imageMetadata = imageSource.imageMetadata()
        guard let imageMetadata else {
            return nil
        }
        let imageFormat = imageMetadata.imageFormat
        let imageSize = imageMetadata.pixelSize

        let maxImageSize: CGFloat = 2400
        let isOriginalValid: Bool = (
            imageSize.width <= maxImageSize
                && imageSize.height <= maxImageSize
                && !imageMetadata.isAnimated
                && (imageMetadata.imageFormat == .jpeg || imageMetadata.imageFormat == .png),
        )

        if isOriginalValid {
            // If we don't need to resize or convert the file format,
            // return the original data.
            return PreviewThumbnail(imageData: srcImageData, mimetype: imageFormat.mimeType.rawValue)
        }

        let cgImageSource = CGImageSourceCreateWithData(
            srcImageData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary,
        )
        guard let cgImageSource else {
            Logger.warn("couldn't parse image")
            return nil
        }
        let dstImage = NormalizedImage.loadImage(imageSource: cgImageSource, maxPixelSize: maxImageSize)
        guard let dstImage else {
            Logger.warn("couldn't load/resize image")
            return nil
        }

        if imageMetadata.hasAlpha {
            guard let dstData = UIImage(cgImage: dstImage).pngData() else {
                owsFailDebug("Could not write resized image to PNG.")
                return nil
            }
            return PreviewThumbnail(imageData: dstData, mimetype: MimeType.imagePng.rawValue)
        } else {
            guard let dstData = UIImage(cgImage: dstImage).jpegDataSafe(compressionQuality: 0.8) else {
                owsFailDebug("Could not write resized image to JPEG.")
                return nil
            }
            return PreviewThumbnail(imageData: dstData, mimetype: MimeType.imageJpeg.rawValue)
        }
    }

    // MARK: - Stickers

    private func linkPreviewDraft(forStickerShare url: URL, draftUrl: URL? = nil) async throws -> OWSLinkPreviewDraft? {
        return try await linkPreviewDraftAndCount(forStickerShare: url, draftUrl: draftUrl)?.draft
    }

    /// 草稿加上包里有几个贴纸（发给对方的卡片副行用，card-visual §3.9）。
    private func linkPreviewDraftAndCount(forStickerShare url: URL, draftUrl: URL? = nil) async throws -> (draft: OWSLinkPreviewDraft, count: Int)? {
        guard let stickerPackInfo = StickerPackInfo.parseStickerPackShare(url) else {
            Logger.error("Could not parse url.")
            throw LinkPreviewError.invalidPreview
        }
        // tryToDownloadStickerPack will use locally saved data if possible...
        let stickerPack = try await StickerManager.tryToDownloadStickerPack(stickerPackInfo: stickerPackInfo).awaitable()
        let title = stickerPack.title?.filterForDisplay.nilIfEmpty
        let coverUrl = try await StickerManager.tryToDownloadSticker(stickerInfo: stickerPack.coverInfo).awaitable()
        let coverData = try Data(contentsOf: coverUrl, options: [.mappedIfSafe])
        let previewThumbnail = await Self.previewThumbnail(srcImageData: coverData)

        guard title != nil || previewThumbnail != nil else {
            return nil
        }

        let draft = OWSLinkPreviewDraft(
            url: draftUrl ?? url,
            title: title,
            imageData: previewThumbnail?.imageData,
            imageMimeType: previewThumbnail?.mimetype,
            isForwarded: false,
        )
        return (draft, stickerPack.items.count)
    }

    // MARK: - Group Invite Links

    private func linkPreviewDraft(forGroupInviteLink url: PossibleGroupInviteLinkUrl) async throws -> OWSLinkPreviewDraft? {
        return try await linkPreviewDraftAndCount(forGroupInviteLink: url)?.draft
    }

    /// 草稿加上群里有几位成员（发给对方的卡片副行用，card-visual §3.9）。
    private func linkPreviewDraftAndCount(forGroupInviteLink url: PossibleGroupInviteLinkUrl) async throws -> (draft: OWSLinkPreviewDraft, count: Int)? {
        let groupInviteLink: GroupInviteLink
        do {
            groupInviteLink = try GroupInviteLink.parseFrom(url)
        } catch {
            // 只记错误的类型：链接的 # 片段是群的主密钥（ADR-0063 §6.5）。
            Logger.warn("Couldn't parse the group invite link: \(type(of: error))")
            throw LinkPreviewError.invalidPreview
        }
        let groupV2ContextInfo = GroupV2ContextInfo.deriveFrom(masterKey: groupInviteLink.masterKey)
        let groupInviteLinkPreview = try await self.groupsV2.fetchGroupInviteLinkPreview(
            inviteLinkPassword: groupInviteLink.inviteLinkPassword,
            groupSecretParams: groupV2ContextInfo.groupSecretParams,
        )
        let previewThumbnail: PreviewThumbnail? = await {
            guard let avatarUrlPath = groupInviteLinkPreview.avatarUrlPath else {
                return nil
            }
            let avatarData: Data
            do {
                avatarData = try await self.groupsV2.fetchGroupInviteLinkAvatar(
                    avatarUrlPath: avatarUrlPath,
                    groupSecretParams: groupV2ContextInfo.groupSecretParams,
                )
            } catch {
                owsFailDebugUnlessNetworkFailure(error)
                return nil
            }
            return await Self.previewThumbnail(srcImageData: avatarData)
        }()

        let title = groupInviteLinkPreview.title.nilIfEmpty
        guard title != nil || previewThumbnail != nil else {
            return nil
        }

        let draft = OWSLinkPreviewDraft(
            url: url.rawValue,
            title: title,
            imageData: previewThumbnail?.imageData,
            imageMimeType: previewThumbnail?.mimetype,
            isForwarded: false,
        )
        return (draft, Int(groupInviteLinkPreview.memberCount))
    }

    // MARK: - Call Links

    private func fetchName(forCallLink callLink: CallLink) async throws -> String? {
        let registeredState = try tsAccountManager.registeredStateWithMaybeSneakyTransaction()
        let localIdentifiers = registeredState.localIdentifiers
        let authCredential = try await authCredentialManager.fetchCallLinkAuthCredential(localIdentifiers: localIdentifiers)
        let callLinkState = try await CallLinkFetcherImpl().readCallLink(callLink.rootKey, authCredential: authCredential)
        return callLinkState.name
    }
}

// MARK: - Tellomi 发送端用的查询

/// fetcher 持有 sender，sender 不该再强引用回 fetcher（否则是个引用环）。
private final class WeakLookups: TellomiSendLookups, @unchecked Sendable {
    private weak var target: LinkPreviewFetcherImpl?

    init(_ target: LinkPreviewFetcherImpl) {
        self.target = target
    }

    func firstParty(kind: String, url: URL) async -> TellomiLinkSender.FirstParty {
        return await target?.firstParty(kind: kind, url: url) ?? .notFound
    }

    func thumbnail(from data: Data) async -> TellomiLinkSender.Thumbnail? {
        return await target?.thumbnail(from: data)
    }
}

extension LinkPreviewFetcherImpl: TellomiSendLookups {

    /// tell.cc 对象用 Signal 自己现成的查询（发送时联网没关系）。
    public func firstParty(kind: String, url: URL) async -> TellomiLinkSender.FirstParty {
        do {
            switch kind {
            case "tellomi.group":
                guard let possible = PossibleGroupInviteLinkUrl.parseFrom(url) else {
                    return .notFound
                }
                guard let found = try await linkPreviewDraftAndCount(forGroupInviteLink: possible) else {
                    return .notFound
                }
                return .found(found.draft, count: found.count)
            case "tellomi.sticker":
                let legacyUrl = TellomiLinks.legacyEquivalent(of: url)
                guard StickerPackInfo.isStickerPackShare(legacyUrl) else {
                    return .notFound
                }
                guard let found = try await linkPreviewDraftAndCount(forStickerShare: legacyUrl, draftUrl: url) else {
                    return .notFound
                }
                return .found(found.draft, count: found.count)
            case "tellomi.call":
                guard let callLink = CallLink(url: TellomiLinks.legacyEquivalent(of: url)) ?? CallLink(url: url) else {
                    return .notFound
                }
                let name = try await fetchName(forCallLink: callLink)
                return .found(OWSLinkPreviewDraft(url: url, title: name, isForwarded: false), count: nil)
            default:
                return .notFound
            }
        } catch GroupsV2Error.expiredGroupInviteLink {
            return .inactive
        } catch {
            // 只记失败的类别，不记 URL（§6.5）
            Logger.warn("First-party link lookup failed: \(type(of: error))")
            return .notFound
        }
    }

    public func thumbnail(from data: Data) async -> TellomiLinkSender.Thumbnail? {
        guard let thumbnail = await Self.previewThumbnail(srcImageData: data) else {
            return nil
        }
        return TellomiLinkSender.Thumbnail(imageData: thumbnail.imageData, mimeType: thumbnail.mimetype)
    }
}

private extension HTMLMetadata {
    var dateForLinkPreview: Date? {
        [ogPublishDateString, articlePublishDateString, ogModifiedDateString, articleModifiedDateString]
            .first(where: { $0 != nil })?
            .flatMap {
                guard
                    let date = Date.ows_parseFromISO8601String($0),
                    date.timeIntervalSince1970 > 0
                else {
                    return nil
                }
                return date
            }
    }
}

// MARK: - Tellomi 服务端代抓（ADR-0063 §6.5）

/// `POST /v1/tellomi/link-preview`：走已登录账号的鉴权（和别的 `/v1/` 请求一样），链接放在请求体里。
///
/// UNVERIFIED（box 上不能编译 iOS）：`TSRequest(url:method:parameters:)` 带 JSON 体与账号鉴权、`asyncRequest` 在非 2xx 时抛错、
/// `Error.httpStatusCode` / `httpResponseHeaders`——照 `SignalServerFeedAuthFetcher`（FeedAuth.swift）同一套写法。
struct SignalServerLinkPreviewClient: TellomiServerLinkPreviewClient {

    func fetch(url: URL) async -> TellomiServerLinkPreview.Answer {
        var request = TSRequest(
            url: URL(string: TellomiServerLinkPreview.path)!,
            method: "POST",
            parameters: ["url": TellomiServerLinkPreview.requestUrlString(url)],
        )
        request.timeoutInterval = TellomiServerLinkPreview.requestTimeout
        do {
            let response = try await SSKEnvironment.shared.networkManagerRef.asyncRequest(request)
            return TellomiServerLinkPreview.answer(
                status: response.responseStatusCode,
                body: response.responseBodyData,
                retryAfter: nil,
            )
        } catch {
            guard let status = error.httpStatusCode else {
                return .failed
            }
            return TellomiServerLinkPreview.answer(
                status: status,
                body: nil,
                retryAfter: error.httpResponseHeaders?["Retry-After"],
            )
        }
    }
}
