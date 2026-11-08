/// The first Escape remains the page's; a nearby second press exits fullscreen.
public struct FullscreenEscape: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case none, showHint, exit }
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
