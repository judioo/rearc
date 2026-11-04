#if REARC_CHROMIUM
import AppKit
import Foundation
import Network
import ReArcEngine
import SidebarModel
import SwiftUI

/// `--rearc-selftest`: drives ChromiumEngines through the real shell code
/// paths (engine, SwiftUI host view, boost mapping, script evaluation with
/// document identity, boost editor/picker over page messages, zoom, two
/// windows sharing a tab, named and off-the-record profiles, trusted
/// navigation, the real ChromiumShell windows, shutdown) and exits 0 only if
/// every step passed and the engine
/// shut down cleanly. Optional steps run only when the engine advertises
/// them; an older engine logs ABI-GAP lines instead.
final class ChromiumSelfTest {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let watchdogSeconds = 180.0
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
            log("keychain: macOS Keychain ('\(capabilities.safeStorageKeychainItem)')")
        case .devMock:
            log("keychain: MOCK (--use-mock-keychain, development bundle; cookies not Keychain-encrypted)")
        case .devMockRefused:
            log("keychain: macOS Keychain (mock keychain refused in a release build)")
        }
        let features = ["native_view", "navigation", "navigation_extended", "media_session", "media_metadata_snapshot",
                        "favicon", "security_state", "user_scripts", "script_evaluation", "link_peek",
                        "snapshot_viewport", "snapshot_full_page", "pip_control", "pip_native",
                        "profiles", "profile_off_the_record", "script_evaluation_identity", "page_zoom",
                        "isolated_page_messages", "rearc_safe_storage_branding", "os_permission_shutdown",
                        "shutdown_pending_closes", "profile_directory", "webui_daily_pages", "history_recording",
                        "password_autofill", "find_in_page", "downloads", "javascript_dialogs", "file_chooser",
                        "permission_prompts", "context_menu", "password_prompts", "devtools"]
        let foreground = ChromiumLaunchArguments.selfTestForegroundSwitches.filter(CommandLine.arguments.contains)
        log("renderer foreground switches (self-test only): "
            + ChromiumLaunchArguments.selfTestForegroundSwitches.joined(separator: " ")
            + "; app active \(NSApp.isActive)\(foreground.isEmpty ? "" : "; also on the command line")")
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
        try check(await engine.waitForTab(), "ReArcTabCreate returned no tab (\(engine.lastError ?? "no error"))")
        log("PASS tab created: shell \(shellTabID) -> engine tab \(engine.tabID), \(engine.profileKey) -> engine profile \(engine.engineProfileID)")
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

        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

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
                        + "'\(capabilities.safeStorageKeychainItem)' read waiting on Keychain authorization "
                        + "(C-ABI.md 'First-load and Keychain findings'). Grant access and rerun, or use --dev-mock-keychain "
                        + "for development bundles.")
                }
                throw error
            }
            try await wait("page A load stop") { !engine.isLoading }
            log("PASS title event '\(engine.pageTitle ?? "")' url \(engine.currentURL?.absoluteString ?? "nil") (after attach)")
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        // 3b. Favicon (ABI services kind 0 + ReArcFaviconGet): page A declares /favicon.png.
        if ReArcEngineHasFeature("favicon") {
            try await wait("favicon event and ReArcFaviconGet PNG", timeout: 15) { engine.faviconData != nil }
            let icon = engine.faviconData ?? Data()
            try check(Array(icon.prefix(4)) == pngSignature, "favicon is not a PNG (\(icon.count) bytes)")
            let (staleStatus, staleData) = engine.fetchFavicon(ref: "rearc-selftest-stale-ref")
            try check(staleStatus != .rearcOK && staleData == nil, "stale favicon ref returned \(staleStatus.rearcName)")
            log("PASS favicon: icon_ref \(engine.faviconRef ?? "-") -> ReArcFaviconGet \(icon.count)-byte PNG; "
                + "stale ref -> \(staleStatus.rearcName)")
        } else {
            log("ABI-GAP favicon not advertised: sidebar rows keep letter tokens on Chromium")
        }
        let png = try await engine.captureSnapshot(scope: .visible)
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
            if capabilities.scriptEvaluationIdentity {
                try await identityMismatchCheck(engine: engine, base: base)
            } else {
                log("ABI-GAP script_evaluation_identity not advertised: results are checked by content generation only")
            }
        } else {
            log("ABI-GAP script_evaluation not advertised: boost editor and element picker stay WebKit-only")
        }

        // 11. Page zoom round trip, and the picker's zoom-corrected coordinates.
        if capabilities.pageZoom {
            try await zoomChecks(engine: engine)
        } else {
            log("ABI-GAP page_zoom not advertised: zoom commands are inert on Chromium")
        }

        // 12. Isolated-world page messages (boost and editor worlds), never the main world.
        if capabilities.isolatedPageMessages, capabilities.scriptEvaluation {
            try await pageMessageChecks(engine: engine, window: window)
        } else {
            log("ABI-GAP isolated_page_messages not advertised: the picker uses the native overlay only")
        }

        // 12b. Find in page (ABI 1.16) through the shell's find bar model, on the attached tab.
        if capabilities.findInPage {
            try await findInPageChecks(engine: engine, base: base)
        } else {
            log("ABI-GAP find_in_page not advertised (ABI minor \(capabilities.abiMinorVersion.map(String.init) ?? "absent") < 16): Cmd+F is hidden on Chromium")
        }

        // 12c. Downloads (ABI 1.17) into a temporary policy directory, through the tray's controller.
        if capabilities.downloads {
            try await downloadChecks(engine: engine, base: base)
        } else {
            log("ABI-GAP downloads not advertised (ABI minor \(capabilities.abiMinorVersion.map(String.init) ?? "absent") < 17): the tray shows WebKit downloads only")
        }

        // 12d. Host prompt channels (ABI 1.18–1.22) through the tab's PagePromptCenter.
        try await promptChannelChecks(engine: engine, base: base, window: window)

        // 13. Two windows: the tab's one lease moves to a second window and back.
        try await twoWindowChecks(engine: engine, first: window)

        // 14. Trusted WebUI / view-source navigation and the settings entry point.
        if capabilities.navigationExtended {
            try await trustedNavigationChecks(engine: engine, base: base)
        }

        // 15. Named profiles are isolated; an off-the-record child sees neither; teardown order.
        if capabilities.profiles {
            try await profileChecks(base: base)
            if capabilities.profileDirectory {
                try await profileDirectoryChecks()
            } else {
                log("ABI-GAP profile_directory not advertised: the startup Default directory is not adopted")
            }
        } else {
            log("ABI-GAP profiles not advertised: every shell profile shares the startup profile")
        }

        // 16. The real shell: browser windows, split view, peek, Little Arc, private
        //     windows and zoom commands through BrowserViewModel; closing every
        //     window leaves the app running.
        try await shellChecks(base: base)

        // 17. Every accepted evaluation completed once and released its context.
        try await wait("evaluations drained") { engine.evaluationsOutstanding == 0 }
        try check(runtime.liveScriptContexts == 0, "\(runtime.liveScriptContexts) evaluation context(s) never released")
        try check(runtime.liveProfileContexts == 0, "\(runtime.liveProfileContexts) profile request context(s) never released")
        log("PASS every evaluation and profile request context released exactly once "
            + "(live script contexts: \(runtime.liveScriptContexts), profile contexts: \(runtime.liveProfileContexts))")
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
        let documentBefore = engine.currentDocumentIdentity
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
        let documentAfter = engine.currentDocumentIdentity
        try check(title as? String == Self.titleA, "fresh evaluation after navigation returned \(title)")
        if runtime.capabilities.scriptEvaluationIdentity {
            guard let documentBefore, let documentAfter, !documentAfter.isSameDocument(as: documentBefore) else {
                throw Failure(description: "document identity did not change across navigation (\(String(describing: documentBefore)) -> \(String(describing: documentAfter)))")
            }
        }
        log("PASS fresh evaluation on the new document: '\(title)' (document \(documentBefore.map { "\($0.documentGeneration)" } ?? "?") -> \(documentAfter.map { "\($0.documentGeneration)" } ?? "?"))")
    }

    // MARK: Boost editor and picker

    @MainActor
    private func boostEditorChecks(engine: ChromiumEngine, host: ChromiumHostView?) async throws {
        try check(engine.supportsBoostEditor, "ChromiumEngine does not offer the boost editor")
        engine.setBoostEditorOpen(true)
        engine.setBoostPickerMode(true)
        if engine.usesPickerOverlay {
            try check(host?.pickerOverlay != nil && host?.subviews.last === host?.pickerOverlay,
                      "picker overlay is not installed above the Chromium view")
        } else {
            // http(s) with page messages: the page's own input picks in the editor world.
            try check(host?.pickerOverlay == nil, "picker overlay installed although page messages carry picks")
        }
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
        log(String(format: "PASS picker: view hit (%.0f,%.0f) -> editor-world snapshotAt -> ", x, y)
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


    // MARK: Document identity

    /// A result evaluated in a document the caller no longer expects is discarded.
    @MainActor
    private func identityMismatchCheck(engine: ChromiumEngine, base: String) async throws {
        guard let old = engine.currentDocumentIdentity else {
            throw Failure(description: "ReArcTabGetDocumentIdentity failed on page A")
        }
        let matching = try await engine.evaluate("document.title", in: .editor, expecting: old, sameNavigation: true)
        try check(matching as? String == Self.titleA, "evaluation with the current identity returned \(matching)")
        engine.reload()
        try await wait("reload of page A") {
            guard let now = engine.currentDocumentIdentity else { return false }
            return !now.isSameDocument(as: old) && !engine.isLoading && engine.pageTitle == Self.titleA
        }
        let discardedBefore = engine.staleResultsDiscarded
        let mismatch = try await expectEvaluationError("evaluation expecting the pre-reload document") {
            try await engine.evaluate("document.title", in: .editor, expecting: old)
        }
        try check(mismatch == .staleDocument && engine.staleResultsDiscarded == discardedBefore + 1,
                  "identity mismatch reported as \(mismatch) (discarded \(discardedBefore) -> \(engine.staleResultsDiscarded))")
        let current = engine.currentDocumentIdentity
        log("PASS EvaluateScript2 identity mismatch rejected: expected [\(old)], tab shows [\(current.map(String.init(describing:)) ?? "?")] -> staleDocument")
    }

    // MARK: Zoom

    @MainActor
    private func zoomChecks(engine: ChromiumEngine) async throws {
        try check(PageZoom.isDefault(engine.refreshZoomFactor() ?? 0), "initial zoom is \(engine.zoomFactor)")
        let status = engine.requestZoomFactor(1.5)
        try check(status == .rearcOK, "ReArcTabSetZoomFactor(1.5) returned \(status.rearcName)")
        try await wait("zoom event 1.5") { abs(engine.zoomFactor - 1.5) < PageZoom.tolerance }
        let queried = engine.refreshZoomFactor() ?? 0
        try check(abs(queried - 1.5) < PageZoom.tolerance, "ReArcTabGetZoomFactor returned \(queried) after the event")
        let invalid = engine.requestZoomFactor(.infinity)
        try check(invalid == ReArcStatus(REARC_INVALID_ARGUMENT), "non-finite zoom returned \(invalid.rearcName)")

        // The picker maps view points to CSS pixels by the zoom factor.
        let rect = try await engine.evaluate(
            "(function(){ var r = document.querySelector('h1').getBoundingClientRect(); return { x: r.left + 20, y: r.top + r.height / 2 }; })()",
            in: .page
        ) as? [String: Double]
        guard let cssX = rect?["x"], let cssY = rect?["y"] else {
            throw Failure(description: "could not locate <h1> at zoom 1.5: \(String(describing: rect))")
        }
        let viewPoint = PageZoom.viewPoint(fromCSSPoint: CGPoint(x: cssX, y: cssY), zoom: engine.zoomFactor)
        engine.setBoostEditorOpen(true)
        engine.setBoostPickerMode(true)
        let picked = try await engine.pickElement(atViewPoint: viewPoint)
        engine.setBoostPickerMode(false)
        engine.setBoostEditorOpen(false)
        try check(picked?.descriptor.tag == "h1", "zoomed pick at view \(viewPoint) found \(String(describing: picked?.descriptor.tag))")

        engine.setZoomFactor(PageZoom.factor(after: .reset, from: engine.zoomFactor))
        try await wait("zoom event 1.0") { PageZoom.isDefault(engine.zoomFactor) }
        log(String(format: "PASS zoom round trip: set 1.5 -> zoom event %.2f, get %.2f; infinity rejected (invalid_argument); ", 1.5, queried)
            + String(format: "picker at view (%.0f,%.0f) = CSS (%.0f,%.0f) -> <h1>; reset -> %.2f", viewPoint.x, viewPoint.y, cssX, cssY, engine.zoomFactor))
    }

    // MARK: Page messages

    @MainActor
    private func pageMessageChecks(engine: ChromiumEngine, window: NSWindow) async throws {
        // The main world gets no binding.
        let mainWorld = try await engine.evaluate("typeof rearcPostMessage", in: .page) as? String
        try check(mainWorld == "undefined", "main world sees rearcPostMessage as \(mainWorld ?? "nil")")

        // A boost world message carries the package ID and arrives as JSON data.
        engine.load(URL(string: engine.currentURL!.absoluteString.replacingOccurrences(of: "/a", with: "/boost"))!)
        try await wait("boosted page for page messages") { engine.pageTitle?.hasPrefix("boost-ok") == true && !engine.isLoading }
        var boostMessages: [ChromiumPageMessage] = []
        engine.onBoostPageMessage = { boostMessages.append($0) }
        _ = try await engine.evaluate("(rearcPostMessage(JSON.stringify({ kind: 'selftest', n: 7 })), true)",
                                      in: .boost(Self.boostPackageID))
        try await wait("boost page message", timeout: 5) { !boostMessages.isEmpty }
        let boostMessage = boostMessages[0]
        let decoded = try? JSONSerialization.jsonObject(with: Data(boostMessage.json.utf8)) as? [String: Any]
        try check(boostMessage.boostID == Self.boostPackageID.uuidString.lowercased()
                  && decoded?["kind"] as? String == "selftest" && decoded?["n"] as? Int == 7
                  && boostMessage.document.tabID == engine.tabID,
                  "boost message \(boostMessage.boostID) \(boostMessage.json)")
        engine.onBoostPageMessage = nil
        log("PASS boost-world page message: boost \(boostMessage.boostID) json \(boostMessage.json) document [\(boostMessage.document)]; main world has no rearcPostMessage")

        // Editor world: a real (trusted) click on the page picks through the channel, no polling.
        engine.goBack()
        try await wait("page A for the editor picker") { engine.currentURL?.path == "/a" && !engine.isLoading }
        var picks: [PickedElementSnapshot] = []
        var cancels = 0
        engine.onBoostEditorPick = { picks.append($0) }
        engine.onBoostEditorCancel = { cancels += 1 }
        engine.setBoostEditorOpen(true)
        engine.setBoostPickerMode(true)
        try await wait("editor scripts installed") { engine.evaluationsOutstanding == 0 }
        let droppedBefore = engine.droppedEditorMessages
        _ = try await engine.evaluate("(rearcPostMessage(JSON.stringify({ type: 'bogus' })), true)", in: .editor)
        try await wait("unknown editor message dropped", timeout: 5) { engine.droppedEditorMessages > droppedBefore }

        let center = try await engine.evaluate(
            "(function(){ var r = document.querySelector('h1').getBoundingClientRect(); return { x: r.left + 20, y: r.top + r.height / 2 }; })()",
            in: .page
        ) as? [String: Double]
        guard let x = center?["x"], let y = center?["y"],
              let host = window.contentView?.firstDescendant(ofType: ChromiumHostView.self) else {
            throw Failure(description: "no <h1> or host for the trusted click")
        }
        window.makeKeyAndOrderFront(nil)
        var via = "trusted click -> editor-world listener -> rearcPostMessage"
        // Synthesized NSEvents reach the renderer as trusted input only while the app
        // is active and the window key and visible; otherwise Chromium drops them.
        // Decide that up front instead of waiting for a click that cannot arrive.
        let canDeliverInput = NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
        if canDeliverInput {
            let viewPoint = PageZoom.viewPoint(fromCSSPoint: CGPoint(x: x, y: y), zoom: engine.zoomFactor)
            let local = NSPoint(x: viewPoint.x, y: host.isFlipped ? viewPoint.y : host.bounds.height - viewPoint.y)
            let location = host.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            do {
                try await wait("editor pick page message", timeout: 5) { !picks.isEmpty }
            } catch {
                log("NOTE synthesized click produced no page message although the window was key and visible")
            }
        } else {
            log("NOTE app inactive or window not visible (active \(NSApp.isActive), key \(window.isKeyWindow), "
                + "visible \(window.occlusionState.contains(.visible))): synthesized input cannot reach the page; "
                + "posting the editor pick from the editor world")
        }
        if picks.isEmpty {
            via = "editor-world rearcPostMessage(snapshotAt)"
            let started = Date()
            _ = try await engine.evaluate(
                BoostEditorScripts.withPicker("(rearcPostMessage(JSON.stringify(p.snapshotAt(\(x), \(y)))), true)"),
                in: .editor,
                timeoutMS: 15_000
            )
            try await wait("editor pick page message (direct)", timeout: 10) { !picks.isEmpty }
            via += String(format: " in %.0f ms", Date().timeIntervalSince(started) * 1000)
        }
        try check(picks.first?.descriptor.tag == "h1", "page-message pick was \(String(describing: picks.first?.descriptor.tag))")
        _ = try await engine.evaluate("(rearcPostMessage(JSON.stringify({ type: 'cancel' })), true)", in: .editor, timeoutMS: 15_000)
        try await wait("editor cancel page message", timeout: 10) { cancels > 0 }
        engine.setBoostPickerMode(false)
        engine.setBoostEditorOpen(false)
        engine.onBoostEditorPick = nil
        engine.onBoostEditorCancel = nil
        try await wait("editor scripts drained") { engine.evaluationsOutstanding == 0 }
        log("PASS editor page messages: \(via) -> <\(picks.first?.descriptor.tag ?? "")>; cancel delivered; "
            + "unknown kind dropped (dropped \(droppedBefore) -> \(engine.droppedEditorMessages))")
    }

    // MARK: Find in page (ABI 1.16)

    @MainActor
    private func findInPageChecks(engine: ChromiumEngine, base: String) async throws {
        engine.load(URL(string: "\(base)/find")!)
        try await wait("find fixture loaded") { engine.pageTitle == "find" && !engine.isLoading }
        try check(engine.attachmentID != nil, "find needs an attached tab (a 0x0 view reports no matches)")
        let invalid = ReArcTabFindNext(engine.tabID, true)
        try check(invalid == ReArcStatus(REARC_INVALID_STATE), "FindNext without a session returned \(invalid.rearcName)")
        let empty = "".withCString { text -> ReArcStatus in
            var session: UInt64 = 0
            return ReArcTabFindStart(engine.tabID, text, UInt32(REARC_FIND_FORWARD), &session)
        }
        try check(empty == ReArcStatus(REARC_INVALID_ARGUMENT), "empty find text returned \(empty.rearcName)")

        var terminals: [FindInPageEvent.Reason] = []
        let find = FindBarModel()
        find.present(on: engine)
        // The bar owns onFindEvent; wrap it to also count terminals.
        let barHandler = engine.onFindEvent
        engine.onFindEvent = { event in
            if event.reason != .result { terminals.append(event.reason) }
            barHandler?(event)
        }
        find.setQuery("needl")
        find.setQuery("needle")
        try await wait("find: 1 of 4") { find.statusText == "1 of 4" }
        try check(terminals.contains(.replaced), "the first keystroke's session did not end as replaced (\(terminals))")
        var steps = [find.statusText]
        for forward in [true, false, false] {
            let before = find.state.activeOrdinal
            find.next(forward: forward)
            try await wait("find \(forward ? "next" : "previous") from \(before)") { find.state.activeOrdinal != before }
            steps.append(find.statusText)
        }
        try check(steps == ["1 of 4", "2 of 4", "1 of 4", "4 of 4"], "find ordinals \(steps)")
        find.setMatchCase(true)
        try await wait("case-sensitive count") { find.state.matchCase && find.state.matchCount == 2 }
        find.setQuery("zzz-not-on-page")
        try await wait("no matches") { find.hasNoMatches }
        let noMatches = find.statusText
        find.setQuery("needle")
        try await wait("case-sensitive needle again") { find.state.matchCount == 2 }
        let stopsBefore = terminals.filter { $0 == .stopped }.count
        find.close()
        // Closing detaches the bar's handler; the stop terminal is delivered after this turn.
        engine.onFindEvent = { event in if event.reason != .result { terminals.append(event.reason) } }
        try await wait("stop terminal") { terminals.filter { $0 == .stopped }.count == stopsBefore + 1 }
        try check(engine.findSessionID == 0, "engine still holds find session \(engine.findSessionID)")

        // A navigation ends the session exactly once; Return then searches the new document.
        find.present(on: engine)
        let handler = engine.onFindEvent
        engine.onFindEvent = { event in
            if event.reason != .result { terminals.append(event.reason) }
            handler?(event)
        }
        try await wait("reopened bar repeats the query") { find.state.matchCount == 2 }
        engine.load(URL(string: "\(base)/a")!)
        try await wait("navigation terminal") { terminals.last == .navigated && find.state.sessionID == 0 }
        try await wait("page A after find") { engine.pageTitle == Self.titleA && !engine.isLoading }
        try check(find.statusText.isEmpty, "count still shown after navigation: '\(find.statusText)'")
        find.close()
        engine.onFindEvent = nil
        log("PASS find in page (ABI 1.16, FindBarModel on the attached tab): 'needle' -> \(steps.joined(separator: " -> ")) "
            + "(backward wrap); match case -> 2; '\(noMatches)' for a missing word; terminals \(terminals.map { "\($0)" }); "
            + "FindNext without a session -> invalid_state, empty text -> invalid_argument")
    }

    // MARK: Downloads (ABI 1.17)

    @MainActor
    private func downloadChecks(engine: ChromiumEngine, base: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rearc-selftest-downloads-\(UUID().uuidString)", isDirectory: true)
        let controller = DownloadsController(fileURL: directory.appendingPathComponent("Downloads.json"))
        controller.setDirectory(directory)
        let backend = ChromiumDownloadBackend(runtime: runtime, controller: controller)
        backend.install()
        defer { runtime.onDownloadEvent = nil }
        try check(runtime.downloadDirectory == directory.standardizedFileURL, "policy directory \(runtime.downloadDirectory?.path ?? "nil")")
        let rejected = "relative/dir".withCString { ReArcDownloadSetPolicy(engine.engineProfileID, $0, 0) }
        try check(rejected == ReArcStatus(REARC_INVALID_ARGUMENT), "relative policy directory returned \(rejected.rearcName)")
        let picker = directory.path.withCString { ReArcDownloadSetPolicy(engine.engineProfileID, $0, 1) }
        let expectedPicker = runtime.capabilities.fileChooser ? ReArcStatus.rearcOK : ReArcStatus(REARC_UNSUPPORTED)
        try check(picker == expectedPicker, "prompt mode 1 returned \(picker.rearcName)")
        try check(runtime.applyDownloadPolicy(profile: engine.engineProfileID) == .rearcOK, "policy for engine profile \(engine.engineProfileID)")

        // 1. A small attachment lands in the policy directory without a picker or a navigation.
        func row(_ name: String) -> DownloadRecord? {
            controller.records.first { $0.fileName.hasPrefix(name) || $0.url.hasSuffix("/\(name)") }
        }
        let started = engine.navigateNow(URL(string: "\(base)/download/rearc-small.bin")!)
        try check(started == .rearcOK, "navigating to the attachment returned \(started.rearcName)")
        try await wait("small download complete", timeout: 20) { row("rearc-small.bin")?.state == .complete }
        let small = try XUnwrap(row("rearc-small.bin"))
        let size = (try? FileManager.default.attributesOfItem(atPath: small.targetPath))?[.size] as? Int ?? -1
        try check(small.targetPath.hasPrefix(directory.standardizedFileURL.path), "saved to \(small.targetPath), not the policy directory")
        try check(size == SelfTestFixtureServer.smallDownloadSize, "saved file has \(size) bytes")
        try check(controller.isTrayPresented && controller.startCount >= 1, "a new download did not open the tray")
        // The pending entry's URL may show while the navigation turns into a download; it must not stick.
        try await wait("tab still on page A after the attachment", timeout: 5) { engine.currentURL?.path == "/a" }
        controller.perform(.remove, on: small.id)
        try await wait("removed event drops the row") { row("rearc-small.bin") == nil }
        let removedHandle = backend.handle(for: small.id)
        try check(removedHandle == nil, "backend kept a handle for the removed item")

        // 2. A trickled 1 MiB file: pause -> resume -> progress -> cancel -> remove.
        try check(engine.navigateNow(URL(string: "\(base)/download/rearc-trickle.bin")!) == .rearcOK, "trickle navigation rejected")
        try await wait("trickle started", timeout: 20) { (row("rearc-trickle.bin")?.receivedBytes ?? 0) > 0 }
        let id = try XUnwrap(row("rearc-trickle.bin")).id
        let handle = try XUnwrap(backend.handle(for: id))
        controller.perform(.pause, on: id)
        try await wait("paused") { controller.list.record(withID: id).map { $0.isPaused && $0.canResume } ?? false }
        let pausedAt = controller.list.record(withID: id)?.receivedBytes ?? 0
        let pauseAgain = runtime.downloadAction(profile: handle.profile, id: handle.id, action: 0)
        try check(pauseAgain == ReArcStatus(REARC_INVALID_STATE), "pausing a paused item returned \(pauseAgain.rearcName)")
        controller.perform(.resume, on: id)
        try await wait("resumed with progress", timeout: 20) {
            guard let record = controller.list.record(withID: id) else { return false }
            return !record.isPaused && record.receivedBytes > pausedAt
        }
        let resumedAt = controller.list.record(withID: id)?.receivedBytes ?? 0
        controller.perform(.cancel, on: id)
        try await wait("cancelled") { controller.list.record(withID: id)?.state == .cancelled }
        let status = controller.list.record(withID: id)?.statusText ?? ""
        controller.perform(.remove, on: id)
        try await wait("cancelled row removed") { controller.list.record(withID: id) == nil }
        let gone = runtime.downloadAction(profile: handle.profile, id: handle.id, action: 4)
        try check(gone == ReArcStatus(REARC_NOT_FOUND), "reveal after remove returned \(gone.rearcName)")
        let asked = runtime.capabilities.downloadSavePrompt
            ? try await askWhereToSaveChecks(engine: engine, base: base, controller: controller, backend: backend, directory: directory)
            : "ABI-GAP Ask where to save needs file_chooser (ABI 1.19)"
        controller.save()
        let saved = DownloadListFile.load(from: directory.appendingPathComponent("Downloads.json"))
        try check(saved.directory == directory.standardizedFileURL.path && saved.list.records.isEmpty,
                  "persisted tray: \(saved.directory ?? "nil"), \(saved.list.records.count) row(s)")
        try? FileManager.default.removeItem(at: directory)
        log("PASS downloads (ABI 1.17, DownloadsController + ChromiumDownloadBackend): \(SelfTestFixtureServer.smallDownloadSize)-byte "
            + "attachment saved without a picker to the policy directory (tab stayed on /a), tray opened, remove -> removed event; "
            + "trickle paused at \(pausedAt) B (pause again -> invalid_state), resumed to \(resumedAt) B, '\(status)', "
            + "removed (reveal -> not_found); relative directory -> invalid_argument, prompt 1 -> \(picker.rearcName); "
            + "\(backend.eventCount) events; \(asked)")
    }

    private func XUnwrap<T>(_ value: T?, _ label: String = #function) throws -> T {
        guard let value else { throw Failure(description: "unexpected nil in \(label)") }
        return value
    }

    // MARK: Two windows

    /// One live attachment per tab: showing the tab in a second window detaches
    /// it from the first before re-attaching; closing the second window hands it
    /// back without ending the app.
    @MainActor
    private func twoWindowChecks(engine: ChromiumEngine, first: NSWindow) async throws {
        guard let firstHost = first.contentView?.firstDescendant(ofType: ChromiumHostView.self),
              let firstLease = firstHost.leaseAttachmentID else {
            throw Failure(description: "first window holds no lease")
        }
        let windowsBefore = runtime.registeredWindowCount
        let second = NSWindow(
            contentRect: NSRect(x: 220, y: 160, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        second.isReleasedWhenClosed = false
        second.title = "ReArc Chromium selftest (second window)"
        second.contentView = NSHostingView(rootView: engine.makeView().frame(minWidth: 400, minHeight: 300))
        second.makeKeyAndOrderFront(nil)
        try await wait("lease moved to the second window") {
            guard let secondHost = second.contentView?.firstDescendant(ofType: ChromiumHostView.self) else { return false }
            return secondHost.leaseAttachmentID != nil && engine.leaseHolder === secondHost
        }
        let secondHost = second.contentView?.firstDescendant(ofType: ChromiumHostView.self)
        let secondLease = secondHost?.leaseAttachmentID ?? 0
        try check(firstHost.leaseAttachmentID == nil, "first window kept its lease \(firstLease) after the move")
        try check(secondLease != firstLease && engine.attachmentID == secondLease,
                  "lease ids: first \(firstLease), second \(secondLease), engine \(engine.attachmentID ?? 0)")
        try check(runtime.registeredWindowCount == windowsBefore + 1, "second window not registered")
        let title = try await engine.evaluate("document.title", in: .page)
        log("PASS tab moved to a second window: lease \(firstLease) detached, then \(secondLease) attached in window 2; "
            + "window 1 shows a placeholder; page still live ('\(title)')")

        ChromiumHostView.dismantleAll(in: second)
        second.close()
        try await wait("lease returned to the first window") { firstHost.leaseAttachmentID != nil && engine.leaseHolder === firstHost }
        try await wait("second window unregistered") { runtime.registeredWindowCount == windowsBefore }
        try check(first.isVisible && NSApp.isRunning, "closing the second window ended the app or hid the first")
        second.contentView = nil
        log("PASS second window closed without quitting: lease \(firstHost.leaseAttachmentID ?? 0) re-attached in window 1, "
            + "registered windows \(runtime.registeredWindowCount)")
    }

    // MARK: Profiles

    @MainActor
    private func makeEngine(_ context: EngineProfileContext, privateSession: UUID? = nil) async throws -> ChromiumEngine {
        let engine = ChromiumEngine(runtime: runtime, context: context, role: .tab, shellID: UUID(), privateSession: privateSession)
        try check(await engine.waitForTab(), "no tab for \(engine.profileKey): \(engine.lastError ?? "no error")")
        return engine
    }

    @MainActor
    private func loadPageA(_ engine: ChromiumEngine, base: String) async throws {
        engine.load(URL(string: "\(base)/a")!)
        try await wait("page A in \(engine.profileKey)", timeout: 20) {
            engine.pageTitle == Self.titleA && !engine.isLoading
        }
    }

    @MainActor
    private func cookies(_ engine: ChromiumEngine) async throws -> String {
        // Never-attached (hidden) tabs can be slow to run script in this debug build.
        try await engine.evaluate("document.cookie", in: .page, timeoutMS: 10_000) as? String ?? ""
    }

    @MainActor
    private func profileChecks(base: String) async throws {
        let profileA = UUID()
        let profileB = UUID()
        let a1 = try await makeEngine(EngineProfileContext(profileID: profileA))
        let a2 = try await makeEngine(EngineProfileContext(profileID: profileA))
        let b = try await makeEngine(EngineProfileContext(profileID: profileB))
        try check(a1.engineProfileID == a2.engineProfileID && a1.engineProfileID != b.engineProfileID
                  && a1.engineProfileID != runtime.defaultProfileID && b.engineProfileID != runtime.defaultProfileID,
                  "engine profiles: A \(a1.engineProfileID)/\(a2.engineProfileID), B \(b.engineProfileID), default \(runtime.defaultProfileID)")
        for engine in [a1, a2, b] { try await loadPageA(engine, base: base) }
        _ = try await a1.evaluate("(document.cookie = 'rearc_profile=A; path=/; max-age=3600', document.cookie)", in: .page)
        let inA2 = try await cookies(a2)
        let inB = try await cookies(b)
        try check(inA2.contains("rearc_profile=A"), "same-profile tab does not see the cookie ('\(inA2)')")
        try check(!inB.contains("rearc_profile"), "profile B sees profile A's cookie ('\(inB)')")
        log("PASS profiles isolated: \(a1.profileKey) -> engine profile \(a1.engineProfileID), \(b.profileKey) -> \(b.engineProfileID); "
            + "cookie set in A visible to A's second tab ('\(inA2)'), invisible in B ('\(inB)')")

        // Off the record under A: in memory, sees neither A's cookies nor leaks its own.
        let session = UUID()
        let otr = try await makeEngine(EngineProfileContext(profileID: profileA, isEphemeral: true), privateSession: session)
        let otrKey = otr.profileKey
        try check(otrKey == .offTheRecord(session: session, parent: profileA)
                  && otr.engineProfileID != a1.engineProfileID && otr.engineProfileID != 0,
                  "OTR key \(otrKey) engine profile \(otr.engineProfileID)")
        try await loadPageA(otr, base: base)
        let inOTR = try await cookies(otr)
        try check(!inOTR.contains("rearc_profile"), "off-the-record tab sees the parent's cookie ('\(inOTR)')")
        _ = try await otr.evaluate("(document.cookie = 'rearc_otr=1; path=/', document.cookie)", in: .page)
        let parentAfter = try await cookies(a2)
        try check(!parentAfter.contains("rearc_otr"), "parent profile sees the off-the-record cookie ('\(parentAfter)')")
        log("PASS off-the-record window profile \(otr.engineProfileID) under \(a1.engineProfileID): parent cookie invisible ('\(inOTR)'), "
            + "its own cookie stays out of the parent ('\(parentAfter)')")

        // Teardown: closing A closes the OTR child first, then A; keep engines until the completion.
        var events: [String] = []
        runtime.onProfileEvent = { events.append($0) }
        var closed: (ReArcStatus, Bool)?
        let oldA = a1.engineProfileID
        runtime.closeProfile(.persistent(profileA), force: true) { closed = ($0, $1) }
        try await wait("profile A close", timeout: 20) { closed != nil }
        runtime.onProfileEvent = nil
        try check(closed?.0 == .rearcOK && closed?.1 == false, "profile A close: \(closed?.0.rearcName ?? "-") cancelled \(closed?.1 ?? false)")
        let closedOrder = events.filter { $0.hasPrefix("closed ") }
        try check(closedOrder.count == 2 && closedOrder[0].contains("private session") && closedOrder[1].contains(ChromiumProfileKey.storageKey(for: profileA)),
                  "teardown order: \(closedOrder)")
        try check(runtime.engineProfileID(for: otrKey) == nil && runtime.engineProfileID(for: .persistent(profileA)) == nil,
                  "profiles still open after close")
        log("PASS teardown order: " + closedOrder.joined(separator: " then "))
        _ = (a1, a2, otr)

        // Reopening A yields a new engine ID; its persistent cookie survived.
        let reopened = try await makeEngine(EngineProfileContext(profileID: profileA))
        try await loadPageA(reopened, base: base)
        let persisted = try await cookies(reopened)
        try check(reopened.engineProfileID != oldA && persisted.contains("rearc_profile=A") && !persisted.contains("rearc_otr"),
                  "reopened A: engine \(oldA) -> \(reopened.engineProfileID), cookies '\(persisted)'")
        log("PASS reopened \(reopened.profileKey): engine profile \(oldA) -> \(reopened.engineProfileID), persistent cookie kept ('\(persisted)')")
        _ = b
    }

    // MARK: Shell windows

    @MainActor
    private func shellEngine(_ model: BrowserViewModel, _ tab: Tab) throws -> ChromiumEngine {
        guard let engine = model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab)) as? ChromiumEngine else {
            throw Failure(description: "no ChromiumEngine for shell tab \(tab.title)")
        }
        return engine
    }

    @MainActor
    private func checkOneLease(_ engine: ChromiumEngine, _ label: String) throws {
        let leases = runtime.liveLeaseCount(forTab: engine.tabID)
        try check(leases == 1, "\(label): tab \(engine.tabID) holds \(leases) live attachments")
    }

    /// Drives `ChromiumShell` (the normal Chromium-path UI) with a throwaway
    /// sidebar: the same BrowserView, LittleArcWindowView and PrivateWindowView
    /// the app shows, through the model's own commands.
    @MainActor
    private func shellChecks(base: String) async throws {
        let sidebarFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rearc-selftest-sidebar-\(UUID().uuidString).json")
        let store = SidebarStore()
        let tabA = store.addTab(kind: .today, title: "Shell A", url: URL(string: "\(base)/a")!)
        store.selectTab(tabA.id)
        // As ChromiumShell.makeModel does: the owner is named before the model loads tab A.
        runtime.legacyDefaultOwner = store.profiles.first?.id
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: sidebarFile),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        let shell = ChromiumShell(runtime: runtime, autosavesFrames: false)
        shell.start(model: model)
        guard let first = shell.browserWindows.first else { throw Failure(description: "ChromiumShell opened no browser window") }
        let engineA = try shellEngine(model, tabA)
        try await wait("shell tab A attached and loaded", timeout: 20) {
            engineA.attachmentID != nil && engineA.pageTitle == Self.titleA && !engineA.isLoading
        }
        try check(engineA.leaseHolder?.window === first, "tab A's lease is not in the shell window")
        try checkOneLease(engineA, "shell window")
        log("PASS shell browser window: BrowserView attached tab A (lease \(engineA.attachmentID ?? 0), \(engineA.profileKey) "
            + "-> engine profile \(engineA.engineProfileID))")
        if runtime.capabilities.profileDirectory, let owner = store.profiles.first?.id {
            // Wave 16 adoption: the first shell profile opened the startup Default directory in place.
            let mapURL = runtime.userDataDir?.appendingPathComponent(ChromiumProfileStorageMap.fileName)
            let saved = mapURL.map(ChromiumProfileStorageMap.load(from:))
            try check(engineA.engineProfileID == runtime.defaultProfileID,
                      "first profile's tab is on engine profile \(engineA.engineProfileID), not the startup \(runtime.defaultProfileID)")
            try check(runtime.storageMap.legacyDefault == .adopted && runtime.storageMap.storage(for: owner) == .directory("Default"),
                      "storage map after adoption: \(runtime.storageMap)")
            try check(saved == runtime.storageMap, "persisted storage map \(String(describing: saved)) differs")
            log("PASS Default adopted in place: \(engineA.profileKey) -> startup engine profile \(runtime.defaultProfileID), "
                + "mapping persisted in \(mapURL?.lastPathComponent ?? "-")")
        }

        // A second browser window on the same model shows the same selected tab:
        // the lease moves (detach, then attach) and returns when it closes.
        let leaseBefore = engineA.attachmentID ?? 0
        guard let second = shell.openBrowserWindow() else { throw Failure(description: "New Window opened nothing") }
        try await wait("lease moved to the second browser window") {
            engineA.leaseHolder?.window === second && engineA.attachmentID != nil && engineA.attachmentID != leaseBefore
        }
        try checkOneLease(engineA, "two browser windows")
        let leaseInSecond = engineA.attachmentID ?? 0
        shell.closeWindow(second)
        try await wait("lease back in the first browser window") {
            engineA.leaseHolder?.window === first && engineA.attachmentID != nil && engineA.attachmentID != leaseInSecond
        }
        try checkOneLease(engineA, "after closing window 2")
        try check(shell.browserWindowCount == 1 && first.isVisible && NSApp.isRunning, "closing window 2 changed the app")
        log("PASS New Window: tab A lease \(leaseBefore) -> \(leaseInSecond) (window 2) -> \(engineA.attachmentID ?? 0) (window 1 "
            + "after window 2 closed); one live attachment throughout; app still running")

        // Split view: both panes attach at once, each its own tab and lease.
        model.addSplitView(orientation: .horizontal)
        guard let split = store.splitContaining(tabID: tabA.id)?.split,
              let companionTab = split.tabs.first(where: { $0.id != tabA.id }) else {
            throw Failure(description: "Add Split View created no split")
        }
        let companion = try shellEngine(model, companionTab)
        try await wait("both split panes attached", timeout: 20) {
            engineA.attachmentID != nil && companion.attachmentID != nil
                && engineA.leaseHolder?.window === first && companion.leaseHolder?.window === first
        }
        try checkOneLease(engineA, "split pane A")
        try checkOneLease(companion, "split companion")
        log("PASS Split View: tab \(engineA.tabID) lease \(engineA.attachmentID ?? 0) and companion tab \(companion.tabID) "
            + "lease \(companion.attachmentID ?? 0) attached side by side in window 1")
        model.closeTab(companionTab.id)
        model.selectTab(tabA.id)
        try await wait("tab A alone after closing the split companion") {
            store.splitContaining(tabID: tabA.id) == nil && engineA.attachmentID != nil
        }

        // Peek: an overlay engine in the same profile, attached over the page.
        model.showPeek(url: URL(string: "\(base)/a")!)
        guard let session = model.peekSession,
              let peek = model.engineHost.ephemeralEngine(withID: session.engineID, profileID: session.profileID) as? ChromiumEngine else {
            throw Failure(description: "Peek created no Chromium engine")
        }
        try await wait("peek attached and loaded", timeout: 20) {
            peek.attachmentID != nil && peek.pageTitle == Self.titleA && !peek.isLoading
        }
        try check(peek.role == .peek && peek.engineProfileID == engineA.engineProfileID && peek.leaseHolder?.window === first,
                  "peek role \(peek.role) profile \(peek.engineProfileID) vs \(engineA.engineProfileID)")
        log("PASS Peek: overlay tab \(peek.tabID) lease \(peek.attachmentID ?? 0) in window 1, same engine profile \(peek.engineProfileID)")
        model.dismissPeek()
        try await wait("peek dismissed") { model.peekSession == nil && runtime.liveLeaseCount(forTab: peek.tabID) == 0 }

        // Little Arc: its own NSWindow through BrowserWindowPresenting.
        let record = model.openLittleArc(url: URL(string: "\(base)/a")!)
        guard let littleWindow = shell.window(forLittleArc: record.id),
              let little = model.littleArcEngine(for: record.id) as? ChromiumEngine else {
            throw Failure(description: "Little Arc opened no window/engine")
        }
        try await wait("Little Arc attached and loaded", timeout: 20) {
            little.attachmentID != nil && little.pageTitle == Self.titleA && !little.isLoading
        }
        try check(little.role == .littleArc && little.leaseHolder?.window === littleWindow, "Little Arc lease not in its window")
        let littleLease = little.attachmentID ?? 0
        shell.dismissLittleArcWindow(record.id)
        try await wait("Little Arc window closed and archived") {
            shell.window(forLittleArc: record.id) == nil && store.littleArcWindow(withID: record.id) == nil
        }
        try check(NSApp.isRunning && first.isVisible, "closing Little Arc changed the app")
        log("PASS Little Arc: own window with tab \(little.tabID) lease \(littleLease); closed (lease released: "
            + "\(little.attachmentID == nil)) and archived; app still running")

        // Zoom commands: Cmd+= on the focused tab; Chromium's per-host zoom also
        // reaches a sibling same-host tab of the same profile.
        let tabB = store.addTab(kind: .today, title: "Shell B", url: URL(string: "\(base)/boost")!)
        model.selectTab(tabA.id)
        // A background tab gets an engine only when something loads it (here, the test).
        try check(model.engineHost.engine(forTabID: tabB.id, profileID: model.profileID(for: tabB)) == nil,
                  "an unselected tab got an engine without being loaded")
        _ = model.engineHost.engine(for: tabB, profileID: model.profileID(for: tabB))
        let engineB = try shellEngine(model, tabB)
        engineB.load(tabB.url)
        try await wait("sibling tab B loaded", timeout: 20) { engineB.currentURL?.path == "/boost" && !engineB.isLoading }
        model.zoom(.zoomIn)
        let zoomed = PageZoom.factor(after: .zoomIn, from: 1.0)
        try await wait("zoom in on tab A and its same-host sibling") {
            abs(engineA.zoomFactor - zoomed) < PageZoom.tolerance && abs(engineB.zoomFactor - zoomed) < PageZoom.tolerance
        }
        model.zoom(.reset)
        try await wait("zoom reset on both") { PageZoom.isDefault(engineA.zoomFactor) && PageZoom.isDefault(engineB.zoomFactor) }
        log(String(format: "PASS zoom command: Zoom In -> tab A %.2f and same-host tab B %.2f (zoom events); Actual Size -> 1.00", zoomed, zoomed))

        try await sidebarNavigationChecks(model: model, store: store, tab: tabA, engine: engineA, base: base)
        try await shellFindAndHistoryChecks(model: model, engine: engineA, base: base)

        // Private window: PrivateWindowModel on an off-the-record profile under the
        // active profile; its end closes that profile, and a new one starts empty.
        _ = try await engineA.evaluate("(document.cookie = 'rearc_shell=normal; path=/; max-age=3600', document.cookie)", in: .page)
        let privateWindow = model.openPrivateWindow(url: URL(string: "\(base)/a")!)
        guard let privateEngine = privateWindow.engine as? ChromiumEngine else {
            throw Failure(description: "private window engine is not Chromium")
        }
        try await wait("private window attached and loaded", timeout: 20) {
            privateEngine.attachmentID != nil && privateEngine.pageTitle == Self.titleA && !privateEngine.isLoading
                && privateWindow.hostWindow != nil
        }
        let privateKey = privateEngine.profileKey
        try check(privateKey == .offTheRecord(session: privateWindow.session, parent: store.activeProfileID)
                  && privateEngine.role == .privateWindow && privateEngine.engineProfileID != engineA.engineProfileID
                  && privateEngine.leaseHolder?.window === privateWindow.hostWindow,
                  "private window: \(privateKey) engine profile \(privateEngine.engineProfileID)")
        let privateCookies = try await cookies(privateEngine)
        try check(!privateCookies.contains("rearc_shell"), "private window sees the normal cookie ('\(privateCookies)')")
        _ = try await privateEngine.evaluate("(document.cookie = 'rearc_private_window=1; path=/', document.cookie)", in: .page)
        let normalCookies = try await cookies(engineA)
        try check(!normalCookies.contains("rearc_private_window"), "normal tab sees the private cookie ('\(normalCookies)')")
        if NSApp.keyWindow === privateWindow.hostWindow {
            model.zoom(.zoomIn)
            try await wait("zoom command on the key private window") { !PageZoom.isDefault(privateEngine.zoomFactor) }
            try check(PageZoom.isDefault(engineA.zoomFactor), "private-window zoom changed the normal tab")
            log(String(format: "PASS zoom command targets the key private window (%.2f); normal tab stays 1.00", privateEngine.zoomFactor))
        } else {
            log("NOTE the private window is not key (app inactive); its zoom-command routing is not exercised")
        }
        let privateProfileID = privateEngine.engineProfileID
        var events: [String] = []
        runtime.onProfileEvent = { events.append($0) }
        guard let privateNSWindow = privateWindow.hostWindow else { throw Failure(description: "private window has no NSWindow") }
        shell.closeWindow(privateNSWindow)
        try await wait("private session closed", timeout: 20) {
            events.contains { $0.hasPrefix("closed private session") } && runtime.engineProfileID(for: privateKey) == nil
        }
        runtime.onProfileEvent = nil
        try check(model.privateWindows.isEmpty && NSApp.isRunning && first.isVisible, "closing the private window changed the app")
        let again = model.openPrivateWindow(url: URL(string: "\(base)/a")!)
        guard let againEngine = again.engine as? ChromiumEngine else { throw Failure(description: "second private engine") }
        try await wait("second private window loaded", timeout: 20) { againEngine.pageTitle == Self.titleA && !againEngine.isLoading }
        let againCookies = try await cookies(againEngine)
        try check(againEngine.engineProfileID != privateProfileID && !againCookies.contains("rearc_private_window"),
                  "new private session: engine profile \(againEngine.engineProfileID), cookies '\(againCookies)'")
        if let againWindow = again.hostWindow { shell.closeWindow(againWindow) }
        try await wait("second private session closed", timeout: 20) {
            model.privateWindows.isEmpty && runtime.engineProfileID(for: againEngine.profileKey) == nil
        }
        log("PASS private window: \(privateKey) -> engine profile \(privateProfileID), normal cookie invisible, private cookie "
            + "stays out of the normal tab; window close -> \(events.filter { $0.hasPrefix("closed") }.joined(separator: ", ")); "
            + "next private window -> new engine profile \(againEngine.engineProfileID) without the old cookie")

        // Closing every window keeps the app (and engine) running; activation reopens one.
        shell.closeWindow(first)
        try await wait("all shell windows closed") { shell.windowCount == 0 && engineA.attachmentID == nil }
        try check(NSApp.isRunning && runtime.isReady && !runtime.isStopping, "closing the last window stopped the app")
        shell.reopenIfNoWindows()
        guard let reopened = shell.browserWindows.first else { throw Failure(description: "reopen opened no window") }
        try await wait("tab A re-attached in the reopened window", timeout: 20) {
            engineA.leaseHolder?.window === reopened && engineA.attachmentID != nil
        }
        try checkOneLease(engineA, "reopened window")
        log("PASS closing the last window kept the app running (no quit); reopen attached tab A again (lease \(engineA.attachmentID ?? 0))")
        try? FileManager.default.removeItem(at: sidebarFile)
    }

    // MARK: Sidebar navigation controls (wave 17)

    /// The shell's own paths: Cmd+F on BrowserView's tab, and command-bar
    /// history recorded from the navigations the shell just made.
    @MainActor
    private func shellFindAndHistoryChecks(model: BrowserViewModel, engine: ChromiumEngine, base: String) async throws {
        let navURL = URL(string: "\(base)/nav")!
        let visit = model.visitHistory.record(for: navURL)
        try check(visit != nil, "the shell recorded no visit for /nav (\(model.visitHistory.count) visit(s))")
        model.commandBarText = "nav:"
        let historyRow = model.commandBarResults.first { $0.kind == .history }
        try check(historyRow?.destinationURL.flatMap(VisitHistory.key(for:)) == VisitHistory.key(for: navURL),
                  "command bar history row: \(historyRow.map { "\($0.title) \($0.destinationURL?.absoluteString ?? "")" } ?? "none")")
        model.commandBarText = ""
        if runtime.capabilities.findInPage {
            model.showFindBar()
            try check(model.findBar.isShown(for: engine), "Cmd+F did not open the find bar on tab A")
            model.findBar.setQuery("selftest page")
            try await wait("shell find bar result") { model.findBar.statusText == "1 of 1" }
            model.findNext(forward: true)
            try await wait("shell find next wraps") { model.findBar.state.activeOrdinal == 1 && model.findBar.state.sessionID != 0 }
            model.closeFindBar()
            try check(!model.findBar.isPresented, "find bar still open")
        }
        log("PASS shell find and history: /nav recorded (\(visit?.visitCount ?? 0) visit(s), '\(visit?.title ?? "")'), "
            + "command bar 'nav:' -> history row '\(historyRow?.title ?? "")'"
            + (runtime.capabilities.findInPage ? "; Cmd+F on tab A -> '1 of 1', Cmd+G wraps, Esc closes" : ""))
    }

    /// The sidebar's back/forward/reload/stop and lock state act on the
    /// selected tab's engine through BrowserViewModel (the menu and command-bar
    /// paths call the same methods), and the engine's favicon reaches the
    /// sidebar's favicon cache.
    @MainActor
    private func sidebarNavigationChecks(
        model: BrowserViewModel,
        store: SidebarStore,
        tab: Tab,
        engine: ChromiumEngine,
        base: String
    ) async throws {
        model.selectTab(tab.id)
        try check(model.navigationEngine === engine, "navigation commands do not target the selected tab's engine")
        if ReArcEngineHasFeature("favicon") {
            try await wait("tab A favicon in the sidebar cache", timeout: 15) {
                store.tab(withID: tab.id).map { model.favicon(for: $0) != nil } ?? false
            }
            log("PASS sidebar favicon: tab A row icon from ReArcFaviconGet (\(engine.faviconData?.count ?? 0) bytes) via FaviconStore")
        }
        if ReArcEngineHasFeature("security_state") {
            try await wait("security_state event for tab A", timeout: 10) { engine.securityLevel != 4 }
            log("PASS security_state for \(engine.currentURL?.absoluteString ?? "") -> level \(engine.securityLevel) "
                + "(\(engine.securityState)) shown by the sidebar URL field")
        }

        func title() -> String { engine.pageTitle ?? "" }
        func loadCount() -> Int { Int(title().split(separator: ":").last ?? "") ?? 0 }
        engine.load(URL(string: "\(base)/nav")!)
        try await wait("navigation fixture loaded", timeout: 15) { title().hasPrefix("nav:navigate:") && !engine.isLoading }
        model.goBack()
        try await wait("sidebar Back -> /a", timeout: 15) { engine.currentURL?.path == "/a" && !engine.isLoading }
        try await wait("canGoForward after Back") { engine.canGoForward }
        model.goForward()
        try await wait("sidebar Forward -> /nav", timeout: 15) {
            engine.currentURL?.path == "/nav" && !engine.isLoading && title().hasPrefix("nav:")
        }
        let before = loadCount()
        model.reload()
        try await wait("sidebar Reload", timeout: 15) { title() == "nav:reload:\(before + 1)" && !engine.isLoading }
        model.reload(ignoringCache: true)
        try await wait("Reload Ignoring Cache", timeout: 15) { title() == "nav:reload:\(before + 2)" && !engine.isLoading }
        log("PASS sidebar navigation: Back/Forward between /a and /nav, Reload -> '\(before + 1)', Reload Ignoring Cache -> '\(title())'")

        engine.load(URL(string: "\(base)/slow")!)
        try await wait("slow load in flight", timeout: 10) { engine.isLoading }
        let started = Date()
        model.reloadOrStop()
        try await wait("Stop ended the load before the fixture answered", timeout: SelfTestFixtureServer.slowResponseDelay - 2) {
            !engine.isLoading
        }
        try check(title() != "slow-loaded", "the stopped page still loaded")
        log(String(format: "PASS Stop (ReArcTabStop) ended the in-flight load after %.2f s; page stays '%@'",
                   Date().timeIntervalSince(started), title()))
        // Back to page A so the checks that follow see the state they expect.
        engine.load(URL(string: "\(base)/a")!)
        try await wait("tab A restored after navigation checks", timeout: 15) {
            engine.currentURL?.path == "/a" && engine.pageTitle == Self.titleA && !engine.isLoading
        }
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

        if runtime.capabilities.webUIDailyPages {
            var committed: [String] = []
            for page in [BrowserInternalPage.history, .downloads, .passwords, .extensions] {
                let status = engine.navigateNow(page.url)
                try check(status == .rearcOK, "\(page.url) rejected: \(status.rearcName)")
                let host = page.url.host()
                try await wait("\(page.url) commit", timeout: 25) {
                    engine.currentURL?.scheme == "chrome" && engine.currentURL?.host() == host && !engine.isLoading
                }
                committed.append("\(engine.currentURL?.absoluteString ?? "") '\(engine.pageTitle ?? "")'")
            }
            log("PASS daily WebUI committed (webui_daily_pages): \(committed.joined(separator: ", "))")
        } else {
            log("ABI-GAP webui_daily_pages not advertised: History, Downloads, Passwords and Extensions stay hidden")
        }

        var rejected: [String] = []
        for bad in ["javascript:void(0)", "chrome://flags", "view-source:view-source:\(base)/a"] {
            let status = engine.navigateNow(URL(string: bad)!)
            try check(status == ReArcStatus(REARC_INVALID_URL), "\(bad) returned \(status.rearcName)")
            rejected.append(bad)
        }
        log("PASS still rejected with invalid_url: \(rejected.joined(separator: ", "))")
    }

    /// ABI 1.13: an existing directory opens in place; the startup one returns
    /// the startup ID; bad syntax rejects synchronously, a missing one async.
    @MainActor
    private func profileDirectoryChecks() async throws {
        func open(_ token: String) async -> (ReArcStatus, UInt64) {
            await withCheckedContinuation { continuation in
                runtime.openDirectory(token) { status, id, _ in continuation.resume(returning: (status, id)) }
            }
        }
        let (defaultStatus, defaultID) = await open("Default")
        try check(defaultStatus == .rearcOK && defaultID == runtime.defaultProfileID,
                  "OpenDirectory(Default) -> \(defaultStatus.rearcName) id \(defaultID), startup \(runtime.defaultProfileID)")
        let (missingStatus, missingID) = await open("rearc-selftest-missing")
        try check(missingStatus != .rearcOK && missingID == 0, "missing directory -> \(missingStatus.rearcName) id \(missingID)")
        let (traversalStatus, _) = await open("../Default")
        try check(traversalStatus == ReArcStatus(REARC_INVALID_ARGUMENT), "../Default -> \(traversalStatus.rearcName)")
        try check(runtime.liveProfileContexts == 0, "\(runtime.liveProfileContexts) directory request context(s) never released")
        log("PASS OpenDirectory: Default -> startup profile \(defaultID); missing -> \(missingStatus.rearcName); "
            + "../Default -> \(traversalStatus.rearcName); contexts released")
    }

    @MainActor
    private func shutdown() {
        log("requesting orderly shutdown")
        let status = runtime.requestShutdown(force: true) { [self] status, cancelled in
            shutdownStatus = cancelled ? ReArcStatus(REARC_CANCELLED) : status
            log("shutdown completion: \(status.rearcName) cancelled=\(cancelled) attached=\(engine?.attachmentID != nil)")
            if status != .rearcOK {
                // Rejected after waiting for closes in flight: Run will not return.
                failures.append("ReArcEngineShutdown rejected: \(status.rearcName)")
                log("FAIL ReArcEngineShutdown rejected: \(status.rearcName)")
                fflush(stdout)
                _exit(1)
            }
        }
        if status != .rearcOK {
            failures.append("ReArcEngineShutdown rejected: \(status.rearcName)")
            log("FAIL ReArcEngineShutdown rejected: \(status.rearcName)")
            fflush(stdout)
            _exit(1)
        }
    }
}

