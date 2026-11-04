#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

/// The tray's Chromium side (ABI 1.17, WAVE-18-REPORT "Exact Swift adoption —
/// concern C"). Chromium's DownloadManager owns the items: rows are keyed by
/// GUID, and actions address the item by its session-local profile and
/// download IDs, refreshed by every event. Items restored from Chromium's
/// history arrive as kind 0 with their current state and merge into the
/// persisted rows.
final class ChromiumDownloadBackend: DownloadBackend {
    private unowned let runtime: ChromiumRuntime
    private weak var controller: DownloadsController?
    private var handles: [String: (profile: UInt64, id: UInt32)] = [:]
    /// Events delivered, for logs and the self-test.
    private(set) var eventCount = 0

    init(runtime: ChromiumRuntime, controller: DownloadsController) {
        self.runtime = runtime
        self.controller = controller
    }

    /// Connects the runtime's download events and directory to `controller`.
    func install() {
        guard runtime.capabilities.downloads, let controller else { return }
        runtime.onDownloadEvent = { [weak self] in self?.handle($0) }
        controller.chromium = self
    }

    func handle(_ download: ChromiumDownloadEvent) {
        eventCount += 1
        let guid = download.event.guid
        if download.event.kind == .removed {
            handles[guid] = nil
        } else if !guid.isEmpty {
            handles[guid] = (download.profileID, download.downloadID)
        }
        controller?.apply(download.event, source: .chromium)
    }

    func handle(for id: String) -> (profile: UInt64, id: UInt32)? { handles[id] }

    func perform(_ action: DownloadAction, id: String) -> Bool {
        guard let handle = handles[id] else { return false }
        let status = runtime.downloadAction(profile: handle.profile, id: handle.id, action: action.rawValue)
        if status == ReArcStatus(REARC_INVALID_STATE) {
            // The item changed state since the last event; that event's successor will show it.
            ChromiumLog.info("download \(id) \(action) not valid in its current state")
            return true
        }
        if status != .rearcOK {
            ChromiumLog.info("download \(id) \(action) rejected: \(status.rearcName)")
            if status == ReArcStatus(REARC_NOT_FOUND) { handles[id] = nil }
            return false
        }
        return true
    }

    func directoryChanged(_ directory: URL) {
        runtime.downloadDirectory = directory
    }
}
#endif
