import Foundation

/// Modifier keys of a shortcut (device independent).
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ShortcutModifiers(rawValue: 1 << 0)
    public static let control = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// macOS order: ⌃⌥⇧⌘.
    public var display: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// The physical key of a shortcut, as on a US keyboard (Arc's nib names the
/// unshifted character plus Shift: ⇧⌘C, not ⌘"C").
public enum ShortcutKey: Hashable, Sendable {
    case character(Character)
    case leftArrow, rightArrow, upArrow, downArrow
    case tab, escape, space
    case function(Int)

    public var display: String {
        switch self {
        case .character(let character): return String(character).uppercased()
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        case .tab: return "⇥"
        case .escape: return "⎋"
        case .space: return "Space"
        case .function(let number): return "F\(number)"
        }
    }
}

/// Who gets a shortcut when a web page has keyboard focus. These are Arc's
/// three `arcKeyBindingPriority` values, in its Shortcuts preferences' words.
public enum ShortcutPriority: String, Sendable, CaseIterable {
    /// `overrideWebView`: "When shortcuts conflict, Arc wins." The page never sees the key.
    case arcWins
    /// `promptAfterConsumedByWebView`: "Press this shortcut once to use the
    /// website's shortcut. Press it twice to use Arc's shortcut." A key the page
    /// does not take still runs Arc's action at once.
    case websiteFirst
    /// No priority attribute: "When shortcuts conflict, the website wins." A
    /// key the page does not take runs Arc's action.
    case websiteWins
}

/// One of Arc's default key bindings.
public struct ArcShortcut: Hashable, Sendable {
    /// Arc's `arcKeyBindingID` (`goToSpace1`… and `goToSidebarItem1`… name
    /// Arc's code-defined bindings, which have no menu item).
    public let id: String
    /// Arc's menu title (or its Shortcuts preferences name).
    public let title: String
    public let key: ShortcutKey
    public let modifiers: ShortcutModifiers
    public let priority: ShortcutPriority

    public init(_ id: String, _ title: String, _ key: ShortcutKey, _ modifiers: ShortcutModifiers, _ priority: ShortcutPriority = .websiteWins) {
        self.id = id
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.priority = priority
    }

    public init(_ id: String, _ title: String, _ character: Character, _ modifiers: ShortcutModifiers, _ priority: ShortcutPriority = .websiteWins) {
        self.init(id, title, .character(character), modifiers, priority)
    }

    /// "⇧⌘C".
    public var display: String { modifiers.display + key.display }
}

/// Arc's default shortcut table: every key-bound item of Arc 1.171.0's
/// MainMenu.nib (its `arcKeyBindingID` and `arcKeyBindingPriority` runtime
/// attributes; no user overrides in StorableKeyBindings.json), then the
/// code-defined Space and sidebar-item bindings. docs/SHORTCUTS.md lists
/// each with ReArc's status.
public enum ArcShortcuts {
    public static let all: [ArcShortcut] = app + file + edit + view + developer + archive + spaces + tabs + window

    static let app: [ArcShortcut] = [
        ArcShortcut("viewPreferences", "Preferences…", ",", .command),
        ArcShortcut("hideArc", "Hide Arc", "h", .command, .arcWins),
        ArcShortcut("hideOthers", "Hide Other Windows", "h", [.option, .command]),
        ArcShortcut("quitArc", "Quit Arc", "q", .command, .arcWins),
    ]

    static let file: [ArcShortcut] = [
        ArcShortcut("newTab", "New Tab…", "t", .command, .arcWins),
        ArcShortcut("newWindow", "New Window", "n", .command, .arcWins),
        ArcShortcut("newBlankWindow", "Blank Window", "n", [.control, .command]),
        ArcShortcut("newIncognitoWindow", "New Incognito Window", "n", [.shift, .command], .arcWins),
        ArcShortcut("showLittleArc", "New Little ReArc Window", "n", [.option, .command], .arcWins),
        ArcShortcut("addressBar", "Open Command Bar", "l", .command, .arcWins),
        ArcShortcut("reopenLastClosedTab", "Restore Last Closed Tab", "t", [.shift, .command], .arcWins),
        ArcShortcut("archiveTab", "Archive Tab", "w", .command, .arcWins),
        ArcShortcut("closeWindow", "Close Window", "w", [.shift, .command], .arcWins),
        ArcShortcut("savePageAs", "Save Page As", "s", [.shift, .command]),
        ArcShortcut("printPage", "Print", "p", .command, .websiteFirst),
        ArcShortcut("capturePage", "Capture…", "2", [.shift, .command]),
        ArcShortcut("newNote", "New Note", "n", [.control, .shift], .websiteFirst),
        ArcShortcut("newNoteInSplitView", "New Note (in Split)", "n", [.control, .option], .websiteFirst),
        ArcShortcut("newEasel", "New Easel", "e", [.control, .shift]),
    ]

