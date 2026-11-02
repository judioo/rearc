import Foundation

/// Whether the browser window is visible to the user (occlusion trigger input).
public enum WindowOcclusionState: Equatable, Sendable {
    case visible
    /// Window is fully covered by other windows (Arc: autoPictureInPictureOnWindowOccluded).
    case fullyOccluded
}

public enum AutoPiPHostPreference: Equatable, Codable, Sendable {
    case enabled
    case disabled
    case snoozedUntil(Date)
}

public struct AutoPiPPolicyState: Equatable, Codable, Sendable {
    public var perHost: [String: AutoPiPHostPreference]

    public init(perHost: [String: AutoPiPHostPreference] = [:]) {
        self.perHost = perHost
    }
}

public enum AutoPiPDecision: Equatable, Sendable {
    case trigger
    case suppress(reason: String)
}

/// Pure auto-PiP decision engine (Chromium handles real PiP in the future engine).
public enum AutoPiPPolicy {

    public static func effectiveHostPreference(
        host: String,
        settings: AutoPiPPolicyState,
        now: Date
    ) -> AutoPiPHostPreference {
        guard let stored = settings.perHost[host] else { return .enabled }
        switch stored {
        case .snoozedUntil(let deadline):
            return now < deadline ? .snoozedUntil(deadline) : .enabled
        case .enabled, .disabled:
            return stored
        }
    }

    public static func shouldAutoPiP(
        host: String?,
        occlusionState: WindowOcclusionState,
        now: Date,
        hasPlayingVideo: Bool,
        settings: AutoPiPPolicyState
    ) -> AutoPiPDecision {
        guard let host, !host.isEmpty else {
            return .suppress(reason: "no host")
        }
        guard hasPlayingVideo else {
            return .suppress(reason: "no playing video")
        }
        guard occlusionState == .fullyOccluded else {
            return .suppress(reason: "window not fully occluded")
        }
        switch effectiveHostPreference(host: host, settings: settings, now: now) {
        case .disabled:
            return .suppress(reason: "host disabled")
        case .snoozedUntil:
            return .suppress(reason: "host snoozed")
        case .enabled:
            return .trigger
        }
    }

    public static func snooze(host: String, from settings: AutoPiPPolicyState, now: Date, duration: TimeInterval) -> AutoPiPPolicyState {
        var copy = settings
        copy.perHost[host] = .snoozedUntil(now.addingTimeInterval(duration))
        return copy
    }
}
