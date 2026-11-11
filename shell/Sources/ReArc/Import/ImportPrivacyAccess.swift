import AppKit
import Onboarding
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
    @MainActor
    static func openSettings(for permission: ImportPermission) {
        SettingsAccess.open(permission)
        // macOS never lists ReArc in Full Disk Access by itself: offer its icon to drag in, beside Settings.
        guard permission == .fullDiskAccess else { return }
        SettingsAccess.whenSettingsAppears { frame in
            let layout = SettingsCompanionLayout.layout(screen: SettingsAccess.settingsScreen(for: frame), settings: frame,
                                                        helper: SettingsAccess.helperSize)
            if let helper = layout.helper { SettingsAccess.showDragHelper(at: helper) }
        }
    }

    /// "macOS keeps Brave private. Under ReArc in Privacy & Security › Files & Folders, switch on Brave, then come back."
    static func explanation(for browsers: [ImportBrowser], permission: ImportPermission) -> String {
        let names = ListFormatter.localizedString(byJoining: browsers.map(\.name))
        switch permission {
        case .appData:
            return "macOS keeps \(names) private. Under ReArc in Privacy & Security › Files & Folders, "
                + "switch on \(names), then come back."
        case .fullDiskAccess:
            return "macOS keeps \(names) private. Switch on ReArc in Privacy & Security › Full Disk Access. "
                + (macOSReopensThisCopy ? "If macOS offers Quit & Reopen, choose it."
                    : "If macOS offers Quit & Reopen, choose Later, then come back and relaunch ReArc here.")
        }
    }

    /// System Settings' "Quit & Reopen" opens ReArc by bundle id, so it
    /// reopens this copy only when it is the one copy Launch Services knows
    /// (a normal install). A test build beside /Applications/ReArc.app is not.
    static var macOSReopensThisCopy: Bool {
        let copies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        return copies.count == 1 && copies[0].standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Tells the relaunched ReArc to open the Import window again.
    static let reopenImportFlag = "--reopen-import"

    /// Only a bundled ReArc can be launched again (not `swift run`).
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Quits and opens this very copy again (`ReArcRelaunch`), on the same
    /// `REARC_DATA_DIR` and arguments. A first run's onboarding resumes by
    /// itself; `reopenImport` brings the Import window back.
    @MainActor
    static func relaunch(reopenImport: Bool) {
        guard canRelaunch, ReArcRelaunch.start(arguments: ReArcRelaunch.arguments(CommandLine.arguments, reopenImport: reopenImport))
        else { return }
        NSApp.terminate(nil)
    }
}

/// Relaunching exactly this bundle, never "the app with this bundle id"
/// (which may be /Applications/ReArc.app). A helper, this same executable
/// started with `helperFlag` in its own session, waits until this process
/// has gone, then opens `Bundle.main.bundleURL` with
/// `NSWorkspace.openApplication(at:configuration:)` as a new instance.
enum ReArcRelaunch {
    static let helperFlag = "--rearc-relaunch-helper"
    static let separator = "--"

    /// The relaunched app's arguments: this launch's, without the process
    /// serial number, the helper's own flag or a stale reopen flag.
    static func arguments(_ current: [String], reopenImport: Bool) -> [String] {
        var out = current.dropFirst().filter { !$0.hasPrefix("-psn_") && $0 != ImportPrivacyAccess.reopenImportFlag && $0 != helperFlag }
        if reopenImport { out.append(ImportPrivacyAccess.reopenImportFlag) }
        return out
    }

    /// `<exe> --rearc-relaunch-helper <pid> <bundle path> -- <arguments…>`
    static func helperArguments(pid: pid_t, bundle: URL, arguments: [String]) -> [String] {
        [helperFlag, String(pid), bundle.path, separator] + arguments
    }

    struct Request: Equatable {
        var pid: pid_t
        var bundle: URL
        var arguments: [String]
    }

    static func request(from argv: [String]) -> Request? {
        guard argv.count >= 5, argv[1] == helperFlag, let pid = pid_t(argv[2]), argv[4] == separator else { return nil }
        return Request(pid: pid, bundle: URL(fileURLWithPath: argv[3], isDirectory: true), arguments: Array(argv.dropFirst(5)))
    }

    /// The environment the new instance gets: the data folder, if this one had its own.
    static func environment(_ current: [String: String]) -> [String: String] {
        current[ShellDataLocation.environmentKey].map { [ShellDataLocation.environmentKey: $0] } ?? [:]
    }

    /// Starts the helper detached (its own session, so nothing ReArc does on
    /// the way out reaches it). False if it could not start.
    static func start(arguments: [String]) -> Bool {
        guard let exe = Bundle.main.executableURL?.path else { return false }
        let argv = [exe] + helperArguments(pid: ProcessInfo.processInfo.processIdentifier, bundle: Bundle.main.bundleURL, arguments: arguments)
        var attributes = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, exe, nil, &attributes, &cArgs, environ) == 0
    }

    /// Set in the reopened app's environment: who opened it, for `relaunch.log`.
    static let relaunchedByKey = "REARC_RELAUNCHED_BY"

    /// Whether this helper may act (RC-0.1.0-602 T-09): it reopens only the
    /// bundle it runs from, and only for the ReArc that started it (its
    /// parent, or launchd once that parent has already gone).
    static func accepts(_ request: Request, ownBundle: URL = Bundle.main.bundleURL, parent: pid_t = getppid()) -> Bool {
        let own = ownBundle.standardizedFileURL.resolvingSymlinksInPath()
        let asked = request.bundle.standardizedFileURL.resolvingSymlinksInPath()
        guard own.path == asked.path, own.pathExtension == "app" else { return false }
        return parent == request.pid || (parent == 1 && kill(request.pid, 0) != 0)
    }

    /// In the helper: wait (up to a minute) until the old ReArc has quit and
    /// Launch Services has let go of it, then open the bundle by its URL.
    static func runHelperIfAsked(_ argv: [String] = CommandLine.arguments) {
        guard let request = request(from: argv) else { return }
        guard accepts(request) else {
            OnboardingResumeTicket.log("relaunch helper refused: not this bundle's own relaunch (asked for \(request.bundle.path), pid \(request.pid))")
            exit(64)
        }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, kill(request.pid, 0) == 0 || NSRunningApplication(processIdentifier: request.pid) != nil {
            usleep(100_000)
        }
        usleep(300_000)
        let dir = ProcessInfo.processInfo.environment[ShellDataLocation.environmentKey]
        open(Bundle.main.bundleURL, arguments: request.arguments, dataDirectory: dir, by: "ReArc's Relaunch helper (old pid \(request.pid))")
        exit(0)
    }

    /// Opens exactly `bundle`, a new instance, with `arguments` and the data
    /// folder; waits for Launch Services to answer. Never by bundle id.
    static func open(_ bundle: URL, arguments: [String], dataDirectory: String?, by: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = arguments
        var env = dataDirectory.map { [ShellDataLocation.environmentKey: $0] } ?? [:]
        env[relaunchedByKey] = by
        configuration.environment = env
        let done = DispatchSemaphore(value: 0)
        var outcome = "no answer"
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
            outcome = app.map { "opened pid \($0.processIdentifier)" } ?? "failed: \(error?.localizedDescription ?? "unknown")"
            done.signal()
        }
        _ = done.wait(timeout: .now() + 30)
        OnboardingResumeTicket.log("\(by) opened \(bundle.path) (data \(dataDirectory ?? "default")): \(outcome)")
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
