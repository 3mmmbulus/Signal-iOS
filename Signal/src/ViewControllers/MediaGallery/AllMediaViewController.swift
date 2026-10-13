//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
import SignalServiceKit
import SignalUI

class AllMediaViewController: OWSViewController {
    private let tileViewController: MediaTileViewController
    private let accessoriesHelper = MediaGalleryAccessoriesHelper()
    private let thread: TSThread

    /// Tellomi：从「我的收藏」的分类点进来时一开始停在哪一段（#1174）。
    var tellomiInitialSegmentIndex: Int?
    private var tellomiLinksViewController: TellomiSavedLinksViewController?

    override var navigationItem: UINavigationItem {
        return tileViewController.navigationItem
    }

    init(
        thread: TSThread,
        spoilerState: SpoilerRenderState,
        name: String?,
    ) {
        tileViewController = MediaTileViewController(
            thread: thread,
            accessoriesHelper: accessoriesHelper,
            spoilerState: spoilerState,
        )
        self.thread = thread
        super.init()
        navigationItem.title = name
        accessoriesHelper.viewController = tileViewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(tileViewController)
        view.addSubview(tileViewController.view)
        tileViewController.view.autoPinEdgesToSuperviewEdges()

        accessoriesHelper.tellomiLinksSelectionChanged = { [weak self] showsLinks in
            self?.tellomiShowLinks(showsLinks)
        }
        if let tellomiInitialSegmentIndex {
            accessoriesHelper.tellomiSelectSegment(tellomiInitialSegmentIndex)
        }
        tellomiInstallSearchIfSavedMessages()
    }

