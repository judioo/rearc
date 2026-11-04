import AppKit
import SidebarModel

/// What a tray button asks of a download.
enum DownloadAction: UInt32 {
    /// Raw values are `ReArcDownloadAction` actions.
    case pause = 0, resume, cancel, open, reveal, remove
}

/// An engine's side of the tray: performs actions on the items it owns.
protocol DownloadBackend: AnyObject {
    /// False when the backend does not know the item (the controller then
    /// falls back to Finder/Launch Services for open and reveal, or drops the row).
    func perform(_ action: DownloadAction, id: String) -> Bool
    /// The default download directory changed.
    func directoryChanged(_ directory: URL)
    /// "Ask where to save each file" changed.
    func askWhereToSaveChanged(_ ask: Bool)
}

extension DownloadBackend {
    func askWhereToSaveChanged(_ ask: Bool) {}
}

/// The downloads tray's model, shared by every window: the recent list
/// (persisted with the default directory in `Downloads.json` next to the
/// sidebar file), and routing of tray actions to the engine that owns each
/// item. Chromium items come from ABI 1.17 events, WebKit items from
/// `WebKitDownloadCenter`.
@Observable
final class DownloadsController {
    private(set) var list: DownloadList
    private(set) var directory: URL
    /// Each download asks for its location in a save panel (sheet on the
    /// page's window) instead of going to `directory`.
    var askWhereToSave: Bool {
        didSet {
            guard askWhereToSave != oldValue else { return }
            chromium?.askWhereToSaveChanged(askWhereToSave)
            scheduleSave(immediately: true)
        }
    }
    /// False when the running engine cannot ask (Chromium before ABI 1.19).
    var canAskWhereToSave = true
    /// Shown in the key browser window's sidebar.
    var isTrayPresented = false
    /// Bumped when a new download starts (the tray button pulses).
    private(set) var startCount = 0

    @ObservationIgnored let webKit = WebKitDownloadCenter()
    /// Chromium's backend when the engine has `downloads` (ABI 1.17).
    @ObservationIgnored weak var chromium: DownloadBackend? {
        didSet {
            chromium?.directoryChanged(directory)
            chromium?.askWhereToSaveChanged(askWhereToSave)
        }
    }
    /// Shows chrome://downloads (keep-dangerous flow); nil when unavailable.
    @ObservationIgnored var reviewDangerousPage: (() -> Void)?
    /// True while `reviewDangerousPage` can open a page.
    var canReviewDangerous = false
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?
    @ObservationIgnored private let workspace: NSWorkspace

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    init(fileURL: URL?, workspace: NSWorkspace = .shared) {
        self.fileURL = fileURL
        self.workspace = workspace
        let contents = fileURL.map(DownloadListFile.load(from:)) ?? DownloadListFile.Contents()
        var list = contents.list
        list.markStaleTransfersInterrupted()
        list.trim()
        self.list = list
        directory = contents.directory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultDirectory
        askWhereToSave = contents.askWhereToSave ?? false
        webKit.controller = self
    }

    var records: [DownloadRecord] { list.records }
    var activeCount: Int { list.activeCount }
    var hasDangerous: Bool { list.hasDangerous }

    // MARK: Engine events

    func apply(_ event: DownloadEvent, source: DownloadSource, now: Date = Date()) {
        let change = list.apply(event, source: source, now: now)
        if case .inserted = change, event.state == .inProgress {
            startCount += 1
            isTrayPresented = true
        }
        // Progress is saved lazily; state transitions right away.
        scheduleSave(immediately: event.kind != .updated)
    }

    // MARK: Tray actions

    func perform(_ action: DownloadAction, on id: String) {
        guard let record = list.record(withID: id) else { return }
        let handled = backend(for: record)?.perform(action, id: id) ?? false
        switch action {
        case .open:
            if !handled, record.hasFileOnDisk { workspace.open(URL(fileURLWithPath: record.targetPath)) }
        case .reveal:
            if !handled, !record.targetPath.isEmpty { reveal(record) }
        case .remove:
            // Chromium confirms with a removed event; anything else goes now.
            if !handled || record.source == .webKit { list.remove(id: id) }
            scheduleSave(immediately: true)
        case .pause, .resume, .cancel:
            break
        }
    }

    /// Discard a dangerous download: cancel it and drop it from the list.
    func discard(_ id: String) {
        perform(.remove, on: id)
    }

    func clearFinished() {
        for record in list.records where !record.isActive {
            perform(.remove, on: record.id)
        }
        // Rows no engine still knows (an earlier session's WebKit items) go too.
        _ = list.clearFinished()
        scheduleSave(immediately: true)
    }

    func setDirectory(_ url: URL) {
        directory = url.standardizedFileURL
        chromium?.directoryChanged(directory)
        scheduleSave(immediately: true)
    }

    /// Lets the user pick the default download folder.
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        panel.prompt = "Use Folder"
        panel.message = "Downloads are saved to this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDirectory(url)
    }

    func revealDirectory() {
        workspace.activateFileViewerSelecting([directory])
    }

    private func reveal(_ record: DownloadRecord) {
        let url = URL(fileURLWithPath: record.targetPath)
        if FileManager.default.fileExists(atPath: url.path) {
            workspace.activateFileViewerSelecting([url])
        } else {
            workspace.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    private func backend(for record: DownloadRecord) -> DownloadBackend? {
        switch record.source {
        case .chromium: return chromium
        case .webKit: return webKit
        }
    }

    // MARK: Persistence

    private func scheduleSave(immediately: Bool) {
        guard fileURL != nil else { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0.05 : 2), execute: work)
    }

    func save() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        guard let fileURL else { return }
        var trimmed = list
        trimmed.trim()
        do {
            try DownloadListFile.save(.init(directory: directory.path, askWhereToSave: askWhereToSave, list: trimmed), to: fileURL)
        } catch {
            FileHandle.standardError.write(Data("[ReArc] could not save \(fileURL.lastPathComponent): \(error.localizedDescription)\n".utf8))
        }
    }
}
