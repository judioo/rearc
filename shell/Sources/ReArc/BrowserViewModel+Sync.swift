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

    func setSyncEnabled(_ enabled: Bool) {
        MainActor.assumeIsolated { syncControl?.setUserEnabled(enabled) }
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
