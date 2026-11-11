import Foundation

/// Where the shell keeps its own files: the sidebar, history, favicons,
/// easels, captures and the Chromium user data dir. By default
/// `~/Library/Application Support/ReArc`. `REARC_DATA_DIR` moves all of it,
/// so a manual test launch (`open --env REARC_DATA_DIR=… ReArc.app`) never
/// reads or writes the user's data. Chromium's `--user-data-dir` alone moves
/// only the engine's profile directories (perf-6).
///
/// A shipped bundle ignores `REARC_DATA_DIR` (RC-0.1.0-602 T-04): once the
/// person grants ReArc Full Disk Access, any process could otherwise start
/// it on a folder that process prepared and borrow the grant.
public enum ShellDataLocation {
    public static let environmentKey = "REARC_DATA_DIR"

    /// The data root for this process.
    public static let root: URL = root(environment: ProcessInfo.processInfo.environment)

    /// Whether `REARC_DATA_DIR` moved the root away from the user's data.
    public static let isOverridden: Bool = override(in: ProcessInfo.processInfo.environment) != nil

    /// The user's own data root, whatever the environment says.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReArc", isDirectory: true)
    }

    public static func root(environment: [String: String], honoursOverride: Bool = !ShippedBuild.current) -> URL {
        if let dir = override(in: environment, honoursOverride: honoursOverride) { return URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL }
        return defaultRoot
    }

    private static func override(in environment: [String: String], honoursOverride: Bool = !ShippedBuild.current) -> String? {
        guard honoursOverride, let dir = environment[environmentKey], !dir.isEmpty else { return nil }
        return (dir as NSString).expandingTildeInPath
    }
}

/// A release bundle as people get it (RC-0.1.0-602 T-04, F-03). Its signed
/// Info.plist has `ReArcRelease` and not `ReArcReleaseVerification`, the key
/// `scripts/release.sh` signs into the bundle it verifies and removes, then
/// signs again, before notarizing. A shipped bundle takes no data folder,
/// engine profile folder, self-test or launch probe from its environment or
/// arguments: changing the key breaks the signature the person's Full Disk
/// Access grant is bound to.
public enum ShippedBuild {
    public static let releaseKey = "ReArcRelease"
    public static let verificationKey = "ReArcReleaseVerification"

    /// This process's bundle.
    public static let current: Bool = isShipped(infoDictionary: Bundle.main.infoDictionary)

    public static func isRelease(infoDictionary: [String: Any]?) -> Bool {
        infoDictionary?[releaseKey] as? Bool == true
    }

    /// A release bundle still being verified by `scripts/release.sh`.
    public static func isVerificationBundle(infoDictionary: [String: Any]?) -> Bool {
        isRelease(infoDictionary: infoDictionary) && infoDictionary?[verificationKey] as? Bool == true
    }

    public static func isShipped(infoDictionary: [String: Any]?) -> Bool {
        isRelease(infoDictionary: infoDictionary) && !isVerificationBundle(infoDictionary: infoDictionary)
    }

    /// Why a shipped bundle will not start: it was given a data folder or an
    /// engine profile folder. Refusing, rather than quietly using the
    /// person's own folder, also keeps a test launch with a throwaway
    /// `REARC_DATA_DIR` from ever opening their real data.
    public static func launchRefusal(arguments: [String], environment: [String: String], shipped: Bool = current) -> String? {
        guard shipped else { return nil }
        if let dir = environment[ShellDataLocation.environmentKey], !dir.isEmpty {
            return "a shipped ReArc ignores \(ShellDataLocation.environmentKey) and does not start with it; "
                + "use a bundle built with scripts/release.sh --qa (never distributed) for test launches"
        }
        if arguments.dropFirst().contains(where: { $0 == "--user-data-dir" || $0.hasPrefix("--user-data-dir=") }) {
            return "a shipped ReArc takes no --user-data-dir; use a bundle built with scripts/release.sh --qa for test launches"
        }
        return nil
    }
}
