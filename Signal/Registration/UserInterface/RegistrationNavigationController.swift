//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

public import SignalServiceKit
public import SignalUI

public class RegistrationNavigationController: OWSNavigationController {

    private let coordinator: RegistrationCoordinator
    private var logger: PrefixedLogger { coordinator.logger }

    public static func withCoordinator(_ coordinator: RegistrationCoordinator) -> RegistrationNavigationController {
        let vc = RegistrationNavigationController(coordinator: coordinator)
        return vc
    }

    private init(coordinator: RegistrationCoordinator) {
        self.coordinator = coordinator
        super.init()
        // 只收自己这个协调器发的（它发的时候 object: self）：同一进程里有别的注册流程时（并行跑的用例），
        // 别人的令牌到了不能让这里替自己的协调器取下一步。
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tellomiPreAuthChallengeTokenDidArrive),
            name: RegistrationCoordinatorImpl.tellomiPreAuthChallengeTokenDidArriveNotification,
            object: coordinator as AnyObject,
        )
    }

    /// Tellomi（ADR-0070 P4）：推送挑战令牌晚于等待窗口才到。还停在验证页上的话就重新取下一步，
    /// 协调器会先用这个令牌提交推送挑战，验证页随之离开；不在验证页（已经往下走了）就什么也不做。
    @objc
    private func tellomiPreAuthChallengeTokenDidArrive() {
        guard topViewController is RegistrationCaptchaViewController, !isLoading else {
            return
        }
        logger.info("Push challenge token arrived while showing the captcha; continuing with it")
        pushNextController(Guarantee.wrapAsync { await self.coordinator.nextStep() })
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.isEnabled = false
        if #available(iOS 26.0, *) {
            interactiveContentPopGestureRecognizer?.isEnabled = false
        }
        if #unavailable(iOS 26) {
            navigationBar.tintColor = .Signal.accent
        }
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if viewControllers.isEmpty, !isLoading {
            logger.info("Performing initial load")
            pushNextController(Guarantee.wrapAsync { await self.coordinator.nextStep() })
        }

        let submitLogsGesture = UITapGestureRecognizer(
            target: self,
            action: #selector(didRequestToSubmitDebugLogs),
        )
        submitLogsGesture.numberOfTapsRequired = 8
        submitLogsGesture.delaysTouchesEnded = false
        view.addGestureRecognizer(submitLogsGesture)
    }

    private var isLoading = false

    private func pushNextController(
        _ step: Guarantee<RegistrationStep>,
        loadingMode: RegistrationLoadingViewController.RegistrationLoadingMode? = .generic,
    ) {
        guard !isLoading else {
            owsFailDebug("Parallel loads not allowed", logger: logger)
            return
        }

        if let loadingMode, !step.isSealed {
            logger.info("Pushing loading controller")
            isLoading = true

            switch loadingMode {
            case .restoringBackup(let progressModal):
                present(
                    progressModal,
                    animated: true,
                ) { [weak self] in
                    self?._pushNextController(step)
                }
            default:
                pushViewController(
                    RegistrationLoadingViewController(mode: loadingMode),
                    animated: false,
                ) { [weak self] in
                    self?._pushNextController(step)
                }
            }
        } else {
            logger.info("Skipping loading controller for \(String(describing: try? step.result?.get().logSafeString))")
            _pushNextController(step)
        }
    }

    private func _pushNextController(_ step: Guarantee<RegistrationStep>) {
        isLoading = true
        Task { @MainActor [self] in
            let step = await step.awaitable()

            if let progressModal = self.presentedViewController as? BackupRestoreProgressModal {
                logger.info("Dismissing progress view")
                await progressModal.completeAndDismiss()
            }

            logger.info("Pushing registration step: \(step.logSafeString)")

            self.isLoading = false
            guard let controller = self.controller(for: step) else {
                logger.info("No controller for \(step.logSafeString)")
                return
            }
            var controllerToPush: UIViewController?
            for viewController in self.viewControllers.reversed() {
                // If we already have this controller available, update it and pop to it.
                if type(of: viewController) == controller.viewType {
                    if let newController = controller.updateViewController(viewController) {
                        logger.info("Pushing new version of existing controller for \(step.logSafeString)")
                        controllerToPush = newController
                    } else {
                        logger.info("Popping to existing controller for \(step.logSafeString)")
                        let animatePop = !(self.topViewController is RegistrationLoadingViewController)
                        self.popToViewController(viewController, animated: animatePop)
                        return
                    }
                }
            }

            // If we got here, there were no matches and we should push.
            let vc = controllerToPush ?? controller.makeViewController(self)

            if
                controller.canCancel,
                !self.viewControllers.contains(where: { $0 is RegistrationSplashViewController })
            {
                // Cancellable controllers need to have a splash view behind
                logger.info("Pushing splash view and controller for \(step.logSafeString)")
                let splashController = self.registrationSplashController()
                let newViewControllers = [splashController.makeViewController(self), vc]
                self.setViewControllers(self.viewControllers + newViewControllers, animated: true)
                return
            }

            logger.info("Pushing controller for \(step.logSafeString)")
            self.pushViewController(vc, animated: true)
        }
    }

    private struct Controller<T: UIViewController>: AnyController {
        private let type: T.Type
        // If a controller can cancel, then it needs to have a splash screen behind it to go back to
        let canCancel: Bool
        let make: (RegistrationNavigationController) -> UIViewController
        // Return a new controller to push, or nil if it should reuse the same controller.
        let update: ((T) -> T?)?

        init(
            type: T.Type,
            canCancel: Bool = false,
            make: @escaping (RegistrationNavigationController) -> UIViewController,
            update: ((T) -> T?)?,
        ) {
            self.type = type
            self.canCancel = canCancel
            self.make = make
            self.update = update
        }

        var viewType: UIViewController.Type { T.self }

        func makeViewController(_ presenter: RegistrationNavigationController) -> UIViewController {
            return make(presenter)
        }

        func updateViewController<U>(_ vc: U) -> U? where U: UIViewController {
            guard let vc = vc as? T else {
                owsFailDebug("Invalid view controller type")
                return nil
            }
            if let newController = update?(vc) as? U {
                return newController
            }
            return nil
        }
    }

    private func registrationSplashController() -> Controller<RegistrationSplashViewController> {
        let tellomiLastLogin = tellomiLastLogin()
        return Controller(
            type: RegistrationSplashViewController.self,
            make: { presenter in
                return RegistrationSplashViewController(presenter: presenter, tellomiLastLogin: tellomiLastLogin)
            },
            // No state to update.
            update: nil,
        )
    }

    /// Tellomi（ADR-0072 §4.1 第 4 步）：本机已退出登录时，欢迎页上的「上次登录」（头像 + 打码的手机号）。
    private func tellomiLastLogin() -> TellomiLastLogin? {
        guard let e164 = coordinator.tellomiReLoginE164 else {
            return nil
        }
        return TellomiLastLogin(
            maskedPhoneNumber: TellomiMaskedPhoneNumber.format(e164: e164, phoneNumberUtil: SSKEnvironment.shared.phoneNumberUtilRef),
            localAddress: DependenciesBridge.shared.tsAccountManager.localIdentifiersWithMaybeSneakyTransaction?.aciAddress,
        )
    }

    private func controller(for step: RegistrationStep) -> AnyController? {
        switch step {
        case .registrationSplash:
            return self.registrationSplashController()
        case .changeNumberSplash:
            return Controller(
                type: RegistrationChangeNumberSplashViewController.self,
                make: { presenter in
                    return RegistrationChangeNumberSplashViewController(presenter: presenter)
                },
                // No state to update.
                update: nil,
            )
        case .permissions:
            return Controller(
                type: RegistrationPermissionsViewController.self,
                make: { presenter in
                    RegistrationPermissionsViewController(requestingContactsAuthorization: true, presenter: presenter)
                },
                // The state never changes here. In theory we would build
                // state update support in the permissions controller,
                // but its overkill so we have not.
                update: nil,
            )
        case .scanQuickRegistrationQrCode:
            return Controller(
                type: RegistrationQuickRestoreQRCodeViewController.self,
                canCancel: true,
                make: { presenter in
                    return RegistrationQuickRestoreQRCodeViewController(
                        presenter: presenter,
                    )
                },
                // State never changes.
                update: nil,
            )
        case .phoneNumberEntry(let state):
            switch state {
            case .registration(let registrationMode):
                return Controller(
                    type: RegistrationPhoneNumberViewController.self,
                    canCancel: true,
                    make: { presenter in
                        return RegistrationPhoneNumberViewController(state: registrationMode, presenter: presenter)
                    },
                    update: { controller in
                        controller.updateState(registrationMode)
                        return nil
                    },
                )
            case .changingNumber(let changingNumberMode):
                switch changingNumberMode {
                case .initialEntry(let initialEntryState):
                    return Controller(
                        type: RegistrationChangePhoneNumberViewController.self,
                        make: { presenter in
                            return RegistrationChangePhoneNumberViewController(
                                state: initialEntryState,
                                presenter: presenter,
                            )
                        },
                        update: { controller in
                            controller.updateState(initialEntryState)
                            return nil
                        },
                    )
                case .confirmation(let confirmationState):
                    return Controller(
                        type: RegistrationChangePhoneNumberConfirmationViewController.self,
                        make: { presenter in
                            return RegistrationChangePhoneNumberConfirmationViewController(
                                state: confirmationState,
                                presenter: presenter,
                            )
                        },
                        update: { controller in
                            controller.updateState(confirmationState)
                            return nil
                        },
                    )
                }
            }
        case .verificationCodeEntry(let state):
            return Controller(
                type: RegistrationVerificationViewController.self,
                make: { presenter in
                    return RegistrationVerificationViewController(state: state, presenter: presenter)
                },
                update: { controller in
                    controller.updateState(state)
                    return nil
                },
            )
        case .pinEntry(let state):
            return Controller(
                type: RegistrationPinViewController.self,
                make: { presenter in
                    return RegistrationPinViewController(state: state, presenter: presenter)
                },
                update: { [weak self] controller in
                    switch (controller.state.operation, state.operation) {
                    case
                        (.creatingNewPin, .creatingNewPin),
                        (.confirmingNewPin, .confirmingNewPin),
                        (.enteringExistingPin, .enteringExistingPin):
                        controller.updateState(state)
                        return nil
                    default:
                        guard let self else { return nil }
                        return RegistrationPinViewController(state: state, presenter: self)
                    }
                },
            )
        case .pinAttemptsExhaustedWithoutReglock(let state):
            return Controller(
                type: RegistrationPinAttemptsExhaustedAndMustCreateNewPinViewController.self,
                make: { presenter in
                    return RegistrationPinAttemptsExhaustedAndMustCreateNewPinViewController(
                        state: state,
                        presenter: presenter,
                    )
                },
                update: {
                    $0.updateState(state)
                    return nil
                },
            )
        case .captchaChallenge:
            return Controller(
                type: RegistrationCaptchaViewController.self,
                make: { presenter in
                    return RegistrationCaptchaViewController(presenter: presenter)
                },
                update: { [weak self] _ in
                    guard let self else {
                        return nil
                    }
                    // Show a fresh captcha controller if we get repeated captcha requests.
                    return RegistrationCaptchaViewController(presenter: self)
                },
            )
        case .setupProfile(let state):
            return Controller(
                type: RegistrationProfileViewController.self,
                make: { presenter in
                    return RegistrationProfileViewController(state: state, presenter: presenter)
                },
                // No state to update.
                update: nil,
            )
        case .chooseRestoreMethod(let restorePath):
            return Controller(
                type: RegistrationChooseRestoreMethodViewController.self,
                make: { [securityScopedBookmarkAccess = coordinator.securityScopedBookmarkAccess] presenter in
                    return RegistrationChooseRestoreMethodViewController(
                        presenter: presenter,
                        restorePath: restorePath,
                        securityScopedBookmarkAccess: securityScopedBookmarkAccess,
                    )
                },
                update: nil,
            )
        case .confirmRestoreFromBackup(let state):
            return Controller(
                type: RegistrationRestoreFromBackupConfirmationViewController.self,
                make: { presenter in
                    return RegistrationRestoreFromBackupConfirmationViewController(state: state, presenter: presenter)
                },
                update: nil,
            )
        case .deviceTransfer(let coordinator):
            return Controller(
                type: RegistrationDeviceTransferStatusViewController.self,
                make: { presenter in
                    return RegistrationDeviceTransferStatusViewController(
                        coordinator: coordinator,
                        presenter: presenter,
                    )
                },
                // No state to update.
                update: nil,
            )
        case .phoneNumberDiscoverability(let state):
            return Controller(
                type: RegistrationPhoneNumberDiscoverabilityViewController.self,
                make: { presenter in
                    return RegistrationPhoneNumberDiscoverabilityViewController(state: state, presenter: presenter)
                },
                update: nil,
            )
        case .reglockTimeout(let state):
            return Controller(
                type: RegistrationReglockTimeoutViewController.self,
                make: { presenter in
                    return RegistrationReglockTimeoutViewController(state: state, presenter: presenter)
                },
                // No state to update.
                update: nil,
            )
        case .enterRecoveryKey(let state):
            return Controller(
                type: RegistrationEnterAccountEntropyPoolViewController.self,
                make: { presenter in
                    return RegistrationEnterAccountEntropyPoolViewController(
                        state: state,
                        presenter: presenter,
                    )
                },
                // No state to update.
                update: nil,
            )
        case let .showErrorSheet(errorSheet):
            let title: String?
            let message: String
            switch errorSheet {
            case .sessionCanNeverRequestVerificationCode:
                title = nil
                message = OWSLocalizedString(
                    "REGISTRATION_PROVIDER_FAILURE_MESSAGE_PERMANENT",
                    comment: "Error shown if an SMS/call service provider is unable to send a verification code to the provided number.",
                )
            case .becameDeregistered(let reregParams):
                handleDeregistrationReset(reregParams)
                return nil
            case .verificationCodeSubmissionUnavailable:
                title = nil
                // Tellomi（tellomi/tellomi#1214）：这里既可能是输错太多次，也可能是验证码过期（见 ErrorSheet 的注释），
                // 上游只说「输入次数过多」。两种情况下一步都是重新获取验证码，照实说。
                message = TSConstants.isUsingProductionService ? OWSLocalizedString(
                    "REGISTRATION_SUBMIT_CODE_ATTEMPTS_EXHAUSTED_ALERT",
                    comment: "Alert shown when running out of attempts at submitting a verification code.",
                ) : OWSLocalizedString(
                    "REGISTRATION_TELLOMI_CODE_NO_LONGER_VALID",
                    comment: "Tellomi: Alert shown when the verification code can no longer be submitted, because it expired or was entered wrong too many times.",
                )
            case .submittingVerificationCodeBeforeAnyCodeSent:
                title = nil
                message = OWSLocalizedString(
                    "REGISTRATION_VERIFICATION_ERROR_INVALID_VERIFICATION_CODE",
                    comment: "During registration and re-registration, users may have to enter a code to verify ownership of their phone number. If they enter an invalid code, they will see this error message.",
                )
            case .networkError:
                title = OWSLocalizedString(
                    "REGISTRATION_NETWORK_ERROR_TITLE",
                    comment: "A network error occurred during registration, and an error is shown to the user. This is the title on that error sheet.",
                )
                message = OWSLocalizedString(
                    "REGISTRATION_NETWORK_ERROR_BODY",
                    comment: "A network error occurred during registration, and an error is shown to the user. This is the body on that error sheet.",
                )
            case .sessionInvalidated where !TSConstants.isUsingProductionService:
                // Tellomi（tellomi/tellomi#1214）：会话失效时上游说「出错了，请稍后重试」，让人以为是服务器坏了。
                // 失效不只是服务端 404 过期：协调器在「被限流且会话已不能再发码」和「等推送挑战超时」时也会先重置会话再报它，
                // 所以文案说「已失效」而不是「已过期」（taishi 审查 b6）。
                // 点「好」之后协调器回到手机号页（resetSession 清了 hasEnteredE164，号码还填着），再点下一步就重新开会话、重新发验证码。
                title = nil
                message = OWSLocalizedString(
                    "REGISTRATION_TELLOMI_SESSION_EXPIRED",
                    comment: "Tellomi: Alert shown when the registration verification session is no longer valid (it expired, or was reset); the user goes back to the phone number screen, where Next requests a new code.",
                )
            case .sessionInvalidated, .genericError:
                title = nil
                message = CommonStrings.somethingWentWrongTryAgainLaterError
            case .tellomiSuspended(let restriction):
                title = nil
                message = TellomiRestrictionUI.suspendedAtRegistration(restriction)
            }
            let actionSheet = ActionSheetController(title: title, message: message)
            actionSheet.addAction(.init(title: CommonStrings.okButton, style: .default, handler: { [weak self] _ in
                guard let self else { return }
                self.pushNextController(Guarantee.wrapAsync { await self.coordinator.nextStep() })
            }))
            // We explicitly don't want the user to be able to dismiss.
            actionSheet.isCancelable = false
            self.presentActionSheet(actionSheet)
            return nil
        case .appUpdateBanner:
            present(UIAlertController.registrationAppUpdateBanner(), animated: true)
            return nil
        case .done:
            logger.info("Finished with registration!")
            if coordinator.tellomiReLoginE164 != nil {
                // Tellomi（ADR-0072 §4.2 第 4 步）：重新登录解锁了，重新登记推送令牌（退出时服务端清掉了）。
                // 注册状态已经回到 registered，WebSocket 会自己连上、收排队的消息。
                SyncPushTokensJob.run()
            }
            SignalApp.shared.showConversationSplitView()
            return nil
        }
    }

    private func handleDeregistrationReset(_ reregParams: RegistrationMode.ReregistrationParams) {
        let actionSheet = ActionSheetController(
            title: OWSLocalizedString(
                "DEREGISTRATION_NOTIFICATION",
                comment: "Notification warning the user that they have been de-registered.",
            ),
            message: nil,
        )
        actionSheet.addAction(.init(
            title: OWSLocalizedString(
                "SETTINGS_REREGISTER_BUTTON",
                comment: "Label for re-registration button.",
            ),
            style: .default,
            handler: { [weak self] _ in
                guard let self else { return }
                let loader = RegistrationCoordinatorLoaderImpl(dependencies: .from(self))
                SignalApp.shared.showRegistration(loader: loader, desiredMode: .reRegistering(reregParams))
            },
        ))
        // We explicitly don't want the user to be able to dismiss.
        actionSheet.isCancelable = false
        self.presentActionSheet(actionSheet)
    }

    override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        let superOrientations = super.supportedInterfaceOrientations
        let onboardingOrientations: UIInterfaceOrientationMask = UIDevice.current.isIPad ? .all : .portrait

        return superOrientations.intersection(onboardingOrientations)
    }

    @objc
    private func didRequestToSubmitDebugLogs() {
        if DebugFlags.internalSettings {
            let navVc = UINavigationController(rootViewController: InternalSettingsViewController(
                mode: .registration,
            ))
            self.present(navVc, animated: true)
        } else {
            let logs = DebugLogs(dumper: .fromGlobals())
            logs.promptToSubmitLogs(from: self, supportTag: "Registration")
        }
    }
}

