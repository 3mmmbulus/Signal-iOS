//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Contacts
import LibSignalClient
import XCTest

@testable import Signal
@testable import SignalServiceKit

class OWSContactsManagerTest: SignalBaseTest {
    private let dbV2: InMemoryDB = .init()

    private let mockUsernameLookupMananger: MockUsernameLookupManager = .init()
    private let mockNicknameManager = MockNicknameManager()
    private let mockRecipientDatabaseTable = RecipientDatabaseTable()

    override func setUp() {
        super.setUp()

        // Create local account.
        SSKEnvironment.shared.databaseStorageRef.write { tx in
            (DependenciesBridge.shared.registrationStateChangeManager as! RegistrationStateChangeManagerImpl).registerForTests(
                localIdentifiers: .forUnitTests,
                tx: tx,
            )
        }

        // Replace the fake contacts manager with the real one just for this test.
        SSKEnvironment.shared.setContactManagerForUnitTests(makeContactsManager())
    }

    override func tearDown() {
        mockUsernameLookupMananger.clearAllUsernames()
        super.tearDown()
    }

    private func makeContactsManager() -> OWSContactsManager {
        return OWSContactsManager(
            appReadiness: AppReadinessMock(),
            nicknameManager: mockNicknameManager,
            notificationPreferencesManager: NotificationPreferencesManager(),
            recipientDatabaseTable: mockRecipientDatabaseTable,
            usernameLookupManager: mockUsernameLookupMananger,
        )
    }

    private func makeAndInsertRecipient(address: SignalServiceAddress) -> SignalRecipient {
        return self.dbV2.write { tx in
            return try! SignalRecipient.insertRecord(aci: address.aci, phoneNumber: address.e164, tx: tx)
        }
    }

    private func createRecipients(_ serviceIds: [ServiceId]) {
        let recipientFetcher = DependenciesBridge.shared.recipientFetcher
        let recipientManager = DependenciesBridge.shared.recipientManager
        self.dbV2.write { tx in
            for serviceId in serviceIds {
                var recipient = recipientFetcher.fetchOrCreate(serviceId: serviceId, tx: tx)
                recipientManager.markAsRegisteredAndSave(
                    &recipient,
                    shouldUpdateStorageService: false,
                    tx: tx,
                )
            }
        }
    }

    private func createAccounts(_ accounts: [SignalAccount]) {
        self.dbV2.write { transaction in
            for account in accounts {
                account.anyInsert(transaction: transaction)
            }
        }
    }

    private func makeAccount(
        serviceId: ServiceId,
        phoneNumber: E164,
        fullName: String,
    ) -> SignalAccount {
        let parts = fullName.components(separatedBy: " ")
        return SignalAccount(
            recipientPhoneNumber: phoneNumber.stringValue,
            recipientServiceId: serviceId,
            multipleAccountLabelText: "home",
            cnContactId: nil,
            givenName: parts.first!,
            familyName: parts.dropFirst().first ?? "",
            nickname: "",
            fullName: fullName,
            contactAvatarHash: nil,
        )
    }

    private func makeUserProfile(givenName: String, familyName: String) -> OWSUserProfile {
        return OWSUserProfile(
            id: nil,
            uniqueId: "",
            serviceIdString: nil,
            phoneNumber: nil,
            avatarFileName: nil,
            avatarUrlPath: nil,
            profileKey: nil,
            givenName: givenName,
            familyName: familyName,
            bio: nil,
            bioEmoji: nil,
            badges: [],
            lastFetchDate: nil,
            lastMessagingDate: nil,
            isPhoneNumberShared: nil,
            hasPaymentAddress: nil,
        )
    }

    // MARK: - Display Names

