import Foundation

/// Find-in-page bar state shared by both engines (pure, no UI imports).
///
/// Chromium (ABI 1.16) reports results per find session: every keystroke
/// starts a new session, the old one ends with a `replaced` terminal, and
/// only `final_update` results carry the settled count (C-ABI.md "Find in
/// page"). WebKit has no session IDs; `WKEngine` counts matches itself and
/// reports them as one final result per request.
public struct FindInPageState: Equatable, Sendable {
    public var query: String
    public var matchCase: Bool
    /// Engine session of the current search; 0 when none is active.
    public var sessionID: UInt64
    /// Settled match count; nil while the first final result is pending or
    /// after the session ended (navigation, close, stop).
    public var matchCount: Int?
    /// 1-based active match; 0 = none.
    public var activeOrdinal: Int

    public init(query: String = "", matchCase: Bool = false) {
        self.query = query
        self.matchCase = matchCase
        sessionID = 0
        matchCount = nil
        activeOrdinal = 0
    }

    /// "3 of 12", "No matches", or empty while there is nothing to show.
    public var statusText: String {
        guard !query.isEmpty, let matchCount else { return "" }
        if matchCount == 0 { return "No matches" }
        return "\(max(activeOrdinal, 1)) of \(matchCount)"
    }

    public var hasNoMatches: Bool { !query.isEmpty && matchCount == 0 }

    /// A new session was accepted for the current query; counts reset until its first final result.
    public mutating func began(session: UInt64) {
        sessionID = session
        matchCount = nil
        activeOrdinal = 0
    }

    public mutating func cleared() {
        sessionID = 0
        matchCount = nil
        activeOrdinal = 0
    }

    /// Applies one engine result. Returns false when the event belongs to
    /// another session or is a partial update, and so changes nothing.
    @discardableResult
    public mutating func apply(_ event: FindInPageEvent) -> Bool {
        guard sessionID != 0, event.sessionID == sessionID else { return false }
        if event.reason != .result {
            // Terminal: the session is gone (navigated, closed, stopped, replaced).
            sessionID = 0
            matchCount = nil
            activeOrdinal = 0
            return true
        }
        guard event.finalUpdate else { return false }
        matchCount = max(Int(event.matchCount), 0)
        activeOrdinal = matchCount == 0 ? 0 : min(max(Int(event.activeOrdinal), 0), matchCount ?? 0)
        return true
    }
}

/// One find result or terminal, copied out of the engine callback.
public struct FindInPageEvent: Equatable, Sendable {
    /// `ReArcFindEvent.reason`: 0 is a result, every other value ends the session once.
    public enum Reason: UInt32, Sendable {
        case result = 0, navigated, closed, stopped, replaced
    }

    public var sessionID: UInt64
    public var matchCount: Int32
    public var activeOrdinal: Int32
    public var finalUpdate: Bool
    public var reason: Reason

    public init(sessionID: UInt64, matchCount: Int32, activeOrdinal: Int32, finalUpdate: Bool, reason: Reason) {
        self.sessionID = sessionID
        self.matchCount = matchCount
        self.activeOrdinal = activeOrdinal
        self.finalUpdate = finalUpdate
        self.reason = reason
    }

    /// Raw ABI fields; unknown reasons are treated as terminals (`stopped`).
    public init(sessionID: UInt64, matchCount: Int32, activeOrdinal: Int32, finalUpdate: Bool, rawReason: UInt32) {
        self.init(
            sessionID: sessionID,
            matchCount: matchCount,
            activeOrdinal: activeOrdinal,
            finalUpdate: finalUpdate,
            reason: Reason(rawValue: rawReason) ?? .stopped
        )
    }
}

/// What closing the bar does to the selection (`ReArcTabFindStop` action).
public enum FindStopAction: UInt32, Sendable {
    case clearSelection = 0, keepSelection, activateSelection
}

public enum FindOrdinal {
    /// Next/previous active match with wrap-around (WebKit path, which counts itself).
    public static func step(_ ordinal: Int, count: Int, forward: Bool) -> Int {
        guard count > 0 else { return 0 }
        guard ordinal > 0 else { return forward ? 1 : count }
        if forward { return ordinal >= count ? 1 : ordinal + 1 }
        return ordinal <= 1 ? count : ordinal - 1
    }

    /// Case-(in)sensitive occurrence count in plain text, as WebKit's text search sees it.
    public static func count(of needle: String, in text: String, matchCase: Bool) -> Int {
        guard !needle.isEmpty else { return 0 }
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive, .diacriticInsensitive]
        var count = 0
        var range = text.startIndex ..< text.endIndex
        while let found = text.range(of: needle, options: options, range: range) {
            count += 1
            range = found.upperBound ..< text.endIndex
        }
        return count
    }
}
