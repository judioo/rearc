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
    /// Keep or Discard a download the engine warned about; false when it cannot.
    func resolveDanger(_ decision: DownloadDangerDecision, id: String) -> Bool
    /// Removes finished items in one batch (Clear); the controller drops the rows.
    func removeFinished(_ ids: [String])
    /// The Library wants the whole history: start the engine's history load.
    func loadHistory()
    /// The engine keeps a long history in its database and reports its size
    /// when it loads (ABI 1.48): until then the list is not the whole history.
    var reportsHistorySize: Bool { get }
}

extension DownloadBackend {
    func askWhereToSaveChanged(_ ask: Bool) {}
    func resolveDanger(_ decision: DownloadDangerDecision, id: String) -> Bool { false }
    func removeFinished(_ ids: [String]) { ids.forEach { _ = perform(.remove, id: $0) } }
    func loadHistory() {}
    var reportsHistorySize: Bool { false }
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
    /// Shown in the key browser window's sidebar. Only the button opens it:
    /// a new download shows the bar's button, which pulses and fills its
    /// ring, as Arc's bar does, rather than presenting a popover (~60 ms of
    /// SwiftUI layout in the download's first frame).
    var isTrayPresented = false
    var libraryFilter = LibraryDownloadFilter()
    /// Bumped when a new download starts (the tray button pulses).
    private(set) var startCount = 0

    // What the bottom bar shows, worked out from the list's kept indexes
    // after each change and set only when it differs, so a replayed history
    // that changes none of it never redraws the bar.
    /// The quick view's rows (`RecentDownloads.latest`).
    private(set) var recent: [DownloadRecord] = []
    private(set) var activeCount = 0
    private(set) var activeFraction: Double?
    /// A row waits for Keep or Discard (`needsDecision`).
    private(set) var hasDangerous = false
    /// Clear has something to remove.
    private(set) var hasFinished = false
    /// History rows each engine profile reported at its load (ABI 1.48
    /// `archived_rows`) that the list does not hold yet: they page in a chunk
    /// at a time. Nil until the first profile's history loaded.
    private var historyOutstanding: [UInt64: Int]?

    @ObservationIgnored let webKit = WebKitDownloadCenter()
    /// Chromium's backend when the engine has `downloads` (ABI 1.17).
    @ObservationIgnored weak var chromium: DownloadBackend? {
        didSet {
            chromium?.directoryChanged(directory)
            chromium?.askWhereToSaveChanged(askWhereToSave)
        }
    }
    /// Shows chrome://downloads (keep-dangerous flow before ABI 1.24); nil when unavailable.
    @ObservationIgnored var reviewDangerousPage: (() -> Void)?
    /// True while `reviewDangerousPage` can open a page.
    var canReviewDangerous = false
    /// Chromium's current warnings (ABI 1.24 `dangerous_downloads`), by row; not persisted.
    private(set) var warnings: [String: DownloadWarning] = [:]
    /// The Library search's folded names and sites, kept between keystrokes.
    @ObservationIgnored private var searchIndex = LibraryDownloads.SearchIndex()
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?
    /// When the pending save runs; a change due no sooner rides on it.
    @ObservationIgnored private(set) var saveDeadline: DispatchTime?
    @ObservationIgnored private let workspace: NSWorkspace
    /// Main-thread time a turn may spend applying events before the rest
    /// wait for later turns (nil: every event applies at once).
    @ObservationIgnored private let turnBudget: TimeInterval?
    @ObservationIgnored private let clock: () -> TimeInterval
    @ObservationIgnored private var turnStarted: TimeInterval?
    @ObservationIgnored private var pending = BudgetedQueue<Pending>()
    @ObservationIgnored private var drainScheduled = false

    /// Work that waits for a later turn, in arrival order.
    private enum Pending {
        case event(DownloadEvent, DownloadSource, Date)
        case archived([DownloadRecord], profile: UInt64?)
    }

