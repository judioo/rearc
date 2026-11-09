import AppKit

/// What ⌘W closes, as in Arc and Chrome: the selected tab while a browser
/// window is key, otherwise the key window itself when it is an auxiliary
/// one (About, Settings, Import, Air Traffic Control, the DevTools, Little
/// Arc and private windows). Sheets, panels such as extension popups, and
/// borderless windows such as the sunrise leave ⌘W to the tab behind them.
enum CloseShortcutTarget: Equatable {
    case selectedTab
    case keyWindow

    static func resolve(keyWindow: NSWindow?, isBrowserWindow: (NSWindow) -> Bool) -> CloseShortcutTarget {
        guard let window = keyWindow, !isBrowserWindow(window), window.sheetParent == nil, !(window is NSPanel),
              window.styleMask.isSuperset(of: [.titled, .closable]) else { return .selectedTab }
        return .keyWindow
    }
}
