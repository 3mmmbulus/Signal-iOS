//
// Copyright 2026 重庆半格智能科技有限公司
// SPDX-License-Identifier: AGPL-3.0-only
//

import GRDB
import LibSignalClient
import XCTest
@testable import Signal
@testable import SignalServiceKit
@testable import SignalUI

/// Tellomi（tellomi/tellomi#1259，需求 `media-album-forward-picker.md` 第二节 F-1…F-12、判据「转发面板」1–6）：转发网格。
///
/// 截图只在 `TELLOMI_SHOTS=1` 时拍：每台模拟器截自己的屏宽，写到 `TELLOMI_SHOTS_DIR/<屏宽>/forward-*.png`。
final class TellomiForwardGridTests: SignalBaseTest {

    @MainActor
    override func setUp() {
        super.setUp()
        // 头像换成用例自己画的（测试环境的通讯录是假的，真头像会崩）。整个测试进程里一直开着：
        // 上一条用例的格子可能在下一条用例搭环境时还被排一次版，那时环境不在，走真头像会读不到依赖
        TellomiForwardGridCell.avatarOverrideForTesting = { target in Self.placeholderAvatar(for: target) }
    }

    @MainActor
    override func tearDown() {
        // 先把这条用例弹出的网格摘掉、窗口收起：环境拆掉后它们不能再排版
        for window in hostedWindows {
            window.rootViewController?.presentedViewController?.view.removeFromSuperview()
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        hostedWindows = []
        super.tearDown()
    }

    private var hostedWindows: [UIWindow] = []

    // MARK: - 候选聊天（F-5，判据 2）

    /// 判据 2：第一格「我的收藏」——还没有这个会话（新注册账号）也有，而且只出现一次。
    func testSavedMessagesComesFirstEvenBeforeItsChatExists() {
        register()
        let buddy = makeContactChat("小林")

        let targets = read { tx in TellomiForwardTargets.load(tx: tx) }

        XCTAssertEqual(targets.first?.id, savedMessagesId)
        XCTAssertEqual(targets.first?.shortName, MessageStrings.noteToSelf)
        XCTAssertTrue(targets.first?.isSavedMessages == true)
        XCTAssertNil(read { tx in TSContactThread.getWithContactAddress(LocalIdentifiers.forUnitTests.aciAddress, transaction: tx) })
        XCTAssertEqual(targets.map(\.id), [savedMessagesId, contactId(buddy)])

        // 给自己发过消息之后，它也只在第一格出现一次
        makeChat(with: LocalIdentifiers.forUnitTests.aciAddress)
        let again = read { tx in TellomiForwardTargets.load(tx: tx) }
        XCTAssertEqual(again.map(\.id), [savedMessagesId, contactId(buddy)])
    }

    /// F-5：之后与聊天列表同序——置顶的在前，其余新的在前，归档的排最后；最多 N 个（不算「我的收藏」）。
    func testChatsFollowTheChatListPinnedFirstArchivedLastAndAreCapped() throws {
        register()
        let old = makeContactChat("老王")
        let archived = makeContactChat("归档")
        let pinned = makeContactChat("置顶")
        let group = makeGroupChat("周末爬山")
        let newest = makeContactChat("最新")
        write { tx in
            let pinnedThread = TSContactThread.getWithContactAddress(pinned, transaction: tx)!
            try! DependenciesBridge.shared.pinnedThreadManager.pinThread(pinnedThread, updateStorageService: false, tx: tx)
            let archivedThread = TSContactThread.getWithContactAddress(archived, transaction: tx)!
            try! tx.database.execute(sql: "UPDATE model_TSThread SET isArchived = 1 WHERE uniqueId = ?", arguments: [archivedThread.uniqueId])
        }

        let targets = read { tx in TellomiForwardTargets.load(tx: tx) }
        XCTAssertEqual(
            targets.map(\.shortName),
            [MessageStrings.noteToSelf, "置顶", "最新", "周末爬山", "老王", "归档"],
        )
        XCTAssertEqual(targets[3].id, "group:" + group.uniqueId)

        let capped = read { tx in TellomiForwardTargets.load(maxChats: 3, tx: tx) }
        XCTAssertEqual(capped.map(\.shortName), [MessageStrings.noteToSelf, "置顶", "最新", "周末爬山"])
        XCTAssertEqual(TellomiForwardTargets.maxChats, 150)
        _ = (old, newest)
    }

    /// F-5：不出现——已退出的群、拉黑的人和群、还没接受的消息请求；「动态」本来就不进。
    func testChatsYouCannotPostInAreLeftOut() throws {
        register()
        let friend = makeContactChat("朋友")
        let blocked = makeContactChat("拉黑的")
        let stranger = makeContactChat("陌生人", incoming: true)
        _ = makeGroupChat("还在的群")
        let blockedGroup = makeGroupChat("拉黑的群")
        let leftGroup = makeGroupChat("退出的群", includingMe: false)
        write { tx in
            SSKEnvironment.shared.blockingManagerRef.addBlockedAddress(blocked, blockMode: .local, transaction: tx)
            SSKEnvironment.shared.blockingManagerRef.addBlockedGroupId(blockedGroup.groupId, blockMode: .local, transaction: tx)
        }

        let names = read { tx in TellomiForwardTargets.load(tx: tx) }.map(\.shortName)

        XCTAssertEqual(names, [MessageStrings.noteToSelf, "还在的群", "朋友"])
        XCTAssertTrue(read { tx in ThreadFinder().hasPendingMessageRequest(thread: TSContactThread.getWithContactAddress(stranger, transaction: tx)!, transaction: tx) })
        let leftGroupIsVisible = try read { tx in
            try Bool.fetchOne(tx.database, sql: "SELECT shouldThreadBeVisible FROM model_TSThread WHERE uniqueId = ?", arguments: [leftGroup.uniqueId])
        }
        XCTAssertEqual(leftGroupIsVisible, true, "退出的群在聊天列表里还看得见，只是网格里没有")
        _ = friend
    }

    /// F-9：搜索分组——我的收藏（按名字）、聊天（网格里有的）、群组（网格里没有的），同一个聊天只出现一次。
    func testSearchGroupsSavedChatsAndGroupsOnceEach() throws {
        register()
        _ = makeContactChat("小林")
        let hiking = makeGroupChat("Hiking Club")
        let quiet = makeGroupChat("Hiking Quiet", visible: false)
        // 拉黑了、聊天也删了，但人还在群里（本地拉黑只是排队退群；存储服务、备份恢复来的拉黑根本不退）
        let blockedQuiet = makeGroupChat("Hiking Blocked", visible: false)
        write { tx in
            SSKEnvironment.shared.blockingManagerRef.addBlockedGroupId(blockedQuiet.groupId, blockMode: .local, transaction: tx)
        }

        let chats = read { tx in TellomiForwardTargets.load(tx: tx) }
        let saved = try read { tx in try TellomiForwardTargets.search(query: "Saved", chats: chats, tx: tx) }
        XCTAssertEqual(saved.savedMessages?.id, savedMessagesId)

        let hikingResults = try read { tx in try TellomiForwardTargets.search(query: "Hiking", chats: chats, tx: tx) }
        XCTAssertNil(hikingResults.savedMessages)
        XCTAssertEqual(hikingResults.chats.map(\.id), ["group:" + hiking.uniqueId])
        XCTAssertEqual(hikingResults.groups.map(\.id), ["group:" + quiet.uniqueId], "没聊过的群在「群组」里，拉黑的群不出现")
        XCTAssertFalse(hikingResults.groups.contains { $0.id == "group:" + blockedQuiet.uniqueId })
        XCTAssertTrue(hikingResults.contacts.isEmpty)

        let nothing = try read { tx in try TellomiForwardTargets.search(query: "zzzz", chats: chats, tx: tx) }
        XCTAssertTrue(nothing.isEmpty)
    }

    // MARK: - 几何（F-2 / F-4）

    /// 卡片宽 = min(屏宽, 440) − 20；列数 = ⌊(卡片宽 − 24) / 70⌋（402 以上 5 列、375–393 4 列）；格子高 = 宽 + 25。
    func testGeometryMatchesTheSpecAtEachWidth() {
        typealias Metrics = TellomiForwardGridViewController.Metrics
        let cases: [(CGFloat, CGFloat, Int, CGFloat)] = [
            (375, 355, 4, 82),
            (393, 373, 4, 87),
            (402, 382, 5, 71),
            (440, 420, 5, 79),
            (1024, 420, 5, 79),
        ]
        for (screenWidth, cardWidth, columns, itemWidth) in cases {
            let metrics = Metrics(containerWidth: screenWidth)
            XCTAssertEqual(metrics.cardWidth, cardWidth, "\(screenWidth)")
            XCTAssertEqual(metrics.columns, columns, "\(screenWidth)")
            XCTAssertEqual(metrics.itemWidth, itemWidth, "\(screenWidth)")
            XCTAssertEqual(metrics.itemHeight, itemWidth + 25)
        }
    }

    /// F-2：浮动卡片在独立的「取消」上方 8 pt，「取消」高 57；一开始露出约三行（标题区 + 3.7 × 格宽 + 14）。
    @MainActor
    func testCardFloatsAboveTheCancelButtonAndRevealsAboutThreeRows() throws {
        register()
        for index in 0..<20 {
            makeContactChat("好友\(index)")
        }
        let hosted = try host()
        let grid = hosted.grid
        let screen = hosted.window.bounds
        let metrics = grid.metricsForTesting

        XCTAssertEqual(metrics, TellomiForwardGridViewController.Metrics(containerWidth: screen.size.width))
        let card = grid.cardFrameForTesting
        let button = grid.actionButtonFrameForTesting
        XCTAssertEqual(card.size.width, min(screen.size.width, 440) - 20)
        XCTAssertEqual(card.midX, screen.midX, accuracy: 1)
        XCTAssertEqual(button.size.height, 57)
        XCTAssertEqual(button.minY - card.maxY, 8, accuracy: 0.5)
        XCTAssertEqual(grid.actionTitleForTesting, CommonStrings.cancelButton)
        XCTAssertEqual(grid.dimAlphaForTesting, 1)

        let revealed = card.maxY - grid.visibleCardTopForTesting
        XCTAssertEqual(revealed, 64 + metrics.initialRevealHeight, accuracy: 1)
        XCTAssertGreaterThan(revealed - 64, 2.5 * metrics.itemHeight, "约三行")
        XCTAssertLessThan(revealed - 64, 3.2 * metrics.itemHeight, "约三行")

        let collectionView = grid.collectionViewForTesting
        collectionView.layoutIfNeeded()
        let firstCell = try XCTUnwrap(collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? TellomiForwardGridCell)
        XCTAssertEqual(firstCell.nameTextForTesting, MessageStrings.noteToSelf, "第一格是我的收藏")
        XCTAssertEqual(firstCell.avatarFrameForTesting.size, CGSize(width: 60, height: 60))
        XCTAssertEqual(firstCell.bounds.size.width, metrics.itemWidth)
        XCTAssertEqual(collectionView.cellForItem(at: IndexPath(item: metrics.columns, section: 0))?.frame.minY, metrics.itemHeight, "第二行从格子高度处开始")
    }

    /// 清单 5.4：没有可隐藏的说明文字（发起方不给回调）时，附言栏上没有「隐藏说明文字」开关，高度不变。
    @MainActor
    func testHideCaptionSwitchAbsentWhenNothingToHide() throws {
        register()
        let lin = makeContactChat("小林")
        let hosted = try host()
        let grid = hosted.grid
        grid.tapTargetForTesting(id: contactId(lin))
        grid.view.layoutIfNeeded()

        XCTAssertTrue(grid.isCommentBarVisibleForTesting)
        XCTAssertFalse(grid.isHideCaptionSwitchVisibleForTesting)
        XCTAssertNil(grid.hideCaptionLabelForTesting)
        XCTAssertEqual(grid.commentBarHeightForTesting, TellomiForwardGridViewController.Metrics.commentBarHeight)
    }

    /// 清单 5.4：有说明文字时，选了聊天后附言栏上方出现「隐藏说明文字」开关，默认关；拨动把值交给发起方。
    @MainActor
    func testHideCaptionSwitchDefaultsOffAndReportsChanges() throws {
        register()
        let lin = makeContactChat("小林")
        var reported: [Bool] = []
        let hosted = try host(hideCaptionDidChange: { reported.append($0) })
        let grid = hosted.grid
        XCTAssertFalse(grid.isHideCaptionSwitchVisibleForTesting, "没选聊天时附言栏整个不出现")

        grid.tapTargetForTesting(id: contactId(lin))
        grid.view.layoutIfNeeded()

        XCTAssertTrue(grid.isHideCaptionSwitchVisibleForTesting)
        XCTAssertFalse(grid.isHideCaptionOnForTesting)
        XCTAssertEqual(grid.hideCaptionLabelForTesting, TellomiForwardGridViewController.Strings.hideCaption)
        XCTAssertEqual(
            grid.commentBarHeightForTesting,
            TellomiForwardGridViewController.Metrics.commentBarHeight + TellomiForwardGridViewController.Metrics.hideCaptionRowHeight,
        )

        grid.setHideCaptionForTesting(true)
        grid.setHideCaptionForTesting(false)
        XCTAssertEqual(reported, [true, false])
    }

    /// 清单 5.4：开关的值在点「发送」之后仍由发起方持有；发送回调本身不变（附言照常单独发）。
    @MainActor
    func testHideCaptionDoesNotChangeTheSendCallback() async throws {
        register()
        let lin = makeContactChat("小林")
        var isOn = false
        let hosted = try host(hideCaptionDidChange: { isOn = $0 })
        let grid = hosted.grid
        grid.tapTargetForTesting(id: contactId(lin))
        grid.setHideCaptionForTesting(true)
        grid.typeCommentForTesting("看看")
        grid.tapActionButtonForTesting()
        try await settle()

        XCTAssertTrue(isOn)
        XCTAssertEqual(hosted.recorder.sent.count, 1)
        XCTAssertEqual(hosted.recorder.sent.first?.comment, "看看")
    }

    /// F-3 / F-6：点头像切换选中；副标题换成已选名字（「、」连接）；选中态 = 缩小 + 环 + 勾 + 强调色名字；
    /// F-7：底部出现附言栏，「取消」变成带数量的「发送」。
    @MainActor
    func testTappingSelectsAndTheSubtitleListsTheNames() throws {
        register()
        let lin = makeContactChat("小林")
        let wang = makeContactChat("小王")
        let hosted = try host()
        let grid = hosted.grid
        XCTAssertEqual(grid.subtitleForTesting, TellomiForwardGridViewController.Strings.chooseChats)
        XCTAssertFalse(grid.isCommentBarVisibleForTesting)

        grid.tapTargetForTesting(id: contactId(wang))
        grid.tapTargetForTesting(id: contactId(lin))

        XCTAssertEqual(grid.selectedIdsForTesting, [contactId(wang), contactId(lin)])
        XCTAssertEqual(grid.subtitleForTesting, "小王" + TellomiForwardGridViewController.Strings.nameSeparator + "小林")
        XCTAssertEqual(grid.actionTitleForTesting, OWSLocalizedString("SEND_BUTTON_TITLE", comment: ""))
        XCTAssertEqual(grid.badgeTextForTesting, "2")
        XCTAssertTrue(grid.isCommentBarVisibleForTesting)
        XCTAssertEqual(hosted.recorder.prefetched.count, 2, "选中时预取身份密钥（安全码确认用）")

        let cell = try XCTUnwrap(visibleCell(grid, id: contactId(lin)))
        XCTAssertTrue(cell.isChosen)
        XCTAssertTrue(cell.isRingVisibleForTesting)
        XCTAssertTrue(cell.isCheckVisibleForTesting)
        XCTAssertEqual(
            cell.nameColorForTesting?.resolvedColor(with: cell.traitCollection),
            UIColor.Signal.accent.resolvedColor(with: cell.traitCollection),
        )
        XCTAssertLessThan(cell.avatarScaleForTesting, 0.9)
        XCTAssertTrue(cell.accessibilityTraits.contains(.selected))

        grid.tapTargetForTesting(id: contactId(wang))
        grid.tapTargetForTesting(id: contactId(lin))
        XCTAssertEqual(grid.selectedIdsForTesting, [])
        XCTAssertEqual(grid.subtitleForTesting, TellomiForwardGridViewController.Strings.chooseChats)
        XCTAssertEqual(grid.actionTitleForTesting, CommonStrings.cancelButton)
        XCTAssertNil(grid.badgeTextForTesting)
        XCTAssertFalse(grid.isCommentBarVisibleForTesting)
        let deselected = try XCTUnwrap(visibleCell(grid, id: contactId(lin)))
        XCTAssertFalse(deselected.isRingVisibleForTesting)
        XCTAssertEqual(deselected.avatarScaleForTesting, 1)
    }

    /// 判据 3：选第 6 个不选上，提示「最多选 5 个聊天」。
    @MainActor
    func testTheSixthChatIsRefusedWithAToast() throws {
        register()
        let addresses = (0..<6).map { makeContactChat("好友\($0)") }
        let hosted = try host()
        let grid = hosted.grid

        for address in addresses {
            grid.tapTargetForTesting(id: contactId(address))
        }

        XCTAssertEqual(grid.selectedIdsForTesting.count, 5)
        XCTAssertFalse(grid.selectedIdsForTesting.contains(contactId(addresses[5])))
        XCTAssertEqual(grid.badgeTextForTesting, "5")
        let toast = try XCTUnwrap(findToast(in: grid.view))
        XCTAssertEqual(toast.text, String(format: TellomiForwardGridViewController.Strings.selectionLimitFormat, 5))
        XCTAssertEqual(toast.text, "You can select up to 5 chats")
    }

    /// F-7 / F-8：点「发送」按勾选顺序交出聊天和附言，面板立即收起。
    @MainActor
    func testSendHandsOverTheChatsInOrderWithTheCommentAndHidesThePanel() async throws {
        register()
        let lin = makeContactChat("小林")
        let group = makeGroupChat("周末爬山")
        let hosted = try host()
        let grid = hosted.grid

        grid.tapTargetForTesting(id: "group:" + group.uniqueId)
        grid.tapTargetForTesting(id: savedMessagesId)
        grid.tapTargetForTesting(id: contactId(lin))
        grid.typeCommentForTesting("  看看这个  ")
        grid.tapActionButtonForTesting()
        try await settle()

        XCTAssertEqual(hosted.recorder.sent.count, 1)
        XCTAssertEqual(hosted.recorder.sent.first?.recipients, [
            .group(group.uniqueId),
            .contact(LocalIdentifiers.forUnitTests.aciAddress),
            .contact(lin),
        ])
        XCTAssertEqual(hosted.recorder.sent.first?.comment, "看看这个")
        XCTAssertEqual(grid.dimAlphaForTesting, 0, "面板立即收起")
        XCTAssertGreaterThanOrEqual(grid.visibleCardTopForTesting, hosted.window.bounds.size.height, "卡片移出屏幕")
        XCTAssertEqual(hosted.recorder.cancelCount, 0)

        // 收起期间再点不会重复发
        grid.tapActionButtonForTesting()
        try await settle()
        XCTAssertEqual(hosted.recorder.sent.count, 1)
    }

    /// 没发出去（错误提示已弹出）：面板回来，选择还在，可以再点「发送」。
    @MainActor
    func testAFailedSendBringsThePanelBack() async throws {
        register()
        let lin = makeContactChat("小林")
        let hosted = try host(sendResult: false)
        let grid = hosted.grid

        grid.tapTargetForTesting(id: contactId(lin))
        grid.tapActionButtonForTesting()
        try await settle()

        XCTAssertEqual(hosted.recorder.sent.count, 1)
        XCTAssertEqual(grid.dimAlphaForTesting, 1)
        XCTAssertLessThan(grid.visibleCardTopForTesting, hosted.window.bounds.size.height)
        XCTAssertEqual(grid.selectedIdsForTesting, [contactId(lin)])
        XCTAssertNil(hosted.recorder.sent.first?.comment, "附言空着就不发附言")

        grid.tapActionButtonForTesting()
        try await settle()
        XCTAssertEqual(hosted.recorder.sent.count, 2)
    }

    /// F-2 / F-4：没选时的「取消」、点压暗处、标题区下拉超过 30 pt 松手都是关闭；不到 30 pt 不关。
    @MainActor
    func testCancelDimTapAndPullingDownPastThirtyPointsClose() throws {
        register()
        makeContactChat("小林")
        let hosted = try host()
        let grid = hosted.grid

        grid.tapActionButtonForTesting()
        XCTAssertEqual(hosted.recorder.cancelCount, 1)
        grid.tapDimForTesting()
        XCTAssertEqual(hosted.recorder.cancelCount, 2)
        grid.pullDownAndReleaseForTesting(distance: 29)
        XCTAssertEqual(hosted.recorder.cancelCount, 2, "不到 30 pt 不关")
        grid.pullDownAndReleaseForTesting(distance: 31)
        XCTAssertEqual(hosted.recorder.cancelCount, 3)
        XCTAssertTrue(hosted.recorder.sent.isEmpty)
    }

    /// F-4：上拉网格，标题区跟着上去，到卡片顶端停住（展开到状态栏下方）。
    @MainActor
    func testPullingTheGridUpExpandsItToTheTop() throws {
        register()
        for index in 0..<40 {
            makeContactChat("好友\(index)")
        }
        let hosted = try host()
        let grid = hosted.grid
        let restingTop = grid.visibleCardTopForTesting
        XCTAssertGreaterThan(restingTop, grid.cardFrameForTesting.minY + 100)

        grid.scrollUpForTesting(distance: 60)
        XCTAssertEqual(grid.visibleCardTopForTesting, restingTop - 60, accuracy: 0.5, "标题区跟着内容上去")

        grid.scrollUpForTesting(distance: 2_000)
        XCTAssertEqual(grid.visibleCardTopForTesting, grid.cardFrameForTesting.minY, accuracy: 0.5, "到顶后停住")
        XCTAssertEqual(grid.headerFrameInCardForTesting.minY, 0, accuracy: 0.5)
        XCTAssertLessThanOrEqual(grid.cardFrameForTesting.minY, hosted.window.safeAreaInsets.top + 8, "展开到状态栏下方")
    }

    /// F-4（taishi 审查 #70）：标题区贴顶以后，底下滚过去的格子不能从标题区透出来——标题区自己铺卡片底色；上面两个角跟卡片一样圆。
    @MainActor
    func testTheTitleAreaHidesTheGridScrolledUnderIt() async throws {
        register()
        for index in 0..<60 {
            makeContactChat("好友\(index)")
        }
        let hosted = try host()
        let grid = hosted.grid
        let collectionView = grid.collectionViewForTesting
        let metrics = grid.metricsForTesting
        let card = components(TellomiForwardGridViewController.Colors.card, traits: grid.traitCollection)

        // 第二行第二格。头像圆心在格子里 (中线, 4 + 30)；取圆环上、字母以外的一点（圆心左边 22）
        let item = IndexPath(item: metrics.columns + 1, section: 0)
        let cellFrame = try XCTUnwrap(collectionView.layoutAttributesForItem(at: item)?.frame)
        let avatarCenterY = cellFrame.minY + 4 + 30
        let ringPoint = CGPoint(x: cellFrame.midX - 22, y: avatarCenterY)

        // 先让它露在标题区下面：头像确实画出了颜色，这条用例才有意义
        collectionView.contentOffset.y = avatarCenterY - 64 - 100
        collectionView.layoutIfNeeded()
        try await settle()
        let avatar = pixel(render(hosted.window), at: collectionView.convert(ringPoint, to: hosted.window))
        XCTAssertGreaterThan(distance(avatar, card), 0.2, "格子的头像没画出来（\(avatar)），量不了标题区")

        // 再滚到这一圈正好落在贴顶的标题区中间（标题区高 64）
        collectionView.contentOffset.y = avatarCenterY - 32
        collectionView.layoutIfNeeded()
        try await settle()
        XCTAssertEqual(grid.headerFrameInCardForTesting.minY, 0, accuracy: 0.5, "标题区贴在卡片顶端")
        let image = render(hosted.window)
        let underHeader = pixel(image, at: collectionView.convert(ringPoint, to: hosted.window))
        XCTAssertLessThan(
            distance(underHeader, card),
            0.04,
            "标题区里透出了底下格子的头像（\(underHeader)，头像本身 \(avatar)），应当是卡片底色（\(card)）",
        )

        // 卡片左上角外侧那一点是压暗层，不是方角的标题区
        let cardFrame = grid.cardFrameForTesting
        let corner = pixel(image, at: CGPoint(x: cardFrame.minX + 1, y: cardFrame.minY + 1))
        XCTAssertGreaterThan(distance(corner, card), 0.1, "标题区上面两个角要和卡片一样是圆的（\(corner)）")
    }

    /// F-9：点 🔍 进搜索态——空查询是最近联系人一排；在搜索里勾一个，回到网格、插在「我的收藏」之后并保持选中。
    @MainActor
    func testSearchShowsRecentContactsAndAPickedChatLandsAfterSavedMessages() throws {
        register()
        let group = makeGroupChat("Hiking Club")
        let addresses = (0..<15).map { makeContactChat("好友\($0)") }
        let hosted = try host()
        let grid = hosted.grid
        let farAway = contactId(addresses[0])
        XCTAssertGreaterThan(grid.gridTargetIdsForTesting.firstIndex(of: farAway) ?? 0, 10)

        grid.tapSearchButtonForTesting()
        XCTAssertTrue(grid.isSearchingForTesting)
        XCTAssertEqual(grid.searchSectionTitlesForTesting, [TellomiForwardGridViewController.Strings.recentContacts])
        let recentIds = try XCTUnwrap(grid.searchSectionIdsForTesting.first)
        XCTAssertEqual(recentIds.count, 12, "最近联系人一排最多 12 个")
        XCTAssertFalse(recentIds.contains(savedMessagesId))
        XCTAssertFalse(recentIds.contains("group:" + group.uniqueId), "一排里只有人")

        grid.typeSearchForTesting("Hiking")
        XCTAssertEqual(grid.searchSectionTitlesForTesting, [TellomiForwardGridViewController.Strings.sectionChats])

        grid.typeSearchForTesting("")
        grid.tapTargetForTesting(id: recentIds[11])

        XCTAssertFalse(grid.isSearchingForTesting, "勾选后回到网格")
        XCTAssertEqual(Array(grid.gridTargetIdsForTesting.prefix(2)), [savedMessagesId, recentIds[11]])
        XCTAssertEqual(grid.selectedIdsForTesting, [recentIds[11]])
        let cell = try XCTUnwrap(visibleCell(grid, id: recentIds[11]))
        XCTAssertTrue(cell.isChosen)

        // 取消搜索不改选择
        grid.tapSearchButtonForTesting()
        grid.tapSearchCancelForTesting()
        XCTAssertFalse(grid.isSearchingForTesting)
        XCTAssertEqual(grid.selectedIdsForTesting, [recentIds[11]])
    }

    /// F-9：搜不到写「没有找到“x”」。
    @MainActor
    func testSearchWithNoResultsSaysSo() throws {
        register()
        makeContactChat("小林")
        let hosted = try host()
        let grid = hosted.grid

        grid.tapSearchButtonForTesting()
        grid.typeSearchForTesting("zzzz")

        XCTAssertTrue(grid.isNoResultsVisibleForTesting)
        XCTAssertEqual(grid.noResultsTextForTesting, "No results found for 'zzzz'")
        XCTAssertEqual(grid.searchSectionIdsForTesting, [])

        grid.typeSearchForTesting("Saved")
        XCTAssertFalse(grid.isNoResultsVisibleForTesting)
        XCTAssertEqual(grid.searchSectionIdsForTesting, [[savedMessagesId]])
    }

    /// F-9（taishi 审查 #70：搜索态比设计低 50 pt）：进搜索态以后卡片展开到状态栏下方，搜索框就在卡片顶端，不被系统往下挪。
    @MainActor
    func testSearchKeepsTheSearchFieldAtTheTopOfTheCard() async throws {
        register()
        for index in 0..<20 {
            makeContactChat("好友\(index)")
        }
        let hosted = try host()
        let grid = hosted.grid
        let collectionView = grid.collectionViewForTesting

        grid.tapSearchButtonForTesting()
        try await settle()
        hosted.window.layoutIfNeeded()

        let card = grid.cardFrameForTesting
        let field = grid.searchFieldFrameInWindowForTesting
        let state = "offset \(collectionView.contentOffset.y) inset \(collectionView.contentInset.top) card \(card) header \(grid.headerFrameInCardForTesting) field \(field) safeTop \(hosted.window.safeAreaInsets.top) firstResponder \(grid.isSearchFieldFirstResponderForTesting)"
        XCTAssertEqual(card.minY, hosted.window.safeAreaInsets.top + 8, accuracy: 0.5, "搜索态卡片展开到状态栏下方：\(state)")
        XCTAssertEqual(field.minY, card.minY + 14, accuracy: 0.5, "搜索框离卡片顶 14：\(state)")
        // 结果从搜索栏下面开始：网格停在停放位置，没有被系统为了「露出搜索框」往下推
        XCTAssertEqual(collectionView.contentOffset.y, -collectionView.contentInset.top, accuracy: 0.5, "搜索结果被往下推了：\(state)")
    }

    /// F-3 / F-10：右上角「分享到其他 App」只在内容能分享时出现，点它交给系统分享面板。
    @MainActor
    func testShareButtonOnlyWhenThereIsSomethingToShare() throws {
        register()
        let withShare = try host()
        XCTAssertTrue(withShare.grid.isShareButtonVisibleForTesting)
        withShare.grid.tapShareButtonForTesting()
        XCTAssertEqual(withShare.recorder.shareCount, 1)
        withShare.window.isHidden = true

        let withoutShare = try host(canShare: false)
        XCTAssertFalse(withoutShare.grid.isShareButtonVisibleForTesting)
    }

    /// F-2 / 判据 6：从查看器打开的面板一律深色。
    @MainActor
    func testTheViewerOpensItDark() throws {
        register()
        let dark = try host(forceDarkTheme: true)
        XCTAssertEqual(dark.grid.traitCollection.userInterfaceStyle, .dark)
        XCTAssertEqual(dark.grid.preferredStatusBarStyle, .lightContent)
        dark.window.isHidden = true

        let normal = try host()
        XCTAssertEqual(normal.grid.overrideUserInterfaceStyle, .unspecified)
    }

    // MARK: - 发出以后（F-7 / F-8）

    /// 判据 4：附言作为单独一条文字，先于转发内容发出；没写附言就只发转发内容（`_tryToSend` 按这个顺序发）。
    func testTheCommentIsSentBeforeTheForwardedContent() {
        func describe(_ steps: [ForwardMessageViewController.TellomiForwardStep<String>]) -> [String] {
            steps.map { step in
                switch step {
                case .comment(let text): return "附言:" + text
                case .item(let item): return "内容:" + item
                }
            }
        }

        XCTAssertEqual(
            describe(ForwardMessageViewController.tellomiForwardSteps(items: ["第一条", "第二条"], comment: "看看这个")),
            ["附言:看看这个", "内容:第一条", "内容:第二条"],
        )
        XCTAssertEqual(describe(ForwardMessageViewController.tellomiForwardSteps(items: ["第一条"], comment: nil)), ["内容:第一条"])
    }

    /// F-8：「已转发给 **X**」/「… 和 …」/「… 等 N 个聊天」/「已转发到 **我的收藏**」（只有这个能点开）。
    func testForwardedToastNamesTheChats() throws {
        let lin = TellomiForwardedRecipient(name: "小林", isSavedMessages: false)
        let wang = TellomiForwardedRecipient(name: "小王", isSavedMessages: false)
        let saved = TellomiForwardedRecipient(name: MessageStrings.noteToSelf, isSavedMessages: true)

        XCTAssertNil(TellomiForwardedToast(recipients: []))

        let one = try XCTUnwrap(TellomiForwardedToast(recipients: [lin]))
        XCTAssertEqual(one.text, "Forwarded to 小林")
        XCTAssertEqual(one.boldTexts, ["小林"])
        XCTAssertFalse(one.opensSavedMessages)

        let two = try XCTUnwrap(TellomiForwardedToast(recipients: [lin, wang]))
        XCTAssertEqual(two.text, "Forwarded to 小林 and 小王")
        XCTAssertEqual(two.boldTexts, ["小林", "小王"])

        let many = try XCTUnwrap(TellomiForwardedToast(recipients: [lin, wang, saved]))
        XCTAssertEqual(many.text, "Forwarded to 3 chats, including 小林")
        XCTAssertEqual(many.boldTexts, ["小林"])
        XCTAssertFalse(many.opensSavedMessages)

        let onlySaved = try XCTUnwrap(TellomiForwardedToast(recipients: [saved]))
        XCTAssertEqual(onlySaved.text, "Forwarded to Saved Messages")
        XCTAssertTrue(onlySaved.opensSavedMessages)
    }

    /// F-8：提示条里的名字加粗（ToastView 的 tellomiEmphasize）。
    @MainActor
    func testToastBoldsTheNames() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        hostedWindows.append(window)

        let toast = ToastController(text: "Forwarded to 小林 and 小王")
        toast.tellomiBoldTexts = ["小林", "小王"]
        toast.presentToastView(from: .bottom, of: root.view, inset: 20)

        let toastView = try XCTUnwrap(findToast(in: window))
        let attributed = try XCTUnwrap(toastView.tellomiAttributedTextForTesting)
        let text = attributed.string as NSString
        func weight(at location: Int) -> CGFloat {
            let font = attributed.attribute(.font, at: location, effectiveRange: nil) as? UIFont
            let traits = font?.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
            return (traits?[.weight] as? CGFloat) ?? 0
        }
        XCTAssertGreaterThan(weight(at: text.range(of: "小林").location), weight(at: 0))
        XCTAssertGreaterThan(weight(at: text.range(of: "小王").location), weight(at: text.range(of: "and").location))
    }

