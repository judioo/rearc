import AppKit
import Onboarding
import SidebarModel

/// The sunrise onboarding inside ReArc (shell/Sources/Onboarding). On a
/// first run — no sidebar file yet, or an onboarding a quit or crash cut
/// short (`SidebarFilePersistence.onboardingMarkerURL`) — it takes over the screen before the
/// browser is seen, imports for real when asked, names and colours the main
/// profile, shapes the spaces, and then lets go over the real window, which
/// it has put exactly where the drawn one formed.
///
/// `--onboarding` forces it on an existing install as a rehearsal: the
/// same flow, nothing imported or changed. For a real first run on a test
/// install, launch with `REARC_DATA_DIR` set to an empty folder.
/// `--no-onboarding` skips it, and the first run is over on the starter's
/// one empty space; “Onboard later” leaves a reminder inside the browser.
@MainActor
final class FirstRunOnboarding: OnboardingHost {
    enum Kind: Equatable { case firstRun, rehearsal, replay }

    static let forceFlag = "--onboarding"
    static let skipFlag = "--no-onboarding"

    /// Self-tests, benches and launch probes drive the UI themselves.
    static func isAutomated(_ arguments: [String]) -> Bool {
        arguments.contains { arg in
            arg == EngineLaunchOptions.selfTestFlag || arg.hasPrefix(EngineLaunchOptions.benchFlag)
                || arg.hasPrefix(EngineLaunchOptions.launchProbeFlagPrefix)
        } || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// For this launch, from its arguments.
    static func kind(isFirstRun: Bool, arguments: [String] = CommandLine.arguments) -> Kind? {
        kind(isFirstRun: isFirstRun, arguments: arguments, automated: isAutomated(arguments))
    }

    /// A relaunch for a privacy permission left a ticket: the onboarding
    /// resumes at its browser step (a rehearsal as a rehearsal).
    static var resumeTicket: OnboardingResumeTicket? {
        OnboardingResumeTicket.peek(bundlePath: Bundle.main.bundlePath)
    }

    /// This copy's ticket, once: the onboarding about to start resumes from it.
    static func takeResumeTicket(at url: URL = OnboardingResumeTicket.defaultURL) -> OnboardingResumeTicket? {
        OnboardingResumeTicket.take(at: url, bundlePath: Bundle.main.bundlePath)
    }

    /// At process start, before anything reads or writes `ShellDataLocation`:
    /// what a fresh resume ticket asks of this launch. A reopen from System
    /// Settings carries no `REARC_DATA_DIR` or arguments, so the ticket,
    /// outside any data folder, says where the onboarding was; only this very
    /// bundle honours it, and a shipped one only on its own data folder
    /// (RC-0.1.0-602 T-06). Logs which path relaunched to `relaunch.log` beside it.
    static func applyResumeTicketAtLaunch(arguments: [String] = CommandLine.arguments,
                                          environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !isAutomated(arguments) else { return }
        let by = environment[ReArcRelaunch.relaunchedByKey]
        unsetenv(ReArcRelaunch.relaunchedByKey)
        let ticket = OnboardingResumeTicket.current()
        guard ticket != nil || by != nil else { return }
        let here = Bundle.main.bundlePath
        let action = OnboardingResumeTicket.launchAction(environment: environment, bundlePath: here, ticket: ticket)
        OnboardingResumeTicket.log("launch of \(here), opened by \(by ?? "macOS or the person (Quit & Reopen, Finder, open)"): \(action)")
        switch action {
        case .none:
            break
        case .discard:
            OnboardingResumeTicket.remove()
        case .adopt(let dir):
            if let dir { setenv(ShellDataLocation.environmentKey, dir, 1) }
        }
    }

    /// Whether this launch runs it, and how.
    static func kind(isFirstRun: Bool, arguments: [String], automated: Bool) -> Kind? {
        if automated || arguments.contains(skipFlag) { return nil }
        if arguments.contains(forceFlag) { return isFirstRun ? .firstRun : .rehearsal }
        return isFirstRun ? .firstRun : nil
    }

    /// At launch, for `model`. A first run is marked before the onboarding
    /// can change anything, so a quit or crash leaves the next launch a first
    /// run too; one this launch skips (`--no-onboarding`) is over. Automated
    /// launches leave the marker alone.
    static func forLaunch(_ model: BrowserViewModel, arguments: [String] = CommandLine.arguments) -> Kind? {
        let automated = isAutomated(arguments)
        let resumesRehearsal = !automated && resumeTicket?.isRehearsal == true
        return forLaunch(model, arguments: resumesRehearsal ? arguments + [forceFlag] : arguments, automated: automated)
    }

    static func forLaunch(_ model: BrowserViewModel, arguments: [String], automated: Bool) -> Kind? {
        let kind = kind(isFirstRun: model.isFirstRun, arguments: arguments, automated: automated)
        if kind == .firstRun {
            model.beginFirstRunOnboarding()
        } else if model.isFirstRun, !automated {
            model.finishFirstRunOnboarding()
        }
        // A ticket resumes only an onboarding this launch runs (T-06).
        if kind == nil, !automated { OnboardingResumeTicket.remove() }
        return kind
    }

    let kind: Kind
    private weak var model: BrowserViewModel?
    private let browserWindows: () -> [NSWindow]
    private var takeover: SunriseTakeover?
    private var hidden: [NSWindow] = []
    /// The untouched starter's space and favorites, cleared once the
    /// person's own are in (first run only). Recorded in the onboarding
    /// marker when the first run began, so an onboarding resumed after a quit
    /// or crash still replaces it, though its import made the sidebar no
    /// longer look like a starter. A sidebar sync adopted is kept.
    private var starterSpaceIDs: [Space.ID] = []
    private var starterFavoriteIDs: [Tab.ID] = []
    private var mainProfileID: Profile.ID?
    private var outcome: OnboardingImportOutcome?
    private var onDone: (() -> Void)?

    init(kind: Kind, model: BrowserViewModel, browserWindows: @escaping () -> [NSWindow]) {
        self.kind = kind
        self.model = model
        self.browserWindows = browserWindows
    }

    private var applies: Bool { kind == .firstRun }

    func start(onDone: (() -> Void)? = nil) {
        guard let model, takeover == nil else { return }
        self.onDone = onDone
        if kind != .replay {
            // The browser waits under the night; it comes back where the drawn window forms.
            hidden = browserWindows().filter(\.isVisible)
            hidden.forEach { $0.orderOut(nil) }
        }
        if applies {
            mainProfileID = model.store.activeProfileID
            let starter = model.onboardingStarter
            starterSpaceIDs = starter.spaceIDs
            starterFavoriteIDs = starter.favoriteIDs
            // Nothing installs, and no install toast plays, under the sunrise.
            model.holdExtensionFeedback()
        }
        let takeover = SunriseTakeover(host: self, mode: kind == .replay ? .replay : .firstRun)
        self.takeover = takeover
        takeover.present { }
        if kind != .replay, let ticket = Self.takeResumeTicket() {
            OnboardingResumeTicket.log("onboarding resumes at the browser step (ticket \(ticket.nonce))")
            takeover.player.resumeAtBrowsers(name: ticket.name, colourIndex: ticket.colourIndex)
        }
    }

    // MARK: OnboardingHost

    /// ReArc's importer reads Arc's sidebar (spaces, pinned tabs, folders,
    /// favorites) and Chromium profiles' bookmarks and history, and queues
    /// extensions to reinstall from the Web Store, which needs the Chromium
    /// engine. Passwords are never offered (Act 2 says why).
    var importCategories: [ImportCategory] {
        [.spaces, .bookmarks, .history] + (canReinstallExtensions ? [.extensions] : [])
    }

    private var canReinstallExtensions: Bool { model?.canOpenBrowserPage(.extensions) ?? false }

    func discoverSources(_ done: @escaping (BrowserScan) -> Void) {
        let extensions = canReinstallExtensions
        let installed = model?.installedExtensionsReader()
        let main = model?.store.activeProfileID
        DispatchQueue.global(qos: .userInitiated).async {
            let root = BrowserImportDiscovery.applicationSupport
            let scan = BrowserScanner.survey(applicationSupport: root, installed: { ImportPrivacyAccess.isInstalled($0) })
            let found = OnboardingImportPlan.counted(scan.sources, applicationSupport: root, extensions: extensions,
                                                     installedIDs: main.flatMap { id in installed?(id) } ?? [])
            DispatchQueue.main.async { done(OnboardingImportPlan.withEmptyBrowsers(scan, counted: found).trimmed()) }
        }
    }

    /// A relaunch from Act 2 comes back to the sunrise: `onboarding-pending` (first run) or `--onboarding`.
    var canRelaunch: Bool { ImportPrivacyAccess.canRelaunch && kind != .replay }

    func relaunchForAccess() {
        guard canRelaunch else { return }
        ImportPrivacyAccess.relaunch(reopenImport: false)
    }

    var macOSReopensThisCopy: Bool { ImportPrivacyAccess.macOSReopensThisCopy }

    func saveResumePoint(name: String, colourIndex: Int) {
        guard kind != .replay else { return }
        let dir = ShellDataLocation.isOverridden ? ShellDataLocation.root.path : nil
        let ticket = OnboardingResumeTicket(dataDirectory: dir, bundlePath: Bundle.main.bundlePath, name: name, colourIndex: colourIndex,
                                            isRehearsal: kind == .rehearsal)
        if dir != nil { ticket.bindDataDirectory(ShellDataLocation.root) }
        ticket.write()
        OnboardingResumeTicket.log("resume point saved (ticket \(ticket.nonce), data \(dir ?? "default"))")
    }

    func bring(_ sources: [ImportSource], categories: [ImportCategory], done: @escaping (OnboardingImportOutcome) -> Void) {
        guard applies, model != nil else {
            // A rehearsal shows what would come over (Act 2's own sum) and changes nothing.
            let seeds = categories.contains(.spaces) ? sources.flatMap(\.spaces) : []
            done(OnboardingImportOutcome(totals: ImportSource.totals(sources, categories: categories), spaces: seeds))
            return
        }
        let plan = OnboardingImportPlan(sources: sources, categories: categories)
        // History merges off the main thread too: each merge rebuilds the
        // command bar's search index, seconds for several profiles.
        let history = model?.visitHistory ?? VisitHistory()
        let installed = model?.installedExtensionsReader()
        let main = mainProfileID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var read = plan.read(applicationSupport: BrowserImportDiscovery.applicationSupport)
            read.mergeHistory(into: history)
            // An interrupted onboarding may have installed some already.
            if plan.extensions, let installed, let main { read.installedExtensionIDs = installed(main) }
            DispatchQueue.main.async {
                guard let self, let model = self.model else { return }
                let result = OnboardingImportPlan.apply(read, model: model, replacingFavorites: self.starterFavoriteIDs)
                self.outcome = result
                done(result)
            }
        }
    }