extension RegistrationNavigationController: RegistrationSplashPresenter {

    public func continueFromSplash() {
        pushNextController(coordinator.continueFromSplash())
    }

    public func setHasOldDevice(_ hasOldDevice: Bool) {
        pushNextController(coordinator.setHasOldDevice(hasOldDevice))
    }

    public func switchToDeviceLinkingMode() {
        logger.info("Pushing device linking")
        let controller = RegistrationConfirmModeSwitchViewController(presenter: self)
        pushViewController(controller, animated: true)
    }

    public func tellomiContinueWithLastLogin() {
        pushNextController(coordinator.tellomiContinueWithLastLogin())
    }
}

extension RegistrationNavigationController: RegistrationConfimModeSwitchPresenter {

    public func confirmSwitchToDeviceLinkingMode() {
        beginSecondaryDeviceLinking(startingAtQRCode: false)
    }

    fileprivate func beginSecondaryDeviceLinking(startingAtQRCode: Bool) {
        guard coordinator.switchToSecondaryDeviceLinking() else {
            owsFailBeta("Can't switch to secondary device linking")
            return
        }
        SignalApp.shared.showSecondaryProvisioning(skipOnboarding: startingAtQRCode)
    }
}

extension RegistrationNavigationController: RegistrationChangeNumberSplashPresenter {
    func canChangeNumber() -> ChangeNumberAllowedResult {
        return coordinator.canChangeNumber()
    }
}

