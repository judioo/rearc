import AppKit
import ArcBenchCore
import Foundation

/// Runs the plan against one target and adds its metrics to the report.
@MainActor
final class Runner {
    let options: Options
    let out: URL
    var report: RunReport

    private struct Accumulator {
        var scenario: String
        var method: TimingMethod
        var samples: [Double] = []
        var timeouts = 0
        var resolutionMs: Double
    }

    private var metrics: [String: Accumulator] = [:]
    private var metricOrder: [String] = []
    /// The window the last ⌥⌘N opened (only it may receive ⌘W).
    private var openedWindow: CGWindowID?
    private var noisyPresses = 0
    /// Notes from inside a step, moved onto the target after each scenario.
    private var pendingNotes: [String] = []

    init(options: Options, out: URL, report: RunReport) {
        self.options = options
        self.out = out
        self.report = report
    }

    nonisolated static func regionName(_ region: Region) -> String {
        region == .window ? "window" : "r:\(region.x0),\(region.y0),\(region.x1),\(region.y1)"
    }

    func run(_ target: Target) async throws {
        var target = target
        metrics = [:]
        metricOrder = []
        noisyPresses = 0
        pendingNotes = []
        let plan = ScenarioCatalog.plan(target.layout, groups: options.groups, regions: options.regions, reserved: target.reserved)
        target.notes += plan.skipped.map { "skipped \($0)" }
        let refreshHz = Display.refreshHz(for: target.window.bounds)
        let frameMs = 1000 / Double(refreshHz)
        var regions = ["content": Region.content(options.sidebarFraction)]
        for scenario in plan.scenarios { regions[Self.regionName(scenario.region)] = scenario.region }
        var keep: URL?
        if let dir = options.keepFrames {
            keep = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent(target.app.rawValue, isDirectory: true)
            try FileManager.default.createDirectory(at: keep!, withIntermediateDirectories: true)
        }
        log(target, "window \(target.window.id) \(Int(target.window.bounds.width))×\(Int(target.window.bounds.height)) pt on "
            + "\(Display.name(for: target.window.bounds)) at \(refreshHz) Hz; \(plan.scenarios.count) scenarios")
        guard try ensureKey(target) else { throw notKey(target) }
        let capture = WindowCapture(windowID: target.window.id, regions: regions, diff: options.diff, keepFrames: keep)
        try await capture.start(refreshHz: refreshHz, scale: options.captureScale)
        do {
            try await run(plan, target: &target, capture: capture, frameMs: frameMs, refreshHz: refreshHz)
        } catch {
            await capture.stop()
            flush(target, refreshHz: refreshHz)
            throw error
        }
        await capture.stop()
        flush(target, refreshHz: refreshHz)
    }

    private func run(_ plan: ScenarioCatalog.Plan, target: inout Target, capture: WindowCapture, frameMs: Double, refreshHz: Int) async throws {
        for _ in 0 ..< 40 where !capture.hasFrame { try await Task.sleep(nanoseconds: 50_000_000) }
        guard capture.hasFrame else { throw Failure("no frame captured from \(target.app.title)'s window") }
        if target.sidebarInitiallyHidden {
            guard try await toggleSidebar(target, capture) else { throw Failure("⌘S did not show the sidebar (pass --arc-sidebar if the start state was misread)") }
            target.notes.append("the sidebar was hidden: shown with ⌘S for the run")
        }
        do {
            try await scenarios(plan, target: &target, capture: capture, frameMs: frameMs, refreshHz: refreshHz)
        } catch {
            if target.sidebarInitiallyHidden { target.notes.append("the sidebar was left visible (\(error))") }
            throw error
        }
        if target.sidebarInitiallyHidden {
            let hidden = (try? await toggleSidebar(target, capture)) ?? false
            target.notes.append(hidden ? "hid the sidebar again with ⌘S" : "could not hide the sidebar again")
        }
    }

    /// ⌘S, and whether the sidebar column changed (it was shown or hidden).
    private func toggleSidebar(_ target: Target, _ capture: WindowCapture) async throws -> Bool {
        guard try ensureKey(target) else { return false }
        try await waitQuiet(capture)
        let before = capture.latestFrame
        _ = Keyboard.press(.commandS)
        try await Task.sleep(nanoseconds: 800_000_000)
        guard let before, let after = capture.latestFrame else { return false }
        return FrameDiff.changedFraction(before, after, in: .sidebar(options.sidebarFraction), settings: options.diff) > 0.05
    }