    func apply(_ result: OnboardingResult) {
        guard applies, let model, let main = mainProfileID else { return }
        // The starter goes; the person's own spaces stay.
        let first = OnboardingApplier.apply(result, to: model.store, mainProfileID: main,
                                            replacing: starterSpaceIDs, starterFavorites: starterFavoriteIDs)
        // Act 1's name goes on the membership card.
        model.recordOnboardingName(result.name)
        model.reconcileEngineOwnership()
        if let first { model.selectSpace(first) }
        // The sidebar's own count: Act 3 shows at most `Act3Timeline.maxSpaces`,
        // and the spaces past those stay as they came.
        model.openPageInNewTab(WelcomePage.write(name: result.name, colour: result.colour,
                                                 spaces: model.store.spaces.count, imported: outcome?.totals),
                               title: "Welcome to ReArc")
    }

    func revealBrowser(in frame: NSRect, below overlay: NSWindow) {
        guard kind != .replay else { return }
        for (i, window) in hidden.enumerated() {
            if i == 0, applies { window.setFrame(frame, display: true) }
            window.order(.below, relativeTo: overlay.windowNumber)
        }
        if hidden.isEmpty, applies, let window = browserWindows().first {
            window.setFrame(frame, display: true)
            window.order(.below, relativeTo: overlay.windowNumber)
        }
    }

