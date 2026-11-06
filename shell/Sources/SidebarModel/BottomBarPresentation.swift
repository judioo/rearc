import Foundation

// The sidebar bottom bar's wave-34 decisions, kept pure so they can be tested
// (ARC-RECORDING-2026-11-06.md §5).

extension Space {
    /// The icon a new space gets; Arc draws such a space as a dot, never an icon.
    public static let defaultIconName = "circle.fill"

    /// Whether the space has an icon of its own to show in the bottom bar.
    public var hasIcon: Bool {
        !iconName.isEmpty && iconName != Space.defaultIconName
    }
}

/// What one space shows in the bottom bar's dot row.
public enum SpaceDotAppearance: Equatable, Sendable {
    /// The 4 pt grey dot of every other space.
    case dot
    /// The current space's 8 pt dot.
    case largeDot
    case icon
}

public enum SpaceDots {
    /// Only one icon shows at a time, and the hovered dot wins (§5.2): a
    /// hovered space shows its icon and the current space falls back to its
    /// larger dot. At rest the current space shows its icon if it has one.
    public static func appearance(isCurrent: Bool, isHovered: Bool, hasIcon: Bool, anyHovered: Bool) -> SpaceDotAppearance {
        if isHovered { return hasIcon ? .icon : .largeDot }
        guard isCurrent else { return .dot }
        return hasIcon && !anyHovered ? .icon : .largeDot
    }

    /// Every space's appearance, in order.
    public static func appearances(spaces: [Space], current: Space.ID, hovered: Space.ID?) -> [SpaceDotAppearance] {
        let anyHovered = hovered.map { id in spaces.contains { $0.id == id } } ?? false
        return spaces.map {
            appearance(isCurrent: $0.id == current, isHovered: $0.id == hovered, hasIcon: $0.hasIcon, anyHovered: anyHovered)
        }
    }
}

/// Hover-to-reveal timing for the Library button's downloads stack (§5.1):
/// it shows once the pointer has rested about 0.5 s and hides when it has
/// left both the button and the stack. A short grace on leaving lets the
/// pointer cross from the button to the stack. Time is passed in.
public struct HoverReveal: Equatable, Sendable {
    public enum Region: Hashable, Sendable {
        case trigger, content
    }

    public var showDelay: TimeInterval
    public var hideDelay: TimeInterval
    public private(set) var isShown = false
    private var hovered: Set<Region> = []
    /// When the pending change (show or hide) is due.
    public private(set) var deadline: TimeInterval?

    public init(showDelay: TimeInterval = 0.5, hideDelay: TimeInterval = 0.15) {
        self.showDelay = showDelay
        self.hideDelay = hideDelay
    }

    public mutating func setHovering(_ hovering: Bool, _ region: Region, at now: TimeInterval) {
        let wasHovered = !hovered.isEmpty
        if hovering { hovered.insert(region) } else { hovered.remove(region) }
        let isHovered = !hovered.isEmpty
        if isHovered, !wasHovered {
            // Only resting on the button opens it; the stack is not there yet.
            deadline = isShown ? nil : (region == .trigger ? now + showDelay : nil)
        } else if !isHovered, wasHovered {
            deadline = isShown ? now + hideDelay : nil
        }
    }

    /// Applies a change that is due by `now`. Returns whether `isShown` changed.
    @discardableResult
    public mutating func advance(to now: TimeInterval) -> Bool {
        guard let due = deadline, now >= due else { return false }
        deadline = nil
        let shown = !hovered.isEmpty
        defer { isShown = shown }
        return shown != isShown
    }

    /// Hides at once, as a click on the button does.
    public mutating func dismiss() {
        isShown = false
        deadline = nil
    }
}

public enum RecentDownloads {
    /// Arc's hover stack shows four rows.
    public static let limit = 4

    /// The latest finished downloads whose file is on disk, newest first.
    public static func latest(_ records: [DownloadRecord], limit: Int = RecentDownloads.limit) -> [DownloadRecord] {
        Array(records.filter(\.hasFileOnDisk).sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// "24 minutes ago", or "Just now" in the first minute.
    public static func relativeTime(_ date: Date, now: Date, locale: Locale = .current) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// An update the updater found. Nothing sets it yet: the bottom bar's update
/// slot stays hidden until an updater (Sparkle) exists (§4 item 7).
public struct AvailableUpdate: Equatable, Sendable {
    public var version: String

    public init(version: String) {
        self.version = version
    }

    /// Arc's "New Arc Version Available" pill, in ReArc's words.
    public static let title = "New Version Available"
}
