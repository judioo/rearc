import Foundation
import Testing
@testable import ArcBenchCore

struct StatsTests {
    @Test func nearestRankMatchesBenchFinalize() {
        // bench_finalize.py: k = ceil(p * n) - 1 on the sorted values.
        let summary = Summary((1 ... 20).map(Double.init).reversed())
        #expect(summary.n == 20)
        #expect(summary.p50 == 10)
        #expect(summary.p95 == 19)
        #expect(summary.max == 20)
    }

    @Test func smallSamples() {
        #expect(Summary([]) == Summary([]))
        #expect(Summary([]).p50 == nil)
        #expect(Summary([]).max == nil)
        let one = Summary([7.5])
        #expect(one.p50 == 7.5 && one.p95 == 7.5 && one.max == 7.5 && one.n == 1)
        let three = Summary([3, 1, 2])
        #expect(three.p50 == 2)
        #expect(three.p95 == 3)
    }
}

struct ReportTests {
    func sample() -> RunReport {
        var report = RunReport(runID: "arc-vs-rearc-test", startedAt: "2026-11-07T01:00:00Z", revision: "abc1234", settings: ["iterations": "3"])
        report.apps = [
            AppRun(app: .arc, bundleID: "company.thebrowser.Browser", bundlePath: "/Applications/Arc.app", version: "1.170.0",
                   window: [1440, 900], refreshHz: 120, notes: ["space \"Demo\""]),
            AppRun(app: .rearc, bundleID: "com.rearc.browser", bundlePath: "/x/ReArc.app", version: "0.1", window: [1440, 900], refreshHz: 120),
        ]
        report.metrics = [
            MetricResult(scenario: "sidebar_toggle", app: .arc, metric: "ui.sidebar_toggle.ack.hide", method: .pixels,
                         frameIntervalMs: 8.33, samples: [20, 30, 25], timeouts: 0),
            MetricResult(scenario: "sidebar_toggle", app: .rearc, metric: "ui.sidebar_toggle.ack.hide", method: .pixels,
                         frameIntervalMs: 8.33, samples: [18, 22, 19], timeouts: 1),
            MetricResult(scenario: "little_arc", app: .rearc, metric: "ui.little_arc_open.window.shortcut", method: .windowList,
                         frameIntervalMs: 0.6, samples: [], timeouts: 3),
        ]
        return report
    }

    @Test func jsonHasTheRequiredFields() throws {
        let data = try sample().json()
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["schema"] as? String == "rearc.arc-vs-rearc/1")
        #expect(root["run_id"] as? String == "arc-vs-rearc-test")
        let metrics = try #require(root["metrics"] as? [[String: Any]])
        let first = metrics[0]
        for key in ["scenario", "app", "metric", "p50", "p95", "max", "n", "frame_interval_ms", "timeouts", "samples", "method", "unit"] {
            #expect(first[key] != nil, "missing \(key)")
        }
        #expect(first["app"] as? String == "arc")
        #expect(first["p50"] as? Double == 25)
        #expect(first["p95"] as? Double == 30)
        #expect(first["n"] as? Int == 3)
        #expect(metrics[2]["method"] as? String == "window-list")
        let apps = try #require(root["apps"] as? [[String: Any]])
        #expect(apps[0]["refresh_hz"] as? Int == 120)
        #expect(apps[0]["bundle_id"] as? String == "company.thebrowser.Browser")
    }

    @Test func jsonRoundTrips() throws {
        let report = sample()
        #expect(try JSONDecoder().decode(RunReport.self, from: report.json()) == report)
    }

    @Test func markdownTablePairsTheApps() {
        let markdown = sample().markdown()
        #expect(markdown.contains("| Metric | Arc | ReArc | ReArc − Arc p50 | ± (Arc / ReArc) |"))
        #expect(markdown.contains("| `ui.sidebar_toggle.ack.hide` | 25.0 / 30.0 / 30.0 (3) | 19.0 / 22.0 / 22.0 (3, 1 t/o) | -6.0 | 8.3 / 8.3 |"))
        #expect(markdown.contains("| `ui.little_arc_open.window.shortcut` ¹ | – | no samples (3 timeouts) | – | – / 0.6 |"))
        #expect(markdown.contains("¹ Timed from the window server's window list"))
        #expect(markdown.contains("- **Arc** 1.170.0, window 1440 × 900 pt, 120 Hz (± 8.3 ms per frame)"))
        #expect(markdown.contains("  - space \"Demo\""))
    }

    @Test func markdownRowsFollowFirstSeenOrder() {
        var report = sample()
        report.metrics.insert(MetricResult(scenario: "new_tab", app: .rearc, metric: "ui.new_tab.ack", method: .pixels,
                                           frameIntervalMs: 8.33, samples: [40], timeouts: 0), at: 0)
        let markdown = report.markdown()
        let newTab = markdown.range(of: "ui.new_tab.ack")!.lowerBound
        let sidebar = markdown.range(of: "ui.sidebar_toggle.ack.hide")!.lowerBound
        #expect(newTab < sidebar)
        #expect(markdown.components(separatedBy: "`ui.sidebar_toggle.ack.hide`").count == 2)
    }
}
