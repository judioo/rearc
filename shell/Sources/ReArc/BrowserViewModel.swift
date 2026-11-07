import AppKit
import Combine
import SwiftUI
import SidebarModel

/// Glues the pure model (`SidebarStore`) to the chrome: selection side
/// effects (loading the engine), the command-bar overlay, and sidebar
/// visibility. Keyboard shortcuts and views both drive the app through here.
@Observable
final class BrowserViewModel {

    struct PeekSession: Equatable {
        var url: URL
        var title: String
        var engineID: UUID
        var profileID: Profile.ID
    }

    enum CommandBarURLIntent: Equatable {
        case peek
        case littleArc
    }
    let store: SidebarStore
    let engineHost = EngineHost()
    @ObservationIgnored let themeColors = SpaceThemeColorCache()
    let easelStore = EaselDocumentStore()
    let captureFileStore = CaptureFileStore()
    let faviconStore: FaviconStore
    private let persistence: SidebarFilePersistence
    private let syncPipeline: SyncOutboundPipeline
    let syncEngine: SyncEngine
    private(set) var syncStatus: SyncEngineStatus = .local
    /// Settings > iCloud Sync; nil when this build has no iCloud entitlement.
    var syncDetails: SyncStatusDetails?
    @ObservationIgnored var syncActivationObserver: NSObjectProtocol?
    private let nowPlaying: MediaKeyRouting
    private var mediaSubscriptions: [Tab.ID: AnyCancellable] = [:]
    private var captureSubscriptions: [Tab.ID: AnyCancellable] = [:]
    /// Camera and microphone use per tab, for the call card (engines with `media_capture`).
    var captureStateByTab: [Tab.ID: MediaCaptureState] = [:]

    var mediaStateByTab: [Tab.ID: WebMediaState] = [:] {
        didSet {
            mediaControls.update(media: mediaStateByTab)
            reconcileLivePlacements()
        }
    }
    /// Arc's sidebar media strips (wave 32), following `mediaStateByTab`.
    var mediaControls = MediaControlsModel()
    /// The floating PiP panel for a live video (Arc mode, or popped out).
    @ObservationIgnored lazy var livePanel = MainActor.assumeIsolated { LiveVideoPanelController(model: self) }
    /// Where each tab's live video shows (Chromium `pip_embedded`).
    var livePlacements: [Tab.ID: LiveVideoPlacement] = [:]
    /// Tabs whose next PiP session was asked for in the floating panel ("Open Picture in Picture").
    @ObservationIgnored var livePanelRequests: Set<Tab.ID> = []
    /// ReArc > Video in Sidebar: a live video plays in the sidebar above its
    /// strip instead of a floating panel (a ReArc addition; off by default,
    /// since Arc shows only the strip).
    var embedsVideoInSidebar = UserDefaults.standard.object(forKey: BrowserViewModel.embedsVideoInSidebarKey) as? Bool ?? false {
        didSet {
            externalLinkDefaults.set(embedsVideoInSidebar, forKey: Self.embedsVideoInSidebarKey)
            for (id, placement) in livePlacements where placement != .minimized {
                livePlacements[id] = embedsVideoInSidebar ? .sidebar : .panel
            }
        }
    }
    var tabMuteModel = TabMediaMuteModel()
    private(set) var windowOcclusionState: WindowOcclusionState = .visible
    private var autoPiPTriggeredThisOcclusion: Set<Tab.ID> = []
    /// Tabs ReArc put in PiP on a tab switch; showing one again brings its video back.
    @ObservationIgnored var autoPiPEnteredTabIDs: Set<Tab.ID> = []
    /// The tabs on screen at the last selection change (what "switched away" compares with).
    @ObservationIgnored var pipVisibleTabIDs: Set<Tab.ID> = []
    /// ReArc > Automatic Picture in Picture (Arc's setting; on by default).
    var automaticPictureInPicture = UserDefaults.standard.object(forKey: BrowserViewModel.automaticPictureInPictureKey) as? Bool ?? true {
        didSet { externalLinkDefaults.set(automaticPictureInPicture, forKey: Self.automaticPictureInPictureKey) }
    }

    // MARK: Settings window (wave 35)

    /// Settings › Shortcuts: the user's changes to Arc's bindings. The menu
    /// bar's key equivalents and `shortcutRouter` read them.
    var shortcutOverrides: ShortcutOverrides = .load(from: .standard) {
        didSet {
            guard shortcutOverrides != oldValue else { return }
            shortcutOverrides.save(to: externalLinkDefaults)
            onShortcutOverridesChanged?()
        }
    }
    /// The Chromium shell re-applies its menu key equivalents.
    @ObservationIgnored var onShortcutOverridesChanged: (() -> Void)?
    /// Settings › Links: Shift-click on a link opens it in Peek (Arc's default).
    var peekOnShiftClick = UserDefaults.standard.object(forKey: BrowserViewModel.peekOnShiftClickKey) as? Bool ?? true {
        didSet {
            externalLinkDefaults.set(peekOnShiftClick, forKey: Self.peekOnShiftClickKey)
            reconfigureLinkPeek()
        }
    }
    /// Settings › Links: ⌥⌘-click on a link opens it in Little Arc (Arc's default).
    var littleArcOnModifiedClick = UserDefaults.standard.object(forKey: BrowserViewModel.littleArcOnModifiedClickKey) as? Bool ?? true {
        didSet {
            externalLinkDefaults.set(littleArcOnModifiedClick, forKey: Self.littleArcOnModifiedClickKey)
            reconfigureLinkPeek()
        }
    }
    /// Settings › Links › Archive Little Arcs after; checked with the tab auto-archive.
    var littleArcArchiveAfter: AutoArchiveThreshold = LittleArcArchivePreference.load(from: .standard) {
        didSet { LittleArcArchivePreference.save(littleArcArchiveAfter, to: externalLinkDefaults) }
    }
    /// Settings › General › Warn before quitting (⌘Q only).
    var warnBeforeQuitting = QuitWarning.isEnabled(in: .standard) {
        didSet { externalLinkDefaults.set(warnBeforeQuitting, forKey: QuitWarning.defaultsKey) }
    }
    /// Settings › Advanced: reopen every window of the last session at launch.
    var restoresWindows = WindowRestorePreference.isEnabled(in: .standard) {
        didSet { externalLinkDefaults.set(restoresWindows, forKey: WindowRestorePreference.defaultsKey) }
    }
    /// The Settings window's pane; it opens on the one shown last.
    var settingsPane: SettingsPane = .load(from: .standard) {
        didSet { settingsPane.save(to: externalLinkDefaults) }
    }
    /// Settings › Icon.
    var appIcon: AppIconChoice = .load(from: .standard) {
        didSet {
            appIcon.save(to: externalLinkDefaults)
            appIcon.apply()
        }
    }
    /// Opens the Settings window (the Chromium shell's; the WebKit app opens its scene).
    @ObservationIgnored var presentSettings: ((SettingsPane?) -> Void)?
    /// Settings › Profiles › Search engine, once the engine can read and set it.
    @ObservationIgnored var searchEngineSettings: (any SearchEngineSettings)?

