import SwiftUI
import SidebarModel

/// Kept over the page rather than replacing it: folding Spaces uncovers
/// the same engine view and scroll position.
struct LibrarySpacesOverlay: View {
    let model: BrowserViewModel
    let window: SidebarWindowID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = model.librarySection(in: window) == .spaces
        let edge: Edge = model.sidebarPlacement.side == .left ? .leading : .trailing
        ZStack {
            if shown {
                LibrarySpacesPage(model: model, window: window)
                    .transition(reduceMotion ? .opacity : .move(edge: edge))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(shown)
        .animation(.timingCurve(0.23, 1, 0.32, 1, duration: LibrarySpacesMotion.duration(opening: shown)), value: shown)
    }
}

/// Each space is a full-height themed column, with its sidebar and the
/// existing space menu. Horizontal scrolling keeps large libraries usable.
struct LibrarySpacesPage: View {
    let model: BrowserViewModel
    let window: SidebarWindowID?

    var body: some View {
        GeometryReader { geometry in
            let groups = LibrarySpaces.groups(in: model.store)
            let count = groups.reduce(0) { $0 + $1.rows.count }
            let width = max(180, min(280, geometry.size.width / CGFloat(max(count, 1))))
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(groups, id: \.profile.id) { group in
                        ForEach(group.rows) { row in
                            LibrarySpaceColumn(model: model, row: row, window: window)
                                .frame(width: width)
                        }
                        Button { model.beginSpaceCreation(profileID: group.profile.id) } label: {
                            Label("New Space…", systemImage: "plus")
                                .frame(width: 140, height: geometry.size.height)
                                .background(.regularMaterial)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
    }
}

private struct LibrarySpaceColumn: View {
    let model: BrowserViewModel
    let row: LibrarySpaceRow
    let window: SidebarWindowID?
    @State private var collapsed: Set<UUID> = []
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let space = row.space
        let content = model.store.content(for: space.id)
        let palette = SpaceThemePalette(theme: space.theme,
                                        darkAppearance: space.theme.appearance.isDark(systemDark: SystemAppearance.isDark(colorScheme)))
        let foreground: Color = palette.prefersLightForeground ? .white : .black.opacity(0.8)
        VStack(alignment: .leading, spacing: 0) {
            Button { model.openLibrarySpace(space.id) } label: {
                HStack(spacing: 8) {
                    SpaceIconView(iconName: space.iconName, size: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(space.name).font(.headline).lineLimit(1)
                        Text(row.profileName).font(.caption).opacity(0.7)
                    }
                    Spacer(minLength: 0)
                    if model.space(in: window).id == space.id { Image(systemName: "checkmark") }
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    entries(model.store.favorites(in: space.profileID).map(SidebarEntry.tab))
                    if !content.pinned.isEmpty {
                        sectionTitle("Pinned")
                        entries(content.pinned)
                    }
                    sectionTitle("Today")
                    entries(content.today)
                }
                .padding(.horizontal, 10)
            }
        }
        .foregroundStyle(foreground)
        .frame(maxHeight: .infinity)
        .background(SpaceThemeFill(palette: palette))
        .overlay(alignment: .trailing) { Rectangle().fill(foreground.opacity(0.12)).frame(width: 1) }
        .contextMenu { SpaceContextMenu(model: model, space: space) }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).opacity(0.6).padding(.vertical, 10).padding(.leading, 8)
    }

    private func entries(_ entries: [SidebarEntry]) -> some View {
        let expanded = Set(SidebarTree.folders(entries).map(\.id)).subtracting(collapsed)
        return ForEach(SidebarRowItem.rows(entries, expanded: expanded, selected: nil)) { item in
            Button { open(item.entry) } label: {
                HStack(spacing: 8) {
                    glyph(item.entry).frame(width: 18, height: 18)
                    Text(title(item.entry)).font(.system(size: 14)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(item.depth) * 12 + 8)
                .padding(.trailing, 8)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func glyph(_ entry: SidebarEntry) -> some View {
        if case .tab(let tab) = entry {
            SiteIconView(image: model.favicon(for: tab), token: tab.faviconToken, customIcon: tab.customIcon)
        } else {
            SidebarGlyphView(icon: entry.customIcon, fallback: entry.isFolder ? "folder" : "square.split.2x1")
        }
    }

    private func title(_ entry: SidebarEntry) -> String {
        switch entry {
        case .tab(let tab): return tab.displayTitle
        case .folder(let folder): return folder.title
        case .split(let split): return split.displayTitle
        case .easel(let ref): return model.easelTitle(for: ref)
        }
    }

    private func open(_ entry: SidebarEntry) {
        if case .folder = entry {
            if !collapsed.insert(entry.id).inserted { collapsed.remove(entry.id) }
            return
        }
        model.selectSpace(row.id)
        switch entry {
        case .tab(let tab): model.selectTab(tab.id)
        case .split(let split): model.selectSplit(split.id)
        case .easel(let ref): model.openLibraryDocument(ref.id)
        case .folder: break
        }
    }
}