    func onboardingFinished() {
        OnboardingResumeTicket.remove()
        if kind != .replay {
            // Rehearsal (or an early quit of Act 4): nothing left hidden.
            for window in hidden where !window.isVisible { window.orderFront(nil) }
            hidden.first?.makeKeyAndOrderFront(nil)
        }
        hidden = []
        // The player's own dismiss goes through a weak reference that dropping
        // the takeover here clears; without this the clear overlay stays on top.
        takeover?.dismiss()
        takeover = nil
        if applies {
            model?.finishFirstRunOnboarding()
            // The browser is on screen: installs start, and their toasts show.
            model?.releaseExtensionFeedback()
            model?.offerPendingExtensionReinstall()
        }
        onDone?()
    }

    /// “Onboard later”: the browser comes back with a persistent setup
    /// reminder. An interruption without this choice still resumes the sunrise.
    func onboardingDeferred() {
        OnboardingResumeTicket.remove()
        for window in hidden where !window.isVisible { window.orderFront(nil) }
        hidden.first?.makeKeyAndOrderFront(nil)
        hidden = []
        takeover?.dismiss()
        takeover = nil
        if applies {
            model?.deferFirstRunOnboarding()
            // What an earlier, interrupted import queued goes on as it would have.
            model?.releaseExtensionFeedback()
            model?.installPendingExtensions()
        }
        onDone?()
    }
}

