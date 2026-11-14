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
        /// The symbol on its colour, alone in a Settings row. On a space's icon
        /// or a profile avatar it comes with the ring: `containerMark`.
        case badge
    }

    static let symbol = "shippingbox.fill"
    static let help = "Container: own sign-ins"
    /// The badge's disc, on an 18 pt icon or avatar.
    static let badgeSize: CGFloat = 13

    let label: ContainerLabel
    var style: Style = .chip
    /// The toolbar's own ink where it is tinted with the page's colour.
    var ink: Color? = nil
    /// Narrower than the style's own (the mini sidebar's column).
    var maxWidth: CGFloat? = nil
    /// The badge's disc.
    var badgeSize = ContainerChip.badgeSize
    /// What the badge is drawn on.
    var surface: ContainerMarkSurface = .window

    @Environment(\.themeChrome) private var chrome
    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        Color(red: label.theme.red, green: label.theme.green, blue: label.theme.blue)
    }

    var body: some View {
        Group {
            switch style {
            case .badge:
                let mark = surface.ink(for: label, chrome: chrome, colorScheme: colorScheme)
                Image(systemName: Self.symbol)
                    .font(.system(size: badgeSize * 0.56, weight: .bold))
                    .foregroundStyle(Color(mark.glyph))
                    .frame(width: badgeSize, height: badgeSize)
                    .background(Circle().fill(Color(mark.tint)))
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

    /// The ring and badge for a space's icon: its current container.
    func containerLabel(forSpace id: Space.ID) -> ContainerLabel? {
        store.container(ofSpace: id).flatMap { store.containerLabel(forEngineProfile: $0.id) }
    }
}

/// What a container's ring and badge are drawn on.
enum ContainerMarkSurface {
    /// The sidebar, in its space's theme (`\.themeChrome`).
    case sidebar
    /// A window's or a popover's own background.
    case window

    @MainActor
    func ink(for label: ContainerLabel, chrome: ThemeChromeColors, colorScheme: ColorScheme) -> ContainerMarkInk {
        switch self {
        case .sidebar: ContainerMarkInks.ink(for: label, on: chrome.backdrop, lightInk: chrome.isDark)
        case .window: ContainerMarkInks.ink(for: label, on: ContainerMarkInk.window(dark: colorScheme == .dark), lightInk: colorScheme == .dark)
        }
    }
}

/// Fitted once per container colour and backdrop: a header that redraws on
/// hover, or the pager, does no gamut mapping.
@MainActor
enum ContainerMarkInks {
    private struct Key: Hashable {
        var container: SpaceColor
        var backdrop: SidebarBackdrop
        var lightInk: Bool
    }
    private static var inks: [Key: ContainerMarkInk] = [:]

    static func ink(for label: ContainerLabel, on backdrop: SidebarBackdrop, lightInk: Bool) -> ContainerMarkInk {
        let key = Key(container: label.theme.spaceColor, backdrop: backdrop, lightInk: lightInk)
        if let ink = inks[key] { return ink }
        // Dragging a theme's colour makes a backdrop per step.
        if inks.count > 256 { inks.removeAll() }
        let ink = ContainerMarkInk(container: key.container, backdrop: backdrop, lightInk: lightInk)
        inks[key] = ink
        return ink
    }
}

/// The ring a container draws around its space's icon or its profile's
/// avatar, by the ring's own size.
enum ContainerRing: Equatable {
    /// Around an avatar or a space's dot.
    case circle(CGFloat)
    /// Around a space's icon, which has no shape of its own.
    case roundedSquare(CGFloat)
    /// No ring, only the badge at the corner of a disc this wide: the
    /// switcher's coloured circles, where a ring is the current space's.
    case badgeOnly(CGFloat)

    var size: CGFloat {
        switch self {
        case let .circle(size), let .roundedSquare(size), let .badgeOnly(size): size
        }
    }

    var lineWidth: CGFloat { size >= 20 ? 1.5 : 1.25 }
    var cornerRadius: CGFloat { size * 0.29 }

    /// The badge's centre from the ring's: on the ring's bottom-trailing
    /// corner, so it covers the ring there and little of what is inside. On
    /// an avatar a little further in: the header's is 6 pt from the sidebar's edge.
    var badgeCentre: CGFloat {
        switch self {
        case .circle: (size - lineWidth) / 2 * 0.65
        case .roundedSquare: size / 2 - cornerRadius + (cornerRadius - lineWidth / 2) * 0.7071
        case .badgeOnly: size / 2 * 0.7071
        }
    }
}

extension View {
    /// A container's mark on its space's icon or its profile's avatar: the
    /// ring around it in the container's colour, and the badge (nil for none)
    /// on the ring's corner. Nothing at all without a container.
    func containerMark(_ label: ContainerLabel?, ring: ContainerRing, badge: CGFloat? = ContainerChip.badgeSize,
                       surface: ContainerMarkSurface = .sidebar) -> some View {
        modifier(ContainerMark(label: label, ring: ring, badge: badge, surface: surface))
    }
}

private struct ContainerMark: ViewModifier {
    let label: ContainerLabel?
    let ring: ContainerRing
    let badge: CGFloat?
    let surface: ContainerMarkSurface

    @Environment(\.themeChrome) private var chrome
    @Environment(\.colorScheme) private var colorScheme

    /// The clear band between the badge and what it sits on.
    private static let badgeGap: CGFloat = 1.5

    func body(content: Content) -> some View {
        if let label {
            let tint = Color(surface.ink(for: label, chrome: chrome, colorScheme: colorScheme).tint)
            // The ring and the badge reach past the icon's own frame.
            let reach = ring.size
            let marked = content
                .overlay {
                    Group {
                        switch ring {
                        case .circle:
                            Circle().strokeBorder(tint, lineWidth: ring.lineWidth)
                        case .roundedSquare:
                            RoundedRectangle(cornerRadius: ring.cornerRadius, style: .continuous).strokeBorder(tint, lineWidth: ring.lineWidth)
                        case .badgeOnly:
                            EmptyView()
                        }
                    }
                    .frame(width: ring.size, height: ring.size)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                // The badge is cut out of the icon and the ring, so its edge
                // is whatever the sidebar is there, on any theme.
                .overlay {
                    if let badge {
                        Circle()
                            .frame(width: badge + 2 * Self.badgeGap, height: badge + 2 * Self.badgeGap)
                            .offset(x: ring.badgeCentre, y: ring.badgeCentre)
                            .blendMode(.destinationOut)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(reach)
                .compositingGroup()
                .padding(-reach)
                .overlay {
                    if let badge {
                        ContainerChip(label: label, style: .badge, badgeSize: badge, surface: surface)
                            .offset(x: ring.badgeCentre, y: ring.badgeCentre)
                    } else {
                        // The ring alone still says what it is.
                        Color.clear
                            .frame(width: ring.size, height: ring.size)
                            .allowsHitTesting(false)
                            .accessibilityElement()
                            .accessibilityLabel("Container: \(label.name)")
                    }
                }
            // The badge has the tooltip; without one the ring does.
            if badge == nil {
                marked.help("\(ContainerChip.help) — \(label.name)")
            } else {
                marked
            }
        } else {
            content
        }
    }
}
