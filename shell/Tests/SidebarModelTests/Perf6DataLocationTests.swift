import Foundation
import Testing
@testable import SidebarModel

/// perf-6: `REARC_DATA_DIR` moves every shell file, so a test launch never
/// touches the user's ReArc data.
struct Perf6DataLocationTests {
    private let userRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ReArc", isDirectory: true)

    @Test func defaultsToApplicationSupport() {
        #expect(ShellDataLocation.root(environment: [:]) == userRoot)
        #expect(ShellDataLocation.root(environment: [ShellDataLocation.environmentKey: ""]) == userRoot)
    }

    @Test func overrideMovesTheRoot() {
        let root = ShellDataLocation.root(environment: [ShellDataLocation.environmentKey: "/tmp/rearc-test/./data"])
        #expect(root.path == "/tmp/rearc-test/data")
        let home = ShellDataLocation.root(environment: [ShellDataLocation.environmentKey: "~/rearc-test"])
        #expect(home.path == NSHomeDirectory() + "/rearc-test")
    }

    /// RC-0.1.0-602 T-04: a shipped bundle never moves its data folder.
    @Test func aShippedBundleIgnoresTheOverride() {
        #expect(ShellDataLocation.root(environment: [ShellDataLocation.environmentKey: "/tmp/prepared"], honoursOverride: false) == userRoot)
    }

    /// The test process sets no override: the shell's files stay under one root.
    @Test func filesShareTheRoot() {
        let root = ShellDataLocation.root
        #expect(SidebarFilePersistence.defaultFileURL == root.appendingPathComponent("sidebar.json"))
        #expect(EaselFilePersistence.defaultDirectoryURL == root.appendingPathComponent("easels", isDirectory: true))
        #expect(CaptureFileStore.defaultDirectoryURL == root.appendingPathComponent("Captures", isDirectory: true))
    }
}
