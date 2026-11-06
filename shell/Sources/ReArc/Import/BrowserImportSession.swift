import AppKit
import SidebarModel

/// The File › Import from Arc, Chrome or Brave… window's state
/// (PROFILE-IMPORT.md). Discovery and every file read run off the main
/// thread; nothing is imported until Import is clicked, and nothing in
/// the source browser is written to or locked.
@Observable
final class BrowserImportSession {
    enum Source: Hashable {
        /// Arc's spaces, pinned tabs, folders and favorites.
        case arcSidebar
        case profile(ImportSourceProfile)
    }

    struct ProfileDetail {
        var inventory: ImportSourceInventory
        var extensions: [SourceExtension]
        var setup: ChromiumProfileSetup
    }

    private(set) var browsers: [DiscoveredBrowser] = []
    private(set) var isDiscovering = false
    var selection: Source? {
        didSet { if case .profile(let profile) = selection { loadDetail(profile) } }
    }

    private(set) var arc: ArcSidebarImport?
    private(set) var arcProblem: String?
    var arcChoices = ArcImportChoices(spaceIDs: [])
    private(set) var arcSettings = ArcSettingsImport()
    var includeArcSettings = true

    private(set) var details: [ImportSourceProfile.ID: ProfileDetail] = [:]
    var includeBookmarks = true
    var includeHistory = true
    var includeSearchEngine = true
    var includeExtensions = true
    /// Extensions unticked in the list.
    var skippedExtensions: Set<String> = []
    /// The ReArc profile a Chrome or Brave profile's data goes to.
    var targetProfileID: Profile.ID

    private(set) var isImporting = false
    /// The last import's outcome, shown under the buttons.
    private(set) var result: String?
    /// Extensions waiting to be reinstalled, one store page at a time.
    var reinstall: ExtensionReinstallQueue?

    @ObservationIgnored let applicationSupport: URL
    /// Arc's preferences, read-only (a dictionary in tests).
    @ObservationIgnored let arcDefaults: () -> [String: Any]
    @ObservationIgnored private weak var model: BrowserViewModel?

    init(model: BrowserViewModel,
         applicationSupport: URL = BrowserImportDiscovery.applicationSupport,
         arcDefaults: @escaping () -> [String: Any] = {
             UserDefaults(suiteName: ImportBrowser.arc.defaultsDomain)?.dictionaryRepresentation() ?? [:]
         }) {
        self.model = model
        self.applicationSupport = applicationSupport
        self.arcDefaults = arcDefaults
        targetProfileID = model.store.activeProfileID
    }

