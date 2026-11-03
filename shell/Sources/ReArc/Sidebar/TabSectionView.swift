import SwiftUI
import UniformTypeIdentifiers
import SidebarModel

/// One section of the sidebar (pinned or today) for the active space.
struct TabSectionView: View {
    let title: String?
    let section: ItemContainerKind.SpaceSection
    let entries: [SidebarEntry]
    let model: BrowserViewModel
    @Binding var draggedItemID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title, !entries.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            ForEach(entries, id: \.id) { entry in
                entryRow(entry)
                    .onDrag {
                        draggedItemID = entry.id
                        return NSItemProvider(object: entry.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [.plainText],
                        delegate: SectionDropDelegate(
                            targetEntry: entry,
                            section: section,
                            model: model,
                            draggedItemID: $draggedItemID
                        )
                    )
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: SidebarEntry) -> some View {
        switch entry {
        case .tab(let tab):
            TabRowView(
                tab: tab,
                isSelected: model.store.selectedItemID == tab.id,
                showsAudibleIndicator: model.showsAudibleIndicator(for: tab.id),
                onSelect: { model.selectTab(tab.id) },
                onClose: { model.closeTab(tab.id) },
                onMute: { model.muteTab(tab.id) },
                onCloseOption: { model.unsplitTabIfInSplit(tab.id) },
                onEditBoost: {
                    model.selectTab(tab.id)
                    model.editBoostFromTabContextMenu()
                }
            )
        case .easel(let ref):
            EaselRowView(
                ref: ref,
                title: model.easelTitle(for: ref),
                isSelected: model.store.selectedItemID == ref.id,
                onSelect: { model.selectEasel(ref.id) },
                onClose: { model.deleteEaselSidebarItem(ref.id) },
                onRename: { model.renameEasel(documentID: ref.easelDocumentID, title: $0) }
            )
        case .folder:
            EmptyView()
        case .split(let split):
            SplitRowView(
                split: split,
                isSelected: model.store.selectedItemID == split.id,
                focusedTabID: split.focusTabID,
                themeColor: model.themeColor,
                showsAudibleIndicator: { model.showsAudibleIndicator(for: $0) },
                onMutePane: { model.muteTab($0) },
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
        }
    }
}

struct SectionDropDelegate: DropDelegate {
    let targetEntry: SidebarEntry
    let section: ItemContainerKind.SpaceSection
    let model: BrowserViewModel
    @Binding var draggedItemID: UUID?

    func dropEntered(info: DropInfo) {
        guard let draggedItemID,
              draggedItemID != targetEntry.id,
              let destination = sectionEntries().firstIndex(where: { $0.id == targetEntry.id })
        else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            model.store.moveEntry(
                draggedItemID,
                to: destination,
                in: model.store.activeSpaceID,
                section: section
            )
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let draggedItemID else { return DropProposal(operation: .forbidden) }
        let compatible = isSameSection(draggedItemID)
        return DropProposal(operation: compatible ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedItemID = nil
        return true
    }

    private func isSameSection(_ id: UUID) -> Bool {
        if model.store.favorites.contains(where: { $0.id == id }) { return false }
        if let loc = model.store.locateSplit(id) {
            return loc.section == section
        }
        if let loc = model.store.locateEasel(id) {
            return loc.section == section
        }
        guard let kind = model.store.kind(of: id) else { return false }
        switch (kind, section) {
        case (.pinned, .pinned), (.today, .unpinned): return true
        default: return false
        }
    }

    private func sectionEntries() -> [SidebarEntry] {
        let content = model.store.content(for: model.store.activeSpaceID)
        switch section {
        case .pinned: return content.pinned
        case .unpinned: return content.today
        }
    }
}
