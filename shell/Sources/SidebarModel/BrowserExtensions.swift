import CoreGraphics
import Foundation

// Extensions (engine ABI 1.31–1.33, 1.36). Chromium owns install, storage,
// permissions and the extensions themselves; the shell draws the toolbar,
// presents prompts and popups, and reports its tab/window model. Everything
// here is pure so the toolbar layout, prompt text and window reporting are
// testable without Chromium.

/// SkColor ARGB as the engine reports it; 0 means "Chromium's default".
public struct ExtensionBadgeColor: Equatable, Sendable {
    public var red, green, blue, alpha: Double

    public init?(skColor: UInt32) {
        guard skColor != 0 else { return nil }
        alpha = Double((skColor >> 24) & 0xFF) / 255
        red = Double((skColor >> 16) & 0xFF) / 255
        green = Double((skColor >> 8) & 0xFF) / 255
        blue = Double(skColor & 0xFF) / 255
    }
}

/// One extension's toolbar action for one tab (`ReArcExtensionAction`).
public struct ExtensionActionItem: Identifiable, Equatable, Sendable {
    /// The extension ID (32 letters a–p).
    public var id: String
    public var name: String
    public var title: String
    public var badgeText: String
    public var badgeTextColor: ExtensionBadgeColor?
    public var badgeBackgroundColor: ExtensionBadgeColor?
    /// False: the action is disabled for this tab.
    public var isEnabled: Bool
    public var hasPopup: Bool
    /// Blocked scripts or requests wait for a click (site access "on click").
    public var wantsToRun: Bool
    public var iconPNG: Data?

    public init(
        id: String, name: String, title: String = "", badgeText: String = "",
        badgeTextColor: UInt32 = 0, badgeBackgroundColor: UInt32 = 0,
        isEnabled: Bool = true, hasPopup: Bool = false, wantsToRun: Bool = false, iconPNG: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.badgeText = badgeText
        self.badgeTextColor = ExtensionBadgeColor(skColor: badgeTextColor)
        self.badgeBackgroundColor = ExtensionBadgeColor(skColor: badgeBackgroundColor)
        self.isEnabled = isEnabled
        self.hasPopup = hasPopup
        self.wantsToRun = wantsToRun
        self.iconPNG = iconPNG
    }

    /// Chrome's tooltip: the action title, or the extension name without one.
    public var tooltip: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == name { return name }
        return "\(name)\n\(title)"
    }

    /// Badges are short; Chrome shows four characters at most.
    public var displayBadge: String? {
        let text = badgeText.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(4))
    }
}

/// Which actions sit in the toolbar. Chrome and Arc keep new extensions in
/// the extensions menu until pinned; pins are the shell's (Chromium has no
/// toolbar model for registry tabs) and survive relaunches.
public struct ExtensionPins: Codable, Equatable, Sendable {
    public static let defaultsKey = "ReArcPinnedExtensions"

    public private(set) var pinnedIDs: [String]

    public init(pinnedIDs: [String] = []) {
        var seen = Set<String>()
        self.pinnedIDs = pinnedIDs.filter { seen.insert($0).inserted }
    }

    public func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    public mutating func pin(_ id: String) {
        guard !isPinned(id) else { return }
        pinnedIDs.append(id)
    }

    public mutating func unpin(_ id: String) {
        pinnedIDs.removeAll { $0 == id }
    }

    public mutating func toggle(_ id: String) {
        if isPinned(id) { unpin(id) } else { pin(id) }
    }

    /// The pinned actions in pin order; the menu lists every action in
    /// Chromium's registry order. Pins of extensions this tab does not list
    /// (an off-the-record tab lists incognito-enabled ones only) are kept.
    public func pinned(_ actions: [ExtensionActionItem]) -> [ExtensionActionItem] {
        pinnedIDs.compactMap { id in actions.first { $0.id == id } }
    }

    public static func load(from defaults: UserDefaults) -> ExtensionPins {
        ExtensionPins(pinnedIDs: defaults.stringArray(forKey: defaultsKey) ?? [])
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(pinnedIDs, forKey: Self.defaultsKey)
    }
}