// MARK: - Host prompt channels (ABI 1.18–1.22)

/// Answers file panels for the self-test: records each request and replies
/// with `reply` (nil cancels) unless `hold` keeps the panel open.
private final class SelfTestFilePanels: FilePanelPresenting {
    final class Handle: FilePanelHandle {
        var closed = false
        func close() { closed = true }
    }

    var requests: [FileChooserRequest] = []
    var handles: [Handle] = []
    var reply: [URL]?
    var hold = false

    func present(_ request: FileChooserRequest, in window: NSWindow?, completion: @escaping ([URL]?) -> Void) -> FilePanelHandle? {
        requests.append(request)
        let handle = Handle()
        handles.append(handle)
        if !hold {
            let reply = self.reply
            DispatchQueue.main.async { completion(reply) }
        }
        return handle
    }
}

/// Stands in for the NSMenu (whose tracking loop would block the run): records each plan.
private final class SelfTestMenus: PageContextMenuPresenting {
    var plans: [PageContextMenuPlan] = []
    var choice: PageContextMenuItem?
    var hold = false

    func present(_ plan: PageContextMenuPlan, at point: CGPoint, in view: NSView?, completion: @escaping (PageContextMenuItem?) -> Void) {
        plans.append(plan)
        guard !hold else { return }
        let choice = self.choice
        DispatchQueue.main.async { completion(choice) }
    }
}

