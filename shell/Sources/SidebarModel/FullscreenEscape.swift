/// The first Escape remains the page's; a nearby second press exits fullscreen.
public struct FullscreenEscape: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case none, showHint, exit }
    /// What has keyboard focus when Escape is pressed.
    public enum Focus: Equatable, Sendable {
        case page, text, other

        /// Whether the first press goes on to the focused view. Nothing else
        /// wants it, and AppKit's `cancelOperation:` would leave full screen at once.
        public var takesFirstPress: Bool { self != .other }
    }
    private var isFullscreen = false
    private var lastPress: Double?

    public init() {}

    public mutating func setFullscreen(_ fullscreen: Bool) -> Action {
        guard fullscreen != isFullscreen else { return .none }
        isFullscreen = fullscreen
        lastPress = nil
        return fullscreen ? .showHint : .none
    }

    public mutating func press(at now: Double, consumed: Bool) -> Action {
        guard isFullscreen, !consumed else {
            lastPress = nil
            return .none
        }
        if let previous = lastPress, now >= previous, now - previous <= 1.5 {
            lastPress = nil
            return .exit
        }
        lastPress = now
        return .showHint
    }
}
