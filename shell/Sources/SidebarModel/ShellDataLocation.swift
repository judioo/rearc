import Foundation

/// Where the shell keeps its own files: the sidebar, history, favicons,
/// easels, captures and the Chromium user data dir. By default
/// `~/Library/Application Support/ReArc`. `REARC_DATA_DIR` moves all of it,
/// so a manual test launch (`open --env REARC_DATA_DIR=… ReArc.app`) never
/// reads or writes the user's data. Chromium's `--user-data-dir` alone moves
/// only the engine's profile directories (perf-6).
public enum ShellDataLocation {
    public static let environmentKey = "REARC_DATA_DIR"

    /// The data root for this process.
    public static let root: URL = root(environment: ProcessInfo.processInfo.environment)

    /// Whether `REARC_DATA_DIR` moved the root away from the user's data.
    public static let isOverridden: Bool = override(in: ProcessInfo.processInfo.environment) != nil

    public static func root(environment: [String: String]) -> URL {
        if let dir = override(in: environment) { return URL(fileURLWithPath: dir, isDirectory: true).standardizedFileURL }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReArc", isDirectory: true)
    }

    private static func override(in environment: [String: String]) -> String? {
        guard let dir = environment[environmentKey], !dir.isEmpty else { return nil }
        return (dir as NSString).expandingTildeInPath
    }
}