    /// Looks for browsers once; the window calls it when it opens.
    func discover(completion: (() -> Void)? = nil) {
        guard !isDiscovering else { return }
        isDiscovering = true
        let root = applicationSupport
        let readDefaults = arcDefaults
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = BrowserImportDiscovery.discover(in: root)
            var arc: ArcSidebarImport?
            var problem: String?
            var settings = ArcSettingsImport()
            if found.contains(where: { $0.browser == .arc && $0.sidebarFile != nil }) {
                do {
                    arc = try ArcSidebarImport.load(from: root)
                } catch {
                    problem = "Arc's sidebar file could not be read."
                }
                settings = ArcSettingsImport.read(readDefaults())
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.browsers = found
                self.arc = arc
                self.arcProblem = problem
                self.arcSettings = settings
                if let arc, let store = self.model?.store { self.arcChoices = arc.defaultChoices(for: store) }
                self.details = [:]
                self.isDiscovering = false
                if let selection = self.selection, self.sources.contains(selection) {
                    if case .profile(let profile) = selection { self.loadDetail(profile) }
                } else {
                    self.selection = self.sources.first
                }
                completion?()
            }
        }
    }

    /// The sidebar list: Arc's sidebar first, then every profile.
    var sources: [Source] {
        var out: [Source] = []
        for browser in browsers {
            if browser.browser == .arc, browser.sidebarFile != nil { out.append(.arcSidebar) }
            out += browser.profiles.map(Source.profile)
        }
        return out
    }

    var unreadableBrowsers: [ImportBrowser] {
        browsers.filter { $0.status == .notReadable }.map(\.browser)
    }

    func detail(for profile: ImportSourceProfile) -> ProfileDetail? { details[profile.id] }

    /// The profiles the pickers offer.
    var reArcProfiles: [Profile] { model?.store.profiles ?? [] }

    private func loadDetail(_ profile: ImportSourceProfile) {
        guard details[profile.id] == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detail = ProfileDetail(
                inventory: BrowserImportDiscovery.inventory(of: profile),
                extensions: ExtensionInventoryReader.read(profile: profile.url),
                setup: ChromiumProfileSetup.read(profile: profile.url)
            )
            DispatchQueue.main.async { [weak self] in self?.details[profile.id] = detail }
        }
    }

    var arcSummary: ArcImportSummary { arc?.summary(for: arcChoices) ?? ArcImportSummary() }

    func setSpace(_ id: String, included: Bool) {
        if included { arcChoices.spaceIDs.insert(id) } else { arcChoices.spaceIDs.remove(id) }
    }

    /// Extensions the queue would reinstall from this profile.
    func chosenExtensions(_ detail: ProfileDetail) -> [SourceExtension] {
        detail.extensions.filter { $0.canReinstall && !skippedExtensions.contains($0.id) }
    }

    var canImport: Bool {
        guard !isImporting, let selection else { return false }
        switch selection {
        case .arcSidebar:
            return !arcSummary.isEmpty || (includeArcSettings && arcSettings.count > 0)
        case .profile(let profile):
            guard let detail = details[profile.id] else { return false }
            return (includeBookmarks && detail.inventory.bookmarks > 0)
                || (includeHistory && (detail.inventory.historyPages ?? 0) > 0)
                || (includeSearchEngine && detail.setup.searchEngine != nil)
                || (includeExtensions && canReinstallExtensions && !chosenExtensions(detail).isEmpty)
        }
    }

    /// Store installs need the Chromium engine (and its Web Store support).
    var canReinstallExtensions: Bool {
        model?.canOpenBrowserPage(.extensions) ?? false
    }

    func performImport(completion: (() -> Void)? = nil) {
        guard canImport, let model, let selection else { return }
        switch selection {
        case .arcSidebar:
            guard let arc else { return }
            let summary = model.applyArcImport(arc, choices: arcChoices, settings: includeArcSettings ? arcSettings : nil)
            result = BrowserImportSession.describe(summary, settings: includeArcSettings ? arcSettings.count : 0)
            completion?()
        case .profile(let profile):
            guard let detail = details[profile.id] else { return }
            isImporting = true
            let wantsBookmarks = includeBookmarks && detail.inventory.bookmarks > 0
            let wantsHistory = includeHistory && (detail.inventory.historyPages ?? 0) > 0
            let engine = includeSearchEngine ? detail.setup.searchEngine?.name : nil
            let queue = includeExtensions && canReinstallExtensions
                ? ExtensionReinstallQueue(chosenExtensions(detail), into: targetProfileID) : nil
            let target = targetProfileID
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let bookmarks = wantsBookmarks
                    ? (try? ChromiumBookmarksReader.read(profile.url.appendingPathComponent(ChromiumBookmarksReader.fileName))) : nil
                let history = wantsHistory
                    ? (try? ChromiumHistoryReader.read(profile.url.appendingPathComponent(ChromiumHistoryReader.fileName))) : nil
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    var lines = model.applyChromiumImport(from: profile, bookmarks: bookmarks, history: history,
                                                          searchEngine: engine, into: target)
                    if let queue, !queue.isFinished {
                        self.reinstall = queue
                        lines.append("\(queue.items.count) extension\(queue.items.count == 1 ? "" : "s") to reinstall")
                    }
                    self.result = lines.isEmpty ? "Nothing was imported." : lines.joined(separator: " · ")
                    self.isImporting = false
                    completion?()
                }
            }
        }
    }

    static func describe(_ summary: ArcImportSummary, settings: Int) -> String {
        var parts: [String] = []
        func add(_ count: Int, _ noun: String) {
            if count > 0 { parts.append("\(count) \(noun)\(count == 1 ? "" : "s")") }
        }
        add(summary.spaces, "space")
        add(summary.pinnedTabs, "pinned tab")
        add(summary.todayTabs, "Today tab")
        add(summary.favorites, "favorite")
        add(summary.newProfiles, "new profile")
        add(settings, "setting")
        return parts.isEmpty ? "Nothing was imported." : "Imported " + parts.joined(separator: ", ")
    }

    // MARK: Extension reinstall

    /// Opens the current extension's store page (or chrome://extensions and
    /// its folder, for an unpacked one) in a space of the target profile.
    func openCurrentExtension() {
        guard let item = reinstall?.current, let model else { return }
        model.openExtensionForReinstall(item)
    }

    func nextExtension() {
        reinstall?.advance()
        if reinstall?.isFinished == true { reinstall = nil }
    }
}

