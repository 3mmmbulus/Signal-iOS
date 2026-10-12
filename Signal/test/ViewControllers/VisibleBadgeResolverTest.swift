//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import XCTest

import SignalServiceKit
@testable import Signal
@testable import SignalUI

class VisibleBadgeResolverTest: XCTestCase {

    typealias Badge = ProfileBadgesSnapshot.Badge
    typealias SwitchType = VisibleBadgeResolver.SwitchType

    func testVisibleBadgeIds() {
        struct TestCase {
            // The state of the user's badges, cached when the view is first presented.
            var profileBadgeIds: [String]
            var areBadgesVisible: Bool

            // The default configuration for the switch, computed when the view is
            // first presented.
            var newBadgeId: String
            var switchType: SwitchType
            var defaultSwitchValue: Bool

            // The action to perform against the user's badges, applied when redeeming
            // a gift or dismissing the sheet.
            var selectedSwitchValue: Bool
            var areBadgesVisibleWhenUpdating: Bool?
            var newVisibleBadgeIds: [String]

            static func forFirstBadge(_ badgeId: String, selectedSwitchValue: Bool) -> Self {
                Self(
                    profileBadgeIds: [],
                    areBadgesVisible: false,
                    newBadgeId: badgeId,
                    switchType: .displayOnProfile,
                    defaultSwitchValue: true,
                    selectedSwitchValue: selectedSwitchValue,
                    newVisibleBadgeIds: selectedSwitchValue ? [badgeId] : [],
                )
            }
        }
        let testCases: [TestCase] = [
            // You don't have any badges.
            // Show "Display on Profile" and default the switch to on.
            .forFirstBadge("GIFT", selectedSwitchValue: false),
            .forFirstBadge("GIFT", selectedSwitchValue: true),
            .forFirstBadge("R_LOW", selectedSwitchValue: false),
            .forFirstBadge("R_LOW", selectedSwitchValue: true),
            .forFirstBadge("BOOST", selectedSwitchValue: false),
            .forFirstBadge("BOOST", selectedSwitchValue: true),

            // You already have a Sustainer badge on your profile and are redeeming a gift.
            // Show "Make Featured Badge" and default the switch to off.
            TestCase(
                profileBadgeIds: ["R_LOW"],
                areBadgesVisible: true,
                newBadgeId: "GIFT",
                switchType: .makeFeaturedBadge,
                defaultSwitchValue: false,
                selectedSwitchValue: false,
                newVisibleBadgeIds: ["R_LOW", "GIFT"],
            ),

            // You already have a Boost badge on your profile and are redeeming a gift.
            // Show "Make Featured Badge" and default the switch to on.
            TestCase(
                profileBadgeIds: ["BOOST"],
                areBadgesVisible: true,
                newBadgeId: "GIFT",
                switchType: .makeFeaturedBadge,
                defaultSwitchValue: true,
                selectedSwitchValue: true,
                newVisibleBadgeIds: ["GIFT", "BOOST"],
            ),

            // You already have a Gift badge on your profile and are buying a subscription.
            // Show "Make Featured Badge" and default the switch to on.
            TestCase(
                profileBadgeIds: ["GIFT"],
                areBadgesVisible: true,
                newBadgeId: "R_LOW",
                switchType: .makeFeaturedBadge,
                defaultSwitchValue: true,
                selectedSwitchValue: false,
                newVisibleBadgeIds: ["GIFT", "R_LOW"],
            ),

            // You already have a Boost badge on your profile and purchase another one.
            // Don't show any switch.
            TestCase(
                profileBadgeIds: ["BOOST"],
                areBadgesVisible: true,
                newBadgeId: "BOOST",
                switchType: .none,
                defaultSwitchValue: true,
                selectedSwitchValue: true,
                newVisibleBadgeIds: ["BOOST"],
            ),

            // You already have a Boost badge that you've hidden, and you purchase another one.
            // Show "Display on Profile".
            TestCase(
                profileBadgeIds: ["BOOST"],
                areBadgesVisible: false,
                newBadgeId: "BOOST",
                switchType: .displayOnProfile,
                defaultSwitchValue: true,
                selectedSwitchValue: false,
                newVisibleBadgeIds: [],
            ),

            // You have a Boost and Sustainer badge visible on your profile, and you purchase a Boost.
            // Don't show any switch.
            TestCase(
                profileBadgeIds: ["BOOST", "R_LOW"],
                areBadgesVisible: true,
                newBadgeId: "BOOST",
                switchType: .none,
                defaultSwitchValue: true,
                selectedSwitchValue: true,
                newVisibleBadgeIds: ["BOOST", "R_LOW"],
            ),

            // EDGE CASES THAT REQUIRE BADGE UPDATES FROM IPAD / BADGE EXPIRATIONS

            // You have hidden Boost/Gift badges, you purchase a Boost, and you unhide badges on another device.
            // Selecting "off" for "Display on Profile" keeps the badge visible but no longer features it.
            TestCase(
                profileBadgeIds: ["BOOST", "GIFT"],
                areBadgesVisible: false,
                newBadgeId: "BOOST",
                switchType: .displayOnProfile,
                defaultSwitchValue: true,
                selectedSwitchValue: false,
                areBadgesVisibleWhenUpdating: true,
                newVisibleBadgeIds: ["GIFT", "BOOST"],
            ),

            // You have a hidden Gift badge, you purchase a Boost, and you unhide badges on another device.
            // Selecting "off" for "Display on Profile" will result in the new badge being shown.
            TestCase(
                profileBadgeIds: ["GIFT"],
                areBadgesVisible: false,
                newBadgeId: "BOOST",
                switchType: .displayOnProfile,
                defaultSwitchValue: true,
                selectedSwitchValue: false,
                areBadgesVisibleWhenUpdating: true,
                newVisibleBadgeIds: ["GIFT", "BOOST"],
            ),

            // You have a visible Gift badge, you purchase a Boost, and you hide badges on another device.
            // Selecting "off" for "Make Featured Badge" will result in all badges being hidden.
            TestCase(
                profileBadgeIds: ["GIFT"],
                areBadgesVisible: true,
                newBadgeId: "BOOST",
                switchType: .makeFeaturedBadge,
                defaultSwitchValue: true,
                selectedSwitchValue: false,
                areBadgesVisibleWhenUpdating: false,
                newVisibleBadgeIds: [],
            ),

            // You have a visible Gift badge, you purchase a Boost, and you hide badges on another device.
            // Selecting "on" for "Make Featured Badge" will result in all badges being visible.
            TestCase(
                profileBadgeIds: ["GIFT"],
                areBadgesVisible: true,
                newBadgeId: "BOOST",
                switchType: .makeFeaturedBadge,
                defaultSwitchValue: true,
                selectedSwitchValue: true,
                areBadgesVisibleWhenUpdating: false,
                newVisibleBadgeIds: ["BOOST", "GIFT"],
            ),
        ]

        for testCase in testCases {
            let initialResolver = VisibleBadgeResolver(
                badgesSnapshot: ProfileBadgesSnapshot(
                    existingBadges: testCase.profileBadgeIds.map {
                        .init(id: $0, isVisible: testCase.areBadgesVisible)
                    },
                ),
            )

            let switchType = initialResolver.switchType(for: testCase.newBadgeId)
            XCTAssertEqual(switchType, testCase.switchType, "\(testCase)")

            let defaultSwitchValue = initialResolver.switchDefault(for: testCase.newBadgeId)
            XCTAssertEqual(defaultSwitchValue, testCase.defaultSwitchValue, "\(testCase)")

            // If no switch is shown, the default value must match the selected value.
            if switchType == .none {
                XCTAssertEqual(testCase.selectedSwitchValue, testCase.defaultSwitchValue, "\(testCase)")
            }

            // a short while later

            let updateResolver = VisibleBadgeResolver(
                badgesSnapshot: ProfileBadgesSnapshot(
                    existingBadges: testCase.profileBadgeIds.map {
                        .init(id: $0, isVisible: testCase.areBadgesVisibleWhenUpdating ?? testCase.areBadgesVisible)
                    },
                ),
            )

            let visibleBadgeIds = updateResolver.visibleBadgeIds(
                adding: testCase.newBadgeId,
                isVisibleAndFeatured: testCase.selectedSwitchValue,
            )
            XCTAssertEqual(visibleBadgeIds, testCase.newVisibleBadgeIds, "\(testCase)")
        }

    }

