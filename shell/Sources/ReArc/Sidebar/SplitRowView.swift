import AppKit
import SwiftUI
import SidebarModel

/// Sidebar cell for a split item with child tab rows.
struct SplitRowView: View {
    let model: BrowserViewModel
    let split: SplitViewItem
    let isSelected: Bool
    let focusedTabID: Tab.ID
    let themeColor: Color
    let favicon: (Tab) -> NSImage?
    let showsAudibleIndicator: (Tab.ID) -> Bool
    let onMutePane: (Tab.ID) -> Void
    let onSelectSplit: () -> Void
    let onSelectPane: (Tab.ID) -> Void
    let onCloseSplit: () -> Void
    let onClosePane: (_ optionClick: Bool, Tab.ID) -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                SidebarGlyphView(icon: split.customIcon, fallback: split.orientation == .horizontal ? "square.split.2x1" : "square.split.1x2", size: 11)
                    .foregroundStyle(.secondary)
                Text("Split View")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(split.tabs.count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                Spacer(minLength: 0)
                if isHovering {
                    Button(action: onCloseSplit) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close Split View")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.primary.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture(perform: onSelectSplit)
            .onHover { isHovering = $0 }

            ForEach(split.tabs) { tab in
                SplitPaneRowView(
                    tab: tab,
                    favicon: favicon(tab),
                    isFocused: isSelected && tab.id == focusedTabID,
                    accent: themeColor,
                    showsAudibleIndicator: showsAudibleIndicator(tab.id),
                    onSelect: { onSelectPane(tab.id) },
                    onClose: { option in onClosePane(option, tab.id) },
                    onMute: { onMutePane(tab.id) }
                )
                .padding(.leading, 12)
                .contextMenu { ItemIconMenu(model: model, itemID: tab.id) }
            }
        }
    }
}

private struct SplitPaneRowView: View {
    let tab: Tab
    let favicon: NSImage?
    let isFocused: Bool
    let accent: Color
    let showsAudibleIndicator: Bool
    let onSelect: () -> Void
    let onClose: (_ optionClick: Bool) -> Void
    let onMute: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            SiteIconView(image: favicon, token: tab.faviconToken, size: 14, customIcon: tab.customIcon)
                .frame(width: 16, height: 16)
            Text(tab.displayTitle)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 0)
            if showsAudibleIndicator {
                Button(action: onMute) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Mute tab")
            }
            if isHovering {
                Button {
                    onClose(NSEvent.modifierFlags.contains(.option))
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close pane (⌥-click to unsplit)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            isFocused ? accent.opacity(0.22) : Color.primary.opacity(isHovering ? 0.06 : 0),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? accent.opacity(0.55) : .clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }
}