extension RegistrationNavigationController: RegistrationPermissionsPresenter {
    func requestPermissions() async {
        let guarantee = coordinator.requestPermissions()
        pushNextController(guarantee, loadingMode: nil)
        await guarantee.asVoid().awaitable()
    }
}

extension RegistrationNavigationController: RegistrationPhoneNumberPresenter {

    func goToNextStep(withE164 e164: E164) {
        if let reLoginE164 = coordinator.tellomiReLoginE164, e164 != reLoginE164 {
            // Tellomi（ADR-0072 §4.2 末段）：本机已退出登录，又输了另一个号码。一台手机同时只放一个账号，
            // 先确认会删掉本机的聊天记录；确认后清空本机（App 退出），重新打开就是一次正常注册。
            confirmTellomiLogInWithNewNumber(loggedOutE164: reLoginE164)
            return
        }
        pushNextController(coordinator.submitE164(e164), loadingMode: .submittingPhoneNumber(e164: e164.stringValue))
    }

    private func confirmTellomiLogInWithNewNumber(loggedOutE164: E164) {
        let maskedPhoneNumber = TellomiMaskedPhoneNumber.format(e164: loggedOutE164, phoneNumberUtil: SSKEnvironment.shared.phoneNumberUtilRef)
        let actionSheet = ActionSheetController(
            message: String(
                format: OWSLocalizedString(
                    "TELLOMI_LOGOUT_NEW_NUMBER_CONFIRM_BODY_FORMAT",
                    comment: "Tellomi: Confirmation shown on the phone number screen when this phone is logged out of one account and the user enters a different number. Deleting local data is required first. Embeds {{masked phone number of the logged-out account, e.g. +86 138****5678}}.",
                ),
                maskedPhoneNumber,
            ),
        )
        actionSheet.addAction(ActionSheetAction(
            title: CommonStrings.continueButton,
            style: .destructive,
            handler: { [weak self] _ in
                guard let self else { return }
                self.logger.warn("Logging in with a different number; deleting this phone's data first")
                ModalActivityIndicatorViewController.present(
                    fromViewController: self,
                    title: CommonStrings.deletingModal,
                ) { _ in
                    SignalApp.shared.resetAppDataAndExit(keyFetcher: SSKEnvironment.shared.databaseStorageRef.keyFetcher)
                }
            },
        ))
        actionSheet.addAction(OWSActionSheets.cancelAction)
        presentActionSheet(actionSheet)
    }

