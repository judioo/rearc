#if REARC_CHROMIUM
import AppKit
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

    /// Save panels for "Ask where to save" requests with no live tab to show them.
    private var savePanels: [UInt64: FilePanelHandle] = [:]
    private var savesPending: Set<UInt64> = []
    var filePanels: FilePanelPresenting = SystemFilePanelPresenter()

    /// Connects the runtime's download events and directory to `controller`.
    func install() {
        guard runtime.capabilities.downloads, let controller else { return }
        runtime.onDownloadEvent = { [weak self] in self?.handle($0) }
        controller.canAskWhereToSave = runtime.capabilities.downloadSavePrompt
        if runtime.capabilities.downloadSavePrompt {
            runtime.onDownloadSaveRequest = { [weak self] in self?.presentSavePanel($0) }
            runtime.onDownloadSaveCancelled = { [weak self] id in
                guard let self, self.savesPending.remove(id) != nil else { return }
                self.savePanels.removeValue(forKey: id)?.close()
            }
        }
        controller.chromium = self
    }

    /// Policy prompt 1 (ABI 1.19): Chromium asks for the path through the
    /// file chooser channel; the panel confirms replacing an existing file.
    func askWhereToSaveChanged(_ ask: Bool) {
        runtime.asksWhereToSaveDownloads = ask
    }

    private func presentSavePanel(_ event: ChromiumFileChooserEvent) {
        let id = event.identity.requestID
        savesPending.insert(id)
        let handle = filePanels.present(event.request, in: NSApp.keyWindow) { [weak self] urls in
            guard let self, self.savesPending.remove(id) != nil else { return }
            self.savePanels[id] = nil
            let paths = urls.flatMap { FileChooserReply.validPaths($0.map(\.path), mode: .save) }
            self.runtime.respondFileChooser(id, paths: paths)
        }
        if savesPending.contains(id), let handle { savePanels[id] = handle }
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
        refreshWarning(download)
    }

    /// ABI 1.24: the warning booleans, not the danger code, say whether Keep
    /// and Discard apply (4 is a pending check, 6 already validated).
    private func refreshWarning(_ download: ChromiumDownloadEvent) {
        let event = download.event
        guard runtime.capabilities.dangerousDownloads, event.kind != .removed, event.state == .inProgress, !event.guid.isEmpty else { return }
        let (status, warning) = runtime.downloadWarning(profile: download.profileID, id: download.downloadID)
        if status == .rearcOK || status == ReArcStatus(REARC_NOT_FOUND) {
            controller?.updateWarning(warning?.offersDecision == true ? warning : nil, for: event.guid)
        }
    }

    func resolveDanger(_ decision: DownloadDangerDecision, id: String) -> Bool {
        guard let handle = handles[id] else { return false }
        let status = runtime.resolveDownloadDanger(profile: handle.profile, id: handle.id, decision: decision)
        guard status == .rearcOK else { return false }
        if decision == .keep {
            // A second warning (insecure, then dangerous) may remain: ask again.
            let (after, warning) = runtime.downloadWarning(profile: handle.profile, id: handle.id)
            if after == .rearcOK || after == ReArcStatus(REARC_NOT_FOUND) {
                controller?.updateWarning(warning?.offersDecision == true ? warning : nil, for: id)
            }
        }
        return true
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
