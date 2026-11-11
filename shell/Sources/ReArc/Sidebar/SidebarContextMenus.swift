import SwiftUI
import SidebarModel

// Sidebar item context menus (SIDEBAR-SPEC §4.9: pin/unpin, rename, duplicate,
// copy URL, move to space, archive, close; folders: rename, expand, delete).

struct TabContextMenu: View {
    let model: BrowserViewModel
    let tab: Tab
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        let targets = model.store.menuTargets(for: tab.id, in: window)
        if targets.count > 1 {
            SelectionContextMenu(model: model, ids: targets)
        } else {
            singleTabMenu
        }
    }

    @ViewBuilder
    private var singleTabMenu: some View {
        let store = model.store
        let kind = store.kind(of: tab.id)
        let inSplit = store.splitContaining(tabID: tab.id) != nil
        let isSpaceTab = (kind == .pinned || kind == .today) && !inSplit

        if kind == .favorite {
            Button("Remove from Favorites") { model.removeFavorite(tab.id) }
            Button("Move to Pinned") { model.moveFavoriteToPinned(tab.id) }
        } else if isSpaceTab {
            Button(kind == .pinned ? "Unpin Tab" : "Pin Tab") { model.togglePin(tab.id) }
            Button("Add to Favorites") { model.addToFavorites(tab.id) }
        }
        if kind == .pinned, !inSplit {
            Divider()
            Button("Reset to Pinned URL") { model.resetTabToSavedURL(tab.id) }
                .disabled(!tab.isAwayFromSavedURL)
            Button("Make This the Pinned URL") { model.updateSavedURLToCurrent(tab.id) }
                .disabled(!tab.isAwayFromSavedURL)
        }
        Divider()
        Button("Unload Tab") { model.unloadTab(tab.id) }
            .disabled(!model.canUnloadTab(tab.id))
            .help("Frees the page's memory; the tab stays here and reloads when you open it")
        Button("Rename…") { model.beginRename(.tab(tab.id)) }
        ItemIconMenu(model: model, itemID: tab.id)
        Button("Duplicate") { model.duplicateTab(tab.id) }
        Button("Copy Link") { model.copyURL(of: tab.id) }
        Button("Copy Link as Markdown") { model.copyURL(of: tab.id, format: .markdown) }
        if model.tabActivity(tab.id) == .crashed {
            Button("Reload Crashed Page") { model.reloadCrashedTab(tab.id) }
        }
        if isSpaceTab {
            Menu("Move to Folder") {
                let outline = store.folderOutline(in: store.spaceContaining(tabID: tab.id))
                ForEach(outline, id: \.folder.id) { item in
                    Button(String(repeating: "    ", count: item.depth) + item.folder.title) {
                        model.moveItem(tab.id, intoFolder: item.folder.id)
                    }
                    .disabled(store.parentFolderID(of: tab.id) == item.folder.id)
                }
                if !outline.isEmpty { Divider() }
                Button("New Folder with Tab") { model.newFolder(containing: [tab.id]) }
                if store.parentFolderID(of: tab.id) != nil, let spaceID = store.spaceContaining(tabID: tab.id) {
                    Button("Out of Folder") {
                        let count = store.content(for: spaceID).pinned.count
                        model.moveItem(tab.id, to: .section(spaceID: spaceID, section: .pinned), index: count)
                    }
                }
            }
            let owner = store.spaceContaining(tabID: tab.id).flatMap { store.space(withID: $0)?.profileID }
            let otherSpaces = store.spaces(in: owner ?? store.activeProfileID).filter { $0.id != store.spaceContaining(tabID: tab.id) }
            if !otherSpaces.isEmpty {
                Menu("Move to Space") {
                    ForEach(otherSpaces) { space in
                        Button(space.name) { model.moveTab(tab.id, toSpace: space.id) }
                    }
                }
            }
            if let spaceID = store.spaceContaining(tabID: tab.id) {
                MoveToProfileMenu(model: model, ids: [tab.id], spaceID: spaceID)
            }
        }
        if model.canSplitWithSelectedTab(tab.id) {
            Button("Split with Current Tab") { model.splitWithSelectedTab(tab.id) }
        }
        Button("Open in Little ReArc") { model.openLittleArc(url: tab.url, title: tab.displayTitle, profileID: model.profileID(for: tab)) }
        if BoostScopeMatcher.urlIsEligibleForBoosts(tab.url) {
            Button("Edit Boost for This Site") {
                model.selectTab(tab.id)
                model.editBoostFromTabContextMenu()
            }
        }
        Divider()
        if isSpaceTab {
            Button("Archive Tab") { model.archiveTab(tab.id) }
        }
        if kind == .pinned, !inSplit {
            Button("Unload Tab") { model.closeTab(tab.id) }
            Button("Delete Tab") { model.deleteTab(tab.id) }
        } else {
            Button(kind == .favorite ? "Unload Tab" : "Close Tab") { model.closeTab(tab.id) }
        }
    }
}

