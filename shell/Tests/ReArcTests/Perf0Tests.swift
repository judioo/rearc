import XCTest
@testable import ReArc

/// perf-0: the bench's flags, its engine arguments and the probe's frame accounting.
final class Perf0Tests: XCTestCase {
    func testBenchFlagImpliesChromiumWithDefaults() {
        let options = EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-bench"], environment: [:])
        XCTAssertEqual(options.engine, .chromium)
        XCTAssertEqual(options.source, .bench)
        XCTAssertFalse(options.selfTest)
        let bench = try! XCTUnwrap(options.bench)
        XCTAssertEqual(bench.suites, [.ui, .page, .memory])
        XCTAssertEqual(bench.iterations, 40)
        XCTAssertEqual(bench.warmups, 3)
        XCTAssertEqual(bench.fixture, "items500")
        XCTAssertFalse(bench.allowLocked)
        XCTAssertTrue(bench.runs("ui.tab_switch.ack.cmd_n"))
    }

    func testBenchOptionsParse() {
        let options = EngineLaunchOptions.parse(arguments: [
            "ReArc", "--rearc-bench=ui,launch-child", "--rearc-bench-out=/tmp/x.json", "--rearc-bench-iterations=12",
            "--rearc-bench-warmups=1", "--rearc-bench-only=ui.tab_switch,ui.cmdbar_key", "--rearc-bench-fixture=items300",
            "--rearc-bench-seed=9", "--rearc-bench-allow-locked", "--rearc-bench-dump-pages=/tmp/pages",
        ], environment: [:])
        let bench = try! XCTUnwrap(options.bench)
        XCTAssertEqual(bench.suites, [.ui, .launchChild])
        XCTAssertEqual(bench.outputPath, "/tmp/x.json")
        XCTAssertEqual(bench.iterations, 12)
        XCTAssertEqual(bench.warmups, 1)
        XCTAssertEqual(bench.only, ["ui.tab_switch", "ui.cmdbar_key"])
        XCTAssertEqual(bench.fixture, "items300")
        XCTAssertEqual(bench.seed, 9)
        XCTAssertTrue(bench.allowLocked)
        XCTAssertEqual(bench.dumpPagesPath, "/tmp/pages")
        XCTAssertTrue(bench.runs("ui.cmdbar_key.echo"))
        XCTAssertFalse(bench.runs("ui.sidebar_toggle.ack.show"))
    }

    func testSelfTestWinsOverBenchAndNoFlagMeansNoBench() {
        XCTAssertNil(EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-selftest", "--rearc-bench"], environment: [:]).bench)
        XCTAssertNil(EngineLaunchOptions.parse(arguments: ["ReArc"], environment: [:]).bench)
        XCTAssertNil(EngineLaunchOptions.parse(arguments: ["ReArc", "--rearc-bench-out=/tmp/x"], environment: [:]).bench)
    }

    func testBenchArgumentsHaveNoAntiThrottlingSwitches() {
        let arguments = ChromiumLaunchArguments.benchArguments(["ReArc", "--user-data-dir=/tmp/b"])
        for switchName in ChromiumLaunchArguments.selfTestForegroundSwitches {
            XCTAssertFalse(arguments.contains(switchName), switchName)
        }
        XCTAssertFalse(arguments.contains(ChromiumLaunchArguments.selfTestAutoplaySwitch))
        XCTAssertFalse(arguments.contains(ChromiumLaunchArguments.selfTestAutofillFocusSwitch))
        // Loopback only: every other name fails to resolve.
        for switchName in ChromiumLaunchArguments.selfTestNoOutsideNetworkSwitches {
            XCTAssertEqual(arguments.filter { $0 == switchName }.count, 1, switchName)
        }
    }

    func testFrameStatsCountDroppedFramesAndHitchTime() {
        let nominal = 1.0 / 120
        // 10 steady frames, one 3-frame gap (2 dropped), then 5 steady.
        var times = (0 ..< 10).map { Double($0) * nominal }
        times.append(times.last! + 3 * nominal)
        for _ in 0 ..< 5 { times.append(times.last! + nominal) }
        let stats = PresentationProbe.stats(timestamps: times, nominal: nominal)
        XCTAssertEqual(stats.frames, 16)
        XCTAssertEqual(stats.dropped, 2)
        XCTAssertEqual(stats.hitchTime, 2 * nominal, accuracy: 1e-9)
        XCTAssertEqual(stats.duration, 17 * nominal, accuracy: 1e-9)
        XCTAssertEqual(stats.hitchRatioMsPerSecond, 2 * nominal * 1000 / (17 * nominal), accuracy: 1e-6)
    }

    func testFrameStatsIgnoreJitterBelowOneAndAHalfFrames() {
        let nominal = 1.0 / 120
        let times = [0, nominal * 1.4, nominal * 2.4, nominal * 3.4]
        let stats = PresentationProbe.stats(timestamps: times, nominal: nominal)
        XCTAssertEqual(stats.dropped, 0)
        XCTAssertEqual(stats.hitchTime, 0)
        XCTAssertEqual(PresentationProbe.stats(timestamps: [1], nominal: nominal).frames, 1)
    }

    func testPerfMetricsCapabilityNeedsABI44() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 43, hasFeature: all).perfMetrics)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 44, hasFeature: all).perfMetrics)
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 44, hasFeature: { $0 != "perf_metrics" }).perfMetrics)
        XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 44, hasFeature: all).summary.contains("perf_metrics=1"))
    }
}
