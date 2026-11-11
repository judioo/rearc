import Foundation
import SidebarModel

/// A rename typed into the sidebar row itself, the way Arc renames tabs and
/// folders (docs/arc-recordings/2026-11-06-tab-rename.md): the title turns
/// into a field in place, Return or a click away saves, Esc puts the old
/// name back.
struct SidebarInlineRename: Equatable {
    enum Ending: Equatable {
        /// Return, Tab, or focus leaving the field.
        case commit
        /// Esc.
        case cancel
    }

    let target: SidebarRenameRequest
    /// The name when the edit began: the empty field's placeholder, and what
    /// Esc leaves in place.
    let previousName: String
    /// What the field holds now; it starts as the whole old name, selected.
    var text: String

    init(target: SidebarRenameRequest, previousName: String) {
        self.target = target
        self.previousName = previousName
        text = previousName
    }

    /// The name to save when the edit ends, or nil to leave the row as it
    /// was. An empty tab name clears the custom title, so the page title
    /// shows again; an empty folder name keeps the folder's name.
    func savedName(on ending: Ending) -> String? {
        guard ending == .commit else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != previousName else { return nil }
        if trimmed.isEmpty {
            switch target {
            case .folder, .space: return nil
            case .tab: break
            }
        }
        return trimmed
    }
}

extension BrowserViewModel {
    /// Starts an in-place rename when the row is on screen to type into: a
    /// tab, folder, favorite, split pane or space header in the active space
    /// with the sidebar showing.
    /// A rename already under way on another row is saved first.
    func beginInlineRename(_ request: SidebarRenameRequest) -> Bool {
        // A mini column has no room for a field: the rename asks in an alert.
        guard isSidebarVisible, librarySection(in: store.keyWindowID) == nil, !isMiniSidebar(in: store.keyWindowID) else { return false }
        let name: String
        let rowID: UUID
        switch request {
        case .tab(let id):
            guard let tab = store.tab(withID: id) else { return false }
            if store.kind(of: id) == .favorite {
                guard store.favorites(in: store.activeProfileID).contains(where: { $0.id == id }) else { return false }
            } else {
                guard store.spaceContaining(tabID: id) == store.activeSpaceID else { return false }
            }
            name = tab.displayTitle
            rowID = id
        case .folder(let id):
            guard let folder = store.folder(withID: id), store.spaceContaining(entryID: id) == store.activeSpaceID else { return false }
            name = folder.title
            rowID = id
        case .space(let id):
            guard id == store.activeSpaceID, let space = store.space(withID: id) else { return false }
            name = space.name
            rowID = id
        }
        if inlineRename != nil, inlineRename?.target != request { endInlineRename(.commit) }
        guard inlineRename?.target != request else { return true }
        // A row inside a collapsed folder has to show to be typed into.
        var folderID = store.parentFolderID(of: rowID)
        while let id = folderID {
            store.setFolderExpanded(id, true)
            folderID = store.parentFolderID(of: id)
        }
        inlineRename = SidebarInlineRename(target: request, previousName: name)
        return true
    }

    /// `target`: the row's field that typed it. A field still on screen after
    /// its rename ended (another row's began) changes nothing.
    func updateInlineRename(_ text: String, target: SidebarRenameRequest? = nil) {
        guard inlineRename != nil, target == nil || inlineRename?.target == target else { return }
        inlineRename?.text = text
    }

    /// Saves (Return, Tab, a click away) or drops (Esc) the in-place rename;
    /// false when there was none to end.
    @discardableResult
    func endInlineRename(_ ending: SidebarInlineRename.Ending, target: SidebarRenameRequest? = nil) -> Bool {
        guard let rename = inlineRename, target == nil || rename.target == target else { return false }
        inlineRename = nil
        guard let name = rename.savedName(on: ending) else { return true }
        switch rename.target {
        case .tab(let id): store.renameTab(id, to: name)
        case .folder(let id): store.renameFolder(id, to: name)
        case .space(let id): store.renameSpace(id, to: name)
        }
        return true
    }

    /// The edit typed into this row, if any.
    func inlineRename(forRow id: UUID) -> SidebarInlineRename? {
        guard let rename = inlineRename else { return nil }
        switch rename.target {
        case .tab(let target), .folder(let target), .space(let target): return target == id ? rename : nil
        }
    }
}
