#if REARC_CHROMIUM
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ReArcEngine
import SidebarModel

/// `--rearc-bench`: perf-0's measurement run (docs/PERFORMANCE-PLAN.md §2.2).
///
/// It drives the real `ChromiumShell` the way the self-test does (same shell
/// setup, loopback fixture server, `ShellInput`), with three differences:
/// - no self-test anti-throttling switches: pages background and throttle as
///   they do for users;
/// - every measurement ends on an event: a presented frame from the
///   `PresentationProbe`, an engine presentation or page-timing event
///   (ABI 1.44), or an animation's completion. Waits have timeouts, recorded
///   as such; nothing polls for an end;
/// - each sample records how its input was delivered: `appkit-event` (posted
///   to the event queue, the real path) or `direct-entry` (the entry point the
///   shortcut handler or monitor calls, when the screen is locked and AppKit
///   drops synthesized input).
///
/// Output is raw samples plus conditions as JSON (`rearc.bench/1` before
/// finalizing); `scripts/bench.sh` adds build and machine details and the
/// statistics. Exit codes: 0 complete, 1 a scenario failed, 75 conditions do
/// not hold, 124 watchdog.
@MainActor
final class ChromiumBench {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    nonisolated static let watchdogSeconds = 2400.0
    static let exitConditions: Int32 = 75

    private let runtime: ChromiumRuntime
    private let options: EngineLaunchOptions.BenchOptions
    private let started = Date()
    private var exitStatus: Int32 = 0
    private var shutdownStatus: ReArcStatus?

    private var base = ""
    private var model: BrowserViewModel!
    private var shell: ChromiumShell!
    private var window: NSWindow!
    private var fixture: BenchFixture.Result!
    private let probe = PresentationProbe.shared
    private let metrics = ChromiumPerfMetrics.shared

    private var report = BenchReport()
    private let pageTimings = EventStream<ChromiumPageTiming>()
    private let presentations = EventStream<ChromiumViewPresentation>()
    private let animations = EventStream<BrowserViewModel.ShellAnimation>()
    private let hangs = HangWatchdog()
    private var cpu = CPUMeter()
    private var scenario = "setup"

    init(runtime: ChromiumRuntime, options: EngineLaunchOptions.BenchOptions) {
        self.runtime = runtime
        self.options = options
        probe.enable()
    }

    /// The probe must be on before the first window renders; `ChromiumHost` calls this before `run`.
    static func prepareLaunch() {
        PresentationProbe.shared.enable()
    }

