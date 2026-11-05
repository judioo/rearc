import AppKit
import SidebarModel
import SwiftUI

/// A short confirmation at the top right of the page card (Arc's "Copied
/// Current URL" toast, ARC-RECORDING-ANALYSIS.md §6): tinted by the space's
/// theme, shortcuts drawn as keycap chips, an optional action button.
struct ShellToast: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var systemImage: String
    /// Substrings of `message` drawn as keycaps ("⌘Z").
    var keycaps: [String] = []
    var action: Action?

    enum Action: Equatable {
        /// Copied Current URL's trailing share button.
        case share(URL)
    }

    /// Arc's toasts stayed 4.6 s and 5.0 s.
    static let defaultDuration: TimeInterval = 5

    struct Segment: Equatable {
        var text: String
        var isKeycap: Bool
    }

    /// `message` split around its keycaps, in order.
    static func segments(_ message: String, keycaps: [String]) -> [Segment] {
        var segments: [Segment] = []
        var rest = Substring(message)
        while let match = keycaps.compactMap({ key in rest.range(of: key).map { (key, $0) } }).min(by: { $0.1.lowerBound < $1.1.lowerBound }) {
            if match.1.lowerBound > rest.startIndex { segments.append(Segment(text: String(rest[..<match.1.lowerBound]), isKeycap: false)) }
            segments.append(Segment(text: match.0, isKeycap: true))
            rest = rest[match.1.upperBound...]
        }
        if !rest.isEmpty { segments.append(Segment(text: String(rest), isKeycap: false)) }
        return segments
    }

    var segments: [Segment] { Self.segments(message, keycaps: keycaps) }
}

/// Engines that can read the page's selected text (Copy as Quote).
protocol PageSelectionReading: AnyObject {
    func selectedText() async -> String?
    /// ⌘J (Jump to Selection); false without a selection.
    func scrollSelectionIntoView() async -> Bool
}

/// Wave 26 sidebar activity: the Pinned section's collapse, Copy URL
/// formats with a toast, the unread dot, and each tab's loading and crashed
/// state (SIDEBAR-SPEC §3.1.3, §4.9, §4.10; RECON `ARC_SadTab`,
/// `ARC_GlowProgressLoadingIndicator`).
extension BrowserViewModel {

    // MARK: - Pinned section

    func isPinnedSectionCollapsed(spaceID: Space.ID, in window: SidebarWindowID?) -> Bool {
        pinnedSectionCollapse.isCollapsed(spaceID: spaceID, window: windowKey(window))
    }

    /// Expand/Collapse Pinned Section for a window (the key window by default).
    func setPinnedSectionCollapsed(_ collapsed: Bool, spaceID: Space.ID? = nil, in window: SidebarWindowID? = nil) {
        let target = window ?? store.keyWindowID
        let space = spaceID ?? store.focusedSpaceID(in: target)
        withAnimation(.easeInOut(duration: 0.18)) {
            pinnedSectionCollapse.setCollapsed(collapsed, spaceID: space, window: windowKey(target))
        }
    }

    func togglePinnedSection(spaceID: Space.ID? = nil, in window: SidebarWindowID? = nil) {
        let target = window ?? store.keyWindowID
        let space = spaceID ?? store.focusedSpaceID(in: target)
        setPinnedSectionCollapsed(!isPinnedSectionCollapsed(spaceID: space, in: target), spaceID: space, in: target)
    }

    /// Windows that never registered (tests, the self-test's model) share one key.
    private func windowKey(_ window: SidebarWindowID?) -> SidebarWindowID? {
        window ?? store.keyWindowID
    }

    // MARK: - Split View

    /// The split a menu command acts on: the key window's selection.
    private var commandSplit: SplitViewItem? { activeSplit(in: store.keyWindowID) }

    /// Arc `convertToHorizontalSplitView` / `convertToVerticalSplitView`.
    func flipSplitOrientation(_ splitID: SplitViewItem.ID? = nil) {
        guard let id = splitID ?? commandSplit?.id else { return }
        withAnimation(.easeInOut(duration: 0.2)) { _ = store.flipSplitOrientation(splitID: id) }
    }

    /// Expand Current Split: the focused pane alone, or back to the split.
    func toggleExpandedSplitPane(_ splitID: SplitViewItem.ID? = nil, in window: SidebarWindowID? = nil) {
        let target = window ?? store.keyWindowID
        guard let split = splitID.flatMap({ store.split(withID: $0) }) ?? activeSplit(in: target) else { return }
        withAnimation(.easeInOut(duration: 0.2)) { _ = splitMaximize.toggle(split, window: target) }
    }

    func expandedSplitPane(_ split: SplitViewItem, in window: SidebarWindowID?) -> Tab.ID? {
        splitMaximize.maximizedTab(in: split, window: window ?? store.keyWindowID)
    }

    func visibleSplitPanes(_ split: SplitViewItem, in window: SidebarWindowID?) -> [Tab] {
        splitMaximize.visibleTabs(in: split, window: window ?? store.keyWindowID)
    }

    // MARK: - + menu

    /// New Boost: a boost for the page on screen, in the editor with the
    /// element picker; without a page a boost can change, the Boosts library.
    func newBoost() {
        if let tab = store.selectedTab, BoostScopeMatcher.urlIsEligibleForBoosts(tab.url) {
            _ = executeCommand(.newBoostForSite, commandID: nil)
        } else {
            isBoostLibraryPresented = true
        }
    }

    // MARK: - Copy URL

