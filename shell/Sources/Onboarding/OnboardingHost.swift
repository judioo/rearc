import AppKit

/// What really came over when "Bring them over" was pressed.
public struct OnboardingImportOutcome: Equatable, Sendable {
    public var totals: ImportStats
    /// Spaces the import created, in order, each with the host's id.
    public var spaces: [SpaceSeed]

    public init(totals: ImportStats, spaces: [SpaceSeed]) { self.totals = totals; self.spaces = spaces }
}

/// A space as Act 3 left it.
public struct OnboardingSpace: Equatable, Sendable {
    /// Set for a space that already exists in the host (imported); nil for a new one.
    public var hostID: String?
    public var name: String
    public var icon: String
    public var colour: RGBA

    public init(hostID: String?, name: String, icon: String, colour: RGBA) {
        self.hostID = hostID; self.name = name; self.icon = icon; self.colour = colour
    }
}

/// Everything the person chose, handed over as Act 4 begins.
public struct OnboardingResult: Equatable, Sendable {
    public var name: String
    public var colour: RGBA
    /// In sidebar order.
    public var spaces: [OnboardingSpace]
    /// Imported spaces the person removed in Act 3.
    public var removedHostIDs: [String]

    public init(name: String, colour: RGBA, spaces: [OnboardingSpace], removedHostIDs: [String]) {
        self.name = name; self.colour = colour; self.spaces = spaces; self.removedHostIDs = removedHostIDs
    }

    /// From the acts' logs: Act 1's name and colour, Act 3's spaces.
    public static func from(act1: Act1Log?, act3: Act3Log?, at t: Double) -> OnboardingResult {
        let name = act1?.submitted?.name ?? ""
        let colour = act1?.picked.map { ProfilePalette.colours[$0.index].rgba } ?? MarkPalette.sun
        guard let act3 else { return OnboardingResult(name: name, colour: colour, spaces: [], removedHostIDs: []) }
        let all = act3.state(at: t).spaces
        let hostID = { (id: Int) in id < act3.seeds.count ? act3.seeds[id].hostID : nil }
        let spaces = all.filter { $0.removed == nil }.map {
            OnboardingSpace(hostID: hostID($0.id), name: $0.name.isEmpty ? "New space" : $0.name, icon: $0.icon, colour: $0.colour)
        }
        let removed = all.filter { $0.removed != nil }.compactMap { hostID($0.id) }
        return OnboardingResult(name: name, colour: colour, spaces: spaces, removedHostIDs: removed)
    }
}

/// The browser the onboarding runs in. Without one (the `sunrise`
/// prototype), Act 2 scans on its own and nothing is applied.
@MainActor
public protocol OnboardingHost: AnyObject {
    /// The categories this host can really import; Act 2 offers only these.
    var importCategories: [ImportCategory] { get }
    /// Other browsers' profiles, and the browsers it can only name (blocked
    /// by macOS, or empty), found off the main thread. Called again when
    /// ReArc comes back from System Settings.
    func discoverSources(_ done: @escaping (BrowserScan) -> Void)
    /// Whether `relaunchForAccess` can start ReArc again (a bundled app).
    var canRelaunch: Bool { get }
    /// Quit and start again: macOS applies some privacy switches only to a
    /// new launch. The onboarding resumes by itself.
    func relaunchForAccess()
    /// Bring them over: import now, while the light flows in.
    func bring(_ sources: [ImportSource], categories: [ImportCategory], done: @escaping (OnboardingImportOutcome) -> Void)
    /// Act 4 begins: name the main profile, colour it, shape the spaces.
    func apply(_ result: OnboardingResult)
    /// The drawn window is complete: put the real one at `frame` (screen
    /// coordinates), ordered just below `overlay`, which then fades away.
    func revealBrowser(in frame: NSRect, below overlay: NSWindow)
    /// The overlay is gone.
    func onboardingFinished()
    /// "Onboard later": the overlay closed before the end, nothing applied.
    func onboardingDeferred()
}

public extension OnboardingHost {
    func onboardingDeferred() { onboardingFinished() }
    var canRelaunch: Bool { false }
    func relaunchForAccess() {}
}