    func start() {
        LaunchTimeline.engineReady = ProcessInfo.processInfo.systemUptime
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.watchdogSeconds) {
            print("BENCH FAIL: watchdog fired after \(Int(Self.watchdogSeconds)) s")
            fflush(stdout)
            _exit(124)
        }
        Task { @MainActor in
            do {
                try await self.run()
            } catch let refusal as Refusal {
                self.report.status = "refused"
                self.report.notes.append(refusal.reason)
                self.log("REFUSED \(refusal.reason)")
                self.exitStatus = Self.exitConditions
            } catch {
                self.report.status = "failed"
                self.report.notes.append(String(describing: error))
                self.log("FAIL \(error)")
                self.exitStatus = 1
            }
            self.finish()
        }
    }

    func exitCode(runResult: Int32) -> Int32 {
        log("ReArcEngineRun returned \(runResult) (shutdown \(shutdownStatus?.rearcName ?? "none"))")
        if exitStatus != 0 { return exitStatus }
        return runResult == 0 && shutdownStatus == .rearcOK ? 0 : 1
    }

    private func log(_ message: String) {
        print(String(format: "[bench %7.2fs] ", Date().timeIntervalSince(started)) + message)
        fflush(stdout)
    }

    // MARK: Run

    private struct Refusal: Error { let reason: String }

    private func run() async throws {
        let conditions = BenchConditions.current()
        report.conditions = conditions
        if conditions.displayAsleep {
            throw Refusal(reason: "the display is asleep (no display-link frames); hold `caffeinate -u` (bench.sh does)")
        }
        if conditions.screenLocked && !options.allowLocked {
            throw Refusal(reason: "the screen is locked; unlock it, or pass --rearc-bench-allow-locked (results are marked)")
        }
        if ProcessInfo.processInfo.thermalState != .nominal {
            throw Refusal(reason: "thermal state is \(ProcessInfo.processInfo.thermalState.rawValue), not nominal")
        }
        guard metrics.install(capabilities: runtime.capabilities) else {
            throw Refusal(reason: "the engine lacks perf_metrics (ABI \(runtime.capabilities.abiMinorVersion.map(String.init) ?? "absent") < 44)")
        }
        metrics.onPageTiming = { [pageTimings] in pageTimings.send($0) }
        metrics.onViewPresentation = { [presentations] in presentations.send($0) }
        report.engine = BenchReport.Engine(
            abiMinor: Int(runtime.capabilities.abiMinorVersion ?? 0), bridge: String(cString: ReArcEngineBridgeVersion()),
            chromium: String(cString: ReArcEngineVersion()))
        hangs.start { [weak self] in self?.scenario ?? "-" }

        // Generate the page set before the first request (first visits must not pay for it).
        _ = (BenchPages.images.count, BenchPages.spaScript.count, BenchPages.article.count, BenchPages.list.count)
        if let path = options.dumpPagesPath { try BenchPages.dump(to: URL(fileURLWithPath: path, isDirectory: true)) }
        let server = try LoopbackFixtureServer()
        LoopbackFixtureServer.configure { settings in
            settings.logsRequests = false
            settings.routes = BenchPages.route
        }
        let port = try await server.start()
        base = "http://127.0.0.1:\(port)"
        report.fixture = BenchReport.Fixture(sidebar: options.fixture, seed: options.seed, server: "loopback 127.0.0.1",
                                             pages: BenchPages.names)

        try await setUpShell()
        if options.suites.contains(.launchChild) {
            try await launchChild()
            return
        }
        if options.suites.contains(.ui) { try await uiSuite() }
        if options.suites.contains(.page) { try await pageSuite() }
        if options.suites.contains(.memory) { try await memorySuite() }
        report.status = report.status ?? "complete"
    }

    /// Written after every scenario too, so a stopped run keeps its results.
    @discardableResult
    private func writeReport() -> Bool {
        report.hangs = hangs.hangs
        report.conditionsEnd = BenchConditions.current()
        report.elapsedSeconds = Date().timeIntervalSince(started)
        let path = options.outputPath ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("rearc-bench-\(ProcessInfo.processInfo.processIdentifier).json").path
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            log("could not write \(path): \(error)")
            return false
        }
    }

    private func finish() {
        hangs.stop()
        if writeReport() {
            log("wrote \(options.outputPath ?? "-") (\(report.metrics.count) metrics, status \(report.status ?? "-"))")
        } else if exitStatus == 0 {
            exitStatus = 1
        }
        for line in report.summaryLines() { log(line) }
        let status = runtime.requestShutdown(force: true) { [weak self] status, cancelled in
            self?.shutdownStatus = cancelled ? ReArcStatus(REARC_CANCELLED) : status
        }
        if status != .rearcOK {
            log("ReArcEngineShutdown rejected: \(status.rearcName)")
            _exit(1)
        }
    }

    // MARK: Shell setup

    private var delivery: ShellInput.Delivery { ShellInput.deliverable(window) ? .appKit : .direct }

    private func setUpShell() async throws {
        let size = BenchFixture.Size(rawValue: options.fixture) ?? .items500
        fixture = BenchFixture.make(size, seed: options.seed) { [base] in URL(string: "\(base)/bench/tab/\($0)")! }
        let store = fixture.store
        // A small page selected at start: the first Today tab of the first space.
        if let first = store.content(for: fixture.spaceIDs[0]).todayLeaves.first?.id { store.selectTab(first) }
        runtime.legacyDefaultOwner = store.profiles.first?.id
        let sidebarFile = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-bench-sidebar-\(UUID().uuidString).json")
        model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: sidebarFile),
                                 syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        model.onShellAnimationComplete = { [animations] in animations.send($0) }
        shell = ChromiumShell(runtime: runtime, autosavesFrames: false)
        shell.start(model: model)
        guard let window = shell.browserWindows.first else { throw Failure(description: "ChromiumShell opened no browser window") }
        self.window = window
        place(window)
        probe.attach(to: window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // A loopback default search: typed text never reaches a real engine.
        if runtime.capabilities.searchAutocomplete, let services = model.commandBarServices as? ChromiumCommandBarServices {
            let engine = try selectedEngine()
            _ = await engine.waitForTab()
            let loopback = SearchProvider(id: "bench", name: "ReArc Bench Search", keyword: "search.bench.invalid",
                                          searchTemplate: "\(base)/search?q=%s", suggestTemplate: "\(base)/suggest?q=%s")
            var status: ReArcStatus?
            runtime.setDefaultSearchProvider(profile: engine.engineProfileID, loopback) { status = $0 }
            try await settle("default search set", timeout: 10) { status != nil }
            services.refreshSearchProvider(for: model.store.activeProfileID)
        }
        try await settle("first tab loaded", timeout: 30) { [self] in
            (try? selectedEngine()).map { !$0.isLoading && $0.attachmentID != nil } ?? false
        }
        let screen = window.screen
        report.display = BenchReport.Display(
            refreshHz: screen?.maximumFramesPerSecond ?? 0, scale: Double(window.backingScaleFactor),
            points: [Int(screen?.frame.width ?? 0), Int(screen?.frame.height ?? 0)], name: screen?.localizedName ?? "-",
            window: [Int(window.contentLayoutRect.width), Int(window.contentLayoutRect.height)])
        report.inputDelivery = delivery.rawValue
        log("shell ready: \(fixture.tabIDs.count) tabs in \(fixture.spaceIDs.count) spaces, window \(report.display?.window ?? []) on "
            + "\(report.display?.name ?? "-") at \(report.display?.refreshHz ?? 0) Hz, input \(delivery.rawValue), "
            + "screen locked \(report.conditions?.screenLocked ?? false)")
    }

    /// The window on the built-in (120 Hz) display, 1440 × 900 pt of content.
    private func place(_ window: NSWindow) {
        let screen = NSScreen.screens.first { $0.maximumFramesPerSecond >= 120 } ?? NSScreen.main ?? window.screen
        guard let visible = screen?.visibleFrame else { return }
        window.setContentSize(NSSize(width: min(1440, visible.width), height: min(900, visible.height - 40)))
        window.setFrameOrigin(NSPoint(x: visible.minX + 20, y: visible.maxY - window.frame.height - 10))
    }

    private func selectedEngine() throws -> ChromiumEngine {
        guard let tab = model.store.selectedTab,
              let engine = model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab)) as? ChromiumEngine else {
            throw Failure(description: "no ChromiumEngine for the selected tab")
        }
        return engine
    }

    private func engine(for tabID: Tab.ID) -> ChromiumEngine? {
        guard let tab = model.store.tab(withID: tabID) else { return nil }
        return model.engineHost.engine(forTabID: tabID, profileID: model.profileID(for: tab)) as? ChromiumEngine
    }

    /// Setup and between-iteration waits only (never a measurement's end).
    private func settle(_ label: String, timeout: TimeInterval, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw Failure(description: "timed out waiting for \(label)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Between iterations: no tab loading, then 350 ms of quiet.
    private func quiet() async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, (try? selectedEngine())?.isLoading == true {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    // MARK: Measurement helpers

    private func ms(_ from: TimeInterval, _ to: TimeInterval?) -> Double? { to.map { ($0 - from) * 1000 } }
    private func ms(_ from: TimeInterval, micros: Int64?) -> Double? {
        micros.flatMap { $0 > 0 ? (Double($0) / 1e6 - from) * 1000 : nil }
    }

    private func record(_ id: String, _ value: Double?, unit: String = "ms", input: ShellInput.Delivery? = nil,
                        contaminated: Bool = false, warmup: Bool = false) {
        guard !warmup, options.runs(id) else { return }
        report.record(id, value, unit: unit, input: input?.rawValue, contaminated: contaminated)
    }

    /// Runs `body` for warm-ups and then `count` iterations, tagging each with
    /// the other processes' CPU share.
    private func iterate(_ name: String, count: Int? = nil,
                         _ body: (_ index: Int, _ warmup: Bool, _ contaminated: () -> Bool) async throws -> Void) async throws {
        guard options.runsScenario(name) else { return }
        scenario = name
        let total = count ?? options.iterations
        let pids = await metrics.processes().map(\.pid)
        log("scenario \(name): \(options.warmups) warm-ups + \(total) iterations, input \(delivery.rawValue)")
        for index in 0 ..< options.warmups + total {
            await quiet()
            let before = cpu.sample(pids: pids)
            var share: Double?
            try await body(index, index < options.warmups) {
                if share == nil { share = self.cpu.otherShare(since: before, pids: pids) }
                return (share ?? 0) > self.options.maxOtherCPU
            }
            if share == nil { share = cpu.otherShare(since: before, pids: pids) }
            report.noteCPU(name, share ?? 0)
        }
        writeReport()
    }

    /// Chromium presents and paints a page only while its window is visible:
    /// with the screen locked (occluded window) content events never come, so
    /// their waits are short and the timeouts are explained in the notes.
    private var contentCanPresent: Bool { window.occlusionState.contains(.visible) }
    private func contentTimeout(_ normal: TimeInterval) -> TimeInterval {
        if contentCanPresent { return normal }
        if !notedOcclusion {
            notedOcclusion = true
            report.notes.append("window occluded (screen locked): Chromium does not present or paint hidden pages, so content "
                + "metrics (tab switch content, FCP, LCP, resize presentation) time out; shell frames are still presented")
        }
        return 0.5
    }
    private var notedOcclusion = false

    private func press(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags) -> TimeInterval {
        ShellInput.press(characters, keyCode: keyCode, flags, in: window, model: model, delivery: delivery)
    }

    private func frameStats(_ id: String, from: Double?, to: Double?, input: ShellInput.Delivery, contaminated: Bool, warmup: Bool) {
        let stats = probe.stopRecording(window: window, from: from, to: to)
        guard from != nil, to != nil else { return }
        record(id + ".dropped", Double(stats.dropped), unit: "frames", input: input, contaminated: contaminated, warmup: warmup)
        record(id + ".hitch_ratio", stats.hitchRatioMsPerSecond, unit: "ms/s", input: input, contaminated: contaminated, warmup: warmup)
    }

    // MARK: UI suite

    private func uiSuite() async throws {
        try await sidebarToggle()
        try await sidebarPeek()
        try await spaceSwitch()
        try await profileSwitchWarm()
        try await profileSwitchCold()
        try await newTabAndLocation()
        try await commandBarTyping()
        try await tabSwitch()
        try await tabSwitcher()
        try await peek()
        try await littleArc()
        try await sidebarScroll()
    }

    /// ⌘S, show and hide alternating. ack: the first presented frame with the
    /// sidebar's new state; complete: the frame after the animation logically
    /// completes; content_lag: the page's first frame at its final size after that.
    private func sidebarToggle() async throws {
        try await iterate("ui.sidebar_toggle", count: options.iterations * 2) { index, warmup, contaminated in
            let showing = !model.isSidebarVisible
            let suffix = showing ? "show" : "hide"
            let input = delivery
            let tabID = (try? selectedEngine())?.tabID ?? 0
            let ack = probe.arm("sidebar", accepts: { $0 == (showing ? "shown" : "hidden") })
            let done = animations.arm(timeout: 10) { $0 == .sidebarToggle }
            probe.startRecording()
            let t0 = press("s", keyCode: 1, .command)
            let lastResize = presentations.arm(timeout: contentTimeout(1.5)) { $0.tabID == tabID && $0.kind == .resized && $0.status == .presented }
            let acked = await ack.value()
            let completed = await done.value()
            let complete = completed == nil ? nil : await probe.nextFrame(after: window)
            frameStats("ui.sidebar_toggle", from: acked?.callback, to: complete?.callback, input: input, contaminated: contaminated(), warmup: warmup)
            record("ui.sidebar_toggle.ack.\(suffix)", ms(t0, acked?.target), input: input, contaminated: contaminated(), warmup: warmup)
            record("ui.sidebar_toggle.complete.\(suffix)", ms(t0, complete?.target), input: input, contaminated: contaminated(), warmup: warmup)
            // The page resizes during the animation; its last frame at the final size ends the content lag.
            var final = await lastResize.value()
            while let event = final, let next = await presentations.arm(timeout: contentTimeout(0.3), { $0.tabID == tabID && $0.kind == .resized && $0.requestID > event.requestID }).value() {
                final = next
            }
            if let complete, let final {
                record("ui.sidebar_toggle.content_lag.\(suffix)", max(0, (Double(final.presentedMicros) / 1e6 - complete.target) * 1000),
                       input: input, contaminated: contaminated(), warmup: warmup)
            }
            _ = index
        }
        if !model.isSidebarVisible { model.toggleSidebar() }
    }

    /// Hover reveal with the sidebar hidden: a mouse move at x = 2 pt (or the
    /// monitor's own callback), then away past the floating sidebar.
    private func sidebarPeek() async throws {
        if model.isSidebarVisible {
            model.toggleSidebar()
            _ = await animations.arm(timeout: 2) { $0 == .sidebarToggle }.value()
        }
        try await iterate("ui.sidebar_peek") { _, warmup, contaminated in
            let input = delivery
            for reveal in [true, false] {
                let id = reveal ? "ui.sidebar_peek" : "ui.sidebar_unpeek"
                let ack = probe.arm("sidebar", accepts: { $0 == (reveal ? "hidden+peek" : "hidden") })
                let done = animations.arm(timeout: 2) { $0 == .sidebarPeek }
                probe.startRecording()
                let t0: TimeInterval
                let x: CGFloat = reveal ? 2 : model.sidebarWidth + 120
                if input == .appKit {
                    t0 = ShellInput.moveMouse(to: NSPoint(x: x, y: window.contentLayoutRect.height / 2), in: window)
                } else {
                    // SidebarEdgeHoverMonitor's onChange.
                    t0 = ProcessInfo.processInfo.systemUptime
                    model.setSidebarPeeking(reveal)
                }
                let acked = await ack.value()
                let completed = await done.value()
                let complete = completed == nil ? nil : await probe.nextFrame(after: window)
                frameStats(id, from: acked?.callback, to: complete?.callback, input: input, contaminated: contaminated(), warmup: warmup)
                record(id + ".ack", ms(t0, acked?.target), input: input, contaminated: contaminated(), warmup: warmup)
                record(id + ".complete", ms(t0, complete?.target), input: input, contaminated: contaminated(), warmup: warmup)
            }
        }
        model.setSidebarPeeking(false)
        model.toggleSidebar()
        _ = await animations.arm(timeout: 2) { $0 == .sidebarToggle }.value()
    }

    /// ⌃1 / ⌃2 between the first two spaces. ack: the switch's first frame;
    /// settled: the pager at rest; content: Chromium presented the new space's tab.
    private func spaceSwitch() async throws {
        let spaces = Array(model.store.spacesInActiveProfile.prefix(2))
        guard spaces.count == 2 else { return report.notes.append("ui.space_switch: fewer than two spaces") }
        try await iterate("ui.space_switch") { index, warmup, contaminated in
            let target = model.store.activeSpaceID == spaces[0].id ? spaces[1] : spaces[0]
            let number = target.id == spaces[0].id ? 1 : 2
            let input = delivery
            let ack = probe.arm("space", accepts: { $0.hasPrefix(target.id.uuidString) })
            let moving = probe.arm("pager", timeout: 1) { $0 == "moving" }
            let started = Int64(ProcessInfo.processInfo.systemUptime * 1e6)
            let content = presentations.arm(timeout: contentTimeout(2)) { $0.kind == .shown && $0.startMicros >= started }
            probe.startRecording()
            let t0 = press("\(number)", keyCode: number == 1 ? 18 : 19, .control)
            let acked = await ack.value()
            var settled = acked
            if await moving.value() != nil {
                settled = await probe.arm("pager", timeout: 3) { $0 == "rest" }.value()
            }
            let shown = await content.value()
            frameStats("ui.space_switch", from: acked?.callback, to: settled?.callback, input: input, contaminated: contaminated(), warmup: warmup)
            record("ui.space_switch.ack.ctrl_n", ms(t0, acked?.target), input: input, contaminated: contaminated(), warmup: warmup)
            record("ui.space_switch.settled.ctrl_n", ms(t0, settled?.target), input: input, contaminated: contaminated(), warmup: warmup)
            record("ui.space_switch.content.ctrl_n", ms(t0, micros: shown?.presentedMicros), input: input,
                   contaminated: contaminated(), warmup: warmup)
            _ = index
        }
        model.selectSpace(spaces[0].id)
    }

    /// A space in the other profile, whose engine profile is already open.
    /// The sidebar entry point (a space icon click, `selectSpace`).
    private func profileSwitchWarm() async throws {
        guard fixture.spaceIDs.count >= 4 else { return }
        let home = fixture.spaceIDs[0], other = fixture.spaceIDs[3]
        try await iterate("ui.profile_switch.warm") { _, warmup, contaminated in
            let target = model.store.activeSpaceID == other ? home : other
            let started = Int64(ProcessInfo.processInfo.systemUptime * 1e6)
            let sidebar = probe.arm("space", accepts: { $0.hasPrefix(target.uuidString) })
            let content = presentations.arm(timeout: contentTimeout(3)) { $0.kind == .shown && $0.startMicros >= started }
            let t0 = ProcessInfo.processInfo.systemUptime
            model.selectSpace(target)
            let presented = await sidebar.value()
            let shown = await content.value()
            record("ui.profile_switch.warm.sidebar", ms(t0, presented?.target), input: .direct, contaminated: contaminated(), warmup: warmup)
            record("ui.profile_switch.warm.content", ms(t0, micros: shown?.presentedMicros), input: .direct,
                   contaminated: contaminated(), warmup: warmup)
        }
        model.selectSpace(home)
    }

    /// A space in a new profile each time: its engine profile is not open.
    /// engine_profile ends when the tab exists (profile opened, tab created);
    /// content at the page's first contentful paint.
    private func profileSwitchCold() async throws {
        let home = fixture.spaceIDs[0]
        try await iterate("ui.profile_switch.cold", count: min(options.iterations, 15)) { index, warmup, contaminated in
            let store = model.store
            let profile = store.addProfile(name: "Bench Cold \(index + 1)")
            guard let space = store.createSpace(from: SpaceDraft.suggested(in: store, profileID: profile.id)) else { return }
            let url = URL(string: "\(base)/bench/article?cold=\(index)")!
            let tab = store.addTab(kind: .today, title: "Cold \(index + 1)", url: url, in: space.id)
            store.selectSpace(home)
            await quiet()
            let sidebar = probe.arm("space", accepts: { $0.hasPrefix(space.id.uuidString) })
            let fcp = pageTimings.arm(timeout: contentTimeout(10)) { $0.kind == .firstContentfulPaint && $0.url == url.absoluteString }
            let t0 = ProcessInfo.processInfo.systemUptime
            model.selectSpace(space.id)
            let presented = await sidebar.value()
            var opened: TimeInterval?
            if let engine = engine(for: tab.id), await engine.waitForTab() { opened = ProcessInfo.processInfo.systemUptime }
            let painted = await fcp.value()
            record("ui.profile_switch.cold.sidebar", ms(t0, presented?.target), input: .direct, contaminated: contaminated(), warmup: warmup)
            record("ui.profile_switch.cold.engine_profile", ms(t0, opened), input: .direct, contaminated: contaminated(), warmup: warmup)
            record("ui.profile_switch.cold.content", ms(t0, micros: painted?.valueMicros), input: .direct,
                   contaminated: contaminated(), warmup: warmup)
            model.selectSpace(home)
            _ = model.deleteProfile(profile.id, deletingSpaces: true)
        }
    }

    /// ⌘T (bar presented, then "abc" typed 5 ms later) and ⌘L.
    private func newTabAndLocation() async throws {
        try await iterate("ui.new_tab") { _, warmup, contaminated in
            let input = delivery
            let ack = probe.arm("commandbar", accepts: { $0 == "open|" })
            let typed = probe.arm("commandbar", accepts: { $0 == "open|abc" })
            let t0 = press("t", keyCode: 17, .command)
            let acked = await ack.value()
            try? await Task.sleep(nanoseconds: 5_000_000)
            let typing = type("abc")
            let ready = await typed.value()
            record("ui.new_tab.ack", ms(t0, acked?.target), input: input, contaminated: contaminated(), warmup: warmup)
            record("ui.new_tab.type_ready", ms(t0, ready?.target), input: typing, contaminated: contaminated(), warmup: warmup)
            record("ui.new_tab.lost_keys", Double(max(0, 3 - model.commandBarText.count)), unit: "keys", input: typing, warmup: warmup)
            await closeCommandBar()
        }
        try await iterate("ui.open_location") { _, warmup, contaminated in
            let input = delivery
            let ack = probe.arm("commandbar", accepts: { $0.hasPrefix("open|http") })
            let t0 = press("l", keyCode: 37, .command)
            let acked = await ack.value()
            record("ui.open_location.ack", ms(t0, acked?.target), input: input, contaminated: contaminated(), warmup: warmup)
            await closeCommandBar()
        }
    }

    /// Types into the command bar's field editor: real key events when they
    /// can be delivered, else `insertText:` (where interpretKeyEvents: sends them).
    @discardableResult
    private func type(_ text: String) -> ShellInput.Delivery {
        let input = delivery
        for character in text {
            let string = String(character)
            if input == .appKit {
                for kind in [NSEvent.EventType.keyDown, .keyUp] {
                    if let event = ShellInput.keyEvent(kind, string, keyCode: 0, [], in: window) { NSApp.postEvent(event, atStart: false) }
                }
            } else if let field = window.firstResponder as? NSTextView, field.isFieldEditor {
                field.insertText(string, replacementRange: field.selectedRange())
            } else {
                model.commandBarText += string
            }
        }
        if probe.traces {
            print("[bench] typed \(text) via \(input.rawValue) responder \(Swift.type(of: window.firstResponder)) text now '\(model.commandBarText)'")
        }
        return input
    }

    private func closeCommandBar() async {
        guard model.isCommandBarPresented else { return }
        let closed = probe.arm("commandbar", accepts: { $0 == "closed" })
        model.dismissCommandBar()
        _ = await closed.value()
    }

    /// One character at a time into an open bar, "wikipedia" repeatedly:
    /// echo (the character shown), local results (same text's rows), engine
    /// history and suggestions for that text, with the loopback suggest
    /// endpoint answering at once (d0) and after 100 ms (d100).
    private func commandBarTyping() async throws {
        let word = Array("wikipedia")
        for delay in [0, 100] {
            LoopbackFixtureServer.configure { $0.suggestDelay = Double(delay) / 1000 }
            model.newTab()
            _ = await probe.arm("commandbar", accepts: { $0 == "open|" }).value()
            var position = 0
            try await iterate("ui.cmdbar_key.d\(delay)") { _, warmup, contaminated in
                if position == word.count {
                    let cleared = probe.arm("commandbar", accepts: { $0 == "open|" })
                    model.commandBarText = ""
                    _ = await cleared.value()
                    position = 0
                }
                let text = String(word[0 ... position])
                position += 1
                let echo = probe.arm("commandbar", accepts: { $0 == "open|" + text })
                let local = probe.arm("results", accepts: { $0.hasPrefix(text + "|") })
                let history = probe.arm("results", timeout: 3) { $0.hasPrefix("\(text)|\(text)|") && !$0.contains("|-1|") }
                let suggestions = probe.arm("results", timeout: 3) {
                    let parts = $0.split(separator: "|", omittingEmptySubsequences: false)
                    return parts.count == 4 && parts[0] == text && parts[1] == text && (Int(parts[3]) ?? 0) > 0
                }
                let t0 = ProcessInfo.processInfo.systemUptime
                let input = type(String(text.last!))
                let shown = await echo.value()
                let rows = await local.value()
                let engineRows = await history.value()
                let suggested = await suggestions.value()
                if delay == 0 {
                    record("ui.cmdbar_key.echo", ms(t0, shown?.target), input: input, contaminated: contaminated(), warmup: warmup)
                    record("ui.cmdbar_key.local_results", ms(t0, rows?.target), input: input, contaminated: contaminated(), warmup: warmup)
                    record("ui.cmdbar_key.engine_history", ms(t0, engineRows?.target), input: input, contaminated: contaminated(), warmup: warmup)
                }
                record("ui.cmdbar_key.suggestions.d\(delay)", ms(t0, suggested?.target), input: input,
                       contaminated: contaminated(), warmup: warmup)
            }
            await closeCommandBar()
        }
        LoopbackFixtureServer.configure { $0.suggestDelay = 0 }
    }

    /// ⌘1 / ⌘2 (the menu's Tab 1 / Tab 2) and sidebar row clicks (`selectTab`).
    /// ack: the highlight's frame; content: Chromium presented the tab.
    private func tabSwitch() async throws {
        let today = model.store.content(for: fixture.spaceIDs[0]).todayLeaves.prefix(3).map(\.id)
        guard today.count >= 3 else { return }
        model.selectSpace(fixture.spaceIDs[0])
        try await iterate("ui.tab_switch.cmd_n") { index, warmup, contaminated in
            let before = model.store.selectedTabID
            let number = index % 2 + 1
            let input = delivery
            let ack = probe.arm("tab", accepts: { $0 != (before?.uuidString ?? "-") })
            let started = Int64(ProcessInfo.processInfo.systemUptime * 1e6)
            let content = presentations.arm(timeout: contentTimeout(2)) { $0.kind == .shown && $0.startMicros >= started }
            let t0 = press("\(number)", keyCode: number == 1 ? 18 : 19, .command)
            let acked = await ack.value()
            let shown = await content.value()
            record("ui.tab_switch.ack.cmd_n", ms(t0, acked?.target), input: input, contaminated: contaminated(), warmup: warmup)
            record("ui.tab_switch.content.cmd_n", ms(t0, micros: shown?.presentedMicros), input: input,
                   contaminated: contaminated(), warmup: warmup)
        }
        try await iterate("ui.tab_switch.click") { index, warmup, contaminated in
            let target = today[1 + index % 2]
            let ack = probe.arm("tab", accepts: { $0 == target.uuidString })
            let started = Int64(ProcessInfo.processInfo.systemUptime * 1e6)
            let content = presentations.arm(timeout: contentTimeout(2)) { $0.kind == .shown && $0.startMicros >= started }
            let t0 = ProcessInfo.processInfo.systemUptime
            model.selectTab(target)
            let acked = await ack.value()
            let shown = await content.value()
            record("ui.tab_switch.ack.click", ms(t0, acked?.target), input: .direct, contaminated: contaminated(), warmup: warmup)
            record("ui.tab_switch.content.click", ms(t0, micros: shown?.presentedMicros), input: .direct,
                   contaminated: contaminated(), warmup: warmup)
        }
    }

    /// ⌃Tab: the switcher overlay's frame; releasing ⌃: the chosen tab presented.
    private func tabSwitcher() async throws {
        try await iterate("ui.tab_switcher") { _, warmup, contaminated in
            let input = delivery
            let ack = probe.arm("switcher", accepts: { $0 == "open" })
            let t0 = press("\t", keyCode: 48, .control)
            let acked = await ack.value()
            let started = Int64(ProcessInfo.processInfo.systemUptime * 1e6)
            let content = presentations.arm(timeout: contentTimeout(2)) { $0.kind == .shown && $0.startMicros >= started }
            let closed = probe.arm("switcher", accepts: { $0 == "closed" })
            let t1 = ShellInput.releaseModifiers(in: window, model: model, delivery: input)
            let shown = await content.value()
            _ = await closed.value()
            record("ui.tab_switcher.ack", ms(t0, acked?.target), input: input, contaminated: contaminated(), warmup: warmup)
            record("ui.tab_switcher.release", ms(t1, micros: shown?.presentedMicros), input: input,
                   contaminated: contaminated(), warmup: warmup)
        }
    }

    /// Peek on a link (the entry point a Peek link calls): overlay frame,
    /// the page's first contentful paint, then dismiss.
    private func peek() async throws {
        try await iterate("ui.peek") { index, warmup, contaminated in
            let url = URL(string: "\(base)/bench/article?peek=\(index)")!
            let ack = probe.arm("peek", accepts: { $0 == url.absoluteString })
            let fcp = pageTimings.arm(timeout: contentTimeout(5)) { $0.kind == .firstContentfulPaint && $0.url == url.absoluteString }
            let t0 = ProcessInfo.processInfo.systemUptime
            model.showPeek(url: url)
            let acked = await ack.value()
            let painted = await fcp.value()
            record("ui.peek_open.ack", ms(t0, acked?.target), input: .direct, contaminated: contaminated(), warmup: warmup)
            record("ui.peek_open.content_fcp", ms(t0, micros: painted?.valueMicros), input: .direct, contaminated: contaminated(), warmup: warmup)
            let closed = probe.arm("peek", accepts: { $0 == "-" })
            let t1 = ProcessInfo.processInfo.systemUptime
            model.dismissPeek()
            record("ui.peek_close.ack", ms(t1, await closed.value()?.target), input: .direct, contaminated: contaminated(), warmup: warmup)
        }
    }

    /// ⌥⌘N (a blank Little Arc: its window's first frame) and a link routed
    /// to Little Arc (`openLittleArc`: window frame and the page's FCP).
    private func littleArc() async throws {
        try await iterate("ui.little_arc_open") { index, warmup, contaminated in
            let input = delivery
            let existing = Set(model.store.littleArcLiveWindows.map(\.id))
            let blank = probe.arm("littlearc", timeout: 5) { !existing.contains(UUID(uuidString: $0) ?? UUID()) }
            let t0 = press("n", keyCode: 45, [.command, .option])
            let opened = await blank.value()
            record("ui.little_arc_open.window.shortcut", ms(t0, opened?.target), input: input, contaminated: contaminated(), warmup: warmup)
            closeLittleArcs()

            let url = URL(string: "\(base)/bench/article?littlearc=\(index)")!
            let before = Set(model.store.littleArcLiveWindows.map(\.id))
            let frame = probe.arm("littlearc", timeout: 5) { !before.contains(UUID(uuidString: $0) ?? UUID()) }
            let fcp = pageTimings.arm(timeout: contentTimeout(8)) { $0.kind == .firstContentfulPaint && $0.url == url.absoluteString }
            let t1 = ProcessInfo.processInfo.systemUptime
            _ = model.openLittleArc(url: url)
            let shown = await frame.value()
            let painted = await fcp.value()
            record("ui.little_arc_open.window", ms(t1, shown?.target), input: .direct, contaminated: contaminated(), warmup: warmup)
            record("ui.little_arc_open.content_fcp", ms(t1, micros: painted?.valueMicros), input: .direct,
                   contaminated: contaminated(), warmup: warmup)
            closeLittleArcs()
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func closeLittleArcs() {
        for record in model.store.littleArcLiveWindows { model.closeLittleArcWindow(record.id) }
    }

    /// Scrolls the first space's Today list (fixture rows) for one second, one
    /// step per display frame, down then up: dropped frames and hitch ratio.
    private func sidebarScroll() async throws {
        model.selectSpace(fixture.spaceIDs[0])
        guard let scroll = sidebarScrollView() else { return report.notes.append("ui.sidebar_scroll: no sidebar NSScrollView found") }
        let rows = BenchFixture.layout(BenchFixture.Size(rawValue: options.fixture) ?? .items500).firstSpaceRows
        let id = "ui.sidebar_scroll.items\(rows >= 450 && rows < 600 ? 500 : rows)"
        try await iterate(id, count: max(10, options.iterations / 4)) { index, warmup, contaminated in
            let clip = scroll.contentView
            let range = max(0, (scroll.documentView?.frame.height ?? 0) - clip.bounds.height)
            let down = index % 2 == 0
            let step = range / 120
            probe.startRecording()
            var first: Double?, last: Double?
            var frames = 0
            await probe.eachFrame(of: window) { link in
                if first == nil { first = link.timestamp }
                last = link.timestamp
                frames += 1
                let y = down ? step * Double(frames) : range - step * Double(frames)
                clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), range)))
                scroll.reflectScrolledClipView(clip)
                return frames < 120
            }
            frameStats(id, from: first, to: last, input: .direct, contaminated: contaminated(), warmup: warmup)
        }
    }

    /// The tallest NSScrollView whose frame lies in the sidebar's column.
    private func sidebarScrollView() -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found.filter {
            let frame = $0.convert($0.bounds, to: nil)
            return frame.minX < model.sidebarWidth && frame.width <= model.sidebarWidth + 2
        }.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    // MARK: Page suite

    /// Each page of the loopback set in a new tab of the shell (the Return
    /// path: tab create, attach, load), ending on the engine's page-timing
    /// events; then the page's own Performance entries as a cross-check.
    private func pageSuite() async throws {
        for page in BenchPages.names {
            try await iterate("page.\(page)", count: max(10, options.iterations / 4)) { index, warmup, contaminated in
                let state = index == 0 ? "first" : "warm"
                let url = URL(string: "\(base)/bench/\(page)?n=\(index)")!
                let fcp = pageTimings.arm(timeout: contentTimeout(15)) { $0.kind == .firstContentfulPaint && $0.url == url.absoluteString }
                let load = pageTimings.arm(timeout: 15) { $0.kind == .loadEventStart && $0.url == url.absoluteString }
                let ttfb = pageTimings.arm(timeout: 15) { $0.kind == .responseStart && $0.url == url.absoluteString }
                let lcp = Ref<ChromiumPageTiming?>(nil)
                let lcpWatch = pageTimings.watch { if $0.kind == .largestContentfulPaint && $0.url == url.absoluteString { lcp.value = $0 } }
                let t0 = ProcessInfo.processInfo.systemUptime
                let tab = model.store.addTab(kind: .today, title: page, url: url)
                model.selectTab(tab.id)
                let painted = await fcp.value()
                let loaded = await load.value()
                let first = await ttfb.value()
                // LCP candidates keep coming until input; take the last within a second of load.
                try? await Task.sleep(nanoseconds: contentCanPresent ? 1_000_000_000 : 100_000_000)
                pageTimings.unwatch(lcpWatch)
                let w = warmup || state == "first"
                record("page.\(page).warm.ttfb", first?.milliseconds, contaminated: contaminated(), warmup: w)
                record("page.\(page).warm.fcp", painted?.milliseconds, contaminated: contaminated(), warmup: w)
                record("page.\(page).warm.lcp", lcp.value?.milliseconds, contaminated: contaminated(), warmup: w)
                record("page.\(page).warm.load", loaded?.milliseconds, contaminated: contaminated(), warmup: w)
                record("page.\(page).warm.input_to_fcp", ms(t0, micros: painted?.valueMicros), input: .direct,
                       contaminated: contaminated(), warmup: w)
                if state == "first", !warmup {
                    record("page.\(page).first.fcp", painted?.milliseconds, contaminated: contaminated())
                    record("page.\(page).first.load", loaded?.milliseconds, contaminated: contaminated())
                }
                if !warmup, let engine = engine(for: tab.id),
                   let js = try? await engine.evaluate(BenchPages.navigationTimingScript, in: .page) as? [String: Double] {
                    record("page.\(page).js.fcp", js["fcp"].flatMap { $0 >= 0 ? $0 : nil }, contaminated: contaminated())
                    record("page.\(page).js.load", js["load"].flatMap { $0 > 0 ? $0 : nil }, contaminated: contaminated())
                }
                model.closeTab(tab.id)
            }
        }
    }

    // MARK: Memory suite

    /// phys_footprint by process type: one blank page, then the four pages
    /// open (2 s settle each; three samples 2 s apart, median).
    private func memorySuite() async throws {
        scenario = "mem"
        func sample(_ label: String) async {
            var totals: [[String: Double]] = []
            for _ in 0 ..< 3 {
                let processes = await metrics.processes()
                var sums: [String: Double] = [:]
                for p in processes {
                    let key: String
                    switch p.kind {
                    case .browser: key = "browser"
                    case .renderer: key = p.isExtension ? "extension" : "renderer"
                    case .gpu: key = "gpu"
                    case .utility: key = "utility"
                    case .other: key = "other"
                    }
                    sums[key, default: 0] += Double(p.physFootprint) / 1_048_576
                    sums["total", default: 0] += Double(p.physFootprint) / 1_048_576
                }
                sums["processes"] = Double(processes.count)
                totals.append(sums)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            for key in Set(totals.flatMap(\.keys)) {
                let values = totals.compactMap { $0[key] }.sorted()
                record("mem.\(label).\(key)", values[values.count / 2], unit: key == "processes" ? "count" : "MB")
            }
        }
        await sample("idle_1tab")
        var opened: [Tab.ID] = []
        for page in BenchPages.names {
            let url = URL(string: "\(base)/bench/\(page)?mem=1")!
            let load = pageTimings.arm(timeout: 15) { $0.kind == .loadEventStart && $0.url == url.absoluteString }
            let tab = model.store.addTab(kind: .today, title: page, url: url)
            model.selectTab(tab.id)
            _ = await load.value()
            opened.append(tab.id)
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await sample("pages4")
        for id in opened { model.closeTab(id) }
    }

    // MARK: Launch child

    /// One cold launch (bench.sh starts the bundle N times): process start →
    /// engine ready → first presented browser frame → ⌘L handled → the
    /// selected page's first contentful paint.
    private func launchChild() async throws {
        scenario = "launch"
        let start = options.launchStart ?? LaunchTimeline.processStart ?? LaunchTimeline.main
        record("launch.exec_to_main", ms(start, LaunchTimeline.main))
        record("launch.main_to_engine_ready", ms(LaunchTimeline.main, LaunchTimeline.engineReady))
        let fcp = pageTimings.arm(timeout: 15) { $0.kind == .firstContentfulPaint }
        let visible = await probe.nextFrame(after: window)
        PerfSignposts.launchEvent("FirstSidebarFrame")
        record("launch.window_visible", ms(start, visible?.target))
        let bar = probe.arm("commandbar", accepts: { $0.hasPrefix("open") })
        _ = press("l", keyCode: 37, .command)
        let usable = await bar.value()
        PerfSignposts.launchEvent("FirstInputHandled")
        record("launch.first_usable", ms(start, usable?.target), input: delivery)
        let painted = await fcp.value()
        PerfSignposts.launchEvent("FirstPageFrame")
        record("launch.first_page_frame", ms(start, micros: painted?.valueMicros))
        report.status = "complete"
    }
}

/// Process-start and early milestones on the CACurrentMediaTime clock.
enum LaunchTimeline {
    nonisolated(unsafe) static var main: TimeInterval = ProcessInfo.processInfo.systemUptime
    nonisolated(unsafe) static var engineReady: TimeInterval?

    /// The process's start (kinfo_proc p_starttime), moved onto the uptime clock.
    static var processStart: TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        let startedWall = Double(started.tv_sec) + Double(started.tv_usec) / 1e6
        let nowWall = Date().timeIntervalSince1970
        return ProcessInfo.processInfo.systemUptime - (nowWall - startedWall)
    }
}

// MARK: - Events

/// Event-driven waits: `arm` before the action, `value()` after. A value
/// arriving resolves the first armed waiter it satisfies; a timeout resolves nil.
@MainActor
final class EventStream<T> {
    final class Pending {
        fileprivate var result: T??
        fileprivate var continuation: CheckedContinuation<T?, Never>?
        fileprivate func resolve(_ value: T?) {
            guard result == nil else { return }
            result = .some(value)
            continuation?.resume(returning: value)
            continuation = nil
        }
        func value() async -> T? {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
    }

    private var waiters: [(id: UUID, accepts: (T) -> Bool, pending: Pending)] = []
    private var watchers: [UUID: (T) -> Void] = [:]

    func arm(timeout: TimeInterval, _ accepts: @escaping (T) -> Bool) -> Pending {
        let pending = Pending()
        let id = UUID()
        waiters.append((id, accepts, pending))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                self.waiters.remove(at: index).pending.resolve(nil)
            }
        }
        return pending
    }

    func watch(_ body: @escaping (T) -> Void) -> UUID {
        let id = UUID()
        watchers[id] = body
        return id
    }

    func unwatch(_ id: UUID) { watchers.removeValue(forKey: id) }

    func send(_ value: T) {
        for watcher in watchers.values { watcher(value) }
        let matched = waiters.filter { $0.accepts(value) }
        waiters.removeAll { waiter in matched.contains { $0.id == waiter.id } }
        for waiter in matched { waiter.pending.resolve(value) }
    }
}