struct FolderContextMenu: View {
    let model: BrowserViewModel
    let folder: SidebarFolder
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        let targets = model.store.menuTargets(for: folder.id, in: window)
        if targets.count > 1 {
            SelectionContextMenu(model: model, ids: targets)
        } else {
            singleFolderMenu
        }
    }

    @ViewBuilder
    private var singleFolderMenu: some View {
        let store = model.store
        let expanded = store.isFolderExpanded(folder.id)
        Button("Rename Folder…") { model.beginRename(.folder(folder.id)) }
        ItemIconMenu(model: model, itemID: folder.id)
        Button("New Folder Inside") { model.newFolder(parentFolderID: folder.id) }
        if let spaceID = store.spaceContaining(entryID: folder.id) {
            MoveToProfileMenu(model: model, ids: [folder.id], spaceID: spaceID)
        }
        Divider()
        Button(expanded ? "Collapse Folder" : "Expand Folder") { store.setFolderExpanded(folder.id, !expanded) }
        Button("Expand All Folders") { store.setAllFoldersExpanded(true) }
        Button("Collapse All Folders") { store.setAllFoldersExpanded(false) }
        Divider()
        Button("Remove Folder, Keep Tabs") { model.deleteFolder(folder.id, keepingChildren: true) }
        Button("Delete Folder and Tabs…", role: .destructive) {
            model.pendingDeletion = .folderAndContents(folder.id)
        }
    }
}

/// Splits and easels move between Pinned and Today as one item.
struct SectionItemContextMenu: View {
    let model: BrowserViewModel
    let entry: SidebarEntry
    /// The split pane right-clicked, for its own items.
    var paneID: Tab.ID? = nil
    @Environment(\.sidebarWindow) private var window

    var body: some View {
        let targets = model.store.menuTargets(for: entry.id, in: window)
        if targets.count > 1 {
            SelectionContextMenu(model: model, ids: targets)
        } else {
            singleItemMenu
        }
    }

    @ViewBuilder
    private var singleItemMenu: some View {
        let store = model.store
        if let spaceID = store.spaceContaining(entryID: entry.id),
           case .section(_, let section) = store.parent(of: entry.id) {
            let target: ItemContainerKind.SpaceSection = section == .pinned ? .unpinned : .pinned
            Button(section == .pinned ? "Unpin" : "Pin") {
                let index = target == .pinned ? store.content(for: spaceID).pinned.count : 0
                model.moveItem(entry.id, to: .section(spaceID: spaceID, section: target), index: index)
            }
        }
        if case .split(let split) = entry {
            Button("Rename…") { model.beginSplitRename(split.id) }
        }
        ItemIconMenu(model: model, itemID: entry.id)
        switch entry {
        case .split(let split):
            // Arc's Split View Context Menu: add a tab, separate all, flip,
            // then the right-clicked pane's own items under its title.
            Divider()
            Button("Add Tab to Split View") { model.addBlankPane(to: split.id) }
            Button("Separate All Tabs") { model.unsplit(split.id) }
            Button(split.orientation == .horizontal ? "Arrange Top and Bottom" : "Arrange Side by Side") {
                model.flipSplitOrientation(split.id)
            }
            Button("Expand Current Split") {
                model.selectSplit(split.id, focusTabID: split.focusTabID)
                model.toggleExpandedSplitPane(split.id)
            }
            if let pane = split.tabs.first(where: { $0.id == (paneID ?? split.focusTabID) }) {
                Section(pane.displayTitle) {
                    Button("Rename Pane…") { model.beginRename(.tab(pane.id)) }
                    Button("Separate from Split View") { model.unsplitTabIfInSplit(pane.id) }
                    Button("Copy Link") { model.copyURL(of: pane.id) }
                    Button("Close Pane") { model.closeTab(pane.id) }
                }
            }
            Divider()
            Button("Copy Links") { model.copySplitLinks(split.id, markdown: false) }
            Button("Copy Links as Markdown") { model.copySplitLinks(split.id, markdown: true) }
            Divider()
            if let spaceID = store.spaceContaining(entryID: split.id) {
                MoveToProfileMenu(model: model, ids: [split.id], spaceID: spaceID)
            }
            Button("Close Split View") { model.closeSplit(split.id) }
        case .easel(let ref):
            Divider()
            Button("Delete") { model.deleteEaselSidebarItem(ref.id) }
        case .tab, .folder:
            EmptyView()
        }
    }
}