/// Popup sizes the renderer asks for (event kind 3), within Chromium's
/// ExtensionPopup bounds.
public enum ExtensionPopupGeometry {
    public static let minimum = CGSize(width: 25, height: 25)
    public static let maximum = CGSize(width: 800, height: 600)
    /// Shown until the first resize arrives.
    public static let initial = CGSize(width: 64, height: 40)

    public static func clamped(width: Int32, height: Int32) -> CGSize {
        CGSize(
            width: min(max(CGFloat(width), minimum.width), maximum.width),
            height: min(max(CGFloat(height), minimum.height), maximum.height)
        )
    }
}

/// `ReArcTabRunExtensionAction` result.
public enum ExtensionActionRunResult: UInt32, Sendable {
    /// action.onClicked dispatched, or a blocked action ran.
    case handled = 0
    /// A popup registry tab was created.
    case popup
    /// A side-panel action (openPanelOnActionClick): the shell toggles the
    /// extension's side panel (ABI 1.47; before it nothing is shown).
    case sidePanel
}

// MARK: - Prompts (ABI 1.32)

public enum ExtensionPromptKind: Equatable, Sendable {
    case install, reEnable, permissions, external, remote, repair, request, parentApproval, uninstall
    case other(UInt32)

    /// Chromium `InstallPromptData::PromptType`, or 100 for uninstall.
    public init(rawValue: UInt32) {
        switch rawValue {
        case 0: self = .install
        case 3: self = .reEnable
        case 4: self = .permissions
        case 5: self = .external
        case 8: self = .remote
        case 9: self = .repair
        case 13, 14: self = .request
        case 15: self = .parentApproval
        case 100: self = .uninstall
        default: self = .other(rawValue)
        }
    }
}

public enum ExtensionPromptPhase: UInt32, Sendable {
    case request = 0, cancelled, installed, failed
}

/// `ReArcExtensionPromptRespond` action.
public enum ExtensionPromptAction: UInt32, Sendable {
    case accept = 0, cancel
}

/// An install, re-enable, permission or uninstall confirmation. Titles and
/// labels are Chromium's localized strings; fallbacks cover an engine that
/// sent none.
public struct ExtensionPromptRequest: Identifiable, Equatable, Sendable {
    public var id: UInt64
    /// The registry tab the prompt is parented to; 0 for none.
    public var tabID: UInt64
    public var kind: ExtensionPromptKind
    public var extensionID: String
    public var name: String
    public var title: String
    public var acceptLabel: String
    public var cancelLabel: String
    public var permissions: [String]
    public var triggeringExtension: String
    public var iconPNG: Data?

    public init(
        id: UInt64, tabID: UInt64 = 0, kind: ExtensionPromptKind, extensionID: String, name: String,
        title: String = "", acceptLabel: String = "", cancelLabel: String = "", permissions: [String] = [],
        triggeringExtension: String = "", iconPNG: Data? = nil
    ) {
        self.id = id
        self.tabID = tabID
        self.kind = kind
        self.extensionID = extensionID
        self.name = name
        self.title = title
        self.acceptLabel = acceptLabel
        self.cancelLabel = cancelLabel
        self.permissions = permissions
        self.triggeringExtension = triggeringExtension
        self.iconPNG = iconPNG
    }

    private var quotedName: String { name.isEmpty ? "this extension" : "“\(name)”" }

