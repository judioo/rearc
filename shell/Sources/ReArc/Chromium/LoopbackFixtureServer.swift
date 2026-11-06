#if REARC_CHROMIUM
import AppKit
import Foundation
import Network

/// Minimal loopback HTTP/1.1 server (127.0.0.1 only) for the self-test's
/// fixture pages and the bench's page set (`ChromiumBench`): the bench adds
/// its routes and a suggest delay through `configure`, and turns request
/// logging off.
final class LoopbackFixtureServer {
    /// Extra routes (path without query -> body and content type), the
    /// request log switch and the suggest endpoint's delay. Read on the
    /// fixture queue, so behind a lock.
    struct Settings {
        var routes: (String) -> (body: Data, type: String)? = { _ in nil }
        var logsRequests = true
        var suggestDelay: TimeInterval = 0
    }
    private static let settingsLock = NSLock()
    nonisolated(unsafe) private static var storedSettings = Settings()
    static var settings: Settings { settingsLock.withLock { storedSettings } }
    static func configure(_ change: (inout Settings) -> Void) { settingsLock.withLock { change(&storedSettings) } }
    private static func log(_ line: @autoclosure () -> String) {
        guard settings.logsRequests else { return }
        print(line())
        fflush(stdout)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "net.rearc.selftest.fixture")