    var isSidebarVisible = true
    /// The page is laid out beside the sidebar. It goes wide at the start of
    /// a hide and narrow at the end of a show, so Chromium resizes once per
    /// toggle and never per frame (ARC-RECORDING-ANALYSIS.md §3).
    var isSidebarLaidOut = true
    /// 1 shown, 0 hidden; animated by ⌘S. The sidebar's right edge sits at
    /// `sidebarReveal × sidebarWidth`.
    var sidebarReveal: Double = 1
    /// ⌘S is mid-slide; `isSidebarVisible` says which way.
    var isSidebarSliding = false
    /// Points; dragged from the sidebar's trailing edge, saved when the drag ends.
    var sidebarWidth: CGFloat = SidebarWidth.load()
    /// The hidden sidebar shown floating while the pointer is at the window's
    /// leading edge (Arc `SidebarHovering` / floating sidebar).
    var isSidebarPeeking = false
    /// Settings › General › Sidebar position, as laid out now. `setSidebarSide`
    /// changes it behind `sidebarFlipOpacity`.
    var sidebarSide: SidebarSide = .load(from: .standard)
    /// The sidebar and page fade out and back in around a side change.
    var sidebarFlipOpacity: Double = 1
    /// The side asked for last, while a flip's fade-out runs (Settings shows it at once).
    var pendingSidebarSide: SidebarSide?
    /// The Library per window (Home button, View Library).
    var library = LibraryPresentation()
    /// Windows whose sidebar the Library is widening (animated).
    var libraryGrowth: [SidebarWindowID?: LibrarySidebarGrowth] = [:]
    /// Shown in the bottom bar's update slot. Nothing sets it until an updater exists.
    var availableUpdate: AvailableUpdate?
    /// Installs `availableUpdate`; the updater provides it.
    @ObservationIgnored var installUpdate: (() -> Void)?
    /// Where links from other apps open; remembered across launches.
    var externalLinkDestination: ExternalLinkDestination = .load(from: .standard) {
        didSet { externalLinkDestination.save(to: externalLinkDefaults) }
    }
    @ObservationIgnored var externalLinkDefaults: UserDefaults = .standard
    /// Air Traffic Control: rules that send links from other apps to a space
    /// or a Little Arc profile; saved with the external-link choice.
    var linkRouting: LinkRoutingState = .load(from: .standard) {
        didSet { linkRouting.save(to: externalLinkDefaults) }
    }
    /// The Air Traffic Control settings window (both paths).
    var isAirTrafficControlPresented = false
    /// Set by the Chromium shell, which owns its windows.
    @ObservationIgnored var presentAirTrafficControl: (() -> Void)?
    /// File › Import from Arc, Chrome or Brave… (both engines).
    @ObservationIgnored var browserImportWindow: BrowserImportWindowController?
    /// Extensions the onboarding queued to reinstall (PendingExtensionReinstall).
    var pendingExtensionReinstall: PendingExtensionReinstall?
    @ObservationIgnored let pendingExtensionReinstallURL: URL
    /// Bumped by the Site Controls command; the key window's URL field opens its panel.
    var siteControlCenterRequest = 0
    @ObservationIgnored var defaultBrowser: any DefaultBrowserSetting = SystemDefaultBrowser()
    /// Bumped when the default-browser state may have changed (menus re-read it).
    var defaultBrowserRevision = 0
    var defaultBrowserMessage: String?
    /// Space being edited in the Edit Space sheet (name, theme, icon).
    var spaceEditorID: Space.ID?
    /// Edit Theme Color: the space whose header shows the theme editor popover.
    var themePopoverSpaceID: Space.ID?
    /// Create a Space while it is open, as a page of one window's sidebar.
    /// The window reads its theme and where it shows (`creationShell`); the
    /// name and icon are observed apart, so typing redraws the page alone.
    var spaceCreation: SpaceCreationSession? {
        get {
            guard var session = creationShell else { return nil }
            session.draft.name = creationName
            session.draft.iconName = creationIcon
            return session
        }
        set {
            let shell = newValue.map { session -> SpaceCreationSession in
                var session = session
                session.draft.name = ""
                session.draft.iconName = ""
                return session
            }
            if shell != creationShell { creationShell = shell }
            if newValue?.draft.name ?? "" != creationName { creationName = newValue?.draft.name ?? "" }
            if newValue?.draft.iconName ?? "" != creationIcon { creationIcon = newValue?.draft.iconName ?? "" }
        }
    }
    private var creationShell: SpaceCreationSession?
    private var creationName = ""
    private var creationIcon = ""
    /// Create a Space's fields; setting a draft opens the page in the key window.
    var spaceCreationDraft: SpaceDraft? {
        get { spaceCreation?.draft }
        set {
            if let newValue {
                if spaceCreation == nil {
                    spaceCreation = SpaceCreationSession(draft: newValue, window: store.keyWindowID, origin: .command)
                } else {
                    spaceCreation?.draft = newValue
                }
            } else {
                spaceCreation = nil
            }
        }
    }
    var profileEditorRequest: ProfileEditorRequest?
    var itemIconEditorID: UUID?
    /// The split row whose name is being edited in place.
    var renamingSplitID: SplitViewItem.ID?
    /// Today tabs archived by the last Clear, for Undo.
    var lastClearedTabIDs: [Tab.ID] = []
    var archiveFilter = LibraryArchiveFilter()
    var pendingRename: SidebarRenameRequest?
    var pendingRenameText = ""
    /// A tab or folder being renamed in its own row.
    var inlineRename: SidebarInlineRename?
    /// The just-pinned row showing "Double-click to rename", and since when.
    var renameHint: (tabID: Tab.ID, shownAt: Date)?
    var pendingDeletion: SidebarDeletionRequest?
    /// A space waiting for confirmation to move to another profile.
    var pendingSpaceProfileChange: SpaceProfileChange?
    @ObservationIgnored var autoArchiveTimer: Timer?
    /// Engine whose favicon is being tracked, per tab.
    @ObservationIgnored var faviconObservedEngines: [Tab.ID: ObjectIdentifier] = [:]
    /// Engine whose page title is tracked for unread activity, per tab.
    @ObservationIgnored var titleObservedEngines: [Tab.ID: ObjectIdentifier] = [:]
    @ObservationIgnored var observedPageTitles: [Tab.ID: String] = [:]
    /// Last navigation commit or load finish per tab (titles settle after it).
    @ObservationIgnored var lastNavigationAt: [Tab.ID: Date] = [:]
    /// Collapsed Pinned sections, per window and space.
    var pinnedSectionCollapse = PinnedSectionCollapseState()
    /// Expand Current Split: the pane a window shows alone, per split.
    var splitMaximize = SplitPaneMaximizeState()
    /// The open Ctrl+Tab switcher.
    var tabSwitcher: TabSwitcherSession?
    @ObservationIgnored var tabSwitcherMonitor: Any?
    /// Arc's shortcut priorities while a page has focus (wave 30).
    @ObservationIgnored let shortcutRouter = ShortcutRouter()
    /// Cycle Tab Backward/Forward's visit order (⌃⌘← / ⌃⌘→).
    @ObservationIgnored var tabVisitCycle: TabVisitCycle?
    /// ⌘T opens only the field. Its Today tab is created when a page is chosen.
    var commandBarCreatesNewTab = false
    /// The Little Arc whose window is key (nil when a browser window is).
    var keyLittleArcID: LittleArcWindow.ID? {
        didSet {
            // Focus in and out counts as use, so a window in use never looks idle to the auto-archive.
            guard keyLittleArcID != oldValue else { return }
            for id in [oldValue, keyLittleArcID].compactMap({ $0 }) { store.touchLittleArcWindow(id: id) }
        }
    }
    /// A Little Arc whose address field should start editing (⌘L, New Little Arc Window).
    var littleArcFocusRequest: LittleArcWindow.ID?
    var littleArcHotkeyPreference = LittleArcHotkeyPreference()
    @ObservationIgnored var littleArcHotkeyDefaults: UserDefaults = .standard
    @ObservationIgnored var littleArcHotkey: GlobalHotkey?
    @ObservationIgnored var littleArcHotkeyStarted = false
    /// ⌥⌘-click contents the Chromium shell adopted as Little Arcs (self-test).
    @ObservationIgnored var littleArcAdoptions = 0
    @ObservationIgnored var lastMouseDown: (modifiers: NSEvent.ModifierFlags, at: Date)?
    /// The confirmation toast over the page ("Copied Current URL"), cleared after a moment.
    var toast: ShellToast?
    @ObservationIgnored var lastCopiedLinkText: String?
    /// Copy URL's pasteboard (tests use a private one).
    @ObservationIgnored var linkPasteboard: NSPasteboard = .general
    var isCommandBarPresented = false
    var commandBarText = "" {
        didSet {
            commandBarHighlightedIndex = 0
            // Deleting turns inline completion off until the next character (omnibox rule).
            commandBarSuppressesInlineCompletion = commandBarText.count < oldValue.count && oldValue.hasPrefix(commandBarText)
            if commandBarText != oldValue {
                PerfSignposts.interaction(.commandBarKey, "\(commandBarText.count) chars")
                refreshCommandBarLive()
            }
        }
    }
    var commandBarHighlightedIndex = 0
    /// The tab the command bar will navigate on submit.
    var commandBarTargetID: Tab.ID?
    /// The tab shown before ⌘T: a ⌥↩ split pairs with it.
    var commandBarSplitAnchorID: Tab.ID?
    /// Bumped to give the command bar's field focus again (`CommandBarOverlay.focusRequest`).
    var commandBarFocusRequest = 0
    var commandBarSuppressesInlineCompletion = false

    /// The site a Tab-triggered scoped search is aimed at (Arc site search pill).
    var commandBarSiteSearch: SiteSearchEngine?
    /// What was typed before Tab, restored when the pill is removed
    /// (Arc `queryBeforeEnteringScopedSearch`).
    @ObservationIgnored var commandBarTextBeforeSiteSearch = ""

    @ObservationIgnored let commandBarResultCache = ObservedCache<[CommandBarSearch.Result]>()
    @ObservationIgnored let commandBarCatalogCache = ObservedCache<[AppCommand]>()
    @ObservationIgnored let commandBarDomainCache = ObservedCache<[String]>()
    @ObservationIgnored let commandBarInlineCache = ObservedCache<String?>()
    /// Open tabs and enabled commands prepared for matching, rebuilt when the
    /// sidebar or the catalog changes rather than on every keystroke.
    @ObservationIgnored let commandBarTabIndexCache = ObservedCache<CommandBarSearch.TabIndex>()
    @ObservationIgnored let commandBarCommandIndexCache = ObservedCache<CommandBarSearch.CommandIndex>()
    /// The main menu's commands while the bar is open (`commandBarMenuCommands`).
    @ObservationIgnored var commandBarMenuSnapshot: [MenuCommand]?
    /// That snapshot prepared against the catalog (`commandBarMenuIndex`).
    @ObservationIgnored var commandBarMenuIndexMemo: MenuCommandSearch.Index?
    /// The engine's history for the current text, prepared once for all of
    /// the passes its other answers cause.
    @ObservationIgnored var commandBarLiveHistoryMemo: (records: [VisitRecord], history: VisitHistory)?

    var commandBarResults: [CommandBarSearch.Result] {
        commandBarResultCache.value {
            ModelSignposts.measure(ModelSignposts.model, "CommandBarResults", detail: "\(commandBarText.count) chars") {
                computeCommandBarResults()
            }
        }
    }

    private func computeCommandBarResults() -> [CommandBarSearch.Result] {
        if let engine = commandBarSiteSearch {
            return CommandBarSearch.siteSearchResults(engine, query: commandBarText)
        }
        let (mode, needle) = CommandBarSearch.parseMode(commandBarText)
        if mode == .blended && needle.isEmpty { return [] }
        let commandIndex = commandBarCommandIndex
        return CommandBarSearch.results(
            for: commandBarText,
            in: store,
            isSidebarVisible: isSidebarVisible,
            peekURL: peekSession?.url,
            focusedLittleArcID: focusedLittleArcID,
            mediaByTab: mediaStateByTab,
            tabMuteModel: tabMuteModel,
            navigationSchemes: engineHost.navigationSchemes,
            history: visitHistory,
            liveHistory: commandBarLiveHistory,
            tabIndex: commandBarTabIndex,
            commandIndex: commandIndex,
            menuIndex: commandBarMenuIndex(registered: commandIndex.catalog),
            externalLinkDestination: externalLinkDestination,
            live: commandBarLive,
            searchProvider: searchProvider,
            inlineCompletion: commandBarInlineCompletion
        )
    }

    /// Every open tab, prepared; rebuilt when the sidebar changes.
    var commandBarTabIndex: CommandBarSearch.TabIndex {
        commandBarTabIndexCache.value { CommandBarSearch.TabIndex(store: store) }
    }

    /// The enabled command catalog, prepared; its enabled checks read the sidebar.
    var commandBarCommandIndex: CommandBarSearch.CommandIndex {
        commandBarCommandIndexCache.value {
            CommandBarSearch.CommandIndex(catalog: commandBarCatalogCache.value {
                AppCommandRegistry.all(in: CommandBarContext(
                    store: store, isSidebarVisible: isSidebarVisible, closedTabStack: store.closedTabStack,
                    peekURL: peekSession?.url, focusedLittleArcID: focusedLittleArcID,
                    mediaByTab: mediaStateByTab, tabMuteModel: tabMuteModel,
                    navigationSchemes: engineHost.navigationSchemes, externalLinkDestination: externalLinkDestination,
                    pendingExtensionReinstall: pendingExtensionReinstall?.title))
            })
        }
    }

    /// The menu snapshot prepared against `registered`, kept while neither changes.
    func commandBarMenuIndex(registered: [AppCommand]) -> MenuCommandSearch.Index {
        let menus = commandBarMenuCommands
        if let memo = commandBarMenuIndexMemo, memo.commands == menus, memo.registered == registered { return memo }
        let index = MenuCommandSearch.Index(menus, registered: registered)
        commandBarMenuIndexMemo = index
        return index
    }

    /// `commandBarLive`'s history as a prepared store, built once per answer.
    private var commandBarLiveHistory: VisitHistory? {
        guard let records = commandBarLive?.history else { return nil }
        if let memo = commandBarLiveHistoryMemo, memo.records == records { return memo.history }
        let history = VisitHistory(records: records)
        commandBarLiveHistoryMemo = (records, history)
        return history
    }

