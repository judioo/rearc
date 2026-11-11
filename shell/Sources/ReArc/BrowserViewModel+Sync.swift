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
        syncDecisionPrompt = nil
        MainActor.assumeIsolated { syncControl?.setUserEnabled(enabled) }
    }

    /// An existing install nobody chose for: ask once before anything syncs
    /// (RC-0.1.0-602 T-01). The answer is saved at once; an unanswered
    /// prompt asks again at the next launch.
    func offerSyncDecisionIfNeeded() {
        MainActor.assumeIsolated {
            guard let control = syncControl, control.needsDecision, syncDecisionPrompt == nil else { return }
            syncDecisionPrompt = SyncDecisionPrompt(syncedBefore: control.syncedBeforeDecision)
        }
    }

    /// A new install's onboarding finished: sync is on by default then,
    /// unless the prompt is already asking.
    func enableSyncForNewInstall() {
        guard syncDecisionPrompt == nil else { return }
        MainActor.assumeIsolated { syncControl?.enableForNewInstall() }
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
