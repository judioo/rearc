import AppKit
import SwiftUI
import SidebarModel

/// Arc's Library (Home button panel, SIDEBAR-SPEC §3.1.6): a page list on
/// the left (Spaces, Downloads, Media, Easels & Notes, Archive, Boosts) and
/// the page on the right, over the window's page area. Esc or the close
/// button brings the page back, as does showing any sidebar item.
struct LibraryView: View {
    let model: BrowserViewModel
    let window: SidebarWindowID?
    let section: LibrarySection

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                ForEach(LibrarySection.allCases, id: \.self) { page in
                    Button { model.openLibrary(page, in: window) } label: {
                        Label(page.title, systemImage: page.systemImage)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(page == section ? Color.accentColor.opacity(0.18) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == section ? .isSelected : [])
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 190)
            .background(.quaternary.opacity(0.5))

            Divider()

            VStack(spacing: 0) {
                HStack {
                    Label(section.title, systemImage: section.systemImage)
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button { model.closeLibrary(in: window) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .help("Close Library (Esc)")
                }
                .padding([.horizontal, .top], 16)
                .padding(.bottom, 4)

                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .spaces: LibrarySpacesPage(model: model, window: window)
        case .downloads: LibraryDownloadsPage(model: model)
        case .media: LibraryMediaPage(model: model)
        case .easels: LibraryEaselsPage(model: model)
        case .archive: ArchiveView(model: model)
        case .boosts: BoostLibraryView(model: model)
        }
    }
}

// MARK: - Spaces

private struct LibrarySpacesPage: View {
    let model: BrowserViewModel
    let window: SidebarWindowID?
    @Environment(\.colorScheme) private var colorScheme
    private let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]

    var body: some View {
        let current = model.space(in: window).id
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(LibrarySpaces.groups(in: model.store), id: \.profile.id) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ProfileAvatarView(profile: group.profile, diameter: 18)
                            Text(group.profile.name).font(.headline)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(group.rows) { row in
                                card(row, isCurrent: row.id == current)
                            }
                            Button { model.beginSpaceCreation(profileID: group.profile.id) } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "plus").font(.title2)
                                    Text("New Space…").font(.callout)
                                }
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 96)
                                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4])))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private func card(_ row: LibrarySpaceRow, isCurrent: Bool) -> some View {
        let palette = SpaceThemePalette(
            theme: row.space.theme,
            darkAppearance: row.space.theme.appearance.isDark(systemDark: SystemAppearance.isDark(colorScheme))
        )
        let foreground: Color = palette.prefersLightForeground ? .white : .black.opacity(0.8)
        return Button { model.openLibrarySpace(row.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                SpaceIconView(iconName: row.space.iconName, size: 18)
                    .frame(width: 28, height: 28)
                Spacer(minLength: 0)
                Text(row.space.name).font(.headline).lineLimit(1)
                Text("\(row.pinnedCount) pinned · \(row.todayCount) today")
                    .font(.caption)
                    .opacity(0.75)
            }
            .foregroundStyle(foreground)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(SpaceThemeFill(palette: palette).clipShape(RoundedRectangle(cornerRadius: 12)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isCurrent ? Color(palette.accent) : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(isCurrent ? "\(row.space.name) (shown in this window)" : "Switch to \(row.space.name)")
        .contextMenu { SpaceContextMenu(model: model, space: row.space) }
    }
}

// MARK: - Downloads

private struct LibraryDownloadsPage: View {
    let model: BrowserViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DownloadsTrayView(downloads: model.downloads, embedded: true)
            if BrowserInternalPage.downloads.isAvailable(engine: model.engineHost.navigationSchemes) {
                Button("Open Chromium’s Downloads Page") {
                    model.openBrowserPage(.downloads)
                    model.closeLibrary()
                }
                .buttonStyle(.link)
                .padding(16)
            }
        }
    }
}

// MARK: - Media

