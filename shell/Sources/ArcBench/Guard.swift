import CoreGraphics
import Foundation

/// The input gate, the shared input lock and cleanup on every way out.
///
/// - Gate: `~/Library/Caches/rearc-input-allowed` exists only while the user
///   allows screen takeover. The harness refuses to start without it and
///   stops before the next key press once it is gone.
/// - Lock: `~/Library/Caches/rearc-input.lock`, the directory bench.sh and the
///   self-tests take, so only one of them posts input at a time. Removed on
///   exit, on errors and on SIGINT / SIGTERM / SIGHUP.
enum InputGuard {
    static let caches = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
    static let gate = caches.appendingPathComponent("rearc-input-allowed")
    static let lock = caches.appendingPathComponent("rearc-input.lock", isDirectory: true)

    static var gateOpen: Bool { FileManager.default.fileExists(atPath: gate.path) }
    static var lockHeld: Bool { FileManager.default.fileExists(atPath: lock.path) }

    private static var ownsLock = false

    /// Waits up to `seconds` for the lock; false when it stayed taken.
    static func acquire(waiting seconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        while mkdir(lock.path, 0o755) != 0 {
            guard errno == EEXIST, Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        ownsLock = true
        return true
    }

    static func release() {
        guard ownsLock else { return }
        ownsLock = false
        rmdir(lock.path)
    }
}

/// Closures run once on normal exit, `fail`, or a signal: stop capture, quit
/// the ReArc instance this run launched, release any held modifier, then the lock.
enum Cleanup {
    private static var actions: [() -> Void] = []
    private static var sources: [DispatchSourceSignal] = []
    private static var ran = false

    static func add(_ action: @escaping () -> Void) { actions.append(action) }

    static func run() {
        guard !ran else { return }
        ran = true
        for action in actions.reversed() { action() }
        Keyboard.releaseModifiers()
        InputGuard.release()
    }

    static func installSignalHandlers() {
        atexit { Cleanup.run() }
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                FileHandle.standardError.write("arc-vs-rearc: signal \(number), cleaning up\n".data(using: .utf8)!)
                Cleanup.run()
                exit(128 + number)
            }
            source.resume()
            sources.append(source)
        }
    }
}

struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Stops the whole run (the gate closed): partial results are still written.
struct GateClosed: Error, CustomStringConvertible {
    var description: String { "the input gate \(InputGuard.gate.path) was removed" }
}

enum Session {
    /// Input is not delivered to apps while the screen is locked.
    static var screenLocked: Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (info["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }
}
