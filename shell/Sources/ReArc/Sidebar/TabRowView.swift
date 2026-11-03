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
    var isDropTarget = false
    let onSelect: () -> Void
    let onClose: () -> Void
    var onMute: (() -> Void)? = nil
    var onCloseOption: (() -> Void)? = nil
    @ViewBuilder let menu: () -> Menu

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            SiteIconView(image: favicon, token: tab.faviconToken, size: 16)
                .frame(width: 18, height: 18)

            Text(tab.displayTitle)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            if tab.isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
            }

            Spacer(minLength: 0)

            if showsAudibleIndicator {
                Button {
                    onMute?()
                } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Mute tab")
            }

            if isHovering {
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
                .help("Close Tab (⌥-click to unsplit when in a split)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isDropTarget
                ? Color.accentColor.opacity(0.22)
                : isSelected
                ? Color.primary.opacity(0.14)
                : Color.primary.opacity(isHovering ? 0.07 : 0),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu { menu() }
        .help(tab.customTitle == nil ? tab.url.absoluteString : "\(tab.title)\n\(tab.url.absoluteString)")
    }
}