/// Arc's Media page (`screenshotsAndCaptures`): every capture, newest first,
/// with the easels it is on. Click to preview; the menu copies it, adds it
/// to an easel, opens its page or deletes it.
struct LibraryMediaPage: View {
    let model: BrowserViewModel
    @State private var filter: LibraryMediaFilter = .all
    @State private var query = ""
    @State private var previewRecord: CaptureRecord?
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        let items = model.libraryMediaItems(filter: filter, query: query)
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(LibraryMediaFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search media", text: $query)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button("Capture Visible Area") { captureFromLibrary(.visible) }
                    Button("Capture Full Page") { captureFromLibrary(.fullPage) }
                } label: {
                    Label("Capture", systemImage: "camera")
                }
                .fixedSize()
                .disabled(model.store.selectedTab == nil)
            }
            .padding(16)

            if items.isEmpty {
                ContentUnavailableView(
                    model.store.captures.isEmpty ? "No captures yet" : "No matches",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(model.store.captures.isEmpty
                        ? "Captures from Capture Page, Capture Visible Area and the capture tools collect here."
                        : "Try another search or filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(items) { tile($0) }
                    }
                    .padding([.horizontal, .bottom], 16)
                }
            }
        }
        .sheet(item: $previewRecord) { record in
            CapturePreviewSheet(record: record, model: model)
        }
    }

    private func captureFromLibrary(_ scope: CaptureScope) {
        model.closeLibrary()
        Task { await model.performCapture(scope: scope) }
    }

    private func tile(_ item: LibraryMediaItem) -> some View {
        let record = item.record
        return VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image = model.captureThumbnail(record.id) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(height: 110)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { previewRecord = record }

            Text(record.sourceTitle.isEmpty ? "Capture" : record.sourceTitle)
                .font(.caption.weight(.medium))
                .lineLimit(1)
            Text(subtitle(item))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contextMenu {
            Button("Preview") { previewRecord = record }
            Button("Copy") { model.copyCaptureToClipboard(record) }
            Menu("Add to Easel") {
                ForEach(model.store.allEaselRefs(), id: \.id) { ref in
                    Button(model.easelTitle(for: ref)) { model.insertCapture(record, intoEasel: ref.easelDocumentID) }
                }
                Divider()
                Button("New Easel") { model.insertCaptureIntoNewEasel(record) }
            }
            Button("Open Page") { model.openCaptureSource(record) }
                .disabled(record.sourceURL == nil)
            Divider()
            Button("Delete", role: .destructive) { model.deleteCapture(record) }
        }
    }

    private func subtitle(_ item: LibraryMediaItem) -> String {
        var parts = [item.record.scope.title, item.record.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let easel = item.easelTitles.first {
            parts.append(item.easelTitles.count > 1 ? "\(easel) +\(item.easelTitles.count - 1)" : easel)
        }
        return parts.joined(separator: " · ")
    }
}

extension CaptureScope {
    var title: String {
        switch self {
        case .visible: return "Visible"
        case .fullPage: return "Full page"
        }
    }
}

// MARK: - Easels & Notes

private struct LibraryEaselsPage: View {
    let model: BrowserViewModel
    @State private var filter: LibraryDocumentFilter = .all
    @State private var query = ""
    @State private var renaming: LibraryDocumentRow?
    @State private var renameText = ""
    @State private var deleting: LibraryDocumentRow?

    var body: some View {
        let rows = model.libraryDocumentRows(filter: filter, query: query)
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(LibraryDocumentFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search easels and notes", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button { open(model.createEasel(title: "Note", note: true)) } label: { Label("New Note", systemImage: "note.text") }
                Button { open(model.createEasel()) } label: { Label("New Easel", systemImage: "scribble.variable") }
            }
            .padding(16)

            if rows.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No easels or notes" : "No matches",
                    systemImage: "scribble.variable",
                    description: Text(query.isEmpty ? "New Note and New Easel add one to the sidebar." : "Try another search.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(rows) { row in
                    Button { model.openLibraryDocument(row.sidebarItemID) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: row.kind == .note ? "note.text" : "scribble.variable")
                                .frame(width: 20)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).lineLimit(1)
                                Text(row.summary.isEmpty ? row.spaceName : "\(row.spaceName) · \(row.summary)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(row.updatedAt, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open") { model.openLibraryDocument(row.sidebarItemID) }
                        Button("Rename…") {
                            renameText = row.title
                            renaming = row
                        }
                        Divider()
                        Button("Delete…", role: .destructive) { deleting = row }
                    }
                }
                .listStyle(.inset)
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let row = renaming { model.renameEasel(documentID: row.documentID, title: renameText) }
                renaming = nil
            }
        }
        .alert("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let row = deleting { model.deleteEaselDocument(row.documentID) }
                deleting = nil
            }
        } message: {
            Text("It is removed from the sidebar and cannot be restored.")
        }
    }

    private func open(_ ref: SidebarEaselRef?) {
        if let ref { model.openLibraryDocument(ref.id) }
    }
}