// MARK: - Conditions, CPU and hangs

struct BenchConditions: Codable {
    var screenLocked: Bool
    var displayAsleep: Bool
    var appActive: Bool
    var thermal: String
    var lowPower: Bool
    var loadAverage: [Double]
    var memoryPressure: Int?

    static func current() -> BenchConditions {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressure = sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 ? Int(level) : nil
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return BenchConditions(
            screenLocked: (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false,
            displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            appActive: NSApp?.isActive ?? false, thermal: thermal,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, loadAverage: load, memoryPressure: pressure)
    }
}

/// Other processes' share of the machine's CPU between two samples: host busy
/// time (all cores) minus our own processes' CPU time.
struct CPUMeter {
    struct Sample {
        var busy: UInt64
        var total: UInt64
        var ours: Double
        var at: TimeInterval
    }

    func sample(pids: [Int32]) -> Sample {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        let ticks = status == KERN_SUCCESS ? info.cpu_ticks : (0, 0, 0, 0)
        let busy = UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3)
        let total = busy + UInt64(ticks.2)
        return Sample(busy: busy, total: total, ours: Self.cpuSeconds(pids), at: ProcessInfo.processInfo.systemUptime)
    }

    func otherShare(since before: Sample, pids: [Int32]) -> Double {
        let after = sample(pids: pids)
        let wall = after.at - before.at
        guard wall > 0, after.total > before.total else { return 0 }
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let busySeconds = Double(after.busy - before.busy) / Double(after.total - before.total) * wall * cores
        let other = max(0, busySeconds - (after.ours - before.ours))
        return other / (wall * cores)
    }

