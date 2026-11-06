import AppKit
import ArcBenchCore
import CoreGraphics
import Foundation

// arc-vs-rearc: the same interactions timed in Arc and in ReArc from outside,
// by keystrokes and the target window's pixels (docs/ARC-VS-REARC-BENCH.md).
// Run it through scripts/arc-vs-rearc.sh, which builds it, runs the load
// guards and keeps the display awake. Exit codes: 0 done, 1 failed, 2 usage,
// 75 conditions do not hold (gate, lock, screen locked), 77 permissions.

let usage = """
usage: arc-vs-rearc [--dry-run] [--apps arc,rearc] [--scenarios LIST] [--iterations N] [--warmups N]
                    [--pause-ms MS] [--pre-quiet-ms MS] [--bundle APP] [--out DIR] [--keep-frames DIR]
                    [--restart-arc] [--arc-space NAME] [--arc-sidebar auto|visible|hidden]
                    [--channel-threshold N] [--area-threshold F]
                    [--stride N] [--quiet-ms MS] [--timeout-ms MS] [--region SCENARIO=REGION]
                    [--sidebar-fraction F] [--capture-scale F] [--lock-wait S] [--keep-data] [--no-match-size]
scenarios: \(ScenarioCatalog.groups.joined(separator: ", "))
Full description: scripts/arc-vs-rearc.sh --help and docs/ARC-VS-REARC-BENCH.md.
"""

func stderr(_ message: String) { FileHandle.standardError.write((message + "\n").data(using: .utf8)!) }

/// The process chain above this one: TCC grants Screen Recording and
/// Accessibility to the responsible app at the top (a terminal, T3 Code…).
func hostChain() -> String {
    var names: [String] = []
    var pid = getppid()
    for _ in 0 ..< 8 where pid > 1 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? withUnsafePointer(to: &info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        if names.last != name { names.append(name) }
        pid = info.kp_eproc.e_ppid
    }
    return names.joined(separator: " ← ")
}

func describe(_ plan: ScenarioCatalog.Plan, indent: String = "    ") -> [String] {
    var lines: [String] = []
    for scenario in plan.scenarios {
        let setup = scenario.setup.map(\.chord.label).joined(separator: " ")
        let keys = scenario.iteration.map(\.chord.label).joined(separator: " then ")
        let region = scenario.region == .window ? "" : ", region \(Runner.regionName(scenario.region))"
        lines.append("\(indent)\(scenario.id): \(setup.isEmpty ? "" : "setup \(setup); ")\(keys)\(region)")
        var seen = Set<String>()
        lines.append("\(indent)  → \(scenario.metricIDs.filter { seen.insert($0).inserted }.joined(separator: ", "))")
    }
    for skipped in plan.skipped { lines.append("\(indent)skipped: \(skipped)") }
    return lines
}