    static let edit: [ArcShortcut] = [
        ArcShortcut("undo", "Undo", "z", .command),
        ArcShortcut("redo", "Redo", "z", [.shift, .command]),
        ArcShortcut("cut", "Cut", "x", .command),
        ArcShortcut("copy", "Copy", "c", .command),
        ArcShortcut("paste", "Paste", "v", .command),
        ArcShortcut("pasteAndMatchStyle", "Paste and Match Style", "v", [.shift, .command]),
        ArcShortcut("selectAll", "Select All", "a", .command),
        ArcShortcut("copyCurrentURL", "Copy URL", "c", [.shift, .command], .arcWins),
        ArcShortcut("copyCurrentURLMarkdown", "Copy URL as Markdown", "c", [.option, .shift, .command], .arcWins),
        ArcShortcut("copyCurrentURLAsQuote", "Copy URL as Quote", "c", [.control, .shift, .command], .arcWins),
        ArcShortcut("find", "Find…", "f", .command),
        ArcShortcut("findNext", "Find Next", "g", .command),
        ArcShortcut("findPrevious", "Find Previous", "g", [.shift, .command]),
        ArcShortcut("findAndReplace", "Find and Replace", "f", [.option, .command]),
        ArcShortcut("jumpToSelection", "Jump to Selection", "j", .command),
        ArcShortcut("bold", "Bold", "b", .command),
        ArcShortcut("italic", "Italic", "i", .command),
        ArcShortcut("underline", "Underline", "u", .command),
        ArcShortcut("checkSpelling", "Check Document Now", ";", .command),
        ArcShortcut("showSpellingAndGrammar", "Show Spelling and Grammar", ";", [.shift, .command]),
    ]

    static let view: [ArcShortcut] = [
        ArcShortcut("showSidebar", "Show/Hide Sidebar", "s", .command, .websiteFirst),
        ArcShortcut("toggleToolbar", "Show/Hide Toolbar", "d", [.shift, .command], .websiteFirst),
        ArcShortcut("fullscreen", "Enter/Exit Full Screen", "f", [.control, .command], .websiteFirst),
        ArcShortcut("reloadPage", "Refresh the Page", "r", .command),
        ArcShortcut("forceReloadPage", "Force Refresh the Page", "r", [.shift, .command]),
        ArcShortcut("stopLoading", "Stop Loading", ".", .command),
        ArcShortcut("zoomIn", "Zoom In", "=", .command),
        ArcShortcut("zoomIn_Plus", "Zoom In", "=", [.shift, .command]),
        ArcShortcut("zoomOut", "Zoom Out", "-", .command),
        ArcShortcut("zoomOut_Shift", "Zoom Out", "-", [.shift, .command]),
        ArcShortcut("resetZoom", "Zoom to Actual Size", "0", .command),
        ArcShortcut("addSplitView", "Add Split View", "=", [.control, .shift], .websiteFirst),
        ArcShortcut("removeSplitView", "Close this Split Pane", "-", [.control, .shift], .websiteFirst),
        ArcShortcut("exit", "Exit", .escape, [], .websiteFirst),
        ArcShortcut("focusSidebar", "Reveal Current Tab", .space, .control, .websiteFirst),
    ]

    static let developer: [ArcShortcut] = [
        ArcShortcut("developerTools", "Developer Tools", "i", [.option, .command], .websiteFirst),
        ArcShortcut("developerTools_Alternate", "Developer Tools", .function(12), [], .websiteFirst),
        ArcShortcut("inspectElements", "Inspect Elements", "c", [.option, .command], .websiteFirst),
        ArcShortcut("javaScriptConsole", "JavaScript Console", "j", [.option, .command]),
        ArcShortcut("viewSource", "View Source", "u", [.option, .command], .websiteFirst),
        ArcShortcut("toggleDeveloperMode", "Toggle Developer Mode", "d", .control, .websiteFirst),
    ]

