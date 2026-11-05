import Foundation
import SidebarModel

/// Owned copy of one `ReArcHistoryEntry` (ABI 1.23).
struct ChromiumHistoryRow: Equatable {
    var title: String
    var url: String
    /// Microseconds since the Unix epoch.
    var visitTimeUS: Int64
    var visitCount: Int32

    /// The row as a command-bar visit record; nil for pages the command bar never suggests.
    var record: VisitRecord? {
        guard let url = URL(string: url), VisitHistory.isRecordable(url) else { return nil }
        let date = Date(timeIntervalSince1970: Double(visitTimeUS) / 1_000_000)
        return VisitRecord(url: url, title: title, visitCount: max(Int(visitCount), 1), firstVisit: date, lastVisit: date)
    }
}

/// Owned copy of one `ReArcAutocompleteMatch` (ABI 1.26).
struct ChromiumAutocompleteMatch: Equatable {
    /// 0 none, 1 url, 2 search.
    var kind: UInt32
    var matchType: UInt32
    var relevance: Int32
    var allowedToBeDefault: Bool
    var deletable: Bool
    var contents: String
    var description: String
    var destinationURL: String
    var fillIntoEdit: String
}

/// Pure mapping of the engine's search results to the command bar's
/// models, unit-tested without Chromium.
enum ChromiumSearchMapping {
    /// `ReArcSearchProvider` as a `SearchProvider`; nil without a usable search template.
    static func provider(name: String, keyword: String, searchURL: String, suggestURL: String) -> SearchProvider? {
        guard !name.isEmpty, SearchProvider.isValidTemplate(searchURL) else { return nil }
        return SearchProvider(
            id: "chromium:\(keyword.isEmpty ? name : keyword)",
            name: name,
            keyword: keyword,
            searchTemplate: searchURL,
            suggestTemplate: SearchProvider.isValidTemplate(suggestURL) ? suggestURL : nil
        )
    }

    /// `ReArcInputClassification`: kind 1 navigates, 2 searches, 0 decides nothing.
    static func classification(kind: UInt32, destination: String) -> InputClassification? {
        guard let url = URL(string: destination), url.scheme != nil else { return nil }
        switch kind {
        case 1: return .url(url)
        case 2: return .search(url)
        default: return nil
        }
    }

    /// Search matches in Chromium's rank order. URL matches are left out:
    /// history rows come from `ReArcHistoryQuery`, and the typed address
    /// from the classification.
    static func suggestions(_ matches: [ChromiumAutocompleteMatch], partialQuery: String? = nil) -> [SearchSuggestion] {
        matches.compactMap { match in
            guard match.kind == 2, let url = URL(string: match.destinationURL), url.scheme != nil else { return nil }
            let text = match.contents.isEmpty ? match.fillIntoEdit : match.contents
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            // Chromium may carry cached suggestions from its previous input
            // into a partial result. Stream only rows completing this input;
            // the terminal snapshot admits corrections and non-prefix matches.
            if let partialQuery {
                let needle = partialQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !needle.isEmpty, text.lowercased().hasPrefix(needle) else { return nil }
            }
            return SearchSuggestion(text: text, destinationURL: url)
        }
    }
}