    func testCurrentlyVisibleBadgeIds() {
        let badgeA = Badge(id: "A", isVisible: true)
        let badgeB = Badge(id: "B", isVisible: true)
        let badgeC = Badge(id: "C", isVisible: false)
        let badgeD = Badge(id: "D", isVisible: false)

        let testCases: [([Badge], [String])] = [
            ([], []),
            ([badgeA], ["A"]),
            ([badgeA, badgeB], ["A", "B"]),
            ([badgeC], []),
            ([badgeC, badgeD], []),
            ([badgeA, badgeC], ["A"]),
            ([badgeC, badgeA], ["A"]),
            ([badgeA, badgeB, badgeC], ["A", "B"]),
            ([badgeA, badgeC, badgeB], ["A", "B"]),
            ([badgeC, badgeA, badgeD], ["A"]),
        ]

        for (existingBadges, visibleBadgeIds) in testCases {
            let visibleBadgeResolver = VisibleBadgeResolver(
                badgesSnapshot: ProfileBadgesSnapshot(existingBadges: existingBadges),
            )
            XCTAssertEqual(visibleBadgeResolver.currentlyVisibleBadgeIds(), visibleBadgeIds)
        }
    }

}

// MARK: - Tellomi（tellomi/tellomi#1174）

/// 直接读某个语言的 Localizable.strings（测试跑在英文下，要看译文有没有写进去）。
private func localizedString(_ key: String, _ localization: String) -> String? {
    guard let path = Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization) else {
        return nil
    }
    return NSDictionary(contentsOfFile: path)?[key] as? String
}