    /// Shift+Cmd+C (plain), Option+Shift+Cmd+C (Markdown) and Copy as Quote.
    /// Quote reads the page's selection first; it falls back to the link.
    func copyURL(of tabID: Tab.ID? = nil, format: PageLinkCopyFormat) {
        guard let id = tabID ?? store.selectedTabID, let tab = store.tab(withID: id) else { return }
        let engine = engineHost.engine(forTabID: id, profileID: profileID(for: tab))
        // Arc copies the link "without any trackers".
        let (url, cleaned) = LinkCleaner.clean(engine?.currentURL ?? tab.url)
        let title = tab.customTitle ?? engine?.pageTitle ?? tab.title
        guard format == .quote, let reader = engine as? PageSelectionReading else {
            writeToPasteboard(format.text(url: url, title: title), toast: format, cleaned: cleaned, url: url)
            return
        }
        Task { @MainActor [weak self] in
            let selection = await reader.selectedText()
            self?.writeToPasteboard(format.text(url: url, title: title, selection: selection), toast: format, cleaned: cleaned, url: url)
        }
    }

    /// The last text a copy command wrote (the self-test reads it back).
    private func writeToPasteboard(_ text: String, toast format: PageLinkCopyFormat, cleaned: Bool, url: URL) {
        linkPasteboard.clearContents()
        linkPasteboard.setString(text, forType: .string)
        lastCopiedLinkText = text
        // Arc's Copied Current URL toast carries a share button (§6).
        if cleaned, format != .quote {
            showToast(PageLinkCopyFormat.cleanConfirmation, systemImage: "checkmark.shield.fill", action: .share(url))
        } else {
            showToast(format.confirmation, systemImage: format == .quote ? "quote.bubble.fill" : "link",
                      action: format == .quote ? nil : .share(url))
        }
    }

    /// Shows `message` for about 5 s. It scales in over a frame or two and
    /// out in one (§6).
    func showToast(_ message: String, systemImage: String, keycaps: [String] = [], action: ShellToast.Action? = nil,
                   duration: TimeInterval = ShellToast.defaultDuration) {
        let toast = ShellToast(message: message, systemImage: systemImage, keycaps: keycaps, action: action)
        withAnimation(ShellToast.inAnimation) { self.toast = toast }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.toast?.id == toast.id else { return }
            withAnimation(ShellToast.outAnimation) { self.toast = nil }
        }
    }

    // MARK: - Loading and crashed tabs

    /// Loading or crashed, without creating an engine for a tab that has none.
    func tabActivity(_ tabID: Tab.ID) -> TabActivity {
        guard let profileID = profileID(forTabID: tabID),
              let engine = engineHost.engine(forTabID: tabID, profileID: profileID) else { return .idle }
        return engine.activity
    }

    /// The crashed page's Reload button (and the row's menu).
    func reloadCrashedTab(_ tabID: Tab.ID) {
        guard let profileID = profileID(forTabID: tabID),
              let engine = engineHost.engine(forTabID: tabID, profileID: profileID) else { return }
        engine.reload(ignoringCache: false)
    }

    // MARK: - Unread activity

    /// Follows a sidebar tab's page title: a background change marks a pinned
    /// tab or favorite unread, and the row shows the new title.
    func observePageTitle(of engine: any WebEngine, tabID: Tab.ID) {
        let identity = ObjectIdentifier(engine)
        guard titleObservedEngines[tabID] != identity else { return }
        titleObservedEngines[tabID] = identity
        observedPageTitles[tabID] = engine.pageTitle
        trackPageTitle(of: engine, tabID: tabID, identity: identity)
    }

    private func trackPageTitle(of engine: any WebEngine, tabID: Tab.ID, identity: ObjectIdentifier) {
        withObservationTracking {
            _ = engine.pageTitle
        } onChange: { [weak self, weak engine] in
            DispatchQueue.main.async {
                guard let self, let engine, self.titleObservedEngines[tabID] == identity else { return }
                self.pageTitleChanged(engine.pageTitle, engine: engine, tabID: tabID)
                self.trackPageTitle(of: engine, tabID: tabID, identity: identity)
            }
        }
    }

    func pageTitleChanged(_ title: String?, engine: any WebEngine, tabID: Tab.ID, now: Date = Date()) {
        let previous = observedPageTitles[tabID]
        observedPageTitles[tabID] = title
        guard let tab = store.tab(withID: tabID), let kind = store.kind(of: tabID) else { return }
        if UnreadActivityPolicy.shouldMarkUnread(
            kind: kind,
            isVisible: isTabOnScreen(tabID),
            isLoading: engine.isLoading,
            secondsSinceNavigation: lastNavigationAt[tabID].map { now.timeIntervalSince($0) },
            previousTitle: previous,
            newTitle: title
        ), !tab.isUnread {
            store.setUnread(true, for: tabID)
        }
        if !engine.isLoading, let title, !title.isEmpty, title != tab.title,
           engine.currentURL.map({ $0.absoluteString == tab.url.absoluteString }) ?? false {
            store.updateTab(tabID, title: title)
        }
    }

    /// Selected in some window (a split counts when it is the selection).
    func isTabOnScreen(_ tabID: Tab.ID) -> Bool {
        let windows = Array(store.focusedSpaceByWindow.keys)
        let spaces = windows.isEmpty ? [store.activeSpaceID] : windows.map { store.focusedSpaceID(in: $0) }
        for spaceID in Set(spaces) {
            guard let selected = store.selectedItemID(inSpace: spaceID) else { continue }
            if selected == tabID { return true }
            if let split = store.split(withID: selected), split.tabs.contains(where: { $0.id == tabID }) { return true }
        }
        return false
    }
}