    /// 四种语言都有译文（跑在英文下，直接读各语言的表）。
    func testStringsAreTranslated() {
        let expectations: [(String, String, String, String)] = [
            ("FORWARD_MESSAGE_TELLOMI_GRID_SUBTITLE", "选择聊天", "選擇聊天", "選擇聊天"),
            ("FORWARD_MESSAGE_TELLOMI_GRID_NAME_SEPARATOR", "、", "、", "、"),
            ("FORWARD_MESSAGE_TELLOMI_GRID_COMMENT_PLACEHOLDER", "添加消息…", "新增訊息…", "新增訊息…"),
            ("FORWARD_MESSAGE_TELLOMI_GRID_SELECTION_LIMIT_%d", "最多选 %d 个聊天", "最多選 %d 個聊天", "最多選 %d 個聊天"),
            ("FORWARD_MESSAGE_TELLOMI_GRID_SENT_TO_ONE_%@", "已转发给 %@", "已轉寄給 %@", "已轉寄給 %@"),
            ("FORWARD_MESSAGE_TELLOMI_GRID_SENT_TO_TWO_%@_%@", "已转发给 %1$@ 和 %2$@", "已轉寄給 %1$@ 和 %2$@", "已轉寄給 %1$@ 和 %2$@"),
            ("FORWARD_MESSAGE_TELLOMI_GRID_SENT_TO_MANY_%@_%d", "已转发给 %1$@ 等 %2$d 个聊天", "已轉寄給 %1$@ 等 %2$d 個聊天", "已轉寄給 %1$@ 等 %2$d 個聊天"),
            ("FORWARD_MESSAGE_TELLOMI_GRID_SENT_TO_SAVED_%@", "已转发到 %@", "已轉寄到 %@", "已轉寄到 %@"),
        ]
        for (key, zhCN, zhTW, zhHK) in expectations {
            XCTAssertEqual(tableString(key, "zh_CN"), zhCN, key)
            XCTAssertEqual(tableString(key, "zh_TW"), zhTW, key)
            XCTAssertEqual(tableString(key, "zh_HK"), zhHK, key)
            XCTAssertNotNil(tableString(key, "en"), key)
        }
        for key in [
            "FORWARD_MESSAGE_TELLOMI_GRID_SHARE_TO_OTHER_APPS",
            "FORWARD_MESSAGE_TELLOMI_GRID_SECTION_RECENT",
            "FORWARD_MESSAGE_TELLOMI_GRID_SECTION_CHATS",
            "FORWARD_MESSAGE_TELLOMI_GRID_SECTION_CONTACTS",
            "FORWARD_MESSAGE_TELLOMI_GRID_SECTION_GROUPS",
        ] {
            for localization in ["en", "zh_CN", "zh_TW", "zh_HK"] {
                XCTAssertNotNil(tableString(key, localization), "\(key) \(localization)")
            }
        }
    }

