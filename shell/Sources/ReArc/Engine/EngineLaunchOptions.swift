import Foundation

/// Which web engine the process should host. WebKit is the default; Chromium
/// is honored only by a binary built with `REARC_CHROMIUM` running from a
/// bundle that embeds `Chromium Framework.framework` (see `ReArcMain`).
struct EngineLaunchOptions: Equatable {
    enum Engine: String, Equatable {
        case webkit
        case chromium
    }

    static let engineFlagPrefix = "--rearc-engine="
    static let selfTestFlag = "--rearc-selftest"
    static let environmentKey = "REARC_ENGINE"

    var engine: Engine
    /// Chromium runtime proof mode; implies the Chromium engine.
    var selfTest: Bool

    /// The command-line flag wins over `REARC_ENGINE`; unknown values mean WebKit.
    static func parse(arguments: [String], environment: [String: String]) -> EngineLaunchOptions {
        var engine = Engine(rawValue: environment[environmentKey]?.lowercased() ?? "") ?? .webkit
        var selfTest = false
        for argument in arguments.dropFirst() {
            if argument.hasPrefix(engineFlagPrefix) {
                let value = argument.dropFirst(engineFlagPrefix.count).lowercased()
                engine = Engine(rawValue: value) ?? .webkit
            } else if argument == selfTestFlag {
                selfTest = true
            }
        }
        if selfTest { engine = .chromium }
        return EngineLaunchOptions(engine: engine, selfTest: selfTest)
    }
}

/// What an engine instance backs. The Chromium adapter passes this as the
/// tab's nonzero shell space label.
enum EngineRole: UInt64 {
    case tab = 1
    case peek = 2
    case littleArc = 3
}

/// Engines that report main-frame commits/finishes back to the sidebar model.
protocol NavigationCommitReporting: AnyObject {
    var onNavigationCommit: ((URL?, String?) -> Void)? { get set }
}

extension WKEngine: NavigationCommitReporting {}
