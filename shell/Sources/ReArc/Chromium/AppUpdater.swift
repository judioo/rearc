#if REARC_CHROMIUM
import AppKit
import Sparkle
import SidebarModel
import SwiftUI

/// Sparkle 2, with ReArc's sidebar notice in front of it
/// (docs/FEATURE-SPECS/UPDATE-NOTICE.md §4). Sparkle's own updater does
/// everything that keeps an update safe: the signed feed, the archive's
/// EdDSA signature, the installer and the relaunch. Only the user interface
/// is split: `UpdateNoticeUserDriver` sends a scheduled find, and Restart and
/// Update's own session, to the notice, and everything else (Check for
/// Updates…, "You're up to date", the permission prompt) to Sparkle's
/// standard driver unchanged.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, NSMenuItemValidation, UpdateNoticeDriving {
    static let shared = AppUpdater()
    let isEnabled: Bool
    private(set) var updater: SPUUpdater?
    private var driver: UpdateNoticeUserDriver?
    private let center = UpdateNoticeCenter.shared
    private weak var menuItem: NSMenuItem?
    private var automaticObservation: NSKeyValueObservation?
    private var vetoObserver: NSObjectProtocol?

    private override init() {
        // A preview of the notice never starts Sparkle (`UpdateNoticePreview`).
        isEnabled = Bundle.main.object(forInfoDictionaryKey: "ReArcRelease") as? Bool == true && !UpdateNoticeCenter.shared.isPreviewing
        super.init()
        guard isEnabled else { return }
        let driver = UpdateNoticeUserDriver(center: center, standard: SPUStandardUserDriver(hostBundle: .main, delegate: self))
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        driver.updater = updater
        do {
            try updater.start()
        } catch {
            UpdateLog.error("Sparkle did not start", error)
            return
        }
        self.updater = updater
        self.driver = driver
        center.driver = self
        automaticObservation = updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let value = change.newValue else { return }
                self?.center.automaticUpdatesChanged(value)
            }
        }
        // A page's beforeunload kept ReArc open after Sparkle asked it to quit.
        vetoObserver = NotificationCenter.default.addObserver(forName: ChromiumRuntime.shutdownVetoedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.driver?.quitWasRefused() }
        }
        observeMenuState()
    }

    // MARK: Menu

    func makeMenuItem() -> NSMenuItem? {
        guard updater != nil else { return nil }
        let item = NSMenuItem(title: center.notice.menuState.title, action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        menuItem = item
        refreshMenu()
        return item
    }

    /// Check for Updates… / Update Available…: Sparkle's standard window,
    /// "You're up to date" included. With the notice holding an update,
    /// Sparkle asks the driver to bring it forward, which hands it to that window.
    @objc func checkForUpdates(_ sender: Any?) {
        updater?.checkForUpdates()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(checkForUpdates(_:)) || updater?.canCheckForUpdates == true
    }

    private func observeMenuState() {
        withObservationTracking { _ = center.notice.menuState } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshMenu()
                self?.observeMenuState()
            }
        }
    }

    private func refreshMenu() {
        let state = center.notice.menuState
        menuItem?.title = state.title
        menuItem?.badge = state.badgeCount == 0 ? nil : .updates(count: state.badgeCount)
    }

    // MARK: UpdateNoticeDriving

    func installFromNotice() {
        driver?.installFromNotice()
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { if updater?.automaticallyDownloadsUpdates != newValue { updater?.automaticallyDownloadsUpdates = newValue } }
    }

    // MARK: SPUUpdaterDelegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdatePreferences.allowedChannels(in: .standard)
    }

    /// Automatic Updates downloaded an update to install at quit. ReArc
    /// takes the immediate install, so Restart and Update needs no second
    /// download or check; Sparkle still installs at quit as before. Taking
    /// it stops further cycles until the relaunch.
    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard let driver else { return false }
        driver.holdImmediateInstall(for: item, immediateInstallHandler)
        return true
    }

    @objc(updater:userDidMakeChoice:forUpdate:state:)
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        if choice == .skip { center.send(.skipped) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        center.send(.notFound)
    }

    // MARK: SPUStandardUserDriverDelegate

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// The standard driver sees a scheduled update only when the driver hands
    /// one over (Update Available… while the notice holds it), or an
    /// information-only item, which stays on the menu's badge.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated { driver?.isHandingOver == true }
    }

    /// Required with gentle reminders; the notice and the menu follow `UpdateNoticeCenter`.
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {}

    // MARK: Feed items

    /// The notice's view of an item: its build and level from the signed
    /// feed's flags. The display version is logged escaped, never drawn.
    static func availableUpdate(_ item: SUAppcastItem) -> AvailableUpdate {
        let flags = UpdateFeedFlags(isCritical: item.isCriticalUpdate, properties: item.propertiesDictionary)
        if flags.requirement == .unrecognized {
            UpdateLog.note("item \(UpdateNoticeLog.escaped(item.versionString)) has a \(UpdateFeedMarker.requiredBelowKey) that is not a build number; ignored")
        }
        let host = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(UpdateBuild.init)
        let update = AvailableUpdate(version: item.displayVersionString, build: UpdateBuild(item.versionString),
                                     urgency: flags.urgency(forHostBuild: host))
        UpdateLog.note("found \(UpdateNoticeLog.escaped(item.displayVersionString)) (\(UpdateNoticeLog.escaped(item.versionString))), \(update.urgency)")
        return update
    }
}