extension BrowserViewModel {
    /// File › Import from Arc, Chrome or Brave…
    func showBrowserImport() {
        if let window = browserImportWindow {
            window.showWindow(nil)
            return
        }
        let window = BrowserImportWindowController(session: BrowserImportSession(model: self))
        browserImportWindow = window
        window.showWindow(nil)
    }

    /// Arc's sidebar into the store, then its settings. Returns the counts.
    @discardableResult
    func applyArcImport(_ source: ArcSidebarImport, choices: ArcImportChoices, settings: ArcSettingsImport?) -> ArcImportSummary {
        let summary = store.importArcSidebar(source, choices: choices)
        if let settings { applyArcSettings(settings) }
        if summary.spaces > 0 || summary.favorites > 0 {
            loadSelectedIfNeeded()
            showToast(BrowserImportSession.describe(summary, settings: 0), systemImage: "square.and.arrow.down")
        }
        return summary
    }

    func applyArcSettings(_ settings: ArcSettingsImport) {
        if let value = settings.warnBeforeQuitting { warnBeforeQuitting = value }
        if let value = settings.restoreWindows { restoresWindows = value }
        if let value = settings.externalLinkDestination { externalLinkDestination = value }
        if let value = settings.littleArcArchive { littleArcArchiveAfter = value }
        if let value = settings.autoArchive { setAutoArchiveThreshold(value) }
    }

    /// A Chrome or Brave profile's bookmarks (a new space in `profileID`),
    /// history (command-bar suggestions) and search engine. Returns one
    /// line per thing imported.
    func applyChromiumImport(from source: ImportSourceProfile, bookmarks: [BookmarkNode]?, history: [VisitRecord]?,
                             searchEngine: String?, into profileID: Profile.ID) -> [String] {
        var lines: [String] = []
        if let bookmarks, let result = store.importBookmarks(bookmarks, spaceName: "\(source.browser.name) – \(source.name)",
                                                             profileID: profileID) {
            selectSpace(result.space.id)
            lines.append("\(result.tabs) bookmark\(result.tabs == 1 ? "" : "s") in \(result.space.name)")
        }
        if let history, !history.isEmpty {
            let added = visitHistory.merge(history)
            scheduleVisitHistorySave()
            lines.append("\(added) history page\(added == 1 ? "" : "s")")
        }
        if let searchEngine, let settings = activeSearchEngineSettings,
           let choice = settings.engines(for: profileID).first(where: { $0.name.localizedCaseInsensitiveCompare(searchEngine) == .orderedSame }),
           settings.isEditable(for: profileID) {
            settings.setDefaultEngine(choice.id, for: profileID)
            lines.append("search with \(choice.name)")
        }
        if !lines.isEmpty { showToast("Imported " + lines.joined(separator: ", "), systemImage: "square.and.arrow.down") }
        return lines
    }

    /// One reinstall step, in a space of the item's profile.
    func openExtensionForReinstall(_ item: ExtensionReinstallQueue.Item) {
        if store.activeProfileID != item.profileID { store.selectProfile(item.profileID) }
        switch item.origin {
        case .webStore:
            openPageInNewTab(ExtensionReinstallQueue.storeURL(for: item.id), title: item.name)
        case .unpacked(let path):
            // Developer mode › Load unpacked, then pick the folder Finder shows.
            openBrowserPage(.extensions)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
        case .other:
            break
        }
    }
}
