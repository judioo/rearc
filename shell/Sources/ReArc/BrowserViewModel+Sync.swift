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

    /// The switch in Settings › Account. Off is immediate. On looks at
    /// iCloud first (read-only): empty, it starts syncing; holding a
    /// sidebar, it asks what to do with it (`syncCloudChoice`); out of
    /// reach, it says so and the switch stays off.
    func setSyncEnabled(_ enabled: Bool) {
        syncCloudMessage = nil
        guard enabled else {
            MainActor.assumeIsolated { syncControl?.setUserEnabled(false) }
            return
        }
        checkCloudSidebar { [weak self] detection in
            guard let self else { return }
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

    /// A read-only look at iCloud for Settings › Account; `done` gets it too.
    func checkCloudSidebar(_ done: ((CloudSidebarDetection) -> Void)? = nil) {
        guard let control = syncControl, !isCheckingCloud else { return }
        isCheckingCloud = true
        Task { @MainActor [weak self] in
            let detection = await control.detectCloudSidebar()
            guard let self else { return }
            self.isCheckingCloud = false
            self.cloudDetection = detection
            done?(detection)
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