/// What Act 2 asked for, read off the main thread and applied on it. Act 2's
/// counts come from the same readers (`counted`), so its line, the
/// rehearsal's totals and the real outcome agree category by category.
struct OnboardingImportPlan: Sendable {
    var arcDirectories: Set<String>
    var chromium: [(browser: ImportBrowser, directory: String)]
    var spaces: Bool
    var bookmarks: Bool
    var history: Bool
    var extensions: Bool
    var extensionOrigins: [String: [String: SourceExtension.Origin]]

    init(sources: [ImportSource], categories: [ImportCategory]) {
        arcDirectories = Set(sources.filter { $0.importBrowser == .arc }.map(\.directory))
        chromium = sources.compactMap { s in
            s.importBrowser.map { ($0, s.directory) }
        }
        // A profile listed twice keeps its first snapshot rather than trapping.
        extensionOrigins = Dictionary(sources.compactMap { source in
            source.importBrowser.map {
                ("\($0.rawValue)/\(source.directory)", source.extensionOrigins)
            }
        }, uniquingKeysWith: { first, _ in first })
        spaces = categories.contains(.spaces)
        bookmarks = categories.contains(.bookmarks)
        history = categories.contains(.history)
        extensions = categories.contains(.extensions)
    }

    struct Read: @unchecked Sendable {
        /// Only the chosen Arc profiles' spaces and favorites.
        var arc: ArcSidebarImport?
        var arcSettings: ArcSettingsImport?
        /// Arc's membership card comes with its spaces.
        var arcCard: ArcMembershipCardImport?
        var profiles: [(profile: ImportSourceProfile, bookmarks: [BookmarkNode]?, history: [VisitRecord]?)]
        /// In source order; the queue keeps the reinstallable ones, each once.
        var extensions: [(browser: ImportBrowser, extension: SourceExtension)] = []
        /// Every profile's history merged into `historyBase` off the main
        /// thread; `apply` takes it if the model's history is still the base.
        var historyBase: VisitHistory?
        var mergedHistory: VisitHistory?
        /// Already in the main profile; never queued again.
        var installedExtensionIDs: Set<String> = []

        var importedHistory: [VisitRecord] { profiles.flatMap { $0.history ?? [] } }

