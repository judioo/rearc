import Foundation
import SidebarModel

/// Disk-only startup work. No model, AppKit view, engine or observer crosses
/// the worker boundary. The sidebar is applied once, on the main thread.
struct PreparedBrowserStartup {
    let sidebar: SidebarFilePersistence.PreparedLoad
    let history: VisitHistory
    let downloads: DownloadListFile.Contents
    let permissions: SitePermissionStore
    let syncState: SidebarSyncState
    let loadSeconds: [String: TimeInterval]

    static func load(from sidebarFile: URL) -> PreparedBrowserStartup {
        let directory = sidebarFile.deletingLastPathComponent()
        PerfSignposts.launchEvent("StoreLoadStarted")
        var phases: [String: TimeInterval] = [:]
        func load<T>(_ phase: String, _ body: () -> T) -> T {
            let start = ProcessInfo.processInfo.systemUptime
            let value = body()
            phases[phase] = ProcessInfo.processInfo.systemUptime - start
            return value
        }
        let sidebar = load("sidebar") { SidebarFilePersistence.prepareLoad(from: sidebarFile) }
        let history = load("history") { VisitHistoryFile.load(from: directory.appendingPathComponent(VisitHistoryFile.fileName)) }
        let downloads = load("downloads") { DownloadListFile.load(from: directory.appendingPathComponent(DownloadListFile.fileName)) }
        let permissions = load("permissions") { SitePermissionStore.load(from: directory.appendingPathComponent(SitePermissionStore.fileName)) }
        let syncState = load("sync") { SidebarSyncStateFile(fileURL: directory.appendingPathComponent(SidebarSyncStateFile.fileName)).load() }
        let result = PreparedBrowserStartup(sidebar: sidebar, history: history, downloads: downloads,
                                            permissions: permissions, syncState: syncState, loadSeconds: phases)
        PerfSignposts.launchEvent("StoreLoadFinished")
        return result
    }
}
