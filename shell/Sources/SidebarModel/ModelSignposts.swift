import os

/// perf-0 signposts for the model layer (docs/PERFORMANCE-PLAN.md §2.1),
/// subsystem `net.rearc.shell` like the app's `PerfSignposts`. `model`:
/// StoreMutation, ReconcileEngines, SyncAllBoosts, CommandBarResults.
/// `persistence`: SidebarSnapshot, SidebarEncodeWrite, VisitHistorySave,
/// FaviconDiskRead, ModelLoad. Unrecorded signposts cost a branch.
public enum ModelSignposts {
    public static let model = OSSignposter(subsystem: "net.rearc.shell", category: "model")
    public static let persistence = OSSignposter(subsystem: "net.rearc.shell", category: "persistence")

    /// Runs `body` inside the interval `name` of `signposter`.
    @inlinable
    public static func measure<T>(_ signposter: OSSignposter, _ name: StaticString, _ body: () throws -> T) rethrows -> T {
        guard signposter.isEnabled else { return try body() }
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// As `measure`, with a short public detail (a mutation kind, a row count).
    @inlinable
    public static func measure<T>(_ signposter: OSSignposter, _ name: StaticString, detail: @autoclosure () -> String,
                                  _ body: () throws -> T) rethrows -> T {
        guard signposter.isEnabled else { return try body() }
        let text = detail()
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID(), "\(text, privacy: .public)")
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}
