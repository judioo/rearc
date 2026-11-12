import AppKit
import SwiftUI
import SidebarModel

/// A profile's avatar everywhere one shows: its picture cropped to the
/// circle, or its symbol or emoji on its colour (also where this Mac does
/// not have the picture).
struct ProfileAvatarView: View {
    let profile: Profile
    var diameter: CGFloat = 24
    /// Sidebar badges use the space's chrome ink, regardless of profile colour.
    var sidebarBadge: SidebarBadgeInk?
    var images: ProfileAvatarImageStore = .shared

    private var tint: Color {
        let theme = profile.themeColor
        return Color(red: theme.red, green: theme.green, blue: theme.blue)
    }

    var body: some View {
        if let picture = profile.avatar.image.flatMap({ ProfileAvatarPictures.picture($0, in: images) }) {
            Image(nsImage: picture)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(sidebarBadge.map { Color($0.glyph).opacity($0.outlineAlpha) } ?? .clear, lineWidth: 1))
        } else {
            glyph
        }
    }

    private var glyph: some View {
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

/// Decoded pictures, and avatars drawn for menus: an `NSMenuItem` takes an
/// image, not a view. Names are content hashes, so a cached picture is never stale.
@MainActor
enum ProfileAvatarPictures {
    private static var pictures: [URL: NSImage] = [:]
    private static var menuImages: [MenuImageKey: NSImage] = [:]

    private struct MenuImageKey: Hashable {
        let avatar: ProfileAvatarDescriptor
        let theme: SpaceTheme
        let hasPicture: Bool
        let diameter: CGFloat
    }

    static func picture(_ name: ProfileAvatarImageName, in images: ProfileAvatarImageStore) -> NSImage? {
        let key = images.directory.appendingPathComponent(name.rawValue)
        if let cached = pictures[key] { return cached }
        // Not cached when missing: this Mac may get the file later (the same picture chosen here).
        guard let image = images.image(named: name) else { return nil }
        let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        pictures[key] = picture
        return picture
    }

    /// The avatar as a menu item's image, on the profile's own colour.
    static func menuImage(for profile: Profile, diameter: CGFloat = 16, images: ProfileAvatarImageStore = .shared) -> NSImage {
        let hasPicture = profile.avatar.image.map { picture($0, in: images) != nil } ?? false
        let key = MenuImageKey(avatar: profile.avatar, theme: profile.themeColor, hasPicture: hasPicture, diameter: diameter)
        if let cached = menuImages[key] { return cached }
        let renderer = ImageRenderer(content: ProfileAvatarView(profile: profile, diameter: diameter, images: images))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: diameter, height: diameter))
        image.isTemplate = false
        menuImages[key] = image
        return image
    }
}

/// The profile rows of the profile menus: avatar, name, space count as the
/// item's subtitle, and the standard checkmark on the active profile (a
/// menu `Toggle`, so VoiceOver reads it as checked). In a SwiftUI menu an
/// image and two texts become `NSMenuItem.image`, `title` and `subtitle`;
/// a `Label` or `HStack` would drop the count (ProfileMenuTests).
struct ProfileMenuChoices: View {
    let store: SidebarStore
    let active: Profile.ID?
    /// A space's profile choices keep the current one checked but unavailable.
    var disablesActive = false
    /// Containers too, under their parents (Little ReArc's session menu).
    var includesContainers = false
    var images: ProfileAvatarImageStore = .shared
    let onSelect: (Profile.ID) -> Void

    var body: some View {
        ForEach(store.profileMenuRows(active: active, includingContainers: includesContainers)) { row in
            Toggle(isOn: Binding(get: { row.isActive }, set: { if $0 { onSelect(row.id) } })) {
                // A container shows its parent's avatar: it is not a profile of its own.
                let avatar = row.isContainer ? store.parentProfile(ofContainer: row.id) ?? row.profile : row.profile
                Image(nsImage: ProfileAvatarPictures.menuImage(for: avatar, images: images))
                Text(row.title)
                Text(row.spaceCountText)
            }
            .disabled(disablesActive && row.isActive)
        }
    }
}
