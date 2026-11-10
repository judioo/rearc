import AppKit
import SidebarModel

/// Getting past macOS's privacy protection of other browsers' data
/// (PROFILE-IMPORT §6): which apps are installed, the System Settings pane
/// that allows ReArc, and the relaunch some switches need. The Import window
/// and the onboarding use the same pieces.
enum ImportPrivacyAccess {
    /// Launch Services first, then the standard folders. Chromium only by
    /// folder: ReArc's own engine and any build tree register a Chromium.app.
    static func isInstalled(_ browser: ImportBrowser) -> Bool {
        if browser == .chromium { return browser.isInstalledAtStandardLocation }
        return browser.bundleIdentifiers.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
            || browser.isInstalledAtStandardLocation
    }

    /// Every browser on this Mac, off the main thread.
    static func discover(in applicationSupport: URL = BrowserImportDiscovery.applicationSupport) -> [DiscoveredBrowser] {
        BrowserImportDiscovery.discover(in: applicationSupport, installed: isInstalled)
    }

    /// The pane that allows ReArc. macOS has no prompt to ask with: it
    /// records the attempt and denies it, so the person switches it on there.
    static func openSettings(for permission: ImportPermission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    /// "Allow ReArc to read Brave's data in System Settings › Privacy & Security › Files & Folders."
    static func explanation(for browsers: [ImportBrowser], permission: ImportPermission) -> String {
        let names = ListFormatter.localizedString(byJoining: browsers.map(\.name))
        switch permission {
        case .appData:
            return "macOS keeps \(names) data private. Allow ReArc under Privacy & Security › Files & Folders "
                + "(or give it Full Disk Access), then come back here."
        case .fullDiskAccess:
            return "macOS lets only apps with Full Disk Access read \(names) data. Switch ReArc on under "
                + "Privacy & Security › Full Disk Access, then come back here."
        }
    }

    /// Tells the relaunched ReArc to open the Import window again.
    static let reopenImportFlag = "--reopen-import"

    /// Only a bundled ReArc can be launched again (not `swift run`).
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Quits and opens this same bundle again once this process has gone,
    /// on the same `REARC_DATA_DIR` and arguments. A first run's onboarding
    /// resumes by itself (`onboarding-pending`); `reopenImport` brings the
    /// Import window back.
    @MainActor
    static func relaunch(reopenImport: Bool) {
        guard canRelaunch else { return }
        var open = ["-n", Bundle.main.bundleURL.path]
        if let dir = ProcessInfo.processInfo.environment[ShellDataLocation.environmentKey] {
            open += ["--env", "\(ShellDataLocation.environmentKey)=\(dir)"]
        }
        var arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") && $0 != reopenImportFlag }
        if reopenImport { arguments.append(reopenImportFlag) }
        if !arguments.isEmpty { open += ["--args"] + arguments }
        // Waits up to a minute for this process to exit, then opens the bundle.
        let script = "pid=$1; shift; i=0; while [ $i -lt 600 ]; do kill -0 \"$pid\" 2>/dev/null || exec /usr/bin/open \"$@\"; sleep 0.1; i=$((i+1)); done"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "rearc-relaunch", String(ProcessInfo.processInfo.processIdentifier)] + open
        do {
            try task.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}

extension BrowserViewModel {
    /// After a relaunch the Import window asked for, it opens again.
    @MainActor
    func reopenImportAfterRelaunchIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(ImportPrivacyAccess.reopenImportFlag) else { return }
        DispatchQueue.main.async { [weak self] in self?.showBrowserImport() }
    }
}
