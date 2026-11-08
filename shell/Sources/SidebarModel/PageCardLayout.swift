/// Native fullscreen keeps the toolbar and split gaps, but removes the outer card.
/// HTML fullscreen additionally hides the toolbar and split gaps at their call sites.
public struct PageCardLayout: Equatable, Sendable {
    public let inset: Double
    public let radius: Double
    public let showsDecoration: Bool
    public let splitGap: Double

    public init(isNativeFullscreen: Bool, isPageFullscreen: Bool) {
        let edgeToEdge = isNativeFullscreen || isPageFullscreen
        inset = edgeToEdge ? 0 : 10
        radius = edgeToEdge ? 0 : 8
        showsDecoration = !edgeToEdge
        splitGap = isPageFullscreen ? 5 : 10
    }

    public func topInset(showsToolbar: Bool, trafficLightsInSidebar: Bool, trafficLightClearance: Double) -> Double {
        showsDecoration && !showsToolbar && !trafficLightsInSidebar ? trafficLightClearance : inset
    }
}