    public var displayTitle: String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        switch kind {
        case .uninstall: return "Remove \(quotedName)?"
        case .reEnable: return "Turn \(quotedName) back on?"
        case .permissions: return "\(quotedName) needs new permissions"
        case .repair: return "Repair \(quotedName)?"
        default: return "Add \(quotedName)?"
        }
    }

    public var displayAcceptLabel: String {
        if !acceptLabel.isEmpty { return acceptLabel }
        switch kind {
        case .uninstall: return "Remove"
        case .reEnable: return "Turn On"
        case .permissions: return "Accept Permissions"
        case .repair: return "Repair"
        default: return "Add Extension"
        }
    }

    public var displayCancelLabel: String { cancelLabel.isEmpty ? "Cancel" : cancelLabel }

    /// Every prompt needs an explicit click: Return cancels, as Chrome's install
    /// dialog does (security RC-0.1.0-544 F-10).
    public var cancelIsDefault: Bool { true }

    public var isDestructive: Bool { kind == .uninstall }

    /// The alert's body: what the extension can do, one bullet per line.
    public var informativeText: String {
        var lines: [String] = []
        if kind == .uninstall, !triggeringExtension.isEmpty {
            lines.append("“\(triggeringExtension)” wants to remove it.")
        }
        let permissions = permissions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !permissions.isEmpty {
            lines.append("It can:")
            lines += permissions.map { "• \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// Phase 2 / 3 notifications (no reply).
public struct ExtensionInstallNotice: Equatable, Sendable {
    public var extensionID: String
    public var name: String
    public var succeeded: Bool
    public var error: String

    public init(extensionID: String, name: String, succeeded: Bool, error: String = "") {
        self.extensionID = extensionID
        self.name = name
        self.succeeded = succeeded
        self.error = error
    }

    public var message: String {
        let name = name.isEmpty ? "the extension" : "“\(name)”"
        if succeeded { return "Added \(name)" }
        return error.isEmpty ? "Couldn't add \(name)" : "Couldn't add \(name): \(error)"
    }
}

// MARK: - Logical extension windows (ABI 1.36)

/// One tab's extension-window state (`ReArcTabSetExtensionWindow`).
public struct ExtensionWindowState: Hashable, Sendable {
    /// Positive shell window ID; 0 means no membership.
    public var windowID: Int32
    public var active: Bool
    public var focused: Bool

    public init(windowID: Int32, active: Bool, focused: Bool) {
        self.windowID = windowID
        self.active = active
        self.focused = focused
    }

    public static let none = ExtensionWindowState(windowID: 0, active: false, focused: false)
}

/// What one logical window holds. Arc has no tab strips: each space is a
/// window to extensions (one profile, one selected tab), and so is each
/// Little Arc window. The space shown in the key browser window is focused.
public struct ExtensionLogicalWindow: Equatable, Sendable {
    public var key: UUID
    /// Bridge tab IDs in sidebar order.
    public var tabs: [UInt64]
    public var activeTab: UInt64?
    public var focused: Bool

    public init(key: UUID, tabs: [UInt64], activeTab: UInt64?, focused: Bool) {
        self.key = key
        self.tabs = tabs
        self.activeTab = activeTab
        self.focused = focused
    }
}

public struct ExtensionWindowCall: Equatable, Sendable {
    public var tab: UInt64
    public var state: ExtensionWindowState

    public init(tab: UInt64, state: ExtensionWindowState) {
        self.tab = tab
        self.state = state
    }
}

/// Keeps the engine's logical window model in step with the shell's. Window
/// IDs are stable per space. `plan` returns only the calls that change
/// something, ordered so the engine's side effects (selecting a tab clears
/// the other active flags of its window; focusing a window unfocuses the
/// rest; focused=false clears the focus of a focused window) leave exactly
/// the desired state with the fewest calls. `reported` mirrors the engine
/// after each call.
public struct ExtensionWindowReporter: Sendable {
    private var windowIDs: [UUID: Int32] = [:]
    private var nextWindowID: Int32 = 1
    public private(set) var reported: [UInt64: ExtensionWindowState] = [:]

    public init() {}

    public mutating func windowID(for key: UUID) -> Int32 {
        if let id = windowIDs[key] { return id }
        let id = nextWindowID
        nextWindowID = nextWindowID == Int32.max ? 1 : nextWindowID + 1
        windowIDs[key] = id
        return id
    }

    public func key(forWindowID id: Int32) -> UUID? {
        windowIDs.first { $0.value == id }?.key
    }

    /// Each tab once (the first window listing it wins), one focused window.
    public mutating func desiredStates(_ windows: [ExtensionLogicalWindow]) -> [UInt64: ExtensionWindowState] {
        var states: [UInt64: ExtensionWindowState] = [:]
        var focusTaken = false
        for window in windows {
            let id = windowID(for: window.key)
            let focused = window.focused && !focusTaken
            if focused { focusTaken = true }
            for tab in window.tabs where tab != 0 && states[tab] == nil {
                states[tab] = ExtensionWindowState(windowID: id, active: tab == window.activeTab, focused: focused)
            }
        }
        return states
    }

    public mutating func plan(_ windows: [ExtensionLogicalWindow]) -> [ExtensionWindowCall] {
        let desired = desiredStates(windows)
        var calls: [ExtensionWindowCall] = []
        func send(_ tab: UInt64, _ state: ExtensionWindowState) {
            guard (reported[tab] ?? .none) != state else { return }
            calls.append(ExtensionWindowCall(tab: tab, state: state))
            apply(calls[calls.count - 1])
        }
        for tab in reported.keys.sorted() where desired[tab] == nil {
            send(tab, .none)
        }
        // Unfocused windows first, the focused one last; each window's active tab first.
        for window in windows.filter({ !$0.focused }) + windows.filter(\.focused) {
            let tabs = window.tabs.filter { desired[$0]?.windowID == windowIDs[window.key] }
            for tab in tabs where desired[tab]?.active == true { send(tab, desired[tab]!) }
            for tab in tabs where desired[tab]?.active == false { send(tab, desired[tab]!) }
        }
        return calls
    }

    /// The engine's effect of one accepted call.
    public mutating func apply(_ call: ExtensionWindowCall) {
        let state = call.state
        let windowWasFocused = reported.values.contains { $0.windowID == state.windowID && $0.focused }
        guard state.windowID != 0 else {
            reported[call.tab] = nil
            return
        }
        reported[call.tab] = state
        for (tab, other) in reported where tab != call.tab {
            var updated = other
            if state.active, other.windowID == state.windowID { updated.active = false }
            if state.focused {
                updated.focused = other.windowID == state.windowID
            } else if windowWasFocused, other.windowID == state.windowID {
                updated.focused = false
            }
            if updated != other { reported[tab] = updated }
        }
    }

    /// The engine dropped the tab (closed) or refused the call: report it again next time.
    public mutating func forget(tab: UInt64) {
        reported[tab] = nil
    }
}

// MARK: - Extension tab requests (ABI 1.36)

public enum ExtensionTabRequestKind: UInt32, Sendable {
    case createTab = 0, createWindow, optionsPage, activate
}

/// An extension's tabs.create / windows.create / openOptionsPage / tabs.update(active).
public struct ExtensionTabRequest: Identifiable, Equatable, Sendable {
    public var id: UInt64
    public var profileID: UInt64
    /// Bridge ID of the tab to activate (kind activate).
    public var tabID: UInt64
    public var openerTabID: UInt64
    /// 0: the current space; positive: an explicit logical window.
    public var windowID: Int32
    public var kind: ExtensionTabRequestKind
    public var isWithdrawal: Bool
    public var active: Bool
    public var url: String
    public var extensionID: String

    public init(
        id: UInt64, profileID: UInt64, tabID: UInt64 = 0, openerTabID: UInt64 = 0, windowID: Int32 = 0,
        kind: ExtensionTabRequestKind, isWithdrawal: Bool = false, active: Bool = true, url: String = "", extensionID: String = ""
    ) {
        self.id = id
        self.profileID = profileID
        self.tabID = tabID
        self.openerTabID = openerTabID
        self.windowID = windowID
        self.kind = kind
        self.isWithdrawal = isWithdrawal
        self.active = active
        self.url = url
        self.extensionID = extensionID
    }
}

/// Where the shell answers an extension tab request.
public enum ExtensionTabPlacement: Equatable, Sendable {
    /// A new blank tab in this space (the engine then loads the extension's URL).
    case newTab(space: UUID)
    /// A new Today tab at the bottom of this space, not selected, whatever
    /// the request asked: an extension an import is installing quietly
    /// (`QuietExtensionInstalls`) opening its welcome page.
    case backgroundTab(space: UUID)
    /// windows.create: a Little Arc window, its own logical window.
    case littleArc
    /// Select this existing tab and answer with it.
    case activate(tab: UInt64)
    /// Answer 0; the extension's Promise fails.
    case decline(String)

    /// `currentSpace` is the key window's space; `windowSpace` the space a
    /// positive window ID names (nil when it names none or a Little Arc);
    /// `profileMatches` says whether a space lives in the request's profile.
    public static func resolve(
        _ request: ExtensionTabRequest,
        currentSpace: UUID?,
        windowSpace: UUID?,
        spaces: [UUID],
        quiet: Bool = false,
        profileMatches: (UUID) -> Bool
    ) -> ExtensionTabPlacement {
        if quiet, request.kind == .createTab || request.kind == .optionsPage {
            let placed = resolve(request, currentSpace: currentSpace, windowSpace: windowSpace, spaces: spaces, profileMatches: profileMatches)
            if case .newTab(let space) = placed { return .backgroundTab(space: space) }
            return placed
        }
        switch request.kind {
        case .activate:
            return request.tabID == 0 ? .decline("no tab to activate") : .activate(tab: request.tabID)
        case .createWindow:
            return .littleArc
        case .createTab, .optionsPage:
            if request.windowID > 0 {
                guard let space = windowSpace else { return .decline("window \(request.windowID) is not a space") }
                return profileMatches(space) ? .newTab(space: space) : .decline("window \(request.windowID) is in another profile")
            }
            if let current = currentSpace, profileMatches(current) { return .newTab(space: current) }
            // The current space is another profile's: the first space of the extension's profile.
            if let space = spaces.first(where: profileMatches) { return .newTab(space: space) }
            return .decline("no space in the extension's profile")
        }
    }
}

// MARK: - Modified link opens (ABI 1.39)

/// Chromium's disposition for a gestured HTTP(S) link open the engine hands
/// to the host. At this pin ⌘-click and middle-click are background, ⇧⌘-click
/// foreground, ⇧-click a new window and ⌥⌘-click a split.
public enum LinkOpenDisposition: UInt32, Sendable {
    case foregroundTab = 1, backgroundTab = 2, newWindow = 4, splitView = 5
}

/// Where the sidebar puts a link opened with a modifier or the middle button.
public enum LinkOpenPlacement: Equatable, Sendable {
    /// A today tab in the source's space, not selected (⌘-click, middle-click).
    case backgroundTab
    /// A today tab in the source's space, selected (⇧⌘-click).
    case foregroundTab
    /// A Little Arc window, Arc's small window for one page.
    case littleArc
    /// A new pane split with this sidebar tab.
    case split(with: UUID)
    case decline(String)

    /// ⌥⌘ held at the click (`LittleArcChrome.clickOpensLittleArc`) keeps
    /// wave 26's rule, which WebKit and target=_blank links follow too:
    /// Little Arc, whatever the engine's disposition. A split needs a
    /// sidebar tab to split with; without one it opens as a new tab.
    public static func resolve(disposition raw: UInt32, littleArcKeysHeld: Bool, sourceTab: UUID?) -> LinkOpenPlacement {
        guard let disposition = LinkOpenDisposition(rawValue: raw) else { return .decline("unsupported disposition \(raw)") }
        if littleArcKeysHeld { return .littleArc }
        switch disposition {
        case .backgroundTab: return .backgroundTab
        case .foregroundTab: return .foregroundTab
        case .newWindow: return .littleArc
        case .splitView: return sourceTab.map { .split(with: $0) } ?? .foregroundTab
        }
    }

    /// Dispositions 1, 4 and 5 must answer with a tab that is active in its window.
    public var isActive: Bool { self != .backgroundTab }
}

/// Extensions an import's bulk install is adding. Like Chrome's installs
/// from sync they install without asking, and the pages they open from
/// `runtime.onInstalled` (welcome, "getting started") must not take the
/// window: while an extension installs, and for `grace` after, its new tabs
/// open in the background (`ExtensionTabPlacement.backgroundTab`).
public struct QuietExtensionInstalls: Equatable, Sendable {
    /// `onInstalled` runs once the extension's service worker starts, a
    /// moment after the engine reports it installed.
    public static let grace: TimeInterval = 120
    /// The longest a store download may run before it is treated as done.
    public static let installing: TimeInterval = 30 * 60

    private var until: [String: Date] = [:]

    public init() {}

    public mutating func begin(_ ids: [String], at now: Date = Date()) {
        for id in ids { until[id] = now.addingTimeInterval(Self.installing) }
    }

    public mutating func finished(_ id: String, at now: Date = Date()) {
        until[id] = now.addingTimeInterval(Self.grace)
    }

    public func isQuiet(_ id: String, at now: Date = Date()) -> Bool {
        guard !id.isEmpty, let end = until[id] else { return false }
        return now < end
    }
}
