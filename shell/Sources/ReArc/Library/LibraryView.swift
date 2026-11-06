import AppKit
import SwiftUI
import SidebarModel

/// Arc's Library in the sidebar (arc-recordings/2026-11-06-library-in-sidebar.md):
/// a rail of pages, centred, with the ← bar under it, and the page's
/// column beside it at full height under its search field. The page stays
/// in the main frame. Spaces has no column: it fills the page area beside
/// the rail (`LibrarySpacesPage`). ←, Esc or showing any item leaves.
struct LibraryView: View {
    let model: BrowserViewModel
    let window: SidebarWindowID?
    let section: LibrarySection
    @Binding var draggedItemID: UUID?
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                // The traffic lights' row.
                Color.clear.frame(height: SidebarToolbarView.rowHeight)
                // Arc's 100 pt pitch needs 600 pt; a short window packs the rail.
                ViewThatFits(in: .vertical) {
                    rail(chipHeight: CGFloat(LibrarySidebarLayout.chipHeight),
                         spacing: CGFloat(LibrarySidebarLayout.railPitch - LibrarySidebarLayout.chipHeight))
                    rail(chipHeight: 62, spacing: 2)
                }
                .frame(maxHeight: .infinity)
                BottomBarView(model: model, draggedItemID: $draggedItemID)
            }
            .frame(width: LibrarySidebarLayout.railWidth)

            if !section.coversPage {
                LibraryColumn(model: model, window: window, section: section)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(alignment: .leading) { LibraryColumnEdge(dark: chrome.isWindowDark) }
            }
        }
        .frame(maxHeight: .infinity)
        // Takes every click, so none reaches the hidden sidebar under it.
        .contentShape(Rectangle())
    }

    private func rail(chipHeight: CGFloat, spacing: CGFloat) -> some View {
        VStack(spacing: spacing) {
            ForEach(LibrarySection.railOrder, id: \.self) { page in
                LibraryRailButton(section: page, isSelected: page == section, height: chipHeight) {
                    model.openLibrary(page, in: window)
                }
            }
        }
    }
}

/// A rail page: glyph over an 11 pt label, on a chip while selected.
private struct LibraryRailButton: View {
    let section: LibrarySection
    let isSelected: Bool
    let height: CGFloat
    let action: () -> Void
    @Environment(\.themeChrome) private var chrome
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 18))
                    .foregroundStyle(chrome.glyph)
                    .frame(height: 24)
                Text(section.railTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: LibrarySidebarLayout.chipWidth, height: height)
            .background(fill, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(section.railTitle)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Black at about 10 % on the light theme (211 on 233), half that on hover.
    private var fill: Color {
        let ink = chrome.isWindowDark ? Color.white : Color.black
        return isSelected ? ink.opacity(0.1) : isHovering ? ink.opacity(0.05) : .clear
    }
}

/// The column's leading edge: a 1 pt line (black 10 % on light) and a
/// shadow that fades out over about 30 pt into the column.
private struct LibraryColumnEdge: View {
    let dark: Bool

    var body: some View {
        HStack(spacing: 0) {
            Color.black.opacity(dark ? 0.35 : 0.1).frame(width: 1)
            LinearGradient(colors: [.black.opacity(dark ? 0.15 : 0.045), .black.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 30)
        }
        .allowsHitTesting(false)
    }
}

/// The page in the sidebar's column. Each page puts its own search field at
/// the top, centred on the traffic lights' row.
private struct LibraryColumn: View {
    let model: BrowserViewModel
    let window: SidebarWindowID?
    let section: LibrarySection

    var body: some View {
        Group {
            switch section {
            case .spaces: EmptyView()
            case .downloads: LibraryDownloadsPage(model: model)
            case .media: LibraryMediaPage(model: model)
            case .easels: LibraryEaselsPage(model: model)
            case .archive: ArchiveView(model: model)
            case .boosts: BoostLibraryView(model: model)
            }
        }
        .id(section)
    }
}

/// Arc's column search field: 36 pt tall, black 6 % with a magnifier.
struct LibrarySearchField: View {
    let prompt: String
    @Binding var text: String
    @Environment(\.themeChrome) private var chrome

    static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(chrome.secondaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background((chrome.isWindowDark ? Color.white : Color.black).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The column's top row: the search field and an optional trailing control.
struct LibraryColumnHeader<Trailing: View>: View {
    let prompt: String
    @Binding var text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            LibrarySearchField(prompt: prompt, text: $text)
            trailing
        }
        .padding(.horizontal, LibraryColumnMetrics.inset)
        .padding(.top, SidebarToolbarView.rowHeight / 2 - LibrarySearchField.height / 2)
        .padding(.bottom, 8)
    }
}

extension LibraryColumnHeader where Trailing == EmptyView {
    init(prompt: String, text: Binding<String>) {
        self.init(prompt: prompt, text: text) { EmptyView() }
    }
}

enum LibraryColumnMetrics {
    /// The search field sits 9 pt in from the column's edges.
    static let inset: CGFloat = 9
}

// MARK: - Spaces

/// Every space beside the rail, over the page area.
struct LibrarySpacesPage: View {
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
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryColumnHeader(prompt: LibrarySection.downloads.searchPrompt ?? "", text: $query)
            DownloadsTrayView(downloads: model.downloads, embedded: true, query: query)
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
    /// Two tiles across the column, as Arc's.
    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    var body: some View {
        let items = model.libraryMediaItems(filter: filter, query: query)
        VStack(spacing: 0) {
            LibraryColumnHeader(prompt: LibrarySection.media.searchPrompt ?? "", text: $query)
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(LibraryMediaFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Menu {
                    Button("Capture Visible Area") { captureFromLibrary(.visible) }
                    Button("Capture Full Page") { captureFromLibrary(.fullPage) }
                } label: {
                    Image(systemName: "camera")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Capture")
                .accessibilityLabel("Capture")
                .disabled(model.store.selectedTab == nil)
            }
            .padding(.horizontal, LibraryColumnMetrics.inset)
            .padding(.bottom, 10)

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
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items) { tile($0) }
                    }
                    .padding([.horizontal, .bottom], LibraryColumnMetrics.inset)
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
            .frame(height: 96)
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
        var parts = [item.record.kindTitle, item.record.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let easel = item.easelTitles.first {
            parts.append(item.easelTitles.count > 1 ? "\(easel) +\(item.easelTitles.count - 1)" : easel)
        }
        return parts.joined(separator: " · ")
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
            LibraryColumnHeader(prompt: LibrarySection.easels.searchPrompt ?? "", text: $query)
            HStack {
                Picker("Show", selection: $filter) {
                    ForEach(LibraryDocumentFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Button { open(model.createEasel(title: "Note", note: true)) } label: { Image(systemName: "note.text") }
                    .buttonStyle(.borderless)
                    .help("New Note")
                    .accessibilityLabel("New Note")
                Button { open(model.createEasel()) } label: { Image(systemName: "scribble.variable") }
                    .buttonStyle(.borderless)
                    .help("New Easel")
                    .accessibilityLabel("New Easel")
            }
            .padding(.horizontal, LibraryColumnMetrics.inset)
            .padding(.bottom, 10)

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
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