    func switchToDeviceLinking() {
        beginSecondaryDeviceLinking(startingAtQRCode: true)
    }

    func exitRegistration() {
        guard coordinator.exitRegistration() else {
            owsFailBeta("Unable to exit registration")
            return
        }
        logger.info("Early exiting registration")
        SignalApp.shared.showConversationSplitView()
    }
}

extension RegistrationNavigationController: RegistrationChangePhoneNumberPresenter {
    func submitProspectiveChangeNumberE164(newE164: E164) {
        pushNextController(coordinator.submitProspectiveChangeNumberE164(newE164), loadingMode: .submittingPhoneNumber(e164: newE164.stringValue))
    }
}

extension RegistrationNavigationController: RegistrationChangePhoneNumberConfirmationPresenter {

    func confirmChangeNumber(newE164: E164) {
        pushNextController(coordinator.submitE164(newE164), loadingMode: .submittingPhoneNumber(e164: newE164.stringValue))
    }
}

extension RegistrationNavigationController: RegistrationCaptchaPresenter {

    func submitCaptcha(_ token: String) {
        pushNextController(coordinator.submitCaptcha(token))
    }
}

extension RegistrationNavigationController: RegistrationVerificationPresenter {

    func returnToPhoneNumberEntry() {
        pushNextController(coordinator.requestChangeE164())
    }

