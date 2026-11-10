import SwiftUI
import SidebarModel

struct ProfileAvatarView: View {
    let profile: Profile
    var diameter: CGFloat = 24
    /// Sidebar badges use the space's chrome ink, regardless of profile colour.
    var sidebarBadge: SidebarBadgeInk?

    private var tint: Color {
        let theme = profile.themeColor
        return Color(red: theme.red, green: theme.green, blue: theme.blue)
    }

    var body: some View {
        Group {
            switch profile.avatar.kind {
            case .sfSymbol(let name):
                Image(systemName: name)
                    .font(.system(size: diameter * 0.42, weight: .semibold))
            case .emoji(let text):
                Text(text)
                    .font(.system(size: diameter * 0.48))
            }
        }
        .foregroundStyle(sidebarBadge.map { Color($0.glyph) } ?? .white)
        .frame(width: diameter, height: diameter)
        // A neutral disc keeps the glyph readable on every theme, even when
        // the profile's colour matches the space's (SidebarBadgeInkTests).
        .background(Circle().fill(sidebarBadge.map { Color($0.disc).opacity($0.discAlpha) } ?? tint.opacity(0.85)))
        .overlay(Circle().strokeBorder(sidebarBadge.map { Color($0.glyph).opacity($0.outlineAlpha) } ?? .clear, lineWidth: 1))
    }
}
