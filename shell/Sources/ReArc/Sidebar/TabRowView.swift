import AppKit
import SwiftUI
import SidebarModel

/// A single text-row tab (pinned or today). Hover reveals the close button.
struct TabRowView: View {
    let tab: Tab
    let isSelected: Bool
    let showsAudibleIndicator: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var onMute: (() -> Void)? = nil
    var onCloseOption: (() -> Void)? = nil
    var onEditBoost: (() -> Void)? = nil

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(tab.faviconToken)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))

            Text(tab.title)
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
            isSelected
                ? Color.primary.opacity(0.14)
                : Color.primary.opacity(isHovering ? 0.07 : 0),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            if let onEditBoost, BoostScopeMatcher.urlIsEligibleForBoosts(tab.url) {
                Button {
                    onEditBoost()
                } label: {
                    Label("Edit Boost for This Site", systemImage: "paintbrush")
                }
            }
        }
    }
}
