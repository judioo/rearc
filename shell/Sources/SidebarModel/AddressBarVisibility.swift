import Foundation

/// Settings › Advanced. Fixed toolbars remain the default for existing installs.
public enum AutoHideAddressBarPreference {
    public static let key = "rearc.autoHideAddressBar"
    public static let defaultValue = false

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// The mini sidebar (⇧⌘S) always puts the address in the page's toolbar. The first time
/// someone switches to it with auto-hide off, a toast says the toolbar can hide itself.
public enum MiniSidebarAddressBarTip {
    public static let shownKey = "rearc.miniSidebarAutoHideTipShown"
    public static let message = "The address bar can hide itself"

    /// True once: when auto-hide is off and the tip was never shown. Records the showing.
    public static func takeIfDue(in defaults: UserDefaults) -> Bool {
        guard !AutoHideAddressBarPreference.isEnabled(in: defaults), !defaults.bool(forKey: shownKey) else { return false }
        defaults.set(true, forKey: shownKey)
        return true
    }
}

/// One pane's transient toolbar state. The caller supplies time so deadline
/// cancellation and focus/hover handoffs can be tested without real timers.
public struct AddressBarVisibility: Equatable {
    public enum Pointer: Equatable {
        case outside, topEdge, toolbar
    }

    public static let hideDelay: TimeInterval = 0.35
    /// How long the bar shows by itself after the page's origin changes, so the trusted
    /// origin is seen without hovering (security RC-0.1.0-564 S-02).
    public static let originRevealDuration: TimeInterval = 3
    public private(set) var isRevealed: Bool
    public private(set) var hideDeadline: TimeInterval?
    /// A timed reveal: the bar does not hide before this, whatever the pointer does.
    public private(set) var revealedUntil: TimeInterval?
    public private(set) var autoHideEnabled: Bool
    public private(set) var hasKeyboardFocus = false
    public private(set) var pointer: Pointer = .outside

    public init(autoHideEnabled: Bool = AutoHideAddressBarPreference.defaultValue) {
        self.autoHideEnabled = autoHideEnabled
        isRevealed = !autoHideEnabled
    }

    public mutating func update(autoHideEnabled: Bool, pointer: Pointer,
                                hasKeyboardFocus: Bool, now: TimeInterval) {
        self.autoHideEnabled = autoHideEnabled
        self.pointer = pointer
        self.hasKeyboardFocus = hasKeyboardFocus
        if !autoHideEnabled || hasKeyboardFocus || pointer == .topEdge {
            isRevealed = true
            hideDeadline = nil
        } else if isRevealed && pointer == .toolbar {
            hideDeadline = nil
        } else if isRevealed && hideDeadline == nil {
            hideDeadline = max(now + Self.hideDelay, revealedUntil ?? 0)
        }
    }

    /// Shows the bar now and keeps it for `duration` (a main-frame navigation to another
    /// origin). Hover and focus still extend it as usual.
    public mutating func reveal(for duration: TimeInterval, now: TimeInterval) {
        guard autoHideEnabled else { return }
        let until = max(revealedUntil ?? 0, now + duration)
        revealedUntil = until
        isRevealed = true
        if !hasKeyboardFocus, pointer != .topEdge, pointer != .toolbar {
            hideDeadline = max(hideDeadline ?? 0, until)
        }
    }

    public mutating func hideIfDue(at now: TimeInterval) {
        guard autoHideEnabled, !hasKeyboardFocus, pointer == .outside,
              let hideDeadline, now >= hideDeadline else { return }
        if let revealedUntil, now < revealedUntil {
            self.hideDeadline = revealedUntil
            return
        }
        isRevealed = false
        self.hideDeadline = nil
        revealedUntil = nil
    }
}

/// Screen coordinates (origin at bottom left), shared by both engine paths.
/// The first row also reveals through the card inset/titlebar up to the
/// window or fullscreen screen edge; lower stacked panes use their own edge.
public enum AddressBarPointerRegion {
    public static func position(_ point: CGPoint, pane: CGRect, topEdge: Double,
                                toolbarHeight: Double = 32) -> AddressBarVisibility.Pointer {
        guard pane.width > 0, pane.height > 0,
              point.x >= pane.minX, point.x < pane.maxX else { return .outside }
        if point.y >= pane.maxY - 4, point.y <= max(pane.maxY, topEdge) {
            return .topEdge
        }
        if point.y >= max(pane.minY, pane.maxY - toolbarHeight), point.y < pane.maxY {
            return .toolbar
        }
        return .outside
    }
}