extension ChromiumSelfTest {
    /// Synthesized input reaches the renderer only while the app is active and the window key and visible.
    @MainActor
    private func inputDeliverable(_ window: NSWindow) -> Bool {
        NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
    }

    @MainActor
    private func cssCenter(of selector: String, in engine: ChromiumEngine) async throws -> CGPoint {
        let point = try await engine.evaluate(
            "(function(){ var r = document.querySelector('\(selector)').getBoundingClientRect(); "
                + "return { x: r.left + Math.min(30, r.width / 2), y: r.top + r.height / 2 }; })()",
            in: .page
        ) as? [String: Double]
        guard let x = point?["x"], let y = point?["y"] else { throw Failure(description: "no \(selector) on the page") }
        return CGPoint(x: x, y: y)
    }

    /// Brings the window forward and gives the page the keyboard.
    @MainActor
    private func focus(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let host = window.contentView?.firstDescendant(ofType: ChromiumHostView.self), let page = host.subviews.first {
            window.makeFirstResponder(page)
        }
    }

    /// Sends a synthesized (right) click to the page at a CSS point.
    @MainActor
    private func click(_ window: NSWindow, engine: ChromiumEngine, at css: CGPoint, right: Bool = false, control: Bool = false) {
        guard let host = window.contentView?.firstDescendant(ofType: ChromiumHostView.self) else { return }
        window.makeKeyAndOrderFront(nil)
        let viewPoint = PageZoom.viewPoint(fromCSSPoint: css, zoom: engine.zoomFactor)
        let local = NSPoint(x: viewPoint.x, y: host.isFlipped ? viewPoint.y : host.bounds.height - viewPoint.y)
        let location = host.convert(local, to: nil)
        let types: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: control ? [.control] : [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    @MainActor
    private func rightClickUntil(_ window: NSWindow, engine: ChromiumEngine, at css: CGPoint, _ label: String, _ condition: () -> Bool) async throws {
        for attempt in 0..<3 {
            focus(window)
            click(window, engine: engine, at: css, right: attempt < 2, control: attempt == 2)
            if await eventually(timeout: 1.5, condition) { return }
        }
        throw Failure(description: "timed out waiting for \(label) after three right-clicks")
    }

    @MainActor
    private func type(_ text: String, in window: NSWindow) {
        for character in text {
            let string = String(character)
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: string,
                                                charactersIgnoringModifiers: string, isARepeat: false,
                                                keyCode: string == "\r" ? 36 : 0) {
                    window.sendEvent(event)
                }
            }
        }
    }

