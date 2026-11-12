import SwiftUI
import SidebarModel

/// The container a page runs in, as Firefox labels its containers: the
/// container's colour, symbol and name. The one view for every place that
/// says so (address areas, split panes, the hover card, Peek, the space
/// header and switcher). It is browser chrome only, never drawn over a page,
/// so a site cannot paint a convincing one; and it is fed the engine's own
/// profile (`BrowserViewModel.containerLabel(for:tab:)`), not the space's.
struct ContainerChip: View {
    enum Style {
        /// Symbol and name, for address areas, hover cards and Peek.
        case chip
        /// A smaller chip for the mini sidebar and the auto-hidden address bar's band.
        case compact
        /// The symbol on its colour, beside a space's icon or a profile avatar.
        case badge
    }

    static let symbol = "shippingbox.fill"
    static let help = "Container: own sign-ins"

    let label: ContainerLabel
    var style: Style = .chip
    /// The toolbar's own ink where it is tinted with the page's colour.
    var ink: Color? = nil
    /// Narrower than the style's own (the mini sidebar's column).
    var maxWidth: CGFloat? = nil

    private var tint: Color {
        Color(red: label.theme.red, green: label.theme.green, blue: label.theme.blue)
    }

    var body: some View {
        Group {
            switch style {
            case .badge:
                Image(systemName: Self.symbol)
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 11, height: 11)
                    .background(Circle().fill(tint))
                    .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1))
            case .chip, .compact:
                let compact = style == .compact
                HStack(spacing: compact ? 3 : 4) {
                    Image(systemName: Self.symbol)
                        .font(.system(size: compact ? 8 : 9, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(label.name)
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .foregroundStyle(ink.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, compact ? 5 : 6)
                .frame(height: compact ? 15 : 18)
                .frame(maxWidth: maxWidth ?? (compact ? 110 : 140))
                .background(Capsule().fill(tint.opacity(0.2)))
                .overlay(Capsule().strokeBorder(tint.opacity(0.7), lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .help("\(Self.help) — \(label.name)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Container: \(label.name)")
    }
}

extension BrowserViewModel {
    /// The chip for a page: from the engine's own profile when it has one, else
    /// the profile the tab will load in. During a change of container the old
    /// engine still names the old one until the page reloads in the new.
    func containerLabel(for engine: (any WebEngine)?, tab: Tab?) -> ContainerLabel? {
        store.containerLabel(forEngineProfile: engine?.pagePrompts.profileID ?? tab.map(profileID(for:)))
    }

    /// The badge for a space's icon: its current container.
    func containerLabel(forSpace id: Space.ID) -> ContainerLabel? {
        store.container(ofSpace: id).flatMap { store.containerLabel(forEngineProfile: $0.id) }
    }
}

extension View {
    /// A container badge at the bottom-trailing corner of an icon or avatar.
    func containerBadge(_ label: ContainerLabel?, offset: CGFloat = 3) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let label {
                ContainerChip(label: label, style: .badge).offset(x: offset, y: offset)
            }
        }
    }
}
