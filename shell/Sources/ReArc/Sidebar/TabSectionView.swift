import SwiftUI
import UniformTypeIdentifiers
import SidebarModel

/// Where a drag hovering a sidebar row lands: next to it, or into it (a
/// folder takes the item; a tab makes a new folder with the dragged tab).
enum SidebarDropPosition: Equatable {
    case before, after, into
}

struct SidebarDropState: Equatable {
    var targetID: UUID
    var position: SidebarDropPosition
}

/// One visible row: an entry and its folder depth. A collapsed folder still
/// shows its selected descendant (Arc's "peeked" expansion state).
struct SidebarRowItem: Identifiable {
    let entry: SidebarEntry
    let depth: Int
    var id: UUID { entry.id }

    static func rows(_ entries: [SidebarEntry], depth: Int = 0, expanded: Set<UUID>, selected: UUID?) -> [SidebarRowItem] {
        entries.flatMap { entry -> [SidebarRowItem] in
            guard case .folder(let folder) = entry else { return [SidebarRowItem(entry: entry, depth: depth)] }
            let header = SidebarRowItem(entry: entry, depth: depth)
            if expanded.contains(folder.id) {
                return [header] + rows(folder.children, depth: depth + 1, expanded: expanded, selected: selected)
            }
            if let selected, let leaf = SidebarTree.leaves(folder.children).first(where: { $0.id == selected }) {
                return [header, SidebarRowItem(entry: leaf, depth: depth + 1)]
            }
            return [header]
        }
    }
}

/// One section of the sidebar (pinned or today) for the active space.
struct TabSectionView: View {
    let title: String?
    let section: ItemContainerKind.SpaceSection
    let spaceID: Space.ID
    let entries: [SidebarEntry]
    let model: BrowserViewModel
    @Binding var draggedItemID: UUID?
    @Binding var dropState: SidebarDropState?
    @Environment(\.sidebarWindow) private var window

    /// This window's selection in this space.
    private var selectedID: UUID? { model.store.selectedItemID(inSpace: spaceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title, !entries.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            let rows = SidebarRowItem.rows(
                entries,
                expanded: model.store.expandedFolderIDs,
                selected: selectedID
            )
            ForEach(rows) { row in
                SidebarDropRow(
                    entry: row.entry,
                    model: model,
                    draggedItemID: $draggedItemID,
                    dropState: $dropState
                ) {
                    entryRow(row.entry)
                }
                .padding(.leading, CGFloat(row.depth) * 14)
            }
            SectionEndDropZone(
                destination: .section(spaceID: spaceID, section: section),
                placeholder: entries.isEmpty && draggedItemID != nil
                    ? (section == .pinned ? "Drop here to pin" : "Drop here to unpin")
                    : nil,
                model: model,
                draggedItemID: $draggedItemID,
                dropState: $dropState
            )
        }
    }

    private func isDropInto(_ id: UUID) -> Bool {
        dropState == SidebarDropState(targetID: id, position: .into)
    }

