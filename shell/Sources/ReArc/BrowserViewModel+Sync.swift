import AppKit
import SidebarModel

/// iCloud sidebar sync (docs/SYNC-DESIGN.md, docs/ICLOUD-SETUP.md). Builds
/// without the iCloud entitlement get `UnavailableSyncEngine`, and nothing
/// here touches CloudKit.
extension BrowserViewModel {
    static let syncActivationThrottle: TimeInterval = 60

    var syncControl: SyncControlling? {
        syncEngine as? SyncControlling
    }

    /// Why Settings shows "iCloud sync unavailable in this build", or nil when it is available.
    var syncUnavailableReason: String? {
        guard syncControl == nil else { return nil }
        if case .unavailable(let reason) = syncStatus { return reason }
        return CloudKitSyncAvailability.unavailableMessage
    }

    var isSyncEnabled: Bool {
        MainActor.assumeIsolated { syncControl?.isUserEnabled ?? false }
    }

    /// The switch in Settings › Account. Off is immediate. On uses this
    /// session's look at iCloud, or waits for one (read-only): empty, it
    /// starts syncing; holding a sidebar, it asks what to do with it
    /// (`syncCloudChoice`); out of reach, it says so and the switch stays off.
    func setSyncEnabled(_ enabled: Bool) {
        syncCloudMessage = nil
        guard enabled else {
            syncSwitchWaiting = false
            MainActor.assumeIsolated { syncControl?.setUserEnabled(false) }
            return
        }
        guard syncControl != nil else { return }
        syncSwitchWaiting = true
        checkCloudSidebar(force: false) { [weak self] detection in
            guard let self, self.syncSwitchWaiting else { return }
            self.syncSwitchWaiting = false
            switch detection {
            case .empty:
                MainActor.assumeIsolated { self.syncControl?.setUserEnabled(true) }
            case .found(let found):
                self.syncCloudChoice = found
            case .signedOut(let message), .unreachable(let message), .unavailable(let message):
                self.syncCloudMessage = message
            }
        }
    }

    var isCheckingCloud: Bool { cloudLook != .idle }

    /// The look in one line, the same in the iCloud box and under the switch.
    var cloudStatusText: String {
        switch cloudLook {
        case .looking(nil): return "Looking at iCloud…"
        case .looking(let count?): return "Looking at iCloud… \(count.formatted()) items"
        case .stalled(let message): return message
        case .idle: return SyncCloudText.status(cloudDetection)
        }
    }

    /// A read-only look at iCloud; `done` gets the result. Without `force`
    /// this session's result answers at once. A look under way answers
    /// every caller; one stalled is joined by a fresh one when forced, and
    /// whichever finishes later still replaces an earlier result.
    func checkCloudSidebar(force: Bool = true, _ done: ((CloudSidebarDetection) -> Void)? = nil) {
        guard let control = syncControl else { return }
        if !force, cloudLooksRunning == 0, let cached = cloudDetection {
            switch cached {
            case .found, .empty:
                done?(cached)
                return
            default:
                break
            }
        }
        if let done { cloudCheckWaiters.append(done) }
        if cloudLooksRunning > 0, !(force && cloudLook.isStalled) { return }
        cloudLooksStarted += 1
        cloudLooksRunning += 1
        let look = cloudLooksStarted
        cloudLook = .looking(nil)
        // Owned by the model, not the Settings window: closing it cancels nothing.
        Task { @MainActor [weak self] in
            let detection = await control.detectCloudSidebar { [weak self] step in
                guard let self, look == self.cloudLooksStarted else { return }
                switch step {
                case .account: self.cloudLook = .looking(nil)
                case .records(let count): self.cloudLook = .looking(count)
                case .stalled(let message): self.cloudLook = .stalled(message)
                }
            }
            guard let self else { return }
            self.cloudLooksRunning -= 1
            if self.cloudLooksRunning == 0 { self.cloudLook = .idle }
            guard look > self.newestCloudLookFinished else { return }
            self.newestCloudLookFinished = look
            self.cloudDetection = detection
            let waiters = self.cloudCheckWaiters
            self.cloudCheckWaiters = []
            waiters.forEach { $0(detection) }
        }
    }

    /// Settings' Use and Replace: what iCloud holds now, not at the last look.
    func chooseCloudSidebarAfterLooking(_ choice: CloudSidebarChoice) {
        syncCloudMessage = nil
        checkCloudSidebar { [weak self] detection in
            guard let self else { return }
            switch detection {
            case .found(let found): self.chooseCloudSidebar(choice, from: found)
            case .empty: self.syncCloudMessage = "iCloud has no ReArc sidebar any more. Turn Sync Sidebar on to upload this Mac's."
            case .signedOut(let message), .unreachable(let message), .unavailable(let message): self.syncCloudMessage = message
            }
        }
    }

    /// Where "Use the iCloud sidebar" keeps the copy of this Mac's sidebar it replaces.
    var sidebarBackupFolder: URL { SidebarBackup.folder(besides: persistence.fileURL) }

    /// The folder as the sheet names it: "ReArc › Backups".
    var sidebarBackupFolderName: String {
        ShellDataLocation.isOverridden ? sidebarBackupFolder.path : "ReArc › Backups in your Application Support folder"
    }

    /// The person's answer for the sidebar in iCloud; sync is on afterwards.
    /// Using iCloud's backs this Mac's sidebar up first, and does nothing if that fails.
    func chooseCloudSidebar(_ choice: CloudSidebarChoice, from found: CloudSidebarFound) {
        syncCloudChoice = nil
        syncCloudMessage = nil
        if choice == .useCloud {
            do {
                _ = try SidebarBackup.write(store.makeSnapshot(), besides: persistence.fileURL, reason: "before-icloud")
            } catch {
                syncCloudMessage = "ReArc couldn't save a copy of this Mac's sidebar, so nothing was changed."
                return
            }
        }
        MainActor.assumeIsolated { syncControl?.apply(choice, from: found) }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        checkCloudSidebar()
    }

    /// Settings › Account › Delete iCloud Content…: this Mac's sidebar stays; sync turns off.
    func deleteCloudSidebar() {
        guard let control = syncControl else { return }
        syncCloudMessage = nil
        Task { @MainActor [weak self] in
            do {
                try await control.deleteCloudSidebar()
            } catch {
                self?.syncCloudMessage = (error as? SyncTransportError)?.userMessage ?? "iCloud couldn't delete ReArc's sidebar. Try again in a moment."
            }
            self?.checkCloudSidebar()
        }
    }

    func syncNow() {
        MainActor.assumeIsolated { syncControl?.syncNow() }
    }

    func attachSync() {
        MainActor.assumeIsolated {
            guard let control = syncControl else { return }
            control.attach(host: store)
            syncDetails = control.details
            control.onDetailsChange = { [weak self] details in
                self?.syncDetails = details
            }
            // Coming back to ReArc is a good moment to pick up other Macs' edits.
            syncActivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isSyncEnabled else { return }
                let last = self.syncDetails?.lastSyncedAt ?? .distantPast
                if Date().timeIntervalSince(last) > Self.syncActivationThrottle { self.syncNow() }
            }
        }
    }
}

/// A look at iCloud from Settings, while it runs.
enum CloudLookState: Equatable {
    case idle
    /// Items read so far, once the first batch is in.
    case looking(Int?)
    /// Nothing new for a while; the look carries on.
    case stalled(String)

    var isStalled: Bool {
        if case .stalled = self { return true }
        return false
    }
}