    /// Waits for `condition`; false (no failure) when it never came, for input-driven steps.
    @MainActor
    private func eventually(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    @MainActor
    private func promptChannelChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let capabilities = runtime.capabilities
        let minor = capabilities.abiMinorVersion.map(String.init) ?? "absent"
        log("prompt channels: javascript_dialogs=\(capabilities.javascriptDialogs ? 1 : 0) file_chooser=\(capabilities.fileChooser ? 1 : 0) "
            + "permission_prompts=\(capabilities.permissionPrompts ? 1 : 0) context_menu=\(capabilities.contextMenu ? 1 : 0) "
            + "password_prompts=\(capabilities.passwordPrompts ? 1 : 0) devtools=\(capabilities.devTools ? 1 : 0); "
            + "synthesized input \(inputDeliverable(window) ? "deliverable" : "not deliverable (app inactive or window not key)")")
        let prompts = engine.pagePrompts
        try check(prompts.anchorView?.window === window, "the page prompt overlay is not in the tab's window")
        // Input-driven channels first, while the app is most likely still active.
        if capabilities.fileChooser {
            try await fileInputChecks(engine: engine, base: base, window: window)
        } else {
            log("ABI-GAP file_chooser not advertised (ABI minor \(minor) < 19): file inputs are cancelled")
        }
        if capabilities.contextMenu {
            try await contextMenuChecks(engine: engine, base: base, window: window)
        } else {
            log("ABI-GAP context_menu not advertised (ABI minor \(minor) < 21): no page menu on Chromium")
        }
        if capabilities.passwordPrompts {
            try await passwordChecks(engine: engine, base: base, window: window)
        } else {
            log("ABI-GAP password_prompts not advertised (ABI minor \(minor) < 22): no save-password offers")
        }
        if capabilities.javascriptDialogs {
            try await beforeUnloadChecks(engine: engine, base: base, window: window)
            try await dialogChecks(engine: engine, base: base, window: window)
        } else {
            log("ABI-GAP javascript_dialogs not advertised (ABI minor \(minor) < 18): pages get Chromium's no-host cancel")
        }
        if capabilities.permissionPrompts {
            try await permissionChecks(engine: engine, base: base)
        } else {
            log("ABI-GAP permission_prompts not advertised (ABI minor \(minor) < 20): requests are dismissed")
        }
        engine.load(URL(string: "\(base)/a")!)
        try await wait("page A after the prompt channels") { engine.pageTitle == Self.titleA && !engine.isLoading }
        try check(!prompts.hasPendingPrompt, "a prompt is still pending after the channel checks")
    }