    /// Engine history, suggestions and URL-vs-search for the typed text
    /// (`CommandBarServices`); nil until a source answers.
    var commandBarLive: CommandBarLiveResults?
    @ObservationIgnored var commandBarGate = CommandBarQueryGate()
    /// Engine lookups start once the keystroke's frame has been committed.
    @ObservationIgnored let commandBarAfterCommit = AfterCommit()
    /// The newest text waiting for that, with its gate generation.
    @ObservationIgnored var pendingCommandBarQuery: (text: String, generation: UInt64)?
    /// The engine's command-bar sources; the Chromium shell installs its own.
    @ObservationIgnored var commandBarServices: CommandBarServices = WebKitCommandBarServices() {
        didSet { observeSearchProvider() }
    }
    /// Bumped when a default search changes, so rows and menus re-read it.
    var searchProviderRevision = 0

    /// The active profile's default search (Chromium's, or the WebKit preference).
    var searchProvider: SearchProvider {
        _ = searchProviderRevision
        return commandBarServices.searchProvider(for: store.activeProfileID)
    }

    var peekURL: URL? { peekSession?.url }

    var commandBarError: String?
    var commandBarURLIntent: CommandBarURLIntent?
    var pendingProfileRenameID: Profile.ID?
    var pendingProfileRenameName = ""

    var peekSession: PeekSession?
    var focusedLittleArcID: LittleArcWindow.ID?
    var littleArcOpenRequests: [LittleArcWindow.ID] = []
    /// Opens Little Arc windows when the app has no SwiftUI scenes (Chromium path).
    @ObservationIgnored weak var windowPresenter: BrowserWindowPresenting?
    /// Runs after a shell profile is deleted, to release its engine storage.
    @ObservationIgnored var onProfileDeleted: ((Profile.ID) -> Void)?
    /// Open private windows; never persisted.
    var privateWindows: [UUID: PrivateWindowModel] = [:]
    var privateWindowOpenRequests: [UUID] = []
    /// Runs when the last window of a private session closes, with that window.
    @ObservationIgnored var onPrivateSessionEnded: ((PrivateWindowModel) -> Void)?
    private var didRestoreLittleArcWindows = false

    var boostEditorDraftByTab: [Tab.ID: BoostEditorDraft] = [:]
    /// The legacy (CSS and JavaScript) boost open in its editor sheet.
    var legacyBoostEditorID: UUID?
    /// Open DevTools frontends, per sidebar tab, and their engines.
    var devTools = DevToolsSessions()
    @ObservationIgnored var devToolsEngines: [Tab.ID: any WebEngine] = [:]
    /// Tabs whose frontend was asked for and has not arrived yet.
    @ObservationIgnored var devToolsPending: Set<Tab.ID> = []
    /// Set by the Chromium shell when the engine hosts DevTools (ABI 1.40).
    @ObservationIgnored weak var devToolsOpener: DevToolsOpening?
    var boostSessionApplyByTab: [Tab.ID: BoostSessionApplyMap] = [:]
    var lastPickedSnapshotByTab: [Tab.ID: PickedElementSnapshot] = [:]
    var boostSelectorFingerprintByTab: [Tab.ID: BoostSelectorFingerprint] = [:]
    var boostLiveDebounceWorkItem: DispatchWorkItem?

    var easelMutationRevision = 0
    var sidebarRecoveredFromCorruption = false
    var isCapturePreviewPresented = false
    var lastCapturePreview: CaptureRecord?
    /// Capture's drag-or-click overlay, while it is up.
    var pageCaptureSession: PageCaptureSession?
    var captureErrorMessage: String?

    /// Cmd+F bar; targets one page at a time.
    let findBar = FindBarModel()
    /// The sidebar's downloads tray (both engines).
    let downloads: DownloadsController
    /// Extension actions and pins (Chromium only; hidden on WebKit).
    let extensions = ExtensionsController()
    /// Permission answers per site (URL field indicator; WebKit's remembered answers).
    let sitePermissions: SitePermissionsController
    /// Command-bar visit history, saved next to the sidebar file.
    var visitHistory: VisitHistory
    /// No sidebar file yet: the sample store stands in until the onboarding
    /// replaces it (Onboarding/FirstRunOnboarding.swift).
    let isFirstRun: Bool
    @ObservationIgnored let historyFileURL: URL?
    @ObservationIgnored var historySaveWorkItem: DispatchWorkItem?
    @ObservationIgnored let historySaveQueue = DispatchQueue(label: "net.rearc.history.persistence", qos: .utility)
    /// Last URL recorded per tab: a commit and its load-stop report the same visit.
    @ObservationIgnored var lastRecordedVisit: [Tab.ID: String] = [:]
    /// The page in HTML fullscreen, and what to restore when it leaves.
    var htmlFullscreen: HTMLFullscreenSession?
    /// Tabs whose engine the shell dropped to unload them (rows dim until shown).
    var unloadedTabIDs: Set<Tab.ID> = []
    /// Last time each tab was on screen, for the automatic unload.
    @ObservationIgnored var tabLastShown: [Tab.ID: Date] = [:]
    /// Unload inactive tabs after this long unseen (remembered).
    var tabUnloadThreshold: TabUnloadThreshold = .load(from: .standard) {
        didSet { tabUnloadThreshold.save(to: tabUnloadDefaults) }
    }
    @ObservationIgnored var tabUnloadDefaults: UserDefaults = .standard
    private(set) var startupDeferred = false
    @ObservationIgnored private var didFinishStartup = false
    /// A mutation's engine reconcile and boost sync are queued (`scheduleMutationFollowUp`).
    @ObservationIgnored var mutationFollowUpScheduled = false
    @ObservationIgnored private var transientWarmupScheduled = false

    init(
        store: SidebarStore? = nil,
        persistence: SidebarFilePersistence? = nil,
        nowPlaying: MediaKeyRouting? = nil,
        syncEngine: SyncEngine? = nil,
        faviconStore: FaviconStore? = nil,
        preparedStartup: PreparedBrowserStartup? = nil,
        deferStartup: Bool = false
    ) {
        let persistence = persistence ?? SidebarFilePersistence()
        self.persistence = persistence
        self.faviconStore = faviconStore
            ?? FaviconStore(directory: persistence.fileURL.deletingLastPathComponent().appendingPathComponent("Favicons", isDirectory: true))
        self.store = store ?? SidebarFilePersistence.loadStore(persistence: persistence)
        self.sidebarRecoveredFromCorruption = persistence.loadOutcome == .recoveredFromCorruptFile
        self.isFirstRun = persistence.loadOutcome == .missingFile
        let historyFile = Self.siblingFile(VisitHistoryFile.fileName, of: persistence.fileURL)
        self.historyFileURL = historyFile
        self.visitHistory = preparedStartup?.history ?? VisitHistoryFile.load(from: historyFile)
        let reinstallFile = Self.siblingFile(PendingExtensionReinstall.fileName, of: persistence.fileURL)
        self.pendingExtensionReinstallURL = reinstallFile
        self.pendingExtensionReinstall = PendingExtensionReinstall.load(from: reinstallFile)
        self.downloads = DownloadsController(fileURL: Self.siblingFile(DownloadListFile.fileName, of: persistence.fileURL), prepared: preparedStartup?.downloads,
                                             turnBudget: DownloadsController.appTurnBudget)
        engineHost.downloadCenter = downloads.webKit
        self.sitePermissions = SitePermissionsController(fileURL: Self.siblingFile(SitePermissionStore.fileName, of: persistence.fileURL), prepared: preparedStartup?.permissions)
        engineHost.sitePermissions = sitePermissions
        self.nowPlaying = nowPlaying ?? NowPlayingController()
        let engine = syncEngine ?? MainActor.assumeIsolated {
            CloudKitSyncAvailability.makeEngine(stateFileURL: Self.siblingFile(SidebarSyncStateFile.fileName, of: persistence.fileURL), initialState: preparedStartup?.syncState)
        }
        self.syncEngine = engine
        self.syncPipeline = SyncOutboundPipeline(journal: self.store.mutationJournal, engine: engine)
        self.syncStatus = engine.status
        engine.onStatusChange = { [weak self] status in
            self?.syncStatus = status
        }
        attachSync()
        self.store.mutationJournal.onAppend = { [weak self] entry in
            self?.syncPipeline.handleJournalEntry(entry)
        }
        engineHost.linkRouter = self
        shortcutRouter.binding = { [weak self] key, modifiers in
            (self?.shortcutOverrides ?? ShortcutOverrides()).binding(for: key, modifiers: modifiers)
        }
        self.persistence.start(autoSave: self.store) { [weak self] in
            self?.scheduleMutationFollowUp()
        }
        if self.store.selectedItemID == nil {
            if let first = self.store.displayTabs().first {
                self.store.selectTab(first.id)
            } else if let easel = self.store.allEaselRefs().first {
                self.store.selectEasel(easel.id)
            }
        }
        startupDeferred = deferStartup
        if !deferStartup { finishStartup() }
    }

    /// The cached sidebar can render before page/profile creation, archive,
    /// sync and media setup. Idempotent so multiple windows cannot start twice.
    func finishStartup() {
        guard !didFinishStartup else { return }
        didFinishStartup = true
        let wasDeferred = startupDeferred
        startupDeferred = false
        #if REARC_CHROMIUM
        LaunchTimeline.servicesStarted = ProcessInfo.processInfo.systemUptime
        #endif
        PerfSignposts.launchEvent("ServicesStarting")
        syncEngine.start()
        observeSearchProvider()
        wireMediaKeyHandlers()
        runAutoArchive()
        startAutoArchiveTimer()
        loadSelectedIfNeeded()
        if wasDeferred { restoreLittleArcWindowsIfNeeded() }
        MainActor.assumeIsolated { livePanel.track() }
    }

    func mediaState(for tabID: Tab.ID) -> WebMediaState {
        mediaStateByTab[tabID] ?? .silent
    }

    func showsAudibleIndicator(for tabID: Tab.ID) -> Bool {
        tabMuteModel.showsAudibleIndicator(for: tabID, media: mediaState(for: tabID))
    }

    func muteTab(_ tabID: Tab.ID) {
        guard let tab = store.tab(withID: tabID) else { return }
        let profileID = profileID(for: tab)
        engineHost.setMuted(true, forTabID: tabID, profileID: profileID)
        tabMuteModel.markUserMuted(tabID)
    }

    /// Storage context for a tab's engine: the profile owning its space, or
    /// owning the favorites strip it sits in.
    func profileID(for tab: Tab) -> Profile.ID {
        if let owner = store.favoriteOwner(of: tab.id) {
            return owner
        }
        if let spaceID = store.spaceContaining(tabID: tab.id),
           let space = store.spaces.first(where: { $0.id == spaceID }) {
            return space.profileID
        }
        return store.activeProfileID
    }

    func profileID(forTabID id: Tab.ID) -> Profile.ID? {
        store.tab(withID: id).map { profileID(for: $0) }
    }

