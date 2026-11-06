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
/// it shows once the pointer has rested on the button briefly and hides when
/// it has left both the button and the stack for a while, so the pointer can
/// cross from the button to the stack. Time is passed in.
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

    public init(showDelay: TimeInterval = DownloadsQuickView.showDelay, hideDelay: TimeInterval = DownloadsQuickView.hideDelay) {
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

/// Arc's downloads quick view as measured from its recording
/// (docs/arc-recordings/2026-11-06-downloads-quick-view.md). Rows are counted
/// from the bottom, the newest file sitting on the Library button. Every
/// timing lives here; the views only apply the poses.
public enum DownloadsQuickView {
    /// Pointer on the button to the first row: 8–10 frames at 60 fps.
    public static let showDelay: TimeInterval = 0.15
    /// Arc keeps the stack about half a second after the pointer leaves.
    public static let hideDelay: TimeInterval = 0.5

    /// Row to row, in points.
    public static let rowPitch: Double = 56
    /// The bottom row starts this far below its place, so the stack unfolds
    /// out of the button rather than over it.
    public static let originDrop: Double = 14

    /// Opening: the rows' spacing eases out exponentially, half-way after one
    /// frame and settled by about 0.12 s; no overshoot.
    public static let openTimeConstant: TimeInterval = 0.024
    public static let openDuration: TimeInterval = 0.18
    /// Each row fades in over this, the bottom row first.
    public static let openFade: TimeInterval = 0.06
    public static let openStagger: TimeInterval = 0.012

    /// Closing: each row sinks toward the button and fades, bottom row first;
    /// the top row is gone after about 5 frames.
    public static let closeFade: TimeInterval = 0.035
    public static let closeSink: Double = 40
    public static let closeSinkDuration: TimeInterval = 0.06
    public static let closeStagger: TimeInterval = 0.012
    public static var closeDuration: TimeInterval {
        closeStagger * Double(RecentDownloads.limit - 1) + max(closeFade, closeSinkDuration)
    }

    /// Where a row is drawn relative to its place: `offset` points down.
    public struct Pose: Equatable, Sendable {
        public var offset: Double
        public var opacity: Double

        public static let rest = Pose(offset: 0, opacity: 1)
    }

    public enum Phase: Equatable, Sendable {
        case opening, closing
    }

    /// The pose of the row `fromBottom` places above the button, `elapsed`
    /// seconds into the phase.
    public static func pose(_ phase: Phase, fromBottom row: Int, elapsed: TimeInterval) -> Pose {
        let row = Double(max(row, 0))
        switch phase {
        case .opening:
            let fade = clamp((elapsed - row * openStagger) / openFade)
            return Pose(offset: (1 - spread(at: elapsed)) * (originDrop + row * rowPitch),
                        opacity: 1 - (1 - fade) * (1 - fade))
        case .closing:
            let local = elapsed - row * closeStagger
            let sink = clamp(local / closeSinkDuration)
            return Pose(offset: closeSink * sink * sink, opacity: 1 - clamp(local / closeFade))
        }
    }

    /// The opening's spacing, 0 (folded on the button) to 1, normalised so it
    /// lands exactly on 1 at `openDuration`.
    public static func spread(at elapsed: TimeInterval) -> Double {
        let t = min(max(elapsed, 0), openDuration)
        return (1 - exp(-t / openTimeConstant)) / (1 - exp(-openDuration / openTimeConstant))
    }

    private static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
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
