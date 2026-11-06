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
    /// favorites) and Chromium profiles' bookmarks and history. Passwords and
    /// extensions are not offered until it can bring them too.
    var importCategories: [ImportCategory] { [.spaces, .bookmarks, .history] }

    func discoverSources(_ done: @escaping ([ImportSource]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = BrowserScanner.scan()
            DispatchQueue.main.async { done(found) }
        }
    }

    func bring(_ sources: [ImportSource], categories: [ImportCategory], done: @escaping (OnboardingImportOutcome) -> Void) {
        guard applies, let model else {
            // A rehearsal shows what would come over and changes nothing.
            var totals = ImportStats()
            for s in sources { totals = totals + s.stats }
            if !categories.contains(.spaces) { totals.spaces = 0; totals.tabs = 0 }
            if !categories.contains(.bookmarks) { totals.bookmarks = 0 }
            if !categories.contains(.history) { totals.pages = 0 }
            totals.passwords = 0; totals.extensions = 0
            let seeds = categories.contains(.spaces) ? sources.flatMap(\.spaces) : []
            done(OnboardingImportOutcome(totals: totals, spaces: seeds))
            return
        }
        let plan = OnboardingImportPlan(sources: sources, categories: categories)
        DispatchQueue.global(qos: .userInitiated).async {
            let read = plan.read(applicationSupport: BrowserImportDiscovery.applicationSupport)
            DispatchQueue.main.async { [weak self] in
                guard let self, let model = self.model else { return }
                let result = OnboardingImportPlan.apply(read, model: model)
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
        onDone?()
    }
}

/// What Act 2 asked for, read off the main thread and applied on it.
struct OnboardingImportPlan: Sendable {
    var arcDirectories: Set<String>
    var chromium: [(browser: ImportBrowser, directory: String)]
    var spaces: Bool
    var bookmarks: Bool
    var history: Bool

    init(sources: [ImportSource], categories: [ImportCategory]) {
        arcDirectories = Set(sources.filter { $0.browser == "Arc" }.map(\.directory))
        chromium = sources.compactMap { s in
            ImportBrowser(rawValue: s.browser.lowercased()).map { ($0, s.directory) }
        }
        spaces = categories.contains(.spaces)
        bookmarks = categories.contains(.bookmarks)
        history = categories.contains(.history)
    }

    struct Read: @unchecked Sendable {
        var arc: ArcSidebarImport?
        var arcDirectories: Set<String>
        var arcSettings: ArcSettingsImport?
        var profiles: [(profile: ImportSourceProfile, bookmarks: [BookmarkNode]?, history: [VisitRecord]?)]
    }

    func read(applicationSupport root: URL) -> Read {
        let found = BrowserImportDiscovery.discover(in: root)
        var arc: ArcSidebarImport?
        var settings: ArcSettingsImport?
        if spaces, !arcDirectories.isEmpty {
            arc = try? ArcSidebarImport.load(from: root)
            settings = ArcSettingsImport.read(UserDefaults(suiteName: ImportBrowser.arc.defaultsDomain)?.dictionaryRepresentation() ?? [:])
        }
        var profiles: [(ImportSourceProfile, [BookmarkNode]?, [VisitRecord]?)] = []
        if bookmarks || history {
            for browser in found {
                for profile in browser.profiles where chromium.contains(where: { $0.browser == profile.browser && $0.directory == profile.directory }) {
                    let marks = bookmarks ? (try? ChromiumBookmarksReader.read(profile.url.appendingPathComponent(ChromiumBookmarksReader.fileName))) : nil
                    let visits = history ? (try? ChromiumHistoryReader.read(profile.url.appendingPathComponent(ChromiumHistoryReader.fileName))) : nil
                    profiles.append((profile, marks, visits))
                }
            }
        }
        return Read(arc: arc, arcDirectories: arcDirectories, arcSettings: settings, profiles: profiles)
    }

    /// Into the store, quietly (no toasts: the onboarding is the feedback).
    @MainActor
    static func apply(_ read: Read, model: BrowserViewModel) -> OnboardingImportOutcome {
        let store = model.store
        let before = Set(store.spaces.map(\.id))
        let main = store.activeProfileID
        var totals = ImportStats()
        if let arc = read.arc {
            var choices = arc.defaultChoices(for: store)
            choices.spaceIDs = choices.spaceIDs.filter { id in
                arc.export.spaces.first { $0.id == id }.map { read.arcDirectories.contains($0.profile.directory) } ?? false
            }
            let summary = store.importArcSidebar(arc, choices: choices)
            if let settings = read.arcSettings { model.applyArcSettings(settings) }
            totals.tabs += summary.pinnedTabs + summary.todayTabs + summary.favorites
        }
        for (profile, bookmarks, history) in read.profiles {
            if let bookmarks, let result = store.importBookmarks(bookmarks, spaceName: "\(profile.browser.name) – \(profile.name)", profileID: main) {
                totals.bookmarks += result.tabs
            }
            if let history, !history.isEmpty {
                totals.pages += model.visitHistory.merge(history)
                model.scheduleVisitHistorySave()
            }
        }
        let created = store.spaces.filter { !before.contains($0.id) }
        totals.spaces = created.count
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