        mutating func mergeHistory(into base: VisitHistory) {
            let imported = importedHistory
            guard !imported.isEmpty else { return }
            var merged = base
            merged.merge(imported)
            historyBase = base
            mergedHistory = merged
        }
    }

    /// `arcDefaults`: Arc's preferences, read-only (a dictionary in tests).
    func read(applicationSupport root: URL, arcDefaults: () -> [String: Any] = {
        UserDefaults(suiteName: ImportBrowser.arc.defaultsDomain)?.dictionaryRepresentation() ?? [:]
    }) -> Read {
        let found = BrowserImportDiscovery.discover(in: root, installed: { _ in false })
        var arc: ArcSidebarImport?
        var settings: ArcSettingsImport?
        var card: ArcMembershipCardImport?
        if spaces, !arcDirectories.isEmpty {
            arc = (try? ArcSidebarImport.load(from: root))?.only(directories: arcDirectories)
            settings = ArcSettingsImport.read(arcDefaults())
            card = ArcMembershipCardImport.load(from: root)
        }
        var profiles: [(ImportSourceProfile, [BookmarkNode]?, [VisitRecord]?)] = []
        var extensions: [(ImportBrowser, SourceExtension)] = []
        for browser in found {
            for profile in browser.profiles where chromium.contains(where: { $0.browser == profile.browser && $0.directory == profile.directory }) {
                if bookmarks || history {
                    profiles.append((profile, bookmarks ? Self.bookmarks(profile) : nil, history ? Self.history(profile) : nil))
                }
                if self.extensions, profile.browser.family == .chromium {
                    let snapshot = extensionOrigins["\(profile.browser.rawValue)/\(profile.directory)"] ?? [:]
                    extensions += ExtensionInventoryReader.consented(ExtensionInventoryReader.read(profile: profile.url),
                                                                    snapshot: snapshot).map { (profile.browser, $0) }
                }
            }
        }
        return Read(arc: arc, arcSettings: settings, arcCard: card, profiles: profiles, extensions: extensions)
    }

    static func bookmarks(_ profile: ImportSourceProfile) -> [BookmarkNode]? {
        try? profile.readBookmarks()
    }

    static func history(_ profile: ImportSourceProfile) -> [VisitRecord]? {
        try? profile.readHistory()
    }

    /// A browser whose every profile `counted` left out has nothing to bring: Act 2 names it as empty.
    static func withEmptyBrowsers(_ scan: BrowserScan, counted: [ImportSource]) -> BrowserScan {
        var result = BrowserScan(sources: counted, pending: scan.pending)
        let kept = Set(counted.compactMap(\.importBrowser))
        for source in scan.sources {
            guard let browser = source.importBrowser, !kept.contains(browser),
                  !result.pending.contains(where: { $0.browser == browser }) else { continue }
            result.pending.append(PendingBrowser(browser: browser, state: .noData))
        }
        return result
    }