    func handleWindowOcclusion(_ state: WindowOcclusionState) {
        windowOcclusionState = state
        if state == .visible {
            autoPiPTriggeredThisOcclusion.removeAll()
        }
        evaluateAutoPiPIfNeeded()
    }

    var themeColor: Color {
        let theme = store.activeSpace.theme
        return Color(red: theme.red, green: theme.green, blue: theme.blue)
    }

    var syncStatusColor: Color {
        switch SyncStatusPresentation(syncStatus).indicator {
        case .grey: return Color(nsColor: .systemGray)
        case .blue: return .blue
        case .green: return .green
        case .red: return .red
        }
    }

    var syncStatusHelp: String {
        SyncStatusPresentation(syncStatus).help
    }

    // MARK: - Selection & navigation

    var activeSplit: SplitViewItem? {
        guard let id = store.selectedItemID else { return nil }
        return store.split(withID: id)
    }

    /// A sidebar click shows the item, closing the Library even when the
    /// item was already selected under it.
    func selectTab(_ id: Tab.ID) {
        PerfSignposts.interaction(.tabSwitch, "select")
        closeLibrary()
        store.selectTab(id)
        loadSelectedIfNeeded()
    }

    func selectSplit(_ splitID: SplitViewItem.ID, focusTabID: Tab.ID? = nil) {
        closeLibrary()
        store.selectSplit(splitID, focusTabID: focusTabID)
        loadSelectedIfNeeded()
    }

    func selectNextTab() {
        store.selectNextTab()
        loadSelectedIfNeeded()
    }

    func selectPreviousTab() {
        store.selectPreviousTab()
        loadSelectedIfNeeded()
    }

    /// Cmd+W / hover close. A favorite is unloaded (engine dropped, kept in
    /// the strip) and a pinned tab is unloaded back to its saved URL, as in
    /// Arc; anything else is closed and archived.
    func closeTab(_ id: Tab.ID) {
        // The page may ask "Leave site?" first (Chromium beforeunload); Stay keeps the tab.
        closeThroughPage(id) { [weak self] in self?.closeTabNow(id) }
    }

    private func closeTabNow(_ id: Tab.ID) {
        guard store.tab(withID: id) != nil else { return }
        if store.kind(of: id) == .favorite {
            unloadFavorite(id)
            return
        }
        if store.kind(of: id) == .pinned, store.splitContaining(tabID: id) == nil {
            unloadPinnedTab(id)
            return
        }
        deleteTab(id)
    }

    /// Removes a tab from the sidebar (to the archive), pinned tabs included.
    func deleteTab(_ id: Tab.ID) {
        store.closeTab(id)
        releaseEngine(for: id)
        loadSelectedIfNeeded()
    }

    /// Back to the saved URL, unloaded. A Chromium page still on its saved
    /// URL is discarded in place (history kept); otherwise the engine goes.
    func unloadPinnedTab(_ id: Tab.ID) {
        let atSavedURL = store.tab(withID: id).map { !$0.isAwayFromSavedURL } ?? false
        let engine = discardableEngine(for: id)
        guard store.unloadPinnedTab(id) else { return }
        finishUnload(id, discarding: atSavedURL ? engine : nil)
    }

    func unloadFavorite(_ id: Tab.ID) {
        let engine = discardableEngine(for: id)
        store.unloadFavorite(id)
        finishUnload(id, discarding: engine)
    }

    private func discardableEngine(for id: Tab.ID) -> (any WebEngine)? {
        guard let tab = store.tab(withID: id),
              let engine = engineHost.engine(forTabID: id, profileID: profileID(for: tab)),
              engine is TabDiscarding else { return nil }
        return engine
    }

    private func finishUnload(_ id: Tab.ID, discarding engine: (any WebEngine)?) {
        if engine == nil {
            releaseEngine(for: id)
            unloadedTabIDs.insert(id)
        }
        // The selection moved; its page shows (and this one hides) before the discard.
        loadSelectedIfNeeded()
        if let engine { unloadEngine(engine, tabID: id, dropIfRefused: true) }
    }

    /// Remove from Favorites: deletes the favorite.
    func removeFavorite(_ id: Tab.ID) {
        guard store.kind(of: id) == .favorite else { return }
        store.closeTab(id)
        releaseEngine(for: id)
        loadSelectedIfNeeded()
    }

    func releaseEngine(for id: Tab.ID) {
        faviconObservedEngines[id] = nil
        titleObservedEngines[id] = nil
        observedPageTitles[id] = nil
        mediaSubscriptions[id] = nil
        mediaStateByTab[id] = nil
        captureSubscriptions[id] = nil
        captureStateByTab[id] = nil
        tabMuteModel.markUserUnmuted(id)
        closeDevTools(for: id)
        engineHost.remove(id)
        refreshNowPlaying()
    }

    func closeSplit(_ splitID: SplitViewItem.ID) {
        if let split = store.split(withID: splitID) {
            split.tabs.forEach { tab in
                engineHost.remove(tab.id)
                mediaSubscriptions[tab.id] = nil
                mediaStateByTab[tab.id] = nil
                captureSubscriptions[tab.id] = nil
                captureStateByTab[tab.id] = nil
            }
        }
        store.closeSplit(splitID)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    func unsplit(_ splitID: SplitViewItem.ID) {
        store.unsplit(splitID)
        loadSelectedIfNeeded()
    }

    func unsplitTabIfInSplit(_ tabID: Tab.ID) {
        guard let location = store.splitContaining(tabID: tabID) else { return }
        if store.removeTabFromSplit(splitID: location.split.id, tabID: tabID) {
            loadSelectedIfNeeded()
        }
    }

    func addSplitView(orientation: SplitLayoutOrientation) {
        if store.selectedTab == nil {
            newTab()
        }
        guard let anchorTab = store.selectedTab else { return }
        let sectionKind: Tab.Kind = anchorTab.kind == .pinned ? .pinned : .today
        if let existing = store.splitContaining(tabID: anchorTab.id)?.split {
            // Inside a split: add a blank pane, up to four.
            guard !existing.isFull else { return showSplitFullToast() }
            let pane = store.addTab(kind: sectionKind, title: "New Tab", url: URL(string: "about:blank")!)
            guard store.splitTab(pane.id, with: anchorTab.id) != nil else {
                store.closeTab(pane.id)
                engineHost.remove(pane.id)
                return
            }
            loadSelectedIfNeeded()
            return
        }
        let companion = store.addTab(
            kind: sectionKind,
            title: "New Tab",
            url: URL(string: "about:blank")!
        )
        guard store.createSplit(tabIDs: [anchorTab.id, companion.id], orientation: orientation) != nil else {
            store.closeTab(companion.id)
            engineHost.remove(companion.id)
            return
        }
        loadSelectedIfNeeded()
    }

    func closeSelectedTab() {
        guard let id = store.selectedTabID else { return }
        closeTab(id)
    }

    func selectSpace(_ id: Space.ID) {
        PerfSignposts.interaction(.spaceSwitch, "select")
        store.selectSpace(id)
        loadSelectedIfNeeded()
    }

    func selectProfile(_ id: Profile.ID) {
        PerfSignposts.interaction(.profileSwitch, "select")
        guard store.profile(withID: id) != nil, id != store.activeProfileID else { return }
        store.selectProfile(id)
        loadSelectedIfNeeded()
    }

    /// Deletes a profile and drops engines that used it. Without
    /// `deletingSpaces` the profile must own no spaces.
    @discardableResult
    func deleteProfile(_ id: Profile.ID, deletingSpaces: Bool = false) -> ProfileMutationError? {
        if let error = store.deleteProfile(id, deletingSpaces: deletingSpaces) { return error }
        engineHost.evictEngines(forProfileID: id)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        onProfileDeleted?(id)
        return nil
    }

    func cycleSpace(forward: Bool = true) {
        PerfSignposts.interaction(.spaceSwitch, forward ? "next" : "previous")
        store.cycleSpace(forward: forward)
        loadSelectedIfNeeded()
    }

    /// Ctrl+1…9.
    func selectSpace(atIndex index: Int) {
        PerfSignposts.interaction(.spaceSwitch, "index \(index)")
        guard store.selectSpace(atIndex: index) else { return }
        loadSelectedIfNeeded()
    }

    /// Creates the suggested next space directly (no dialog).
    @discardableResult
    func addSpace() -> Space {
        let space = store.createSpace(from: SpaceDraft.suggested(in: store)) ?? store.activeSpace
        loadSelectedIfNeeded()
        return space
    }

    /// New Space: Create a Space opens as a page after the last space of
    /// the window's sidebar (name, icon, theme, profile). Arc starts it blank
    /// on its built-in theme (ARC-RECORDING-ANALYSIS.md §1, row 7) and fades
    /// to it; pulled past the last space it pops in at once.
    func beginSpaceCreation(profileID: Profile.ID? = nil, in window: SidebarWindowID? = nil,
                            origin: SpaceCreationSession.Origin = .command) {
        let window = window ?? store.keyWindowID
        if librarySection(in: window) != nil { closeLibrary(in: window) }
        let draft = SpaceDraft.blank(in: store, profileID: profileID ?? space(in: window).profileID)
        swapCreationPage(SpaceCreationSession(draft: draft, window: window, origin: origin), origin: origin)
    }

    /// Cancel: the page fades back to the space the window was on.
    func cancelSpaceCreation() {
        guard spaceCreation != nil else { return }
        swapCreationPage(nil, origin: nil)
    }

    private func swapCreationPage(_ session: SpaceCreationSession?, origin: SpaceCreationSession.Origin?) {
        var transaction = Transaction(animation: .easeOut(duration: max(SpaceCreationSession.fadeDuration(opening: origin), 0.12)))
        transaction.swapsCreationPage = true
        withTransaction(transaction) { spaceCreation = session }
    }

    /// A page's theme: a space's, or Create a Space's draft.
    func pageTheme(_ id: Space.ID) -> SpaceTheme? {
        id == SpaceCreationSession.pageID ? creationShell?.draft.theme : store.space(withID: id)?.theme
    }

    /// The window shows Create a Space's page.
    func isCreatingSpace(in window: SidebarWindowID?) -> Bool {
        creationShell?.isShown(in: window) ?? false
    }

    /// The theme a window wears: its space's, or the draft's while it
    /// shows Create a Space.
    func shownTheme(in window: SidebarWindowID?) -> SpaceTheme {
        if let session = creationShell, session.isShown(in: window) { return session.draft.theme }
        return space(in: window).theme
    }

    @discardableResult
    func createSpace(from draft: SpaceDraft) -> Space? {
        guard let space = store.createSpace(from: draft) else { return nil }
        spaceCreation = nil
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        return space
    }

    /// ⌘S (Arc's Show/Hide Sidebar), as the user's recording shows it
    /// (ARC-RECORDING-ANALYSIS.md §3): one quick push with no overshoot. The
    /// sidebar slides with the page's leading edge. A hide lays the page out
    /// wide at once and the receding sidebar uncovers it; a show slides the
    /// wide page right with the sidebar and lays it out narrow at the end.
    /// The page keeps keyboard focus. While hidden, the window's leading edge
    /// floats the sidebar.
    func toggleSidebar() {
        PerfSignposts.interaction(.sidebarToggle, isSidebarVisible ? "hide" : "show")
        let showing = !isSidebarVisible
        isSidebarVisible = showing
        isSidebarPeeking = false
        isSidebarSliding = true
        if !showing { isSidebarLaidOut = false }
        withAnimation(Self.sidebarAnimation, completionCriteria: .logicallyComplete) {
            sidebarReveal = showing ? 1 : 0
        } completion: { [weak self] in
            guard let self else { return }
            // A newer toggle owns the state now.
            if self.isSidebarVisible == showing {
                self.isSidebarSliding = false
                if showing { self.isSidebarLaidOut = true }
            }
            self.onShellAnimationComplete?(.sidebarToggle)
        }
    }

    /// The bench's end event for shell animations (`--rearc-bench`).
    enum ShellAnimation { case sidebarToggle, sidebarPeek }
    @ObservationIgnored var onShellAnimationComplete: ((ShellAnimation) -> Void)?

    /// Arc's ⌘S has exactly one intermediate frame at 10 fps in 4 of 4
    /// events and never passes its end, so ≈ 100–150 ms with no overshoot.
    /// It replaces wave 30's inferred `spring(response: 0.35, dampingFraction: 0.85)`.
    static let sidebarAnimationDuration = 0.12
    static let sidebarAnimation = Animation.timingCurve(0.3, 0, 0.2, 1, duration: sidebarAnimationDuration)

    /// Loads the selected tab's URL into its engine if the engine isn't
    /// already showing it (fresh engine or URL changed in the model).
    func loadSelectedIfNeeded() {
        guard !startupDeferred else { return }
        scheduleTransientWarmup()
        library.closeStale { [unowned self] in selectedItemID(in: $0) }
        applyAutoPiPOnTabSwitch()
        noteVisibleTabsShown()
        if store.selectedEaselRef != nil { return }
        if let split = activeSplit {
            for tab in split.tabs {
                let pid = profileID(for: tab)
                let engine = engineHost.engine(for: tab, profileID: pid)
                configureLinkPeek(on: engine, tab: tab)
                if engine.currentURL != tab.url {
                    engine.load(tab.url)
                }
                wireMediaObserver(for: tab)
                syncBoosts(for: tab)
            }
            return
        }
        guard let tab = store.selectedTab else { return }
        let engine = engineHost.engine(for: tab, profileID: profileID(for: tab))
        configureLinkPeek(on: engine, tab: tab)
        if engine.currentURL != tab.url {
            engine.load(tab.url)
        }
        (engine as? PageZoomRefreshing)?.refreshZoomFactor()
        wireMediaObserver(for: tab)
        syncBoosts(for: tab)
    }

    /// Off the input turn. No URL is loaded, and the pool never contains
    /// visited pages, so history, callbacks and prompts cannot leak to a new UI.
    private func scheduleTransientWarmup() {
        #if REARC_CHROMIUM
        guard ChromiumRuntime.active != nil, !transientWarmupScheduled else { return }
        transientWarmupScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.transientWarmupScheduled = false
            self.engineHost.prepareTransientEngines(profileID: self.store.activeProfileID)
        }
        #endif
    }