    func requestSMSCode() {
        pushNextController(coordinator.requestSMSCode())
    }

    func requestVoiceCode() {
        pushNextController(coordinator.requestVoiceCode())
    }

    func submitVerificationCode(_ code: String) {
        pushNextController(coordinator.submitVerificationCode(code), loadingMode: .submittingVerificationCode)
    }
}

extension RegistrationNavigationController: RegistrationPinPresenter {

    func cancelPinConfirmation() {
        pushNextController(coordinator.resetUnconfirmedPINCode())
    }

    func askUserToConfirmPin(_ blob: RegistrationPinConfirmationBlob) {
        pushNextController(coordinator.setPINCodeForConfirmation(blob))
    }

    func submitPinCode(_ code: String) {
        pushNextController(coordinator.submitPINCode(code))
    }

    func submitWithSkippedPin() {
        pushNextController(coordinator.skipPINCode())
    }

    func submitWithCreateNewPinInstead() {
        pushNextController(coordinator.skipAndCreateNewPINCode())
    }
}

extension RegistrationNavigationController: RegistrationPinAttemptsExhaustedAndMustCreateNewPinPresenter {
    func acknowledgePinGuessesExhausted() {
        pushNextController(Guarantee.wrapAsync { await self.coordinator.nextStep() })
    }
}

