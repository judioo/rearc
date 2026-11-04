import SidebarModel
import SwiftUI

/// The Cmd+F bar for one page at a time: it drives the find session on the
/// engine it was opened on and shows only that session's settled results.
/// Typing restarts the search (incremental); Return / Cmd+G go to the next
/// match, Shift+Return / Shift+Cmd+G to the previous one; Esc closes and
/// keeps the selection, as Chrome does.
@Observable
final class FindBarModel {
    private(set) var isPresented = false
    private(set) var state = FindInPageState()
    /// Bumped to focus the field and select its text (Cmd+F while open).
    private(set) var focusToken = 0

    @ObservationIgnored private(set) weak var engine: (any FindInPageEngine)?
    /// Last query, kept across closes so Cmd+G / reopening repeats it.
    @ObservationIgnored private(set) var lastQuery = ""

    var query: String { state.query }
    var statusText: String { state.statusText }
    var hasNoMatches: Bool { state.hasNoMatches }

    /// Whether the bar belongs on the view rendering `engine`.
    func isShown(for engine: (any WebEngine)?) -> Bool {
        guard isPresented, let engine, let target = self.engine else { return false }
        return (engine as AnyObject) === (target as AnyObject)
    }

    /// Cmd+F: open on `engine` (moving from another page if needed) and focus the field.
    func present(on engine: any FindInPageEngine) {
        guard engine.supportsFindInPage else { return }
        if let current = self.engine, (current as AnyObject) !== (engine as AnyObject) {
            detach(.keepSelection)
        }
        if self.engine == nil {
            attach(engine)
            isPresented = true
            if !lastQuery.isEmpty { setQuery(lastQuery) }
        }
        isPresented = true
        focusToken += 1
    }

    /// Text field edits: every change starts a new session (or clears on empty).
    func setQuery(_ text: String) {
        state.query = text
        guard let engine else { return }
        if text.isEmpty {
            engine.stopFind(.clearSelection)
            state.cleared()
            return
        }
        lastQuery = text
        start(forward: true)
    }

    func setMatchCase(_ matchCase: Bool) {
        guard state.matchCase != matchCase else { return }
        state.matchCase = matchCase
        if !state.query.isEmpty { start(forward: true) }
    }

    /// Return / Cmd+G (forward), Shift+Return / Shift+Cmd+G.
    func next(forward: Bool) {
        guard let engine, !state.query.isEmpty else { return }
        // The session ended (navigation, stop): search the new document again.
        if state.sessionID == 0 || !engine.findNext(forward: forward) {
            start(forward: forward)
        }
    }

    /// Esc or the close button. `.activateSelection` follows a found link.
    func close(_ action: FindStopAction = .keepSelection) {
        guard isPresented else { return }
        detach(action)
        isPresented = false
    }

    /// The page the bar searched went away (tab closed, engine dropped).
    func engineDisappeared(_ engine: any WebEngine) {
        guard let target = self.engine, (target as AnyObject) === (engine as AnyObject) else { return }
        detach(.keepSelection)
        isPresented = false
    }

    private func start(forward: Bool) {
        guard let engine else { return }
        if let session = engine.startFind(state.query, matchCase: state.matchCase, forward: forward) {
            state.began(session: session)
        } else {
            state.cleared()
        }
    }

    private func attach(_ engine: any FindInPageEngine) {
        self.engine = engine
        state = FindInPageState(query: "", matchCase: state.matchCase)
        engine.onFindEvent = { [weak self, weak engine] event in
            guard let self, let engine, let current = self.engine, (current as AnyObject) === (engine as AnyObject) else { return }
            self.state.apply(event)
        }
    }

    private func detach(_ action: FindStopAction) {
        guard let engine else { return }
        engine.stopFind(action)
        engine.onFindEvent = nil
        self.engine = nil
        state.cleared()
    }
}
