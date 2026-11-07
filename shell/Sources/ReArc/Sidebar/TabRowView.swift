import AppKit
import SwiftUI
import SidebarModel

/// A single text-row tab (pinned, today or in a folder). Hover reveals the
/// close button; the context menu comes from the caller (`SidebarItemMenu`).
struct TabRowView<Menu: View>: View {
    let tab: Tab
    let favicon: NSImage?
    let isSelected: Bool
    let showsAudibleIndicator: Bool
    var isMuted = false
    var isDropTarget = false
    /// Unloaded (discarded) until shown again: the icon dims.
    var isUnloaded = false
    /// Its video plays in the Picture in Picture window; the badge brings it back.
    var isInPictureInPicture = false
    /// Loading (a progress ring on the icon) or crashed (a warning glyph).
    var activity: TabActivity = .idle
    let onSelect: () -> Void
    let onClose: () -> Void
    var onMute: (() -> Void)? = nil
    var onPictureInPicture: (() -> Void)? = nil
    var onCloseOption: (() -> Void)? = nil
    /// Set for a pinned tab away from its saved URL: shows "Back to pinned URL".
    var onReset: (() -> Void)? = nil
    /// A second line under the title (Arc's "3 Recent"), 11 pt grey.
    var subtitle: String? = nil
    /// What the ✕ does here: it names the button and its tooltip.
    var closeKind: TabCloseKind = .archive
    /// Double-click: the rename the context menu's Rename… starts.
    var onRename: (() -> Void)? = nil
    /// Set while the title is being renamed in place.
    var rename: SidebarRowRename? = nil
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    /// The tooltip over the icon and title (the icon has none of its own,
    /// to keep one region there). The hover buttons keep their own: a
    /// `.help` on the whole row hid the ✕'s "Archive this tab ⌘W".
    private var tooltip: String {
        let url = tab.customTitle == nil ? tab.url.absoluteString : "\(tab.title)\n\(tab.url.absoluteString)"
        return isUnloaded ? "Unloaded — reloads when you open it\n\(url)" : url
    }

    var body: some View {
        // Arc (THEMES.md §4.6): 16 pt favicon at x 18, 14 pt title at x 45,
        // on a 41 pt pitch; selected and hovered rows use the theme's
        // near-white roles.
        HStack(spacing: SidebarMetrics.iconToText) {
            HStack(spacing: SidebarMetrics.iconToText) {
                TabActivityIcon(activity: activity) {
                    SiteIconView(image: favicon, token: tab.faviconToken, size: SidebarMetrics.iconSize, customIcon: tab.customIcon)
                        .saturation(isUnloaded ? 0 : 1)
                        .opacity(isUnloaded ? 0.4 : 1)
                }
                .frame(width: SidebarMetrics.iconSize, height: SidebarMetrics.iconSize)

                VStack(alignment: .leading, spacing: 0) {
                    if let rename {
                        rename.field()
                    } else {
                        Text(tab.displayTitle)
                            .font(.system(size: SidebarMetrics.titleSize))
                            .foregroundStyle(chrome.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let subtitle, rename == nil {
                        Text(subtitle)
                            .font(.system(size: SidebarMetrics.subtitleSize))
                            .foregroundStyle(chrome.secondaryText)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.3), value: subtitle)

                if tab.isUnread {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .help("New activity since you last looked")
                        .accessibilityLabel("Unread")
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .help(tooltip)

            if isInPictureInPicture {
                Button {
                    onPictureInPicture?()
                } label: {
                    Image(systemName: "pip.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Playing in Picture in Picture — click to bring the video back")
                .accessibilityLabel("Picture in Picture")
            }

            if showsAudibleIndicator {
                Button {
                    onMute?()
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isMuted ? "Unmute tab" : "Mute tab")
            }

            if isHovering, let onReset {
                Button(action: onReset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Back to the pinned URL (\(tab.savedURL?.host() ?? "saved page"))")
            }

            // Arc keeps ✕ up while the row is being renamed, pointer or not.
            if isHovering || rename != nil {
                Button {
                    if NSEvent.modifierFlags.contains(.option), let onCloseOption {
                        onCloseOption()
                    } else {
                        onClose()
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("\(closeKind.buttonLabel)  ⌘W\n⌥-click to unsplit when in a split")
                .accessibilityLabel(closeKind.buttonLabel)
            }
        }
        .padding(.leading, SidebarMetrics.iconLeading)
        .padding(.trailing, 8)
        .frame(height: SidebarMetrics.rowHeight)
        .background {
            let shape = RoundedRectangle(cornerRadius: rename == nil ? 8 : SidebarRowRename.cornerRadius, style: .continuous)
            if isDropTarget {
                shape.fill(Color.accentColor.opacity(0.22))
            } else if isSelected || rename != nil {
                shape.fill(chrome.rowSelected)
                    .shadow(color: .black.opacity(chrome.isDark ? 0.3 : 0.08), radius: 1.5, y: 0.5)
            } else if isHovering {
                shape.fill(chrome.rowHover)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, (SidebarMetrics.rowPitch - SidebarMetrics.rowHeight) / 2)
        // Off while renaming, so clicks in the field place the caret.
        .gesture(TapGesture().onEnded(onSelect), including: rename == nil ? .all : .subviews)
        // Simultaneous, so a single click selects at once rather than
        // waiting to see whether a second follows.
        .simultaneousGesture(TapGesture(count: 2).onEnded { onRename?() }, including: rename == nil ? .all : .subviews)
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        // One accessibility element per row: its title and badges read as
        // one label, the hover buttons become its actions. A rename field
        // stays its own element.
        .accessibilityElement(children: rename == nil ? .combine : .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
