import SwiftUI
import SidebarModel

struct DownloadsLibraryFilterMenu: View {
    @Bindable var downloads: DownloadsController

    var body: some View {
        Menu {
            Picker("State", selection: $downloads.libraryFilter.state) {
                ForEach(LibraryDownloadState.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Type", selection: $downloads.libraryFilter.type) {
                ForEach(LibraryDownloadType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Date", selection: $downloads.libraryFilter.date) {
                ForEach(LibraryDateFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Reset Filters") { downloads.libraryFilter = LibraryDownloadFilter() }
                .disabled(!downloads.libraryFilter.isActive)
        } label: {
            Label("Filter", systemImage: downloads.libraryFilter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(downloads.libraryFilter.isActive ? "Filter Downloads, active" : "Filter Downloads")
    }
}

struct ArchiveLibraryFilterMenu: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        Menu {
            Picker("Space", selection: $model.archiveFilter.spaceID) {
                Text("All Spaces").tag(Optional<Space.ID>.none)
                ForEach(model.store.spaces) { space in
                    Text(space.name).tag(Optional(space.id))
                }
                if let id = model.archiveFilter.spaceID, model.store.space(withID: id) == nil {
                    Text("Deleted Space").tag(Optional(id))
                }
            }
            Picker("Date", selection: $model.archiveFilter.date) {
                ForEach(LibraryDateFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Reset Filters") { model.archiveFilter = LibraryArchiveFilter() }
                .disabled(!model.archiveFilter.isActive)
        } label: {
            Label("Filter", systemImage: model.archiveFilter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(model.archiveFilter.isActive ? "Filter Archive, active" : "Filter Archive")
    }
}
