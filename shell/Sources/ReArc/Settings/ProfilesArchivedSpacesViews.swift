import SidebarModel
import SwiftUI

// Settings › Profiles › Archived Spaces (docs/FEATURE-SPECS/ARCHIVE-SPACE.md):
// a profile's archived spaces, newest first, each with Restore and Delete….

/// The profile's archived spaces, or a line saying where they come from.
struct ArchivedSpacesGroup: View {
    @Bindable var model: BrowserViewModel
    let profileID: Profile.ID
    @State private var deleting: Space.ID?

    static let emptyNote = "Archive a space from its menu to put it away here, exactly as it was."

    var body: some View {
        let archived = model.store.archivedSpaces(in: profileID)
        SettingsHeader(title: "Archived Spaces")
        SettingsGroup {
            if archived.isEmpty {
                SettingsLabeledRow(label: "No archived spaces", detail: Self.emptyNote) { EmptyView() }
            } else {
                ForEach(archived) { space in
                    ArchivedSpaceRow(space: space, pinnedTabs: pinnedTabCount(space.id)) {
                        model.restoreArchivedSpace(space.id)
                    } delete: {
                        deleting = space.id
                    }
                }
            }
        }
        .alert(deleteText.title, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(deleteText.action, role: .destructive) {
                if let id = deleting { model.deleteArchivedSpace(id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(deleteText.message)
        }
    }

    private func pinnedTabCount(_ id: Space.ID) -> Int {
        SidebarTree.tabs(model.store.content(for: id).pinned).count
    }

    private var deleteText: (title: String, message: String, action: String) {
        guard let id = deleting else { return ("", "", "") }
        let content = model.store.content(for: id)
        let count = SidebarTree.tabs(content.pinned + content.today).count
        return ("Delete “\(model.store.space(withID: id)?.name ?? "Space")”?",
                "The space and its \(count) pinned and Today tab\(count == 1 ? "" : "s") are deleted. This cannot be undone.",
                "Delete Space")
    }
}

/// One archived space: its icon on its colour, name, when it was archived
/// and its pinned tabs, then Restore and Delete….
struct ArchivedSpaceRow: View {
    let space: Space
    let pinnedTabs: Int
    let restore: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ArchivedSpaceTile(space: space)
            // Two short notes: the column beside two buttons is narrow.
            VStack(alignment: .leading, spacing: 1) {
                Text(space.name).font(.system(size: 13)).lineLimit(1)
                ForEach(Self.notes(archivedAt: space.archivedAt, pinnedTabs: pinnedTabs), id: \.self) { note in
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsColors.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Button("Restore", action: restore)
                .buttonStyle(SettingsButtonStyle())
                .help("Put “\(space.name)” back in your Spaces")
            Button("Delete…", role: .destructive, action: delete)
                .buttonStyle(SettingsButtonStyle())
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 6)
        .frame(minHeight: SettingsMetrics.iconRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(([space.name] + Self.notes(archivedAt: space.archivedAt, pinnedTabs: pinnedTabs)).joined(separator: ", "))
    }

    /// "Archived 14 Nov" (the year only when it is not this one), then "3 pinned tabs".
    static func notes(archivedAt: Date?, pinnedTabs: Int, now: Date = Date()) -> [String] {
        let tabs = pinnedTabs == 1 ? "1 pinned tab" : "\(pinnedTabs.formatted()) pinned tabs"
        guard let archivedAt else { return [tabs] }
        let sameYear = Calendar.current.isDate(archivedAt, equalTo: now, toGranularity: .year)
        let date = sameYear ? archivedAt.formatted(.dateTime.day().month(.abbreviated))
            : archivedAt.formatted(date: .abbreviated, time: .omitted)
        return ["Archived \(date)", tabs]
    }
}

/// The space's icon on a 24 pt tile of its base colour, the glyph dark or
/// light for contrast.
private struct ArchivedSpaceTile: View {
    let space: Space

    var body: some View {
        let theme = space.theme
        let light = 0.299 * theme.red + 0.587 * theme.green + 0.114 * theme.blue > 0.6
        SpaceIconView(iconName: space.iconName, size: 12)
            .foregroundStyle(light ? Color.black.opacity(0.7) : Color.white)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 24 * 0.24, style: .continuous).fill(Color(theme).gradient))
            .accessibilityHidden(true)
    }
}