    @ViewBuilder
    private func entryRow(_ entry: SidebarEntry) -> some View {
        switch entry {
        case .tab(let tab):
            TabRowView(
                tab: tab,
                favicon: model.favicon(for: tab),
                isSelected: selectedID == tab.id,
                showsAudibleIndicator: model.showsAudibleIndicator(for: tab.id),
                isMuted: model.isUserMuted(tab.id),
                isDropTarget: isDropInto(tab.id),
                isUnloaded: model.isTabUnloaded(tab.id),
                isInPictureInPicture: model.isPictureInPicture(tab.id),
                activity: model.tabActivity(tab.id),
                onSelect: { model.selectTab(tab.id) },
                onClose: { model.closeTab(tab.id) },
                onMute: { model.toggleMute(tab.id) },
                onPictureInPicture: { model.setPictureInPicture(false, tabID: tab.id) },
                onCloseOption: { model.unsplitTabIfInSplit(tab.id) },
                onReset: tab.isAwayFromSavedURL ? { model.resetTabToSavedURL(tab.id) } : nil
            ) {
                TabContextMenu(model: model, tab: tab)
            }
        case .folder(let folder):
            FolderRowView(
                folder: folder,
                isExpanded: model.store.isFolderExpanded(folder.id),
                isDropTarget: isDropInto(folder.id),
                onToggle: { model.store.toggleFolderExpanded(folder.id) }
            ) {
                FolderContextMenu(model: model, folder: folder)
            }
        case .easel(let ref):
            EaselRowView(
                ref: ref,
                title: model.easelTitle(for: ref),
                isNote: model.easelDocumentStore.document(id: ref.easelDocumentID)?.kind == .note,
                isSelected: selectedID == ref.id,
                onSelect: { model.selectEasel(ref.id) },
                onClose: { model.deleteEaselSidebarItem(ref.id) },
                onRename: { model.renameEasel(documentID: ref.easelDocumentID, title: $0) }
            )
            .contextMenu { SectionItemContextMenu(model: model, entry: entry) }
        case .split(let split):
            SplitRowView(
                split: split,
                isSelected: selectedID == split.id,
                focusedTabID: split.focusTabID,
                themeColor: model.themeColor(in: window),
                favicon: { model.favicon(for: $0) },
                showsAudibleIndicator: { model.showsAudibleIndicator(for: $0) },
                onMutePane: { model.toggleMute($0) },
                onSelectSplit: { model.selectSplit(split.id) },
                onSelectPane: { model.selectSplit(split.id, focusTabID: $0) },
                onCloseSplit: { model.closeSplit(split.id) },
                onClosePane: { option, tabID in
                    if option {
                        model.unsplit(split.id)
                    } else {
                        model.closeTab(tabID)
                    }
                }
            )
            .contextMenu { SectionItemContextMenu(model: model, entry: entry) }
        }
    }
}

/// Makes a row draggable and a drop target with an insertion line (Arc
/// `SidebarCellDropFeedbackView`). Placement rules live in `SidebarStore.moveItem`.
struct SidebarDropRow<Content: View>: View {
    let entry: SidebarEntry
    let model: BrowserViewModel
    @Binding var draggedItemID: UUID?
    @Binding var dropState: SidebarDropState?
    @ViewBuilder let content: () -> Content

    @State private var height: CGFloat = 28

    var body: some View {
        content()
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { height = geometry.size.height }
                        .onChange(of: geometry.size.height) { _, newValue in height = newValue }
                }
            )
            .overlay(alignment: .top) { insertionLine(.before) }
            .overlay(alignment: .bottom) { insertionLine(.after) }
            .onDrag {
                draggedItemID = entry.id
                return SidebarDragPayload.itemProvider(for: entry.id)
            }
            .onDrop(
                of: SidebarURLDropLoader.acceptedTypes,
                delegate: SidebarRowDropDelegate(
                    target: entry,
                    rowHeight: height,
                    model: model,
                    draggedItemID: $draggedItemID,
                    dropState: $dropState
                )
            )
    }

    @ViewBuilder
    private func insertionLine(_ position: SidebarDropPosition) -> some View {
        if dropState == SidebarDropState(targetID: entry.id, position: position) {
            Capsule()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 6)
                .offset(y: position == .before ? -1 : 1)
                .allowsHitTesting(false)
        }
    }
}

struct SidebarRowDropDelegate: DropDelegate {
    let target: SidebarEntry
    let rowHeight: CGFloat
    let model: BrowserViewModel
    @Binding var draggedItemID: UUID?
    @Binding var dropState: SidebarDropState?

