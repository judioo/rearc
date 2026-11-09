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

/// Arc's folder glyphs, two-tone in the theme accent: a tinted tab over a
/// pale body, closed or (while expanded) open with its front flap tilted
/// forward. A folder holding a tab with a live page shows three dots on
/// its body, as in the 2026-11-09 Arc recording. SF Symbols has no open
/// folder, so all four are drawn here as template images (alpha is the tone).
/// Shared by plain AppKit cells and the hosted SwiftUI row.
enum SidebarFolderGlyph {
    static func image(isOpen: Bool, holdsOpenTabs: Bool) -> NSImage {
        switch (isOpen, holdsOpenTabs) {
        case (false, false): closed
        case (false, true): closedWithTabs
        case (true, false): open
        case (true, true): openWithTabs
        }
    }

    private static let closed = make(isOpen: false, dots: false)
    private static let closedWithTabs = make(isOpen: false, dots: true)
    private static let open = make(isOpen: true, dots: false)
    private static let openWithTabs = make(isOpen: true, dots: true)

    private static let tabTone: CGFloat = 0.45
    private static let bodyTone: CGFloat = 0.12
    private static let lineWidth: CGFloat = 1.3

    private static func make(isOpen: Bool, dots: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 17), flipped: false) { _ in
            // The back: body outline with the tab at its top left.
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 4.2, y: 2.5))
            back.line(to: NSPoint(x: 3.8, y: 2.5))
            back.curve(to: NSPoint(x: 1.8, y: 4.5), controlPoint1: NSPoint(x: 2.7, y: 2.5), controlPoint2: NSPoint(x: 1.8, y: 3.4))
            back.line(to: NSPoint(x: 1.8, y: 12.8))
            back.curve(to: NSPoint(x: 3.3, y: 14.3), controlPoint1: NSPoint(x: 1.8, y: 13.6), controlPoint2: NSPoint(x: 2.5, y: 14.3))
            back.line(to: NSPoint(x: 7.0, y: 14.3))
            back.curve(to: NSPoint(x: 8.2, y: 13.7), controlPoint1: NSPoint(x: 7.5, y: 14.3), controlPoint2: NSPoint(x: 7.9, y: 14.1))
            back.line(to: NSPoint(x: 9.0, y: 12.6))
            back.line(to: NSPoint(x: 16.4, y: 12.6))
            back.curve(to: NSPoint(x: 18.2, y: 10.8), controlPoint1: NSPoint(x: 17.4, y: 12.6), controlPoint2: NSPoint(x: 18.2, y: 11.8))
            if isOpen {
                back.line(to: NSPoint(x: 18.2, y: 8.8))
            } else {
                back.line(to: NSPoint(x: 18.2, y: 4.5))
                back.curve(to: NSPoint(x: 16.2, y: 2.5), controlPoint1: NSPoint(x: 18.2, y: 3.4), controlPoint2: NSPoint(x: 17.3, y: 2.5))
                back.close()
            }
            back.lineWidth = lineWidth
            back.lineJoinStyle = .round
            back.lineCapStyle = .round

            // The tab tone fills above the body's top edge (closed) or the
            // whole back (open, where the front flap covers its lower part).
            NSGraphicsContext.saveGraphicsState()
            back.addClip()
            NSColor.black.withAlphaComponent(tabTone).setFill()
            NSRect(x: 0, y: isOpen ? 0 : 10.6, width: 20, height: 17).fill()
            if !isOpen {
                NSColor.black.withAlphaComponent(bodyTone).setFill()
                NSRect(x: 0, y: 0, width: 20, height: 10.6).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.setStroke()
            back.stroke()

            if isOpen {
                // The front flap, tilted forward over the back.
                let front = NSBezierPath()
                front.move(to: NSPoint(x: 3.9, y: 2.5))
                front.line(to: NSPoint(x: 6.0, y: 8.6))
                front.curve(to: NSPoint(x: 7.2, y: 9.5), controlPoint1: NSPoint(x: 6.2, y: 9.1), controlPoint2: NSPoint(x: 6.7, y: 9.5))
                front.line(to: NSPoint(x: 18.6, y: 9.5))
                front.curve(to: NSPoint(x: 19.3, y: 8.6), controlPoint1: NSPoint(x: 19.1, y: 9.5), controlPoint2: NSPoint(x: 19.4, y: 9.1))
                front.line(to: NSPoint(x: 17.4, y: 3.4))
                front.curve(to: NSPoint(x: 16.2, y: 2.5), controlPoint1: NSPoint(x: 17.2, y: 2.9), controlPoint2: NSPoint(x: 16.7, y: 2.5))
                front.close()
                front.lineWidth = lineWidth
                front.lineJoinStyle = .round
                // Clear what the flap hides, then give it the body tone.
                NSGraphicsContext.current?.compositingOperation = .clear
                front.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.withAlphaComponent(bodyTone).setFill()
                front.fill()
                front.stroke()
            }

            if dots {
                let centerY: CGFloat = isOpen ? 6.0 : 6.6
                let centerX: CGFloat = isOpen ? 11.6 : 10.0
                NSColor.black.setFill()
                for offset in [-3.2, 0, 3.2] as [CGFloat] {
                    NSBezierPath(ovalIn: NSRect(x: centerX + offset - 1.05, y: centerY - 1.05, width: 2.1, height: 2.1)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// A folder row as Arc draws it (THEMES.md §4.6): a folder glyph in the
/// theme accent, open while expanded, and a 14 pt semibold title, with no
/// disclosure chevron and no child count. Click toggles. While it holds a
/// live tab the glyph shows dots and hover offers Arc's "Close This Folder".
struct FolderRowView<Menu: View>: View {
    let folder: SidebarFolder
    let isExpanded: Bool
    let isDropTarget: Bool
    /// A tab inside (nested folders included) has a page open.
    var holdsOpenTabs = false
    /// Unloads the folder's open tabs, keeping them pinned.
    var onCloseFolder: (() -> Void)? = nil
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
                if folder.customIcon == nil {
                    Image(nsImage: SidebarFolderGlyph.image(isOpen: isExpanded, holdsOpenTabs: holdsOpenTabs))
                        .renderingMode(.template)
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
            if isHovering, rename == nil, holdsOpenTabs, let onCloseFolder {
                Button(action: onCloseFolder) {
                    Image(systemName: "minus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(chrome.title.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close This Folder")
                .accessibilityLabel("Close This Folder")
            }
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
            let duration = isExpanded ? SidebarListController.collapseDuration : SidebarListController.expandDuration
            withAnimation(reduceMotion ? nil : .easeInOut(duration: duration)) { onToggle() }
        }, including: rename == nil ? .all : .subviews)
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .accessibilityElement(children: rename == nil ? .combine : .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }
}