/// 「备忘录」改名「我的收藏」、设置页入口用书签图标（需求 official-account-and-saved §3.2）。
class TellomiSavedMessagesNamingTest: XCTestCase {

    func testItIsCalled我的收藏InChineseAndSavedMessagesInEnglish() {
        XCTAssertEqual(localizedString("NOTE_TO_SELF", "zh_CN"), "我的收藏")
        XCTAssertEqual(localizedString("NOTE_TO_SELF", "zh_HK"), "我的收藏")
        XCTAssertEqual(localizedString("NOTE_TO_SELF", "zh_TW"), "我的收藏")
        XCTAssertEqual(localizedString("NOTE_TO_SELF", "en"), "Saved Messages")
    }

    func testTheSettingsEntryUsesTheBookmarkAssetAndItShipsInTheApp() {
        XCTAssertEqual(Theme.iconName(.settingsTellomiSavedMessages, isDarkThemeEnabled: false), "tellomi-bookmark-resizable")
        XCTAssertNotNil(UIImage(named: "tellomi-bookmark-resizable"))
    }
}

/// 长按「收藏」与转发面板置顶（需求 official-account-and-saved §3.2 第 3 条）。
class TellomiSavedMessagesForwardTest: SignalBaseTest {

    private func contact(_ address: SignalServiceAddress, _ name: String) -> ContactConversationItem {
        return ContactConversationItem(
            address: address,
            isBlocked: false,
            disappearingMessagesConfig: nil,
            comparableName: ComparableDisplayName(address: address, displayName: .username(name), config: .current()),
        )
    }

    private func addresses(_ recent: [RecentConversationItem]) -> [SignalServiceAddress] {
        return recent.compactMap { item in
            if case .contact(let contact) = item.backingItem {
                return contact.address
            }
            return nil
        }
    }

