import Foundation

/// Which web engine the process should host. WebKit is the default; Chromium
/// is honored only by a binary built with `REARC_CHROMIUM` running from a
/// bundle that embeds `Chromium Framework.framework` (see `ReArcMain`).
///
/// Precedence, lowest first: the bundle's `ReArcDefaultEngine` Info.plist key
/// (the Chromium bundle sets it, so Finder, Dock, `open` and links from other
/// apps start Chromium without arguments), then `REARC_ENGINE`, then the
/// `--rearc-engine=` flag.
struct EngineLaunchOptions: Equatable {
    enum Engine: String, Equatable {
        case webkit
        case chromium
    }

    /// Where the engine choice came from (logged; the launch probe reports it).
    enum Source: String, Equatable {
        case builtInDefault = "default"
        case infoPlist
        case environment
        case argument
        case selfTest
        case bench
        /// The bundle's principal class is Chromium's, which aborts on the WebKit path.
        case applicationClass
    }

    static let engineFlagPrefix = "--rearc-engine="
    static let selfTestFlag = "--rearc-selftest"
    /// `--rearc-launch-probe=PATH`: start like a normal launch, write what
    /// happened to PATH at `ready`, then quit. Not an engine choice.
    static let launchProbeFlagPrefix = "--rearc-launch-probe="
    /// `--rearc-bench[=ui,page,memory,launch-child]`: the perf-0 benchmark
    /// (ChromiumBench). Implies the Chromium engine; never with `--rearc-selftest`.
    static let benchFlag = "--rearc-bench"
    static let environmentKey = "REARC_ENGINE"
    static let infoPlistKey = "ReArcDefaultEngine"
    static let principalClassKey = "NSPrincipalClass"
    /// Chromium's NSApplication subclass; its +initialize needs base::CommandLine.
    static let chromiumApplicationClass = "BrowserCrApplication"

    var engine: Engine
    /// Chromium runtime proof mode; implies the Chromium engine.
    var selfTest: Bool
    var source: Source = .builtInDefault
    var launchProbePath: String?
    var bench: BenchOptions?

    /// `--rearc-bench` and its `--rearc-bench-*` options (docs/PERFORMANCE-PLAN.md §2.2).
    struct BenchOptions: Equatable {
        enum Suite: String, CaseIterable { case ui, page, memory, downloads, launchChild = "launch-child" }
        var suites: [Suite] = [.ui, .page, .memory]
        var outputPath: String?
        var iterations = 40
        var warmups = 3
        /// Metric ID prefixes to run (empty: all).
        var only: [String] = []
        var fixture = "items500"
        var seed: UInt64 = 1
        /// Run with the screen locked (results are marked; the gate never compares them with unlocked runs).
        var allowLocked = false
        /// Launch child: the process start time the parent measured, for `launch.*` (mach seconds).
        var launchStart: Double?
        /// Writes the loopback page set here (the Chrome reference serves the same bytes).
        var dumpPagesPath: String?
        /// An iteration whose other processes used more of the machine's CPU than this is contaminated.
        var maxOtherCPU = 0.15
        /// The downloads suite's records: a `Downloads.json` (scripts/seed-downloads.py); none is the empty baseline.
        var downloadsPath: String?

        static func parse(_ arguments: [String]) -> BenchOptions? {
            var options: BenchOptions?
            for argument in arguments {
                if argument == EngineLaunchOptions.benchFlag {
                    options = options ?? BenchOptions()
                } else if argument.hasPrefix(EngineLaunchOptions.benchFlag + "=") {
                    var parsed = options ?? BenchOptions()
                    let names = argument.dropFirst(EngineLaunchOptions.benchFlag.count + 1).split(separator: ",")
                    parsed.suites = names.compactMap { Suite(rawValue: String($0)) }
                    options = parsed
                }
            }
            guard var result = options else { return nil }
            for argument in arguments {
                func value(_ name: String) -> String? {
                    let prefix = "\(EngineLaunchOptions.benchFlag)-\(name)="
                    return argument.hasPrefix(prefix) ? String(argument.dropFirst(prefix.count)) : nil
                }
                if let path = value("out"), !path.isEmpty { result.outputPath = path }
                if let n = value("iterations").flatMap(Int.init), n > 0 { result.iterations = n }
                if let n = value("warmups").flatMap(Int.init), n >= 0 { result.warmups = n }
                if let ids = value("only") { result.only = ids.split(separator: ",").map(String.init) }
                if let name = value("fixture"), !name.isEmpty { result.fixture = name }
                if let seed = value("seed").flatMap(UInt64.init) { result.seed = seed }
                if let start = value("launch-start").flatMap(Double.init) { result.launchStart = start }
                if let path = value("dump-pages"), !path.isEmpty { result.dumpPagesPath = path }
                if let share = value("max-other-cpu").flatMap(Double.init), share > 0 { result.maxOtherCPU = share }
                if let path = value("downloads"), !path.isEmpty { result.downloadsPath = path }
                if argument == EngineLaunchOptions.benchFlag + "-allow-locked" { result.allowLocked = true }
            }
            return result
        }