    /// Tellomi：「我的收藏」的所有媒体顶上有搜索栏，在当前这一段里按文字筛（#1174）。
    private func tellomiInstallSearchIfSavedMessages() {
        guard thread.isNoteToSelf else {
            return
        }
        let searchController = UISearchController(searchResultsController: nil)
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.hidesNavigationBarDuringPresentation = false
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = OWSLocalizedString(
            "ALL_MEDIA_TELLOMI_SEARCH_PLACEHOLDER",
            value: "Search file names, captions and links",
            comment: "Tellomi (#1174): placeholder of the search bar in Saved Messages' All Media; filters the current file type",
        )
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    /// Tellomi：「链接」一段是一张盖在媒体网格上面的列表（#1174）。
    private func tellomiShowLinks(_ showsLinks: Bool) {
        if showsLinks {
            guard tellomiLinksViewController == nil else {
                return
            }
            let links = TellomiSavedLinksViewController(threadUniqueId: thread.uniqueId)
            links.tellomiQuery = navigationItem.searchController?.searchBar.text
            addChild(links)
            view.addSubview(links.view)
            links.view.autoPinEdgesToSuperviewEdges()
            links.didMove(toParent: self)
            tellomiLinksViewController = links
        } else if let links = tellomiLinksViewController {
            links.willMove(toParent: nil)
            links.view.removeFromSuperview()
            links.removeFromParent()
            tellomiLinksViewController = nil
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidChange() {
        owsNavigationController?.updateNavbarAppearance()
    }
}

extension AllMediaViewController: MediaPresentationContextProvider {

    func mediaPresentationContext(item: Media, in coordinateSpace: UICoordinateSpace) -> MediaPresentationContext? {
        return tileViewController.mediaPresentationContext(item: item, in: coordinateSpace)
    }
}

extension AllMediaViewController: OWSNavigationChildController {

    var navbarBackgroundColorOverride: UIColor? { Theme.tableView2PresentedBackgroundColor }
}

// MARK: - Tellomi（tellomi/tellomi#1174）

/// 带链接预览的消息。iOS「所有媒体」原来没有「链接」这一段，Tellomi 补上（Android 按同样的条件列：消息带链接预览）。
enum TellomiSavedLinks {

    struct Item: Equatable {
        let interactionUniqueId: String
        let url: URL
        let title: String?
        let timestamp: UInt64
    }

    private static let interactionTable = "model_TSInteraction"

    /// 带链接预览、不是编辑过的旧版本、不是群快拍回复（和上游「所有媒体」的 InteractionFinder 条件一致）。
    private static let linkCondition = "uniqueThreadId = ? AND linkPreview IS NOT NULL AND editState IS NOT \(TSEditState.pastRevision.rawValue) AND isGroupStoryReply IS NOT 1"

    static func hasAny(threadUniqueId: String, tx: DBReadTransaction) -> Bool {
        let sql = "SELECT EXISTS(SELECT 1 FROM \(interactionTable) WHERE \(linkCondition))"
        do {
            return try Bool.fetchOne(tx.database, sql: sql, arguments: [threadUniqueId]) ?? false
        } catch {
            owsFailDebug("Couldn't look for links: \(error)")
            return false
        }
    }

    /// 搜的时候：标题或网址包含这段字（不分大小写）；空白的查询都留下。
    static func matches(_ item: Item, query: String?) -> Bool {
        guard let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return true
        }
        return (item.title?.localizedCaseInsensitiveContains(query) ?? false) || item.url.absoluteString.localizedCaseInsensitiveContains(query)
    }

    /// 新的在上；链接预览里没有网址的跳过。
    static func items(threadUniqueId: String, tx: DBReadTransaction) -> [Item] {
        let sql = "SELECT uniqueId FROM \(interactionTable) WHERE \(linkCondition) ORDER BY id DESC"
        let uniqueIds: [String]
        do {
            uniqueIds = try String.fetchAll(tx.database, sql: sql, arguments: [threadUniqueId])
        } catch {
            owsFailDebug("Couldn't list links: \(error)")
            return []
        }
        return uniqueIds.compactMap { uniqueId in
            guard
                let message = TSInteraction.anyFetch(uniqueId: uniqueId, transaction: tx) as? TSMessage,
                let linkPreview = message.linkPreview,
                let urlString = linkPreview.urlString,
                let url = URL(string: urlString)
            else {
                return nil
            }
            return Item(interactionUniqueId: uniqueId, url: url, title: linkPreview.title, timestamp: message.timestamp)
        }
    }
}

/// 「所有媒体」的「链接」一段：带链接预览的消息，新的在上；一行 = 标题（没有就用域名）· 网址 · 日期，点了按 rust/links 的 open_plan 打开（和聊天页同一个出口：支付金融只进浏览器）。
final class TellomiSavedLinksViewController: OWSTableViewController2 {

    private let threadUniqueId: String

    /// 「我的收藏」按类型搜：标题或网址包含这段字的留下。
    var tellomiQuery: String? {
        didSet {
            if isViewLoaded, tellomiQuery != oldValue {
                reloadLinks()
            }
        }
    }

    init(threadUniqueId: String) {
        self.threadUniqueId = threadUniqueId
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        reloadLinks()
    }

    func reloadLinks() {
        let items = SSKEnvironment.shared.databaseStorageRef.read { tx in
            TellomiSavedLinks.items(threadUniqueId: threadUniqueId, tx: tx)
        }.filter { TellomiSavedLinks.matches($0, query: tellomiQuery) }
        let section = OWSTableSection()
        if items.isEmpty {
            section.add(.label(withText: OWSLocalizedString(
                "ALL_MEDIA_TELLOMI_LINKS_EMPTY",
                value: "No links yet",
                comment: "Tellomi (#1174): shown on the All Media links page when the chat has no messages with link previews",
            ), accessoryType: .none))
        }
        for item in items {
            let date = Date(millisecondsSince1970: item.timestamp)
            section.add(.disclosureItem(
                withText: item.title ?? item.url.host ?? item.url.absoluteString,
                subtitle: item.url.absoluteString,
                accessoryText: DateUtil.formatDateShort(date),
                actionBlock: { [weak self] in
                    // Tellomi（ADR-0063 §4.9）：和聊天页同一个出口，支付金融只进显式浏览器，不被通用链接带进支付 App。
                    guard let self else { return }
                    TellomiExternalLinkOpener.open(item.url, from: self, inApp: .handOffToSystem)
                },
            ))
        }
        contents = OWSTableContents(sections: [section])
    }
}

extension AllMediaViewController: UISearchResultsUpdating {

    /// Tellomi：搜索栏的字变了，网格和链接列表一起筛（#1174）。
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text
        tileViewController.tellomiSearch(query)
        tellomiLinksViewController?.tellomiQuery = query
    }
}