    // MARK: - 截图

    /// 截图（TELLOMI_SHOTS=1）：同真机从会话页弹出——初始、选了两个带附言、上拉展开、搜索空查询、搜索结果、深色（查看器）。
    @MainActor
    func testForwardGridScreenshots() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TELLOMI_SHOTS"] == "1", "只在 TELLOMI_SHOTS=1 时截图")
        register()
        let names = ["小林", "王小明", "妈妈", "Alice", "陈老师", "Bob Chen", "阿杰", "林家大小姐的超长名字测试", "小雨", "老周", "张三", "Emily", "李四", "赵六"]
        var addresses: [SignalServiceAddress] = []
        for (index, name) in names.enumerated() {
            addresses.append(makeContactChat(name))
            if index == 3 {
                makeGroupChat("周末爬山小分队")
            }
        }
        let width = hostedScreenWidth()

        let initial = try host()
        try await settle()
        try save(render(initial.window), name: "forward-1-initial.png", width: width)
        initial.grid.tapTargetForTesting(id: contactId(addresses[13]))
        initial.grid.tapTargetForTesting(id: contactId(addresses[12]))
        initial.grid.typeCommentForTesting("你看这个")
        try await settle()
        try save(render(initial.window), name: "forward-2-selected.png", width: width)
        initial.grid.scrollUpForTesting(distance: 2_000)
        try await settle()
        try save(render(initial.window), name: "forward-3-expanded.png", width: width)
        initial.window.isHidden = true

