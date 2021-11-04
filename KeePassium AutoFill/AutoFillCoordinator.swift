//  KeePassium Password Manager
//  Copyright © 2018–2019 Andrei Popleteev <info@keepassium.com>
//
//  This program is free software: you can redistribute it and/or modify it
//  under the terms of the GNU General Public License version 3 as published
//  by the Free Software Foundation: https://www.gnu.org/licenses/).
//  For commercial licensing, please contact the author.

import UIKit
import KeePassiumLib
import AuthenticationServices
import LocalAuthentication

class AutoFillCoordinator: NSObject, Coordinator {
    var childCoordinators = [Coordinator]()
    var dismissHandler: CoordinatorDismissHandler? 
    
    unowned var rootController: CredentialProviderViewController
    var router: NavigationRouter

    private var databasePickerCoordinator: DatabasePickerCoordinator!
    private var entryFinderCoordinator: EntryFinderCoordinator?
    private var databaseUnlockerCoordinator: DatabaseUnlockerCoordinator?
    var serviceIdentifiers = [ASCredentialServiceIdentifier]()
    
    fileprivate var watchdog: Watchdog
    fileprivate var passcodeInputController: PasscodeInputVC?
    fileprivate var isBiometricAuthShown = false
    fileprivate var isPasscodeInputShown = false
    
    
    init(rootController: CredentialProviderViewController) {
        self.rootController = rootController
        let navigationController = RouterNavigationController()
        navigationController.view.backgroundColor = .clear
        router = NavigationRouter(navigationController)
        
        watchdog = Watchdog.shared 
        super.init()

        #if PREPAID_VERSION
        BusinessModel.type = .prepaid
        #else
        BusinessModel.type = .freemium
        #endif
        SettingsMigrator.processAppLaunch(with: Settings.current)
        SystemIssueDetector.scanForIssues()
        Diag.info(AppInfo.description)

        watchdog.delegate = self
    }
    
    deinit {
        assert(childCoordinators.isEmpty)
        removeAllChildCoordinators()
    }
    
    public func handleMemoryWarning() {
        Diag.error("Received a memory warning")
        databaseUnlockerCoordinator?.cancelLoading(reason: .lowMemoryWarning)
    }
    
    func start() {
        watchdog.didBecomeActive()
        if !isAppLockVisible {
            rootController.showChildViewController(router.navigationController)
            if isNeedsOnboarding() {
                DispatchQueue.main.async { [weak self] in
                    self?.presentOnboarding()
                }
            }
        }

        let premiumManager = PremiumManager.shared
        premiumManager.reloadReceipt()
        premiumManager.usageMonitor.startInterval()
        
        showDatabasePicker()
        StoreReviewSuggester.registerEvent(.sessionStart)
        if Settings.current.isAutoFillFinishedOK {
            databasePickerCoordinator.shouldSelectDefaultDatabase = true
        } else {
            showCrashReport()
        }
    }
    
    internal func cleanup() {
        PremiumManager.shared.usageMonitor.stopInterval()
        router.popToRoot(animated: false)
    }
    
    private func dismissAndQuit() {
        rootController.dismiss()
        Settings.current.isAutoFillFinishedOK = true
        cleanup()
    }
    
    private func returnCredentials(entry: Entry) {
        watchdog.restart()
        
        let settings = Settings.current
        if settings.isCopyTOTPOnAutoFill,
            let totpGenerator = TOTPGeneratorFactory.makeGenerator(for: entry)
        {
            let totpString = totpGenerator.generate()
            Clipboard.general.insert(
                text: totpString,
                timeout: TimeInterval(settings.clipboardTimeout.seconds)
            )
        }
        
        let passwordCredential = ASPasswordCredential(
            user: entry.resolvedUserName,
            password: entry.resolvedPassword)
        rootController.extensionContext.completeRequest(withSelectedCredential: passwordCredential) {
            (expired) in
            HapticFeedback.play(.credentialsPasted)
        }
        Settings.current.isAutoFillFinishedOK = true
        cleanup()
    }
}

extension AutoFillCoordinator {
    private func isNeedsOnboarding() -> Bool {
        if FileKeeper.canAccessAppSandbox {
            return false
        }
        
        let validDatabases = FileKeeper.shared
            .getAllReferences(fileType: .database, includeBackup: false)
            .filter { !$0.hasError }
        return validDatabases.isEmpty
    }
    
