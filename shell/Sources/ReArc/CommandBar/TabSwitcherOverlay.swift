import SwiftUI
import SidebarModel

/// The Ctrl+Tab switcher (Arc `ModalItemSwitcher`): recent tabs, most
/// recent first, with the highlighted one picked when Control is released.
/// Tab and Shift+Tab move, Escape cancels, a click picks.
struct TabSwitcherOverlay: View {
    let session: TabSwitcherSession
    let favicon: (TabSwitcherItem) -> NSImage?
    let onSelect: (Tab.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent Tabs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                row(item, isHighlighted: index == session.index)
                    .onTapGesture { onSelect(item.id) }
            }
            Text("⌃⇥ next · ⌃⇧⇥ previous · release ⌃ to switch · esc to cancel")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
        }
        .padding(.vertical, 10)
        .frame(width: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab switcher")
    }

    private func row(_ item: TabSwitcherItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            SiteIconView(image: favicon(item), token: Tab.makeFaviconToken(for: item.url), size: 16)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .lineLimit(1)
                Text([item.spaceName, item.url.host()].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHighlighted ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }
}
