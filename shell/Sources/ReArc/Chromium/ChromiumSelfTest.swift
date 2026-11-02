#if REARC_CHROMIUM
import AppKit
import Foundation
import Network
import ReArcEngine
import SidebarModel
import SwiftUI

/// `--rearc-selftest`: drives one ChromiumEngine through the real shell code
/// paths (engine, SwiftUI host view, boost mapping, shutdown) and exits 0 only
/// if every step passed and the engine shut down cleanly.
final class ChromiumSelfTest {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let watchdogSeconds = 60.0
    static let titleA = "ReArc Selftest A"
    static let titleData = "ReArc Selftest Data"

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

    private func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    @MainActor
    private func wait(_ label: String, timeout: TimeInterval = 15, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                let state = engine.map {
                    "tab \($0.tabID) url \($0.currentURL?.absoluteString ?? "nil") title \($0.pageTitle ?? "nil") "
                        + "loading \($0.isLoading) progress \($0.loadProgress) error \($0.lastError ?? "none")"
                } ?? "no engine"
                throw Failure(description: "timed out waiting for \(label) [\(state)]")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private func run() async throws {
        log("engine ABI \(ReArcEngineABIVersion()), bridge \(String(cString: ReArcEngineBridgeVersion())), Chromium \(String(cString: ReArcEngineVersion())), default profile \(runtime.defaultProfileID)")
        let features = ["native_view", "navigation", "media_session", "favicon", "security_state", "user_scripts",
                        "link_peek", "snapshot_viewport", "snapshot_full_page", "pip_control", "pip_native"]
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

        // 2. data: URL with a known title. The ABI admits only http(s)/about:blank.
        let dataURL = URL(string: "data:text/html,<title>\(Self.titleData)</title>".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!
        let dataStatus = engine.navigateNow(dataURL)
        if dataStatus == .rearcOK {
            try await wait("data: URL title") { engine.pageTitle == Self.titleData }
            log("PASS data: URL title event '\(engine.pageTitle ?? "")'")
        } else {
            log("ABI-GAP data: URL navigation rejected synchronously: \(dataStatus.rearcName) (ReArcTabNavigate admits http/https/about:blank only); using a loopback http fixture instead")
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
            log("NOTE never-attached (hidden) tab did not finish loading within 8 s (first-load latency is intermittently long); continuing after attach")
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
            try await wait("title event '\(Self.titleA)' after attach") { engine.pageTitle == Self.titleA }
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
            packageID: UUID(uuidString: "5E1F7E57-B005-4000-8000-000000000001")!,
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
        try await wait("forward to /boost") { engine.currentURL?.path == "/boost" && engine.pageTitle?.hasPrefix("boost-ok") == true }
        log("PASS forward: \(engine.currentURL?.absoluteString ?? "") '\(engine.pageTitle ?? "")'")

        // 7. Media surface: mute is independent of sessions; PiP reports unsupported.
        engine.setMuted(true)
        try await wait("muted media event", timeout: 5) { engine.isMuted }
        let pip = engine.requestPictureInPicture()
        try check(pip == ReArcStatus(REARC_UNSUPPORTED), "PiP returned \(pip.rearcName)")
        log("PASS mute observed via media event; PiP -> \(pip.rearcName) (not advertised)")
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
        <body style="margin:0;background:#2a6;font:32px -apple-system"><h1>ReArc selftest page A</h1></body></html>
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
