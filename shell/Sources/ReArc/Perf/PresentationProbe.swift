import AppKit
import QuartzCore
import SwiftUI

/// When a shell change reaches the screen (docs/PERFORMANCE-PLAN.md §1.1,
/// §2.1). A `ProbeMarker` next to a timed view sees its token change in the
/// same SwiftUI update that renders the change, and registers a one-shot
/// run-loop observer that runs after Core Animation commits that update's
/// transaction; the first display-link
/// callback after the commit gives the frame's `targetTimestamp`, the
/// "presented" time. Every window with a marker gets a display link while the
/// probe is enabled, which also records frame intervals for dropped-frame and
/// hitch accounting. Disabled (the normal app), markers render nothing.
///
/// All times are seconds on `CACurrentMediaTime`'s clock, the clock of
/// `NSEvent.timestamp` and of the engine's microsecond times.
@MainActor
final class PresentationProbe: NSObject {
    static let shared = PresentationProbe()

    /// Set by `--rearc-bench` before any window exists.
    private(set) var isEnabled = false

    struct Presented: Equatable {
        /// The marker's token in the presented frame.
        var token: String
        /// When the transaction carrying it committed.
        var committed: Double
        /// The display-link frame after the commit: its callback time and target (presentation) time.
        var callback: Double
        var target: Double
    }

    struct FrameStats: Equatable {
        var frames: Int
        var dropped: Int
        /// Σ (interval − nominal) over intervals longer than 1.5 × nominal, seconds.
        var hitchTime: Double
        var duration: Double
        var nominalInterval: Double
        var hitchRatioMsPerSecond: Double { duration > 0 ? hitchTime * 1000 / duration : 0 }
    }

    private struct Expectation {
        let marker: String
        let accepts: (String) -> Bool
        let resolve: (Presented?) -> Void
    }

    private var expectations: [UUID: Expectation] = [:]
    /// Commits waiting for the next display-link callback, by window.
    private var awaitingFrame: [(window: ObjectIdentifier?, token: String, marker: String, committed: Double)] = []
    private var links: [ObjectIdentifier: CADisplayLink] = [:]
    private var latestToken: [String: String] = [:]
    /// Display-link callbacks while recording, per window: (timestamp, target).
    private var recorded: [ObjectIdentifier: [(Double, Double)]] = [:]
    private var recording = false
    private var frameObservers: [UUID: (ObjectIdentifier, CADisplayLink) -> Void] = [:]

    /// After Core Animation's commit observer (kCATransactionOrder… = 2000000).
    static let afterCommitOrder: CFIndex = 2_000_100

    func enable() { isEnabled = true }

    /// The token a marker last rendered (setup checks, not timing).
    func token(of marker: String) -> String? { latestToken[marker] }

    /// Waits for one presented frame. Armed synchronously, so it cannot miss
    /// a change triggered right after `arm` returns.
    final class Waiter {
        fileprivate var result: Presented??
        fileprivate var continuation: CheckedContinuation<Presented?, Never>?

        fileprivate func resolve(_ value: Presented?) {
            guard result == nil else { return }
            result = .some(value)
            continuation?.resume(returning: value)
            continuation = nil
        }

        @MainActor
        func value() async -> Presented? {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
    }