    /// The scanner's sources, each counted as the import would bring it:
    /// Arc's spaces, pinned tabs and favorites from its sidebar reader,
    /// bookmarks and pages from the readers `read` uses, and extensions as
    /// the reinstall queue would take them, by id and origin. The scanner's
    /// password-presence flag stays, only to say they stay behind. A source with nothing to
    /// bring is left out.
    /// Arc's bookmarks count only what its spaces don't already bring
    /// (`BookmarkImportPlan.arcMirrorNewShare`); `bookmarksWithoutSpaces`
    /// keeps the full count for when its spaces stay behind. `installedIDs`:
    /// extensions the main profile already has, which don't count.
    static func counted(_ sources: [ImportSource], applicationSupport root: URL, extensions: Bool,
                        installedIDs: Set<String> = []) -> [ImportSource] {
        let profiles = BrowserImportDiscovery.discover(in: root, installed: { _ in false }).flatMap(\.profiles)
        let arc = sources.contains { $0.importBrowser == .arc } ? try? ArcSidebarImport.load(from: root) : nil
        return sources.compactMap { source in
            var stats = ImportStats()
            var counted = source
            counted.extensionIDs = []
            counted.extensionOrigins = [:]
            if source.importBrowser == .arc, let arc = arc?.only(directories: [source.directory]) {
                stats.spaces = arc.export.spaces.count
                stats.tabs = arc.export.spaces.reduce(0) { $0 + $1.pinnedTabCount } + arc.favoritesToImport()
            }
            if let browser = source.importBrowser,
               let profile = profiles.first(where: { $0.browser == browser && $0.directory == source.directory }) {
                let nodes = bookmarks(profile) ?? []
                stats.bookmarks = nodes.reduce(0) { $0 + $1.linkCount }
                if browser == .arc, let arc = arc?.only(directories: [source.directory]), !arc.export.spaces.isEmpty {
                    counted.bookmarksWithoutSpaces = stats.bookmarks
                    stats.bookmarks = BookmarkImportPlan.make(nodes, known: arc.bookmarkKeys(directory: source.directory),
                                                              mirrorsArcSidebar: true).newLinks
                }
                stats.pages = history(profile)?.count ?? 0
                if extensions, browser.family == .chromium {
                    let items = ExtensionReinstallQueue(ExtensionInventoryReader.read(profile: profile.url), into: UUID(),
                                                        installedIDs: installedIDs).items
                    counted.extensionIDs = items.map(\.id)
                    counted.extensionOrigins = Dictionary(items.map { ($0.id, $0.origin) }, uniquingKeysWith: { first, _ in first })
                    stats.extensions = counted.extensionIDs.count
                }
            }
            guard stats != ImportStats() || (counted.bookmarksWithoutSpaces ?? 0) > 0 else { return nil }
            stats.passwords = source.stats.passwords
            counted.stats = stats
            return counted
        }
    }

    /// Into the store, quietly (no toasts: the onboarding is the feedback).
    /// Extensions install in the background when the browser is revealed.
    /// `replacingFavorites` (the starter's) go before Arc's favorites come
    /// in, so none of Arc's is skipped as already there and then cleared.
    ///
    /// Run again on what an interrupted onboarding brought, it brings only
    /// what is missing (each import's ledger: Arc's source IDs, a bookmark
    /// space's `bookmarkSourceID`, the history ledger, installed extensions)
    /// and reports as a single run would: Act 3 gets every space the import
    /// holds, not only the ones made this time, and the totals count the
    /// sources, as Act 2's line (`counted`) does.
    @MainActor
    static func apply(_ read: Read, model: BrowserViewModel, replacingFavorites starter: [Tab.ID] = []) -> OnboardingImportOutcome {
        let store = model.store
        let before = Set(store.spaces.map(\.id))
        let main = store.activeProfileID
        var totals = ImportStats()
        var brought = Set<Space.ID>()
        if let arc = read.arc {
            if arc.favoritesToImport() > 0 {
                for id in starter where store.tab(withID: id) != nil { store.closeTab(id) }
            }
            store.importArcSidebar(arc, choices: arc.defaultChoices(for: store))
            if let settings = read.arcSettings { model.applyArcSettings(settings) }
            if let card = read.arcCard { model.importArcMembershipCard(card) }
            let sourceIDs = Set(arc.export.spaces.map { "\($0.profile.directory):\($0.id)" })
            brought.formUnion(store.spaces.filter { $0.arcSourceID.map(sourceIDs.contains) == true }.map(\.id))
            totals.spaces = arc.export.spaces.count
            totals.tabs = arc.export.spaces.reduce(0) { $0 + $1.pinnedTabCount } + arc.favoritesToImport()
        }
        for (profile, bookmarks, history) in read.profiles {
            if let bookmarks {
                // Arc's own bookmarks copy the sidebar just imported: they add a space only if enough is new.
                store.importBookmarks(bookmarks, spaceName: "\(profile.browser.name) – \(profile.name)", profileID: main,
                                      sourceID: profile.id, arcProfileDirectory: profile.browser == .arc ? profile.directory : nil)
                if let space = store.spaces.first(where: { $0.profileID == main && $0.bookmarkSourceID == profile.id }) {
                    brought.insert(space.id)
                    let held = store.bookmarkKeys(in: space.id)
                    totals.bookmarks += Set(bookmarks.flatMap(\.linkKeys)).intersection(held).count
                }
            }
            if let history, !history.isEmpty {
                totals.pages += history.count
                model.recordImportedHistory(history, from: profile.id)
            }
        }
        if totals.pages > 0 {
            if let merged = read.mergedHistory, model.visitHistory == read.historyBase {
                model.visitHistory = merged
            } else {
                // Merged once, every profile together, if it couldn't be done ahead.
                model.visitHistory.merge(read.importedHistory)
            }
            model.scheduleVisitHistorySave()
        }
        let consolidation = ExtensionConsolidation(read.extensions.map(\.extension), installedIDs: read.installedExtensionIDs)
        let queue = ExtensionReinstallQueue(consolidation.candidates, into: main)
        if !queue.isFinished || !consolidation.skipped.isEmpty {
            var from: [String] = []
            for (browser, item) in read.extensions where item.canReinstall && !from.contains(browser.name) { from.append(browser.name) }
            model.queueExtensionReinstall(queue, from: ListFormatter.localizedString(byJoining: from), skipped: consolidation.skipped)
            totals.extensions = queue.items.count
        }
        brought.formUnion(store.spaces.filter { !before.contains($0.id) }.map(\.id))
        model.loadSelectedIfNeeded()
        let seeds = store.spaces.filter { brought.contains($0.id) }.map { space in
            SpaceSeed(name: space.name, icon: space.iconName,
                      colour: RGBA(space.theme.red, space.theme.green, space.theme.blue),
                      profile: space.profileID == main ? nil : store.profile(withID: space.profileID)?.name,
                      hostID: space.id.uuidString)
        }
        return OnboardingImportOutcome(totals: totals, spaces: seeds)
    }
}