    /// What the app passes as `turnBudget`: Chromium's history slices are
    /// ~8 ms of engine work each, and the shell's share of a turn should
    /// leave room for SwiftUI's update in the same frame.
    static let appTurnBudget: TimeInterval = 0.004
    /// Archived rows go in this many at a time: one chunk is one apply, so
    /// it should fit in a turn's budget (2,000 took ~15 ms of one turn).
    static let archivedChunk = 500

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    init(fileURL: URL?, workspace: NSWorkspace = .shared, prepared: DownloadListFile.Contents? = nil,
         turnBudget: TimeInterval? = nil, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.fileURL = fileURL
        self.workspace = workspace
        self.turnBudget = turnBudget
        self.clock = clock
        let contents = prepared ?? fileURL.map { DownloadListFile.load(from: $0, limit: DownloadList.defaultLimit) } ?? DownloadListFile.Contents()
        var list = contents.list
        list.markStaleTransfersInterrupted()
        list.trim()
        self.list = list
        directory = contents.directory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultDirectory
        askWhereToSave = contents.askWhereToSave ?? false
        webKit.controller = self
        refreshSummary()
        DownloadFormat.prepare()
    }

    var records: [DownloadRecord] { list.records }

    /// Every download in the history, archived rows included, for the tray's
    /// Show All: the list holds the rows loaded so far (the 50 `Downloads.json`
    /// keeps until the engine's history loads, then its archived rows a chunk
    /// at a time). Nil while an engine's history has not reported its size.
    var historyCount: Int? {
        guard chromium?.reportsHistorySize == true else { return list.summary.rows }
        return historyOutstanding.map { list.summary.rows + $0.values.reduce(0, +) }
    }

    /// A profile's engine history loaded with `archived` rows kept in its
    /// database only; the backend pages them in next (`appendArchived`).
    func noteEngineHistory(profile: UInt64, archived: Int) {
        historyOutstanding = (historyOutstanding ?? [:]).merging([profile: archived]) { $1 }
    }

    /// The rows the Library's search shows (`LibraryDownloads.matching`).
    func matching(_ query: String) -> [DownloadRecord] {
        searchIndex.matching(list.records, query: query)
    }

    /// Chromium's warning for a row changed (nil: none, or the item is gone).
    func updateWarning(_ warning: DownloadWarning?, for id: String) {
        guard warnings[id] != warning else { return }
        warnings[id] = warning
        refreshSummary()
    }

    /// Sets the bar's values from the list's indexes; each only when it changed.
    private func refreshSummary() {
        let latest = list.latest()
        if latest != recent { recent = latest }
        let summary = list.summary
        if summary.active != activeCount { activeCount = summary.active }
        if summary.activeFraction != activeFraction { activeFraction = summary.activeFraction }
        if (summary.finished > 0) != hasFinished { hasFinished = summary.finished > 0 }
        // The danger code decides unless Chromium's warning says otherwise;
        // warnings exist only for a few unfinished rows.
        var dangerous = summary.dangerous
        for (id, warning) in warnings {
            guard let record = list.record(withID: id), record.isActive else { continue }
            dangerous += (warning.offersDecision ? 1 : 0) - (record.isDangerous ? 1 : 0)
        }
        if (dangerous > 0) != hasDangerous { hasDangerous = dangerous > 0 }
    }

    /// The row waits for Keep or Discard: the engine's warning when it gave
    /// one, else the danger code (WebKit has none; older engines).
    func needsDecision(_ record: DownloadRecord) -> Bool {
        guard record.isActive else { return false }
        if let warning = warnings[record.id] { return warning.offersDecision }
        return record.isDangerous
    }

    /// Keep is offered: the engine can validate this item natively.
    func canKeep(_ record: DownloadRecord) -> Bool {
        warnings[record.id]?.offersDecision == true
    }

    func warningText(for record: DownloadRecord) -> String? {
        guard needsDecision(record) else { return nil }
        return warnings[record.id]?.message ?? record.statusText
    }

    /// Keep a dangerous download (Chromium validates it; an item with an
    /// insecure and a danger warning asks again for the second).
    @discardableResult
    func keep(_ id: String) -> Bool {
        flushPending()
        guard let record = list.record(withID: id), canKeep(record) else { return false }
        return backend(for: record)?.resolveDanger(.keep, id: id) ?? false
    }

