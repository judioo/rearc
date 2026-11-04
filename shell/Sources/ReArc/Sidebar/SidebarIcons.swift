import AppKit
import SwiftUI
import SidebarModel

/// A site icon from the favicon cache, or the tab's letter token while none is known.
struct SiteIconView: View {
    let image: NSImage?
    let token: String
    var size: CGFloat = 16

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            Text(token)
                .font(.system(size: size * 0.6, weight: .bold))
                .frame(width: size + 2, height: size + 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: size * 0.3))
        }
    }
}

/// A space's icon: an SF Symbol, or an emoji/letter drawn as text.
struct SpaceIconView: View {
    let iconName: String
    var size: CGFloat = 13

    var body: some View {
        if Space.isSymbolName(iconName) {
            Image(systemName: iconName)
                .font(.system(size: size))
        } else {
            Text(iconName)
                .font(.system(size: size + 1))
        }
    }
}

/// A folder row as Arc draws it (THEMES.md §4.6): an outline `folder` glyph
/// in the theme accent and a 14 pt semibold title, with no disclosure
/// chevron and no child count. Click toggles.
struct FolderRowView<Menu: View>: View {
    let folder: SidebarFolder
    let isExpanded: Bool
    let isDropTarget: Bool
    let onToggle: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        HStack(spacing: SidebarMetrics.iconToText - 1.5) {
            Image(systemName: "folder")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(chrome.accent)
                .frame(width: SidebarMetrics.iconSize + 3, height: SidebarMetrics.iconSize + 3)
                .padding(.leading, -1.5)
            Text(folder.title)
                .font(.system(size: SidebarMetrics.titleSize, weight: .semibold))
                .foregroundStyle(chrome.title)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, SidebarMetrics.iconLeading)
        .padding(.trailing, 8)
        .frame(height: SidebarMetrics.rowHeight)
        .background(
            isDropTarget ? Color.accentColor.opacity(0.22) : chrome.rowHover.opacity(isHovering ? 1 : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, (SidebarMetrics.rowPitch - SidebarMetrics.rowHeight) / 2)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { onToggle() }
        }
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}