extension RegistrationNavigationController: RegistrationProfilePresenter {
    func reserveTellomiUsername(nickname: String) async -> TellomiRegistrationUsername.ReservationOutcome {
        return await coordinator.reserveTellomiUsername(nickname: nickname)
    }

    func confirmTellomiUsername(_ reservedUsername: Usernames.HashedUsername) async -> TellomiRegistrationUsername.ConfirmationOutcome {
        return await coordinator.confirmTellomiUsername(reservedUsername)
    }

    func goToNextStep(
        givenName: OWSUserProfile.NameComponent,
        familyName: OWSUserProfile.NameComponent?,
        avatarData: Data?,
        phoneNumberDiscoverability: PhoneNumberDiscoverability,
    ) {
        pushNextController(
            coordinator.setProfileInfo(
                givenName: givenName,
                familyName: familyName,
                avatarData: avatarData,
                phoneNumberDiscoverability: phoneNumberDiscoverability,
            ),
        )
    }
}

extension RegistrationNavigationController: RegistrationPhoneNumberDiscoverabilityPresenter {

    var presentedAsModal: Bool { return false }

    func setPhoneNumberDiscoverability(_ phoneNumberDiscoverability: PhoneNumberDiscoverability) {
        pushNextController(coordinator.setPhoneNumberDiscoverability(phoneNumberDiscoverability))
    }
}

