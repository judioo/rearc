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

/// A folder row: disclosure chevron, folder glyph, title. Click toggles.
struct FolderRowView<Menu: View>: View {
    let folder: SidebarFolder
    let isExpanded: Bool
    let isDropTarget: Bool
    let onToggle: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            Image(systemName: isExpanded ? "folder" : "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(folder.title)
                .font(.callout)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !isExpanded, !folder.children.isEmpty {
                Text("\(SidebarTree.tabs(folder.children).count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isDropTarget ? Color.accentColor.opacity(0.22) : Color.primary.opacity(isHovering ? 0.07 : 0),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
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