/// The menu of a row inside a multi-row selection: the single row's
/// commands that make sense for several, acting on all of them in sidebar
/// order. A right-click outside the selection gets that row's own menu
/// (and the selection goes, `SidebarListController`).
struct SelectionContextMenu: View {
    let model: BrowserViewModel
    let ids: [UUID]

    var body: some View {
        let store = model.store
        let tabs = store.plainTabIDs(ids).filter { store.splitContaining(tabID: $0) == nil }
        let today = tabs.filter { store.kind(of: $0) == .today }
        let pinned = tabs.filter { store.kind(of: $0) == .pinned }
        let spaceID = ids.first.flatMap { store.spaceContaining(entryID: $0) }

        Button("Copy Links") { model.copyLinks(of: ids) }
            .disabled(store.linkTabIDs(for: ids).isEmpty)
        Button("Copy Links as Markdown") { model.copyLinks(of: ids, format: .markdown) }
            .disabled(store.linkTabIDs(for: ids).isEmpty)
        Divider()
        if !today.isEmpty {
            Button(today.count == 1 ? "Pin Tab" : "Pin \(today.count) Tabs") { model.pinTabs(today) }
        }
        if !pinned.isEmpty {
            Button(pinned.count == 1 ? "Unpin Tab" : "Unpin \(pinned.count) Tabs") { model.unpinTabs(pinned) }
        }
        if !tabs.isEmpty {
            Button("Add to Favorites") { model.addTabsToFavorites(tabs) }
            Button(tabs.count == 1 ? "Duplicate" : "Duplicate \(tabs.count) Tabs") { model.duplicateTabs(tabs) }
        }
        if model.canOpenInSplitView(ids) {
            Button("Open in Split View") { model.openInSplitView(ids) }
        }
        Divider()
        if let spaceID {
            Menu("Move to Folder") {
                let outline = store.folderOutline(in: spaceID).filter { !ids.contains($0.folder.id) }
                ForEach(outline, id: \.folder.id) { item in
                    Button(String(repeating: "    ", count: item.depth) + item.folder.title) {
                        model.moveItems(ids, intoFolder: item.folder.id)
                    }
                }
                if !outline.isEmpty { Divider() }
                Button("New Folder with Selection") { model.newFolder(withSelection: ids) }
            }
            let owner = store.space(withID: spaceID)?.profileID ?? store.activeProfileID
            let otherSpaces = store.spaces(in: owner).filter { $0.id != spaceID }
            if !otherSpaces.isEmpty {
                Menu("Move to Space") {
                    ForEach(otherSpaces) { space in
                        Button(space.name) { model.moveItems(ids, toSpace: space.id) }
                    }
                }
            }
            MoveToProfileMenu(model: model, ids: ids, spaceID: spaceID)
        }
        Divider()
        if !tabs.isEmpty {
            Button(tabs.count == 1 ? "Archive Tab" : "Archive \(tabs.count) Tabs") { model.archiveTabs(tabs) }
        }
        Button(model.closeMenuTitle(for: ids)) { model.closeItems(ids) }
            .disabled(tabs.isEmpty && !ids.contains { store.split(withID: $0) != nil })
    }
}

