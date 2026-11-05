import Foundation

/// One autocomplete suggestion from the search provider (Chromium
/// AutocompleteController search matches, or the provider's OpenSearch
/// suggest endpoint on WebKit).
public struct SearchSuggestion: Equatable, Sendable {
    public var text: String
    public var destinationURL: URL

    public init(text: String, destinationURL: URL) {
        self.text = text
        self.destinationURL = destinationURL
    }
}

/// What Enter on the typed text does: open it as an address, or search it.
public enum InputClassification: Equatable, Sendable {
    case url(URL)
    case search(URL)

    public var destinationURL: URL {
        switch self {
        case .url(let url), .search(let url): return url
        }
    }
}

/// Engine or network results for one command-bar query, merged into the
/// shell's own tabs, commands and site search by `CommandBarSearch.results`.
/// Results for any other text are ignored, so a late answer for an earlier
/// keystroke never shows.
public struct CommandBarLiveResults: Equatable, Sendable {
    public var query: String
    /// Engine history (Chromium HistoryService). nil keeps the shell's visit store.
    public var history: [VisitRecord]?
    public var suggestions: [SearchSuggestion]
    /// The engine's URL-vs-search decision. nil uses `URLEntry`'s rules.
    public var classification: InputClassification?

    public init(query: String, history: [VisitRecord]? = nil, suggestions: [SearchSuggestion] = [], classification: InputClassification? = nil) {
        self.query = query
        self.history = history
        self.suggestions = suggestions
        self.classification = classification
    }

    public func applies(to query: String) -> Bool {
        Self.normalized(self.query) == Self.normalized(query)
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Independent sources replace only their own snapshot. The final value is
/// independent of whether history, classification or suggestions answers first;
/// an autocomplete snapshot keeps the provider's order and replaces its partial.
public struct CommandBarLiveAccumulator: Sendable {
    public enum Update: Sendable {
        case history([VisitRecord])
        case classification(InputClassification?)
        case suggestions([SearchSuggestion])
    }

    public private(set) var results: CommandBarLiveResults

    public init(query: String) { results = CommandBarLiveResults(query: query) }

    public mutating func merge(_ update: Update) {
        switch update {
        case .history(let rows): results.history = rows
        case .classification(let classification): results.classification = classification
        case .suggestions(let rows): results.suggestions = rows
        }
    }
}

/// Per-keystroke request generations: every edit starts a new generation
/// and cancels the previous one, and a completion is used only while its
/// generation is still the newest.
public struct CommandBarQueryGate: Equatable, Sendable {
    public private(set) var generation: UInt64 = 0
    public private(set) var query: String = ""

    public init() {}

    @discardableResult
    public mutating func begin(_ text: String) -> UInt64 {
        generation &+= 1
        query = text
        return generation
    }

    /// The command bar closed: every outstanding request is stale.
    public mutating func cancel() {
        generation &+= 1
        query = ""
    }

    public func isCurrent(_ generation: UInt64) -> Bool {
        generation == self.generation
    }
}

/// Per-row actions in the command bar (Arc COMMAND-BAR §6.4).
public enum CommandBarRowAction: Equatable, Sendable {
    case copyURL
    case deleteFromHistory

    public var title: String {
        switch self {
        case .copyURL: return "Copy URL"
        case .deleteFromHistory: return "Remove from History"
        }
    }

    public var systemImage: String {
        switch self {
        case .copyURL: return "doc.on.doc"
        case .deleteFromHistory: return "trash"
        }
    }
}

extension CommandBarSearch {
    /// Most suggestion rows shown for one query.
    public static let suggestionLimit = 4

    public static func rowActions(for result: Result) -> [CommandBarRowAction] {
        switch result.kind {
        case .history:
            return [.copyURL, .deleteFromHistory]
        case .openTab, .openURL, .suggestion:
            return result.destinationURL == nil ? [] : [.copyURL]
        case .search, .command:
            return []
        }
    }
}
