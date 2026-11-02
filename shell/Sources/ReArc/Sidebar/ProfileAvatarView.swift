import SwiftUI
import SidebarModel

struct ProfileAvatarView: View {
    let profile: Profile
    var diameter: CGFloat = 24

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
        .foregroundStyle(.white)
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(tint.opacity(0.85)))
    }
}