/// Move to Profile ▸: the other profiles' spaces under each profile's name.
/// Move to Space lists only the row's own profile, so a move that changes
/// the tabs' cookies and sign-ins is always a choice made here, and confirmed.
struct MoveToProfileMenu: View {
    let model: BrowserViewModel
    let ids: [UUID]
    let spaceID: Space.ID

    var body: some View {
        let destinations = model.store.profileMoveDestinations(from: spaceID)
        if !destinations.isEmpty {
            Menu("Move to Profile") {
                ForEach(destinations, id: \.profile.id) { destination in
                    Section(destination.profile.name) {
                        ForEach(destination.spaces) { space in
                            Button(space.name) { model.requestProfileMove(ids, toSpace: space.id) }
                        }
                    }
                }
            }
        }
    }
}

/// The space menu on the sidebar header and in the space switcher
/// (Arc `spaceHeaderContextMenu`: rename, edit theme, boosts, delete).
struct SpaceContextMenu: View {
    let model: BrowserViewModel
    let space: Space

    var body: some View {
        Button("Rename Space…") { model.beginRename(.space(space.id)) }
        Button("Edit Theme Color") {
            if model.store.activeSpaceID != space.id { model.selectSpace(space.id) }
            model.themePopoverSpaceID = space.id
        }
        Button("Edit Theme and Icon…") { model.spaceEditorID = space.id }
        SpaceProfileMenu(model: model, space: space)
        Divider()
        Button("New Space…") { model.beginSpaceCreation() }
        Button("Reset All Tabs in This Space") {
            if model.store.activeSpaceID != space.id { model.selectSpace(space.id) }
            model.resetPinnedTabs()
        }
        Button("Clear Unpinned Tabs") {
            if model.store.activeSpaceID != space.id { model.selectSpace(space.id) }
            model.clearTodayTabs()
        }
        Divider()
        Button("New Folder") {
            if model.store.activeSpaceID != space.id { model.selectSpace(space.id) }
            model.newFolder()
        }
        Button("Expand All Folders") { model.store.setAllFoldersExpanded(true, in: space.id) }
        Button("Collapse All Folders") { model.store.setAllFoldersExpanded(false, in: space.id) }
        Divider()
        // Under the profile's master switch: with that off there is nothing to turn off here.
        Toggle("Boosts in This Space", isOn: Binding(
            get: { space.boostsEnabled },
            set: { model.setSpaceBoostsEnabled($0, for: space.id) }
        ))
        .disabled(!model.store.boostLibrary(for: space.profileID).masterEnabled)
        Divider()
        Button("Delete Space…", role: .destructive) { model.pendingDeletion = .space(space.id) }
            .disabled(!model.canDeleteSpaces)
    }
}

/// The same complete container choices in the header, space menu and edit sheet.
struct SpaceProfileChoices: View {
    let model: BrowserViewModel
    let space: Space
    var onSelect: ((Profile.ID) -> Void)? = nil

    var body: some View {
        ForEach(model.store.profileChoices(forSpace: space.id)) { profile in
            Button {
                if let onSelect { onSelect(profile.id) }
                else { model.requestSpaceProfileChange(space.id, to: profile.id) }
            } label: {
                if profile.id == space.profileID {
                    Label(profile.name, systemImage: "checkmark")
                } else {
                    Text(profile.name)
                }
            }
            .disabled(profile.id == space.profileID)
        }
        Divider()
        Button("New Profile…") { model.beginProfileCreation(forSpace: space.id) }
        Button("New Container for This Space") { model.createContainerForSpace(space.id) }
    }
}

struct SpaceProfileMenu: View {
    let model: BrowserViewModel
    let space: Space

    var body: some View {
        Menu("Change Profile") { SpaceProfileChoices(model: model, space: space) }
            .help("Choose the cookies, sign-ins and site storage used by this space")
    }
}
