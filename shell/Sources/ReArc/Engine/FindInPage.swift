import SidebarModel
import WebKit

/// Find in page on one tab's engine (Cmd+F bar). Chromium maps onto
/// FindTabHelper through ABI 1.16 (`ReArcTabFindStart/Next/Stop` and result
/// events); WebKit onto `WKWebView.find(_:configuration:)`, counting matches
/// in the page text itself. Results and terminals arrive on `onFindEvent`,
/// always on the main thread, tagged with the session they belong to.
protocol FindInPageEngine: AnyObject {
    var supportsFindInPage: Bool { get }
    var onFindEvent: ((FindInPageEvent) -> Void)? { get set }
    /// Starts a new session for `text` (each keystroke may restart; an active
    /// session ends as `replaced`). Returns the session ID, nil when rejected.
    func startFind(_ text: String, matchCase: Bool, forward: Bool) -> UInt64?
    /// Next/previous match of the active session (wraps). False without one.
    @discardableResult
    func findNext(forward: Bool) -> Bool
    func stopFind(_ action: FindStopAction)
}

// MARK: - WebKit

/// WebKit's find has no counts or sessions: the shell numbers sessions,
/// counts case-folded occurrences in `innerText` (isolated client world),
/// and steps the active ordinal with wrap-around as `find` moves.
final class WebKitFindSession {
    private(set) var sessionID: UInt64 = 0
    private(set) var text = ""
    private(set) var matchCase = false
    private(set) var count = 0
    private(set) var ordinal = 0
    private var nextID: UInt64 = 1

    var isActive: Bool { sessionID != 0 }

    func begin(_ text: String, matchCase: Bool) -> (new: UInt64, replaced: UInt64?) {
        let replaced = isActive ? sessionID : nil
        sessionID = nextID
        nextID += 1
        self.text = text
        self.matchCase = matchCase
        count = 0
        ordinal = 0
        return (sessionID, replaced)
    }

    func counted(_ count: Int, matchFound: Bool) {
        // innerText can miss text WebKit finds (e.g. inside shadow roots), and vice versa.
        self.count = matchFound ? max(count, 1) : 0
        ordinal = self.count > 0 ? 1 : 0
    }

    func stepped(forward: Bool, matchFound: Bool) {
        guard matchFound else { return }
        if count == 0 { count = 1 }
        ordinal = FindOrdinal.step(ordinal, count: count, forward: forward)
    }

    func end() -> UInt64? {
        guard isActive else { return nil }
        defer { sessionID = 0 }
        return sessionID
    }
}

extension WKEngine: FindInPageEngine {
    var supportsFindInPage: Bool { true }

    private static let pageTextSource = "return document.body ? document.body.innerText : (document.documentElement ? document.documentElement.textContent : '');"
    private static let clearSelectionSource = "var s = window.getSelection(); if (s) { s.removeAllRanges(); } return true;"

    func startFind(_ text: String, matchCase: Bool, forward: Bool) -> UInt64? {
        guard !text.isEmpty else { return nil }
        let (session, replaced) = findSession.begin(text, matchCase: matchCase)
        if let replaced { emitFindTerminal(replaced, .replaced) }
        // Restart from the top of the page so the first hit is match 1.
        webView.callAsyncJavaScript(Self.clearSelectionSource, arguments: [:], in: nil, in: .defaultClient) { [weak self] _ in
            guard let self, self.findSession.sessionID == session else { return }
            self.webView.callAsyncJavaScript(Self.pageTextSource, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.findSession.sessionID == session else { return }
                let pageText = (try? result.get()) as? String ?? ""
                let counted = FindOrdinal.count(of: text, in: pageText, matchCase: matchCase)
                self.webView.find(text, configuration: Self.findConfiguration(forward: forward, matchCase: matchCase)) { [weak self] found in
                    guard let self, self.findSession.sessionID == session else { return }
                    self.findSession.counted(counted, matchFound: found.matchFound)
                    self.emitFindResult()
                }
            }
        }
        return session
    }

    @discardableResult
    func findNext(forward: Bool) -> Bool {
        guard findSession.isActive else { return false }
        let session = findSession.sessionID
        let configuration = Self.findConfiguration(forward: forward, matchCase: findSession.matchCase)
        webView.find(findSession.text, configuration: configuration) { [weak self] found in
            guard let self, self.findSession.sessionID == session else { return }
            self.findSession.stepped(forward: forward, matchFound: found.matchFound)
            self.emitFindResult()
        }
        return true
    }

    func stopFind(_ action: FindStopAction) {
        guard let ended = findSession.end() else { return }
        if action == .clearSelection {
            webView.callAsyncJavaScript(Self.clearSelectionSource, arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
        }
        emitFindTerminal(ended, .stopped)
    }

    /// didCommit: the document the session searched is gone.
    func endFindOnNavigation() {
        guard let ended = findSession.end() else { return }
        emitFindTerminal(ended, .navigated)
    }

    private static func findConfiguration(forward: Bool, matchCase: Bool) -> WKFindConfiguration {
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = matchCase
        configuration.wraps = true
        return configuration
    }

    private func emitFindResult() {
        onFindEvent?(FindInPageEvent(
            sessionID: findSession.sessionID,
            matchCount: Int32(findSession.count),
            activeOrdinal: Int32(findSession.ordinal),
            finalUpdate: true,
            reason: .result
        ))
    }

    private func emitFindTerminal(_ session: UInt64, _ reason: FindInPageEvent.Reason) {
        onFindEvent?(FindInPageEvent(sessionID: session, matchCount: -1, activeOrdinal: -1, finalUpdate: true, reason: reason))
    }
}