/// Sparkle's user driver, split between the sidebar notice and Sparkle's
/// standard driver (`UpdateSessionRouting`). The standard driver is a
/// complete one, so every call the notice does not take reaches it as if
/// it were Sparkle's only driver.
@MainActor
final class UpdateNoticeUserDriver: NSObject, SPUUserDriver {
    private let center: UpdateNoticeCenter
    private let standard: SPUStandardUserDriver
    weak var updater: SPUUpdater?
    private var routing = UpdateSessionRouting()
    /// Sparkle's question the notice holds: Restart and Update replies Install.
    private var pendingFound: (item: SUAppcastItem, state: SPUUserUpdateState, reply: (SPUUserUpdateChoice) -> Void)?
    private var pendingReady: ((SPUUserUpdateChoice) -> Void)?
    /// Automatic Updates' downloaded update: install and relaunch at once.
    private var immediateInstall: (() -> Void)?
    /// Asks the app to quit again after a page kept it open.
    private var retryTermination: (() -> Void)?
    /// Restart and Update while Sparkle was busy with another session.
    private var installWhenPossible = false
    private(set) var isHandingOver = false

    init(center: UpdateNoticeCenter, standard: SPUStandardUserDriver) {
        self.center = center
        self.standard = standard
    }

    func installFromNotice() {
        if let retry = retryTermination {
            retryTermination = nil
            retry()
        } else if let reply = pendingReady {
            pendingReady = nil
            reply(.install)
        } else if let found = pendingFound {
            pendingFound = nil
            found.reply(.install)
        } else if let immediate = immediateInstall {
            center.send(.installing)
            immediate()
        } else if routing.route == .standard {
            // Sparkle's window has this session: bring it forward instead.
            center.send(.sessionEnded)
            standard.showUpdateInFocus()
        } else if let updater, updater.canCheckForUpdates, !updater.sessionInProgress {
            // Nothing in hand (the session ended, or Try Again): check, or
            // resume a downloaded update, as the notice's own session.
            routing.noticeWillCheck()
            updater.checkForUpdates()
        } else {
            installWhenPossible = true
        }
    }

    func holdImmediateInstall(for item: SUAppcastItem, _ install: @escaping () -> Void) {
        immediateInstall = install
        center.send(.found(AppUpdater.availableUpdate(item), downloaded: true))
        if installWhenPossible || center.notice.installRequested {
            installWhenPossible = false
            center.send(.installing)
            install()
        }
    }

    func quitWasRefused() {
        guard retryTermination != nil || center.notice.phase == .installing else { return }
        center.send(.failed(.quitRefused))
    }

    private var isNotice: Bool { routing.current == .notice }

