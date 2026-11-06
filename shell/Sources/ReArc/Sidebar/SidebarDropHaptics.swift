import AppKit

/// Settings › Advanced "Haptic feedback when reordering tabs" (Arc
/// `hapticFeedbackWhenReordering`, MEDIA §4). On by default, as in Arc.
enum ReorderHapticsPreference {
    static let key = "ReArcReorderHaptics"
    static let defaultValue = true

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

/// Which sidebar drag moments get a haptic: alignment when a drag crosses
/// into a new drop position, level change when the drop lands. Pure, so
/// tests drive it without a trackpad.
struct ReorderHapticsTracker {
    enum Feedback: Equatable { case alignment, levelChange }

    private var last: SidebarDropState?

    /// A drop position the sidebar now shows; nil between targets. Only a
    /// position different from the last one ticks: leaving a row and
    /// coming back to the same slot, or redrawing it, stays quiet.
    mutating func positionChanged(to state: SidebarDropState?) -> Feedback? {
        guard let state, state != last else { return nil }
        last = state
        return .alignment
    }

    /// A target without a row (the end of a section): always a new position.
    mutating func enteredSectionEnd() -> Feedback? {
        last = nil
        return .alignment
    }

    /// The drop reordered something: one firmer tick, and the next drag starts fresh.
    mutating func dropped(moved: Bool) -> Feedback? {
        last = nil
        return moved ? .levelChange : nil
    }

    mutating func reset() { last = nil }
}

/// Plays the tracker's feedback on the trackpad (Force Touch trackpads only;
/// elsewhere `NSHapticFeedbackManager` does nothing). Off with the preference.
@MainActor
enum SidebarDropHaptics {
    private static var tracker = ReorderHapticsTracker()

    static func dragBegan() { tracker.reset() }

    static func positionChanged(to state: SidebarDropState?) {
        play(tracker.positionChanged(to: state))
    }

    static func enteredSectionEnd() {
        play(tracker.enteredSectionEnd())
    }

    static func dropped(moved: Bool) {
        play(tracker.dropped(moved: moved))
    }

    private static func play(_ feedback: ReorderHapticsTracker.Feedback?) {
        guard let feedback, ReorderHapticsPreference.isEnabled() else { return }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = feedback == .alignment ? .alignment : .levelChange
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