        func runs(_ metric: String) -> Bool {
            only.isEmpty || only.contains { metric.hasPrefix($0) }
        }

        /// A scenario runs when a selected prefix names it or one of its metrics.
        func runsScenario(_ name: String) -> Bool {
            only.isEmpty || only.contains { name.hasPrefix($0) || $0.hasPrefix(name) }
        }
    }

    /// The command-line flag wins over `REARC_ENGINE`, which wins over the
    /// bundle default; unknown values mean WebKit.
    static func parse(
        arguments: [String],
        environment: [String: String],
        infoDictionary: [String: Any]? = nil
    ) -> EngineLaunchOptions {
        var engine = Engine.webkit
        var source = Source.builtInDefault
        if let value = infoDictionary?[infoPlistKey] as? String {
            engine = Engine(rawValue: value.lowercased()) ?? .webkit
            source = .infoPlist
        }
        if let value = environment[environmentKey] {
            engine = Engine(rawValue: value.lowercased()) ?? .webkit
            source = .environment
        }
        var selfTest = false
        var probe: String?
        for argument in arguments.dropFirst() {
            if argument.hasPrefix(engineFlagPrefix) {
                let value = argument.dropFirst(engineFlagPrefix.count).lowercased()
                engine = Engine(rawValue: value) ?? .webkit
                source = .argument
            } else if argument == selfTestFlag {
                selfTest = true
            } else if argument.hasPrefix(launchProbeFlagPrefix) {
                probe = String(argument.dropFirst(launchProbeFlagPrefix.count))
            }
        }
        let bench = selfTest ? nil : BenchOptions.parse(Array(arguments.dropFirst()))
        if selfTest {
            engine = .chromium
            source = .selfTest
        } else if bench != nil {
            engine = .chromium
            source = .bench
        }
        return EngineLaunchOptions(engine: engine, selfTest: selfTest, source: source,
                                   launchProbePath: probe.flatMap { $0.isEmpty ? nil : $0 }, bench: bench)
    }

    /// True when NSApplicationMain would instantiate Chromium's application
    /// class: the WebKit (SwiftUI) path must never run then, because
    /// +[BrowserCrApplication initialize] DCHECKs base::CommandLine, which
    /// only ChromeMain sets up.
    static func applicationClassRequiresChromium(infoDictionary: [String: Any]?, classExists: (String) -> Bool) -> Bool {
        guard let name = infoDictionary?[principalClassKey] as? String, name == chromiumApplicationClass else { return false }
        return classExists(name)
    }

    /// The WebKit path cannot run in a bundle whose application class is
    /// Chromium's; such a launch uses Chromium instead of aborting.
    func resolvingApplicationClass(requiresChromium: Bool) -> EngineLaunchOptions {
        guard requiresChromium, engine == .webkit else { return self }
        var options = self
        options.engine = .chromium
        options.source = .applicationClass
        return options
    }
}

/// What an engine instance backs. The Chromium adapter passes this as the
/// tab's nonzero shell space label.
enum EngineRole: UInt64 {
    case tab = 1
    case peek = 2
    case littleArc = 3
    case privateWindow = 4
}

/// Engines that report main-frame commits/finishes back to the sidebar model.
protocol NavigationCommitReporting: AnyObject {
    var onNavigationCommit: ((URL?, String?) -> Void)? { get set }
}

extension WKEngine: NavigationCommitReporting {}
extension WKEngine: BoostEditorEngine {}
