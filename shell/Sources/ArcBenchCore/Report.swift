import Foundation

public enum AppKind: String, Codable, CaseIterable, Sendable {
    case arc
    case rearc

    public var title: String { self == .arc ? "Arc" : "ReArc" }
    public var bundleID: String { self == .arc ? "company.thebrowser.Browser" : "com.rearc.browser" }
}

/// How a metric was timed.
public enum TimingMethod: String, Codable, Sendable {
    /// Presentation times of the target window's captured frames.
    case pixels
    /// Polling the window server's window list (a window appearing or going).
    case windowList = "window-list"
}

/// One metric for one app: raw samples (ms) and their summary.
public struct MetricResult: Equatable, Codable, Sendable {
    public var scenario: String
    public var app: AppKind
    public var metric: String
    public var unit = "ms"
    public var method: TimingMethod
    public var n: Int
    public var p50: Double?
    public var p95: Double?
    public var max: Double?
    /// The timing resolution: one display frame for pixel metrics, the mean
    /// poll period for window-list ones. Every figure is ± this.
    public var frameIntervalMs: Double
    public var timeouts: Int
    public var samples: [Double]

    public init(scenario: String, app: AppKind, metric: String, method: TimingMethod, frameIntervalMs: Double,
                samples: [Double], timeouts: Int) {
        let summary = Summary(samples)
        self.scenario = scenario
        self.app = app
        self.metric = metric
        self.method = method
        self.n = summary.n
        self.p50 = summary.p50
        self.p95 = summary.p95
        self.max = summary.max
        self.frameIntervalMs = frameIntervalMs
        self.timeouts = timeouts
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case scenario, app, metric, unit, method, n, p50, p95, max, timeouts, samples
        case frameIntervalMs = "frame_interval_ms"
    }
}

/// One app's run conditions.
public struct AppRun: Equatable, Codable, Sendable {
    public var app: AppKind
    public var bundleID: String
    public var bundlePath: String
    public var version: String?
    /// Window size in points.
    public var window: [Int]
    public var refreshHz: Int
    public var notes: [String]

    public init(app: AppKind, bundleID: String, bundlePath: String, version: String?, window: [Int], refreshHz: Int, notes: [String] = []) {
        self.app = app
        self.bundleID = bundleID
        self.bundlePath = bundlePath
        self.version = version
        self.window = window
        self.refreshHz = refreshHz
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case app, version, window, notes
        case bundleID = "bundle_id"
        case bundlePath = "bundle_path"
        case refreshHz = "refresh_hz"
    }
}

/// Everything one harness run writes (schema `rearc.arc-vs-rearc/1`).
public struct RunReport: Equatable, Codable, Sendable {
    public var schema = "rearc.arc-vs-rearc/1"
    public var runID: String
    public var startedAt: String
    public var finishedAt: String?
    public var revision: String?
    public var settings: [String: String]
    public var apps: [AppRun] = []
    public var metrics: [MetricResult] = []
    public var notes: [String] = []

    public init(runID: String, startedAt: String, revision: String?, settings: [String: String]) {
        self.runID = runID
        self.startedAt = startedAt
        self.revision = revision
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey {
        case schema, revision, settings, apps, metrics, notes
        case runID = "run_id"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Metric ids in first-seen order, so the table follows the scenario order.
    var metricOrder: [String] {
        var seen = Set<String>()
        return metrics.map(\.metric).filter { seen.insert($0).inserted }
    }

    /// The side-by-side table: p50 / p95 / max (n) per app, and ReArc's p50 minus Arc's.
    public func markdown() -> String {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "–" }
        func cell(_ result: MetricResult?) -> String {
            guard let result else { return "–" }
            if result.n == 0 { return "no samples (\(result.timeouts) timeouts)" }
            return "\(ms(result.p50)) / \(ms(result.p95)) / \(ms(result.max)) (\(result.n)\(result.timeouts > 0 ? ", \(result.timeouts) t/o" : ""))"
        }
        var lines = ["# Arc vs ReArc: \(runID)", ""]
        for run in apps {
            lines.append("- **\(run.app.title)** \(run.version ?? "?"), window \(run.window.map(String.init).joined(separator: " × ")) pt, "
                + "\(run.refreshHz) Hz (± \(ms(run.refreshHz > 0 ? 1000 / Double(run.refreshHz) : nil)) ms per frame)")
            for note in run.notes { lines.append("  - \(note)") }
        }
        lines += ["", "Times in ms from the key-down post: p50 / p95 / max (n). Each is ± the resolution column.", "",
                  "| Metric | Arc | ReArc | ReArc − Arc p50 | ± (Arc / ReArc) |", "|---|---|---|---|---|"]
        for id in metricOrder {
            let arc = metrics.first { $0.metric == id && $0.app == .arc }
            let rearc = metrics.first { $0.metric == id && $0.app == .rearc }
            var delta = "–"
            if let a = arc?.p50, let r = rearc?.p50 { delta = String(format: "%+.1f", r - a) }
            let resolution = "\(ms(arc?.frameIntervalMs)) / \(ms(rearc?.frameIntervalMs))"
            let method = (arc ?? rearc)?.method == .windowList ? " ¹" : ""
            lines.append("| `\(id)`\(method) | \(cell(arc)) | \(cell(rearc)) | \(delta) | \(resolution) |")
        }
        if metrics.contains(where: { $0.method == .windowList }) {
            lines += ["", "¹ Timed from the window server's window list (a window appearing or closing), not from pixels; ± the poll period."]
        }
        if !notes.isEmpty {
            lines += ["", "## Notes", ""] + notes.map { "- \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
