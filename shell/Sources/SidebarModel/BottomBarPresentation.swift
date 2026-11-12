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

/// Where each dot sits in the row, which is also where it takes the pointer.
/// The row reflows as Arc's does (§5.2): a hovered dot widens to an icon's
/// slot and its neighbours move aside, so a click lands on the dot drawn
/// under the pointer. The row stays centred in the bar, so x is measured from
/// its middle, which holds still while the row reflows.
public struct SpaceDotLayout: Equatable, Sendable {
    /// A 4 pt dot on a 9 pt pitch.
    public static let dotWidth = 9.0
    public static let largeDotWidth = 13.0
    public static let iconWidth = 22.0

    public let widths: [Double]

    public init(widths: [Double]) {
        self.widths = widths
    }

    /// A hovered dot takes an icon's slot even when it only draws its larger
    /// dot. Narrower, a dot handed the hover from a neighbour's icon could
    /// shrink out from under the pointer and pass it on to the next one.
    public init(appearances: [SpaceDotAppearance], hovered: Int?) {
        widths = appearances.indices.map { i in
            if i == hovered { return Self.iconWidth }
            switch appearances[i] {
            case .dot: return Self.dotWidth
            case .largeDot: return Self.largeDotWidth
            case .icon: return Self.iconWidth
            }
        }
    }

    public init(spaces: [Space], current: Space.ID, hovered: Space.ID?) {
        self.init(appearances: SpaceDots.appearances(spaces: spaces, current: current, hovered: hovered),
                  hovered: spaces.firstIndex { $0.id == hovered })
    }

    public var width: Double {
        widths.reduce(0, +)
    }

    /// The slot of the dot at `index`, from the row's middle.
    public func slot(_ index: Int) -> Range<Double> {
        let minX = widths[..<index].reduce(-width / 2, +)
        return minX ..< minX + widths[index]
    }

    /// The dot under `x` (from the row's middle), if any.
    public func index(at x: Double) -> Int? {
        var minX = -width / 2
        for (i, w) in widths.enumerated() {
            if x >= minX, x < minX + w { return i }
            minX += w
        }
        return nil
    }

    /// The space hovered once the pointer is at `x` in the row as it is drawn
    /// with `hovered`. The row then reflows around the new one with the
    /// pointer still on it, so moving along the row hands the icon from dot
    /// to dot without flicker.
    public static func hovered(at x: Double, spaces: [Space], current: Space.ID, hovered: Space.ID?) -> Space.ID? {
        SpaceDotLayout(spaces: spaces, current: current, hovered: hovered).index(at: x).map { spaces[$0].id }
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

    /// The latest finished downloads whose file is on disk, newest first
    /// (rows updated at the same moment keep their list order). One pass
    /// that keeps only `limit` rows: the bar asks on every redraw, and the
    /// list holds all of Chromium's download history.
    public static func latest(_ records: [DownloadRecord], limit: Int = RecentDownloads.limit) -> [DownloadRecord] {
        guard limit > 0 else { return [] }
        var picked: [Int] = []
        picked.reserveCapacity(limit + 1)
        for index in records.indices where records[index].hasFileOnDisk {
            let updated = records[index].updatedAt
            if picked.count == limit, updated <= records[picked[limit - 1]].updatedAt { continue }
            let place = picked.firstIndex { updated > records[$0].updatedAt } ?? picked.endIndex
            picked.insert(index, at: place)
            if picked.count > limit { picked.removeLast() }
        }
        return picked.map { records[$0] }
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

/// ReArc's intentional alternative to Arc's morphing dots.
public enum SpaceCircles {
    public static let diameter = 18.0
    public static let slotWidth = 24.0
    public static let ringDiameter = 23.0
    public static let ringWidth = 1.5

    public static func widths(count: Int) -> [Double] {
        Array(repeating: slotWidth, count: max(count, 0))
    }

    public static func initial(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }

    public static func prefersLightInk(on theme: SpaceTheme) -> Bool {
        PageColor(red: theme.red, green: theme.green, blue: theme.blue).prefersLightInk
    }

    /// The colour emoji a circle shows for an SF Symbol icon, so every space
    /// in the bar is a coloured item, as in onboarding's switcher. Matched by
    /// the symbol's first word ("heart.circle.fill" is "heart"); nil keeps the
    /// symbol, drawn in the contrasting ink.
    public static func emoji(forSymbol name: String) -> String? {
        guard Space.isSymbolName(name) else { return nil }
        let word = name.split(separator: ".").first.map(String.init) ?? name
        return symbolEmoji[word]
    }

    static let symbolEmoji: [String: String] = [
        "house": "🏠", "briefcase": "💼", "star": "⭐️", "flame": "🔥", "leaf": "🌿", "moon": "🌙",
        "globe": "🌍", "music": "🎵", "book": "📚", "books": "📚", "graduationcap": "🎓",
        "gamecontroller": "🎮", "cart": "🛒", "heart": "❤️", "bolt": "⚡️", "paintbrush": "🖌️",
        "paintpalette": "🎨", "hammer": "🔨", "wrench": "🔧", "airplane": "✈️", "camera": "📷",
        "chart": "📊", "terminal": "💻", "laptopcomputer": "💻", "desktopcomputer": "🖥️",
        "cup": "☕️", "mug": "☕️", "pawprint": "🐾", "sun": "☀️", "lightbulb": "💡",
        "magnifyingglass": "🔍", "pencil": "✏️", "highlighter": "🖍️", "cloud": "☁️", "sparkles": "✨",
        "dollarsign": "💵", "banknote": "💵", "creditcard": "💳", "bag": "🛍️", "gift": "🎁",
        "folder": "📁", "doc": "📄", "envelope": "✉️", "paperplane": "📨", "person": "👤",
        "building": "🏢", "car": "🚗", "bicycle": "🚲", "tram": "🚋", "fork": "🍴", "carrot": "🥕",
        "tv": "📺", "film": "🎬", "headphones": "🎧", "mic": "🎙️", "guitars": "🎸", "dumbbell": "🏋️",
        "figure": "🏃", "brain": "🧠", "atom": "⚛️", "flask": "🧪", "testtube": "🧪", "tree": "🌳",
        "drop": "💧", "snowflake": "❄️", "map": "🗺️", "mappin": "📍", "phone": "📞", "message": "💬",
        "bubble": "💬", "calendar": "📅", "clock": "🕒", "alarm": "⏰", "lock": "🔒", "key": "🔑",
        "shield": "🛡️", "crown": "👑", "trophy": "🏆", "flag": "🚩", "bell": "🔔", "puzzlepiece": "🧩",
        "tag": "🏷️", "bookmark": "🔖", "newspaper": "📰", "graduation": "🎓", "stethoscope": "🩺",
        "cross": "➕", "pills": "💊", "bed": "🛏️", "sofa": "🛋️", "tent": "⛺️", "mountain": "⛰️",
        "beach": "🏖️", "fish": "🐟", "bird": "🐦", "hare": "🐇", "tortoise": "🐢", "ant": "🐜",
        "ladybug": "🐞", "dice": "🎲", "theatermasks": "🎭", "scissors": "✂️",
        "ruler": "📏", "eyeglasses": "👓", "tshirt": "👕", "basket": "🧺",
    ]
}
