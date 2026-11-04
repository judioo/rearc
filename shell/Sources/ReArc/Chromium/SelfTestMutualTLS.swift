#if REARC_CHROMIUM
import Foundation

/// Self-test only: a loopback HTTPS server that requires a client
/// certificate (engine/tests' mutual-TLS fixture), for the ABI 1.41 step.
/// It runs only with the mock keychain and a debug engine, where Chromium's
/// test-only memory certificate store reads net/data's client_1 and
/// client_2 (`--rearc-test-client-cert-dir`); the real Keychain is never
/// listed. The server's own certificate is made per run and accepted only by
/// its SPKI exception. The bundle script passes the certificate directory in
/// `REARC_SELFTEST_CLIENT_CERT_DIR`.
final class SelfTestMutualTLS {
    static private(set) var shared: SelfTestMutualTLS?

    let port: Int
    let spki: String
    let certificateDirectory: String
    private let process: Process
    private let input: Pipe

    private init(port: Int, spki: String, certificateDirectory: String, process: Process, input: Pipe) {
        self.port = port
        self.spki = spki
        self.certificateDirectory = certificateDirectory
        self.process = process
        self.input = input
    }

    /// The engine switches the fixture needs.
    var switches: [String] {
        ["--ignore-certificate-errors-spki-list=" + spki, "--rearc-test-client-cert-dir=" + certificateDirectory]
    }

    func url(_ path: String) -> URL { URL(string: "https://127.0.0.1:\(port)\(path)")! }

    /// Starts the server, or nil (and why) when this run cannot have one.
    static func start(environment: [String: String] = ProcessInfo.processInfo.environment) -> (SelfTestMutualTLS?, String) {
        guard let directory = environment["REARC_SELFTEST_CLIENT_CERT_DIR"], !directory.isEmpty else {
            return (nil, "REARC_SELFTEST_CLIENT_CERT_DIR not set")
        }
        let root = URL(fileURLWithPath: directory).appendingPathComponent("client_root_ca.pem")
        guard FileManager.default.fileExists(atPath: root.path) else { return (nil, "no client_root_ca.pem in \(directory)") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-mtls-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let script = work.appendingPathComponent("mtls.py")
        try? Data(source.utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", script.path, work.path, root.path]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (nil, "python3 did not start: \(error)") }
        // The first line is `<port> <spki>`; give openssl and the bind ten seconds.
        let deadline = Date().addingTimeInterval(10)
        var buffer = Data()
        while Date() < deadline, !buffer.contains(10) {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        let parts = String(decoding: buffer, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let port = Int(parts[0]) else {
            process.terminate()
            return (nil, "the fixture did not report a port")
        }
        let fixture = SelfTestMutualTLS(port: port, spki: String(parts[1]), certificateDirectory: directory, process: process, input: input)
        shared = fixture
        return (fixture, "https://127.0.0.1:\(port)")
    }

    deinit { process.terminate() }

    /// Python: TLS 1.2+, client certificate required (chaining to net/data's
    /// client root), echoes the presented leaf's CN in the title. It exits
    /// when its stdin closes (the self-test's process ends).
    private static let source = #"""
import base64, hashlib, ssl, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
work, root = sys.argv[1], sys.argv[2]
key, cert = work + "/mtls-key.pem", work + "/mtls-cert.pem"
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                "-days", "2", "-subj", "/CN=127.0.0.1"], check=True, capture_output=True)
public = subprocess.run(["openssl", "x509", "-in", cert, "-pubkey", "-noout"], check=True, capture_output=True).stdout
der = subprocess.run(["openssl", "pkey", "-pubin", "-outform", "DER"], input=public, check=True, capture_output=True).stdout
spki = base64.b64encode(hashlib.sha256(der).digest()).decode()

class Handler(BaseHTTPRequestHandler):
    def handle(self):
        self.request.settimeout(60)
        try:
            self.request.do_handshake()
        except (ssl.SSLError, OSError):
            return
        super().handle()

    def do_GET(self):
        subject = dict(item[0] for item in self.request.getpeercert()["subject"])
        body = ("<!doctype html><title>mtls:%s:%s</title><p>%s" % (subject["commonName"], self.path, subject["commonName"])).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass

context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
context.verify_mode = ssl.CERT_REQUIRED
context.load_verify_locations(root)
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
threading.Thread(target=server.serve_forever, daemon=True).start()
print(server.server_address[1], spki, flush=True)
sys.stdin.read()
"""#
}
#endif
