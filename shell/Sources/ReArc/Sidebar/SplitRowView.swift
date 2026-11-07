import AppKit
import SwiftUI
import SidebarModel

/// Sidebar row for a split, stacked in place like Arc's (ARC-RECORDING
/// §8): one row on the tab pitch. Unnamed, its panes sit side by side as
/// chips; named or given an icon, it reads "<icon> <name>" like a tab, and
/// double-click renames it there.
struct SplitRowView<Menu: View>: View {
    let split: SplitViewItem
    let isSelected: Bool
    let isDropTarget: Bool
    let focusedTabID: Tab.ID
    let favicon: (Tab) -> NSImage?
    let showsAudibleIndicator: (Tab.ID) -> Bool
    let onMutePane: (Tab.ID) -> Void
    let onSelectSplit: () -> Void
    let onSelectPane: (Tab.ID) -> Void
    let onCloseSplit: () -> Void
    let onClosePane: (_ optionClick: Bool, Tab.ID) -> Void
    /// The inline rename is open (from double-click or the menu's Rename…).
    @Binding var isRenaming: Bool
    let onRename: (String) -> Void
    var paneRename: (Tab.ID) -> SidebarRowRename? = { _ in nil }
    var onRenamePane: (Tab.ID) -> Void = { _ in }
    /// The split's menu; a chip passes its pane for the pane's own items.
    @ViewBuilder let menu: (Tab.ID?) -> Menu

    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Group {
            if (split.showsAsNamedRow && !split.tabs.contains(where: { paneRename($0.id) != nil })) || isRenaming {
                namedRow
            } else {
                chips
            }
        }
        .padding(.trailing, 8)
        .frame(height: SidebarMetrics.rowHeight)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            if isDropTarget {
                shape.fill(Color.accentColor.opacity(0.22))
            } else if isSelected {
                shape.fill(chrome.rowSelected)
                    .shadow(color: .black.opacity(chrome.isDark ? 0.3 : 0.08), radius: 1.5, y: 0.5)
            } else if isHovering {
                shape.fill(chrome.rowHover)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, (SidebarMetrics.rowPitch - SidebarMetrics.rowHeight) / 2)
        .onHover { isHovering = $0 }
        .contextMenu { menu(nil) }
    }

    // MARK: Named

    private var namedRow: some View {
        HStack(spacing: SidebarMetrics.iconToText) {
            SidebarGlyphView(icon: split.customIcon, fallback: split.orientation == .horizontal ? "square.split.2x1" : "square.split.1x2", size: 13)
                .foregroundStyle(chrome.secondaryText)
                .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)
            if isRenaming {
                SplitTitleField(initial: split.displayTitle, onCommit: { text in
                    isRenaming = false
                    onRename(text)
                }, onCancel: { isRenaming = false })
            } else {
                Text(split.displayTitle)
                    .font(.system(size: SidebarMetrics.titleSize))
                    .foregroundStyle(chrome.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if let audible = split.tabs.first(where: { showsAudibleIndicator($0.id) }) {
                Button { onMutePane(audible.id) } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Mute tab")
            }
            if isHovering, !isRenaming {
                closeButton(help: "Close Split View", size: 16, action: onCloseSplit)
            }
        }
        .padding(.leading, SidebarMetrics.iconLeading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelectSplit)
        .simultaneousGesture(TapGesture(count: 2).onEnded { isRenaming = true })
        .help("\(split.displayTitle)\nDouble-click to rename")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(split.displayTitle), split view of \(split.tabs.count) tabs")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Chips

    /// Selected, every chip gets a pill; otherwise thin rules part them.
    private var chips: some View {
        HStack(spacing: isSelected ? 4 : 0) {
            ForEach(Array(split.tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0, !isSelected {
                    Rectangle()
                        .fill(chrome.secondaryText.opacity(0.35))
                        .frame(width: 1, height: 14)
                }
                SplitPaneChip(
                    tab: tab,
                    favicon: favicon(tab),
                    showsTitle: split.showsPaneTitles,
                    isFilled: isSelected,
                    isFocused: isSelected && tab.id == focusedTabID,
                    rowHovered: isHovering,
                    showsAudibleIndicator: showsAudibleIndicator(tab.id),
                    onSelect: { onSelectPane(tab.id) },
                    onClose: { option in onClosePane(option, tab.id) },
                    onMute: { onMutePane(tab.id) },
                    rename: paneRename(tab.id),
                    onRename: { onRenamePane(tab.id) }
                )
                .contextMenu { menu(tab.id) }
            }
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split view of \(split.tabs.count) tabs")
    }

    private func closeButton(help: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One pane in an unnamed split row: favicon and title (favicon only at
/// four panes), ✕ on hover.
private struct SplitPaneChip: View {
    let tab: Tab
    let favicon: NSImage?
    let showsTitle: Bool
    let isFilled: Bool
    let isFocused: Bool
    let rowHovered: Bool
    let showsAudibleIndicator: Bool
    let onSelect: () -> Void
    let onClose: (_ optionClick: Bool) -> Void
    let onMute: () -> Void
    var rename: SidebarRowRename? = nil
    var onRename: () -> Void = {}

    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    /// Arc shows every chip's ✕ while the row is hovered; four favicon-only
    /// chips have no room, so only the hovered one does.
    private var showsClose: Bool { rename != nil || isHovering || (rowHovered && showsTitle) }

    var body: some View {
        HStack(spacing: 6) {
            SiteIconView(image: favicon, token: tab.faviconToken, size: 14, customIcon: tab.customIcon)
                .frame(width: 16, height: 16)
            if let rename {
                rename.field()
            } else if showsTitle {
                Text(tab.displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(chrome.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if showsAudibleIndicator {
                Button(action: onMute) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Mute tab")
            }
            if showsClose {
                Button {
                    onClose(NSEvent.modifierFlags.contains(.option))
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.plain)
                .help("Close pane (⌥-click to unsplit)")
                .accessibilityLabel("Close pane")
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: rename == nil ? nil : 100, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
        .background(
            Color.primary.opacity(isFilled ? (isFocused ? 0.11 : 0.06) : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .gesture(TapGesture().onEnded { onSelect() }, including: rename == nil ? .all : .subviews)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if rename == nil { onRename() } })
        .onHover { isHovering = $0 }
        .help("\(tab.displayTitle)\n\(tab.url.absoluteString)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.displayTitle)
        .accessibilityAddTraits(isFocused ? [.isButton, .isSelected] : .isButton)
    }
}

/// The in-place rename: the current name selected, Return or clicking
/// away commits, Escape cancels.
private struct SplitTitleField: View {
    let initial: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(initial, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: SidebarMetrics.titleSize))
            .focused($focused)
            .onSubmit { finish(commit: true) }
            .onExitCommand { finish(commit: false) }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { finish(commit: true) }
            }
            .onAppear {
                text = initial
                DispatchQueue.main.async { focused = true }
            }
    }

    private func finish(commit: Bool) {
        guard !finished else { return }
        finished = true
        commit ? onCommit(text) : onCancel()
    }
}