    static let pages: [String: String] = [
        "/search": "<!doctype html><html><head><title>search results</title></head><body>search</body></html>",
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
        // A button that asks for element fullscreen (needs the click's user activation).
        "/fullscreen": """
        <!doctype html><html><head><title>fs-ready</title></head><body style="margin:0;font:24px -apple-system">
        <button id="go" style="position:absolute;left:0;top:0;width:400px;height:300px">fullscreen</button><script>
        document.getElementById('go').onclick = function () {
          document.documentElement.requestFullscreen().then(function () { document.title = 'fs-on'; },
                                                          function () { document.title = 'fs-denied'; });
        };
        document.addEventListener('fullscreenchange', function () {
          if (!document.fullscreenElement) document.title = 'fs-off';
        });
        </script></body></html>
        """,
        // Three printed pages; the title records beforeprint/afterprint around window.print().
        "/print": """
        <!doctype html><html><head><title>print-ready</title><style>div{height:900px;break-after:page}</style></head>
        <body style="font:24px -apple-system"><div>page one</div><div>page two</div><div>page three</div><script>
        addEventListener('beforeprint', function () { document.title = 'beforeprint'; });
        addEventListener('afterprint', function () { document.title += '+afterprint'; });
        </script></body></html>
        """,
        // A drop target covering the page that logs every dragenter and drop.
        "/drop": """
        <!doctype html><html><head><title>drop-ready</title></head><body style="margin:0;height:100vh"><script>
        window.log = [];
        ['dragenter', 'dragover'].forEach(function (t) {
          document.addEventListener(t, function (e) {
            e.preventDefault();
            if (t === 'dragenter') log.push('enter:' + Array.prototype.slice.call(e.dataTransfer.types).join(','));
          });
        });
        document.addEventListener('drop', function (e) {
          e.preventDefault();
          var d = e.dataTransfer, files = Array.prototype.slice.call(d.files);
          var entry = 'drop|text=' + d.getData('text/plain') + '|uri=' + d.getData('text/uri-list')
            + '|files=' + files.map(function (f) { return f.name + ':' + f.size; }).join(';');
          if (!files[0]) { log.push(entry + '|content='); return; }
          files[0].text().then(function (c) { log.push(entry + '|content=' + c.slice(0, 40)); });
        });
        </script></body></html>
        """,
        // A playing video with an audio track. A MediaRecorder WebM of a canvas and a
        // silent oscillator is a normal player (Chromium offers browser-initiated PiP
        // for it, never for a MediaStream). Autoplay is allowed by a self-test switch.
        "/pip": """
        <!doctype html><html><head><title>pip-loading</title></head><body style="margin:0">
        <video id="v" playsinline style="width:400px;height:300px"></video><script>
        var v = document.getElementById('v');
        var c = document.createElement('canvas'); c.width = 320; c.height = 180;
        var g = c.getContext('2d'), n = 0;
        setInterval(function () { g.fillStyle = 'hsl(' + (n++ * 10 % 360) + ',80%,50%)'; g.fillRect(0, 0, 320, 180); }, 50);
        var stream = c.captureStream(20), ac = new AudioContext(), osc = ac.createOscillator();
        var dest = ac.createMediaStreamDestination(), gain = ac.createGain();
        gain.gain.value = 0; osc.connect(gain); gain.connect(dest); osc.start();
        stream.addTrack(dest.stream.getAudioTracks()[0]);
        var parts = [], rec = new MediaRecorder(stream, { mimeType: 'video/webm;codecs=vp8,opus' });
        rec.ondataavailable = function (e) { parts.push(e.data); };
        rec.onstop = function () {
          v.loop = true;
          v.src = URL.createObjectURL(new Blob(parts, { type: 'video/webm' }));
          v.play().then(function () { document.title = 'pip-playing'; }, function (e) { document.title = 'pip-err:' + e.name; });
        };
        // Frames presented to the video's compositor (PiP surface included), for wave 32.
        window.rvfc = 0;
        if (v.requestVideoFrameCallback) {
          var counted = function () { window.rvfc++; v.requestVideoFrameCallback(counted); };
          v.requestVideoFrameCallback(counted);
        }
        v.addEventListener('enterpictureinpicture', function () { document.title = 'pip-in'; });
        v.addEventListener('leavepictureinpicture', function () { document.title = 'pip-out'; });
        rec.start(); setTimeout(function () { rec.stop(); }, 2500);
        </script></body></html>
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
        // Wave 30: records every keydown; ?block=1 calls preventDefault on each (a page that takes every shortcut).
        "/keys": """
        <!doctype html><html><head><title>keys</title><script>
        window.rearcKeys = [];
        document.addEventListener('keydown', function (e) {
          window.rearcKeys.push((e.metaKey ? 'M' : '') + (e.ctrlKey ? 'C' : '') + (e.altKey ? 'A' : '') + (e.shiftKey ? 'S' : '')
            + ':' + e.key.toLowerCase());
          if (location.search.indexOf('block=1') >= 0) e.preventDefault();
        }, true);
        </script></head><body style="margin:0;height:100vh;font:28px -apple-system"><p style="padding:40px">keys page</p></body></html>
        """,
        // Wave 26: a target=_blank link for ⌥⌘-click to Little Arc.
        "/links": """
        <!doctype html><html><head><title>links</title></head><body style="margin:0;font:28px -apple-system">
        <a id="blank" target="_blank" href="/a" style="display:block;padding:40px">new window link</a>
        <a id="plain" href="/a" style="display:block;padding:40px">ordinary link</a></body></html>
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
        // Wave 27: a datalist field (suggestions without saved data) and an address form.
        "/autofill": """
        <!doctype html><html><head><title>autofill</title></head><body style="margin:0;font:20px -apple-system">
        <div style="padding:30px"><input id="dl" list="opts" autocomplete="off" style="font-size:20px;width:320px">
        <datalist id="opts"><option value="rearc-option-one"><option value="rearc-option-two"></datalist></div>
        <form action="/autofill-done" method="get" style="padding:30px">
        <input id="name" name="name" autocomplete="name" style="font-size:20px;width:320px"><br>
        <input id="street" name="street" autocomplete="address-line1" style="font-size:20px;width:320px"><br>
        <input id="city" name="city" autocomplete="address-level2" style="font-size:20px;width:320px"><br>
        <input id="state" name="state" autocomplete="address-level1" style="font-size:20px;width:320px"><br>
        <input id="zip" name="zip" autocomplete="postal-code" style="font-size:20px;width:320px"><br>
        <button id="save" type="submit" style="font-size:20px">Save</button></form></body></html>
        """,
        "/autofill-done": """
        <!doctype html><html><head><title>autofill-done</title></head><body>saved</body></html>
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
            begin { continuation.resume(with: $0) }
        }
    }

    /// For a caller with no run loop to await on (the bench's early window,
    /// inside ReArcEngineRun). The listener reports on its own queue.
    func startBlocking(timeout: TimeInterval = 5) throws -> UInt16 {
        let done = DispatchSemaphore(value: 0)
        let result = LockedResult()
        begin { result.set($0); done.signal() }
        guard done.wait(timeout: .now() + timeout) == .success, let port = result.get() else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "loopback listener not ready in \(timeout) s"])
        }
        return try port.get()
    }

    private final class LockedResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<UInt16, Error>?
        func set(_ result: Result<UInt16, Error>) { lock.withLock { value = result } }
        func get() -> Result<UInt16, Error>? { lock.withLock { value } }
    }

    private func begin(_ completion: @escaping (Result<UInt16, Error>) -> Void) {
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready:
                listener.stateUpdateHandler = nil
                completion(.success(listener.port?.rawValue ?? 0))
            case .failed(let error):
                listener.stateUpdateHandler = nil
                completion(.failure(error))
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
            respond(connection, path: path, head: head)
        }
    }

    /// Wave 27 HTTP auth: Basic, realm "rearc-selftest", user rearc / local-secret.
    static let authCredentials = (username: "rearc", password: "local-secret")
    static let authRealm = "rearc-selftest"

    private static func authenticate(_ connection: NWConnection, path: String, head: String) {
        let expected = "Basic " + Data("\(authCredentials.username):\(authCredentials.password)".utf8).base64EncodedString()
        let sent = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("authorization:") }
            .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }
        let ok = sent == expected
        print("[fixture] GET \(path) -> \(ok ? 200 : 401) (basic auth\(sent == nil ? "" : ", credentials sent"))")
        fflush(stdout)
        let body = Data((ok ? "<!doctype html><title>auth-ok</title>signed in" : "<!doctype html><title>auth-denied</title>denied").utf8)
        let head = "HTTP/1.1 \(ok ? "200 OK" : "401 Unauthorized")\r\n"
            + (ok ? "" : "WWW-Authenticate: Basic realm=\"\(authRealm)\"\r\n")
            + "Content-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func respond(_ connection: NWConnection, path: String, head: String) {
        if path.hasPrefix("/auth/") {
            return authenticate(connection, path: path, head: head)
        }
        if path.hasPrefix("/download/") {
            return download(connection, name: String(path.dropFirst("/download/".count)))
        }
        let isIcon = path.hasPrefix("/favicon")
        // Form submissions carry a query; pages are keyed by path.
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if route == "/suggest" {
            return suggest(connection, path: path)
        }
        let extra = settings.routes(route)
        let body = isIcon || extra != nil ? nil : pages[route]
        let found = isIcon || body != nil || extra != nil
        log("[fixture] GET \(path) -> \(found ? 200 : 404)")
        let payload = extra?.body ?? (isIcon ? faviconPNG : Data((body ?? "not found").utf8))
        let type = extra?.type ?? (isIcon ? "image/png" : "text/html; charset=utf-8")
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

    /// OpenSearch suggestions for the self-test's loopback search provider.
    private static func suggest(_ connection: NWConnection, path: String) {
        // Form encoding: '+' is a space. Chromium drops a response whose echoed query differs.
        let raw = URLComponents(string: path)?.percentEncodedQueryItems?.first { $0.name == "q" }?.value ?? ""
        let terms = raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        suggestLock.withLock { recordedSuggestQueries.append(terms) }
        let body = (try? JSONSerialization.data(withJSONObject: [terms, ["\(terms) suggestion one", "\(terms) suggestion two"]])) ?? Data()
        log("[fixture] GET \(path) -> 200 (suggest)")
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        let send = { connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() }) }
        let delay = settings.suggestDelay
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: send) } else { send() }
    }

    /// Terms the suggest endpoint was asked for (written on the fixture queue).
    private static let suggestLock = NSLock()
    private static var recordedSuggestQueries: [String] = []
    static var suggestQueries: [String] { suggestLock.withLock { recordedSuggestQueries } }

    /// Attachments: `rearc-small.bin` in one write, `rearc-trickle.bin` in timed chunks.
    private static func download(_ connection: NWConnection, name: String) {
        let trickle = name.contains("trickle")
        // Inert bytes that the self-test's manual hash blocklist marks dangerous.
        let danger = name.contains("danger")
        let size = trickle ? trickleDownloadSize : danger ? ChromiumLaunchArguments.selfTestDangerousDownloadSize : smallDownloadSize
        print("[fixture] GET /download/\(name) -> 200 (\(size) bytes\(trickle ? ", trickled" : ""))")
        fflush(stdout)
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\n"
            + "Content-Disposition: attachment; filename=\"\(name)\"\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        guard trickle else {
            connection.send(content: Data(head.utf8) + Data(repeating: danger ? 0x61 : 0x52, count: size), completion: .contentProcessed { _ in
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
