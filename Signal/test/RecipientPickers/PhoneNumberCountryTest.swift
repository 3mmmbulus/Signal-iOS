//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalServiceKit
import XCTest

@testable import Signal
@testable import SignalUI

final class PhoneNumberCountryTest: SignalBaseTest {
    func testCountryCodesForSearchTerm() {
        func countryCodes(forSearchTerm searchTerm: String?) -> [String] {
            return PhoneNumberCountry.buildCountries(searchText: searchTerm).map(\.countryCode)
        }
        // Empty search.
        XCTAssertGreaterThan(countryCodes(forSearchTerm: nil).count, 30)
        XCTAssertGreaterThan(countryCodes(forSearchTerm: "").count, 30)
        XCTAssertGreaterThan(countryCodes(forSearchTerm: " ").count, 30)

        // Searches with no results.
        XCTAssertEqual(countryCodes(forSearchTerm: " . ").count, 0)
        XCTAssertEqual(countryCodes(forSearchTerm: " XXXXX ").count, 0)
        XCTAssertEqual(countryCodes(forSearchTerm: " ! ").count, 0)

        // Search by country code.
        XCTAssertEqual(countryCodes(forSearchTerm: "GB"), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: "gb"), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: "GB "), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: " GB"), ["GB"])
        XCTAssert(countryCodes(forSearchTerm: " G").contains("GB"))
        XCTAssertFalse(countryCodes(forSearchTerm: " B").contains("GB"))

        // Search by country name.
        XCTAssertEqual(countryCodes(forSearchTerm: "united kingdom"), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: " UNITED KINGDOM "), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: " UNITED KING "), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: " UNI KING "), ["GB"])
        XCTAssertEqual(countryCodes(forSearchTerm: " u k "), ["GB"])
        XCTAssert(countryCodes(forSearchTerm: " u").contains("GB"))
        XCTAssert(countryCodes(forSearchTerm: " k").contains("GB"))
        XCTAssertFalse(countryCodes(forSearchTerm: " m").contains("GB"))

        // Search by calling code.
        XCTAssert(countryCodes(forSearchTerm: " +44 ").contains("GB"))
        XCTAssert(countryCodes(forSearchTerm: " 44 ").contains("GB"))
        XCTAssert(countryCodes(forSearchTerm: " +4 ").contains("GB"))
        XCTAssert(countryCodes(forSearchTerm: " 4 ").contains("GB"))
        XCTAssertFalse(countryCodes(forSearchTerm: " +123 ").contains("GB"))
        XCTAssertFalse(countryCodes(forSearchTerm: " +444 ").contains("GB"))
    }
}

// MARK: - Tellomi：底栏「好友」页

/// 「好友」页的选人配置、顶部入口、邀请文字、文案（都叫「好友」）。
final class TellomiFriendsTabTest: SignalBaseTest {
    func testFriendsListOnlyHasPeopleAndDoesNotNudgeForContactsAccessWithoutCDSI() {
        let recipientPicker = RecipientPickerViewController()
        TellomiFriendsViewController.configure(recipientPicker)
        XCTAssertEqual(recipientPicker.groupsToShow, .noGroups)
        XCTAssertTrue(recipientPicker.shouldHideLocalRecipient)
        XCTAssertFalse(recipientPicker.shouldShowNewGroup)
        XCTAssertFalse(recipientPicker.shouldShowInvites)
        XCTAssertTrue(recipientPicker.allowsAddByAddress)
        XCTAssertTrue(recipientPicker.tellomiSkipsNoContactsView)
        XCTAssertEqual(recipientPicker.tellomiHidesContactAccessReminder, !TSConstants.cdsiAvailable)
    }

    func testComposeKeepsUpstreamDefaults() {
        let recipientPicker = RecipientPickerViewController()
        XCTAssertTrue(recipientPicker.tellomiExtraStaticItems.isEmpty)
        XCTAssertFalse(recipientPicker.tellomiHidesContactAccessReminder)
        XCTAssertFalse(recipientPicker.tellomiSkipsNoContactsView)
        XCTAssertNil(recipientPicker.tellomiNoContactsText)
    }

    func testFriendsPageHasScanAndInviteRows() {
        let viewController = TellomiFriendsViewController()
        viewController.loadViewIfNeeded()
        XCTAssertEqual(viewController.recipientPicker.tellomiExtraStaticItems.count, 2)
        XCTAssertEqual(viewController.title, HomeTabBarController.Tabs.friends.title)
        XCTAssertNil(viewController.navigationItem.rightBarButtonItem)
    }

    func testInviteTextEndsWithTheDownloadLink() {
        let text = TellomiFriendsViewController.inviteText()
        XCTAssertTrue(text.hasPrefix(OWSLocalizedString("SMS_INVITE_BODY", comment: "")), text)
        XCTAssertTrue(text.hasSuffix(" https://tellomi.app/download/"), text)
    }

    func testStringsSayFriendsNotContacts() throws {
        let expected: [(String, String, String)] = [
            ("en", "Invite Friends", "No friends on Tellomi yet."),
            ("zh_CN", "邀请好友", "还没有 Tellomi 好友。"),
            ("zh_HK", "邀請好友", "還沒有 Tellomi 好友。"),
            ("zh_TW", "邀請好友", "還沒有 Tellomi 好友。"),
        ]
        for (localization, invite, empty) in expected {
            let path = try XCTUnwrap(Bundle.main.path(forResource: localization, ofType: "lproj"), localization)
            let bundle = try XCTUnwrap(Bundle(path: path), localization)
            XCTAssertEqual(bundle.localizedString(forKey: "TELLOMI_FRIENDS_INVITE_ROW", value: nil, table: nil), invite, localization)
            XCTAssertEqual(bundle.localizedString(forKey: "TELLOMI_FRIENDS_EMPTY", value: nil, table: nil), empty, localization)
        }
    }
}