    /// The first presented frame in which `marker`'s token satisfies
    /// `accepts`, or nil after `timeout` seconds. Arm before triggering the
    /// change.
    func arm(_ marker: String, timeout: TimeInterval = 10, accepts: @escaping (String) -> Bool) -> Waiter {
        let waiter = Waiter()
        let id = UUID()
        expectations[id] = Expectation(marker: marker, accepts: accepts, resolve: { [weak waiter] in waiter?.resolve($0) })
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let expectation = self.expectations.removeValue(forKey: id) else { return }
                expectation.resolve(nil)
            }
        }
        return waiter
    }

    /// The next display-link frame of `window` after the current transaction
    /// commits: for changes with no marker (a new window's first frame).
    func nextFrame(after window: NSWindow, timeout: TimeInterval = 10) async -> Presented? {
        attach(to: window)
        let marker = "window-\(ObjectIdentifier(window).hashValue)"
        let waiter = arm(marker, timeout: timeout) { _ in true }
        markerChanged(marker, token: "frame", window: window)
        return await waiter.value()
    }

    // MARK: Markers

    /// REARC_BENCH_TRACE=1: log marker changes and resolved frames.
    let traces = ProcessInfo.processInfo.environment["REARC_BENCH_TRACE"] == "1"

    func markerChanged(_ marker: String, token: String, window: NSWindow?) {
        latestToken[marker] = token
        guard isEnabled else { return }
        if traces { print("[probe] \(marker) -> \(token.prefix(60)) window \(window == nil ? "nil" : "ok") at \(CACurrentMediaTime())") }
        if let window { attach(to: window) }
        let key = window.map(ObjectIdentifier.init)
        // Core Animation commits the run loop's implicit transaction from its
        // own before-waiting observer (order 2000000); this one-shot observer
        // runs right after it, so the change is committed when it fires.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue,
                                                          false, Self.afterCommitOrder) { [weak self] _, _ in
            let committed = CACurrentMediaTime()
            MainActor.assumeIsolated {
                self?.awaitingFrame.append((key, token, marker, committed))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    // MARK: Display links and frame accounting

    func attach(to window: NSWindow) {
        guard isEnabled, let view = window.contentView else { return }
        let key = ObjectIdentifier(window)
        guard links[key] == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        links[key] = link
        windowsByLink[ObjectIdentifier(link)] = key
    }

    private var windowsByLink: [ObjectIdentifier: ObjectIdentifier] = [:]

    func detach(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        links.removeValue(forKey: key)?.invalidate()
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let window = windowsByLink[ObjectIdentifier(link)] else { return }
        if recording { recorded[window, default: []].append((link.timestamp, link.targetTimestamp)) }
        for observer in frameObservers.values { observer(window, link) }
        guard !awaitingFrame.isEmpty else { return }
        let ready = awaitingFrame.filter { $0.window == nil || $0.window == window }
        awaitingFrame.removeAll { $0.window == nil || $0.window == window }
        for commit in ready {
            if traces { print("[probe] frame \(commit.marker) \(commit.token.prefix(40)) target \(link.targetTimestamp)") }
            let presented = Presented(token: commit.token, committed: commit.committed, callback: link.timestamp, target: link.targetTimestamp)
            PerfSignposts.interactionEvent("Presented", "\(commit.marker) \(commit.token) target \(link.targetTimestamp)")
            for (id, expectation) in expectations where expectation.marker == commit.marker && expectation.accepts(commit.token) {
                expectations.removeValue(forKey: id)
                expectation.resolve(presented)
            }
        }
    }

    /// Calls `body` on every display-link frame of `window` until it returns
    /// false (scroll and resize drivers: one step per frame).
    func eachFrame(of window: NSWindow, _ body: @escaping (CADisplayLink) -> Bool) async {
        attach(to: window)
        let key = ObjectIdentifier(window)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id = UUID()
            frameObservers[id] = { [weak self] frameWindow, link in
                guard frameWindow == key else { return }
                if !body(link) {
                    self?.frameObservers.removeValue(forKey: id)
                    continuation.resume()
                }
            }
        }
    }

    func startRecording() {
        recorded = [:]
        recording = true
    }

    /// Frame statistics of `window` since `startRecording`, between `from` and
    /// `to` (callback timestamps).
    func stopRecording(window: NSWindow, from: Double? = nil, to: Double? = nil) -> FrameStats {
        recording = false
        let frames = (recorded[ObjectIdentifier(window)] ?? []).filter { frame in
            (from.map { frame.0 >= $0 } ?? true) && (to.map { frame.0 <= $0 } ?? true)
        }
        return Self.stats(timestamps: frames.map(\.0), nominal: 1 / Double(max(window.screen?.maximumFramesPerSecond ?? 60, 1)))
    }

    nonisolated static func stats(timestamps: [Double], nominal: Double) -> FrameStats {
        guard timestamps.count > 1 else {
            return FrameStats(frames: timestamps.count, dropped: 0, hitchTime: 0, duration: 0, nominalInterval: nominal)
        }
        var dropped = 0
        var hitch = 0.0
        for (previous, next) in zip(timestamps, timestamps.dropFirst()) {
            let interval = next - previous
            if interval > nominal * 1.5 {
                dropped += Int((interval / nominal).rounded()) - 1
                hitch += interval - nominal
            }
        }
        return FrameStats(frames: timestamps.count, dropped: dropped, hitchTime: hitch,
                          duration: timestamps.last! - timestamps.first!, nominalInterval: nominal)
    }
}

/// Reports its token to the probe whenever it renders a new one. Placed next
/// to the view whose change is timed; reads only what it reports.
struct ProbeMarker: NSViewRepresentable {
    let name: String
    let token: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.token != token else { return }
        context.coordinator.token = token
        MainActor.assumeIsolated {
            PresentationProbe.shared.markerChanged(name, token: token, window: nsView.window)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var token: String?
    }
}