    private func scenarios(_ plan: ScenarioCatalog.Plan, target: inout Target, capture: WindowCapture, frameMs: Double, refreshHz: Int) async throws {
        var aborted: String?
        for scenario in plan.scenarios {
            log(target, "scenario \(scenario.id): \(options.warmups) warm-ups + \(options.iterations) iterations")
            guard try ensureKey(target) else { throw notKey(target) }
            try await waitQuiet(capture)
            let before = state(target, capture)
            iterationSamples = []
            do {
                for step in scenario.setup { _ = try await perform(step, scenario: scenario, target: target, capture: capture, frameMs: frameMs, record: false) }
                var index = 0
                var measured = 0
                var repeated = 0
                while measured < options.iterations {
                    let record = index >= options.warmups
                    focusLost = false
                    for step in scenario.iteration {
                        _ = try await perform(step, scenario: scenario, target: target, capture: capture, frameMs: frameMs,
                                              record: record, label: "\(scenario.id)-\(index)")
                    }
                    index += 1
                    guard record else { iterationSamples = []; continue }
                    if focusLost, repeated < options.iterations {
                        // Another app took focus during a press: its pixels include the window losing key status.
                        repeated += 1
                        iterationSamples = []
                        log(target, "\(scenario.id)-\(index - 1): another app took focus during the iteration; repeating it")
                        continue
                    }
                    commitIteration()
                    measured += 1
                }
                if repeated > 0 { pendingNotes.append("\(scenario.id): \(repeated) iteration(s) repeated because another app took focus during them") }
            } catch let error as GateClosed {
                _ = await restore(target, to: before, scenario: scenario, capture: capture)
                throw error
            } catch {
                target.notes.append("\(scenario.id): \(error)")
                aborted = "\(scenario.id) failed"
            }
            if let problem = await restore(target, to: before, scenario: scenario, capture: capture) {
                target.notes.append("\(scenario.id): \(problem)")
                aborted = aborted ?? problem
            }
            target.notes += pendingNotes
            pendingNotes = []
            flush(target, refreshHz: refreshHz)
            if let aborted {
                target.notes.append("stopped \(target.app.title) after \(scenario.id): \(aborted)")
                log(target, "stopping: \(aborted)")
                break
            }
        }
        if noisyPresses > 0 { target.notes.append("\(noisyPresses) presses were posted into a window that never went quiet for \(options.preQuietMs) ms") }
        if let error = capture.failure { target.notes.append("capture stopped: \(error)") }
    }

    // MARK: Steps

