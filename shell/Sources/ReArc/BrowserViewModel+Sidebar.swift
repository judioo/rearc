import AppKit
import SidebarModel
import SwiftUI

/// What the shared rename alert is renaming.
enum SidebarRenameRequest: Equatable {
    case tab(Tab.ID)
    case folder(UUID)
    case space(Space.ID)

    var alertTitle: String {
        switch self {
        case .tab: return "Rename Tab"
        case .folder: return "Rename Folder"
        case .space: return "Rename Space"
        }
    }
}

/// What ✕ and ⌘W do to a tab, as `closeTabNow` decides it, and how the
/// button and the menu name that.
enum TabCloseKind: Equatable {
    /// A Today tab (or a split pane) goes to the archive.
    case archive
    /// A pinned tab goes back to its saved URL, unloaded; the row stays.
    case unloadPinned
    /// A favorite is unloaded and stays in the strip.
    case unloadFavorite

    /// The ✕ button's label. "Archive this tab" is Arc's tooltip on a Today
    /// row; the recording did not capture Arc's pinned wording, so pinned
    /// and favorite rows use a plain "Close tab".
    var buttonLabel: String {
        self == .archive ? "Archive this tab" : "Close tab"
    }

    /// The ⌘W item: Arc's Shortcuts list names it "Archive Tab".
    var menuTitle: String {
        self == .archive ? "Archive Tab" : "Close Tab"
    }
}

/// Destructive sidebar actions that ask first (Arc `SpaceDeletionConfiguration`,
/// `DeleteProfileDialog`).
/// Change Profile of a space, waiting for confirmation (Arc ConfirmInterProfileMove).
struct SpaceProfileChange: Equatable {
    var spaceID: Space.ID
    var profileID: Profile.ID
}

enum SidebarDeletionRequest: Equatable {
    case space(Space.ID)
    case folderAndContents(UUID)
    /// A profile together with the spaces it owns.
    case profile(Profile.ID)
}

/// Wave 17 sidebar actions: navigation controls, favorites, folders, archive,
/// space management and the floating sidebar. Views and both menu bars
/// (SwiftUI commands on WebKit, NSMenu on Chromium) call these.
extension BrowserViewModel {

    // MARK: - Navigation (Arc's toolbar lives in the sidebar)

    /// The page navigation commands act on: the key private window's page,
    /// else the selected tab (the focused pane of a split).
    var navigationEngine: (any WebEngine)? {
        keyPrivateWindow?.engine ?? keyLittleArcEngine ?? focusedEngine
    }

    func goBack() { navigationEngine?.goBack() }
    func goForward() { navigationEngine?.goForward() }

    func reload(ignoringCache: Bool = false) {
        navigationEngine?.reload(ignoringCache: ignoringCache)
    }

    func stopLoading() { navigationEngine?.stopLoading() }

    func reloadOrStop() {
        guard let engine = navigationEngine else { return }
        if engine.isLoading {
            engine.stopLoading()
        } else {
            engine.reload(ignoringCache: false)
        }
    }

    /// Shift+Cmd+C, and Copy Link in context menus.
    func copyURL(of tabID: Tab.ID? = nil) {
        copyURL(of: tabID, format: .plain)
    }

    // MARK: - Favicons

    /// The cached icon for a tab's site (nil draws the letter token).
    func favicon(for tab: Tab) -> NSImage? {
        faviconStore.image(for: tab.url)
    }

    /// Copies an engine's icon into the cache whenever it changes, under the
    /// page's host and the tab's host (they differ across redirects).
    func observeFavicon(of engine: any WebEngine, tabID: Tab.ID) {
        let identity = ObjectIdentifier(engine)
        guard faviconObservedEngines[tabID] != identity else { return }
        faviconObservedEngines[tabID] = identity
        recordFavicon(from: engine, tabID: tabID)
        trackFavicon(of: engine, tabID: tabID, identity: identity)
    }

    private func trackFavicon(of engine: any WebEngine, tabID: Tab.ID, identity: ObjectIdentifier) {
        withObservationTracking {
            _ = engine.faviconData
        } onChange: { [weak self, weak engine] in
            DispatchQueue.main.async {
                guard let self, let engine, self.faviconObservedEngines[tabID] == identity else { return }
                self.recordFavicon(from: engine, tabID: tabID)
                self.trackFavicon(of: engine, tabID: tabID, identity: identity)
            }
        }
    }