/// Checks and prints only: no input, no capture, no app launched or activated.
@MainActor
func dryRun(_ options: Options) -> Int32 {
    print("arc-vs-rearc --dry-run: no input is posted, nothing is captured, no app is started")
    print("host process: \(hostChain())")
    let screen = CGPreflightScreenCaptureAccess()
    let accessibility = AX.trusted
    print("permissions (for the host process above):")
    print("  Screen Recording: \(screen ? "granted" : "NOT granted — System Settings › Privacy & Security › Screen & System Audio Recording")")
    print("  Accessibility:    \(accessibility ? "granted" : "NOT granted — System Settings › Privacy & Security › Accessibility")")
    print("input gate \(InputGuard.gate.path): \(InputGuard.gateOpen ? "present" : "absent (a real run refuses)")")
    print("input lock \(InputGuard.lock.path): \(InputGuard.lockHeld ? "held by another run" : "free")")
    print("screen locked: \(Session.screenLocked ? "yes (a real run refuses)" : "no")")
    var arcWindow: WindowInfo?
    if options.apps.contains(.arc) {
        let arc = ArcTarget.inspect(options)
        print("Arc: \(arc.bundle.exists ? "\(arc.bundle.path) \(arc.bundle.version ?? "?") (\(arc.bundle.id ?? "?"))" : "not found at \(arc.bundle.path)")")
        if arc.pids.isEmpty {
            print("  not running: a real run starts it")
        } else {
            print("  running, pid \(arc.pids.map(String.init).joined(separator: ", "))\(options.restartArc ? "; --restart-arc quits and restarts it" : "; never quit (no --restart-arc)")")
        }
        if let window = arc.window {
            arcWindow = window
            print("  browser window \(window.id): \(Int(window.bounds.width))×\(Int(window.bounds.height)) pt on \(Display.name(for: window.bounds)) at \(Display.refreshHz(for: window.bounds)) Hz")
        } else if !arc.pids.isEmpty {
            print("  no on-screen browser window (≥ 800×500 pt) found")
        }
        if let error = arc.spacesError { print("  StorableSidebar.json: \(error)") }
        if let home = arc.home, let layout = arc.layout {
            let how = home.index < 9 ? "⌃\(home.index + 1)" : "its Spaces menu item over Accessibility (⌃n reaches spaces 1–9 only)"
            print("  \(arc.spaces.count) spaces; \"\(home.title)\" is space \(home.index + 1), selected with \(how)")
            print("  \"\(home.title)\": \(home.favorites) favorites, \(home.pinned) pinned + \(home.unpinned) unpinned top-level items; profile \(home.defaultProfile ? "default" : "other")")
            let folders = home.sidebarItems.enumerated().filter { $0.element == .folder }.map { "⌘\($0.offset + 1)" }
            print("  plain tabs at \(home.tabNumbers.map { "⌘\($0)" }.joined(separator: " "))"
                + (folders.isEmpty ? "" : "; folders at \(folders.joined(separator: " ")) are never pressed"))
            if let neighbour = arc.neighbour, let toward = layout.arrowTowardNeighbour {
                print("  neighbour: space \(neighbour.index + 1) \"\(neighbour.title)\" (\(toward.label) there, back the other way)"
                    + (neighbour.defaultProfile == home.defaultProfile ? "" : "; NOTE: a different profile"))
            }
            if let inMenu = arc.spacesMenuHasHome { print("  Spaces menu lists \"\(home.title)\": \(inMenu ? "yes" : "NO")") }
            let sidebar = options.arcSidebar == "auto" ? arc.sidebar.rawValue : "\(options.arcSidebar) (--arc-sidebar)"
            print("  sidebar: \(sidebar) from the View menu's title, which can lag a keyboard toggle"
                + (sidebar.hasPrefix("hidden") ? "; a run shows it with ⌘S, checks the pixels, hides it again" : "")
                + "; --arc-sidebar visible|hidden overrides")
            print("  plan:")
            describe(ScenarioCatalog.plan(layout, groups: options.groups, regions: options.regions, reserved: MacShortcuts.reserved)).forEach { print($0) }
        } else if arc.spacesError == nil {
            print("  no space named \"\(options.arcSpace)\": a real run refuses (--arc-space)")
        }
    }
    if options.apps.contains(.rearc) {
        let rearc = ReArcTarget.inspect(options)
        print("ReArc: \(rearc.bundle.exists ? "\(rearc.bundle.path) \(rearc.bundle.version ?? "?") (\(rearc.bundle.id ?? "?"))" : "not found at \(rearc.bundle.path) (--bundle)")")
        if rearc.bundle.exists, rearc.bundle.id != AppKind.rearc.bundleID { print("  NOTE: expected bundle id \(AppKind.rearc.bundleID)") }
        print("  a real run launches a new instance with REARC_DATA_DIR=<throwaway dir>: \(ReArcTarget.spaces) spaces × "
            + "\(ReArcTarget.pinnedPerSpace) pinned + \(ReArcTarget.todayPerSpace) Today tabs of local pages; never the user's data")
        if rearc.others > 0 { print("  \(rearc.others) ReArc instance(s) already running: left alone (input goes to the new instance's window only)") }
        if options.matchArcSize, let arcWindow { print("  its window is set to Arc's: \(Int(arcWindow.bounds.width))×\(Int(arcWindow.bounds.height)) pt") }
        print("  plan:")
        describe(ScenarioCatalog.plan(ReArcTarget.layout, groups: options.groups, regions: options.regions, reserved: ReArcTarget.reserved)).forEach { print($0) }
    }
    print("each scenario: \(options.warmups) warm-ups + \(options.iterations) iterations, \(options.pauseMs) ms pause, "
        + "window still for \(options.preQuietMs) ms before each key")
    print("frame diff: channel > \(options.diff.channelThreshold), area > \(options.diff.areaThreshold * 100) %, stride \(options.diff.stride), "
        + "capture at \(options.captureScale)× points; settled after \(options.quietMs) ms quiet; timeout \(options.timeoutMs) ms; "
        + "content region x ≥ \(options.sidebarFraction)")
    print("frames: \(options.keepFrames.map { "kept in \($0) (target windows only)" } ?? "not saved (numbers only)")")
    print("output: \(options.out ?? "shell/bench/results/arc-vs-rearc-<timestamp>/") results.json, results.md (not created by a dry run)")
    let ready = screen && accessibility
    print(ready ? "dry run: permissions OK" : "dry run: missing permissions (exit 77)")
    return ready ? 0 : 77
}

