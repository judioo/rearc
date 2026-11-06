import Foundation

/// The default-search choices of one profile, as Chrome's settings offer them
/// (Chromium `ReArcSearchListEngines`, ABI 1.46 `search_engines`): the current
/// default plus the prepopulated and policy-provided engines, in Chromium's
/// order. A Settings pop-up lists `engines` and selects by `id`.
public struct SearchEngineChoices: Equatable, Sendable {
    public struct Engine: Identifiable, Equatable, Sendable {
        /// Chromium's TemplateURLID: stable for the profile, the handle for setting the default.
        public var id: Int64
        public var name: String
        public var keyword: String
        /// Search URL with `%s` where the terms go.
        public var searchTemplate: String
        public var faviconURL: URL?
        public var isDefault: Bool
        public var isPrepopulated: Bool
        /// False for every engine while the default is policy-managed.
        public var canMakeDefault: Bool

        public init(id: Int64, name: String, keyword: String, searchTemplate: String, faviconURL: URL? = nil,
                    isDefault: Bool = false, isPrepopulated: Bool = false, canMakeDefault: Bool = true) {
            self.id = id
            self.name = name
            self.keyword = keyword
            self.searchTemplate = searchTemplate
            self.faviconURL = faviconURL
            self.isDefault = isDefault
            self.isPrepopulated = isPrepopulated
            self.canMakeDefault = canMakeDefault
        }
    }

    public var engines: [Engine]
    /// An enterprise policy sets the default: show it, disable the pop-up.
    public var isManaged: Bool

    public init(engines: [Engine], isManaged: Bool = false) {
        self.engines = engines
        self.isManaged = isManaged
    }

    public var current: Engine? { engines.first { $0.isDefault } }

    /// The pop-up can change the default.
    public var isEditable: Bool { !isManaged && engines.contains { $0.canMakeDefault } }

    /// The list after Chromium accepted `id` as the new default.
    public func selecting(_ id: Int64) -> SearchEngineChoices {
        guard engines.contains(where: { $0.id == id && $0.canMakeDefault }) else { return self }
        var copy = self
        for index in copy.engines.indices { copy.engines[index].isDefault = copy.engines[index].id == id }
        return copy
    }

    /// The command bar's provider for an engine (suggestions are not part of the list).
    public static func provider(_ engine: Engine) -> SearchProvider {
        SearchProvider(id: engine.keyword, name: engine.name, keyword: engine.keyword, searchTemplate: engine.searchTemplate)
    }
}
