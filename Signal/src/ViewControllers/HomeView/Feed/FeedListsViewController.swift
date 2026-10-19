//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalServiceKit
import SignalUI
import UIKit

/// 名单入口页（`dynamic-feed.md` 第三节第 29、42、44 条）：关注请求、不看 TA 的动态、不让 TA 看我的动态、动态屏蔽列表、关心的人，每一行推一个页面。
/// iOS 还没有自己的主页页面（Android 的入口在那里），所以从动态设置页的一行和「我的动态」右上角的按钮进来；
/// 两处都跟着 `TellomiFeed.isListsEnabled`（默认关，关着时那两个页面和之前一样）。
final class FeedListsViewController: OWSTableViewController2 {

    private let source: FeedSource

    /// 最近一次推出去的页面（单测 / 截图用）。
    private(set) var lastOpened: UIViewController?

    init(source: FeedSource) {
        self.source = source
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = Self.title
        updateTableContents()
    }

    override func themeDidChange() {
        super.themeDidChange()
        updateTableContents()
    }

    private func updateTableContents() {
        let contents = OWSTableContents()
        let section = OWSTableSection()
        for entry in FeedListsEntry.allCases {
            section.add(OWSTableItem(
                text: Self.title(for: entry),
                actionBlock: { [weak self] in self?.open(entry) },
                accessoryType: .disclosureIndicator,
            ))
        }
        contents.add(section)
        self.contents = contents
    }

    /// 点了一行：推对应的页面（单测 / 截图直接调它）。
    func open(_ entry: FeedListsEntry) {
        let page = Self.page(for: entry, source: source)
        lastOpened = page
        navigationController?.pushViewController(page, animated: true)
    }

    static func page(for entry: FeedListsEntry, source: FeedSource) -> UIViewController {
        if let mode = entry.peopleMode {
            return FeedPeopleViewController(mode: mode, source: source)
        }
        return FeedClosePeopleViewController(source: source)
    }

    static var title: String {
        return OWSLocalizedString("TELLOMI_FEED_LISTS_TITLE", comment: "Feed lists: title of the page (and the row / button that opens it) with follow requests, hidden people, blocked people and close people.")
    }

    static func title(for entry: FeedListsEntry) -> String {
        if let mode = entry.peopleMode { return FeedPeopleViewController.title(for: mode) }
        return FeedClosePeopleViewController.title
    }
}
