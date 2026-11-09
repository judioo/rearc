#if REARC_CHROMIUM
import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()
    let isEnabled: Bool
    private var controller: SPUStandardUpdaterController?
    private weak var menuItem: NSMenuItem?
    private var menuState = UpdateMenuState() { didSet { refreshMenu() } }

    private override init() {
        isEnabled = Bundle.main.object(forInfoDictionaryKey: "ReArcRelease") as? Bool == true
        super.init()
        guard isEnabled else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

    var updater: SPUUpdater? { controller?.updater }

    func makeMenuItem() -> NSMenuItem? {
        guard let controller else { return nil }
        let item = NSMenuItem(title: menuState.title,
                              action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        menuItem = item
        refreshMenu()
        return item
    }

    private func refreshMenu() {
        menuItem?.title = menuState.title
        menuItem?.badge = menuState.badgeCount == 0 ? nil : .updates(count: menuState.badgeCount)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdatePreferences.allowedChannels(in: .standard)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        menuState.updateAvailable = true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        menuState.updateAvailable = false
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        menuState.updateAvailable = false
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Critical updates keep Sparkle's prominent presentation and cannot be skipped.
        update.isCriticalUpdate
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        MainActor.assumeIsolated { menuState.updateAvailable = true }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { menuState.updateAvailable = false }
    }
}

private struct UpdateSettingsGroup: View {
    @StateObject private var settings: UpdateSettings
    @AppStorage(UpdatePreferences.betaKey) private var receiveBetaUpdates = false

    init(updater: SPUUpdater) { _settings = StateObject(wrappedValue: UpdateSettings(updater: updater)) }

    var body: some View {
        SettingsGroup {
            SettingsSwitchRow(label: "Automatically download and install updates", isOn: $settings.automaticallyDownloadsUpdates)
            SettingsSwitchRow(label: "Receive beta updates", isOn: $receiveBetaUpdates)
        }
    }
}

@MainActor
private final class UpdateSettings: ObservableObject {
    private let updater: SPUUpdater
    private var observation: NSKeyValueObservation?
    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            if updater.automaticallyDownloadsUpdates != automaticallyDownloadsUpdates {
                updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
            }
        }
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        observation = updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                guard let value = change.newValue else { return }
                self?.automaticallyDownloadsUpdates = value
            }
        }
    }
}

struct UpdateSettingsSection: View {
    var body: some View {
        if let updater = AppUpdater.shared.updater { UpdateSettingsGroup(updater: updater) }
    }
}
#endif
