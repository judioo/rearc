import Foundation

/// Settings › Max (docs/FEATURE-SPECS/MAX.md): the features of Arc's Max tab
/// that work by rules alone. They run on this Mac and send nothing; an
/// assistant shortcut only opens that assistant's own site. Each feature
/// reads its switch here, not from the tab, so the rows can move elsewhere.
public enum MaxFeature: String, CaseIterable, Codable, Sendable {
    case tidyTabs, instantLinks, tidyTabTitles, tidyDownloads, assistants

    public var title: String {
        switch self {
        case .tidyTabs: return "Tidy Tabs"
        case .instantLinks: return "Instant Links"
        case .tidyTabTitles: return "Tidy Tab Titles"
        case .tidyDownloads: return "Tidy Downloads"
        case .assistants: return "Assistants in the Command Bar"
        }
    }

    public var detail: String {
        switch self {
        case .tidyTabs:
            return "With more than \(TidyTabs.threshold) Today tabs, the broom by the divider files them into folders by site and topic, at the end of Pinned. Undo puts them back."
        case .instantLinks:
            return "Shift + Return on a search in the command bar opens the top result. Separate searches with commas to open up to \(InstantLinks.maximumQueries) at once."
        case .tidyTabTitles:
            return "Pinned tabs and favorites get shorter titles, without the site’s name, counters and account names. A title you typed is never replaced."
        case .tidyDownloads:
            return "Finished downloads get clearer file names from the page they came from. The original name stays with the download."
        case .assistants:
            return "Type an assistant’s name in the command bar and press Tab to open it with what you typed."
        }
    }

    /// On when nothing was ever saved: nothing, as in Arc.
    public static let defaultEnabled: Set<MaxFeature> = []
}

/// Settings › Max, the one place its UserDefaults keys are read and written.
/// Which assistants are on is `CommandBarAssistants`' own.
public struct MaxPreferences: Equatable, Sendable {
    public static let enabledKey = "rearc.max.enabled"
    public static let futureKey = "rearc.max.enableFuture"
    public static let knownKey = "rearc.max.known"

    public var enabled: Set<MaxFeature>
    /// Automatically enable future Max features.
    public var enablesFutureFeatures: Bool
    /// Features this Mac has offered: one it has not, from a later build, is
    /// switched on at load while `enablesFutureFeatures` is on.
    public var known: Set<MaxFeature>

    public init(enabled: Set<MaxFeature> = MaxFeature.defaultEnabled, enablesFutureFeatures: Bool = false,
                known: Set<MaxFeature> = Set(MaxFeature.allCases)) {
        self.enabled = enabled
        self.enablesFutureFeatures = enablesFutureFeatures
        self.known = known
    }

    public static func load(from defaults: UserDefaults) -> MaxPreferences {
        var preferences = MaxPreferences()
        if let names = defaults.stringArray(forKey: enabledKey) {
            preferences.enabled = Set(names.compactMap(MaxFeature.init(rawValue:)))
        }
        preferences.enablesFutureFeatures = defaults.bool(forKey: futureKey)
        if let names = defaults.stringArray(forKey: knownKey) {
            preferences.known = Set(names.compactMap(MaxFeature.init(rawValue:)))
        }
        preferences.adoptNewFeatures()
        return preferences
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(enabled.map(\.rawValue).sorted(), forKey: Self.enabledKey)
        defaults.set(enablesFutureFeatures, forKey: Self.futureKey)
        defaults.set(known.map(\.rawValue).sorted(), forKey: Self.knownKey)
    }

    /// Features added since this Mac last saw the list.
    mutating func adoptNewFeatures() {
        let new = Set(MaxFeature.allCases).subtracting(known)
        guard !new.isEmpty else { return }
        if enablesFutureFeatures { enabled.formUnion(new) }
        known.formUnion(new)
    }

    public func isOn(_ feature: MaxFeature) -> Bool {
        enabled.contains(feature)
    }

    public mutating func set(_ feature: MaxFeature, on: Bool) {
        if on { enabled.insert(feature) } else { enabled.remove(feature) }
    }

    /// Enable Max · Turn On All. Every feature can run: none needs anything
    /// this Mac might not have.
    public mutating func turnOnAll() {
        enabled = Set(MaxFeature.allCases)
    }

    public var allOn: Bool { enabled.isSuperset(of: MaxFeature.allCases) }
}