    // MARK: JavaScript dialogs (ABI 1.18)

    @MainActor
    private func dialogChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        engine.load(URL(string: "\(base)/dialogs")!)
        try await wait("dialogs fixture") { engine.pageTitle == "dialogs" && !engine.isLoading }
        func run(_ kind: String) async throws { _ = try await engine.evaluate("run('\(kind)')", in: .page) }
        func shown(_ kind: JavaScriptDialogKind) async throws -> JavaScriptDialogRequest {
            try await wait("\(kind) dialog request") { prompts.dialog?.request.kind == kind }
            return prompts.dialog!.request
        }

        try await run("alert")
        let alert = try await shown(.alert)
        try check(alert.message == "hello from ReArc" && alert.title.hasPrefix("127.0.0.1") && alert.origin.hasPrefix("http://127.0.0.1"),
                  "alert '\(alert.message)' title '\(alert.title)' origin '\(alert.origin)'")
        try check(prompts.dialog?.offersSuppression == false, "the first dialog offered the dialog limit")
        prompts.answerDialog(accept: true)
        try await wait("alert answered") { engine.pageTitle == "alert:done" }

        try await run("confirm")
        _ = try await shown(.confirm)
        try check(prompts.dialog?.offersSuppression == true, "the second dialog did not offer the dialog limit")
        prompts.answerDialog(accept: false)
        try await wait("confirm cancelled") { engine.pageTitle == "confirm:false" }