extension BookmarkNode {
    /// Its links' `BookmarkImportPlan.key`s.
    var linkKeys: [String] {
        switch self {
        case .link(_, let url): return [BookmarkImportPlan.key(url)]
        case .folder(_, let children): return children.flatMap(\.linkKeys)
        }
    }
}

/// Act 3's spaces and Act 1's name and colour, into the store.
enum OnboardingApplier {
    /// Returns the first space, to select.
    @discardableResult
    static func apply(_ result: OnboardingResult, to store: SidebarStore, mainProfileID main: Profile.ID,
                      replacing replaceable: [Space.ID], starterFavorites: [Tab.ID]) -> Space.ID? {
        let theme = { (c: RGBA) in SpaceTheme(red: c.r, green: c.g, blue: c.b) }
        if !result.name.isEmpty { _ = store.renameProfile(main, to: result.name) }
        if let index = store.profiles.firstIndex(where: { $0.id == main }) {
            var draft = ProfileDraft(profile: store.profiles[index])
            draft.themeColor = theme(result.colour)
            _ = store.updateProfile(main, from: draft)
        }
        var kept: [Space.ID] = []
        for space in result.spaces {
            if let hostID = space.hostID, let id = UUID(uuidString: hostID), store.space(withID: id) != nil {
                _ = store.renameSpace(id, to: space.name)
                store.setSpaceIcon(id, iconName: space.icon)
                store.setSpaceTheme(id, theme: theme(space.colour))
                kept.append(id)
            } else {
                kept.append(store.addSpace(name: space.name, theme: theme(space.colour), iconName: space.icon, profileID: main).id)
            }
        }
        for hostID in result.removedHostIDs {
            if let id = UUID(uuidString: hostID), !kept.contains(id) { _ = store.removeSpace(id) }
        }
        // The starter goes once there is something of the person's to keep.
        if !kept.isEmpty {
            for id in replaceable where !kept.contains(id) { _ = store.removeSpace(id) }
            for id in starterFavorites where store.tab(withID: id) != nil { store.closeTab(id) }
        }
        return kept.first
    }
}