    /// Posts one step's key and times it. Throws GateClosed when the gate is gone.
    private func perform(_ step: Step, scenario: Scenario, target: Target, capture: WindowCapture, frameMs: Double,
                         record: Bool, label: String = "setup") async throws -> Bool {
        guard InputGuard.gateOpen else { throw GateClosed() }
        try await Task.sleep(nanoseconds: UInt64(options.pauseMs) * 1_000_000)
        if step.requiresOpenedWindow {
            // ⌘W goes only to the window ⌥⌘N opened, never to the browser window.
            guard let opened = openedWindow,
                  AX.frontmostPID == target.pid,
                  AX.focusedWindowID(target.pid) == opened else {
                if let opened = openedWindow {
                    pendingNotes.append("\(scenario.id): the window ⌥⌘N opened was not key: closed with its close button, not ⌘W")
                    if AX.closeWindow(target.pid, windowID: opened) { openedWindow = nil }
                }
                for id in step.measure.metricIDs { add(id, scenario: scenario, method: .windowList, value: nil, resolutionMs: 0, record: record) }
                return false
            }
        } else if step.toOwnPanel, AX.isKeyOrOwnPanel(target.pid, windowID: target.window.id) {
            // Esc for Arc's command bar, which is its own key window over the browser window.
        } else {
            guard try ensureKey(target) else { throw notKey(target) }
        }
        switch step.measure {
        case let .frames(base, suffix, content):
            try await waitQuiet(capture)
            capture.arm(keep: options.keepFrames == nil ? nil : label + "-" + step.chord.label)
            let posted = Keyboard.press(step.chord)
            let regionName = Self.regionName(scenario.region)
            var main = Detection.pending
            while main == .pending {
                try await Task.sleep(nanoseconds: 5_000_000)
                main = Detector.detect(capture.samples(regionName), postTime: posted, now: HostClock.now, settings: options.detection)
            }
            capture.disarm()
            noteFocus(target)
            let tail = suffix.map { ".\($0)" } ?? ""
            switch main {
            case let .measured(ack, settled):
                add("\(base).ack\(tail)", scenario: scenario, method: .pixels, value: ack * 1000, resolutionMs: frameMs, record: record)
                add("\(base).settled\(tail)", scenario: scenario, method: .pixels, value: settled.map { $0 * 1000 }, resolutionMs: frameMs, record: record)
            default:
                let seen = capture.samples(regionName).filter { $0.time > posted }
                log(target, String(format: "%@ %@: no change within %.0f ms (%d frames, largest change %.2f %%)", label, step.chord.label,
                                   options.detection.timeout * 1000, seen.count, (seen.map(\.fromBaseline).max() ?? 0) * 100))
                add("\(base).ack\(tail)", scenario: scenario, method: .pixels, value: nil, resolutionMs: frameMs, record: record)
                add("\(base).settled\(tail)", scenario: scenario, method: .pixels, value: nil, resolutionMs: frameMs, record: record)
            }
            if content {
                let detected = Detector.detect(capture.samples("content"), postTime: posted, now: .infinity, settings: options.detection)
                var value: Double?
                if case let .measured(ack, _) = detected { value = ack * 1000 }
                add("\(base).content\(tail)", scenario: scenario, method: .pixels, value: value, resolutionMs: frameMs, record: record)
            }
            return main != .noChange
        case let .windowOpens(id):
            let before = Set(WindowList.normal(pid: target.pid).map(\.id))
            let posted = Keyboard.press(step.chord)
            let seen = await poll(pid: target.pid, before: before, closing: nil)
            noteFocus(target)
            openedWindow = seen?.window
            add(id, scenario: scenario, method: .windowList, value: seen.map { ($0.time - posted) * 1000 },
                resolutionMs: (seen?.period ?? 0) * 1000, record: record)
            // Let the new window take key status before ⌘W is checked against it.
            for _ in 0 ..< 20 where openedWindow != nil && AX.focusedWindowID(target.pid) != openedWindow {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            return seen != nil
        case let .windowCloses(id):
            guard let closing = openedWindow else { return false }
            let posted = Keyboard.press(step.chord)
            let seen = await poll(pid: target.pid, before: [], closing: closing)
            if seen != nil { openedWindow = nil }
            add(id, scenario: scenario, method: .windowList, value: seen.map { ($0.time - posted) * 1000 },
                resolutionMs: (seen?.period ?? 0) * 1000, record: record)
            return seen != nil
        case .none:
            try await waitQuiet(capture)
            capture.arm()
            let posted = Keyboard.press(step.chord)
            var result = Detection.pending
            while result == .pending {
                try await Task.sleep(nanoseconds: 5_000_000)
                result = Detector.detect(capture.samples(Self.regionName(scenario.region)), postTime: posted, now: HostClock.now, settings: options.detection)
            }
            return result != .noChange
        }
    }