        try await run("prompt")
        _ = try await shown(.prompt)
        try check(prompts.dialogText == "default name", "prompt default text '\(prompts.dialogText)'")
        prompts.dialogText = "ReArc ✓"
        prompts.answerDialog(accept: true)
        try await wait("prompt answered") { engine.pageTitle == "prompt:ReArc ✓" }

        // "Don't allow this page to create more dialogs": later dialogs are answered without UI.
        try await run("confirm")
        _ = try await shown(.confirm)
        prompts.suppressDialogs = true
        prompts.answerDialog(accept: true)
        try await wait("confirm accepted") { engine.pageTitle == "confirm:true" }
        let eventsBefore = runtime.promptEvents["dialog"] ?? 0
        try await run("confirm")
        try await wait("suppressed confirm") { engine.pageTitle == "confirm:false" }
        try check(prompts.dialog == nil && (runtime.promptEvents["dialog"] ?? 0) == eventsBefore + 1,
                  "a suppressed dialog was shown (events \(eventsBefore) -> \(runtime.promptEvents["dialog"] ?? 0))")

        // A new document may show dialogs again; navigating away withdraws a pending one.
        engine.load(URL(string: "\(base)/dialogs")!)
        try await wait("dialogs fixture reloaded") { engine.pageTitle == "dialogs" && !engine.isLoading }
        try await run("alert")
        let pending = try await shown(.alert)
        let cancelledBefore = prompts.cancelled["dialog"] ?? 0
        engine.load(URL(string: "\(base)/a")!)
        try await wait("navigation withdraws the alert") { prompts.dialog == nil && (prompts.cancelled["dialog"] ?? 0) == cancelledBefore + 1 }
        try await wait("page A after the withdrawn alert") { engine.pageTitle == Self.titleA && !engine.isLoading }
        let late = runtime.respondDialog(pending.id, JavaScriptDialogReply(accept: true))
        try check(late == ReArcStatus(REARC_NOT_FOUND), "a reply to the withdrawn alert returned \(late.rearcName)")
        log("PASS JavaScript dialogs (ABI 1.18, PagePromptCenter): alert '\(alert.title)' accepted, confirm -> false, "
            + "prompt default 'default name' -> 'ReArc ✓', the second dialog offered the limit and a suppressed confirm "
            + "answered false without UI, navigation withdrew a pending alert (late reply -> \(late.rearcName))")
    }

    /// Leave site?: needs the page's sticky user activation, so a synthesized click first.
    @MainActor
    private func beforeUnloadChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        engine.load(URL(string: "\(base)/leave")!)
        try await wait("leave fixture") { engine.pageTitle == "leave" && !engine.isLoading }
        func activate() async throws -> Bool {
            for _ in 0..<3 {
                focus(window)
                click(window, engine: engine, at: CGPoint(x: 200, y: 200))
                if await waitActivation(engine) { return true }
            }
            return false
        }
        guard try await activate() else {
            log("NOTE beforeunload: synthesized input did not activate the page (app active \(NSApp.isActive), key \(window.isKeyWindow)); "
                + "Leave site? needs sticky user activation, so its veto and accept paths are not exercised in this run")
            return
        }
        // Navigation: Stay keeps the page.
        engine.load(URL(string: "\(base)/a")!)
        let leave = try await waitDialog(prompts, .beforeUnload, "beforeunload on navigation")
        try check(leave.title == "Leave site?", "beforeunload title '\(leave.title)'")
        prompts.answerDialog(accept: false)
        try await Task.sleep(nanoseconds: 800_000_000)
        try check(engine.currentURL?.path == "/leave", "Stay still navigated to \(engine.currentURL?.path ?? "nil")")
        // Normal close: Stay vetoes it (ReArcTabClose OK, cancelled).
        var closes: [Bool] = []
        _ = try await activate()
        try check(engine.requestPageClose { closes.append($0) }, "a normal close was not started")
        _ = try await waitDialog(prompts, .beforeUnload, "beforeunload on close")
        prompts.answerDialog(accept: false)
        try await wait("close vetoed") { closes == [false] }
        try check(engine.tabID != 0 && engine.currentURL?.path == "/leave", "the vetoed close still closed the tab")
        // Leave continues the navigation.
        _ = try await activate()
        engine.load(URL(string: "\(base)/a")!)
        _ = try await waitDialog(prompts, .beforeUnload, "beforeunload before leaving")
        prompts.answerDialog(accept: true)
        try await wait("left the page") { engine.pageTitle == Self.titleA && !engine.isLoading }
        log("PASS beforeunload (ABI 1.18): 'Leave site?' on navigation -> Stay kept /leave; on a normal close -> Stay vetoed "
            + "(tab \(engine.tabID) kept); Leave continued to /a")
    }

    @MainActor
    private func waitActivation(_ engine: ChromiumEngine) async -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if (try? await engine.evaluate("navigator.userActivation.hasBeenActive", in: .page)) as? Bool == true { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    @MainActor
    private func waitDialog(_ prompts: PagePromptCenter, _ kind: JavaScriptDialogKind, _ label: String) async throws -> JavaScriptDialogRequest {
        try await wait(label, timeout: 10) { prompts.dialog?.request.kind == kind }
        return prompts.dialog!.request
    }

    // MARK: Permissions (ABI 1.20)

    @MainActor
    private func permissionChecks(engine: ChromiumEngine, base: String) async throws {
        let prompts = engine.pagePrompts
        let sites = SitePermissionsController(fileURL: nil)
        prompts.sitePermissions = sites
        prompts.profileID = UUID()
        engine.load(URL(string: "\(base)/permissions")!)
        try await wait("permissions fixture") { engine.pageTitle == "permissions" && !engine.isLoading }
        func waitRequest(_ key: String) async throws -> PermissionPromptRequest {
            try await wait("\(key) permission request", timeout: 10) { prompts.permission?.request.types.map(\.key) == [key] }
            return prompts.permission!.request
        }
        func reset() async throws { _ = try await engine.evaluate("(document.title = 'permissions', true)", in: .page) }

        // This time only: the next request prompts again.
        _ = try await engine.evaluate("notify()", in: .page)
        let notify = try await waitRequest("notifications")
        try check(notify.origin.hasPrefix("http://127.0.0.1") && notify.phrases == ["Show notifications"], "request \(notify)")
        prompts.rememberPermission = false
        prompts.answerPermission(.allow)
        try await wait("granted this time") { engine.pageTitle == "notify:granted" }
        try await reset()
        _ = try await engine.evaluate("notify()", in: .page)
        _ = try await waitRequest("notifications")
        // Remembered: Chromium stores the block, and the next request gets no prompt.
        prompts.rememberPermission = true
        prompts.answerPermission(.deny)
        try await wait("denied and remembered") { engine.pageTitle == "notify:denied" }
        try await reset()
        let eventsBefore = runtime.promptEvents["permission"] ?? 0
        _ = try await engine.evaluate("notify()", in: .page)
        try await wait("remembered block answers without a prompt") { engine.pageTitle == "notify:denied" }
        try check(prompts.permission == nil && (runtime.promptEvents["permission"] ?? 0) == eventsBefore,
                  "a remembered block prompted again")

        // Dismiss stores nothing; the page sees PERMISSION_DENIED.
        _ = try await engine.evaluate("geo()", in: .page)
        let geo = try await waitRequest("geolocation")
        try check(geo.needsSystemAuthorization, "geolocation should note macOS authorization")
        prompts.answerPermission(.dismiss)
        try await wait("geolocation dismissed") { engine.pageTitle == "geo:1" }

        // Navigation withdraws a pending request.
        try await reset()
        _ = try await engine.evaluate("geo()", in: .page)
        let pending = try await waitRequest("geolocation")
        let cancelledBefore = prompts.cancelled["permission"] ?? 0
        engine.load(URL(string: "\(base)/a")!)
        try await wait("navigation withdraws the permission prompt") {
            prompts.permission == nil && (prompts.cancelled["permission"] ?? 0) == cancelledBefore + 1
        }
        let late = runtime.respondPermission(pending.id, .allow, persist: true)
        try check(late == ReArcStatus(REARC_NOT_FOUND), "a reply to the withdrawn request returned \(late.rearcName)")
        let recorded = sites.entries(origin: notify.origin, scope: prompts.permissionScope)
        try check(recorded.map(\.type.key) == ["notifications"] && recorded.first?.entry.decision == .deny && recorded.first?.entry.remembered == true,
                  "site record \(recorded.map { "\($0.type.key)=\($0.entry.decision)" })")
        try await wait("page A after permissions") { engine.pageTitle == Self.titleA && !engine.isLoading }
        log("PASS permission prompts (ABI 1.20): notifications allowed this time (prompted again), then blocked and remembered "
            + "(the next request answered without a prompt), geolocation dismissed -> PERMISSION_DENIED, navigation withdrew a "
            + "pending request (late reply -> \(late.rearcName)); site record: notifications blocked (remembered)")
    }

    // MARK: File inputs (ABI 1.19)

    @MainActor
    private func fileInputChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        let panels = SelfTestFilePanels()
        prompts.filePanels = panels
        defer { prompts.filePanels = SystemFilePanelPresenter() }
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-upload-\(UUID().uuidString)", isDirectory: true)
        let folder = fixtures.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        for name in ["a.txt", "b.txt", "folder/c.txt", "folder/d.txt"] {
            try Data("rearc \(name)\n".utf8).write(to: fixtures.appendingPathComponent(name))
        }
        // A symlink out of the folder is not uploaded (the engine skips symlinks).
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.txt"), withDestinationURL: fixtures.appendingPathComponent("a.txt"))

        let invalid = ReArcFileChooserRespond(UInt64.max, true, nil, 0)
        try check(invalid == ReArcStatus(REARC_NOT_FOUND), "a reply to an unknown chooser returned \(invalid.rearcName)")
        engine.load(URL(string: "\(base)/upload")!)
        try await wait("upload fixture") { engine.pageTitle == "upload" && !engine.isLoading }
        panels.reply = [fixtures.appendingPathComponent("a.txt"), fixtures.appendingPathComponent("b.txt")]
        var opened = false
        for _ in 0..<3 where !opened {
            focus(window)
            click(window, engine: engine, at: CGPoint(x: 200, y: 200))
            opened = await eventually(timeout: 1.5) { !panels.requests.isEmpty }
        }
        guard opened else {
            log("NOTE file input: the synthesized click opened no chooser (app active \(NSApp.isActive), key \(window.isKeyWindow)); "
                + "input.click() needs user activation, so <input type=file> is not exercised in this run (save panels are, "
                + "through Ask where to save); unknown request -> \(invalid.rearcName)")
            return
        }
        let multiple = panels.requests[0]
        try check(multiple.mode == .openMultiple && multiple.filter.extensions == ["txt"] && multiple.filter.mimeTypes == ["text/plain"],
                  "chooser mode \(multiple.mode) accept \(multiple.acceptTypes)")
        try await wait("files reached the page") { engine.pageTitle == "files:a.txt,b.txt" }

        _ = try await engine.evaluate("folder()", in: .page)
        panels.reply = [folder]
        click(window, engine: engine, at: CGPoint(x: 200, y: 200))
        try await wait("folder chooser", timeout: 5) { panels.requests.count == 2 }
        try check(panels.requests[1].mode == .uploadFolder, "folder chooser mode \(panels.requests[1].mode)")
        try await wait("folder files reached the page") { engine.pageTitle == "folder:2" }

        // The engine withdraws an open chooser when the page navigates; the panel closes.
        panels.hold = true
        click(window, engine: engine, at: CGPoint(x: 200, y: 200))
        try await wait("held chooser", timeout: 5) { panels.requests.count == 3 }
        engine.load(URL(string: "\(base)/a")!)
        try await wait("navigation closes the chooser") { panels.handles.last?.closed == true && prompts.fileChooserRequest == nil }
        try await wait("page A after the chooser") { engine.pageTitle == Self.titleA && !engine.isLoading }
        log("PASS file chooser (ABI 1.19): <input multiple accept=.txt,text/plain> -> open-multiple with filter [txt] [text/plain], "
            + "2 files reached the page; webkitdirectory -> upload folder, 2 files (symlink skipped); navigation closed a held panel; "
            + "unknown request -> \(invalid.rearcName)")
    }

    /// Ask where to save (policy prompt 1): the save path comes from the file chooser channel.
    @MainActor
    private func askWhereToSaveChecks(
        engine: ChromiumEngine,
        base: String,
        controller: DownloadsController,
        backend: ChromiumDownloadBackend,
        directory: URL
    ) async throws -> String {
        let panels = SelfTestFilePanels()
        engine.pagePrompts.filePanels = panels
        backend.filePanels = panels
        defer {
            engine.pagePrompts.filePanels = SystemFilePanelPresenter()
            backend.filePanels = SystemFilePanelPresenter()
        }
        let chosen = directory.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let target = chosen.appendingPathComponent("renamed-by-panel.bin")
        panels.reply = [target]
        controller.askWhereToSave = true
        defer { controller.askWhereToSave = false }
        try check(runtime.asksWhereToSaveDownloads, "Ask where to save did not reach the policy")
        func row(_ name: String) -> DownloadRecord? { controller.records.first { $0.url.hasSuffix("/\(name)") } }

        try check(engine.navigateNow(URL(string: "\(base)/download/rearc-asked.bin")!) == .rearcOK, "asked download rejected")
        try await wait("save panel request", timeout: 20) { panels.requests.count == 1 }
        let request = panels.requests[0]
        try check(request.mode == .save && request.defaultPath.hasSuffix("rearc-asked.bin"), "save request \(request.mode) '\(request.defaultPath)'")
        try await wait("asked download complete", timeout: 20) { row("rearc-asked.bin")?.state == .complete }
        let saved = try XUnwrap(row("rearc-asked.bin"))
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int ?? -1
        try check(saved.targetPath == target.path && size == SelfTestFixtureServer.smallDownloadSize,
                  "saved to '\(saved.targetPath)' (\(size) bytes), chose '\(target.path)'")
        controller.perform(.remove, on: saved.id)
        try await wait("asked row removed") { row("rearc-asked.bin") == nil }

        // Cancel in the panel cancels the download.
        panels.reply = nil
        try check(engine.navigateNow(URL(string: "\(base)/download/rearc-declined.bin")!) == .rearcOK, "declined download rejected")
        try await wait("second save panel request", timeout: 20) { panels.requests.count == 2 }
        try await wait("declined download cancelled", timeout: 20) {
            guard let record = row("rearc-declined.bin") else { return false }
            return record.state == .cancelled
        }
        if let declined = row("rearc-declined.bin") {
            controller.perform(.remove, on: declined.id)
            try await wait("declined row removed") { row("rearc-declined.bin") == nil }
        }
        try await wait("tab still on page A after the asked downloads", timeout: 5) { engine.currentURL?.path == "/a" }
        return "Ask where to save: save request '\((request.defaultPath as NSString).lastPathComponent)' saved to the chosen "
            + "\(target.lastPathComponent) (\(size) B), panel cancel -> download cancelled"
    }

    // MARK: Page context menu (ABI 1.21)

    @MainActor
    private func contextMenuChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        let menus = SelfTestMenus()
        prompts.contextMenus = menus
        defer { prompts.contextMenus = NSMenuContextMenuPresenter() }
        let unknown = runtime.contextCommand(UInt64.max, .dismiss)
        try check(unknown == ReArcStatus(REARC_NOT_FOUND), "a command for an unknown menu returned \(unknown.rearcName)")
        engine.load(URL(string: "\(base)/dialogs")!)
        try await wait("context menu fixture") { engine.pageTitle == "dialogs" && !engine.isLoading }
        let link = try await cssCenter(of: "#link", in: engine)
        var delivered = false
        for attempt in 0..<3 where !delivered {
            focus(window)
            // A fresh page can drop its first input; the last try is a control-click.
            click(window, engine: engine, at: link, right: attempt < 2, control: attempt == 2)
            delivered = await eventually(timeout: 1.5) { !menus.plans.isEmpty }
        }
        guard delivered else {
            log("NOTE context menu: the synthesized right-click produced no menu request (app active \(NSApp.isActive), "
                + "key \(window.isKeyWindow)); the menu is not exercised in this run; unknown request -> \(unknown.rearcName)")
            return
        }
        let linkPlan = menus.plans[0]
        // Split needs a sidebar tab; this engine is not one.
        try check(linkPlan.items.prefix(2) == [.openLinkInNewTab, .openLinkInLittleArc] && linkPlan.items.contains(.copyLink)
                  && linkPlan.items.contains(.openLinkInNewSplit) == (prompts.ownerTabID != nil),
                  "link menu \(linkPlan.items.map(\.title))")
        try check(linkPlan.entry(.inspect)?.isEnabled == runtime.capabilities.devTools, "Inspect enabled without an inspection engine")
        let repliesBefore = runtime.promptReplies["context"] ?? 0
        try await wait("dismissed link menu") { engine.contextMenuRequestID == nil && (runtime.promptReplies["context"] ?? 0) > repliesBefore }

        // Page menu: Reload runs in the engine.
        _ = try await engine.evaluate("(window.rearcMarker = 1, true)", in: .page)
        menus.choice = .reload
        let plain = try await cssCenter(of: "#plain", in: engine)
        try await rightClickUntil(window, engine: engine, at: plain, "page menu") { menus.plans.count == 2 }
        let pagePlan = menus.plans[1]
        try check(pagePlan.items.contains(.reload) && pagePlan.items.contains(.back) && !pagePlan.items.contains(.copyLink),
                  "page menu \(pagePlan.items.map(\.title))")
        try await waitAsync("reload from the page menu") {
            guard !engine.isLoading else { return false }
            let marker = (try? await engine.evaluate("typeof window.rearcMarker", in: .page)) as? String
            return marker == "undefined"
        }

        // Inspect is refused (unsupported) and the request is dismissed instead.
        menus.hold = true
        try await rightClickUntil(window, engine: engine, at: plain, "held menu") { menus.plans.count == 3 && engine.contextMenuRequestID != nil }
        let held = engine.contextMenuRequestID!
        let inspect = engine.finishContextMenu(held, item: .inspect)
        let expected = runtime.capabilities.devTools ? ReArcStatus.rearcOK : ReArcStatus(REARC_UNSUPPORTED)
        try check(inspect == expected, "Inspect returned \(inspect.rearcName)")
        let again = runtime.contextCommand(held, .dismiss)
        try check(again == ReArcStatus(REARC_NOT_FOUND), "the dismissed menu still accepted a command (\(again.rearcName))")
        log("PASS page context menu (ABI 1.21): link menu \(linkPlan.items.map(\.title)) dismissed; page menu Reload ran in the engine; "
            + "Inspect -> \(inspect.rearcName) then dismissed (repeat -> \(again.rearcName)); unknown request -> \(unknown.rearcName)")
    }

    // MARK: Password offers (ABI 1.22)

    @MainActor
    private func passwordChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        let unknown = runtime.respondPassword(UInt64.max, .notNow)
        try check(unknown == ReArcStatus(REARC_NOT_FOUND), "a reply to an unknown offer returned \(unknown.rearcName)")
        engine.load(URL(string: "\(base)/login")!)
        try await wait("login fixture") { engine.pageTitle == "login" && !engine.isLoading }
        // Chromium detects submissions from trusted typing only (script-set values do not count).
        focus(window)
        click(window, engine: engine, at: try await cssCenter(of: "#user", in: engine))
        type("rearc-user", in: window)
        click(window, engine: engine, at: try await cssCenter(of: "#pass", in: engine))
        type("s3cret-pass-\(Int.random(in: 1000...9999))", in: window)
        click(window, engine: engine, at: try await cssCenter(of: "#go", in: engine))
        guard await eventually(timeout: 10, { prompts.password != nil }) else {
            let typed = (try? await engine.evaluate("document.getElementById('user') ? document.getElementById('user').value : '(left)'", in: .page)) as? String
            log("NOTE password offer: no save offer after synthesized typing (app active \(NSApp.isActive), key \(window.isKeyWindow), "
                + "username field '\(typed ?? "?")', page '\(engine.pageTitle ?? "")'); offers need trusted input, so the prompt is "
                + "not exercised in this run; unknown offer -> \(unknown.rearcName)")
            return
        }
        let offer = prompts.password!.prompt
        try check(offer.username == "rearc-user" && !offer.isUpdate && offer.origin.hasPrefix("http://127.0.0.1"), "offer \(offer)")
        prompts.answerPassword(.notNow)
        let late = runtime.respondPassword(offer.id, .save)
        try check(late == ReArcStatus(REARC_NOT_FOUND), "a second reply to the offer returned \(late.rearcName)")
        log("PASS password offer (ABI 1.22): '\(offer.title)' for \(offer.username) -> Not Now (dismiss; nothing stored), "
            + "second reply -> \(late.rearcName); unknown offer -> \(unknown.rearcName)")
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
        <!doctype html><html><head><title>\(ChromiumSelfTest.titleA)</title><link rel="icon" href="/favicon.png"></head>
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
        // Title = navigation type and a per-tab load count, so reloads are observable.
        "/nav": """
        <!doctype html><html><head><title>nav-pending</title><script>
        var n = Number(sessionStorage.getItem('rearcNav') || '0') + 1;
        sessionStorage.setItem('rearcNav', String(n));
        document.title = 'nav:' + performance.getEntriesByType('navigation')[0].type + ':' + n;
        </script></head><body style="font:32px -apple-system"><h1>ReArc selftest navigation page</h1></body></html>
        """,
        // Four case-insensitive "needle"s, two of them lowercase.
        "/find": """
        <!doctype html><html><head><title>find</title></head><body style="font:24px -apple-system">
        <p>needle in a haystack</p><p>Needle</p><p>NEEDLE</p><p>another needle</p></body></html>
        """,
        // JavaScript dialogs, run from a timer so the evaluation that starts one returns first.
        "/dialogs": """
        <!doctype html><html><head><title>dialogs</title><script>
        function run(kind) {
          setTimeout(function () {
            var r;
            if (kind === 'alert') { alert('hello from ReArc'); r = 'done'; }
            else if (kind === 'confirm') { r = confirm('Proceed?'); }
            else { r = prompt('Name?', 'default name'); }
            document.title = kind + ':' + r;
          }, 0);
          return true;
        }
        </script></head><body style="margin:0;font:28px -apple-system">
        <a id="link" href="/a" style="display:block;padding:40px">context menu link</a>
        <p id="plain" style="padding:40px;height:300px">plain page text</p></body></html>
        """,
        "/leave": """
        <!doctype html><html><head><title>leave</title><script>
        window.addEventListener('beforeunload', function (e) { e.preventDefault(); e.returnValue = ''; return ''; });
        </script></head><body style="margin:0;height:100vh;font:28px -apple-system"><p style="padding:40px">unsaved changes</p></body></html>
        """,
        // A file input covering the page, so any click opens the chooser.
        "/upload": """
        <!doctype html><html><head><title>upload</title></head><body style="margin:0">
        <input id="f" type="file" multiple accept=".txt,text/plain"
          style="position:fixed;left:0;top:0;width:100%;height:100%;opacity:0.01">
        <script>
        var f = document.getElementById('f');
        f.addEventListener('change', function () {
          var names = Array.prototype.map.call(f.files, function (x) { return x.name; }).sort();
          document.title = f.webkitdirectory ? 'folder:' + names.length : 'files:' + names.join(',');
        });
        f.addEventListener('cancel', function () { document.title = 'files:cancel'; });
        function folder() { f.multiple = false; f.webkitdirectory = true; return true; }
        </script></body></html>
        """,
        "/permissions": """
        <!doctype html><html><head><title>permissions</title><script>
        function notify() {
          Notification.requestPermission().then(function (r) { document.title = 'notify:' + r; });
          return true;
        }
        function geo() {
          navigator.geolocation.getCurrentPosition(
            function () { document.title = 'geo:ok'; },
            function (e) { document.title = 'geo:' + e.code; });
          return true;
        }
        </script></head><body style="font:28px -apple-system">permissions</body></html>
        """,
        "/login": """
        <!doctype html><html><head><title>login</title></head><body style="margin:0;font:24px -apple-system">
        <form action="/login-done" method="get" style="padding:40px">
        <input id="user" name="user" autocomplete="username" style="font-size:24px;width:400px"><br><br>
        <input id="pass" name="pass" type="password" autocomplete="current-password" style="font-size:24px;width:400px"><br><br>
        <button id="go" type="submit" style="font-size:24px">Sign in</button></form></body></html>
        """,
        "/login-done": """
        <!doctype html><html><head><title>signed-in</title></head><body>signed in</body></html>
        """,
        // Held back (see `respond`) so a load is still in flight when the test stops it.
        "/slow": """
        <!doctype html><html><head><title>slow-loaded</title></head><body>slow</body></html>
        """,
    ]

    /// 16x16 PNG served at /favicon.png (same bytes as engine/tests/run_c_abi.py's fixture).
    static let faviconPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGMQVDImCTGMahjVMHw1AAAaNGYB4V8qqwAAAABJRU5ErkJggg=="
    )!
    static let slowResponseDelay: TimeInterval = 6
    static let smallDownloadSize = 64 * 1024
    /// 1 MiB, 16 KiB every 100 ms: long enough to pause, resume and cancel mid-transfer.
    static let trickleDownloadSize = 1024 * 1024
    static let trickleChunk = 16 * 1024

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
        if path.hasPrefix("/download/") {
            return download(connection, name: String(path.dropFirst("/download/".count)))
        }
        let isIcon = path.hasPrefix("/favicon")
        // Form submissions carry a query; pages are keyed by path.
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let body = isIcon ? nil : pages[route]
        let found = isIcon || body != nil
        print("[fixture] GET \(path) -> \(found ? 200 : 404)")
        fflush(stdout)
        let payload = isIcon ? faviconPNG : Data((body ?? "not found").utf8)
        let type = isIcon ? "image/png" : "text/html; charset=utf-8"
        let head = "HTTP/1.1 \(found ? "200 OK" : "404 Not Found")\r\n"
            + "Content-Type: \(type)\r\nContent-Length: \(payload.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        let send = {
            connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        if path == "/slow" {
            DispatchQueue.global().asyncAfter(deadline: .now() + slowResponseDelay, execute: send)
        } else {
            send()
        }
    }

    /// Attachments: `rearc-small.bin` in one write, `rearc-trickle.bin` in timed chunks.
    private static func download(_ connection: NWConnection, name: String) {
        let trickle = name.contains("trickle")
        let size = trickle ? trickleDownloadSize : smallDownloadSize
        print("[fixture] GET /download/\(name) -> 200 (\(size) bytes\(trickle ? ", trickled" : ""))")
        fflush(stdout)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\n"
            + "Content-Disposition: attachment; filename=\"\(name)\"\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        guard trickle else {
            connection.send(content: Data(head.utf8) + Data(repeating: 0x52, count: size), completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        func sendChunk(_ offset: Int) {
            guard offset < size else { return connection.cancel() }
            let count = min(trickleChunk, size - offset)
            connection.send(content: Data(repeating: 0x54, count: count), completion: .contentProcessed { error in
                // A cancelled download closes the socket; stop sending then.
                guard error == nil else { return connection.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { sendChunk(offset + count) }
            })
        }
        sendChunk(0)
    }
}
#endif
