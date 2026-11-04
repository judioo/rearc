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

/// Pure auto-PiP decisions: window occlusion (Arc
/// `autoPictureInPictureOnWindowOccluded`) and switching away from a tab
/// whose video plays (Arc's automatic Picture in Picture).
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

    /// Switching tabs: the tab that left the screen with a playing video goes
    /// into Picture in Picture (one at a time: the engine keeps a single PiP
    /// window), and a tab ReArc put there leaves it when it is shown again.
    public static func tabSwitchPlan(
        previouslyVisible: Set<UUID>,
        nowVisible: Set<UUID>,
        media: [UUID: WebMediaState],
        hosts: [UUID: String],
        autoEntered: Set<UUID>,
        isEnabled: Bool,
        settings: AutoPiPPolicyState,
        now: Date
    ) -> AutoPiPTabSwitchPlan {
        var plan = AutoPiPTabSwitchPlan()
        plan.exit = nowVisible.subtracting(previouslyVisible)
            .filter { autoEntered.contains($0) && media[$0]?.isPictureInPicture == true }
            .sorted { $0.uuidString < $1.uuidString }
        // A video already in PiP (that is not leaving it now) keeps the window.
        let otherInPiP = media.contains { $0.value.isPictureInPicture && !plan.exit.contains($0.key) }
        guard isEnabled, !otherInPiP else { return plan }
        let hidden = previouslyVisible.subtracting(nowVisible).sorted { $0.uuidString < $1.uuidString }
        let eligible = hidden.filter { id in
            guard let state = media[id], state.isPlaying, state.canPictureInPicture, !state.isPictureInPicture,
                  let host = hosts[id], !host.isEmpty else { return false }
            return effectiveHostPreference(host: host, settings: settings, now: now) == .enabled
        }
        // Prefer the tab you can hear (a muted autoplay preview is not what you were watching).
        plan.enter = eligible.first { media[$0]?.isAudible == true } ?? eligible.first
        return plan
    }
}

public struct AutoPiPTabSwitchPlan: Equatable, Sendable {
    /// The hidden tab to put in Picture in Picture.
    public var enter: UUID?
    /// Shown tabs to bring back from Picture in Picture.
    public var exit: [UUID] = []

    public init(enter: UUID? = nil, exit: [UUID] = []) {
        self.enter = enter
        self.exit = exit
    }
}
