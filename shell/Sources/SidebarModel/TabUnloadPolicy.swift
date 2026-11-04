import Foundation

/// How long a loaded tab may sit unseen before the shell unloads it
/// (Chromium: a preserving `ReArcTabDiscard`, ABI 1.25; WebKit: its engine is
/// dropped). The tab stays in the sidebar and reloads when it is shown.
public enum TabUnloadThreshold: String, CaseIterable, Codable, Sendable {
    case never
    case thirtyMinutes
    case oneHour
    case fourHours
    case twelveHours

    public static let defaultsKey = "ReArcTabUnloadThreshold"
    public static let `default`: TabUnloadThreshold = .fourHours

    public var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .twelveHours: return 12 * 60 * 60
        }
    }

    public var title: String {
        switch self {
        case .never: return "Never"
        case .thirtyMinutes: return "After 30 Minutes"
        case .oneHour: return "After 1 Hour"
        case .fourHours: return "After 4 Hours"
        case .twelveHours: return "After 12 Hours"
        }
    }

    public static func load(from defaults: UserDefaults) -> TabUnloadThreshold {
        defaults.string(forKey: defaultsKey).flatMap(TabUnloadThreshold.init(rawValue:)) ?? .default
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// One tab with a live engine, as the unload check sees it.
public struct TabUnloadCandidate: Equatable, Sendable {
    public var tabID: Tab.ID
    /// Last time the tab was shown (selected, or a pane of the shown split).
    public var lastActive: Date
    /// On screen in some window now.
    public var isVisible: Bool
    /// Playing sound, or capturing: unloading would cut it off.
    public var isAudible: Bool
    /// Already unloaded (discarded) or loading.
    public var isUnloaded: Bool
    /// A dialog or prompt is waiting on the page.
    public var hasPendingPrompt: Bool

    public init(tabID: Tab.ID, lastActive: Date, isVisible: Bool = false, isAudible: Bool = false,
                isUnloaded: Bool = false, hasPendingPrompt: Bool = false) {
        self.tabID = tabID
        self.lastActive = lastActive
        self.isVisible = isVisible
        self.isAudible = isAudible
        self.isUnloaded = isUnloaded
        self.hasPendingPrompt = hasPendingPrompt
    }
}

public enum TabUnloadPolicy {
    /// Tabs to unload now, least recently shown first.
    public static func tabsToUnload(_ candidates: [TabUnloadCandidate], threshold: TabUnloadThreshold, now: Date) -> [Tab.ID] {
        guard let interval = threshold.interval else { return [] }
        return candidates
            .filter { !$0.isVisible && !$0.isAudible && !$0.isUnloaded && !$0.hasPendingPrompt }
            .filter { now.timeIntervalSince($0.lastActive) >= interval }
            .sorted { $0.lastActive < $1.lastActive }
            .map(\.tabID)
    }
}