    /// Sidebar tab engines are never ephemeral, so their icons persist.
    private func recordFavicon(from engine: any WebEngine, tabID: Tab.ID) {
        guard let data = engine.faviconData else { return }
        if let page = engine.currentURL { faviconStore.store(data, for: page) }
        if let tab = store.tab(withID: tabID),
           FaviconStore.hostKey(for: tab.url) != engine.currentURL.flatMap(FaviconStore.hostKey(for:)) {
            faviconStore.store(data, for: tab.url)
        }
    }

    // MARK: - Close wording

    func closeKind(of id: Tab.ID) -> TabCloseKind {
        switch store.kind(of: id) {
        case .favorite: return .unloadFavorite
        case .pinned where store.splitContaining(tabID: id) == nil: return .unloadPinned
        default: return .archive
        }
    }

    /// The ⌘W item's title for the selected tab; a key private window
    /// closes instead, so it keeps "Close Tab".
    var closeTabMenuTitle: String {
        guard keyPrivateWindow == nil, let id = store.selectedTabID else { return "Close Tab" }
        return closeKind(of: id).menuTitle
    }

    // MARK: - Pinning and favorites

    /// How long a just-pinned row says "Double-click to rename" (Arc's drop, about 3 s).
    static let renameHintDuration: TimeInterval = 3

    /// The row's subtitle while its rename hint shows.
    func renameHintSubtitle(for id: Tab.ID, now: Date = Date()) -> String? {
        guard let hint = renameHint, hint.tabID == id,
              now.timeIntervalSince(hint.shownAt) < Self.renameHintDuration else { return nil }
        return "Double-click to rename"
    }