    func syncAllTabBoosts() {
        ModelSignposts.measure(ModelSignposts.model, "SyncAllBoosts") { syncAllTabBoostsNow() }
    }

    /// After any store mutation: engine ownership and every engine's boosts,
    /// once per main-queue turn rather than once per mutation (a tab switch
    /// makes several). The paths that need either at once (closing tabs,
    /// spaces and profiles, boost library edits, a navigation commit) call
    /// them directly.
    private func scheduleMutationFollowUp() {
        guard !mutationFollowUpScheduled else { return }
        mutationFollowUpScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.mutationFollowUpScheduled = false
            self.reconcileEngineOwnership()
            self.syncAllTabBoosts()
        }
    }

    private func syncAllTabBoostsNow() {
        for (tabID, profileID, engine) in engineHost.allTabEngines() {
            guard let tab = store.tab(withID: tabID) else { continue }
            let entries = store.activeBoostEntries(for: tab)
            engine.installBoosts(entries)
            wireNavigationCommit(for: tab, profileID: profileID)
        }
    }

    func syncBoosts(for tab: Tab) {
        let entries = store.activeBoostEntries(for: tab)
        let pid = profileID(for: tab)
        engineHost.syncBoosts(for: tab, profileID: pid, entries: entries)
        wireNavigationCommit(for: tab, profileID: pid)
    }

    private func wireNavigationCommit(for tab: Tab, profileID: Profile.ID) {
        wireMediaObserver(for: tab)
        observeFavicon(of: engineHost.engine(for: tab, profileID: profileID), tabID: tab.id)
        observePageTitle(of: engineHost.engine(for: tab, profileID: profileID), tabID: tab.id)
        guard let wk = engineHost.engine(for: tab, profileID: profileID) as? NavigationCommitReporting else { return }
        wk.onNavigationCommit = { [weak self] url, title in
            self?.handleTabNavigationCommit(tabID: tab.id, url: url, title: title)
        }
    }

    func handleTabNavigationCommit(tabID: Tab.ID, url: URL?, title: String?) {
        boostSessionApplyByTab[tabID] = BoostSessionApplyMap()
        lastNavigationAt[tabID] = Date()
        guard let url else { return }
        recordVisit(tabID: tabID, url: url, title: title)
        let resolvedTitle = (title?.isEmpty == false) ? title : nil
        let fallback = store.tab(withID: tabID)?.title ?? url.host() ?? "Page"
        store.updateTab(tabID, title: resolvedTitle ?? fallback, url: url)
        // The new URL can change which boosts apply: this tab's now, the rest with the follow-up.
        if let tab = store.tab(withID: tabID) {
            engineHost.installBoosts(store.activeBoostEntries(for: tab), forTabID: tabID, profileID: profileID(for: tab))
        }
    }

    func handleLittleArcNavigationCommit(windowID: LittleArcWindow.ID, url: URL?, title: String?) {
        guard let url else { return }
        let resolvedTitle = (title?.isEmpty == false) ? title : nil
        store.updateLittleArcWindow(id: windowID, title: resolvedTitle, url: url)
    }

    /// Subscribes to tabs that already have an engine. Creating one here would
    /// reload every sidebar tab's engine (a blank Chromium tab each) and undo
    /// unloading a favorite.
    private func wireMediaObserver(for tab: Tab) {
        guard mediaSubscriptions[tab.id] == nil,
              let engine = engineHost.engine(forTabID: tab.id, profileID: profileID(for: tab)) else { return }
        mediaSubscriptions[tab.id] = engine.mediaStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.applyMediaState(state, tabID: tab.id, tab: tab)
            }
        if captureSubscriptions[tab.id] == nil, let capturing = engine as? MediaCaptureProviding {
            captureSubscriptions[tab.id] = capturing.mediaCapturePublisher
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.captureStateByTab[tab.id] = state.isInCall ? state : nil
                }
        }
    }

    private func applyMediaState(_ state: WebMediaState, tabID: Tab.ID, tab: Tab) {
        if mediaStateByTab[tabID]?.isPictureInPicture == true, !state.isPictureInPicture {
            // Left PiP (its window closed, the page, back to tab): nothing to undo on return.
            autoPiPEnteredTabIDs.remove(tabID)
        }
        mediaStateByTab[tabID] = state
        if !state.isAudible, !tabMuteModel.userMutedTabIDs.contains(tabID) {
            tabMuteModel.markUserUnmuted(tabID)
        }
        if tabMuteModel.userMutedTabIDs.contains(tabID), state.isAudible {
            let pid = profileID(for: tab)
            engineHost.setMuted(true, forTabID: tabID, profileID: pid)
        }
        refreshNowPlaying()
        evaluateAutoPiPIfNeeded(for: tab)
    }

    func reconcileEngineOwnership() {
        ModelSignposts.measure(ModelSignposts.model, "ReconcileEngines") { reconcileEngineOwnershipNow() }
    }

    private func reconcileEngineOwnershipNow() {
        themeColors.retain(spaces: store.spaces)
        var tabKeys = Set<EngineHost.TabEngineKey>()
        for space in store.spaces {
            for tab in store.displayTabs(in: space.id) {
                tabKeys.insert(EngineHost.TabEngineKey(tabID: tab.id, profileID: profileID(for: tab)))
            }
        }
        engineHost.pruneTabEngines(retaining: tabKeys)

        var littleKeys = Set<EngineHost.LittleArcEngineKey>()
        for window in store.littleArcLiveWindows {
            littleKeys.insert(EngineHost.LittleArcEngineKey(id: window.id, profileID: window.profileID))
        }
        engineHost.pruneLittleArcEngines(retaining: littleKeys)

        if let session = peekSession {
            engineHost.pruneEphemeralEngines(retaining: [
                EngineHost.EphemeralEngineKey(id: session.engineID, profileID: session.profileID)
            ])
        } else {
            engineHost.pruneEphemeralEngines(retaining: [])
        }

        let liveTabIDs = Set(tabKeys.map(\.tabID))
        faviconObservedEngines = faviconObservedEngines.filter { liveTabIDs.contains($0.key) }
        titleObservedEngines = titleObservedEngines.filter { liveTabIDs.contains($0.key) }
        for id in mediaSubscriptions.keys where !liveTabIDs.contains(id) {
            mediaSubscriptions[id] = nil
            mediaStateByTab[id] = nil
            tabMuteModel.markUserUnmuted(id)
        }
        for id in captureSubscriptions.keys where !liveTabIDs.contains(id) {
            captureSubscriptions[id] = nil
            captureStateByTab[id] = nil
        }
    }

    private func evaluateAutoPiPIfNeeded(for tab: Tab? = nil) {
        let candidates: [Tab]
        if let tab {
            candidates = [tab]
        } else {
            candidates = store.spaces.flatMap { store.displayTabs(in: $0.id) }
        }
        for candidate in candidates {
            let state = mediaState(for: candidate.id)
            let hasVideo = state.isPlaying && state.canPictureInPicture && !state.isPictureInPicture
            guard automaticPictureInPicture else { return }
            let decision = AutoPiPPolicy.shouldAutoPiP(
                host: candidate.url.host(),
                occlusionState: windowOcclusionState,
                now: Date(),
                hasPlayingVideo: hasVideo,
                settings: store.autoPiPPolicy
            )
            guard case .trigger = decision else { continue }
            guard autoPiPTriggeredThisOcclusion.insert(candidate.id).inserted else { continue }
            // The window is covered, so its sidebar cannot show the video: use the floating panel.
            if engineHost.supportsLiveVideo { livePanelRequests.insert(candidate.id) }
            engineHost.engine(for: candidate, profileID: profileID(for: candidate)).pictureInPicture()
        }
    }

    private func wireMediaKeyHandlers() {
        nowPlaying.onPlayPause = { [weak self] in self?.routeMediaKeyPlayPause() }
        nowPlaying.onNext = { [weak self] in self?.routeMediaKeySkipNext() }
        nowPlaying.onPrevious = { [weak self] in self?.routeMediaKeySkipPrevious() }
    }

    private func routeMediaKeyPlayPause() {
        guard let tabID = MediaSessionRouting.primaryMediaTab(
            mediaByTab: mediaStateByTab,
            selectedTabID: store.selectedTabID
        ),
              let pid = profileID(forTabID: tabID),
              let engine = engineHost.engine(forTabID: tabID, profileID: pid) else { return }
        engine.togglePlayPause()
    }

    private func routeMediaKeySkipNext() {
        guard let tabID = MediaSessionRouting.primaryMediaTab(
            mediaByTab: mediaStateByTab,
            selectedTabID: store.selectedTabID
        ),
              let pid = profileID(forTabID: tabID),
              let engine = engineHost.engine(forTabID: tabID, profileID: pid) else { return }
        engine.skipToNextTrack()
    }

    private func routeMediaKeySkipPrevious() {
        guard let tabID = MediaSessionRouting.primaryMediaTab(
            mediaByTab: mediaStateByTab,
            selectedTabID: store.selectedTabID
        ),
              let pid = profileID(forTabID: tabID),
              let engine = engineHost.engine(forTabID: tabID, profileID: pid) else { return }
        engine.skipToPreviousTrack()
    }

    private func refreshNowPlaying() {
        guard let tabID = MediaSessionRouting.primaryMediaTab(
            mediaByTab: mediaStateByTab,
            selectedTabID: store.selectedTabID
        ), let tab = store.tab(withID: tabID) else {
            nowPlaying.clearNowPlaying()
            return
        }
        let state = mediaState(for: tabID)
        guard state.isPlaying || state.isAudible else {
            nowPlaying.clearNowPlaying()
            return
        }
        nowPlaying.updateNowPlaying(state: state, tabTitle: tab.title)
    }

    var automaticPeekEnabled = UserDefaults.standard.object(forKey: "rearc.automaticPeek") as? Bool ?? true {
        didSet {
            externalLinkDefaults.set(automaticPeekEnabled, forKey: "rearc.automaticPeek")
            reconfigureLinkPeek()
        }
    }

    func configureLinkPeek(on engine: any WebEngine, tab: Tab? = nil) {
        engine.automaticPeekSourceURL = automaticPeekEnabled && tab?.kind != .today ? tab.map { $0.savedURL ?? $0.url } : nil
        let profileID = tab.map { self.profileID(for: $0) }
        engine.linkPeekHandler = { [weak self] url in
            self?.showPeek(url: url, profileID: profileID)
        }
        (engine as? ShiftClickPeekConfigurable)?.shiftClickPeekEnabled = peekOnShiftClick
        configureLittleArcClicks(on: engine)
    }

    /// After a Links setting changes: every tab's engine again.
    func reconfigureLinkPeek() {
        for (id, _, engine) in engineHost.allTabEngines() {
            configureLinkPeek(on: engine, tab: store.tab(withID: id))
        }
    }

    // MARK: - Peek

    func showPeek(url: URL, profileID: Profile.ID? = nil) {
        PerfSignposts.interaction(.peekOpen)
        dismissPeek()
        let originProfile = profileID ?? store.activeProfileID
        let (engineID, engine) = engineHost.ephemeralEngine(profileID: originProfile)
        engine.linkPeekHandler = nil
        engine.load(url)
        scheduleTransientWarmup()
        peekSession = PeekSession(
            url: url,
            title: url.host() ?? url.absoluteString,
            engineID: engineID,
            profileID: originProfile
        )
        if let wk = engine as? NavigationCommitReporting {
            wk.onNavigationCommit = { [weak self] navURL, title in
                guard let self, var session = self.peekSession, session.engineID == engineID else { return }
                if let navURL { session.url = navURL }
                if let title, !title.isEmpty { session.title = title }
                else if let navURL { session.title = navURL.host() ?? session.title }
                self.peekSession = session
            }
        }
    }

    func dismissPeek() {
        guard let session = peekSession else { return }
        engineHost.removeEphemeral(id: session.engineID, profileID: session.profileID)
        peekSession = nil
    }

    /// Opens `url` in a new Today tab of the active space and selects it.
    @discardableResult
    func openInNewTab(_ url: URL) -> Tab {
        let tab = store.addTab(kind: .today, title: url.host() ?? "New Tab", url: url)
        store.selectTab(tab.id)
        engineHost.engine(for: tab, profileID: profileID(for: tab)).load(url)
        loadSelectedIfNeeded()
        return tab
    }

    func peekOpenInFullTab() {
        guard let session = peekSession else { return }
        let url = session.url
        let originProfile = session.profileID
        dismissPeek()
        if store.activeProfileID != originProfile {
            store.selectProfile(originProfile)
        }
        let tab = store.addTab(kind: .today, title: url.host() ?? "New Tab", url: url)
        store.selectTab(tab.id)
        engineHost.engine(for: tab, profileID: originProfile).load(url)
        loadSelectedIfNeeded()
    }

    func peekOpenInLittleArc() {
        guard let session = peekSession else { return }
        let url = session.url
        let originProfile = session.profileID
        dismissPeek()
        openLittleArc(url: url, profileID: originProfile)
    }

    func peekCopyLink() {
        guard let url = peekSession?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func peekEngineView() -> AnyView? {
        guard let session = peekSession,
              let engine = engineHost.ephemeralEngine(withID: session.engineID, profileID: session.profileID)
        else { return nil }
        return engine.makeView()
    }

    func clearLittleArcOpenRequests() {
        littleArcOpenRequests = []
    }

    func requestLittleArcWindow(_ id: LittleArcWindow.ID) {
        if let windowPresenter {
            windowPresenter.presentLittleArcWindow(id)
        } else {
            littleArcOpenRequests.append(id)
        }
    }

    // MARK: - Page zoom

    /// The engine of the selected tab (the focused pane in a split).
    var focusedEngine: (any WebEngine)? {
        guard store.selectedEaselRef == nil, let tab = store.selectedTab else { return nil }
        return engineHost.engine(forTabID: tab.id, profileID: profileID(for: tab))
    }

    /// Cmd+= / Cmd+- / Cmd+0 on the key window's page: a private window's,
    /// else the focused tab's.
    func zoom(_ step: PageZoom.Step) {
        guard let engine = keyPrivateWindow?.engine ?? focusedEngine else { return }
        engine.setZoomFactor(PageZoom.factor(after: step, from: engine.zoomFactor))
    }

    // MARK: - Little Arc

    func restoreLittleArcWindowsIfNeeded() {
        guard !startupDeferred, !didRestoreLittleArcWindows else { return }
        didRestoreLittleArcWindows = true
        for window in store.littleArcLiveWindows {
            requestLittleArcWindow(window.id)
        }
    }

    @discardableResult
    func openLittleArc(url: URL, title: String? = nil, profileID: Profile.ID? = nil) -> LittleArcWindow {
        PerfSignposts.interaction(.littleArcOpen)
        let originProfile = profileID ?? store.activeProfileID
        let preparedID = engineHost.takePreparedLittleArc(profileID: originProfile)
        let record = store.createLittleArcWindow(id: preparedID ?? UUID(), url: url, title: title, profileID: originProfile)
        scheduleTransientWarmup()
        requestLittleArcWindow(record.id)
        loadLittleArcIfNeeded(record.id)
        return record
    }

    func littleArcEngine(for id: LittleArcWindow.ID) -> any WebEngine {
        guard let record = store.littleArcWindow(withID: id) else {
            return engineHost.engine(forLittleArc: id, profileID: store.activeProfileID)
        }
        return engineHost.engine(forLittleArc: id, profileID: record.profileID)
    }

    func loadLittleArcIfNeeded(_ id: LittleArcWindow.ID) {
        guard let record = store.littleArcWindow(withID: id) else { return }
        let engine = engineHost.engine(forLittleArc: id, profileID: record.profileID)
        engine.linkPeekHandler = nil
        if engine.currentURL != record.url {
            engine.load(record.url)
        }
        if let wk = engine as? NavigationCommitReporting {
            wk.onNavigationCommit = { [weak self] url, title in
                self?.handleLittleArcNavigationCommit(windowID: id, url: url, title: title)
            }
        }
    }

    func touchLittleArcIfNeeded(_ id: LittleArcWindow.ID) {
        store.touchLittleArcWindow(id: id)
    }

    func closeLittleArcWindow(_ id: LittleArcWindow.ID) {
        let profileID = store.littleArcWindow(withID: id)?.profileID ?? store.activeProfileID
        store.archiveLittleArcWindow(id: id, reason: .manual)
        engineHost.removeLittleArc(id, profileID: profileID)
        if focusedLittleArcID == id { focusedLittleArcID = nil }
    }

    func promoteLittleArcWindow(_ id: LittleArcWindow.ID, into spaceID: Space.ID? = nil) {
        let originProfile = store.littleArcWindow(withID: id)?.profileID
            ?? store.archivedLittleArcWindows.first(where: { $0.id == id })?.window.profileID
        // The last focused browser window: Little Arc never becomes it.
        let target = store.keyWindowID
        guard store.promoteLittleArcToTab(id: id, into: spaceID) != nil else { return }
        if let originProfile {
            engineHost.removeLittleArc(id, profileID: originProfile)
        }
        if focusedLittleArcID == id { focusedLittleArcID = nil }
        loadSelectedIfNeeded()
        // Otherwise AppKit keys whichever window is next when the Little Arc
        // closes, and a browser window on another space would take over.
        if let target { windowPresenter?.focusBrowserWindow(target) }
    }

    func promoteFocusedLittleArcToTab() {
        if let id = focusedLittleArcID {
            promoteLittleArcWindow(id)
            return
        }
        if let id = store.littleArcLiveWindows.last?.id {
            promoteLittleArcWindow(id)
        }
    }

    func openInLittleArcFromContext() {
        if peekSession != nil {
            peekOpenInLittleArc()
            return
        }
        guard let tab = store.selectedTab else { return }
        openLittleArc(url: tab.url, title: tab.title)
    }

    func prepareForQuit() {
        autoArchiveTimer?.invalidate()
        store.autoArchiveIdleLittleArcWindows(threshold: littleArcArchiveAfter.interval, keeping: Set([keyLittleArcID].compactMap { $0 }))
        boostLiveDebounceWorkItem?.cancel()
        for (_, draft) in boostEditorDraftByTab {
            _ = store.updateBoostStyleCSS(packageID: draft.packageID, css: draft.draftCSS)
        }
        boostEditorDraftByTab.removeAll()
        easelStore.flushAllCachedDocuments()
        persistence.flush()
        saveVisitHistory()
        downloads.save()
    }

    // MARK: - Command bar

    /// Cmd+T: the field takes focus without mutating or replacing the page.
    /// Choosing a page creates its Today tab; Escape has nothing to undo.
    func newTab() {
        PerfSignposts.interaction(.newTab)
        let previous = store.selectedTabID
        openCommandBar(target: nil, text: "")
        commandBarCreatesNewTab = true
        commandBarSplitAnchorID = previous
        commandBarFocusRequest += 1
    }

    /// Cmd+L: open the command bar aimed at the selected tab, its URL filled
    /// in and selected; pressed again it closes the bar (Arc's
    /// `toggleOpenOmnibox:`).
    func focusLocation() {
        PerfSignposts.interaction(.commandBarOpen, isCommandBarPresented ? "close" : "open")
        if isCommandBarPresented {
            dismissCommandBar()
            return
        }
        if let id = keyLittleArcID, store.littleArcWindow(withID: id) != nil {
            littleArcFocusRequest = id
            return
        }
        guard let selected = store.selectedTab else {
            newTab()
            return
        }
        let text = selected.url.absoluteString == "about:blank" ? "" : selected.url.absoluteString
        openCommandBar(target: selected.id, text: text)
    }

    /// The site Tab would search for the typed word, shown as a hint.
    var commandBarSiteSearchSuggestion: SiteSearchEngine? {
        guard commandBarSiteSearch == nil, commandBarURLIntent == nil, !commandBarText.hasPrefix(">") else { return nil }
        return SiteSearchCatalog.match(commandBarText)
    }

    /// Tab in the command bar: the typed site name becomes a search pill.
    /// Returns false (Tab keeps its usual meaning) when nothing matches.
    @discardableResult
    func enterCommandBarSiteSearch() -> Bool {
        guard let engine = commandBarSiteSearchSuggestion else { return false }
        commandBarTextBeforeSiteSearch = commandBarText
        commandBarSiteSearch = engine
        commandBarText = ""
        commandBarError = nil
        return true
    }

    /// Delete on an empty query removes the pill and restores the text.
    @discardableResult
    func exitCommandBarSiteSearch() -> Bool {
        guard commandBarSiteSearch != nil, commandBarText.isEmpty else { return false }
        commandBarSiteSearch = nil
        commandBarText = commandBarTextBeforeSiteSearch
        commandBarTextBeforeSiteSearch = ""
        return true
    }

    func dismissCommandBar() {
        commandBarCreatesNewTab = false
        isCommandBarPresented = false
        commandBarMenuSnapshot = nil
        cancelCommandBarLive()
        commandBarSiteSearch = nil
        commandBarTextBeforeSiteSearch = ""
        commandBarTargetID = nil
        commandBarText = ""
        commandBarHighlightedIndex = 0
        commandBarError = nil
        commandBarURLIntent = nil
        restorePageFocus()
    }

    func moveCommandBarHighlight(by delta: Int) {
        let count = commandBarResults.count
        guard count > 0 else {
            commandBarHighlightedIndex = 0
            return
        }
        let next = commandBarHighlightedIndex + delta
        commandBarHighlightedIndex = min(max(next, 0), count - 1)
    }

    /// Return in the command bar; ⌘↩, ⌥↩ and ⇧↩ pick another destination
    /// for a page result (`CommandBarRoute`). Commands ignore the route.
    func submitCommandBar(route: CommandBarRoute = .current) {
        if let intent = commandBarURLIntent {
            guard let url = URLEntry.resolve(commandBarText, engine: engineHost.navigationSchemes, provider: searchProvider) else {
                commandBarError = "Enter a valid URL"
                return
            }
            switch intent {
            case .peek:
                showPeek(url: url)
            case .littleArc:
                openLittleArc(url: url)
            }
            dismissCommandBar()
            return
        }

        let results = commandBarResults
        if !results.isEmpty {
            let index = min(max(commandBarHighlightedIndex, 0), results.count - 1)
            let choice = results[index]
            switch choice.kind {
            case .openTab:
                if route != .current, let tabID = choice.tabID, let tab = store.tab(withID: tabID) {
                    routeCommandBar(to: tab.url, route)
                    return
                }
                if let tabID = choice.tabID {
                    store.focusTab(tabID)
                    loadSelectedIfNeeded()
                    dismissCommandBar()
                    return
                }
            case .command:
                if let id = choice.menuCommandID {
                    dismissCommandBar()
                    DispatchQueue.main.async { _ = MainMenuCommandIndex.perform(id) }
                    return
                }
                if let action = choice.commandAction {
                    if action == .peekAtURL || action == .openLittleArcWindow {
                        executeCommand(action, commandID: choice.commandID)
                        return
                    }
                    let error = executeCommand(action, commandID: choice.commandID)
                    if let error {
                        commandBarError = error
                    } else {
                        dismissCommandBar()
                    }
                    return
                }
            case .openURL, .history, .suggestion, .search:
                if let url = choice.destinationURL {
                    routeCommandBar(to: url, route)
                    return
                }
            }
        }

        guard let url = URLEntry.resolve(commandBarText, engine: engineHost.navigationSchemes, provider: searchProvider) else {
            dismissCommandBar()
            return
        }
        routeCommandBar(to: url, route)
        if route == .current { loadSelectedIfNeeded() }
    }

    /// Opens a Chromium-owned page (settings, version, history, downloads,
    /// passwords, extensions) instead of a shell reimplementation, reusing a
    /// tab already showing that WebUI host. Pages the engine does not admit
    /// (no `webui_daily_pages` for the daily-use hosts) do nothing.
    func openBrowserPage(_ page: BrowserInternalPage) {
        guard page.isAvailable(engine: engineHost.navigationSchemes) else { return }
        if let existing = store.displayTabs().first(where: { page.isShown(by: $0.url) }) {
            store.updateTab(existing.id, title: page.title, url: page.url)
            store.focusTab(existing.id)
        } else {
            let tab = store.addTab(kind: .today, title: page.title, url: page.url)
            store.selectTab(tab.id)
        }
        loadSelectedIfNeeded()
    }

    func viewSelectedPageSource() {
        guard let current = store.selectedTab,
              let url = NavigationURLPolicy.viewSourceURL(for: current.url, engine: engineHost.navigationSchemes)
        else { return }
        let tab = store.addTab(kind: .today, title: "Source: \(current.title)", url: url)
        store.selectTab(tab.id)
        loadSelectedIfNeeded()
    }

    func navigateCommandBar(to url: URL) {
        guard NavigationURLPolicy.allows(url, engine: engineHost.navigationSchemes) else {
            commandBarError = "That URL scheme is not allowed"
            return
        }
        if commandBarCreatesNewTab {
            openInNewTab(url)
            return
        }
        let targetID = commandBarTargetID ?? store.selectedTabID
        if let targetID, let existing = store.tab(withID: targetID) {
            if existing.kind == .favorite {
                let tab = store.addTab(kind: .today, title: url.host() ?? commandBarText, url: url)
                store.selectTab(tab.id)
                engineHost.engine(for: tab, profileID: profileID(for: tab)).load(url)
            } else {
                store.updateTab(targetID, title: url.host() ?? existing.title, url: url)
                store.selectTab(targetID)
                if let tab = store.tab(withID: targetID) {
                    engineHost.engine(for: tab, profileID: profileID(for: tab)).load(url)
                }
            }
        }
    }

    private func openCommandBar(target: Tab.ID?, text: String) {
        commandBarMenuSnapshot = nil
        commandBarCreatesNewTab = false
        commandBarSiteSearch = nil
        commandBarSplitAnchorID = nil
        commandBarTargetID = target
        commandBarText = text
        commandBarError = nil
        isCommandBarPresented = true
        commandBarServices.commandBarWillOpen(profileID: store.activeProfileID)
        // ⌘L's URL asks at once: its first frame already waits for the bar.
        refreshCommandBarLive(immediately: true)
        // The first keystroke then finds the menu read and the indexes built.
        commandBarAfterCommit.schedule { [weak self] in self?.prepareCommandBarIndexes() }
    }

    /// Reads the menu snapshot and builds the tab, command and menu indexes.
    func prepareCommandBarIndexes() {
        guard isCommandBarPresented else { return }
        _ = commandBarTabIndex
        _ = commandBarMenuIndex(registered: commandBarCommandIndex.catalog)
    }

    // MARK: - Command bar live results

    /// Every edit starts new lookups and cancels the last; only web input
    /// in an open bar asks (not commands, site-search pills or URL prompts).
    /// A keystroke's lookups start after its frame is committed: Chromium
    /// runs its synchronous omnibox providers inside the calls, on the main
    /// thread. Keys typed within one frame ask only for the newest text.
    func refreshCommandBarLive(immediately: Bool = false) {
        let text = commandBarText
        guard isCommandBarPresented, commandBarSiteSearch == nil, commandBarURLIntent == nil, !text.hasPrefix(">"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelCommandBarLive()
            return
        }
        if let live = commandBarLive, !live.applies(to: text) { commandBarLive = nil }
        let generation = commandBarGate.begin(text)
        let waiting = pendingCommandBarQuery != nil
        pendingCommandBarQuery = (text, generation)
        if immediately {
            startPendingCommandBarQuery()
        } else if !waiting {
            commandBarAfterCommit.schedule { [weak self] in self?.startPendingCommandBarQuery() }
        }
    }

    /// Starts the engine lookups for the newest text, if it is still current.
    func startPendingCommandBarQuery() {
        guard let (text, generation) = pendingCommandBarQuery else { return }
        pendingCommandBarQuery = nil
        guard commandBarGate.isCurrent(generation) else { return }
        commandBarServices.query(text, profileID: store.activeProfileID, isPrivate: false) { [weak self] live in
            guard let self, self.commandBarGate.isCurrent(generation) else { return }
            self.commandBarLive = live
        }
    }

    func cancelCommandBarLive() {
        commandBarGate.cancel()
        pendingCommandBarQuery = nil
        commandBarServices.cancel()
        commandBarLive = nil
    }

    /// The WebKit search preference (provider and suggestions); nil on
    /// Chromium, whose default search lives in chrome://settings/search.
    var webKitSearchPreference: SearchProviderPreference? {
        get {
            _ = searchProviderRevision
            return (commandBarServices as? WebKitCommandBarServices)?.preference
        }
        set {
            guard let newValue, let services = commandBarServices as? WebKitCommandBarServices else { return }
            services.preference = newValue
        }
    }

    private func observeSearchProvider() {
        commandBarServices.onSearchProviderChange = { [weak self] in self?.searchProviderRevision += 1 }
        searchProviderRevision += 1
    }

    /// Copy URL / Remove from History on a command-bar row.
    func performCommandBarRowAction(_ action: CommandBarRowAction, on result: CommandBarSearch.Result) {
        guard let url = result.destinationURL else { return }
        switch action {
        case .copyURL:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
        case .deleteFromHistory:
            deleteFromHistory(url)
        }
    }

    /// Removes a page from the shell's visit store and from the engine's
    /// history (Chromium HistoryService), then asks again for the typed text.
    func deleteFromHistory(_ url: URL) {
        removeFromVisitHistory(url)
        if var live = commandBarLive, let history = live.history {
            let key = VisitHistory.key(for: url)
            live.history = history.filter { VisitHistory.key(for: $0.url) != key }
            commandBarLive = live
        }
        let profileID = store.activeProfileID
        _ = commandBarServices.deleteFromHistory(url, profileID: profileID) { [weak self] _ in
            self?.refreshCommandBarLive()
        }
    }

    /// Shift+Delete on the highlighted row: remove it from history.
    @discardableResult
    func deleteHighlightedCommandBarHistoryRow() -> Bool {
        let results = commandBarResults
        guard results.indices.contains(commandBarHighlightedIndex) else { return false }
        let result = results[commandBarHighlightedIndex]
        guard CommandBarSearch.rowActions(for: result).contains(.deleteFromHistory) else { return false }
        performCommandBarRowAction(.deleteFromHistory, on: result)
        return true
    }

    func reopenClosedTab() {
        guard let tab = store.reopenMostRecentClosedTab() else { return }
        // A reopened split brings back every pane; panes already open keep their pages.
        for pane in store.splitContaining(tabID: tab.id)?.split.tabs ?? [tab]
        where pane.id == tab.id || engineHost.engine(forTabID: pane.id, profileID: profileID(for: pane)) == nil {
            engineHost.engine(for: pane, profileID: profileID(for: pane)).load(pane.url)
        }
        loadSelectedIfNeeded()
    }

    /// Runs a palette command. Returns an error message when the action could not complete.
    @discardableResult
    func executeCommand(_ action: AppCommandAction, commandID: String?) -> String? {
        if let commandID {
            store.bumpCommandUsage(commandID)
        }
        switch action {
        case .newTab:
            let tab = store.addTab(kind: .today, title: "New Tab", url: URL(string: "about:blank")!)
            store.selectTab(tab.id)
            loadSelectedIfNeeded()
        case .closeTab:
            guard store.selectedTabID != nil else { return "No tab selected" }
            closeSelectedTab()
        case .reopenClosedTab:
            guard store.closedTabStack.canReopen else { return "No closed tabs to reopen" }
            reopenClosedTab()
        case .pinTab:
            guard let id = store.selectedTabID, store.pinTab(id) else { return "Cannot pin this tab" }
            loadSelectedIfNeeded()
        case .unpinTab:
            guard let id = store.selectedTabID, store.unpinTab(id) else { return "Cannot unpin this tab" }
            loadSelectedIfNeeded()
        case .moveTabToSpace(let spaceID):
            guard let id = store.selectedTabID, store.moveTab(id, toSpace: spaceID) else {
                return "Cannot move this tab"
            }
            loadSelectedIfNeeded()
        case .switchToSpace(let spaceID):
            selectSpace(spaceID)
        case .switchToProfile(let profileID):
            selectProfile(profileID)
        case .moveSpaceToProfile(let profileID):
            requestSpaceProfileChange(store.activeSpaceID, to: profileID)
        case .createProfile:
            beginProfileCreation()
        case .renameActiveProfile:
            pendingProfileRenameID = store.activeProfileID
            pendingProfileRenameName = store.activeProfile.name
        case .createSpace:
            beginSpaceCreation()
        case .toggleSidebar:
            toggleSidebar()
        case .addSplitRight:
            addSplitView(orientation: .horizontal)
        case .addSplitBottom:
            addSplitView(orientation: .vertical)
        case .separateFromSplit:
            guard let tab = store.selectedTab else { return "No tab selected" }
            guard store.splitContaining(tabID: tab.id) != nil else { return "Tab is not in a split" }
            unsplitTabIfInSplit(tab.id)
        case .nextTab:
            selectNextTab()
        case .previousTab:
            selectPreviousTab()
        case .peekAtURL:
            commandBarURLIntent = .peek
            commandBarText = ""
            commandBarError = nil
        case .openLittleArcWindow:
            commandBarURLIntent = .littleArc
            commandBarText = ""
            commandBarError = nil
        case .openInLittleArc:
            openInLittleArcFromContext()
        case .promoteLittleArcToTab:
            promoteFocusedLittleArcToTab()
        case .muteTab:
            guard let id = store.selectedTabID else { return "No tab selected" }
            muteTab(id)
        case .unmuteAllTabs:
            engineHost.unmuteAllTabs()
            tabMuteModel.clearAllUserMutes()
        case .pauseAllMedia:
            engineHost.pauseAllMedia()
        case .snoozeAutoPiPForSite:
            guard let host = store.selectedTab?.url.host() else { return "No site selected" }
            store.snoozeAutoPiP(forHost: host)
        case .togglePictureInPicture:
            dismissCommandBar()
            togglePictureInPicture()
        case .printPage:
            dismissCommandBar()
            printPage()
        case .exportPageAsPDF:
            dismissCommandBar()
            exportPageAsPDF()
        case .newBoostForSite:
            guard let tab = store.selectedTab else { return "No tab selected" }
            let host = tab.url.host() ?? "site"
            guard let created = store.createBoostForCurrentSite(
                name: "Boost for \(host)",
                css: "/* ReArc boost */\n",
                pageURL: tab.url
            ) else {
                return "Cannot create boost for this page"
            }
            syncAllTabBoosts()
            openBoostEditor(packageID: created.manifest.id, startPicker: true)
        case .editBoost(let packageID):
            editBoost(packageID)
        case .newLegacyBoost:
            return newLegacyBoost()
        case .importBoosts:
            BoostFilePanels.importBoosts(model: self)
        case .importBookmarksFile:
            importBookmarksFile()
        case .importFromBrowser:
            showBrowserImport()
        case .reinstallExtensions:
            startPendingExtensionReinstall()
        case .pickElementToEdit:
            if boostEditorDraft != nil {
                startBoostPicker()
            } else if let tab = store.selectedTab {
                let matches = store.boostsMatchingPage(tab.url)
                if let pkg = matches.first?.0 {
                    openBoostEditor(packageID: pkg.manifest.id, startPicker: true)
                }
            }
        case .manageBoosts:
            isBoostLibraryPresented = true
        case .setAsDefaultBrowser:
            setAsDefaultBrowser()
        case .setExternalLinkDestination(let destination):
            externalLinkDestination = destination
        case .showSiteControlCenter:
            dismissCommandBar()
            showSiteControlCenter()
        case .showAirTrafficControl:
            dismissCommandBar()
            showAirTrafficControl()
        case .toggleBoost(let packageID):
            let library = store.boostLibrary()
            guard let install = library.installation(for: packageID) else {
                return "Boost not found"
            }
            store.setBoostInstallationEnabled(packageID: packageID, enabled: !install.enabled)
            syncAllTabBoosts()
        case .newEasel:
            _ = createEasel()
        case .newNote:
            _ = createEasel(title: "Note", note: true)
        case .capturePage:
            Task { await performCapture(scope: .fullPage) }
        case .captureVisibleArea:
            Task { await performCapture(scope: .visible) }
        case .captureAreaOrElement:
            return beginPageCapture()
        case .capturePortrait:
            Task { await capturePortrait() }
        case .openCapturesGallery:
            openLibrary(.media)
        case .openLibrary(let section):
            openLibrary(section)
        case .openBrowserPage(let page):
            guard page.isAvailable(engine: engineHost.navigationSchemes) else {
                return engineHost.navigationSchemes.contains(.trustedWebUI)
                    ? "\(page.title) needs a newer Chromium engine"
                    : "\(page.title) needs the Chromium engine"
            }
            openBrowserPage(page)
        case .viewPageSource:
            guard let tab = store.selectedTab,
                  NavigationURLPolicy.viewSourceURL(for: tab.url, engine: engineHost.navigationSchemes) != nil else {
                return "Page source is not available for this tab"
            }
            viewSelectedPageSource()
        case .goBack:
            goBack()
        case .goForward:
            goForward()
        case .reloadPage:
            reload()
        case .reloadIgnoringCache:
            reload(ignoringCache: true)
        case .stopLoading:
            stopLoading()
        case .copyURL:
            copyURL()
        case .copyURLAsMarkdown:
            copyURL(format: .markdown)
        case .copyAsQuote:
            copyURL(format: .quote)
        case .flipSplitOrientation:
            flipSplitOrientation()
        case .expandSplitPane:
            toggleExpandedSplitPane()
        case .expandPinnedSection:
            setPinnedSectionCollapsed(false)
        case .collapsePinnedSection:
            setPinnedSectionCollapsed(true)
        case .nextSpace:
            cycleSpace(forward: true)
        case .previousSpace:
            cycleSpace(forward: false)
        case .renameSpace:
            beginRename(.space(store.activeSpaceID))
        case .editSpaceTheme:
            spaceEditorID = store.activeSpaceID
        case .setSpaceAppearance(let appearance):
            setSpaceAppearance(appearance)
        case .deleteSpace:
            guard canDeleteSpaces else { return "The last space cannot be deleted" }
            pendingDeletion = .space(store.activeSpaceID)
        case .newFolder:
            newFolder()
        case .expandAllFolders:
            store.setAllFoldersExpanded(true)
        case .collapseAllFolders:
            store.setAllFoldersExpanded(false)
        case .addToFavorites:
            guard let id = store.selectedTabID, store.kind(of: id) != .favorite else { return "Cannot add this tab to Favorites" }
            addToFavorites(id)
        case .removeFromFavorites:
            guard let id = store.selectedTabID, store.kind(of: id) == .favorite else { return "Not a favorite" }
            removeFavorite(id)
        case .renameTab:
            guard let id = store.selectedTabID else { return "No tab selected" }
            beginRename(.tab(id))
        case .duplicateTab:
            duplicateTab()
        case .archiveTab:
            guard let id = store.selectedTabID, store.archiveTab(id) != nil else { return "Cannot archive this tab" }
            releaseEngine(for: id)
            loadSelectedIfNeeded()
        case .viewArchive:
            isArchivePresented = true
        case .resetTabToOriginalURL:
            resetTabToSavedURL()
        case .resetPinnedTabsInSpace:
            resetPinnedTabs()
        case .updatePinnedURL:
            updateSavedURLToCurrent()
        case .clearUnpinnedTabs:
            clearTodayTabs()
        case .findInPage:
            guard findTargetEngine != nil else { return "No page to search" }
            dismissCommandBar()
            showFindBar()
        case .showDownloads:
            dismissCommandBar()
            downloads.isTrayPresented = true
        case .clearCommandBarHistory:
            clearVisitHistory()
        }
        return nil
    }
}