    static let archive: [ArcShortcut] = [
        ArcShortcut("goBack", "Go Back", "[", .command, .arcWins),
        ArcShortcut("goBack_Alternate", "Go Back", .leftArrow, .command),
        ArcShortcut("goForward", "Go Forward", "]", .command, .arcWins),
        ArcShortcut("goForward_Alternate", "Go Forward", .rightArrow, .command),
        ArcShortcut("viewHistory", "View History", "y", .command),
    ]

    /// ⌃1…9 are code-defined ("Jumps over to your 1st Space without needing to
    /// swipe"); their default priority is not in the nib (inferred: Arc wins).
    static let spaces: [ArcShortcut] = [
        ArcShortcut("focusNextSpace", "Next Space", .rightArrow, [.option, .command]),
        ArcShortcut("focusPreviousSpace", "Previous Space", .leftArrow, [.option, .command]),
    ] + (1 ... 9).map { number in
        ArcShortcut("goToSpace\(number)", "Go to Space \(number)", Character("\(number)"), .control, .arcWins)
    }

    /// ⌘1…9 are code-defined ("Jumps to the first item in your Sidebar,
    /// starting with your Favorites at the top"; ⌘9 "Jumps to the last item").
    static let tabs: [ArcShortcut] = [
        ArcShortcut("clearExplore", "Clear Unpinned Tabs", "k", [.shift, .command]),
        ArcShortcut("cycleTabBackward", "Cycle Tab Backward", .leftArrow, [.control, .command], .arcWins),
        ArcShortcut("cycleTabForward", "Cycle Tab Forward", .rightArrow, [.control, .command], .arcWins),
        ArcShortcut("joinLiveMeeting", "Join Meeting", "j", [.control, .command], .websiteFirst),
        ArcShortcut("gptMessage", "New ChatGPT Message…", "g", [.option, .command]),
        // Shadowed: File's New Incognito Window comes first in the menu bar.
        ArcShortcut("newFolder", "New Folder…", "n", [.shift, .command]),
        ArcShortcut("selectNextTab", "Next Tab", .downArrow, [.option, .command], .arcWins),
        ArcShortcut("selectPreviousTab", "Previous Tab", .upArrow, [.option, .command], .arcWins),
        ArcShortcut("openTabIn", "Open Little ReArc or Peek in…", "o", .command, .websiteFirst),
        ArcShortcut("peekEmail", "Peek Email…", "e", [.shift, .command], .websiteFirst),
        ArcShortcut("pinTab", "Pin/Unpin Tab", "d", .command, .websiteFirst),
        ArcShortcut("cycleNextTab", "Tab Switcher (forward)", .tab, .control, .arcWins),
        ArcShortcut("cyclePreviousTab", "Tab Switcher (backward)", .tab, [.control, .shift], .arcWins),
    ] + (1 ... 9).map { number in
        ArcShortcut("goToSidebarItem\(number)", number == 9 ? "Go to Last Sidebar Item" : "Go to Sidebar Item \(number)",
                    Character("\(number)"), .command, .arcWins)
    }

    static let window: [ArcShortcut] = [
        ArcShortcut("minimize", "Minimize Window", "m", .command, .arcWins),
        ArcShortcut("viewDownloads", "View Downloads", "j", [.shift, .command]),
        ArcShortcut("viewLibrary", "View Library", "l", [.shift, .command]),
    ]

    /// Settings › Shortcuts › Learn the Essential Shortcuts (docs/SHORTCUTS.md
    /// "Essential shortcuts"): the keys Arc's onboarding teaches first.
    public static let essentialIDs = [
        "addressBar", "newTab", "archiveTab", "reopenLastClosedTab", "showSidebar", "copyCurrentURL",
        "pinTab", "addSplitView", "showLittleArc", "cycleNextTab", "goToSpace1", "focusNextSpace",
    ]

    /// The binding a key press triggers, the first in menu-bar order when two
    /// share keys (as AppKit resolves key equivalents).
    public static func binding(for key: ShortcutKey, modifiers: ShortcutModifiers) -> ArcShortcut? {
        index[Combination(key: key, modifiers: modifiers)]
    }