    func showRenameHint(for id: Tab.ID, now: Date = Date()) {
        renameHint = (id, now)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.renameHintDuration) { [weak self] in
            self?.expireRenameHint()
        }
    }

    /// Clears the hint once its time is up; a newer hint keeps its own time.
    func expireRenameHint(now: Date = Date()) {
        guard let hint = renameHint, now.timeIntervalSince(hint.shownAt) >= Self.renameHintDuration else { return }
        renameHint = nil
    }

    /// After a move or command: a tab that was not pinned and now is shows the hint.
    private func noteMove(of id: UUID, wasPinned: Bool) {
        if !wasPinned, store.kind(of: id) == .pinned, store.splitContaining(tabID: id) == nil {
            showRenameHint(for: id)
        }
    }

    /// Cmd+D: pin a Today tab, unpin a pinned one.
    func togglePin(_ tabID: Tab.ID? = nil) {
        guard let id = tabID ?? store.selectedTabID else { return }
        let space = store.spaceContaining(tabID: id).flatMap { store.space(withID: $0) }?.name ?? ""
        switch store.kind(of: id) {
        case .today:
            store.pinTab(id)
            noteMove(of: id, wasPinned: false)
            showToast("Pinned Tab to “\(space)”", systemImage: "pin.fill")
        case .pinned:
            store.unpinTab(id)
            showToast("Un-Pinned Tab from “\(space)”", systemImage: "pin.slash")
        case .favorite, nil: return
        }
        loadSelectedIfNeeded()
    }

    func addToFavorites(_ tabID: Tab.ID? = nil) {
        guard let id = tabID ?? store.selectedTabID else { return }
        // The engine follows the favorite's profile, which is the space's profile.
        store.addToFavorites(id)
        loadSelectedIfNeeded()
    }

    /// Unfavorite into the active space's pinned section.
    func moveFavoriteToPinned(_ id: Tab.ID) {
        let count = store.content(for: store.activeSpaceID).pinned.count
        store.moveItem(id, to: .section(spaceID: store.activeSpaceID, section: .pinned), index: count)
        noteMove(of: id, wasPinned: false)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    /// Move to Space (menu, command bar, or a drop on a space icon): the item
    /// keeps its section, landing at the end of Pinned or the top of Today.
    func moveTab(_ id: Tab.ID, toSpace spaceID: Space.ID) {
        moveEntry(id, toSpace: spaceID)
    }

    func moveEntry(_ id: UUID, toSpace spaceID: Space.ID) {
        guard store.moveEntry(id, toSpace: spaceID) else { return }
        // A space in another profile means another engine profile: drop the old engine.
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    // MARK: - Drag to split (wave 21)

    /// The tab a content drop splits with: the focused pane of a split, or
    /// the selected tab. Easels and favorites do not split.
    func splitDropAnchor(in window: SidebarWindowID?) -> Tab.ID? {
        guard selectedEaselRef(in: window) == nil else { return nil }
        if let split = activeSplit(in: window) { return split.focusTabID }
        return selectedTab(in: window)?.id
    }

    func canDropToSplit(_ itemID: UUID, in window: SidebarWindowID?) -> Bool {
        guard let anchor = splitDropAnchor(in: window) else { return false }
        return store.canSplit(itemID, onto: anchor)
    }

    /// A sidebar tab dropped on an edge of the page becomes a pane there.
    @discardableResult
    func dropToSplit(_ tabID: Tab.ID, edge: SplitDropEdge, in window: SidebarWindowID?) -> Bool {
        guard let anchor = splitDropAnchor(in: window),
              store.splitTab(tabID, onto: anchor, edge: edge) != nil else { return false }
        loadSelectedIfNeeded()
        return true
    }

    // MARK: - Split with a chosen tab

    /// Split with Current Tab (row context menu): the row's tab joins the
    /// selected tab, in its split when it has room.
    func splitWithSelectedTab(_ tabID: Tab.ID) {
        guard let anchor = store.selectedTabID, store.splitTab(tabID, with: anchor) != nil else { return }
        loadSelectedIfNeeded()
    }

    func canSplitWithSelectedTab(_ tabID: Tab.ID) -> Bool {
        guard let anchor = store.selectedTabID, anchor != tabID,
              store.kind(of: anchor) != .favorite, store.kind(of: tabID) != .favorite,
              store.splitContaining(tabID: tabID) == nil,
              store.spaceContaining(tabID: tabID) == store.spaceContaining(tabID: anchor) else { return false }
        return (store.splitContaining(tabID: anchor)?.split.tabs.count ?? 1) < 4
    }

    // MARK: - Pinned tabs (saved URL)

    /// Reset Tab to Original URL; a live engine goes back right away.
    func resetTabToSavedURL(_ tabID: Tab.ID? = nil) {
        guard let id = tabID ?? store.selectedTabID, store.resetTabToSavedURL(id) else { return }
        reloadReset([id])
    }

    /// Reset all tabs in this Space.
    func resetPinnedTabs() {
        reloadReset(store.resetPinnedTabs())
    }

    func updateSavedURLToCurrent(_ tabID: Tab.ID? = nil) {
        guard let id = tabID ?? store.selectedTabID else { return }
        store.updateSavedURLToCurrent(id)
    }

    private func reloadReset(_ ids: [Tab.ID]) {
        for id in ids {
            guard let tab = store.tab(withID: id),
                  let engine = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) else { continue }
            engine.load(tab.url)
        }
        loadSelectedIfNeeded()
    }

    // MARK: - Cmd+1…9

    func selectItem(atPosition number: Int) {
        PerfSignposts.interaction(.tabSwitch, "position \(number)")
        guard store.selectItem(atPosition: number) != nil else { return }
        loadSelectedIfNeeded()
    }

    // MARK: - Clear Today

    /// Clear Unpinned Tabs: archives the active space's Today tabs; Undo puts them back.
    func clearTodayTabs() {
        let cleared = store.clearTodayTabs()
        guard !cleared.isEmpty else { return }
        cleared.forEach(releaseEngine(for:))
        lastClearedTabIDs = cleared
        loadSelectedIfNeeded()
    }

    func undoClearTodayTabs() {
        let ids = lastClearedTabIDs
        lastClearedTabIDs = []
        guard !store.restoreClearedTabs(ids).isEmpty else { return }
        loadSelectedIfNeeded()
    }

    // MARK: - Mute

    /// The speaker on a row: mutes an audible tab, unmutes a muted one.
    func toggleMute(_ tabID: Tab.ID) {
        guard let tab = store.tab(withID: tabID) else { return }
        if tabMuteModel.isUserMuted(tabID) {
            engineHost.setMuted(false, forTabID: tabID, profileID: profileID(for: tab))
            tabMuteModel.markUserUnmuted(tabID)
        } else {
            muteTab(tabID)
        }
    }

    func isUserMuted(_ tabID: Tab.ID) -> Bool {
        tabMuteModel.isUserMuted(tabID)
    }

    // MARK: - Drag and drop

    func moveItem(_ id: UUID, relativeTo targetID: UUID, after: Bool) {
        let wasPinned = store.kind(of: id) == .pinned
        guard store.moveItem(id, relativeTo: targetID, after: after) else { return }
        noteMove(of: id, wasPinned: wasPinned)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    func moveItem(_ id: UUID, to destination: SidebarStore.ItemDestination, index: Int) {
        let wasPinned = store.kind(of: id) == .pinned
        guard store.moveItem(id, to: destination, index: index) else { return }
        noteMove(of: id, wasPinned: wasPinned)
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
    }

    /// Links dropped on a sidebar row from a page or another app: Today tabs
    /// placed before or after that row, in drop order; the first is shown.
    @discardableResult
    func openDroppedURLs(_ urls: [URL], relativeTo targetID: UUID, after: Bool) -> [Tab.ID] {
        let tabs = makeDroppedTabs(urls)
        var anchor = targetID, placeAfter = after
        for tab in tabs {
            _ = store.moveItem(tab.id, relativeTo: anchor, after: placeAfter)
            anchor = tab.id
            placeAfter = true
        }
        return showDroppedTabs(tabs)
    }

    /// Links dropped after a section's last row (or on an empty section).
    @discardableResult
    func openDroppedURLs(_ urls: [URL], appendingTo destination: SidebarStore.ItemDestination) -> [Tab.ID] {
        let tabs = makeDroppedTabs(urls)
        for tab in tabs {
            let count = store.entries(in: store.resolvedParent(destination)).filter { $0.id != tab.id }.count
            _ = store.moveItem(tab.id, to: destination, index: count)
        }
        return showDroppedTabs(tabs)
    }

    private func makeDroppedTabs(_ urls: [URL]) -> [Tab] {
        SidebarURLDrop.tabURLs(from: urls, engine: engineHost.navigationSchemes).map {
            store.addTab(kind: .today, title: SidebarURLDrop.placeholderTitle(for: $0), url: $0)
        }
    }

    private func showDroppedTabs(_ tabs: [Tab]) -> [Tab.ID] {
        guard let first = tabs.first else { return [] }
        reconcileEngineOwnership()
        selectTab(first.id)
        return tabs.map(\.id)
    }

    /// Drop onto a folder row: append to the folder and open it.
    func moveItem(_ id: UUID, intoFolder folderID: UUID) {
        let count = store.folder(withID: folderID)?.children.count ?? 0
        let wasPinned = store.kind(of: id) == .pinned
        guard store.moveItem(id, to: .folder(folderID), index: count) else { return }
        noteMove(of: id, wasPinned: wasPinned)
        store.setFolderExpanded(folderID, true)
        loadSelectedIfNeeded()
    }

    /// Drop a tab onto a tab: group both in a new folder and rename it.
    func groupIntoNewFolder(target: UUID, dragged: UUID) {
        guard let folder = store.createFolder(grouping: target, with: dragged) else { return }
        beginRename(.folder(folder.id))
    }

    // MARK: - Folders

    @discardableResult
    func newFolder(containing ids: [UUID] = [], parentFolderID: UUID? = nil) -> SidebarFolder? {
        guard let folder = store.createFolder(parentFolderID: parentFolderID, containing: ids) else { return nil }
        beginRename(.folder(folder.id))
        return folder
    }

    func deleteFolder(_ id: UUID, keepingChildren: Bool) {
        let removed = store.deleteFolder(id, keepingChildren: keepingChildren)
        removed.forEach(releaseEngine(for:))
        loadSelectedIfNeeded()
    }

    // MARK: - Tabs

    func duplicateTab(_ tabID: Tab.ID? = nil) {
        guard let id = tabID ?? store.selectedTabID, let copy = store.duplicateTab(id) else { return }
        store.selectTab(copy.id)
        loadSelectedIfNeeded()
    }

    /// Archive Tab (Arc keywords "Exit Tab; Unload; Close").
    func archiveTab(_ tabID: Tab.ID? = nil) {
        guard let id = tabID ?? store.selectedTabID, store.archiveTab(id) != nil else { return }
        releaseEngine(for: id)
        loadSelectedIfNeeded()
    }

    // MARK: - Rename and delete prompts

    func beginRename(_ request: SidebarRenameRequest) {
        switch request {
        case .tab(let id):
            guard let tab = store.tab(withID: id) else { return }
            pendingRenameText = tab.displayTitle
        case .folder(let id):
            guard let folder = store.folder(withID: id) else { return }
            pendingRenameText = folder.title
        case .space(let id):
            guard let space = store.space(withID: id) else { return }
            pendingRenameText = space.name
        }
        pendingRename = request
    }

    func commitRename() {
        defer { pendingRename = nil }
        switch pendingRename {
        case .tab(let id): store.renameTab(id, to: pendingRenameText)
        case .folder(let id): store.renameFolder(id, to: pendingRenameText)
        case .space(let id): store.renameSpace(id, to: pendingRenameText)
        case nil: break
        }
    }

    var pendingDeletionMessage: (title: String, message: String, action: String) {
        switch pendingDeletion {
        case .space(let id):
            let space = store.space(withID: id)
            let content = store.content(for: id)
            let count = SidebarTree.tabs(content.pinned + content.today).count
            return ("Delete “\(space?.name ?? "Space")”?",
                    "The space and its \(count) pinned and Today tab\(count == 1 ? "" : "s") are deleted. This cannot be undone.",
                    "Delete Space")
        case .folderAndContents(let id):
            let count = store.folder(withID: id).map { SidebarTree.tabs($0.children).count } ?? 0
            return ("Delete “\(store.folder(withID: id)?.title ?? "Folder")” and its tabs?",
                    "\(count) tab\(count == 1 ? "" : "s") move to the Archive.",
                    "Delete Folder")
        case .profile(let id):
            let profile = store.profile(withID: id)
            let count = store.spaces(in: id).count
            return ("Delete “\(profile?.name ?? "Profile")”?",
                    "Its \(count) space\(count == 1 ? "" : "s"), favorites and browsing data are deleted. This cannot be undone.",
                    "Delete Profile")
        case nil:
            return ("", "", "")
        }
    }

    func confirmPendingDeletion() {
        defer { pendingDeletion = nil }
        switch pendingDeletion {
        case .space(let id): deleteSpace(id)
        case .folderAndContents(let id): deleteFolder(id, keepingChildren: false)
        case .profile(let id): deleteProfile(id, deletingSpaces: true)
        case nil: break
        }
    }

    // MARK: - Space profile (wave 21)

    /// Asks before moving a space to another profile; does nothing when the
    /// move is not allowed.
    func requestSpaceProfileChange(_ spaceID: Space.ID, to profileID: Profile.ID) {
        guard store.profileChangeBlocker(forSpace: spaceID, to: profileID) == nil else { return }
        pendingSpaceProfileChange = SpaceProfileChange(spaceID: spaceID, profileID: profileID)
    }

    func spaceProfileChangeMessage(_ change: SpaceProfileChange) -> (title: String, message: String, action: String) {
        let space = store.space(withID: change.spaceID)
        let source = space.flatMap { store.profile(withID: $0.profileID) }
        let destination = store.profile(withID: change.profileID)
        let content = store.content(for: change.spaceID)
        let count = SidebarTree.tabs(content.pinned + content.today).count
        let tabs = "\(count) tab\(count == 1 ? "" : "s")"
        return ("Move “\(space?.name ?? "Space")” to \(destination?.name ?? "Profile")?",
                "Its \(tabs) reload in \(destination?.name ?? "the new profile"). Cookies, sign-ins and site data stay in \(source?.name ?? "the old profile"), so you may need to sign in again. Back and forward history is lost.",
                "Move Space")
    }

    func confirmSpaceProfileChange() {
        defer { pendingSpaceProfileChange = nil }
        guard let change = pendingSpaceProfileChange else { return }
        changeSpaceProfile(change.spaceID, to: change.profileID)
    }

    /// Moves the space, then swaps its tabs' engines for ones on the new
    /// profile's storage: `reconcileEngineOwnership` closes engines keyed to
    /// the old profile, and loading creates fresh ones at each tab's URL.
    @discardableResult
    func changeSpaceProfile(_ spaceID: Space.ID, to profileID: Profile.ID) -> SpaceProfileChangeError? {
        let tabIDs = SidebarTree.tabs(store.content(for: spaceID).pinned + store.content(for: spaceID).today).map(\.id)
        if let error = store.changeProfile(ofSpace: spaceID, to: profileID) { return error }
        for id in tabIDs {
            // A boost editing session belonged to the closed engine.
            boostEditorDraftByTab[id] = nil
            boostSessionApplyByTab[id] = nil
            lastPickedSnapshotByTab[id] = nil
        }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        return nil
    }

    // MARK: - Spaces

    /// Moves a space within its profile (switcher drag, Spaces menu).
    func moveSpace(_ id: Space.ID, toIndex index: Int) {
        store.moveSpace(id, toIndex: index)
    }

    /// Move Space Left / Right in the Spaces menu.
    func moveActiveSpace(by offset: Int) {
        let peers = store.spacesInActiveProfile
        guard let index = peers.firstIndex(where: { $0.id == store.activeSpaceID }) else { return }
        store.moveSpace(store.activeSpaceID, toIndex: index + offset)
    }

    /// Deletes a space and its tabs, then drops their engines.
    func deleteSpace(_ id: Space.ID) {
        guard store.removeSpace(id) else { return }
        reconcileEngineOwnership()
        loadSelectedIfNeeded()
        // Arc: "Space deleted! Use ⌘Z to undo." ReArc has no undo for it yet.
        showToast("Space deleted", systemImage: "trash")
    }

    var canDeleteSpaces: Bool { store.spaces.count > 1 }

    // MARK: - Archive

    func restoreArchivedTab(_ id: Tab.ID) {
        guard let tab = store.restoreArchivedTab(id) else { return }
        engineHost.engine(for: tab, profileID: profileID(for: tab)).load(tab.url)
        loadSelectedIfNeeded()
    }

    func setAutoArchiveThreshold(_ threshold: AutoArchiveThreshold) {
        store.setAutoArchiveThreshold(threshold)
        runAutoArchive()
    }

    /// Archives idle Today tabs and drops their engines.
    func runAutoArchive() {
        let archived = store.autoArchiveIdleTodayTabs()
        guard !archived.isEmpty else { return }
        archived.forEach(releaseEngine(for:))
        loadSelectedIfNeeded()
    }

    /// Checks every five minutes (auto-archive's shortest threshold is 12
    /// hours, the tab unload's 30 minutes).
    func startAutoArchiveTimer() {
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            self?.runAutoArchive()
            self?.runAutoUnload()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoArchiveTimer?.invalidate()
        autoArchiveTimer = timer
    }

    // MARK: - Floating sidebar

    func setSidebarPeeking(_ peeking: Bool) {
        guard !isSidebarVisible || !peeking, isSidebarPeeking != peeking else { return }
        PerfSignposts.interaction(.sidebarPeek, peeking ? "reveal" : "dismiss")
        withAnimation(.easeOut(duration: 0.16), completionCriteria: .logicallyComplete) {
            isSidebarPeeking = peeking
        } completion: { [weak self] in
            self?.onShellAnimationComplete?(.sidebarPeek)
        }
    }
}

extension BrowserViewModel {
    /// Spaces > Appearance: the active space's light or dark look (synced
    /// with its style).
    func setSpaceAppearance(_ appearance: SpaceAppearance, spaceID: Space.ID? = nil) {
        let id = spaceID ?? store.activeSpaceID
        guard var theme = store.space(withID: id)?.theme else { return }
        theme.appearance = appearance
        store.setSpaceTheme(id, theme: theme)
    }
}

extension BrowserViewModel {
    /// File > Import Bookmarks from HTML File…: the file every browser
    /// exports, as a new space of pinned tabs and folders.
    func importBookmarksFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a bookmarks file exported from Safari, Chrome, Firefox or another browser."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let html = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            let name = url.deletingPathExtension().lastPathComponent
            if let problem = self.importBookmarks(fromHTML: html, spaceName: name) {
                self.showToast(problem, systemImage: "exclamationmark.triangle")
            }
        }
    }

    /// Imports into a new space and shows it; returns why nothing was imported.
    @discardableResult
    func importBookmarks(fromHTML html: String, spaceName: String) -> String? {
        guard BookmarkHTMLImport.isBookmarkFile(html) else { return "That file is not a bookmarks export" }
        guard let result = store.importBookmarks(BookmarkHTMLImport.parse(html), spaceName: spaceName) else {
            return "The file has no web bookmarks"
        }
        selectSpace(result.space.id)
        showToast("Imported \(result.tabs) bookmark\(result.tabs == 1 ? "" : "s") into \(result.space.name)", systemImage: "square.and.arrow.down")
        return nil
    }
}
