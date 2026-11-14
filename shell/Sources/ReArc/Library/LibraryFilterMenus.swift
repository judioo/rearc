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
            LibraryFilterLabel(isActive: downloads.libraryFilter.isActive)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
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
                ForEach(model.store.visibleSpaces) { space in
                    Text(space.name).tag(Optional(space.id))
                }
                if let id = model.archiveFilter.spaceID, model.store.listedSpace(withID: id) == nil {
                    Text(model.store.space(withID: id) == nil ? "Deleted Space" : "Archived Space").tag(Optional(id))
                }
            }
            Picker("Date", selection: $model.archiveFilter.date) {
                ForEach(LibraryDateFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Reset Filters") { model.archiveFilter = LibraryArchiveFilter() }
                .disabled(!model.archiveFilter.isActive)
        } label: {
            LibraryFilterLabel(isActive: model.archiveFilter.isActive)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(model.archiveFilter.isActive ? "Filter Archive, active" : "Filter Archive")
    }
}

/// The Filter menus' label, in the sidebar's ink. A borderless menu draws
/// its title in the theme's tint, which on a light theme all but vanished
/// into the column (#D7D9F3 on #E2E2F4, about 1.1:1, on the default lavender).
private struct LibraryFilterLabel: View {
    let isActive: Bool
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        HStack(spacing: 3) {
            Label("Filter", systemImage: isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                .accessibilityHidden(true)
        }
        .font(.system(size: 13))
        .foregroundStyle(chrome.title)
        .contentShape(Rectangle())
    }
}