    // MARK: Engine events

    /// Applies an engine event now, or, once this turn has spent its budget
    /// (or earlier events still wait), in a later turn, in order.
    func apply(_ event: DownloadEvent, source: DownloadSource, now: Date = Date()) {
        guard let budget = turnBudget, !pending.isEmpty || turnSpent(budget) else {
            return applyNow(CollectionOfOne((event, source, now)))
        }
        pending.append(.event(event, source, now))
        scheduleDrain()
    }

    /// Events in order (ABI 1.49 batches), as `apply(_:source:now:)` each, in one list change.
    func apply(_ events: [DownloadEvent], source: DownloadSource, now: Date = Date()) {
        guard !events.isEmpty else { return }
        guard let budget = turnBudget, !pending.isEmpty || turnSpent(budget) else {
            return applyNow(events.map { (event: $0, source: source, now: now) })
        }
        for event in events { pending.append(.event(event, source, now)) }
        scheduleDrain()
    }

    /// Work still waiting for a later turn (the bench waits until there is none).
    var hasPendingWork: Bool { !pending.isEmpty }

    private func applyNow<Events: Collection>(_ events: Events)
    where Events.Element == (event: DownloadEvent, source: DownloadSource, now: Date) {
        let changes = list.apply(events)
        var immediately = false
        for (change, (event, _, _)) in zip(changes, events) {
            // Chromium replays its whole history at launch: only a row that has a warning writes the observed map.
            if event.kind == .removed || event.state != .inProgress, warnings[event.guid] != nil { warnings[event.guid] = nil }
            if case .inserted = change, event.state == .inProgress { startCount += 1 }
            if event.kind != .updated { immediately = true }
        }
        refreshSummary()
        // Progress is saved lazily; state transitions right away.
        scheduleSave(immediately: immediately)
    }

