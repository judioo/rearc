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
        /// The bundle's principal class is Chromium's, which aborts on the WebKit path.
        case applicationClass
    }

    static let engineFlagPrefix = "--rearc-engine="
    static let selfTestFlag = "--rearc-selftest"
    /// `--rearc-launch-probe=PATH`: start like a normal launch, write what
    /// happened to PATH at `ready`, then quit. Not an engine choice.
    static let launchProbeFlagPrefix = "--rearc-launch-probe="
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
        if selfTest {
            engine = .chromium
            source = .selfTest
        }
        return EngineLaunchOptions(engine: engine, selfTest: selfTest, source: source, launchProbePath: probe.flatMap { $0.isEmpty ? nil : $0 })
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
