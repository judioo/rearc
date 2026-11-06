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

/// What a bottom-bar hover chip says: a name and the shortcut that does the
/// same, when one is bound (Arc's "View Library" chip, §5.1). A space dot's
/// chip names its space; the dot itself only ever shows the icon.
public struct BarChipLabel: Equatable, Sendable {
    public var title: String
    public var shortcut: String?

    public init(_ title: String, shortcut: String? = nil) {
        self.title = title
        self.shortcut = shortcut
    }

    /// "Work ⌃2".
    public var text: String {
        shortcut.map { "\(title) \($0)" } ?? title
    }

    /// The space at `index` in its profile: its name and Go to Space N
    /// (⌃1…⌃9, or the user's own chord). Spaces past the ninth have no key.
    public static func space(named name: String, at index: Int, overrides: ShortcutOverrides = ShortcutOverrides()) -> BarChipLabel {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortcut = (0 ..< 9).contains(index) ? overrides.chord(for: "goToSpace\(index + 1)")?.display : nil
        return BarChipLabel(trimmed.isEmpty ? "Space \(index + 1)" : trimmed, shortcut: shortcut)
    }

    public static func library(overrides: ShortcutOverrides = ShortcutOverrides()) -> BarChipLabel {
        BarChipLabel("View Library", shortcut: overrides.chord(for: "viewLibrary")?.display)
    }

    /// The Library's ← (the recording shows no shortcut; Esc also leaves).
    public static let exitLibrary = BarChipLabel("Exit Library")
    /// The + menu; no key opens it.
    public static let new = BarChipLabel("New")
}

/// When a hover chip shows: once the pointer has rested `showDelay` on its
/// target, or at once when a chip in the same group was showing a moment ago,
/// so moving along the dots hands the label from dot to dot. Leaving hides
/// it at once. Time is passed in.
public struct HoverChipTiming<ID: Hashable & Sendable>: Equatable, Sendable {
    public var showDelay: TimeInterval
    /// How long after a chip hides the next target still shows its own at once.
    public var handOff: TimeInterval
    public private(set) var hovered: ID?
    public private(set) var shown: ID?
    /// When the pending chip is due.
    public private(set) var deadline: TimeInterval?
    private var hiddenAt: TimeInterval?

    public init(showDelay: TimeInterval = 0.5, handOff: TimeInterval = 0.3) {
        self.showDelay = showDelay
        self.handOff = handOff
    }

    public mutating func setHovering(_ hovering: Bool, _ id: ID, at now: TimeInterval) {
        if hovering {
            hovered = id
            if shown != nil || hiddenAt.map({ now - $0 <= handOff }) == true {
                shown = id
                deadline = nil
            } else {
                deadline = now + showDelay
            }
        } else {
            // A late exit from the previous target leaves the new one alone.
            guard hovered == id else { return }
            hovered = nil
            if shown != nil { hiddenAt = now }
            shown = nil
            deadline = nil
        }
    }

    /// Shows the chip that is due by `now`. Returns whether `shown` changed.
    @discardableResult
    public mutating func advance(to now: TimeInterval) -> Bool {
        guard let due = deadline, now >= due, let hovered else { return false }
        deadline = nil
        shown = hovered
        return true
    }

    /// Hides at once, as a click does; the next target waits the full delay.
    public mutating func dismiss() {
        shown = nil
        deadline = nil
        hiddenAt = nil
    }
}

public enum BarChipPlacement {
    /// The leading x of a chip `width` wide centred on `anchorMidX`, slid to
    /// stay `margin` inside `0…containerWidth` (a dot at the row's end must
    /// not push its chip off the sidebar). A chip wider than the room keeps
    /// its leading margin.
    public static func centredX(anchorMidX: Double, width: Double, containerWidth: Double, margin: Double = 8) -> Double {
        let x = min(anchorMidX - width / 2, containerWidth - margin - width)
        return max(x, margin)
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