extension RegistrationNavigationController: RegistrationReglockTimeoutPresenter {

    func acknowledgeReglockTimeout() {
        switch coordinator.acknowledgeReglockTimeout() {
        case .cannotExit:
            logger.warn("Tried to exit registration from reglock timeout when unable.")
            return
        case .exitRegistration:
            logger.info("Exiting registration after reglock timeout")
            SignalApp.shared.showConversationSplitView()
        case .restartRegistration(let nextStepGuarantee):
            pushNextController(nextStepGuarantee)
        }
    }
}

extension RegistrationNavigationController: RegistrationEnterAccountEntropyPoolPresenter {
    func next(accountEntropyPool: AccountEntropyPool) {
        let guarantee = coordinator.updateAccountEntropyPool(accountEntropyPool)
        pushNextController(guarantee)
    }

    func cancelKeyEntry() {
        let guarantee = coordinator.cancelRecoveryKeyEntry()
        pushNextController(guarantee)
    }

    func forgotKeyAction() {
        let guarantee = coordinator.updateRestoreMethod(method: .declined)
        pushNextController(guarantee)
    }
}

extension RegistrationNavigationController: RegistrationChooseRestoreMethodPresenter {
    func didChooseRestoreMethod(method: RegistrationRestoreMethod) {
        let guarantee = coordinator.updateRestoreMethod(method: method)
        pushNextController(guarantee)
    }