        let search = try host()
        search.grid.tapSearchButtonForTesting()
        try await settle()
        try save(render(search.window), name: "forward-4-search-recent.png", width: width)
        search.grid.typeSearchForTesting("周末")
        try await settle()
        try save(render(search.window), name: "forward-5-search-results.png", width: width)
        search.window.isHidden = true

        let dark = try host(forceDarkTheme: true)
        dark.grid.tapTargetForTesting(id: savedMessagesId)
        try await settle()
        try save(render(dark.window), name: "forward-6-dark-viewer.png", width: width)
        dark.window.isHidden = true
    }

    // MARK: - 搭环境

    private final class Recorder {
        var sent: [(recipients: [MessageRecipient], comment: String?)] = []
        var cancelCount = 0
        var shareCount = 0
        var prefetched: [[ServiceId]] = []
    }

    private struct Hosted {
        let grid: TellomiForwardGridViewController
        let recorder: Recorder
        let window: UIWindow
    }

    /// 同真机：会话页（这里是一个空白页）把网格弹出来，窗口接在真实屏幕上（安全区算进去）。
    @MainActor
    private func host(
        forceDarkTheme: Bool = false,
        canShare: Bool = true,
        sendResult: Bool = true,
        hideCaptionDidChange: (@MainActor (Bool) -> Void)? = nil,
    ) throws -> Hosted {
        let recorder = Recorder()
        var share: (@MainActor (UIView) -> Void)?
        if canShare {
            share = { _ in recorder.shareCount += 1 }
        }
        let grid = TellomiForwardGridViewController(
            forceDarkTheme: forceDarkTheme,
            actions: TellomiForwardGridViewController.Actions(
                send: { items, comment in
                    recorder.sent.append((items.map(\.messageRecipient), comment))
                    return sendResult
                },
                share: share,
                cancel: { recorder.cancelCount += 1 },
                hideCaptionDidChange: hideCaptionDidChange,
            ),
        )
        grid.prefetchIdentityKeys = { recorder.prefetched.append($0) }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let root = UIViewController()
        root.view.backgroundColor = .Signal.background
        window.rootViewController = root
        window.isHidden = false
        root.present(grid, animated: false)
        hostedWindows.append(window)
        window.layoutIfNeeded()
        grid.view.layoutIfNeeded()
        grid.collectionViewForTesting.layoutIfNeeded()
        return Hosted(grid: grid, recorder: recorder, window: window)
    }

    private func hostedScreenWidth() -> CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size.width }.first ?? 402
    }

    @MainActor
    private func visibleCell(_ grid: TellomiForwardGridViewController, id: String) -> TellomiForwardGridCell? {
        grid.collectionViewForTesting.layoutIfNeeded()
        return grid.collectionViewForTesting.visibleCells
            .compactMap { $0 as? TellomiForwardGridCell }
            .first { $0.targetId == id }
    }

    @MainActor
    private func findToast(in view: UIView) -> ToastView? {
        if let toast = view as? ToastView {
            return toast
        }
        for subview in view.subviews {
            if let toast = findToast(in: subview) {
                return toast
            }
        }
        return nil
    }

    private var savedMessagesId: String { contactId(LocalIdentifiers.forUnitTests.aciAddress) }

    private func contactId(_ address: SignalServiceAddress) -> String {
        "contact:" + (address.serviceIdUppercaseString ?? address.phoneNumber ?? "")
    }

    private func register() {
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }
    }

    private var phoneCounter = 0

    /// 一个有名字的联系人 + 与他的会话（默认我发过一条；`incoming` = 只收到过他的 = 消息请求）。
    /// 只用号码建地址：测试环境的假通讯录按号码给名字，带 ACI 的会话地址里没有号码、名字会是「Unknown」。
    @discardableResult
    private func makeContactChat(_ name: String, incoming: Bool = false) -> SignalServiceAddress {
        phoneCounter += 1
        let phoneNumber = String(format: "+86138%08d", phoneCounter)
        let address = SignalServiceAddress(phoneNumber: phoneNumber)
        (SSKEnvironment.shared.contactManagerRef as! FakeContactsManager).mockSignalAccounts[phoneNumber] = SignalAccount(
            recipientPhoneNumber: phoneNumber,
            recipientServiceId: nil,
            multipleAccountLabelText: nil,
            cnContactId: nil,
            givenName: name,
            familyName: "",
            nickname: "",
            fullName: name,
            contactAvatarHash: nil,
        )
        makeChat(with: address, incoming: incoming)
        return address
    }

    private func makeChat(with address: SignalServiceAddress, incoming: Bool = false) {
        write { tx in
            let thread = TSContactThread.getOrCreateThread(withContactAddress: address, transaction: tx)
            if incoming {
                let factory = IncomingMessageFactory()
                factory.threadCreator = { _ in thread }
                // 只有号码的会话取不到 ACI；作者是谁不影响「收到过消息 = 消息请求」的判断
                factory.authorAciBuilder = { _ in Aci.randomForTesting() }
                _ = factory.create(transaction: tx)
            } else {
                let factory = OutgoingMessageFactory()
                factory.threadCreator = { _ in thread }
                _ = factory.create(transaction: tx)
            }
        }
    }

    /// 一个群（默认我在里面、有一条建群消息所以在聊天列表里）。
    @discardableResult
    private func makeGroupChat(_ name: String, includingMe: Bool = true, visible: Bool = true) -> TSGroupThread {
        write { tx in
            let other = SignalServiceAddress(Aci.randomForTesting())
            let members = includingMe ? [LocalIdentifiers.forUnitTests.aciAddress, other] : [other]
            let thread = try! GroupManager.createGroupForTests(
                members: members,
                shouldInsertInfoMessage: includingMe && visible,
                name: name,
                transaction: tx,
            )
            if includingMe {
                // 自己建的群已在资料白名单里；不加的话「有建群消息、没接受」会被当成消息请求
                SSKEnvironment.shared.profileManagerRef.addGroupId(toProfileWhitelist: thread.groupId, userProfileWriter: .localUser, transaction: tx)
            }
            if !includingMe, visible {
                // 退出的群：聊天列表里还在（有过消息），但我已不是成员
                try! tx.database.execute(
                    sql: "UPDATE model_TSThread SET shouldThreadBeVisible = 1, lastInteractionRowId = 100000 WHERE uniqueId = ?",
                    arguments: [thread.uniqueId],
                )
            }
            return thread
        }
    }

    /// 用例里的头像：彩色圆 + 名字第一个字；我的收藏是强调色圆 + 书签（同 #1174 的样子）
    private static func placeholderAvatar(for target: TellomiForwardTarget) -> UIImage {
        let size = CGSize(width: 120, height: 120)
        let palette: [UIColor] = [.systemBlue, .systemGreen, .systemOrange, .systemPink, .systemPurple, .systemTeal, .systemIndigo]
        let color = target.isSavedMessages ? UIColor.Signal.accent : palette[abs(target.id.hashValue) % palette.count]
        return UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            if target.isSavedMessages {
                let symbol = UIImage(systemName: "bookmark.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .semibold))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                symbol?.draw(in: CGRect(x: 36, y: 34, width: 48, height: 52))
            } else {
                let text = String(target.shortName.prefix(1)) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 52, weight: .medium), .foregroundColor: UIColor.white]
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2), withAttributes: attributes)
            }
        }
    }

    @MainActor
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @MainActor
    private func render(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// 截图里一点（窗口坐标）的颜色，按 sRGB 取分量
    private func pixel(_ image: UIImage, at point: CGPoint) -> RGB {
        guard let cgImage = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return RGB(red: -1, green: -1, blue: -1)
        }
        let x = Int((point.x * image.scale).rounded(.down))
        let y = Int((point.y * image.scale).rounded(.down))
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                )
            else {
                return
            }
            // 把要取的那一个像素挪到 1×1 画布的原点（CG 的 y 从下往上）
            context.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
        }
        return RGB(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255)
    }

    private func components(_ color: UIColor, traits: UITraitCollection) -> RGB {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return RGB(red: red, green: green, blue: blue)
    }

    private func distance(_ lhs: RGB, _ rhs: RGB) -> CGFloat {
        max(abs(lhs.red - rhs.red), abs(lhs.green - rhs.green), abs(lhs.blue - rhs.blue))
    }

    private struct RGB: CustomStringConvertible {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat

        var description: String {
            String(format: "rgb(%.3f, %.3f, %.3f)", red, green, blue)
        }
    }

    private func save(_ image: UIImage, name: String, width: CGFloat) throws {
        let root = ProcessInfo.processInfo.environment["TELLOMI_SHOTS_DIR"] ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: root).appendingPathComponent("\(Int(width))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }
}

/// 直接读某个语言的 Localizable.strings（测试跑在英文下，要看译文有没有写进去）。
private func tableString(_ key: String, _ localization: String) -> String? {
    guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization) else {
        return nil
    }
    return NSDictionary(contentsOfFile: path)?[key] as? String
}