    /// True once this turn has applied events for longer than `budget`. A
    /// turn starts with its first event and ends when the main queue next
    /// runs a block (after the engine's task that delivered the events).
    private func turnSpent(_ budget: TimeInterval) -> Bool {
        let now = clock()
        guard let started = turnStarted else {
            turnStarted = now
            Self.nextTurn { [weak self] in self?.turnStarted = nil }
            return false
        }
        return now - started > budget
    }

    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        Self.afterYield { [weak self] in self?.drainPending() }
    }

    /// One turn's share of the waiting work: runs of events in one change to
    /// the list each, archived rows a chunk at a time.
    private func drainPending() {
        drainScheduled = false
        guard let budget = turnBudget else { return flushPending() }
        pending.drain(budget: budget, stride: 256, now: clock) { applyPending($0) }
        if !pending.isEmpty { scheduleDrain() }
    }

    /// Everything still waiting, now: an action, Keep or Discard sees every row.
    func flushPending() {
        guard !pending.isEmpty else { return }
        applyPending(pending.removeAll()[...])
    }

    private func applyPending(_ items: ArraySlice<Pending>) {
        var events: [(event: DownloadEvent, source: DownloadSource, now: Date)] = []
        func applyEvents() {
            guard !events.isEmpty else { return }
            applyNow(events)
            events.removeAll(keepingCapacity: true)
        }
        for item in items {
            switch item {
            case .event(let event, let source, let now):
                events.append((event, source, now))
            case .archived(let records, let profile):
                applyEvents()
                applyArchived(records, profile: profile)
            }
        }
        applyEvents()
    }

    /// Runs `block` on the main run loop's next pass, not in the current one
    /// (a main-queue block can run before the run loop next waits).
    private static func nextTurn(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Runs `block` from a 1 ms timer: the run loop fires a timer at most once
    /// a pass, so each budgeted turn gets its own pass, with input and the
    /// display link in between. A performed block can run several times in
    /// one pass, and a 2,000-row drain ran ~15 ms without a break.
    private static func afterYield(_ block: @escaping () -> Void) {
        RunLoop.main.add(Timer(timeInterval: 0.001, repeats: false) { _ in block() }, forMode: .common)
    }

    // MARK: Tray actions

    func perform(_ action: DownloadAction, on id: String) {
        flushPending()
        guard let record = list.record(withID: id) else { return }
        let handled = backend(for: record)?.perform(action, id: id) ?? false
        switch action {
        case .open:
            if !handled, record.hasFileOnDisk { workspace.open(URL(fileURLWithPath: record.targetPath)) }
        case .reveal:
            if !handled, !record.targetPath.isEmpty { reveal(record) }
        case .remove:
            // Chromium confirms with a removed event; anything else goes now.
            if !handled || record.source == .webKit {
                list.remove(id: id)
                refreshSummary()
            }
            scheduleSave(immediately: true)
        case .pause, .resume, .cancel:
            break
        }
    }

    /// Discard a dangerous download: Chromium removes the item and its file
    /// (ABI 1.24), otherwise it is cancelled and dropped from the list.
    func discard(_ id: String) {
        flushPending()
        if let record = list.record(withID: id), canKeep(record),
           backend(for: record)?.resolveDanger(.discard, id: id) == true {
            warnings[id] = nil
            return
        }
        perform(.remove, on: id)
    }

    func clearFinished() {
        flushPending()
        // One batch per engine: with a long history a call per row was quadratic.
        let finished = list.records.filter { !$0.isActive }
        chromium?.removeFinished(finished.filter { $0.source == .chromium }.map(\.id))
        webKit.removeFinished(finished.filter { $0.source == .webKit }.map(\.id))
        // Rows no engine still knows (an earlier session's WebKit items) go too.
        _ = list.clearFinished()
        refreshSummary()
        scheduleSave(immediately: true)
    }

    /// Library › Downloads opened: the engine loads its whole history now
    /// rather than at the session's first download.
    func loadEngineHistory() {
        chromium?.loadHistory()
    }

    /// History rows the engine keeps in its database only (ABI 1.48), a page
    /// at a time, as older rows. Not saved: `Downloads.json` keeps the newest.
    /// With a turn budget they go in a chunk at a time, after any events
    /// still waiting (live rows are newer and come first).
    func appendArchived(_ records: [DownloadRecord], profile: UInt64? = nil) {
        guard turnBudget != nil else { return applyArchived(records, profile: profile) }
        for start in stride(from: 0, to: records.count, by: Self.archivedChunk) {
            pending.append(.archived(Array(records[start ..< min(start + Self.archivedChunk, records.count)]), profile: profile))
        }
        scheduleDrain()
    }

    private func applyArchived(_ records: [DownloadRecord], profile: UInt64?) {
        list.appendArchived(records)
        if let profile, let outstanding = historyOutstanding?[profile] {
            historyOutstanding?[profile] = max(outstanding - records.count, 0)
        }
        refreshSummary()
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

    /// The file in Finder, or its folder when it is gone. The check runs off
    /// the main thread; when it cannot answer in time, Finder gets the file.
    private func reveal(_ record: DownloadRecord) {
        let url = URL(fileURLWithPath: record.targetPath)
        let workspace = workspace
        Task { @MainActor in
            let state = await DownloadFileService.shared.state(atPath: url.path)
            workspace.activateFileViewerSelecting([state?.exists == false ? url.deletingLastPathComponent() : url])
        }
    }

    private func backend(for record: DownloadRecord) -> DownloadBackend? {
        switch record.source {
        case .chromium: return chromium
        case .webKit: return webKit
        }
    }

    // MARK: Persistence

    /// State changes save within 50 ms, progress within 2 s. A save already
    /// due by then writes this change too, so a burst of events (a replayed
    /// history, a transfer's progress) arms one timer, not one per event.
    private func scheduleSave(immediately: Bool) {
        guard fileURL != nil else { return }
        let deadline = DispatchTime.now() + (immediately ? 0.05 : 2)
        if saveWorkItem != nil, let due = saveDeadline, due <= deadline { return }
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = work
        saveDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
    }

    func save() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveDeadline = nil
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