    private func showDatabasePicker() {
        databasePickerCoordinator = DatabasePickerCoordinator(router: router, mode: .autoFill)
        databasePickerCoordinator.delegate = self
        databasePickerCoordinator.dismissHandler = {[weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
            self?.databasePickerCoordinator = nil
            self?.dismissAndQuit()
        }
        databasePickerCoordinator.start()
        addChildCoordinator(databasePickerCoordinator)
    }
    
    private func presentOnboarding() {
        let firstSetupVC = FirstSetupVC.make(delegate: self)
        firstSetupVC.navigationItem.hidesBackButton = true
        router.present(firstSetupVC, animated: false, completion: nil)
    }
    
    private func showCrashReport() {
        StoreReviewSuggester.registerEvent(.trouble)
        
        let crashReportVC = CrashReportVC.instantiateFromStoryboard()
        crashReportVC.delegate = self
        router.push(crashReportVC, animated: false, onPop: nil)
    }
    
    private func showDatabaseUnlocker(_ databaseRef: URLReference) {
        let databaseUnlockerCoordinator = DatabaseUnlockerCoordinator(
            router: router,
            databaseRef: databaseRef
        )
        databaseUnlockerCoordinator.dismissHandler = {[weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
            self?.databaseUnlockerCoordinator = nil
        }
        databaseUnlockerCoordinator.delegate = self
        databaseUnlockerCoordinator.setDatabase(databaseRef)

        databaseUnlockerCoordinator.start()
        addChildCoordinator(databaseUnlockerCoordinator)
        self.databaseUnlockerCoordinator = databaseUnlockerCoordinator
    }
    
    private func showDatabaseViewer(
        _ fileRef: URLReference,
        databaseFile: DatabaseFile,
        warnings: DatabaseLoadingWarnings
    ) {
        let entryFinderCoordinator = EntryFinderCoordinator(
            router: router,
            databaseFile: databaseFile,
            loadingWarnings: warnings,
            serviceIdentifiers: serviceIdentifiers
        )
        entryFinderCoordinator.dismissHandler = {[weak self] coordinator in
            self?.removeChildCoordinator(coordinator)
            self?.entryFinderCoordinator = nil
        }
        entryFinderCoordinator.delegate = self
        
        entryFinderCoordinator.start()
        addChildCoordinator(entryFinderCoordinator)
        self.entryFinderCoordinator = entryFinderCoordinator
    }
}

extension AutoFillCoordinator: WatchdogDelegate {
    var isAppCoverVisible: Bool {
        return false
    }
    
    func showAppCover(_ sender: Watchdog) {
    }
    
    func hideAppCover(_ sender: Watchdog) {
    }
    
    var isAppLockVisible: Bool {
        return isBiometricAuthShown || isPasscodeInputShown
    }

    func showAppLock(_ sender: Watchdog) {
        guard !isAppLockVisible else { return }
        let shouldUseBiometrics = canUseBiometrics()

        let passcodeInputVC = PasscodeInputVC.instantiateFromStoryboard()
        passcodeInputVC.delegate = self
        passcodeInputVC.mode = .verification
        passcodeInputVC.isCancelAllowed = true
        passcodeInputVC.isBiometricsAllowed = shouldUseBiometrics
        passcodeInputVC.modalTransitionStyle = .crossDissolve

        passcodeInputVC.shouldActivateKeyboard = !shouldUseBiometrics

        rootController.swapChildViewControllers(
            from: router.navigationController,
            to: passcodeInputVC,
            options: .transitionCrossDissolve)
        router.dismissModals(animated: false, completion: nil)
        passcodeInputVC.shouldActivateKeyboard = false
        maybeShowBiometricAuth()
        passcodeInputVC.shouldActivateKeyboard = !isBiometricAuthShown
        self.passcodeInputController = passcodeInputVC
        isPasscodeInputShown = true
    }

    func hideAppLock(_ sender: Watchdog) {
        dismissPasscodeAndContinue()
    }

    func mustCloseDatabase(_ sender: Watchdog, animate: Bool) {
        if Settings.current.premiumIsLockDatabasesOnTimeout {
            entryFinderCoordinator?.lockDatabase()
        }else {
            entryFinderCoordinator?.stop(animated: animate)
        }
    }

    private func dismissPasscodeAndContinue() {
        if let passcodeInputVC = passcodeInputController {
            rootController.swapChildViewControllers(
                from: passcodeInputVC,
                to: router.navigationController,
                options: .transitionCrossDissolve,
                completion: { [weak self] finished in
                    guard let self = self else { return }
                    if self.isNeedsOnboarding() {
                        self.presentOnboarding()
                    }
                }
            )
            passcodeInputController = nil
        } else {
            assertionFailure()
        }
        
        isPasscodeInputShown = false
        watchdog.restart()
    }

    private func canUseBiometrics() -> Bool {
        return Settings.current.isBiometricAppLockEnabled
            && LAContext.isBiometricsAvailable()
            && Keychain.shared.isBiometricAuthPrepared()
    }
    
    private func maybeShowBiometricAuth() {
        guard canUseBiometrics() else {
            isBiometricAuthShown = false
            return
        }
        
        Diag.debug("Biometric auth: showing request")
        Keychain.shared.performBiometricAuth { [weak self] success in
            guard let self = self else { return }
            BiometricsHelper.biometricPromptLastSeenTime = Date.now
            self.isBiometricAuthShown = false
            if success {
                Diag.info("Biometric auth successful")
                self.watchdog.unlockApp()
            } else {
                Diag.warning("Biometric auth failed")
                self.passcodeInputController?.showKeyboard()
            }
        }
        isBiometricAuthShown = true
    }
}

extension AutoFillCoordinator: PasscodeInputDelegate {
    func passcodeInputDidCancel(_ sender: PasscodeInputVC) {
        dismissAndQuit()
    }
    
    func passcodeInput(_ sender: PasscodeInputVC, didEnterPasscode passcode: String) {
        do {
            if try Keychain.shared.isAppPasscodeMatch(passcode) { 
                HapticFeedback.play(.appUnlocked)
                Keychain.shared.prepareBiometricAuth(true)
                watchdog.unlockApp()
            } else {
                HapticFeedback.play(.wrongPassword)
                sender.animateWrongPassccode()
                StoreReviewSuggester.registerEvent(.trouble)
                if Settings.current.isLockAllDatabasesOnFailedPasscode {
                    DatabaseSettingsManager.shared.eraseAllMasterKeys()
                    entryFinderCoordinator?.lockDatabase()
                }
            }
        } catch {
            Diag.error(error.localizedDescription)
            sender.showErrorAlert(error, title: LString.titleKeychainError)
        }
    }

    func passcodeInputDidRequestBiometrics(_ sender: PasscodeInputVC) {
        maybeShowBiometricAuth()
    }
}

extension AutoFillCoordinator: CrashReportDelegate {
    func didPressDismiss(in crashReport: CrashReportVC) {
        Settings.current.isAutoFillFinishedOK = true
        router.pop(animated: true)
    }
}

extension AutoFillCoordinator: FirstSetupDelegate {
    func didPressCancel(in firstSetup: FirstSetupVC) {
        dismissAndQuit()
    }
    
    func didPressAddDatabase(in firstSetup: FirstSetupVC, at popoverAnchor: PopoverAnchor) {
        watchdog.restart()
        firstSetup.dismiss(animated: true, completion: nil)
        databasePickerCoordinator.addExistingDatabase(presenter: router.navigationController)
    }
    
    func didPressSkip(in firstSetup: FirstSetupVC) {
        watchdog.restart()
        firstSetup.dismiss(animated: true, completion: nil)
    }
}

extension AutoFillCoordinator: DatabasePickerCoordinatorDelegate {
    func shouldAcceptDatabaseSelection(
        _ fileRef: URLReference,
        in coordinator: DatabasePickerCoordinator
    ) -> Bool {
        return true
    }
    
    func didSelectDatabase(_ fileRef: URLReference?, in coordinator: DatabasePickerCoordinator) {
        guard let fileRef = fileRef else {
            return
        }
        showDatabaseUnlocker(fileRef)
    }
    
    func shouldKeepSelection(in coordinator: DatabasePickerCoordinator) -> Bool {
        return false
    }
}

extension AutoFillCoordinator: DatabaseUnlockerCoordinatorDelegate {
    func shouldAutoUnlockDatabase(
        _ fileRef: URLReference,
        in coordinator: DatabaseUnlockerCoordinator
    ) -> Bool {
        return true
    }
    
    func willUnlockDatabase(_ fileRef: URLReference, in coordinator: DatabaseUnlockerCoordinator) {
        Settings.current.isAutoFillFinishedOK = false
    }
    
    func didNotUnlockDatabase(
        _ fileRef: URLReference,
        with message: String?,
        reason: String?,
        in coordinator: DatabaseUnlockerCoordinator
    ) {
        Settings.current.isAutoFillFinishedOK = true 
    }
    
    func didUnlockDatabase(
        databaseFile: DatabaseFile,
        at fileRef: URLReference,
        warnings: DatabaseLoadingWarnings,
        in coordinator: DatabaseUnlockerCoordinator
    ) {
        Settings.current.isAutoFillFinishedOK = true 
        showDatabaseViewer(fileRef, databaseFile: databaseFile, warnings: warnings)
    }
    
    func didPressReinstateDatabase(
        _ fileRef: URLReference,
        in coordinator: DatabaseUnlockerCoordinator
    ) {
        router.pop(animated: true, completion: { [weak self] in
            guard let self = self else { return }
            self.databasePickerCoordinator.addExistingDatabase(
                presenter: self.router.navigationController
            )
        })
    }
}

extension AutoFillCoordinator: EntryFinderCoordinatorDelegate {
    func didLeaveDatabase(in coordinator: EntryFinderCoordinator) {
    }
    
    func didSelectEntry(_ entry: Entry, in coordinator: EntryFinderCoordinator) {
        returnCredentials(entry: entry)
    }
}
