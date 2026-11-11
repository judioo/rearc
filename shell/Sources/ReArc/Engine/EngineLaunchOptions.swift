import Foundation
import SidebarModel

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

    /// Opt-in for release verification, supplied by release/check-launch scripts
    /// through the process environment (never via open --args). This enables
    /// self-test and probe modes only; release argv filtering still applies.
    /// Honoured only by a bundle whose signed Info.plist carries
    /// `ShippedBuild.verificationKey`, which `scripts/release.sh` removes
    /// before notarizing: a shipped bundle has no self-test or probe mode
    /// (RC-0.1.0-602 F-03, T-04).
    static let releaseVerificationEnvironmentKey = "REARC_RELEASE_VERIFICATION"

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
    /// Set when a release build was asked for self-test or probe mode on a data dir that
    /// is not throwaway (security RC-0.1.0-544 F-03); the process must exit, never launch.
    var verificationRefusal: String?

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
        /// Never activate the app or make its window key (`open -g`): the
        /// frame-free scenarios run while someone else uses the Mac.
        var background = false
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
                if argument == EngineLaunchOptions.benchFlag + "-background" { result.background = true }
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

    /// Self-test, launch probes and the iCloud look probe: a development
    /// build, or a release verification bundle launched with
    /// `REARC_RELEASE_VERIFICATION=1`; never a shipped bundle.
    static func allowsVerification(infoDictionary: [String: Any]?, environment: [String: String]) -> Bool {
        !ShippedBuild.isRelease(infoDictionary: infoDictionary)
            || (ShippedBuild.isVerificationBundle(infoDictionary: infoDictionary) && environment[releaseVerificationEnvironmentKey] == "1")
    }

    /// The command-line flag wins over `REARC_ENGINE`, which wins over the
    /// bundle default; unknown values mean WebKit.
    static func parse(
        arguments: [String],
        environment: [String: String],
        infoDictionary: [String: Any]? = nil,
        dataDirRefusal: (String) -> String? = ReleaseVerificationDataDir.refusal
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
        let isRelease = ShippedBuild.isRelease(infoDictionary: infoDictionary)
        let verificationAllowed = allowsVerification(infoDictionary: infoDictionary, environment: environment)
        var selfTest = false
        var probe: String?
        for argument in arguments.dropFirst() {
            if argument.hasPrefix(engineFlagPrefix) {
                let value = argument.dropFirst(engineFlagPrefix.count).lowercased()
                engine = Engine(rawValue: value) ?? .webkit
                source = .argument
            } else if verificationAllowed, argument == selfTestFlag {
                selfTest = true
            } else if verificationAllowed, argument.hasPrefix(launchProbeFlagPrefix) {
                probe = String(argument.dropFirst(launchProbeFlagPrefix.count))
            }
        }
        // A release build uses the real Keychain item, and the self-test loads extension code:
        // both modes run only on a fresh data dir, never on the user's profile.
        var refusal: String?
        if isRelease, selfTest || probe != nil {
            let mode = selfTest ? selfTestFlag : String(launchProbeFlagPrefix.dropLast())
            if let dir = ChromiumLaunchArguments.userDataDir(in: ChromiumLaunchArguments.releaseArguments(arguments)) {
                refusal = dataDirRefusal(dir).map { "\(mode) refused for --user-data-dir=\(dir): \($0)" }
            } else {
                refusal = "\(mode) in a release build needs --user-data-dir=<new empty directory>"
            }
            if refusal != nil {
                selfTest = false
                probe = nil
            }
        }
        let bench = selfTest || isRelease ? nil : BenchOptions.parse(Array(arguments.dropFirst()))
        if selfTest {
            engine = .chromium
            source = .selfTest
        } else if bench != nil {
            engine = .chromium
            source = .bench
        }
        return EngineLaunchOptions(engine: engine, selfTest: selfTest, source: source,
                                   launchProbePath: probe.flatMap { $0.isEmpty ? nil : $0 }, bench: bench,
                                   verificationRefusal: refusal)
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

/// The data dir a release self-test or launch probe may use: absent or empty, and outside
/// the user's ReArc data (the default root and any `REARC_DATA_DIR` root). Symlinks are
/// resolved first, so a link to the real profile is refused like the profile itself.
enum ReleaseVerificationDataDir {
    static func refusal(_ path: String) -> String? {
        refusal(path, protectedRoots: [ShellDataLocation.root(environment: [:]), ShellDataLocation.root])
    }

    static func refusal(_ path: String, protectedRoots: [URL], fileManager: FileManager = .default) -> String? {
        guard !path.isEmpty else { return "empty path" }
        let dir = resolved(URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
        for root in protectedRoots.map(resolved) {
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            if dir.path == root.path || (dir.path + "/").hasPrefix(rootPath) || rootPath.hasPrefix(dir.path + "/") {
                return "it overlaps the ReArc data directory \(root.path)"
            }
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return "it is not a directory" }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return "it cannot be read" }
        return entries.isEmpty ? nil : "it is not empty (verification runs only on a new profile)"
    }

    private static func resolved(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
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

/// Engines whose shell role can change while their page lives on: a Peek
/// expanded into a tab keeps its contents, history and shell identity.
protocol EngineRoleRetagging: AnyObject {
    func retag(as role: EngineRole)
}

/// Engines that report main-frame commits/finishes back to the sidebar model.
protocol NavigationCommitReporting: AnyObject {
    var onNavigationCommit: ((URL?, String?) -> Void)? { get set }
}

extension WKEngine: NavigationCommitReporting {}
extension WKEngine: BoostEditorEngine {}
