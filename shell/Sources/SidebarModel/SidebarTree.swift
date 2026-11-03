import Foundation

/// Recursive helpers over a section's entry tree (folders nest arbitrarily,
/// SIDEBAR-SPEC "Serialized schema": lists-in-lists observed 8 deep).
public enum SidebarTree {
    /// Every non-folder entry in display order, descending into folders.
    public static func leaves(_ entries: [SidebarEntry]) -> [SidebarEntry] {
        entries.flatMap { entry -> [SidebarEntry] in
            if case .folder(let folder) = entry { return leaves(folder.children) }
            return [entry]
        }
    }

    /// Every folder in the tree, outermost first.
    public static func folders(_ entries: [SidebarEntry]) -> [SidebarFolder] {
        entries.flatMap { entry -> [SidebarFolder] in
            guard case .folder(let folder) = entry else { return [] }
            return [folder] + folders(folder.children)
        }
    }

    public static func contains(_ id: UUID, in entries: [SidebarEntry]) -> Bool {
        find(id, in: entries) != nil
    }

    public static func find(_ id: UUID, in entries: [SidebarEntry]) -> SidebarEntry? {
        for entry in entries {
            if entry.id == id { return entry }
            if case .folder(let folder) = entry, let found = find(id, in: folder.children) {
                return found
            }
        }
        return nil
    }

    public static func folder(_ id: UUID, in entries: [SidebarEntry]) -> SidebarFolder? {
        if case .folder(let folder) = find(id, in: entries) { return folder }
        return nil
    }

    /// The folder directly holding `id`: `.some(nil)` at section level, nil when absent.
    public static func parentFolderID(of id: UUID, in entries: [SidebarEntry]) -> UUID?? {
        for entry in entries {
            if entry.id == id { return .some(nil) }
            if case .folder(let folder) = entry,
               let nested = parentFolderID(of: id, in: folder.children) {
                return .some(nested ?? folder.id)
            }
        }
        return nil
    }

    /// Folder ids from the section root down to the folder holding `id`.
    public static func ancestorFolderIDs(of id: UUID, in entries: [SidebarEntry]) -> [UUID]? {
        for entry in entries {
            if entry.id == id { return [] }
            if case .folder(let folder) = entry,
               let path = ancestorFolderIDs(of: id, in: folder.children) {
                return [folder.id] + path
            }
        }
        return nil
    }

    /// Removes `id` wherever it is in the tree and returns it.
    @discardableResult
    public static func remove(_ id: UUID, from entries: inout [SidebarEntry]) -> SidebarEntry? {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            return entries.remove(at: index)
        }
        for index in entries.indices {
            guard case .folder(var folder) = entries[index] else { continue }
            if let removed = remove(id, from: &folder.children) {
                entries[index] = .folder(folder)
                return removed
            }
        }
        return nil
    }

    /// Applies `transform` to the entry with `id`; false when it is not in the tree.
    @discardableResult
    public static func update(
        _ id: UUID,
        in entries: inout [SidebarEntry],
        _ transform: (inout SidebarEntry) -> Void
    ) -> Bool {
        for index in entries.indices {
            if entries[index].id == id {
                transform(&entries[index])
                return true
            }
            guard case .folder(var folder) = entries[index] else { continue }
            if update(id, in: &folder.children, transform) {
                entries[index] = .folder(folder)
                return true
            }
        }
        return false
    }

    /// Children of folder `id`; nil when the folder is not in the tree.
    public static func children(of folderID: UUID, in entries: [SidebarEntry]) -> [SidebarEntry]? {
        folder(folderID, in: entries)?.children
    }

    @discardableResult
    public static func setChildren(_ children: [SidebarEntry], of folderID: UUID, in entries: inout [SidebarEntry]) -> Bool {
        update(folderID, in: &entries) { entry in
            guard case .folder(var folder) = entry else { return }
            folder.children = children
            entry = .folder(folder)
        }
    }

    /// Sorts every level by LexoRank (folder children included).
    public static func sortedRecursively(_ entries: [SidebarEntry]) -> [SidebarEntry] {
        RankedSortable.sortedEntries(entries).map { entry in
            guard case .folder(var folder) = entry else { return entry }
            folder.children = sortedRecursively(folder.children)
            return .folder(folder)
        }
    }

    /// Tabs anywhere in the tree, including split panes.
    public static func tabs(_ entries: [SidebarEntry]) -> [Tab] {
        leaves(entries).flatMap { entry -> [Tab] in
            switch entry {
            case .tab(let tab): return [tab]
            case .split(let split): return split.tabs
            case .easel, .folder: return []
            }
        }
    }

    /// Sets `kind` on every tab in `entry` (including folder descendants and split panes).
    public static func settingKind(_ kind: Tab.Kind, on entry: SidebarEntry) -> SidebarEntry {
        switch entry {
        case .tab(var tab):
            tab.kind = kind
            return .tab(tab)
        case .split(var split):
            split.tabs = split.tabs.map { var tab = $0; tab.kind = kind; return tab }
            return .split(split)
        case .easel:
            return entry
        case .folder(var folder):
            folder.children = folder.children.map { settingKind(kind, on: $0) }
            return .folder(folder)
        }
    }
}