    private func poll(pid: pid_t, before: Set<CGWindowID>, closing: CGWindowID?) async -> (time: Double, window: CGWindowID?, period: Double)? {
        let timeout = options.detection.timeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInteractive).async {
                continuation.resume(returning: WindowList.waitForChange(pid: pid, before: before, closing: closing, timeout: timeout))
            }
        }
    }

    /// Waits (up to 3 s) until the window has been still for --pre-quiet-ms.
    private func waitQuiet(_ capture: WindowCapture) async throws {
        let window = Double(options.preQuietMs) / 1000
        let deadline = HostClock.now + 3
        while !capture.isQuiet(window: window, areaThreshold: options.diff.areaThreshold) {
            if HostClock.now > deadline {
                noisyPresses += 1
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func notKey(_ target: Target) -> Failure {
        Failure("\(target.app.title)'s browser window is not key (\(AX.describeFocus(target.pid, expected: target.window.id)))")
    }

    /// The target is frontmost with its browser window key; activates it (up to twice) if not.
    private func ensureKey(_ target: Target) throws -> Bool {
        guard InputGuard.gateOpen else { throw GateClosed() }
        if AX.isKey(target.pid, windowID: target.window.id) { return true }
        // Twice: another app may take focus back right after the first (an app that activates itself).
        return AX.activate(target.pid, windowID: target.window.id) || AX.activate(target.pid, windowID: target.window.id)
    }

    // MARK: State

    /// What a scenario must give back: the windows, the key window's title
    /// (in memory only) and the sidebar column's pixels.
    private struct AppState {
        var windows: Set<CGWindowID>
        var title: String?
        var frame: Frame?
        /// The app's own word for its selected tab and space, when it has one (Arc's AppleScript).
        var tab: String?
        var space: String?
    }

    private func state(_ target: Target, _ capture: WindowCapture) -> AppState {
        // Tooltip-sized windows are left out: a help tag under the pointer comes and goes on its own.
        AppState(windows: Set(WindowList.normal(pid: target.pid).filter { $0.bounds.width >= 200 && $0.bounds.height >= 100 }.map(\.id)),
                 title: AX.window(target.pid, id: target.window.id).flatMap(AX.title), frame: capture.latestFrame,
                 tab: target.selectedTab(), space: target.activeSpace())
    }

    /// The sidebar column differs from `before` (a tab, space or the sidebar
    /// itself did not come back). Static content gives 0; a moved row highlight ≈ 1–2 %.
    private func sidebarMoved(_ before: AppState, _ now: AppState) -> Double {
        guard let a = before.frame, let b = now.frame else { return 0 }
        return FrameDiff.changedFraction(a, b, in: .sidebar(options.sidebarFraction), settings: options.diff)
    }

    private func cameBack(_ before: AppState, _ now: AppState) -> Bool {
        let titleBack = (before.title ?? "").isEmpty || now.title == before.title
        let tabBack = before.tab == nil || now.tab == before.tab
        let spaceBack = before.space == nil || now.space == before.space
        return titleBack && tabBack && spaceBack && sidebarMoved(before, now) <= Self.restoreThreshold
    }

    static let restoreThreshold = 0.005

    /// Puts back the tab, space and sidebar the scenario started with; the
    /// problem left over, if any (the run then stops for this app).
    private func restore(_ target: Target, to before: AppState, scenario: Scenario, capture: WindowCapture) async -> String? {
        try? await Task.sleep(nanoseconds: 500_000_000)
        if let opened = openedWindow {
            _ = AX.closeWindow(target.pid, windowID: opened)
            openedWindow = nil
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard InputGuard.gateOpen else { return "gate closed before the state was checked" }
        _ = try? ensureKey(target)
        try? await Task.sleep(nanoseconds: 300_000_000)
        var now = state(target, capture)
        func press(_ chord: KeyChord) async {
            guard InputGuard.gateOpen, (try? ensureKey(target)) == true else { return }
            _ = Keyboard.press(chord)
            try? await Task.sleep(nanoseconds: 800_000_000)
            now = state(target, capture)
        }
        if !cameBack(before, now), scenario.group == "sidebar_toggle" {
            // An odd number of toggles took effect: one more puts the sidebar back.
            await press(.commandS)
        }
        if !cameBack(before, now), scenario.group == "space_switch" {
            let moved = sidebarMoved(before, now)
            _ = await target.returnHome()
            try? await Task.sleep(nanoseconds: 300_000_000)
            now = state(target, capture)
            if !cameBack(before, now), now.space == nil, sidebarMoved(before, now) > moved {
                // ReArc's return home is a toggle (Previous Space): it was home already, so toggle back.
                _ = await target.returnHome()
                try? await Task.sleep(nanoseconds: 300_000_000)
                now = state(target, capture)
            }
        }
        if !cameBack(before, now), scenario.movesTab || scenario.group == "space_switch", let tab = before.tab {
            // The app can select its starting tab itself (Arc's AppleScript), wherever it is in the sidebar.
            if await target.selectTab(tab) {
                try? await Task.sleep(nanoseconds: 500_000_000)
                now = state(target, capture)
            }
        }
        if !cameBack(before, now), scenario.movesTab || scenario.group == "space_switch" {
            // The plain tabs' ⌘n until the starting tab is back (by title and the sidebar's pixels).
            for number in target.layout.tabNumbers ?? Array(1 ... 8) {
                await press(.digit(number, .command))
                if cameBack(before, now) { break }
            }
        }
        var problems: [String] = []
        let extra = now.windows.subtracting(before.windows)
        if !extra.isEmpty { problems.append("\(extra.count) new window(s) left open") }
        if (before.title ?? "").isEmpty, scenario.movesTab {
            report.notes.append("\(target.app.title) \(scenario.id): no window title; the selected tab was checked by the sidebar's pixels only")
        }
        if !cameBack(before, now), scenario.movesTab, let first = target.layout.tabKeys?.first {
            // The starting tab is not one ⌘n reaches (in a folder, say): settle on the first plain tab and go on.
            await press(.digit(first, .command))
            pendingNotes.append("\(scenario.id): the starting tab did not come back by ⌘n; left on ⌘\(first)")
        } else if !cameBack(before, now) {
            problems.append(String(format: "did not come back (title %@, sidebar column %.1f %% different)",
                                   now.title == before.title ? "same" : "changed", sidebarMoved(before, now) * 100))
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    // MARK: Results

    /// Measured iteration's samples, kept until the iteration ends without losing focus.
    private var iterationSamples: [(id: String, scenario: Scenario, method: TimingMethod, value: Double?, resolutionMs: Double)] = []
    /// Another app was frontmost when a press of this iteration was timed.
    private var focusLost = false

    private func add(_ id: String, scenario: Scenario, method: TimingMethod, value: Double?, resolutionMs: Double, record: Bool) {
        guard record else { return }
        iterationSamples.append((id, scenario, method, value, resolutionMs))
    }

    /// Marks the iteration when another app is frontmost after a timed press, and says which (bundle id).
    private func noteFocus(_ target: Target) {
        guard let front = AX.frontmostPID, front != target.pid else { return }
        focusLost = true
        log(target, "frontmost after the press: \(NSRunningApplication(processIdentifier: front)?.bundleIdentifier ?? "pid \(front)")")
    }

    private func commitIteration() {
        for sample in iterationSamples {
            commit(sample.id, scenario: sample.scenario, method: sample.method, value: sample.value, resolutionMs: sample.resolutionMs)
        }
        iterationSamples = []
    }

    private func commit(_ id: String, scenario: Scenario, method: TimingMethod, value: Double?, resolutionMs: Double) {
        if metrics[id] == nil {
            metrics[id] = Accumulator(scenario: scenario.id, method: method, resolutionMs: resolutionMs)
            metricOrder.append(id)
        }
        if let value { metrics[id]!.samples.append(value) } else { metrics[id]!.timeouts += 1 }
        metrics[id]!.resolutionMs = max(metrics[id]!.resolutionMs, resolutionMs)
    }

    private func flush(_ target: Target, refreshHz: Int) {
        report.metrics.removeAll { $0.app == target.app }
        for id in metricOrder {
            let m = metrics[id]!
            report.metrics.append(MetricResult(scenario: m.scenario, app: target.app, metric: id, method: m.method,
                                               frameIntervalMs: (m.resolutionMs * 100).rounded() / 100, samples: m.samples, timeouts: m.timeouts))
        }
        report.apps.removeAll { $0.app == target.app }
        report.apps.append(AppRun(app: target.app, bundleID: target.bundleID, bundlePath: target.bundlePath, version: target.version,
                                  window: [Int(target.window.bounds.width), Int(target.window.bounds.height)], refreshHz: refreshHz,
                                  notes: target.notes))
        write()
    }

    func write() {
        try? report.json().write(to: out.appendingPathComponent("results.json"), options: .atomic)
        try? report.markdown().write(to: out.appendingPathComponent("results.md"), atomically: true, encoding: .utf8)
    }

    private func log(_ target: Target, _ message: String) {
        print("\(target.app.rawValue): \(message)")
    }
}
