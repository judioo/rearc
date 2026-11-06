import AppKit
import ApplicationServices
import ArcBenchCore
import Foundation
import SidebarModel

/// One app ready to measure: its process, its browser window and its spaces.
struct Target {
    var app: AppKind
    var pid: pid_t
    var bundlePath: String
    var bundleID: String
    var version: String?
    var window: WindowInfo
    var layout: SpaceLayout
    var notes: [String] = []
    /// The sidebar was hidden at the start: the run shows it with ⌘S and hides it again.
    var sidebarInitiallyHidden = false
    /// Back to the home space (Demo in Arc, the first space in ReArc).
    var returnHome: () async -> Bool
    /// Leaves the app as found (Arc: its home space and starting tab) or quits
    /// it (ReArc: the instance this run launched); a note on how it was left.
    var finish: () async -> String?
    /// The selected tab as an opaque token kept in memory (Arc: its AppleScript id), when the app can say.
    var selectedTab: () -> String? = { nil }
    /// Selects the tab `selectedTab` named; true when it is selected.
    var selectTab: (String) async -> Bool = { _ in false }
    /// The active space's name (Arc: AppleScript), when the app can say.
    var activeSpace: () -> String? = { nil }
    /// Keys taken before they reach the app: scenarios with them are skipped.
    var reserved = MacShortcuts.reserved
}

struct BundleInfo {
    var path: String
    var id: String?
    var version: String?

    init(path: String) {
        self.path = path
        let plist = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
        id = plist?["CFBundleIdentifier"] as? String
        version = plist?["CFBundleShortVersionString"] as? String
    }

    var exists: Bool { id != nil }
}

// MARK: - Arc

/// Arc: the user's own instance. Read-only except for the switch to its Demo
/// space and the scenarios' keys; it is quit only with --restart-arc.
enum ArcTarget {
    static let bundlePath = "/Applications/Arc.app"

    struct Inspection {
        var bundle: BundleInfo
        var pids: [pid_t]
        var window: WindowInfo?
        var spaces: [ArcSpace]
        var spacesError: String?
        var home: ArcSpace?
        var sidebar: AX.SidebarState
        var spacesMenuHasHome: Bool?

        var layout: SpaceLayout? { home.map { SpaceLayout(home: $0.index, count: spaces.count, tabNumbers: $0.tabNumbers) } }
        var neighbour: ArcSpace? { layout?.neighbourIndex.flatMap { index in spaces.first { $0.index == index } } }
    }