    private func endSession() {
        pendingFound = nil
        pendingReady = nil
        retryTermination = nil
        routing.sessionEnded()
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        standard.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if routing.userInitiatedCheckBegan() == .standard {
            standard.showUserInitiatedUpdateCheck(cancellation: cancellation)
        }
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let route = routing.updateFound(userInitiated: state.userInitiated, informationOnly: appcastItem.isInformationOnlyUpdate)
        if !appcastItem.isInformationOnlyUpdate {
            center.send(.found(AppUpdater.availableUpdate(appcastItem), downloaded: state.stage != .notDownloaded))
        }
        switch route {
        case .standard:
            standard.showUpdateFound(with: appcastItem, state: state, reply: reply)
        case .notice:
            if center.notice.installRequested || installWhenPossible {
                installWhenPossible = false
                reply(.install)
            } else {
                pendingFound = (appcastItem, state, reply)
            }
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if !isNotice { standard.showUpdateReleaseNotes(with: downloadData) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        if !isNotice { standard.showUpdateReleaseNotesFailedToDownloadWithError(error) }
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let notice = isNotice
        center.send(.notFound)
        if notice { acknowledgement() } else { standard.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        UpdateLog.error("update failed", error)
        guard isNotice else {
            standard.showUpdaterError(error, acknowledgement: acknowledgement)
            return
        }
        let chain = UpdateLog.chain(error)
        if chain.first.map({ $0.domain == UpdateNoticeFailure.sparkleErrorDomain && $0.code == UpdateNoticeFailure.canceledCode }) == true {
            center.send(.sessionEnded)
        } else {
            center.send(.failed(UpdateNoticeFailure.classify(chain)))
        }
        endSession()
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        if isNotice { center.send(.downloadStarted) } else { standard.showDownloadInitiated(cancellation: cancellation) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if isNotice { center.send(.downloadExpected(expectedContentLength)) } else { standard.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        if isNotice { center.send(.downloadReceived(length)) } else { standard.showDownloadDidReceiveData(ofLength: length) }
    }

    func showDownloadDidStartExtractingUpdate() {
        if isNotice { center.send(.extractionStarted) } else { standard.showDownloadDidStartExtractingUpdate() }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        if isNotice { center.send(.extracted(progress)) } else { standard.showExtractionReceivedProgress(progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard isNotice else {
            standard.showReady(toInstallAndRelaunch: reply)
            return
        }
        center.send(.readyToInstall)
        if center.notice.installRequested { reply(.install) } else { pendingReady = reply }
    }

    /// Sparkle has asked ReArc to quit (Apple Event quit: the same orderly
    /// shutdown and window-session save as the Dock's Quit, without ⌘Q's
    /// Warn before quitting) and installs once it has.
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        guard isNotice else {
            standard.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication)
            return
        }
        retryTermination = applicationTerminated ? nil : retryTerminatingApplication
        center.send(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        if isNotice { acknowledgement() } else { standard.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement) }
    }

    /// Update Available… (or Check for Updates…) while the notice holds the
    /// update: Sparkle's window takes it over, Install, Later and Skip included.
    func showUpdateInFocus() {
        guard let found = pendingFound else {
            standard.showUpdateInFocus()
            return
        }
        pendingFound = nil
        routing.handOverToStandard()
        isHandingOver = true
        standard.showUpdateFound(with: found.item, state: found.state, reply: found.reply)
        standard.showUpdateInFocus()
        isHandingOver = false
    }

    func dismissUpdateInstallation() {
        standard.dismissUpdateInstallation()
        endSession()
        center.send(.sessionEnded)
    }
}

/// The updater's lines in the shell's log. Feed-derived text is escaped
/// (`UpdateNoticeLog.escaped`), Sparkle's error text included.
enum UpdateLog {
    static func note(_ message: String) {
        ChromiumLog.info("update: \(message)")
    }

    static func error(_ what: String, _ error: Error) {
        let chain = self.chain(error).map { "\($0.domain) \($0.code)" }.joined(separator: " ← ")
        ChromiumLog.info("update: \(what): \(chain): \(UpdateNoticeLog.escaped((error as NSError).localizedDescription))")
    }

    static func chain(_ error: Error) -> [(domain: String, code: Int)] {
        var chain: [(domain: String, code: Int)] = []
        var next: NSError? = error as NSError
        while let current = next, chain.count < 8 {
            chain.append((current.domain, current.code))
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }
}

private struct UpdateSettingsGroup: View {
    @State private var center = UpdateNoticeCenter.shared
    @AppStorage(UpdatePreferences.betaKey) private var receiveBetaUpdates = false

    var body: some View {
        SettingsGroup {
            // The same setting as the update card's Automatic Updates checkbox.
            SettingsSwitchRow(label: "Automatically download and install updates",
                              isOn: Binding(get: { center.automaticUpdates }, set: { center.setAutomaticUpdates($0) }))
            SettingsSwitchRow(label: "Receive beta updates", isOn: $receiveBetaUpdates)
        }
    }
}

struct UpdateSettingsSection: View {
    var body: some View {
        if AppUpdater.shared.updater != nil { UpdateSettingsGroup() }
    }
}
#endif