@MainActor
func realRun(_ options: Options) async -> Int32 {
    guard InputGuard.gateOpen else {
        stderr("arc-vs-rearc: refusing to run: no input gate \(InputGuard.gate.path) (the user has not allowed screen takeover)")
        return 75
    }
    guard !Session.screenLocked else {
        stderr("arc-vs-rearc: refusing to run: the screen is locked, so input would not reach the apps")
        return 75
    }
    guard CGPreflightScreenCaptureAccess(), AX.trusted else {
        stderr("arc-vs-rearc: Screen Recording and Accessibility are needed for \(hostChain()) (see --dry-run)")
        return 77
    }
    Cleanup.installSignalHandlers()
    print("arc-vs-rearc: waiting for the input lock \(InputGuard.lock.path)")
    guard await InputGuard.acquire(waiting: options.lockWaitSeconds) else {
        stderr("arc-vs-rearc: refusing to run: the input lock stayed taken for \(options.lockWaitSeconds) s")
        return 75
    }
    let formatter = ISO8601DateFormatter()
    let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let out = URL(fileURLWithPath: options.out.map { ($0 as NSString).expandingTildeInPath }
        ?? ReArcTarget.shellDirectory.appendingPathComponent("bench/results/arc-vs-rearc-\(stamp)").path, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    } catch {
        stderr("arc-vs-rearc: \(out.path): \(error)")
        return 1
    }
    let revision = ProcessInfo.processInfo.environment["REARC_REVISION"]
    let runner = Runner(options: options, out: out, report: RunReport(runID: "arc-vs-rearc-\(stamp)", startedAt: formatter.string(from: Date()),
                                                                      revision: revision, settings: options.summary))
    print("arc-vs-rearc: results in \(out.path)")
    var status: Int32 = 0
    var arcWindow: WindowInfo?
    for app in options.apps {
        do {
            let target: Target
            switch app {
            case .arc:
                target = try await ArcTarget.prepare(options)
                arcWindow = target.window
            case .rearc:
                target = try await ReArcTarget.prepare(options, out: out, matching: arcWindow ?? ArcTarget.inspect(options).window)
            }
            do {
                try await runner.run(target)
            } catch {
                if let note = await target.finish() { runner.report.notes.append(note) }
                throw error
            }
            if let note = await target.finish() { runner.report.notes.append(note) }
        } catch let error as GateClosed {
            runner.report.notes.append("\(app.title): \(error); stopped")
            stderr("arc-vs-rearc: \(error); stopping")
            status = 75
            break
        } catch {
            runner.report.notes.append("\(app.title): \(error)")
            stderr("arc-vs-rearc: \(app.title): \(error)")
            status = 1
        }
    }
    runner.report.finishedAt = formatter.string(from: Date())
    runner.write()
    print("arc-vs-rearc: wrote \(out.appendingPathComponent("results.md").path)")
    if let markdown = try? String(contentsOf: out.appendingPathComponent("results.md"), encoding: .utf8) { print(markdown) }
    Cleanup.run()
    return status
}

let options: Options
do {
    guard let parsed = try Options.parse(Array(CommandLine.arguments.dropFirst())) else {
        print(usage)
        exit(0)
    }
    options = parsed
} catch {
    stderr("arc-vs-rearc: \(error)\n\(usage)")
    exit(2)
}
if options.dryRun {
    exit(dryRun(options))
}
exit(await realRun(options))