    static func inspect(_ options: Options) -> Inspection {
        let bundle = BundleInfo(path: bundlePath)
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: AppKind.arc.bundleID).map(\.processIdentifier)
        let window = pids.lazy.compactMap { WindowList.browserWindow(pid: $0) }.first
        var spaces: [ArcSpace] = []
        var spacesError: String?
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(ArcSidebar.defaultPath)
        do {
            spaces = try ArcSidebar.spaces(from: Data(contentsOf: file))
        } catch {
            spacesError = "\(file.path): \(error)"
        }
        let home = spaces.first { $0.title == options.arcSpace }
        var sidebar = AX.SidebarState.unknown
        var menuHasHome: Bool?
        if AX.trusted, let pid = window?.pid ?? pids.first {
            sidebar = AX.sidebarState(pid)
            let titles = AX.menuTitles(pid, "Spaces")
            if !titles.isEmpty { menuHasHome = titles.contains(options.arcSpace) }
        }
        return Inspection(bundle: bundle, pids: pids, window: window, spaces: spaces, spacesError: spacesError, home: home,
                          sidebar: sidebar, spacesMenuHasHome: menuHasHome)
    }

    static func prepare(_ options: Options) async throws -> Target {
        let bundle = BundleInfo(path: bundlePath)
        guard bundle.exists else { throw Failure("no Arc at \(bundlePath)") }
        var notes: [String] = []
        var running = NSRunningApplication.runningApplications(withBundleIdentifier: AppKind.arc.bundleID)
        if options.restartArc, !running.isEmpty {
            print("arc: --restart-arc: quitting Arc")
            for app in running { app.terminate() }
            let deadline = Date().addingTimeInterval(30)
            while running.contains(where: { !$0.isTerminated }), Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
            guard running.allSatisfy(\.isTerminated) else { throw Failure("Arc did not quit within 30 s (it is never force-quit)") }
            notes.append("Arc was restarted (--restart-arc)")
            running = []
        }
        if running.isEmpty {
            print("arc: launching Arc")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: bundlePath), configuration: configuration)
            if !options.restartArc { notes.append("Arc was not running; the harness started it") }
        }
        // Arc's window may be on another macOS desktop (not on screen): activating Arc brings it here.
        let window = try await waitForWindow("Arc", activating: { NSRunningApplication.runningApplications(withBundleIdentifier: AppKind.arc.bundleID).first }) {
            NSRunningApplication.runningApplications(withBundleIdentifier: AppKind.arc.bundleID)
                .lazy.compactMap { WindowList.browserWindow(pid: $0.processIdentifier) }.first
        }
        let pid = window.pid
        let inspection = inspect(options)
        guard let home = inspection.home, var layout = inspection.layout else {
            throw Failure("no Arc space named \"\(options.arcSpace)\" in StorableSidebar.json (\(inspection.spacesError ?? "\(inspection.spaces.count) spaces"))")
        }
        guard AX.activate(pid, windowID: window.id) else { throw Failure("could not make Arc's browser window key") }
        guard try await selectSpace(home, options: options, pid: pid, windowID: window.id) else {
            throw Failure("could not select Arc's \"\(home.title)\" space")
        }
        notes.append("space \"\(home.title)\" (\(home.index + 1) of \(inspection.spaces.count), \(home.pinned) pinned + \(home.unpinned) unpinned items; "
            + "plain tabs at ⌘\(home.tabNumbers.map(String.init).joined(separator: ", ⌘")) by its sidebar file)")
        // The tab Demo had selected, put back after every scenario and at the end (its id stays in memory).
        let startTab = ArcScript.activeTabID
        if let startTab {
            if let checked = try await checkTabKeys(home, layout: layout, pid: pid, windowID: window.id) {
                layout.tabNumbers = checked.numbers
                notes.append(checked.note)
            }
            if await !ArcScript.select(tab: startTab) { notes.append("could not reselect the starting tab after checking the ⌘n keys") }
        } else {
            notes.append("Arc's AppleScript gave no active tab: the ⌘n keys are not checked and the starting tab is restored by ⌘n only")
        }
        // The run needs the sidebar visible (the runner shows it, checks the pixels, and hides it again).
        // The View menu's title may lag a keyboard toggle; --arc-sidebar overrides it.
        let initiallyHidden = options.arcSidebar == "auto" ? AX.sidebarState(pid) == .hidden : options.arcSidebar == "hidden"
        let windowID = window.id
        var target = Target(app: .arc, pid: pid, bundlePath: bundlePath, bundleID: AppKind.arc.bundleID, version: bundle.version,
                            window: WindowList.normal(pid: pid).first { $0.id == windowID } ?? window, layout: layout, notes: notes,
                            returnHome: { (try? await selectSpace(home, options: options, pid: pid, windowID: windowID)) ?? false },
                            finish: { await leave(home, startTab: startTab, options: options, pid: pid, windowID: windowID) })
        target.sidebarInitiallyHidden = initiallyHidden
        target.selectedTab = { ArcScript.activeTabID }
        target.selectTab = { await ArcScript.select(tab: $0) }
        target.activeSpace = { ArcScript.activeSpace }
        return target
    }

    /// Arc's ⌘n numbering, checked rather than assumed: each key the sidebar
    /// file calls a plain tab is pressed once and AppleScript says which tab it
    /// selected (ids and URLs stay in memory). The scenarios use the first two
    /// keys that select different tabs showing different pages: two tabs of the
    /// same page differ only by the sidebar's faint highlight, below the diff
    /// threshold, so every switch between them would time out.
    static func checkTabKeys(_ home: ArcSpace, layout: SpaceLayout, pid: pid_t, windowID: CGWindowID) async throws -> (numbers: [Int], note: String)? {
        var seen: [(number: Int, id: String, url: String?)] = []
        for number in layout.tabNumbers ?? [] {
            guard InputGuard.gateOpen else { throw GateClosed() }
            guard AX.isKey(pid, windowID: windowID) || AX.activate(pid, windowID: windowID) else { return nil }
            _ = Keyboard.press(.digit(number, .command))
            try await Task.sleep(nanoseconds: 700_000_000)
            guard ArcScript.activeSpace == home.title else { return nil }
            // A key past the last tab selects nothing new (or the last tab again).
            guard let id = ArcScript.activeTabID, !seen.contains(where: { $0.id == id }) else { continue }
            seen.append((number, id, ArcScript.activeTabURL))
        }
        guard seen.count >= 2 else { return nil }
        var pair = (seen[0], seen[1])
        search: for i in seen.indices {
            for j in seen.indices where j > i && seen[i].url != seen[j].url {
                pair = (seen[i], seen[j])
                break search
            }
        }
        let rest = seen.map(\.number).filter { $0 != pair.0.number && $0 != pair.1.number }
        let distinct = pair.0.url != pair.1.url
        return ([pair.0.number, pair.1.number] + rest,
                "⌘n checked over AppleScript: \(seen.count) tabs at ⌘\(seen.map { String($0.number) }.joined(separator: ", ⌘")); "
                    + "the tab switch uses ⌘\(pair.0.number) and ⌘\(pair.1.number)"
                    + (distinct ? " (different pages)" : " (NOTE: the same page, so switches may not show)"))
    }

    /// Back on the home space with its starting tab selected; says how Arc was left.
    static func leave(_ home: ArcSpace, startTab: String?, options: Options, pid: pid_t, windowID: CGWindowID) async -> String {
        var space = ArcScript.activeSpace
        if space != home.title, InputGuard.gateOpen, (try? await selectSpace(home, options: options, pid: pid, windowID: windowID)) == true {
            space = ArcScript.activeSpace
        }
        var tabBack = startTab.map { ArcScript.activeTabID == $0 }
        if tabBack == false, let startTab { tabBack = await ArcScript.select(tab: startTab) }
        let windows = WindowList.normal(pid: pid).filter(WindowList.isBrowserSized).count
        return "Arc left on space \"\(space ?? "?")\"" + (space == home.title ? "" : " (NOT \"\(home.title)\")")
            + (tabBack.map { $0 ? ", its starting tab selected" : ", its starting tab NOT selected" } ?? ", starting tab unknown")
            + ", \(windows) browser window\(windows == 1 ? "" : "s")"
    }

    /// ⌃n for the first nine spaces; otherwise the Spaces menu item of that
    /// name, pressed over Accessibility (the menu is never opened).
    static func selectSpace(_ space: ArcSpace, options: Options, pid: pid_t, windowID: CGWindowID) async throws -> Bool {
        guard InputGuard.gateOpen else { throw GateClosed() }
        guard AX.isKey(pid, windowID: windowID) || AX.activate(pid, windowID: windowID) else { return false }
        if space.index < 9 {
            _ = Keyboard.press(.digit(space.index + 1, .control))
        } else {
            guard let item = AX.menuItem(pid, "Spaces", space.title), AX.press(item) else { return false }
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        // AppleScript names the active space; else Arc marks it in its Spaces menu when it marks any.
        if let active = ArcScript.activeSpace { return active == space.title }
        let marked = AX.markedItems(pid, "Spaces")
        return marked.isEmpty || marked.contains(space.title)
    }
}