    static func cpuSeconds(_ pids: [Int32]) -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        var total = 0.0
        for pid in pids {
            var usage = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard status == 0 else { continue }
            total += Double(usage.ri_user_time + usage.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        }
        return total
    }
}

/// Main-thread stalls over 100 ms: a background thread queues a ping on the
/// main queue every 16 ms, and a gap of more than 100 ms between two pings'
/// arrival is a stall (§2.2; stacks come from xctrace, not from here).
final class HangWatchdog: @unchecked Sendable {
    struct Hang: Codable { var scenario: String; var milliseconds: Double; var at: Double }
    private let lock = NSLock()
    private var running = false
    private var recorded: [Hang] = []
    var hangs: [Hang] { lock.withLock { recorded } }

    @MainActor
    func start(scenario: @escaping @MainActor () -> String) {
        lock.withLock { running = true }
        var lastPong = ProcessInfo.processInfo.systemUptime
        let ping: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPong > 0.1, let self {
                    let hang = Hang(scenario: scenario(), milliseconds: (now - lastPong) * 1000, at: lastPong)
                    self.lock.withLock { self.recorded.append(hang) }
                }
                lastPong = now
            }
        }
        let thread = Thread { [weak self] in
            while let self, self.lock.withLock({ self.running }) {
                DispatchQueue.main.async(execute: ping)
                Thread.sleep(forTimeInterval: 0.016)
            }
        }
        thread.name = "net.rearc.bench.hang-watchdog"
        thread.start()
    }

    func stop() { lock.withLock { running = false } }
}