    public static func binding(id: String) -> ArcShortcut? {
        all.first { $0.id == id }
    }

    /// Bindings whose keys an earlier binding already takes.
    public static var shadowed: [ArcShortcut] {
        all.filter { binding(for: $0.key, modifiers: $0.modifiers)?.id != $0.id }
    }

    private struct Combination: Hashable {
        let key: ShortcutKey
        let modifiers: ShortcutModifiers
    }

    private static let index: [Combination: ArcShortcut] = {
        var index: [Combination: ArcShortcut] = [:]
        for shortcut in all where index[Combination(key: shortcut.key, modifiers: shortcut.modifiers)] == nil {
            index[Combination(key: shortcut.key, modifiers: shortcut.modifiers)] = shortcut
        }
        return index
    }()
}

/// Where a key pressed while a web page has keyboard focus goes first.
public enum ShortcutRoute: Equatable, Sendable {
    /// The browser runs the shortcut and the page never sees the key.
    case browser
    /// The page sees the key; its verdict decides (`ShortcutVerdict`).
    case page
}

/// What the browser does once the page has seen a key.
public enum ShortcutVerdict: Equatable, Sendable {
    /// Run the browser's shortcut (the page did not take the key).
    case perform
    /// The page took a `websiteFirst` key: offer the browser's action on a second press.
    case prompt
    /// The page keeps the key.
    case none
}

/// Arc's rule for shortcuts while a page has focus (docs/SHORTCUTS.md "Routing").
public enum ShortcutRouting {
    /// `armed`: the same `websiteFirst` shortcut was pressed, and taken by the
    /// page, within `ShortcutPromptArming.window`.
    public static func route(_ shortcut: ArcShortcut?, armed: Bool) -> ShortcutRoute {
        switch shortcut?.priority {
        case .arcWins: return .browser
        case .websiteFirst: return armed ? .browser : .page
        case .websiteWins, nil: return .page
        }
    }

    public static func verdict(_ shortcut: ArcShortcut?, consumedByPage: Bool) -> ShortcutVerdict {
        guard consumedByPage else { return .perform }
        return shortcut?.priority == .websiteFirst ? .prompt : .none
    }

    /// The toast after the page took a `websiteFirst` key (inferred wording:
    /// Arc's string is "<do something> again to <do action>").
    public static func promptMessage(for shortcut: ArcShortcut) -> String {
        "Press \(shortcut.display) again to \(shortcut.title)"
    }
}

/// The second press of a `websiteFirst` shortcut goes to the browser when it
/// comes while the prompt is showing.
public struct ShortcutPromptArming: Equatable, Sendable {
    /// Inferred (Arc's value is not in its strings): the prompt toast's lifetime.
    public static let window: TimeInterval = 2.5

    public private(set) var armedID: String?
    public private(set) var deadline: Date = .distantPast

    public init() {}

    public mutating func arm(_ id: String, now: Date = Date()) {
        armedID = id
        deadline = now.addingTimeInterval(Self.window)
    }

    public func isArmed(_ id: String, now: Date = Date()) -> Bool {
        armedID == id && now < deadline
    }

    public mutating func disarm() {
        armedID = nil
        deadline = .distantPast
    }
}

/// Arc's Cycle Tab Backward / Forward (⌃⌘← / ⌃⌘→): "Cycle backwards through
/// tabs you've previously visited", without the switcher. The visit order is
/// fixed when a cycle starts, so stepping back and forth retraces it; showing
/// any other tab starts a new cycle.
public struct TabVisitCycle: Equatable, Sendable {
    /// Most recently shown first; `order[0]` was showing when the cycle began.
    public private(set) var order: [Tab.ID]
    public private(set) var index = 0

    public init?(order: [Tab.ID]) {
        guard order.count > 1 else { return nil }
        self.order = order
    }

    public var current: Tab.ID { order[index] }

    /// Backward goes to an older visit, forward back toward the newest; nil at either end.
    public mutating func step(forward: Bool) -> Tab.ID? {
        let next = index + (forward ? -1 : 1)
        guard order.indices.contains(next) else { return nil }
        index = next
        return order[next]
    }
}