    func testSavedMessagesIsPinnedFirstAndListedOnlyOnce() {
        let selfAddress = SignalServiceAddress(Aci.randomForTesting())
        let buddy = SignalServiceAddress(Aci.randomForTesting())
        let other = SignalServiceAddress(Aci.randomForTesting())

        var recent = [
            RecentConversationItem(backingItem: .contact(contact(buddy, "buddy"))),
            RecentConversationItem(backingItem: .contact(contact(selfAddress, "me"))),
        ]
        var contacts = [contact(selfAddress, "me"), contact(other, "other")]

        TellomiSavedMessagesConversationItem.pinFirst(contact(selfAddress, "me"), recent: &recent, contacts: &contacts)

        XCTAssertEqual(addresses(recent), [selfAddress, buddy])
        XCTAssertEqual(contacts.map(\.address), [other])
    }

    func testTheSaveStringsAreTranslated() {
        XCTAssertEqual(localizedString("CONTEXT_MENU_FORWARD_MESSAGE_TELLOMI_SAVE", "zh_CN"), "收藏")
        XCTAssertEqual(localizedString("FORWARD_MESSAGE_TELLOMI_SAVED_TOAST", "zh_CN"), "已收藏，点击查看")
        XCTAssertEqual(localizedString("CONTEXT_MENU_FORWARD_MESSAGE_TELLOMI_SAVE", "zh_TW"), "收藏")
        XCTAssertNotNil(localizedString("CONTEXT_MENU_FORWARD_MESSAGE_TELLOMI_SAVE", "ja"))

        XCTAssertEqual(TellomiSavedMessagesStrings.save, "Save")
        XCTAssertEqual(TellomiSavedMessagesStrings.savedToast, "Saved to Saved Messages. Tap to view.")
    }
}

/// 删除「我的收藏」的确认文案（需求 official-account-and-saved §3.2「删除」）。
class TellomiSavedMessagesDeleteTest: SignalBaseTest {

    private let localAci = Aci.randomForTesting()

    override func setUp() {
        super.setUp()
        write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: LocalIdentifiers(aci: localAci, pni: Pni.randomForTesting(), phoneNumber: "+16505550100"),
                tx: tx,
            )
        }
    }

    func testOnlySavedMessagesOnItsOwnGetsItsOwnWording() {
        let savedMessages = TSContactThread(contactAddress: SignalServiceAddress(localAci))
        let buddy = TSContactThread(contactAddress: SignalServiceAddress(Aci.randomForTesting()))

        let alone = TellomiSavedMessagesStrings.deleteConfirmation(for: [savedMessages], hasLinkedDevices: false)
        XCTAssertEqual(alone?.title, "Delete Saved Messages?")
        XCTAssertEqual(alone?.message, "Everything in Saved Messages will be deleted from this device. This can't be undone.")
        XCTAssertEqual(
            TellomiSavedMessagesStrings.deleteConfirmation(for: [savedMessages], hasLinkedDevices: true)?.message,
            "Everything in Saved Messages will be deleted from this device and your linked devices. This can't be undone.",
        )
        XCTAssertNil(TellomiSavedMessagesStrings.deleteConfirmation(for: [buddy], hasLinkedDevices: false))
        XCTAssertNil(TellomiSavedMessagesStrings.deleteConfirmation(for: [savedMessages, buddy], hasLinkedDevices: false))
    }

    func testTheDeleteWordingIsTranslated() {
        XCTAssertEqual(localizedString("CONVERSATION_DELETE_CONFIRMATION_ALERT_TITLE_TELLOMI_SAVED_MESSAGES", "zh_CN"), "删除「我的收藏」？")
        XCTAssertEqual(
            localizedString("CONVERSATION_DELETE_CONFIRMATION_ALERT_MESSAGE_TELLOMI_SAVED_MESSAGES_LINKED_DEVICES", "zh_CN"),
            "「我的收藏」里的内容会从这台设备和已关联设备上删除，无法恢复。",
        )
        XCTAssertEqual(localizedString("CONVERSATION_DELETE_CONFIRMATION_ALERT_TITLE_TELLOMI_SAVED_MESSAGES", "zh_HK"), "刪除「我的收藏」？")
        XCTAssertEqual(
            localizedString("CONVERSATION_DELETE_CONFIRMATION_ALERT_MESSAGE_TELLOMI_SAVED_MESSAGES", "zh_TW"),
            "「我的收藏」裡的內容會從這台裝置上刪除，無法復原。",
        )
    }
}