// MARK: - Report

/// Raw bench output; `scripts/bench_finalize.py` adds build and machine
/// details and the statistics (p50, p95, max, mean, stdev, bootstrap CI).
struct BenchReport: Encodable {
    struct Engine: Encodable { var abiMinor: Int; var bridge: String; var chromium: String }
    struct Display: Encodable { var refreshHz: Int; var scale: Double; var points: [Int]; var name: String; var window: [Int] }
    struct Fixture: Encodable { var sidebar: String; var seed: UInt64; var server: String; var pages: [String] }
    struct Metric: Encodable {
        var unit: String
        var samples: [Double] = []
        var timeouts = 0
        var contaminated = 0
        var input: [String: Int] = [:]
    }

    var schema = "rearc.bench-raw/1"
    var status: String?
    var shellConfig: String = ChromiumLaunchArguments.isDebugBuild ? "debug" : "release"
    var shellRevision = Bundle.main.infoDictionary?["ReArcSourceRevision"] as? String
    var bundle = Bundle.main.bundlePath
    var engine: Engine?
    var display: Display?
    var conditions: BenchConditions?
    var conditionsEnd: BenchConditions?
    var fixture: Fixture?
    var inputDelivery: String?
    var metrics: [String: Metric] = [:]
    var cpuOtherShare: [String: [Double]] = [:]
    var hangs: [HangWatchdog.Hang] = []
    var notes: [String] = []
    var elapsedSeconds: Double = 0
    var antiThrottlingSwitches = false

    mutating func record(_ id: String, _ value: Double?, unit: String, input: String?, contaminated: Bool) {
        var metric = metrics[id] ?? Metric(unit: unit)
        if let input { metric.input[input, default: 0] += 1 }
        if let value {
            if contaminated { metric.contaminated += 1 } else { metric.samples.append(value) }
        } else {
            metric.timeouts += 1
        }
        metrics[id] = metric
    }

    mutating func noteCPU(_ scenario: String, _ share: Double) {
        cpuOtherShare[scenario, default: []].append((share * 1000).rounded() / 1000)
    }

    func summaryLines() -> [String] {
        metrics.keys.sorted().map { id in
            let m = metrics[id]!
            let sorted = m.samples.sorted()
            func rank(_ p: Double) -> Double { sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))] }
            return String(format: "METRIC %@ n=%d p50=%.2f p95=%.2f max=%.2f %@ timeouts=%d contaminated=%d input=%@", id, sorted.count,
                          rank(0.5), rank(0.95), sorted.last ?? .nan, m.unit, m.timeouts, m.contaminated,
                          m.input.keys.sorted().joined(separator: "+"))
        }
    }
}

/// A mutable box for values set from event callbacks.
final class Ref<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
#endif