/// Arc's AppleScript (`osascript`, Automation permission for the host
/// process): the active space's name and the active tab's id. Output stays
/// in memory and is never written; tab titles and URLs are never asked for.
enum ArcScript {
    static func run(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static var activeSpace: String? { run(#"tell application "Arc" to return title of active space of front window"#) }

    static var activeTabID: String? { run(#"tell application "Arc" to return id of active tab of front window"#) }

    /// Compared with other tabs' only, to tell pages apart; never written or printed.
    static var activeTabURL: String? { run(#"tell application "Arc" to return URL of active tab of front window"#) }

    /// Selects the tab with this id in Arc's front window; true once it is the active tab.
    static func select(tab id: String) async -> Bool {
        // Arc's tab ids are UUIDs; anything else is not put into a script.
        guard !id.isEmpty, id.allSatisfy({ $0.isHexDigit || $0 == "-" }), InputGuard.gateOpen else { return false }
        _ = run(#"tell application "Arc" to tell front window to tell (first tab whose id is "\#(id)") to select"#)
        for _ in 0 ..< 10 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if activeTabID == id { return true }
        }
        return false
    }
}

// MARK: - ReArc

/// ReArc: a fresh instance of the release bundle on a throwaway
/// REARC_DATA_DIR (two seeded spaces), never the user's data. Quit at the end.
enum ReArcTarget {
    static let spaces = 2
    static let pinnedPerSpace = 2
    static let todayPerSpace = 3
    /// Every seeded item is a tab: ⌘1…⌘5.
    static let layout = SpaceLayout(home: 0, count: spaces, tabNumbers: Array(1 ... pinnedPerSpace + todayPerSpace))

    /// macOS's shortcuts, and Arc's global ⌥⌘N while Arc runs (it would open a Little Arc in Arc).
    static var reserved: [ReservedShortcut] {
        let arcRuns = !NSRunningApplication.runningApplications(withBundleIdentifier: AppKind.arc.bundleID).isEmpty
        return MacShortcuts.reserved + (arcRuns ? [SystemShortcuts.arcLittleArc] : [])
    }

    static func inspect(_ options: Options) -> (bundle: BundleInfo, others: Int) {
        let bundle = BundleInfo(path: bundlePath(options))
        return (bundle, NSRunningApplication.runningApplications(withBundleIdentifier: bundle.id ?? AppKind.rearc.bundleID).count)
    }

    /// `shell/`, from this executable's place in `shell/.build/<config>/`.
    static var shellDirectory: URL {
        URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func bundlePath(_ options: Options) -> String {
        if let bundle = options.bundle { return (bundle as NSString).expandingTildeInPath }
        return shellDirectory.appendingPathComponent("dist/release/ReArc.app").path
    }

    static func prepare(_ options: Options, out: URL, matching arcWindow: WindowInfo?) async throws -> Target {
        let bundle = BundleInfo(path: bundlePath(options))
        guard bundle.exists else { throw Failure("no ReArc bundle at \(bundle.path) (--bundle)") }
        var notes: [String] = []
        if bundle.id != AppKind.rearc.bundleID { notes.append("bundle id \(bundle.id ?? "?"), not \(AppKind.rearc.bundleID)") }
        let data = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("arc-vs-rearc-data-\(UUID().uuidString)", isDirectory: true)
        try seed(data)
        if !options.keepData { Cleanup.add { try? FileManager.default.removeItem(at: data) } }
        notes.append("REARC_DATA_DIR \(options.keepData ? data.path : "(throwaway, removed afterwards)"): \(spaces) spaces × \(pinnedPerSpace) pinned + \(todayPerSpace) Today tabs (local file pages)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: bundle.path + "/Contents/MacOS/ReArc")
        var environment = ProcessInfo.processInfo.environment
        environment["REARC_DATA_DIR"] = data.path
        process.environment = environment
        let log = out.appendingPathComponent("rearc.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        print("rearc: launching \(bundle.path) with REARC_DATA_DIR=\(data.path)")
        try process.run()
        let pid = process.processIdentifier
        Cleanup.add {
            guard process.isRunning else { return }
            NSRunningApplication(processIdentifier: pid)?.terminate()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { process.terminate() }
        }
        var window = try await waitForWindow("ReArc", activating: { NSRunningApplication(processIdentifier: pid) }) { WindowList.browserWindow(pid: pid) }
        // Pages load and the launch settles before the first key.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        if options.matchArcSize, let arcWindow {
            if AX.setFrame(pid, windowID: window.id, arcWindow.bounds) {
                try await Task.sleep(nanoseconds: 800_000_000)
                window = WindowList.normal(pid: pid).first { $0.id == window.id } ?? window
                notes.append("window set to Arc's size")
            } else {
                notes.append("could not set the window to Arc's size")
            }
        }
        let windowID = window.id
        var target = Target(app: .rearc, pid: pid, bundlePath: bundle.path, bundleID: bundle.id ?? "?", version: bundle.version, window: window,
                      layout: layout, notes: notes,
                      returnHome: {
                          guard InputGuard.gateOpen, AX.isKey(pid, windowID: windowID) || AX.activate(pid, windowID: windowID) else { return false }
                          // ⌃1, unless macOS takes it (Switch to Desktop 1): then Previous Space, which
                          // toggles between the two seeded spaces (ReArc wraps around).
                          let home = KeyChord.digit(1, .control)
                          _ = Keyboard.press(MacShortcuts.reserved.contains { $0.matches(home) } ? .optionCommandLeft : home)
                          try? await Task.sleep(nanoseconds: 800_000_000)
                          return true
                      },
                      finish: {
                          guard process.isRunning else { return nil }
                          NSRunningApplication(processIdentifier: pid)?.terminate()
                          for _ in 0 ..< 100 where process.isRunning { try? await Task.sleep(nanoseconds: 100_000_000) }
                          if process.isRunning { process.terminate() }
                          return nil
                      })
        target.reserved = reserved
        return target
    }

    /// sidebar.json with two spaces of local pages (distinct colours, no
    /// animation, no caret), the first tab of the first space selected.
    static func seed(_ directory: URL) throws {
        let pages = directory.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        let colours = ["#1d4ed8", "#b91c1c", "#047857", "#7c3aed", "#c2410c", "#0e7490", "#be185d", "#4d7c0f", "#a16207", "#334155"]
        let store = SidebarStore()
        let profile = store.profiles[0].id
        var spaceIDs = [store.spaces(in: profile)[0].id]
        _ = store.renameSpace(spaceIDs[0], to: "Bench A")
        for index in 1 ..< spaces {
            var draft = SpaceDraft.suggested(in: store, profileID: profile)
            draft.name = "Bench \(Character(UnicodeScalar(65 + index)!))"
            guard let space = store.createSpace(from: draft) else { throw Failure("could not seed space \(index + 1)") }
            spaceIDs.append(space.id)
        }
        var firstTabs: [Tab.ID] = []
        var page = 0
        for (spaceIndex, spaceID) in spaceIDs.enumerated() {
            let letter = Character(UnicodeScalar(65 + spaceIndex)!)
            var first: Tab.ID?
            for tabIndex in 0 ..< pinnedPerSpace + todayPerSpace {
                let title = "Bench \(letter)\(tabIndex + 1)"
                let file = pages.appendingPathComponent("\(letter)\(tabIndex + 1).html".lowercased())
                let html = """
                <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
                <style>html,body{margin:0;height:100%;background:\(colours[page % colours.count]);color:#fff;font:600 64px -apple-system,sans-serif}
                body{display:flex;align-items:center;justify-content:center}</style></head><body>\(title)</body></html>
                """
                try html.write(to: file, atomically: true, encoding: .utf8)
                page += 1
                let tab = store.addTab(kind: tabIndex < pinnedPerSpace ? .pinned : .today, title: title, url: file, in: spaceID)
                if first == nil { first = tab.id }
            }
            if let first { firstTabs.append(first) }
        }
        for (spaceID, tab) in zip(spaceIDs, firstTabs).reversed() {
            store.selectSpace(spaceID)
            store.selectTab(tab)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(store.makeSnapshot()).write(to: directory.appendingPathComponent("sidebar.json"), options: .atomic)
    }
}

/// Waits up to 60 s for the app's browser window on screen. After 2 s, and
/// every 5 s after that, it activates the app: a window on another macOS
/// desktop is not on screen until the app is activated.
func waitForWindow(_ name: String, activating app: () -> NSRunningApplication?, _ find: () -> WindowInfo?) async throws -> WindowInfo {
    let start = Date()
    var activated: Date?
    while Date().timeIntervalSince(start) < 60 {
        if let window = find() { return window }
        if Date().timeIntervalSince(start) > 2, Date().timeIntervalSince(activated ?? .distantPast) > 5, let app = app() {
            guard InputGuard.gateOpen else { throw GateClosed() }
            print("\(name.lowercased()): no browser window on screen: activating \(name)")
            AXUIElementSetAttributeValue(AX.app(app.processIdentifier), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            app.activate()
            activated = Date()
        }
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    throw Failure("\(name) showed no browser window on screen within 60 s, even after activating it")
}