    private func position(for info: DropInfo) -> SidebarDropPosition? {
        if draggedItemID == nil, SidebarURLDropLoader.hasLinks(info) {
            // A link from a page or another app: a new tab next to this row.
            return info.location.y / max(rowHeight, 1) < 0.5 ? .before : .after
        }
        guard let draggedItemID, draggedItemID != target.id,
              let dragged = model.store.entry(withID: draggedItemID) else { return nil }
        let fraction = info.location.y / max(rowHeight, 1)
        switch target {
        case .folder(let folder):
            let canEnter: Bool
            switch dragged {
            case .tab: canEnter = true
            case .folder(let moving): canEnter = !SidebarTree.contains(folder.id, in: moving.children)
            case .split, .easel: canEnter = false
            }
            if canEnter, (0.25 ... 0.75).contains(fraction) { return .into }
        case .tab:
            if case .tab = dragged, (0.3 ... 0.7).contains(fraction) { return .into }
        case .split, .easel:
            break
        }
        return fraction < 0.5 ? .before : .after
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggedItemID != nil || SidebarURLDropLoader.hasLinks(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let position = position(for: info) else {
            if dropState?.targetID == target.id { dropState = nil }
            return DropProposal(operation: .forbidden)
        }
        let state = SidebarDropState(targetID: target.id, position: position)
        if dropState != state { dropState = state }
        return DropProposal(operation: draggedItemID == nil ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        if dropState?.targetID == target.id { dropState = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            draggedItemID = nil
            dropState = nil
        }
        if draggedItemID == nil, let position = position(for: info) {
            let target = target.id, model = model
            return SidebarURLDropLoader.load(info) { urls in
                model.openDroppedURLs(urls, relativeTo: target, after: position == .after)
            }
        }
        guard let draggedItemID, let position = position(for: info) else { return false }
        withAnimation(.easeInOut(duration: 0.15)) {
            switch (position, target) {
            case (.into, .folder(let folder)):
                model.moveItem(draggedItemID, intoFolder: folder.id)
            case (.into, _):
                model.groupIntoNewFolder(target: target.id, dragged: draggedItemID)
            case (.before, _):
                model.moveItem(draggedItemID, relativeTo: target.id, after: false)
            case (.after, _):
                model.moveItem(draggedItemID, relativeTo: target.id, after: true)
            }
        }
        return true
    }
}

/// Drop area after a container's last row: appends there (pins into an
/// empty Pinned section, unpins into Today, adds to favorites).
struct SectionEndDropZone: View {
    let destination: SidebarStore.ItemDestination
    let placeholder: String?
    let model: BrowserViewModel
    @Binding var draggedItemID: UUID?
    @Binding var dropState: SidebarDropState?

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            if let placeholder {
                Text(placeholder)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    )
            } else {
                Capsule()
                    .fill(isTargeted ? Color.accentColor : .clear)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        // Takes no room until a drag is under way, so the rows keep Arc's pitch.
        .frame(maxWidth: .infinity, minHeight: placeholder == nil ? (draggedItemID == nil ? 0 : 10) : nil)
        .contentShape(Rectangle())
        .onDrop(of: SidebarURLDropLoader.acceptedTypes, delegate: EndDropDelegate(zone: self, isTargeted: $isTargeted))
    }

    private struct EndDropDelegate: DropDelegate {
        let zone: SectionEndDropZone
        @Binding var isTargeted: Bool

        func validateDrop(info: DropInfo) -> Bool {
            zone.draggedItemID != nil || SidebarURLDropLoader.hasLinks(info)
        }

        func dropEntered(info: DropInfo) {
            isTargeted = true
            zone.dropState = nil
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            if zone.draggedItemID == nil { return DropProposal(operation: SidebarURLDropLoader.hasLinks(info) ? .copy : .forbidden) }
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) { isTargeted = false }

        func performDrop(info: DropInfo) -> Bool {
            isTargeted = false
            defer { zone.draggedItemID = nil }
            guard let dragged = zone.draggedItemID else {
                let model = zone.model, destination = zone.destination
                return SidebarURLDropLoader.load(info) { urls in model.openDroppedURLs(urls, appendingTo: destination) }
            }
            let store = zone.model.store
            let count = store.entries(in: store.resolvedParent(zone.destination)).filter { $0.id != dragged }.count
            withAnimation(.easeInOut(duration: 0.15)) {
                zone.model.moveItem(dragged, to: zone.destination, index: count)
            }
            return true
        }
    }
}

/// Reads links and files dropped on the sidebar from pages and other apps.
enum SidebarURLDropLoader {
    /// Sidebar drags carry their UUID as plain text (and `SidebarDragType`).
    static let acceptedTypes: [UTType] = [.plainText, .url, .fileURL]

    static func hasLinks(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.url, .fileURL])
    }

    /// Loads every dropped URL, then calls `open` once on the main queue. False when nothing can load.
    static func load(_ info: DropInfo, open: @escaping ([URL]) -> Void) -> Bool {
        let providers = info.itemProviders(for: [.fileURL, .url])
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls = [URL?](repeating: nil, count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                lock.lock()
                urls[index] = (object as? NSURL).map { $0 as URL }
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { open(urls.compactMap { $0 }) }
        return true
    }
}
