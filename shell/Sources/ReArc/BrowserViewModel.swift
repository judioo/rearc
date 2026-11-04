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
    let easelStore = EaselDocumentStore()
    let captureFileStore = CaptureFileStore()
    let faviconStore: FaviconStore
    private let persistence: SidebarFilePersistence
    private let syncPipeline: SyncOutboundPipeline
    let syncEngine: SyncEngine
    private(set) var syncStatus: SyncEngineStatus = .local
    private let nowPlaying: MediaKeyRouting
    private var mediaSubscriptions: [Tab.ID: AnyCancellable] = [:]

    var mediaStateByTab: [Tab.ID: WebMediaState] = [:]
    var tabMuteModel = TabMediaMuteModel()
    private(set) var windowOcclusionState: WindowOcclusionState = .visible
    private var autoPiPTriggeredThisOcclusion: Set<Tab.ID> = []

    var isSidebarVisible = true
    /// Points; dragged from the sidebar's trailing edge, saved when the drag ends.
    var sidebarWidth: CGFloat = SidebarWidth.load()
    /// The hidden sidebar shown floating while the pointer is at the window's
    /// leading edge (Arc `SidebarHovering` / floating sidebar).
    var isSidebarPeeking = false
    var isArchivePresented = false
    /// Where links from other apps open; remembered across launches.
    var externalLinkDestination: ExternalLinkDestination = .load(from: .standard) {
        didSet { externalLinkDestination.save(to: externalLinkDefaults) }
    }
    @ObservationIgnored var externalLinkDefaults: UserDefaults = .standard
    @ObservationIgnored var defaultBrowser: any DefaultBrowserSetting = SystemDefaultBrowser()
    /// Bumped when the default-browser state may have changed (menus re-read it).
    var defaultBrowserRevision = 0
    var defaultBrowserMessage: String?
    /// View Boosts: the Boosts library sheet.
    var isBoostLibraryPresented = false
    /// Space being edited in the Edit Space sheet (name, theme, icon).
    var spaceEditorID: Space.ID?
    /// The New Space dialog's fields while it is open.
    var spaceCreationDraft: SpaceDraft?
    /// Today tabs archived by the last Clear, for Undo.
    var lastClearedTabIDs: [Tab.ID] = []
    var pendingRename: SidebarRenameRequest?
    var pendingRenameText = ""
    var pendingDeletion: SidebarDeletionRequest?
    /// A space waiting for confirmation to move to another profile.
    var pendingSpaceProfileChange: SpaceProfileChange?
    @ObservationIgnored var autoArchiveTimer: Timer?
    /// Engine whose favicon is being tracked, per tab.
    @ObservationIgnored var faviconObservedEngines: [Tab.ID: ObjectIdentifier] = [:]
    var isCommandBarPresented = false
    var commandBarText = "" {
        didSet {
            commandBarHighlightedIndex = 0
            if commandBarText != oldValue { refreshCommandBarLive() }
        }
    }
    var commandBarHighlightedIndex = 0
    /// The tab the command bar will navigate on submit.
    private var commandBarTargetID: Tab.ID?

    /// The site a Tab-triggered scoped search is aimed at (Arc site search pill).
    var commandBarSiteSearch: SiteSearchEngine?
    /// What was typed before Tab, restored when the pill is removed
    /// (Arc `queryBeforeEnteringScopedSearch`).
    @ObservationIgnored var commandBarTextBeforeSiteSearch = ""

    var commandBarResults: [CommandBarSearch.Result] {
        if let engine = commandBarSiteSearch {
            return CommandBarSearch.siteSearchResults(engine, query: commandBarText)
        }
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
            externalLinkDestination: externalLinkDestination,
            live: commandBarLive,
            searchProvider: searchProvider
        )
    }

    /// Engine history, suggestions and URL-vs-search for the typed text
    /// (`CommandBarServices`); nil until a source answers.
    var commandBarLive: CommandBarLiveResults?
    @ObservationIgnored var commandBarGate = CommandBarQueryGate()
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
    var boostSessionApplyByTab: [Tab.ID: BoostSessionApplyMap] = [:]
    var lastPickedSnapshotByTab: [Tab.ID: PickedElementSnapshot] = [:]
    var boostSelectorFingerprintByTab: [Tab.ID: BoostSelectorFingerprint] = [:]
    var boostLiveDebounceWorkItem: DispatchWorkItem?

    var easelMutationRevision = 0
    var sidebarRecoveredFromCorruption = false
    var isCapturesGalleryPresented = false
    var isCapturePreviewPresented = false
    var lastCapturePreview: CaptureRecord?
    var captureErrorMessage: String?

    /// Cmd+F bar; targets one page at a time.
    let findBar = FindBarModel()
    /// The sidebar's downloads tray (both engines).
    let downloads: DownloadsController
    /// Permission answers per site (URL field indicator; WebKit's remembered answers).
    let sitePermissions: SitePermissionsController
    /// Command-bar visit history, saved next to the sidebar file.
    var visitHistory: VisitHistory
    @ObservationIgnored let historyFileURL: URL?
    @ObservationIgnored var historySaveWorkItem: DispatchWorkItem?
    /// Last URL recorded per tab: a commit and its load-stop report the same visit.
    @ObservationIgnored var lastRecordedVisit: [Tab.ID: String] = [:]

    init(
        store: SidebarStore? = nil,
        persistence: SidebarFilePersistence? = nil,
        nowPlaying: MediaKeyRouting? = nil,
        syncEngine: SyncEngine? = nil,
        faviconStore: FaviconStore? = nil
    ) {
        let persistence = persistence ?? SidebarFilePersistence()
        self.persistence = persistence
        self.faviconStore = faviconStore
            ?? FaviconStore(directory: persistence.fileURL.deletingLastPathComponent().appendingPathComponent("Favicons", isDirectory: true))
        self.store = store ?? SidebarFilePersistence.loadStore(persistence: persistence)
        self.sidebarRecoveredFromCorruption = persistence.loadOutcome == .recoveredFromCorruptFile
        let historyFile = Self.siblingFile(VisitHistoryFile.fileName, of: persistence.fileURL)
        self.historyFileURL = historyFile
        self.visitHistory = VisitHistoryFile.load(from: historyFile)
        self.downloads = DownloadsController(fileURL: Self.siblingFile(DownloadListFile.fileName, of: persistence.fileURL))
        engineHost.downloadCenter = downloads.webKit
        self.sitePermissions = SitePermissionsController(fileURL: Self.siblingFile(SitePermissionStore.fileName, of: persistence.fileURL))
        engineHost.sitePermissions = sitePermissions
        self.nowPlaying = nowPlaying ?? NowPlayingController()
        let engine = syncEngine ?? CloudKitSyncAvailability.makeEngine()
        self.syncEngine = engine
        self.syncPipeline = SyncOutboundPipeline(journal: self.store.mutationJournal, engine: engine)
        self.syncStatus = engine.status
        engine.onStatusChange = { [weak self] status in
            self?.syncStatus = status
        }
        self.store.mutationJournal.onAppend = { [weak self] entry in
            self?.syncPipeline.handleJournalEntry(entry)
        }
        engine.start()
        engineHost.linkRouter = self
        self.persistence.start(autoSave: self.store) { [weak self] in
            self?.reconcileEngineOwnership()
            self?.syncAllTabBoosts()
        }
        if self.store.selectedItemID == nil {
            if let first = self.store.displayTabs().first {
                self.store.selectTab(first.id)
            } else if let easel = self.store.allEaselRefs().first {
                self.store.selectEasel(easel.id)
            }
        }
        observeSearchProvider()
        wireMediaKeyHandlers()
        runAutoArchive()
        startAutoArchiveTimer()
        loadSelectedIfNeeded()
    }

    var miniPlayerTabID: Tab.ID? {
        MiniPlayerVisibility.activeMiniPlayerTab(
            mediaByTab: mediaStateByTab,
            selectedTabID: store.selectedTabID,
            activeSpaceID: store.activeSpaceID,
            spaceForTab: { store.spaceContaining(tabID: $0) }
        )
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

    private func profileID(forTabID id: Tab.ID) -> Profile.ID? {
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

    func selectTab(_ id: Tab.ID) {
        store.selectTab(id)
        loadSelectedIfNeeded()
    }

    func selectSplit(_ splitID: SplitViewItem.ID, focusTabID: Tab.ID? = nil) {
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

    func unloadPinnedTab(_ id: Tab.ID) {
        guard store.unloadPinnedTab(id) else { return }
        releaseEngine(for: id)
        loadSelectedIfNeeded()
    }

    func unloadFavorite(_ id: Tab.ID) {
        store.unloadFavorite(id)
        releaseEngine(for: id)
        loadSelectedIfNeeded()
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
        mediaSubscriptions[id] = nil
        mediaStateByTab[id] = nil
        tabMuteModel.markUserUnmuted(id)
        engineHost.remove(id)
        refreshNowPlaying()
    }

    func closeSplit(_ splitID: SplitViewItem.ID) {
        if let split = store.split(withID: splitID) {
            split.tabs.forEach { tab in
                engineHost.remove(tab.id)
                mediaSubscriptions[tab.id] = nil
                mediaStateByTab[tab.id] = nil
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
            guard existing.tabs.count < 4 else { return }
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
        store.selectSpace(id)
        loadSelectedIfNeeded()
    }

    func selectProfile(_ id: Profile.ID) {
        store.selectProfile(id)
        reconcileEngineOwnership()
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
        store.cycleSpace(forward: forward)
        loadSelectedIfNeeded()
    }

    /// Ctrl+1…9.
    func selectSpace(atIndex index: Int) {
        guard store.selectSpace(atIndex: index) else { return }
        loadSelectedIfNeeded()
    }

    @discardableResult
    func addProfile() -> Profile {
        let index = store.profiles.count
        let profile = store.addProfile(name: "Profile \(index + 1)")
        store.selectProfile(profile.id)
        loadSelectedIfNeeded()
        return profile
    }

    /// Creates the suggested next space directly (no dialog).
    @discardableResult
    func addSpace() -> Space {
        let space = store.createSpace(from: SpaceDraft.suggested(in: store)) ?? store.activeSpace
        loadSelectedIfNeeded()
        return space
    }

    /// New Space: opens the creation dialog (name, icon, theme, profile).
    func beginSpaceCreation(profileID: Profile.ID? = nil) {
        spaceCreationDraft = SpaceDraft.suggested(in: store, profileID: profileID)
    }

    @discardableResult
    func createSpace(from draft: SpaceDraft) -> Space? {
        guard let space = store.createSpace(from: draft) else { return nil }
        spaceCreationDraft = nil
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        return space
    }

    func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSidebarVisible.toggle()
            isSidebarPeeking = false
        }
    }

    /// Loads the selected tab's URL into its engine if the engine isn't
    /// already showing it (fresh engine or URL changed in the model).
    func loadSelectedIfNeeded() {
        if store.selectedEaselRef != nil { return }
        if let split = activeSplit {
            for tab in split.tabs {
                let pid = profileID(for: tab)
                let engine = engineHost.engine(for: tab, profileID: pid)
                configureLinkPeek(on: engine)
                if engine.currentURL != tab.url {
                    engine.load(tab.url)
                }
                syncBoosts(for: tab)
            }
            return
        }
        guard let tab = store.selectedTab else { return }
        let engine = engineHost.engine(for: tab, profileID: profileID(for: tab))
        configureLinkPeek(on: engine)
        if engine.currentURL != tab.url {
            engine.load(tab.url)
        }
        (engine as? PageZoomRefreshing)?.refreshZoomFactor()
        wireMediaObserversForKnownTabs()
        syncBoosts(for: tab)
    }

    func syncAllTabBoosts() {
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
        observeFavicon(of: engineHost.engine(for: tab, profileID: profileID), tabID: tab.id)
        guard let wk = engineHost.engine(for: tab, profileID: profileID) as? NavigationCommitReporting else { return }
        wk.onNavigationCommit = { [weak self] url, title in
            self?.handleTabNavigationCommit(tabID: tab.id, url: url, title: title)
        }
    }

    func handleTabNavigationCommit(tabID: Tab.ID, url: URL?, title: String?) {
        boostSessionApplyByTab[tabID] = BoostSessionApplyMap()
        guard let url else { return }
        recordVisit(tabID: tabID, url: url, title: title)
        let resolvedTitle = (title?.isEmpty == false) ? title : nil
        let fallback = store.tab(withID: tabID)?.title ?? url.host() ?? "Page"
        store.updateTab(tabID, title: resolvedTitle ?? fallback, url: url)
    }

    func handleLittleArcNavigationCommit(windowID: LittleArcWindow.ID, url: URL?, title: String?) {
        guard let url else { return }
        let resolvedTitle = (title?.isEmpty == false) ? title : nil
        store.updateLittleArcWindow(id: windowID, title: resolvedTitle, url: url)
    }

    func goToMiniPlayerTab() {
        guard let id = miniPlayerTabID else { return }
        if let spaceID = store.spaceContaining(tabID: id), spaceID != store.activeSpaceID {
            store.selectSpace(spaceID)
        }
        if let location = store.splitContaining(tabID: id) {
            store.selectSplit(location.split.id, focusTabID: id)
        } else {
            store.selectTab(id)
        }
        loadSelectedIfNeeded()
    }

    func miniPlayerTogglePlayPause() {
        guard let id = miniPlayerTabID,
              let pid = profileID(forTabID: id),
              let engine = engineHost.engine(forTabID: id, profileID: pid) else { return }
        engine.togglePlayPause()
    }

    func miniPlayerNextTrack() {
        guard let id = miniPlayerTabID,
              let pid = profileID(forTabID: id),
              let engine = engineHost.engine(forTabID: id, profileID: pid) else { return }
        engine.skipToNextTrack()
    }

    private func wireMediaObserversForKnownTabs() {
        for space in store.spaces {
            for tab in store.displayTabs(in: space.id) {
                wireMediaObserver(for: tab)
            }
        }
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
    }

    private func applyMediaState(_ state: WebMediaState, tabID: Tab.ID, tab: Tab) {
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
        for id in mediaSubscriptions.keys where !liveTabIDs.contains(id) {
            mediaSubscriptions[id] = nil
            mediaStateByTab[id] = nil
            tabMuteModel.markUserUnmuted(id)
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
            let hasVideo = state.isPlaying && state.canPictureInPicture
            let decision = AutoPiPPolicy.shouldAutoPiP(
                host: candidate.url.host(),
                occlusionState: windowOcclusionState,
                now: Date(),
                hasPlayingVideo: hasVideo,
                settings: store.autoPiPPolicy
            )
            guard case .trigger = decision else { continue }
            guard autoPiPTriggeredThisOcclusion.insert(candidate.id).inserted else { continue }
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

    func configureLinkPeek(on engine: any WebEngine) {
        engine.linkPeekHandler = { [weak self] url in
            self?.showPeek(url: url)
        }
    }

    // MARK: - Peek

    func showPeek(url: URL) {
        dismissPeek()
        let originProfile = store.activeProfileID
        let (engineID, engine) = engineHost.ephemeralEngine(profileID: originProfile)
        engine.linkPeekHandler = nil
        engine.load(url)
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

    private func requestLittleArcWindow(_ id: LittleArcWindow.ID) {
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
        guard !didRestoreLittleArcWindows else { return }
        didRestoreLittleArcWindows = true
        for window in store.littleArcLiveWindows {
            requestLittleArcWindow(window.id)
        }
    }

    @discardableResult
    func openLittleArc(url: URL, title: String? = nil, profileID: Profile.ID? = nil) -> LittleArcWindow {
        let record = store.createLittleArcWindow(url: url, title: title, profileID: profileID)
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

    func promoteLittleArcWindow(_ id: LittleArcWindow.ID) {
        let originProfile = store.littleArcWindow(withID: id)?.profileID
            ?? store.archivedLittleArcWindows.first(where: { $0.id == id })?.window.profileID
        guard store.promoteLittleArcToTab(id: id) != nil else { return }
        if let originProfile {
            engineHost.removeLittleArc(id, profileID: originProfile)
        }
        if focusedLittleArcID == id { focusedLittleArcID = nil }
        loadSelectedIfNeeded()
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
        store.autoArchiveIdleLittleArcWindows()
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

    /// Cmd+T: create a fresh today tab and open the command bar into it.
    func newTab() {
        let tab = store.addTab(kind: .today, title: "New Tab", url: URL(string: "about:blank")!)
        store.selectTab(tab.id)
        openCommandBar(target: tab.id, text: "")
    }

    /// Cmd+L: open the command bar aimed at the selected tab.
    func focusLocation() {
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
        isCommandBarPresented = false
        cancelCommandBarLive()
        commandBarSiteSearch = nil
        commandBarTextBeforeSiteSearch = ""
        commandBarTargetID = nil
        commandBarText = ""
        commandBarHighlightedIndex = 0
        commandBarError = nil
        commandBarURLIntent = nil
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

    func submitCommandBar() {
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
                if let tabID = choice.tabID {
                    store.focusTab(tabID)
                    loadSelectedIfNeeded()
                    dismissCommandBar()
                    return
                }
            case .command:
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
                    navigateCommandBar(to: url)
                    dismissCommandBar()
                    return
                }
            }
        }

        guard let url = URLEntry.resolve(commandBarText, engine: engineHost.navigationSchemes, provider: searchProvider) else {
            dismissCommandBar()
            return
        }
        navigateCommandBar(to: url)
        dismissCommandBar()
        loadSelectedIfNeeded()
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

    private func navigateCommandBar(to url: URL) {
        guard NavigationURLPolicy.allows(url, engine: engineHost.navigationSchemes) else {
            commandBarError = "That URL scheme is not allowed"
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
        commandBarSiteSearch = nil
        commandBarTargetID = target
        commandBarText = text
        commandBarError = nil
        isCommandBarPresented = true
        commandBarServices.commandBarWillOpen(profileID: store.activeProfileID)
    }

    // MARK: - Command bar live results

    /// Every edit starts new lookups and cancels the last; only web input
    /// in an open bar asks (not commands, site-search pills or URL prompts).
    func refreshCommandBarLive() {
        let text = commandBarText
        guard isCommandBarPresented, commandBarSiteSearch == nil, commandBarURLIntent == nil, !text.hasPrefix(">"),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelCommandBarLive()
            return
        }
        if let live = commandBarLive, !live.applies(to: text) { commandBarLive = nil }
        let generation = commandBarGate.begin(text)
        commandBarServices.query(text, profileID: store.activeProfileID, isPrivate: false) { [weak self] live in
            guard let self, self.commandBarGate.isCurrent(generation) else { return }
            self.commandBarLive = live
        }
    }

    func cancelCommandBarLive() {
        commandBarGate.cancel()
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
        engineHost.engine(for: tab, profileID: profileID(for: tab)).load(tab.url)
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
            _ = addProfile()
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
            openBoostEditor(packageID: packageID, startPicker: false)
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
        case .openCapturesGallery:
            isCapturesGalleryPresented = true
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
        case .nextSpace:
            cycleSpace(forward: true)
        case .previousSpace:
            cycleSpace(forward: false)
        case .renameSpace:
            beginRename(.space(store.activeSpaceID))
        case .editSpaceTheme:
            spaceEditorID = store.activeSpaceID
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
