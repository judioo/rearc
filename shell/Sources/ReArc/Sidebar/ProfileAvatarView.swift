import SwiftUI
import SidebarModel

struct ProfileAvatarView: View {
    let profile: Profile
    var diameter: CGFloat = 24
    /// Sidebar badges follow the space's legible glyph role, regardless of profile colour.
    var sidebarGlyph: Color?
    var sidebarIsDark = false

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
        .foregroundStyle(sidebarGlyph ?? .white)
        .frame(width: diameter, height: diameter)
        // A neutral backing keeps the glyph readable even when a custom
        // theme has exactly the same colour as the sidebar's glyph role.
        .background(Circle().fill(sidebarGlyph == nil ? tint.opacity(0.85)
                                  : sidebarIsDark ? Color.black.opacity(0.75) : Color.white.opacity(0.88)))
        .overlay(Circle().strokeBorder(sidebarGlyph?.opacity(0.65) ?? .clear, lineWidth: 1))
    }
}
