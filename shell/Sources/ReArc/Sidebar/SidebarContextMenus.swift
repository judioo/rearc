import SwiftUI
import SidebarModel

// Sidebar item context menus (SIDEBAR-SPEC §4.9: pin/unpin, rename, duplicate,
// copy URL, move to space, archive, close; folders: rename, expand, delete).

struct TabContextMenu: View {
    let model: BrowserViewModel
    let tab: Tab

    var body: some View {
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
        Divider()
        Button("Rename…") { model.beginRename(.tab(tab.id)) }
        Button("Duplicate") { model.duplicateTab(tab.id) }
        Button("Copy Link") { model.copyURL(of: tab.id) }
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
            let otherSpaces = store.spacesInActiveProfile.filter { $0.id != store.spaceContaining(tabID: tab.id) }
            if !otherSpaces.isEmpty {
                Menu("Move to Space") {
                    ForEach(otherSpaces) { space in
                        Button(space.name) { model.moveTab(tab.id, toSpace: space.id) }
                    }
                }
            }
        }
        Button("Open in Little Arc") { model.openLittleArc(url: tab.url, title: tab.displayTitle) }
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
        Button(kind == .favorite ? "Unload Tab" : "Close Tab") { model.closeTab(tab.id) }
    }
}

struct FolderContextMenu: View {
    let model: BrowserViewModel
    let folder: SidebarFolder

    var body: some View {
        let store = model.store
        let expanded = store.isFolderExpanded(folder.id)
        Button("Rename Folder…") { model.beginRename(.folder(folder.id)) }
        Button("New Folder Inside") { model.newFolder(parentFolderID: folder.id) }
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

    var body: some View {
        let store = model.store
        if let spaceID = store.spaceContaining(entryID: entry.id),
           case .section(_, let section) = store.parent(of: entry.id) {
            let target: ItemContainerKind.SpaceSection = section == .pinned ? .unpinned : .pinned
            Button(section == .pinned ? "Unpin" : "Pin") {
                let index = target == .pinned ? store.content(for: spaceID).pinned.count : 0
                model.moveItem(entry.id, to: .section(spaceID: spaceID, section: target), index: index)
            }
        }
        switch entry {
        case .split(let split):
            Button("Separate Split View") { model.unsplit(split.id) }
            Button("Copy Links") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(split.tabs.map(\.url.absoluteString).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("Close Split View") { model.closeSplit(split.id) }
        case .easel(let ref):
            Divider()
            Button("Delete") { model.deleteEaselSidebarItem(ref.id) }
        case .tab, .folder:
            EmptyView()
        }
    }
}

/// The space menu on the sidebar header and in the space switcher
/// (Arc `spaceHeaderContextMenu`: rename, edit theme, delete).
struct SpaceContextMenu: View {
    let model: BrowserViewModel
    let space: Space

    var body: some View {
        Button("Rename Space…") { model.beginRename(.space(space.id)) }
        Button("Edit Theme and Icon…") { model.spaceEditorID = space.id }
        Divider()
        Button("New Folder") {
            if model.store.activeSpaceID != space.id { model.selectSpace(space.id) }
            model.newFolder()
        }
        Button("Expand All Folders") { model.store.setAllFoldersExpanded(true, in: space.id) }
        Button("Collapse All Folders") { model.store.setAllFoldersExpanded(false, in: space.id) }
        Divider()
        Button("Delete Space…", role: .destructive) { model.pendingDeletion = .space(space.id) }
            .disabled(!model.canDeleteSpaces)
    }
}
