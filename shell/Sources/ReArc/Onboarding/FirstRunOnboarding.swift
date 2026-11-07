import AppKit
import Onboarding
import SidebarModel

/// The sunrise onboarding inside ReArc (shell/Sources/Onboarding). On a
/// first run — no sidebar file yet — it takes over the screen before the
/// browser is seen, imports for real when asked, names and colours the main
/// profile, shapes the spaces, and then lets go over the real window, which
/// it has put exactly where the drawn one formed.
///
/// `--onboarding` forces it on an existing install as a rehearsal: the
/// same flow, nothing imported or changed. For a real first run on a test
/// install, launch with `REARC_DATA_DIR` set to an empty folder.
/// `--no-onboarding` skips it.
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

    /// Whether this launch runs it, and how.
    static func kind(isFirstRun: Bool, arguments: [String], automated: Bool) -> Kind? {
        if automated || arguments.contains(skipFlag) { return nil }
        if arguments.contains(forceFlag) { return isFirstRun ? .firstRun : .rehearsal }
        return isFirstRun ? .firstRun : nil
    }

    let kind: Kind
    private weak var model: BrowserViewModel?
    private let browserWindows: () -> [NSWindow]
    private var takeover: SunriseTakeover?
    private var hidden: [NSWindow] = []
    /// The developer sample's spaces and favorites, cleared once the
    /// person's own are in (first run only).
    private var sampleSpaceIDs: [Space.ID] = []
    private var sampleFavoriteIDs: [Tab.ID] = []
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
            sampleSpaceIDs = model.store.spaces.map(\.id)
            sampleFavoriteIDs = model.store.profiles.flatMap { model.store.favorites(in: $0.id).map(\.id) }
        }
        let takeover = SunriseTakeover(host: self, mode: kind == .replay ? .replay : .firstRun)
        self.takeover = takeover
        takeover.present { }
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

    func discoverSources(_ done: @escaping ([ImportSource]) -> Void) {
        let extensions = canReinstallExtensions
        DispatchQueue.global(qos: .userInitiated).async {
            let found = OnboardingImportPlan.counted(BrowserScanner.scan(), applicationSupport: BrowserImportDiscovery.applicationSupport,
                                                     extensions: extensions)
            DispatchQueue.main.async { done(found) }
        }
    }

    func bring(_ sources: [ImportSource], categories: [ImportCategory], done: @escaping (OnboardingImportOutcome) -> Void) {
        guard applies, model != nil else {
            // A rehearsal shows what would come over (Act 2's own sum) and changes nothing.
            let seeds = categories.contains(.spaces) ? sources.flatMap(\.spaces) : []
            done(OnboardingImportOutcome(totals: ImportSource.totals(sources, categories: categories), spaces: seeds))
            return
        }
        let plan = OnboardingImportPlan(sources: sources, categories: categories)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let read = plan.read(applicationSupport: BrowserImportDiscovery.applicationSupport)
            DispatchQueue.main.async {
                guard let self, let model = self.model else { return }
                let result = OnboardingImportPlan.apply(read, model: model, replacingFavorites: self.sampleFavoriteIDs)
                self.outcome = result
                done(result)
            }
        }
    }

    func apply(_ result: OnboardingResult) {
        guard applies, let model, let main = mainProfileID else { return }
        // The developer sample goes; the person's own spaces stay.
        let first = OnboardingApplier.apply(result, to: model.store, mainProfileID: main,
                                            replacing: sampleSpaceIDs, sampleFavorites: sampleFavoriteIDs)
        model.reconcileEngineOwnership()
        if let first { model.selectSpace(first) }
        model.openPageInNewTab(WelcomePage.write(name: result.name, colour: result.colour,
                                                 spaces: result.spaces.count, imported: outcome?.totals),
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
        // No store page opened over the sunrise; now the browser is here.
        if applies { model?.offerPendingExtensionReinstall() }
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

    init(sources: [ImportSource], categories: [ImportCategory]) {
        arcDirectories = Set(sources.filter { $0.browser == "Arc" }.map(\.directory))
        chromium = sources.compactMap { s in
            ImportBrowser(rawValue: s.browser.lowercased()).map { ($0, s.directory) }
        }
        spaces = categories.contains(.spaces)
        bookmarks = categories.contains(.bookmarks)
        history = categories.contains(.history)
        extensions = categories.contains(.extensions)
    }

    struct Read: @unchecked Sendable {
        /// Only the chosen Arc profiles' spaces and favorites.
        var arc: ArcSidebarImport?
        var arcSettings: ArcSettingsImport?
        var profiles: [(profile: ImportSourceProfile, bookmarks: [BookmarkNode]?, history: [VisitRecord]?)]
        /// In source order; the queue keeps the reinstallable ones, each once.
        var extensions: [(browser: ImportBrowser, extension: SourceExtension)] = []
    }

    /// `arcDefaults`: Arc's preferences, read-only (a dictionary in tests).
    func read(applicationSupport root: URL, arcDefaults: () -> [String: Any] = {
        UserDefaults(suiteName: ImportBrowser.arc.defaultsDomain)?.dictionaryRepresentation() ?? [:]
    }) -> Read {
        let found = BrowserImportDiscovery.discover(in: root)
        var arc: ArcSidebarImport?
        var settings: ArcSettingsImport?
        if spaces, !arcDirectories.isEmpty {
            arc = (try? ArcSidebarImport.load(from: root))?.only(directories: arcDirectories)
            settings = ArcSettingsImport.read(arcDefaults())
        }
        var profiles: [(ImportSourceProfile, [BookmarkNode]?, [VisitRecord]?)] = []
        var extensions: [(ImportBrowser, SourceExtension)] = []
        for browser in found {
            for profile in browser.profiles where chromium.contains(where: { $0.browser == profile.browser && $0.directory == profile.directory }) {
                if bookmarks || history {
                    profiles.append((profile, bookmarks ? Self.bookmarks(profile) : nil, history ? Self.history(profile) : nil))
                }
                if self.extensions {
                    extensions += ExtensionInventoryReader.read(profile: profile.url).map { (profile.browser, $0) }
                }
            }
        }
        return Read(arc: arc, arcSettings: settings, profiles: profiles, extensions: extensions)
    }

    static func bookmarks(_ profile: ImportSourceProfile) -> [BookmarkNode]? {
        try? ChromiumBookmarksReader.read(profile.url.appendingPathComponent(ChromiumBookmarksReader.fileName))
    }

    static func history(_ profile: ImportSourceProfile) -> [VisitRecord]? {
        try? ChromiumHistoryReader.read(profile.url.appendingPathComponent(ChromiumHistoryReader.fileName))
    }

    /// The scanner's sources, each counted as the import would bring it:
    /// Arc's spaces, pinned tabs and favorites from its sidebar reader,
    /// bookmarks and pages from the readers `read` uses, and extensions as
    /// the reinstall queue would take them, by id. The scanner's password
    /// count stays, only to say they stay behind. A source with nothing to
    /// bring is left out.
    static func counted(_ sources: [ImportSource], applicationSupport root: URL, extensions: Bool) -> [ImportSource] {
        let profiles = BrowserImportDiscovery.discover(in: root).flatMap(\.profiles)
        let arc = sources.contains { $0.browser == "Arc" } ? try? ArcSidebarImport.load(from: root) : nil
        return sources.compactMap { source in
            var stats = ImportStats()
            var counted = source
            counted.extensionIDs = []
            if source.browser == "Arc", let arc = arc?.only(directories: [source.directory]) {
                stats.spaces = arc.export.spaces.count
                stats.tabs = arc.export.spaces.reduce(0) { $0 + $1.pinnedTabCount } + arc.favoritesToImport()
            }
            if let browser = ImportBrowser(rawValue: source.browser.lowercased()),
               let profile = profiles.first(where: { $0.browser == browser && $0.directory == source.directory }) {
                stats.bookmarks = bookmarks(profile)?.reduce(0) { $0 + $1.linkCount } ?? 0
                stats.pages = history(profile)?.count ?? 0
                if extensions {
                    counted.extensionIDs = ExtensionReinstallQueue(ExtensionInventoryReader.read(profile: profile.url), into: UUID()).items.map(\.id)
                    stats.extensions = counted.extensionIDs.count
                }
            }
            guard stats != ImportStats() else { return nil }
            stats.passwords = source.stats.passwords
            counted.stats = stats
            return counted
        }
    }

    /// Into the store, quietly (no toasts: the onboarding is the feedback).
    /// Extensions are only queued: their store pages wait for the browser.
    /// `replacingFavorites` (the sample's) go before Arc's favorites come
    /// in, so none of Arc's is skipped as already there and then cleared.
    @MainActor
    static func apply(_ read: Read, model: BrowserViewModel, replacingFavorites sample: [Tab.ID] = []) -> OnboardingImportOutcome {
        let store = model.store
        let before = Set(store.spaces.map(\.id))
        let main = store.activeProfileID
        var totals = ImportStats()
        if let arc = read.arc {
            if arc.favoritesToImport() > 0 {
                for id in sample where store.tab(withID: id) != nil { store.closeTab(id) }
            }
            let summary = store.importArcSidebar(arc, choices: arc.defaultChoices(for: store))
            if let settings = read.arcSettings { model.applyArcSettings(settings) }
            totals.spaces = summary.spaces
            totals.tabs = summary.pinnedTabs + summary.todayTabs + summary.favorites
        }
        for (profile, bookmarks, history) in read.profiles {
            if let bookmarks, let result = store.importBookmarks(bookmarks, spaceName: "\(profile.browser.name) – \(profile.name)", profileID: main) {
                totals.bookmarks += result.tabs
            }
            if let history, !history.isEmpty {
                model.visitHistory.merge(history)
                model.scheduleVisitHistorySave()
                totals.pages += history.count
            }
        }
        let queue = ExtensionReinstallQueue(read.extensions.map(\.extension), into: main)
        if !queue.isFinished {
            var from: [String] = []
            for (browser, item) in read.extensions where item.canReinstall && !from.contains(browser.name) { from.append(browser.name) }
            model.queueExtensionReinstall(queue, from: ListFormatter.localizedString(byJoining: from))
            totals.extensions = queue.items.count
        }
        let created = store.spaces.filter { !before.contains($0.id) }
        model.loadSelectedIfNeeded()
        let seeds = created.map { space in
            SpaceSeed(name: space.name, icon: space.iconName,
                      colour: RGBA(space.theme.red, space.theme.green, space.theme.blue),
                      profile: space.profileID == main ? nil : store.profile(withID: space.profileID)?.name,
                      hostID: space.id.uuidString)
        }
        return OnboardingImportOutcome(totals: totals, spaces: seeds)
    }
}

/// Act 3's spaces and Act 1's name and colour, into the store.
enum OnboardingApplier {
    /// Returns the first space, to select.
    @discardableResult
    static func apply(_ result: OnboardingResult, to store: SidebarStore, mainProfileID main: Profile.ID,
                      replacing replaceable: [Space.ID], sampleFavorites: [Tab.ID]) -> Space.ID? {
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
        // The sample goes once there is something of the person's to keep.
        if !kept.isEmpty {
            for id in replaceable where !kept.contains(id) { _ = store.removeSpace(id) }
            for id in sampleFavorites where store.tab(withID: id) != nil { store.closeTab(id) }
        }
        return kept.first
    }
}