    func testGetDisplayNamesWithNicknames() throws {
        let aliceAddress = SignalServiceAddress(phoneNumber: "+16505550101")
        let bobAddress = SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550102")

        let aliceRecipient = makeAndInsertRecipient(address: aliceAddress)
        let bobRecipient = makeAndInsertRecipient(address: bobAddress)

        let aliceRecipientRowID = try XCTUnwrap(aliceRecipient.id)
        let bobRecipientRowID = try XCTUnwrap(bobRecipient.id)

        let aliceNickname = NicknameRecord(
            recipientRowID: aliceRecipientRowID,
            givenName: "Alice",
            familyName: "Doe",
            note: nil,
        )
        let bobNickname = NicknameRecord(
            recipientRowID: bobRecipientRowID,
            givenName: "Bob",
            familyName: nil,
            note: nil,
        )

        self.dbV2.write { tx in
            mockNicknameManager.insert(aliceNickname, tx: tx)
            mockNicknameManager.insert(bobNickname, tx: tx)
        }

        self.dbV2.read { tx in
            let contactsManager = SSKEnvironment.shared.contactManagerRef as! OWSContactsManager
            let actual = contactsManager.displayNames(
                for: [aliceAddress, bobAddress],
                tx: tx,
            ).map { $0.resolvedValue() }
            let expected = ["Alice Doe", "Bob"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testGetDisplayNamesWithCachedContactNames() {
        let addresses = [
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550100"),
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550101"),
        ]
        createRecipients(addresses.map { $0.serviceId! })
        createAccounts(zip(addresses, ["Alice Aliceson", "Bob Bobson"]).map { address, name in
            makeAccount(serviceId: address.serviceId!, phoneNumber: address.e164!, fullName: name)
        })

        self.dbV2.read { transaction in
            let contactsManager = SSKEnvironment.shared.contactManagerRef as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, tx: transaction).map { $0.resolvedValue() }
            let expected = ["Alice Aliceson (home)", "Bob Bobson (home)"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testGetDisplayNamesWithProfileFullNames() {
        let addresses = [SignalServiceAddress.randomForTesting(), SignalServiceAddress.randomForTesting()]
        (SSKEnvironment.shared.profileManagerRef as! OWSFakeProfileManager).fakeUserProfiles = [
            addresses[0]: makeUserProfile(givenName: "Alice", familyName: "Aliceson"),
            addresses[1]: makeUserProfile(givenName: "Bob", familyName: "Bobson"),
        ]
        self.dbV2.read { transaction in
            let contactsManager = SSKEnvironment.shared.contactManagerRef as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, tx: transaction).map { $0.resolvedValue() }
            let expected = ["Alice Aliceson", "Bob Bobson"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testGetDisplayNamesWithPhoneNumbers() {
        let addresses = [
            SignalServiceAddress(phoneNumber: "+17035559900"),
            SignalServiceAddress(phoneNumber: "+17035559901"),
        ]
        // Prevent default fake name from being used.
        (SSKEnvironment.shared.profileManagerRef as! OWSFakeProfileManager).fakeUserProfiles = [:]
        self.dbV2.read { transaction in
            let contactsManager = SSKEnvironment.shared.contactManagerRef as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, tx: transaction).map { $0.resolvedValue() }
            let expected = ["+1 703-555-9900", "+1 703-555-9901"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testGetDisplayNamesWithUserNames() {
        let aliceAci = Aci.randomForTesting()
        let bobAci = Aci.randomForTesting()

        let addresses = [SignalServiceAddress(aliceAci), SignalServiceAddress(bobAci)]

        // Store some fake usernames.

        dbV2.write { transaction in
            mockUsernameLookupMananger.saveUsername("alice", forAci: aliceAci, transaction: transaction)
            mockUsernameLookupMananger.saveUsername("bob", forAci: bobAci, transaction: transaction)
        }

        // Prevent default fake names from being used.
        (SSKEnvironment.shared.profileManagerRef as! OWSFakeProfileManager).fakeUserProfiles = [:]

        dbV2.read { transaction in
            let contactsManager = SSKEnvironment.shared.contactManagerRef as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, tx: transaction).map { $0.resolvedValue() }
            let expected = ["alice", "bob"]
            XCTAssertEqual(actual, expected)
        }
    }

    /// Tellomi（tellomi/tellomi#1106 第三刀，ADR-0066 §六）：只能拿用户名兜底时，`.01` 结尾的去掉后缀显示，
    /// 别的后缀完整显示——`kaixin.57` 必须显示成 `kaixin.57`，不能冒充 `kaixin`。
    /// 显示一律小写（§6.1b，owner 2026-09-27）：老数据里的 `KaiXin.01` 显示成 `kaixin`，存的仍是原样。
    func testGetDisplayNamesWithTellomiUsernames() {
        let acis = [Aci.randomForTesting(), Aci.randomForTesting(), Aci.randomForTesting()]
        let addresses = acis.map { SignalServiceAddress($0) }

        dbV2.write { transaction in
            mockUsernameLookupMananger.saveUsername("kaixin.01", forAci: acis[0], transaction: transaction)
            mockUsernameLookupMananger.saveUsername("KaiXin.01", forAci: acis[1], transaction: transaction)
            mockUsernameLookupMananger.saveUsername("kaixin.57", forAci: acis[2], transaction: transaction)
        }

        // Prevent default fake names from being used.
        (SSKEnvironment.shared.profileManagerRef as! OWSFakeProfileManager).fakeUserProfiles = [:]

        dbV2.read { transaction in
            let contactsManager = SSKEnvironment.shared.contactManagerRef as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, tx: transaction).map { $0.resolvedValue() }
            XCTAssertEqual(actual, ["kaixin", "kaixin", "kaixin.57"])
            // 只改显示：存的仍是完整用户名
            XCTAssertEqual(mockUsernameLookupMananger.fetchUsername(forAci: acis[0], transaction: transaction), "kaixin.01")
        }
    }

    func testGetDisplayNamesUnknown() {
        let addresses = [SignalServiceAddress.randomForTesting(), SignalServiceAddress.randomForTesting()]

        // Intentionally do not set any mock usernames. Additionally, prevent
        // default fake names from being used.
        (SSKEnvironment.shared.profileManagerRef as! OWSFakeProfileManager).fakeUserProfiles = [:]

        dbV2.read { transaction in
            let contactsManager = SSKEnvironment.shared.contactManagerRef as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, tx: transaction).map { $0.resolvedValue() }
            let expected = ["Unknown", "Unknown"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testGetDisplayNamesMixed() throws {
        let aliceAci = Aci.randomForTesting()
        let aliceAddress = SignalServiceAddress(serviceId: aliceAci, phoneNumber: "+16505550100")
        let aliceAccount = makeAccount(serviceId: aliceAci, phoneNumber: aliceAddress.e164!, fullName: "Alice Aliceson")
        createRecipients([aliceAci])
        createAccounts([aliceAccount])

        let bobAddress = SignalServiceAddress.randomForTesting()
        (SSKEnvironment.shared.profileManagerRef as! OWSFakeProfileManager).fakeUserProfiles = [
            bobAddress: makeUserProfile(givenName: "Bob", familyName: "Bobson"),
        ]

        let carolAddress = SignalServiceAddress(phoneNumber: "+17035559900")

        let daveAci = Aci.randomForTesting()
        let daveAddress = SignalServiceAddress(daveAci)
        dbV2.write { transaction in
            mockUsernameLookupMananger.saveUsername("dave", forAci: daveAci, transaction: transaction)
        }

        let eveAddress = SignalServiceAddress.randomForTesting()

        let feliciaAci = Aci.randomForTesting()
        let feliciaAddress = SignalServiceAddress(serviceId: feliciaAci, phoneNumber: "+16505550109")
        // Test that it doesn't show this account name
        let feliciaProfileName = UUID().uuidString
        let feliciaAccount = makeAccount(serviceId: feliciaAci, phoneNumber: feliciaAddress.e164!, fullName: feliciaProfileName)
        createAccounts([feliciaAccount])
        let feliciaRecipient = makeAndInsertRecipient(address: feliciaAddress)
        let feliciaRowID = try XCTUnwrap(feliciaRecipient.id)
        let feliciaNickname = NicknameRecord(
            recipientRowID: feliciaRowID,
            givenName: "Felicia",
            familyName: "Felicity",
            note: nil,
        )
        dbV2.write { tx in
            mockNicknameManager.insert(feliciaNickname, tx: tx)
        }

        dbV2.read { transaction in
            let addresses = [aliceAddress, bobAddress, carolAddress, daveAddress, eveAddress, feliciaAddress]
            let actual = SSKEnvironment.shared.contactManagerRef.displayNames(for: addresses, tx: transaction).map { $0.resolvedValue() }
            let expected = ["Alice Aliceson (home)", "Bob Bobson", "+1 703-555-9900", "dave", "Unknown", "Felicia Felicity"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testSinglePartName() {
        let addresses = [
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550100"),
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550101"),
        ]
        createRecipients(addresses.map { $0.serviceId! })
        createAccounts(zip(addresses, ["Alice", "Bob"]).map { address, name in
            makeAccount(serviceId: address.serviceId!, phoneNumber: address.e164!, fullName: name)
        })

        dbV2.read { transaction in
            let contactsManager = SSKEnvironment.shared.contactManagerRef as! OWSContactsManager
            let actual = contactsManager.displayNames(for: addresses, tx: transaction).map { $0.resolvedValue() }
            let expected = ["Alice (home)", "Bob (home)"]
            XCTAssertEqual(actual, expected)
        }
    }

    // MARK: - Cached Contact Names

    func testCachedContactNamesWithAccounts() {
        let addresses = [
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550100"),
            SignalServiceAddress(serviceId: Aci.randomForTesting(), phoneNumber: "+16505550101"),
        ]
        createRecipients(addresses.map { $0.serviceId! })
        createAccounts(zip(addresses, ["Alice Aliceson", "Bob Bobson"]).map { address, name in
            makeAccount(serviceId: address.serviceId!, phoneNumber: address.e164!, fullName: name)
        })
        let contactsManager = makeContactsManager()
        dbV2.read { transaction in
            let actual = contactsManager.systemContactNames(for: addresses.map { $0.phoneNumber! }, tx: transaction).map { $0?.resolvedValue() }
            let expected = ["Alice Aliceson (home)", "Bob Bobson (home)"]
            XCTAssertEqual(actual, expected)
        }
    }

    func testCachedContactNameMixed() {
        // Register alice with an account that has a full name.
        let aliceAci = Aci.randomForTesting()
        let aliceAddress = SignalServiceAddress(serviceId: aliceAci, phoneNumber: "+16505550100")
        let aliceAccount = makeAccount(serviceId: aliceAci, phoneNumber: aliceAddress.e164!, fullName: "Alice Aliceson")
        createRecipients([aliceAci])
        createAccounts([aliceAccount])

        // Who the heck is Chuck?
        let chuckAci = Aci.randomForTesting()
        let chuckAddress = SignalServiceAddress(serviceId: chuckAci, phoneNumber: "+16505550101")

        let contactsManager = makeContactsManager()
        dbV2.read { transaction in
            let addresses = [aliceAddress, chuckAddress]
            let actual = contactsManager.systemContactNames(for: addresses.map { $0.phoneNumber! }, tx: transaction).map { $0?.resolvedValue() }
            let expected = ["Alice Aliceson (home)", nil]
            XCTAssertEqual(actual, expected)
        }
    }

    /// Tellomi（tellomi/tellomi#1240）：还没决定要不要给通讯录时，只有用户在选人页点了「允许访问」才去问系统；
    /// 打开聊天、新建会话、选人页加载这些自动调用一律不弹框。决定过的照上游。
    func testTellomiContactsPromptOnlyWhenUserInitiated() {
        XCTAssertFalse(OWSContactsManager.tellomiMayRequestSystemContacts(userInitiated: false, status: .notDetermined))
        XCTAssertTrue(OWSContactsManager.tellomiMayRequestSystemContacts(userInitiated: true, status: .notDetermined))
        XCTAssertTrue(OWSContactsManager.tellomiMayRequestSystemContacts(userInitiated: false, status: .authorized))
        XCTAssertTrue(OWSContactsManager.tellomiMayRequestSystemContacts(userInitiated: false, status: .denied))
    }

    /// Tellomi（tellomi/tellomi#1112、#1240）：注册不再要通讯录之后，「还没决定」是新用户的常态。「添加到通讯录 / 新建联系人 /
    /// 加到已有联系人」这些编辑入口遇到它，要先问系统（本身就是用户主动操作），不能直接弹「去 iOS 设置里打开」——
    /// App 从没问过，系统设置里根本没有这个开关。决定过的照上游；关联设备不能编辑。
    func testTellomiEditingAsksForContactsWhileNotDetermined() {
        XCTAssertTrue(OWSContactsManager.tellomiShouldRequestContactsBeforeEditing(isEditingAllowed: true, status: .notDetermined))
        XCTAssertFalse(OWSContactsManager.tellomiShouldRequestContactsBeforeEditing(isEditingAllowed: false, status: .notDetermined))
        for decided in [RawContactAuthorizationStatus.denied, .restricted, .authorized, .limited] {
            XCTAssertFalse(OWSContactsManager.tellomiShouldRequestContactsBeforeEditing(isEditingAllowed: true, status: decided), "\(decided)")
        }

        // 还没决定按「没授权」算（上游在这里断言），编辑入口先走上面那条去问系统
        XCTAssertEqual(OWSContactsManager.tellomiEditingAuthorization(isEditingAllowed: true, status: .notDetermined), .notAuthorized)
        XCTAssertEqual(OWSContactsManager.tellomiEditingAuthorization(isEditingAllowed: true, status: .denied), .notAuthorized)
        XCTAssertEqual(OWSContactsManager.tellomiEditingAuthorization(isEditingAllowed: true, status: .restricted), .notAuthorized)
        XCTAssertEqual(OWSContactsManager.tellomiEditingAuthorization(isEditingAllowed: true, status: .authorized), .authorized)
        XCTAssertEqual(OWSContactsManager.tellomiEditingAuthorization(isEditingAllowed: true, status: .limited), .authorized)
        XCTAssertEqual(OWSContactsManager.tellomiEditingAuthorization(isEditingAllowed: false, status: .authorized), .notAllowed)
    }

    // MARK: - Tellomi：没有 CDSI 时显示通讯录里存的名字（tellomi/tellomi#1346）

    /// 规则：有 CDSI 时照上游，只认 CDS 标过「可发现」的号码；没有 CDSI 时，本机已知、已注册的号码直接认，不查询。
    func testTellomiSavedNamesMatchKnownRegisteredNumbersOnlyWithoutCDSI() {
        let (registered, unregistered) = SSKEnvironment.shared.databaseStorageRef.write { tx in
            (
                try! SignalRecipient.insertRecord(aci: .randomForTesting(), phoneNumber: E164("+16505550111")!, deviceIds: [.primary], tx: tx),
                try! SignalRecipient.insertRecord(aci: .randomForTesting(), phoneNumber: E164("+16505550112")!, tx: tx),
            )
        }
        XCTAssertTrue(OWSContactsManager.canShowSystemContactName(for: registered, cdsiAvailable: false))
        XCTAssertFalse(OWSContactsManager.canShowSystemContactName(for: unregistered, cdsiAvailable: false), "没注册的号码不当成 Tellomi 用户")
        XCTAssertFalse(OWSContactsManager.canShowSystemContactName(for: registered, cdsiAvailable: true), "有 CDSI 时照上游，要 CDS 标过可发现")
    }

    /// 端到端：授权通讯录后同步一次，存进通讯录的 Tellomi 用户显示存的名字；没注册的号码不建账户。
    func testTellomiSyncShowsSavedNamesForKnownUsersWithoutCDSI() async throws {
        XCTAssertFalse(TSConstants.cdsiAvailable, "这条用例跑的是 Tellomi 的档：没有 CDSI")
        let userAci = Aci.randomForTesting()
        let userNumber = E164("+16505550121")!
        let strangerNumber = E164("+16505550122")!
        await SSKEnvironment.shared.databaseStorageRef.awaitableWrite { tx in
            _ = try! SignalRecipient.insertRecord(aci: userAci, phoneNumber: userNumber, deviceIds: [.primary], tx: tx)
            _ = try! SignalRecipient.insertRecord(aci: .randomForTesting(), phoneNumber: strangerNumber, tx: tx)
        }
        let contactsManager = SSKEnvironment.shared.contactManagerImplRef

        contactsManager.updateContacts(
            [
                makeSystemContact(givenName: "Ada", familyName: "Lovelace", phoneNumber: "+1 650-555-0121"),
                makeSystemContact(givenName: "Bob", familyName: "Builder", phoneNumber: "+1 650-555-0122"),
            ],
            isUserRequested: true,
        )

        var account: SignalAccount?
        let deadline = Date().addingTimeInterval(10)
        while account == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            account = SSKEnvironment.shared.databaseStorageRef.read { tx in
                contactsManager.fetchSignalAccount(forPhoneNumber: userNumber.stringValue, transaction: tx)
            }
        }
        XCTAssertEqual(account?.givenName, "Ada")
        XCTAssertEqual(account?.recipientServiceId, userAci)
        let strangerAccount = SSKEnvironment.shared.databaseStorageRef.read { tx in
            contactsManager.fetchSignalAccount(forPhoneNumber: strangerNumber.stringValue, transaction: tx)
        }
        XCTAssertNil(strangerAccount, "没注册的号码只是通讯录里的人，不建账户")
    }

    private func makeSystemContact(givenName: String, familyName: String, phoneNumber: String) -> SystemContact {
        let contact = CNMutableContact()
        contact.givenName = givenName
        contact.familyName = familyName
        contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phoneNumber))]
        return SystemContact(cnContact: contact)
    }
}
