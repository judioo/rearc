import AppKit
import SwiftUI
import SidebarModel

/// A site icon from the favicon cache, or the tab's letter token while none is known.
struct SiteIconView: View {
    let image: NSImage?
    let token: String
    var size: CGFloat = 16
    var customIcon: SidebarItemIcon?

    var body: some View {
        if let customIcon {
            SidebarGlyphView(icon: customIcon, fallback: "globe", size: size)
                .frame(width: size, height: size)
        } else if let image {
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

struct SidebarGlyphView: View {
    let icon: SidebarItemIcon?
    let fallback: String
    var size: CGFloat = 16

    var body: some View {
        switch icon {
        case .emoji(let text): Text(text).font(.system(size: size))
        case .sfSymbol(let name): Image(systemName: name).font(.system(size: size, weight: .medium))
        case nil: Image(systemName: fallback).font(.system(size: size, weight: .medium))
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

/// Arc's expanded outline folder: SF Symbols has no open-folder glyph.
/// Shared by plain AppKit cells and the hosted SwiftUI row.
enum SidebarFolderGlyph {
    static let open: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 17), flipped: false) { _ in
            NSColor.black.setStroke()
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 3, y: 3))
            back.line(to: NSPoint(x: 1.5, y: 13))
            back.line(to: NSPoint(x: 7, y: 13))
            back.line(to: NSPoint(x: 9, y: 11))
            back.line(to: NSPoint(x: 17, y: 11))
            back.line(to: NSPoint(x: 17, y: 9))
            back.lineWidth = 1.2
            back.lineJoinStyle = .round
            back.stroke()
            let front = NSBezierPath()
            front.move(to: NSPoint(x: 3, y: 3))
            front.line(to: NSPoint(x: 6, y: 9))
            front.line(to: NSPoint(x: 19, y: 9))
            front.line(to: NSPoint(x: 16, y: 3))
            front.close()
            front.lineWidth = 1.2
            front.lineJoinStyle = .round
            front.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// A folder row as Arc draws it (THEMES.md §4.6): an outline `folder` glyph
/// in the theme accent and a 14 pt semibold title, with no disclosure
/// chevron and no child count. Click toggles.
struct FolderRowView<Menu: View>: View {
    let folder: SidebarFolder
    let isExpanded: Bool
    let isDropTarget: Bool
    /// Set while the title is being renamed in place.
    var rename: SidebarRowRename? = nil
    let onToggle: () -> Void
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: SidebarMetrics.iconToText - 1.5) {
            Group {
                if isExpanded, folder.customIcon == nil {
                    Image(nsImage: SidebarFolderGlyph.open)
                } else {
                    SidebarGlyphView(icon: folder.customIcon, fallback: "folder", size: 17)
                }
            }
                .foregroundStyle(chrome.accent)
                .frame(width: SidebarMetrics.iconSize + 3, height: SidebarMetrics.iconSize + 3)
                .padding(.leading, -1.5)
            if let rename {
                rename.field(weight: .semibold)
            } else {
                Text(folder.title)
                    .font(.system(size: SidebarMetrics.titleSize, weight: .semibold))
                    .foregroundStyle(chrome.title)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, SidebarMetrics.iconLeading)
        .padding(.trailing, 8)
        .frame(height: SidebarMetrics.rowHeight)
        .background(
            isDropTarget ? Color.accentColor.opacity(0.22)
                : rename != nil ? chrome.rowSelected : chrome.rowHover.opacity(isHovering ? 1 : 0),
            in: RoundedRectangle(cornerRadius: rename == nil ? 8 : SidebarRowRename.cornerRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, (SidebarMetrics.rowPitch - SidebarMetrics.rowHeight) / 2)
        // Off while renaming, so clicks in the field place the caret.
        .gesture(TapGesture().onEnded {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { onToggle() }
        }, including: rename == nil ? .all : .subviews)
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .accessibilityElement(children: rename == nil ? .combine : .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}
