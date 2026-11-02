#if REARC_CHROMIUM
import AppKit
import Foundation
import Network
import ReArcEngine
import SidebarModel
import SwiftUI

/// `--rearc-selftest`: drives one ChromiumEngine through the real shell code
/// paths (engine, SwiftUI host view, boost mapping, script evaluation, boost
/// editor/picker, trusted navigation, shutdown) and exits 0 only if every
/// step passed and the engine shut down cleanly. ABI 1.5 steps run only when
/// the engine advertises them; an older engine logs ABI-GAP lines instead.
final class ChromiumSelfTest {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let watchdogSeconds = 120.0
    static let titleA = "ReArc Selftest A"
    static let titleData = "ReArc Selftest Data"
    static let boostPackageID = UUID(uuidString: "5E1F7E57-B005-4000-8000-000000000001")!

    private let runtime: ChromiumRuntime
    private var failures: [String] = []
    private var server: SelfTestFixtureServer?
    private var engine: ChromiumEngine?
    private var window: NSWindow?
    private var shutdownStatus: ReArcStatus?
    private let started = Date()

    init(runtime: ChromiumRuntime) {
        self.runtime = runtime
    }

    func start() {
        ChromiumLog.traceEnabled = true
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.watchdogSeconds) {
            print("SELFTEST FAIL: watchdog fired after \(Int(Self.watchdogSeconds)) s")
            fflush(stdout)
            _exit(124)
        }
        Task { @MainActor in
            do {
                try await self.run()
            } catch {
                self.failures.append(String(describing: error))
                self.log("FAIL \(error)")
            }
            self.shutdown()
        }
    }

    func exitCode(runResult: Int32) -> Int32 {
        log("ReArcEngineRun returned \(runResult)")
        let clean = runResult == 0 && shutdownStatus == .rearcOK && runtime.shutdownCompleted
        if failures.isEmpty && clean {
            log("RESULT PASS")
            return 0
        }
        log("RESULT FAIL (failures: \(failures.count), shutdown: \(shutdownStatus?.rearcName ?? "none"), run: \(runResult))")
        return 1
    }

    private func log(_ message: String) {
        print(String(format: "[selftest %6.2fs] ", Date().timeIntervalSince(started)) + message)
        fflush(stdout)
    }

    private func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: message()) }
    }

    @MainActor
    private func wait(_ label: String, timeout: TimeInterval = 15, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw Failure(description: "timed out waiting for \(label) [\(engineState)]")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private func waitAsync(_ label: String, timeout: TimeInterval = 10, until condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline {
                throw Failure(description: "timed out waiting for \(label) [\(engineState)]")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private var engineState: String {
        engine.map {
            "tab \($0.tabID) url \($0.currentURL?.absoluteString ?? "nil") title \($0.pageTitle ?? "nil") "
                + "loading \($0.isLoading) progress \($0.loadProgress) error \($0.lastError ?? "none")"
        } ?? "no engine"
    }

    /// Runs `body`, which must fail with a script-evaluation error.
    @MainActor
    private func expectEvaluationError(_ label: String, _ body: () async throws -> Any) async throws -> ChromiumScriptError {
        do {
            let value = try await body()
            throw Failure(description: "\(label): expected an evaluation error, got \(value)")
        } catch let error as ChromiumScriptError {
            return error
        }
    }

    @MainActor
    private func run() async throws {
        let capabilities = runtime.capabilities
        log("engine ABI \(ReArcEngineABIVersion()), bridge \(String(cString: ReArcEngineBridgeVersion())), Chromium \(String(cString: ReArcEngineVersion())), default profile \(runtime.defaultProfileID)")
        log("capabilities: \(capabilities.summary)")
        switch runtime.keychainMode {
        case .system:
            log("keychain: macOS Keychain ('Chromium Safe Storage'); ad-hoc signed bundle")
        case .devMock:
            log("keychain: MOCK (--use-mock-keychain, development bundle; cookies not Keychain-encrypted)")
        case .devMockRefused:
            log("keychain: macOS Keychain (mock keychain refused in a release build)")
        }
        let features = ["native_view", "navigation", "navigation_extended", "media_session", "media_metadata_snapshot",
                        "favicon", "security_state", "user_scripts", "script_evaluation", "link_peek",
                        "snapshot_viewport", "snapshot_full_page", "pip_control", "pip_native"]
        log("features: " + features.map { "\($0)=\(ReArcEngineHasFeature($0) ? 1 : 0)" }.joined(separator: " "))
        try check(runtime.defaultProfileID != 0, "ready delivered a zero default profile")

        // 1. Tab creation through the shell engine (shell UUIDs map to engine uint64 IDs).
        let shellTabID = UUID()
        let engine = ChromiumEngine(
            runtime: runtime,
            context: EngineProfileContext(profileID: UUID()),
            role: .tab,
            shellID: shellTabID
        )
        self.engine = engine
        try check(engine.tabID != 0, "ReArcTabCreate returned no tab")
        log("PASS tab created: shell \(shellTabID) -> engine tab \(engine.tabID), profile \(runtime.engineProfileIDs.values.first ?? 0)")
        try await wait("tab.created snapshot") { engine.contentGeneration != 0 }
        log("PASS tab.created event: content_generation \(engine.contentGeneration)")

        // 2. data: URL with a known title (trusted navigation, ABI 1.5 navigation_extended).
        let dataURL = URL(string: "data:text/html,<title>\(Self.titleData)</title>".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!
        let dataStatus = engine.navigateNow(dataURL)
        if capabilities.navigationExtended {
            try check(dataStatus == .rearcOK, "data: URL rejected synchronously: \(dataStatus.rearcName)")
            try await wait("data: commit with title '\(Self.titleData)'") {
                engine.currentURL?.scheme == "data" && engine.pageTitle == Self.titleData
            }
            log("PASS data: URL committed with title '\(engine.pageTitle ?? "")'")
            if capabilities.scriptEvaluation {
                let title = try await engine.evaluate("document.title", in: .page)
                try check(title as? String == Self.titleData, "data: document.title evaluated to \(title)")
                log("PASS evaluation on the data: document (main world): document.title = '\(title)'")
            }
        } else {
            log("ABI-GAP data: URL navigation rejected synchronously: \(dataStatus.rearcName) (engine lacks navigation_extended); using a loopback http fixture instead")
            try check(dataStatus == ReArcStatus(REARC_INVALID_URL), "unexpected data: URL status \(dataStatus.rearcName)")
        }

        let server = try SelfTestFixtureServer()
        self.server = server
        let port = try await server.start()
        let base = "http://127.0.0.1:\(port)"
        log("fixture server on \(base)")
        // Shell tabs load before they are first shown (background/adopted tabs), so try that first.
        engine.load(URL(string: "\(base)/a")!)
        var loadedHidden = true
        do {
            try await wait("hidden-tab title event '\(Self.titleA)'", timeout: 8) { engine.pageTitle == Self.titleA }
        } catch {
            loadedHidden = false
            log("NOTE never-attached (hidden) tab did not finish loading within 8 s; continuing after attach")
        }
        if loadedHidden {
            try await wait("page A load stop") { !engine.isLoading }
            log("PASS title event '\(engine.pageTitle ?? "")' url \(engine.currentURL?.absoluteString ?? "nil") (hidden tab)")
        }

        // 3. Attach through the SwiftUI NSViewRepresentable host in a registered window.
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "ReArc Chromium selftest"
        window.contentView = NSHostingView(rootView: engine.makeView().frame(minWidth: 400, minHeight: 300))
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("view attachment") { engine.attachmentID != nil }
        let host = window.contentView?.firstDescendant(ofType: ChromiumHostView.self)
        let nativeParented = host?.subviews.isEmpty == false
        try check(nativeParented, "attached NSView is not parented in the host view")
        log("PASS view attached: lease \(engine.attachmentID ?? 0), host \(host.map { NSStringFromRect($0.frame) } ?? "-"), scale \(window.backingScaleFactor)")
        if !loadedHidden {
            do {
                try await wait("title event '\(Self.titleA)' after attach") { engine.pageTitle == Self.titleA }
            } catch {
                if runtime.keychainMode != .devMock, capabilities.navigationExtended {
                    // Cookie access for http(s) waits for the Safe Storage key; data: needs no cookies.
                    log("KEYCHAIN-STALL first http load still loading (progress \(engine.loadProgress)) ~23 s after it started, "
                        + "while the cookie-free data: document committed. With the real macOS Keychain this matches the "
                        + "'Chromium Safe Storage' read waiting on authorization for this ad-hoc signed executable "
                        + "(C-ABI.md 'First-load and Keychain findings'). Grant access and rerun, or use --dev-mock-keychain "
                        + "for development bundles.")
                }
                throw error
            }
            try await wait("page A load stop") { !engine.isLoading }
            log("PASS title event '\(engine.pageTitle ?? "")' url \(engine.currentURL?.absoluteString ?? "nil") (after attach)")
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        // 4. Viewport snapshot.
        let png = try await engine.captureSnapshot(scope: .visible)
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        try check(png.count > 24 && Array(png.prefix(4)) == pngSignature, "viewport snapshot is not a PNG (\(png.count) bytes)")
        let width = png[16..<20].reduce(0) { $0 << 8 | UInt32($1) }
        let height = png[20..<24].reduce(0) { $0 << 8 | UInt32($1) }
        let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-viewport.png")
        try? png.write(to: snapshotURL)
        log("PASS viewport snapshot: \(png.count) bytes, \(width)x\(height) PNG (\(snapshotURL.path))")

        // 5. Boost: install, then navigate; the engine defers the navigation until the install completes.
        let boost = BoostRuntimeEntry(
            packageID: Self.boostPackageID,
            order: 0,
            hostScope: [BoostHostRule(host: "127.0.0.1", hostMatch: .exact, pathPrefix: "/boost", schemes: ["http"])],
            css: "body { background: rgb(1, 2, 3) !important; }",
            cssRules: [BoostCSSRule(id: "bg", css: "body { background: rgb(1, 2, 3) !important; }")],
            js: "globalThis.rearcBoostSecret = 'isolated'; document.documentElement.dataset.rearcBoost = 'js';",
            scriptUserEnabled: true
        )
        let installsBefore = engine.boostInstallCount
        engine.installBoosts([boost])
        engine.load(URL(string: "\(base)/boost")!)
        try await wait("boost install acknowledgement") { engine.boostInstallCount > installsBefore }
        log("PASS boost plan acknowledged (navigations deferred behind install: \(engine.navigationsDeferredForBoosts))")
        try await wait("boosted page title", timeout: 15) {
            guard let title = engine.pageTitle else { return false }
            return title.hasPrefix("boost-ok") || title.hasPrefix("boost-fail")
        }
        let boostTitle = engine.pageTitle ?? ""
        try check(boostTitle == "boost-ok:js:rgb(1, 2, 3):isolated", "boost title '\(boostTitle)'")
        log("PASS boost JS + CSS applied in an isolated world: '\(boostTitle)'")

        // 6. Back / forward.
        try await wait("canGoBack") { engine.canGoBack }
        engine.goBack()
        try await wait("back to /a") { engine.currentURL?.path == "/a" && engine.pageTitle == Self.titleA && !engine.isLoading }
        try await wait("canGoForward") { engine.canGoForward }
        log("PASS back: \(engine.currentURL?.absoluteString ?? "") '\(engine.pageTitle ?? "")' canGoForward=\(engine.canGoForward)")
        engine.goForward()
        try await wait("forward to /boost") {
            engine.currentURL?.path == "/boost" && engine.pageTitle?.hasPrefix("boost-ok") == true && !engine.isLoading
        }
        log("PASS forward: \(engine.currentURL?.absoluteString ?? "") '\(engine.pageTitle ?? "")'")

        // 7. Media surface: mute is independent of sessions; PiP reports unsupported.
        engine.setMuted(true)
        try await wait("muted media event", timeout: 5) { engine.isMuted }
        let pip = engine.requestPictureInPicture()
        try check(pip == ReArcStatus(REARC_UNSUPPORTED), "PiP returned \(pip.rearcName)")
        let media = engine.mediaState
        log("PASS mute observed via media event (metadata title \(media.title ?? "nil") artist \(media.artist ?? "nil") album \(media.album ?? "nil")); PiP -> \(pip.rearcName) (not advertised)")

        // 8-10. Script evaluation, cancellation and the Chromium boost editor/picker.
        if capabilities.scriptEvaluation {
            try await scriptEvaluationChecks(engine: engine)
            try await cancellationOnNavigationCheck(engine: engine, base: base)
            try await boostEditorChecks(engine: engine, host: host)
        } else {
            log("ABI-GAP script_evaluation not advertised: boost editor and element picker stay WebKit-only")
        }

        // 11. Trusted WebUI / view-source navigation and the settings entry point.
        if capabilities.navigationExtended {
            try await trustedNavigationChecks(engine: engine, base: base)
        }

        // 12. Every accepted evaluation completed once and released its context.
        try await wait("evaluations drained") { engine.evaluationsOutstanding == 0 }
        try check(runtime.liveScriptContexts == 0, "\(runtime.liveScriptContexts) evaluation context(s) never released")
        log("PASS every evaluation context released exactly once (live contexts: \(runtime.liveScriptContexts))")
    }

    // MARK: Script evaluation

    @MainActor
    private func scriptEvaluationChecks(engine: ChromiumEngine) async throws {
        // Isolated vs main world on the boosted page: globals are per world, the DOM is shared.
        let probe = """
        (function(){ return {
          secret: typeof rearcBoostSecret === 'undefined' ? null : rearcBoostSecret,
          pageFunction: typeof check,
          marker: document.documentElement.dataset.rearcBoost || null
        }; })()
        """
        let boostWorld = try await engine.evaluate(probe, in: .boost(Self.boostPackageID)) as? [String: Any]
        let pageWorld = try await engine.evaluate(probe, in: .page) as? [String: Any]
        let editorWorld = try await engine.evaluate(probe, in: .editor) as? [String: Any]
        try check(boostWorld?["secret"] as? String == "isolated" && boostWorld?["pageFunction"] as? String == "undefined",
                  "boost world probe: \(String(describing: boostWorld))")
        try check(pageWorld?["secret"] is NSNull && pageWorld?["pageFunction"] as? String == "function",
                  "page world probe: \(String(describing: pageWorld))")
        try check(editorWorld?["secret"] is NSNull && editorWorld?["pageFunction"] as? String == "undefined",
                  "editor world probe: \(String(describing: editorWorld))")
        try check([boostWorld, pageWorld, editorWorld].allSatisfy { $0?["marker"] as? String == "js" },
                  "worlds disagree on the shared DOM marker")
        log("PASS worlds: boost \(Self.boostPackageID.uuidString.lowercased()) sees rearcBoostSecret='isolated'; "
            + "main world sees page function check() but not the boost global; editor world sees neither; all share the DOM")
        _ = try await engine.evaluate("(function(){ window.__rearcMainProbe = 42; return window.__rearcMainProbe; })()", in: .page)
        let leaked = try await engine.evaluate("typeof window.__rearcMainProbe", in: .editor) as? String
        try check(leaked == "undefined", "main-world global visible in the editor world (\(leaked ?? "nil"))")
        log("PASS main-world global (window.__rearcMainProbe) is invisible to the editor isolated world")

        // JSON results are decoded, never double-encoded.
        let object = try await engine.evaluate(
            "({ n: 1.5, s: 'q\"uote', a: [1, true, null], o: { k: 'v' }, u: undefined })", in: .editor
        ) as? [String: Any]
        let array = object?["a"] as? [Any]
        try check(object?["n"] as? Double == 1.5 && object?["s"] as? String == "q\"uote"
                  && array?.count == 3 && array?[0] as? Int == 1 && array?[1] as? Bool == true && array?[2] is NSNull
                  && (object?["o"] as? [String: Any])?["k"] as? String == "v" && object?["u"] == nil,
                  "object result decoded as \(String(describing: object))")
        let string = try await engine.evaluate("'plain string'", in: .editor)
        try check(string as? String == "plain string", "string result decoded as \(string)")
        let undefinedValue = try await engine.evaluate("undefined", in: .editor)
        try check(undefinedValue is NSNull, "undefined decoded as \(undefinedValue)")
        let promised = try await engine.evaluate("Promise.resolve([3, 2, 1])", in: .page) as? [Int]
        try check(promised == [3, 2, 1], "awaited Promise decoded as \(String(describing: promised))")
        log("PASS JSON results: nested object/array, quoted string -> String, undefined -> null, awaited Promise -> [3, 2, 1]")

        // A thrown exception and a rejected Promise report script_error with structured details.
        let thrown = try await expectEvaluationError("exception") {
            try await engine.evaluate("(function(){ throw new Error('selftest-boom'); })()", in: .editor)
        }
        guard case .script(let thrownInfo) = thrown,
              thrownInfo.message.contains("selftest-boom") || thrownInfo.detailsJSON?.contains("selftest-boom") == true else {
            throw Failure(description: "exception reported as \(thrown)")
        }
        log("PASS exception -> script_error code '\(thrownInfo.code)' message '\(thrownInfo.message)' details \(thrownInfo.detailsJSON.map { String($0.prefix(160)) } ?? "none")")
        let rejected = try await expectEvaluationError("rejected Promise") {
            try await engine.evaluate("Promise.reject(new Error('selftest-reject'))", in: .page)
        }
        guard case .script(let rejectedInfo) = rejected else {
            throw Failure(description: "rejected Promise reported as \(rejected)")
        }
        log("PASS rejected Promise -> script_error '\(rejectedInfo.message)'")

        // A never-settling Promise hits the deadline; the tab still evaluates afterwards.
        let timeoutStart = Date()
        let timedOut = try await expectEvaluationError("timeout") {
            try await engine.evaluate("new Promise(function(){})", in: .editor, timeoutMS: 300)
        }
        let timeoutElapsed = Date().timeIntervalSince(timeoutStart)
        try check(timedOut == .timeout, "never-settling Promise reported as \(timedOut)")
        let after = try await engine.evaluate("1 + 1", in: .editor)
        try check(after as? Int == 2, "evaluation after timeout returned \(after)")
        log(String(format: "PASS timeout: 300 ms deadline -> timeout after %.2f s; next evaluation OK (1 + 1 = 2)", timeoutElapsed))
    }

    @MainActor
    private func cancellationOnNavigationCheck(engine: ChromiumEngine, base: String) async throws {
        let documentBefore = engine.documentSerial
        let pending = Task { @MainActor in
            try await engine.evaluate(
                "new Promise(function(resolve){ setTimeout(function(){ resolve('late'); }, 8000); })",
                in: .page,
                timeoutMS: 20000
            )
        }
        try await wait("evaluation accepted", timeout: 5) { engine.evaluationInFlight }
        let navigationStart = Date()
        engine.load(URL(string: "\(base)/a")!)
        let outcome = await pending.result
        let elapsed = Date().timeIntervalSince(navigationStart)
        guard case .failure(let error) = outcome, error as? ChromiumScriptError == .cancelled else {
            throw Failure(description: "evaluation pending across navigation ended with \(outcome)")
        }
        log(String(format: "PASS cross-document navigation cancelled the pending evaluation after %.2f s (status cancelled)", elapsed))
        try await wait("page A after cancellation") {
            engine.currentURL?.path == "/a" && engine.pageTitle == Self.titleA && !engine.isLoading
        }
        let title = try await engine.evaluate("document.title", in: .page)
        try check(engine.documentSerial > documentBefore && title as? String == Self.titleA,
                  "fresh evaluation after navigation returned \(title) (identity \(documentBefore) -> \(engine.documentSerial))")
        log("PASS fresh evaluation on the new document: '\(title)' (navigation identity \(documentBefore) -> \(engine.documentSerial))")
    }

    // MARK: Boost editor and picker

    @MainActor
    private func boostEditorChecks(engine: ChromiumEngine, host: ChromiumHostView?) async throws {
        try check(engine.supportsBoostEditor, "ChromiumEngine does not offer the boost editor")
        engine.setBoostEditorOpen(true)
        engine.setBoostPickerMode(true)
        try check(host?.pickerOverlay != nil && host?.subviews.last === host?.pickerOverlay,
                  "picker overlay is not installed above the Chromium view")
        let center = try await engine.evaluate(
            "(function(){ var r = document.querySelector('h1').getBoundingClientRect(); return { x: r.left + 20, y: r.top + r.height / 2 }; })()",
            in: .page
        ) as? [String: Double]
        guard let x = center?["x"], let y = center?["y"] else {
            throw Failure(description: "could not locate page A's <h1>: \(String(describing: center))")
        }
        var picked: PickedElementSnapshot?
        engine.onBoostEditorPick = { picked = $0 }
        // The overlay's mouseDown path, at view (= CSS) coordinates inside page A's <h1>.
        engine.pickerClick(at: CGPoint(x: x, y: y))
        try await wait("picker pick", timeout: 10) { picked != nil }
        try check(picked?.descriptor.tag == "h1", "picker picked \(String(describing: picked?.descriptor))")
        let bounds = picked.map { String(format: "%.0fx%.0f at %.0f,%.0f", $0.bounds.width, $0.bounds.height, $0.bounds.x, $0.bounds.y) } ?? "-"
        log(String(format: "PASS picker: native overlay hit (%.0f,%.0f) -> editor-world snapshotAt -> ", x, y)
            + "<\(picked?.descriptor.tag ?? "")> path \(picked?.descriptor.structuralPath.joined(separator: ">") ?? "") bounds \(bounds)")
        engine.setBoostPickerMode(false)
        try check(host?.pickerOverlay == nil, "picker overlay still installed after leaving pick mode")

        let backgroundProbe = "getComputedStyle(document.body).backgroundColor"
        engine.applyEditorLiveCSS("body { background: rgb(4, 5, 6) !important; }")
        try await waitAsync("editor live CSS") {
            (try? await engine.evaluate(backgroundProbe, in: .page)) as? String == "rgb(4, 5, 6)"
        }
        log("PASS editor live CSS (editor world) applies to the page: body background rgb(4, 5, 6)")

        var scan: [PickedElementSnapshot]?
        engine.fetchRepairScan { scan = $0 }
        try await wait("repair scan", timeout: 10) { scan != nil }
        try check(scan?.contains { $0.descriptor.tag == "a" } == true, "repair scan returned \(scan?.map(\.descriptor.tag) ?? [])")
        log("PASS repair scan returned a JSON array of \(scan?.count ?? 0) candidate(s): \(scan?.map(\.descriptor.tag) ?? [])")

        engine.clearEditorLiveCSS()
        try await waitAsync("editor live CSS cleared") {
            let value = (try? await engine.evaluate(backgroundProbe, in: .page)) as? String
            return value != nil && value != "rgb(4, 5, 6)"
        }
        engine.setBoostEditorOpen(false)
        try await wait("editor scripts drained") { engine.evaluationsOutstanding == 0 }
        log("PASS editor live CSS cleared; editor closed")
    }

    // MARK: Trusted navigation

    @MainActor
    private func trustedNavigationChecks(engine: ChromiumEngine, base: String) async throws {
        let viewSource = NavigationURLPolicy.viewSourceURL(for: URL(string: "\(base)/a")!, engine: .chromium)!
        let viewSourceStatus = engine.navigateNow(viewSource)
        try check(viewSourceStatus == .rearcOK, "view-source rejected: \(viewSourceStatus.rearcName)")
        try await wait("view-source commit") { engine.currentURL?.scheme == "view-source" && !engine.isLoading }
        log("PASS view-source committed: \(engine.currentURL?.absoluteString ?? "")")

        let versionStatus = engine.navigateNow(BrowserInternalPage.version.url)
        try check(versionStatus == .rearcOK, "chrome://version rejected: \(versionStatus.rearcName)")
        try await wait("chrome://version commit", timeout: 20) {
            engine.currentURL?.absoluteString.hasPrefix("chrome://version") == true && !engine.isLoading
        }
        log("PASS chrome://version committed, title '\(engine.pageTitle ?? "")'")
        if runtime.capabilities.scriptEvaluation {
            let webUIError = try await expectEvaluationError("evaluation on WebUI") {
                try await engine.evaluate("document.title", in: .page)
            }
            let unsupported = ChromiumStatusCode.unsupported
            try check(webUIError == .rejected(unsupported) || {
                if case .failed(let status, _) = webUIError { return status == unsupported }
                return false
            }(), "evaluation on chrome://version reported \(webUIError)")
            log("PASS evaluation on WebUI refused: \(webUIError)")
        }

        let settingsStatus = engine.navigateNow(BrowserInternalPage.settings.url)
        try check(settingsStatus == .rearcOK, "chrome://settings rejected: \(settingsStatus.rearcName)")
        try await wait("chrome://settings commit", timeout: 25) {
            engine.currentURL?.host() == "settings" && engine.currentURL?.scheme == "chrome" && !engine.isLoading
        }
        log("PASS chrome://settings committed (the shell's Settings entry point), title '\(engine.pageTitle ?? "")'")

        var rejected: [String] = []
        for bad in ["javascript:void(0)", "chrome://flags", "view-source:view-source:\(base)/a"] {
            let status = engine.navigateNow(URL(string: bad)!)
            try check(status == ReArcStatus(REARC_INVALID_URL), "\(bad) returned \(status.rearcName)")
            rejected.append(bad)
        }
        log("PASS still rejected with invalid_url: \(rejected.joined(separator: ", "))")
    }

    @MainActor
    private func shutdown() {
        log("requesting orderly shutdown")
        let status = runtime.requestShutdown(force: true) { [self] status, cancelled in
            shutdownStatus = cancelled ? ReArcStatus(REARC_CANCELLED) : status
            log("shutdown completion: \(status.rearcName) cancelled=\(cancelled) attached=\(engine?.attachmentID != nil)")
        }
        if status != .rearcOK {
            failures.append("ReArcEngineShutdown rejected: \(status.rearcName)")
            log("FAIL ReArcEngineShutdown rejected: \(status.rearcName)")
            fflush(stdout)
            _exit(1)
        }
    }
}

private extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for child in subviews {
            if let match = child as? T ?? child.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}

/// Minimal loopback HTTP/1.1 server for the selftest fixture pages.
final class SelfTestFixtureServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "net.rearc.selftest.fixture")

    static let pages: [String: String] = [
        "/a": """
        <!doctype html><html><head><title>\(ChromiumSelfTest.titleA)</title></head>
        <body style="margin:0;background:#2a6;font:32px -apple-system"><h1>ReArc selftest page A</h1>
        <p><a href="/boost">boost page</a></p></body></html>
        """,
        "/boost": """
        <!doctype html><html><head><title>boost-pending</title><script>
        function check(n) {
          var css = getComputedStyle(document.body).backgroundColor;
          var js = document.documentElement.dataset.rearcBoost;
          var world = typeof rearcBoostSecret === 'undefined' ? 'isolated' : 'leaked';
          if (js === 'js' && css === 'rgb(1, 2, 3)') { document.title = 'boost-ok:' + js + ':' + css + ':' + world; return; }
          if (n > 200) { document.title = 'boost-fail:' + js + ':' + css + ':' + world; return; }
          setTimeout(function () { check(n + 1); }, 25);
        }
        window.addEventListener('load', function () { check(0); });
        </script></head><body style="font:32px -apple-system"><h1>ReArc selftest boost page</h1></body></html>
        """,
    ]

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                Self.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// Reads until the end of the request head; preconnected sockets may idle or close without one.
    private static func serve(_ connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var request = buffered
            if let data { request.append(data) }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if buffered.isEmpty, !request.isEmpty {
                    let prefix = request.prefix(16).map { String(format: "%02x", $0) }.joined()
                    print("[fixture] partial/non-HTTP bytes (\(request.count)): \(prefix)")
                    fflush(stdout)
                }
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    serve(connection, buffered: request)
                }
                return
            }
            let head = String(decoding: request, as: UTF8.self)
            let path = head.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
            respond(connection, path: path)
        }
    }

    private static func respond(_ connection: NWConnection, path: String) {
        let body = pages[path]
        print("[fixture] GET \(path) -> \(body == nil ? 404 : 200)")
        fflush(stdout)
        let payload = Data((body ?? "not found").utf8)
        let head = "HTTP/1.1 \(body == nil ? "404 Not Found" : "200 OK")\r\n"
            + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(payload.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
#endif
