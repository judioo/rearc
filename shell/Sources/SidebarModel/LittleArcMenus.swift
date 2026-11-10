import Foundation

/// The Dock menu (P3.22): each open Little Arc by its title, then the new
/// window commands. The shell turns the entries into an NSMenu.
public enum LittleArcDockMenu {
    public enum Entry: Equatable {
        case littleArc(id: LittleArcWindow.ID, title: String)
        case separator
        case newLittleArc
        case newWindow
    }

    /// `canOpenBrowserWindow` is false where the shell has no New Window (WebKit).
    public static func entries(for windows: [LittleArcWindow], canOpenBrowserWindow: Bool) -> [Entry] {
        var entries = windows.map { Entry.littleArc(id: $0.id, title: title(of: $0)) }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.newLittleArc)
        if canOpenBrowserWindow { entries.append(.newWindow) }
        return entries
    }

    /// The page title, else its host, else "Little Arc" (a blank one).
    public static func title(of window: LittleArcWindow) -> String {
        let trimmed = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "Little ReArc", trimmed != "Little Arc" { return trimmed }
        return window.url.host() ?? "Little ReArc"
    }
}