    func didCancelRestoreMethodSelection() {
        let guarantee = coordinator.resetRestoreMode()
        pushNextController(guarantee)
    }
}

extension RegistrationNavigationController: RegistrationQuickRestoreQRCodePresenter {
    func didReceiveRegistrationMessage(_ message: SignalServiceKit.RegistrationProvisioningMessage) {
        let guarantee = coordinator.restoreFromRegistrationMessage(message: message)
        pushNextController(guarantee)
    }

    func cancelChosenRestoreMethod() {
        let guarantee = coordinator.resetRestoreMode()
        pushNextController(guarantee)
    }
}

extension RegistrationNavigationController: RegistrationTransferStatusPresenter {
    func cancelTransfer() {
        let guarantee = coordinator.resetRestoreMode()
        pushNextController(guarantee)
    }

    func transferFailed(error: Error) {
        let guarantee = coordinator.resetRestoreMode()
        pushNextController(guarantee)
    }
}

extension RegistrationNavigationController: RegistrationRestoreFromBackupConfirmationPresenter {
    func skipRestoreFromBackup() {
        let guarantee = coordinator.updateRestoreMethod(method: .declined)
        pushNextController(guarantee)
    }

    func cancelRestoreFromBackup() {
        let guarantee = coordinator.resetRestoreMethodChoice()
        pushNextController(guarantee)
    }

    func restoreFromBackupConfirmed(_ backup: RegistrationRestoreFromBackupConfirmationState.AvailableBackup) {
        Task { @MainActor in
            let progressModal = BackupRestoreProgressModal(style: .backupRestore)
            let (progress, stream) = OWSSequentialProgress<BackupRestoreProgressPhase>.createSink()
            Task { @MainActor in
                for await progress in stream {
                    progressModal.viewModel.updateBackupRestoreProgress(progress: progress)
                }
            }
            let guarantee: Guarantee<RegistrationStep> = coordinator.confirmRestoreFromBackup(
                progress: progress,
                selectedBackup: backup,
            )
            pushNextController(guarantee, loadingMode: .restoringBackup(progressModal))
        }
    }
}

private protocol AnyController {

    var canCancel: Bool { get }

    var viewType: UIViewController.Type { get }

    func makeViewController(_: RegistrationNavigationController) -> UIViewController

    func updateViewController<T: UIViewController>(_: T) -> T?
}
