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
        /// The profile's bookmarks, for `bookmarkPlan`.
        var bookmarks: [BookmarkNode] = []
        /// Pages visited since an earlier import of this profile (all of them the first time).
        var newHistoryPages: Int?
        /// Already in the target ReArc profile (`BrowserViewModel.installedExtensionsReader`).
        var installedExtensionIDs: Set<String> = []
    }

    private(set) var browsers: [DiscoveredBrowser] = []
    private(set) var isDiscovering = false
    var selection: Source? {
        didSet { if case .profile(let profile) = selection { loadDetail(profile) } }
    }

    private(set) var arc: ArcSidebarImport?
    private(set) var arcProblem: String?
    var arcChoices = ArcImportChoices(spaceIDs: []) {
        didSet { if oldValue != arcChoices { refreshArcSummary() } }
    }
    /// What Import would still add (`SidebarStore.remainingArcImport`). Kept,
    /// not computed per render: each count runs the import on a copy of the
    /// whole sidebar.
    private(set) var arcSummary = ArcImportSummary()
    private(set) var arcSettings = ArcSettingsImport()
    var includeArcSettings = true
    /// Arc's membership card (its title, colours and member-since date).
    private(set) var arcCard: ArcMembershipCardImport?
    var includeArcCard = true

    private(set) var details: [ImportSourceProfile.ID: ProfileDetail] = [:]
    var includeBookmarks = true
    var includeHistory = true
    var includeSearchEngine = true
    var includeExtensions = true
    /// Extensions unticked in the list.
    var skippedExtensions: Set<String> = []
    /// The ReArc profile a Chrome or Brave profile's data goes to.
    var targetProfileID: Profile.ID {
        didSet { if oldValue != targetProfileID { details = [:]; if case .profile(let profile) = selection { loadDetail(profile) } } }
    }

    private(set) var isImporting = false
    /// The last import's outcome, shown under the buttons.
    private var importedArcExtras = false
    private(set) var result: String?

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
            var card: ArcMembershipCardImport?
            if found.contains(where: { $0.browser == .arc && $0.sidebarFile != nil }) {
                do {
                    arc = try ArcSidebarImport.load(from: root)
                } catch {
                    problem = "Arc's sidebar file could not be read."
                }
                settings = ArcSettingsImport.read(readDefaults())
                card = ArcMembershipCardImport.load(from: root)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.browsers = found
                self.arc = arc
                self.arcProblem = problem
                self.arcSettings = settings
                self.arcCard = card
                if let arc, let store = self.model?.store { self.arcChoices = arc.defaultChoices(for: store) }
                self.refreshArcSummary()
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
        browsers.filter(\.isBlocked).map(\.browser)
    }

    func detail(for profile: ImportSourceProfile) -> ProfileDetail? { details[profile.id] }

    func spaceName(_ id: Space.ID) -> String? { model?.store.space(withID: id)?.name }

    /// The profiles the pickers offer.
    var reArcProfiles: [Profile] { model?.store.profiles ?? [] }

    /// What the profile holds and how much of it is new: bookmarks against
    /// the sidebar, history against the import ledger, extensions against
    /// the target profile's own.
    private func loadDetail(_ profile: ImportSourceProfile) {
        guard details[profile.id] == nil else { return }
        let historyThrough = model?.loadImportLedger().historyThrough[profile.id]
        let installed: InstalledExtensionsReader = model?.installedExtensionsReader() ?? { _ in [] }
        let target = targetProfileID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var detail = ProfileDetail(
                inventory: BrowserImportDiscovery.inventory(of: profile),
                extensions: ExtensionInventoryReader.read(profile: profile.url),
                setup: ChromiumProfileSetup.read(profile: profile.url)
            )
            detail.bookmarks = (try? ChromiumBookmarksReader.read(profile.url.appendingPathComponent(ChromiumBookmarksReader.fileName))) ?? []
            detail.newHistoryPages = historyThrough == nil ? detail.inventory.historyPages
                : ChromiumHistoryReader.pageCount(profile.url.appendingPathComponent(ChromiumHistoryReader.fileName), after: historyThrough)
            detail.installedExtensionIDs = installed(target)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.targetProfileID == target else { return }
                self.details[profile.id] = detail
            }
        }
    }

    /// The bookmarks an import would add (none twice; Arc's own only if they
    /// are not copies of its sidebar, `BookmarkImportPlan.arcMirrorNewShare`).
    func bookmarkPlan(for profile: ImportSourceProfile, _ detail: ProfileDetail) -> BookmarkImportPlan {
        model?.store.bookmarkImportPlan(detail.bookmarks, sourceID: profile.id,
                                        arcProfileDirectory: profile.browser == .arc ? profile.directory : nil,
                                        profileID: targetProfileID)
            ?? .make(detail.bookmarks, known: [])
    }

    /// The source's default search engine, when ReArc offers it and it is not already the default.
    func newSearchEngine(_ detail: ProfileDetail) -> SearchEngineChoice? {
        guard let name = detail.setup.searchEngine?.name, let settings = model?.activeSearchEngineSettings,
              settings.isEditable(for: targetProfileID),
              let choice = settings.engines(for: targetProfileID).first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }),
              settings.defaultEngine(for: targetProfileID) != choice.id else { return nil }
        return choice
    }

    private func refreshArcSummary() {
        guard let arc else { arcSummary = ArcImportSummary(); return }
        guard let model else { arcSummary = arc.summary(for: arcChoices); return }
        arcSummary = model.store.remainingArcImport(arc, choices: arcChoices)
    }

    /// The Arc pane's first line: what Import would add, or, once
    /// everything is here, what came over (never "0 spaces" above a list
    /// of spaces that are all in).
    var arcHeadline: String {
        let summary = arcSummary
        // Everything is here already: say so, rather than "0 spaces" over a list of spaces.
        if summary.isEmpty, let arc = arc {
            let imported = arc.export.spaces.filter(isImported)
            if !imported.isEmpty {
                let tabs = imported.reduce(0) { $0 + $1.pinnedTabCount }
                return "\(imported.count) space\(imported.count == 1 ? "" : "s") · \(tabs) pinned tab\(tabs == 1 ? "" : "s") imported"
            }
        }
        var parts = ["\(summary.spaces) space\(summary.spaces == 1 ? "" : "s")",
                     "\(summary.pinnedTabs) pinned tab\(summary.pinnedTabs == 1 ? "" : "s")",
                     "\(summary.favorites) favorite\(summary.favorites == 1 ? "" : "s")"]
        if summary.folders > 0 { parts.insert("\(summary.folders) folder\(summary.folders == 1 ? "" : "s")", at: 2) }
        if summary.todayTabs > 0 { parts.append("\(summary.todayTabs) Today tab\(summary.todayTabs == 1 ? "" : "s")") }
        if summary.newProfiles > 0 { parts.append("\(summary.newProfiles) new profile\(summary.newProfiles == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// The Arc space came over in an earlier import (its source ID is on a space here).
    func isImported(_ space: ArcSidebarSpace) -> Bool {
        let sourceID = "\(space.profile.directory):\(space.id)"
        return model?.store.spaces.contains { $0.arcSourceID == sourceID } == true
    }

    func setSpace(_ id: String, included: Bool) {
        if included { arcChoices.spaceIDs.insert(id) } else { arcChoices.spaceIDs.remove(id) }
    }

    /// Extensions the queue would reinstall from this profile: the queue's
    /// own candidates (never one off in the source, a component or a retired
    /// one, `ExtensionConsolidation`), less the unticked and those the target
    /// profile has.
    func chosenExtensions(_ detail: ProfileDetail) -> [SourceExtension] {
        installableExtensions(detail).filter { !skippedExtensions.contains($0.id) }
    }

    func installableExtensions(_ detail: ProfileDetail) -> [SourceExtension] {
        ExtensionConsolidation(detail.extensions, installedIDs: detail.installedExtensionIDs).candidates
    }

    /// Nothing left to bring from the selection: the button reads Imported.
    var isUpToDate: Bool {
        guard !canImport, !isImporting, let selection else { return false }
        switch selection {
        case .arcSidebar:
            return arc != nil && arcSummary.isEmpty
        case .profile(let profile):
            guard let detail = details[profile.id] else { return false }
            let plan = bookmarkPlan(for: profile, detail)
            return plan.existingSpaceID != nil || plan.mirrorsArcSidebar || detail.newHistoryPages != detail.inventory.historyPages
                || !detail.installedExtensionIDs.isDisjoint(with: detail.extensions.map(\.id))
        }
    }

    var canImport: Bool {
        guard !isImporting, let selection else { return false }
        switch selection {
        case .arcSidebar:
            let hasImportedSpaces = model?.store.spaces.contains { space in
                arc?.export.spaces.contains { "\($0.profile.directory):\($0.id)" == space.arcSourceID } == true
            } == true
            let extras = !importedArcExtras && !hasImportedSpaces &&
                ((includeArcSettings && arcSettings.count > 0) || (includeArcCard && arcCard != nil))
            return !arcSummary.isEmpty || extras
        case .profile(let profile):
            guard let detail = details[profile.id] else { return false }
            return (includeBookmarks && !bookmarkPlan(for: profile, detail).isEmpty)
                || (includeHistory && (detail.newHistoryPages ?? 0) > 0)
                || (includeSearchEngine && newSearchEngine(detail) != nil)
                || (includeExtensions && canReinstallExtensions && !chosenExtensions(detail).isEmpty)
        }
    }

    /// Store installs need the Chromium engine (and its Web Store support).
    var canReinstallExtensions: Bool {
        model?.canOpenBrowserPage(.extensions) ?? false
    }

    var canFinishSetup: Bool { model?.onboardingSetupState.showsMenuItem == true }

    /// An explicit choice for people who no longer want to import, including
    /// those with no source browser. Closing the window alone defers setup.
    func finishWithoutImporting() {
        guard !isImporting, canFinishSetup else { return }
        model?.finishFirstRunOnboarding()
        result = "You're all set."
    }

    func performImport(completion: (() -> Void)? = nil) {
        guard canImport, let model, let selection else { return }
        switch selection {
        case .arcSidebar:
            guard let arc else { return }
            let summary = model.applyArcImport(arc, choices: arcChoices, settings: includeArcSettings ? arcSettings : nil)
            let card = includeArcCard ? arcCard : nil
            if let card { model.importArcMembershipCard(card) }
            importedArcExtras = true
            refreshArcSummary()
            result = BrowserImportSession.describe(summary, settings: includeArcSettings ? arcSettings.count : 0, card: card != nil)
            if canFinishSetup { model.finishFirstRunOnboarding() }
            completion?()
        case .profile(let profile):
            guard let detail = details[profile.id] else { return }
            isImporting = true
            let wantsBookmarks = includeBookmarks && !bookmarkPlan(for: profile, detail).isEmpty
            let wantsHistory = includeHistory && (detail.newHistoryPages ?? 0) > 0
            let engine = includeSearchEngine ? newSearchEngine(detail)?.name : nil
            let chosen = includeExtensions && canReinstallExtensions ? chosenExtensions(detail) : []
            let installed = model.installedExtensionsReader()
            let target = targetProfileID
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let bookmarks = wantsBookmarks
                    ? (try? ChromiumBookmarksReader.read(profile.url.appendingPathComponent(ChromiumBookmarksReader.fileName))) : nil
                let history = wantsHistory
                    ? (try? ChromiumHistoryReader.read(profile.url.appendingPathComponent(ChromiumHistoryReader.fileName))) : nil
                // Read again now: an extension may have finished installing since the pane loaded.
                let installedIDs = chosen.isEmpty ? [] : installed(target)
                let snapshot = Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0.origin) })
                let consented = chosen.isEmpty ? [] : ExtensionInventoryReader.consented(
                    ExtensionInventoryReader.read(profile: profile.url), snapshot: snapshot)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    var lines = model.applyChromiumImport(from: profile, bookmarks: bookmarks, history: history,
                                                          searchEngine: engine, into: target)
                    let queue = ExtensionReinstallQueue(consented, into: target, installedIDs: installedIDs)
                    if !queue.isFinished {
                        model.queueExtensionReinstall(queue, from: profile.browser.name,
                                                      skipped: ExtensionConsolidation(consented, installedIDs: installedIDs).skipped)
                        model.installPendingExtensions()
                        lines.append("\(queue.items.count) extension\(queue.items.count == 1 ? "" : "s") installing in the background")
                    }
                    self.result = lines.isEmpty ? "Nothing new to import." : lines.joined(separator: " · ")
                    if !lines.isEmpty, self.canFinishSetup { model.finishFirstRunOnboarding() }
                    self.isImporting = false
                    // The pane shows what is left (nothing, usually) against the new state.
                    self.details[profile.id] = nil
                    self.loadDetail(profile)
                    completion?()
                }
            }
        }
    }

    static func describe(_ summary: ArcImportSummary, settings: Int, card: Bool = false) -> String {
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
        if card { parts.append("your membership card") }
        return parts.isEmpty ? "Nothing was imported." : "Imported " + parts.joined(separator: ", ")
    }

    // Extension installs continue independently of the Import window.

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

    /// A Chrome, Brave or Arc profile's bookmarks (a space in `profileID`,
    /// made by the first import and added to by later ones), history
    /// (command-bar suggestions) and search engine, each only what an earlier
    /// import did not bring. Returns one line per thing imported.
    func applyChromiumImport(from source: ImportSourceProfile, bookmarks: [BookmarkNode]?, history: [VisitRecord]?,
                             searchEngine: String?, into profileID: Profile.ID) -> [String] {
        var lines: [String] = []
        if let bookmarks, let result = store.importBookmarks(bookmarks, spaceName: "\(source.browser.name) – \(source.name)",
                                                             profileID: profileID, sourceID: source.id,
                                                             arcProfileDirectory: source.browser == .arc ? source.directory : nil) {
            selectSpace(result.space.id)
            lines.append("\(result.tabs) bookmark\(result.tabs == 1 ? "" : "s") in \(result.space.name)")
        }
        if let history {
            let new = loadImportLedger().newHistory(history, from: source.id)
            if !new.isEmpty {
                let added = visitHistory.merge(new)
                scheduleVisitHistorySave()
                recordImportedHistory(new, from: source.id)
                if added > 0 { lines.append("\(added) history page\(added == 1 ? "" : "s")") }
            }
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

    /// Failure fallback, in a space of the item's profile.
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
