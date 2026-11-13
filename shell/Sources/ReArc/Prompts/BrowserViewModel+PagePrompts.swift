import AppKit
import SidebarModel

/// Where the page menu's Arc items go, and closing a tab through its page.
extension BrowserViewModel: PageLinkRouting {
    var navigationSchemes: NavigationURLPolicy.EngineSchemes { engineHost.navigationSchemes }

    /// A background Today tab in the page's space and profile (a private
    /// window's link opens another window of its private session).
    func openLinkInNewTab(_ url: URL, from prompts: PagePromptCenter) {
        openLinkTab(url, from: prompts, select: false)
    }

    /// Arc's Open Link in New Window: the link in front, then a new browser
    /// window, which shows its space's selection (the link's tab).
    func openLinkInNewWindow(_ url: URL, from prompts: PagePromptCenter) {
        openLinkTab(url, from: prompts, select: true)
        if prompts.privateSession == nil { windowPresenter?.presentBrowserWindow() }
    }

    func openBrowserWindow(from prompts: PagePromptCenter) {
        windowPresenter?.presentBrowserWindow()
    }

    /// A new private session for the page's profile; the link loads with no referrer, as Chrome's incognito open does.
    func openLinkInPrivateWindow(_ url: URL, from prompts: PagePromptCenter) {
        openPrivateWindow(session: prompts.privateSession, parentProfileID: prompts.profileID, url: url)
    }

    func openLinkInLittleArc(_ url: URL, from prompts: PagePromptCenter) {
        guard prompts.privateSession == nil else { return openLinkInNewTab(url, from: prompts) }
        openLittleArc(url: url, profileID: prompts.profileID, pageLink: true)
    }

    /// The link in a new pane next to the page (Arc "Open in Split View").
    func openLinkInNewSplit(_ url: URL, from prompts: PagePromptCenter) {
        guard let anchorID = prompts.ownerTabID, let anchor = store.tab(withID: anchorID),
              let space = store.spaceContaining(tabID: anchorID) else {
            return openLinkInNewTab(url, from: prompts)
        }
        let kind: Tab.Kind = anchor.kind == .pinned ? .pinned : .today
        let pane = store.addTab(kind: kind, title: url.host() ?? "New Tab", url: url, in: space)
        guard store.splitTab(pane.id, with: anchorID) != nil else {
            store.closeTab(pane.id)
            engineHost.remove(pane.id)
            if store.isSplitFull(joining: anchorID) { showSplitFullToast() }
            return openLinkTab(url, from: prompts, select: true)
        }
        let engine = engineHost.engine(for: pane, profileID: profileID(for: pane))
        engine.loadPageLink(url)
        loadSelectedIfNeeded()
    }

    func searchWeb(for text: String, from prompts: PagePromptCenter) {
        // A container's page searches with its parent's engine, in its own tab's session.
        let provider = commandBarServices.searchProvider(for: settingsProfileID(for: prompts.profileID ?? store.activeProfileID))
        guard let url = URLEntry.searchURL(for: text, provider: provider) else { return }
        openLinkTab(url, from: prompts, select: true)
    }

    func imageSearchProvider(for prompts: PagePromptCenter) -> SearchProvider? {
        let provider = commandBarServices.searchProvider(for: settingsProfileID(for: prompts.profileID ?? store.activeProfileID))
        return provider.searchesByImage ? provider : nil
    }

    func revealPage(of prompts: PagePromptCenter) {
        windowPresenter?.revealForPagePrompt()
        guard let id = prompts.ownerTabID, store.tab(withID: id) != nil else { return }
        if store.focusTab(id) { loadSelectedIfNeeded() }
    }

    /// chrome://settings/content/siteDetails for `origin`, in the settings tab if one is open.
    func openSiteSettings(origin: String) {
        guard BrowserInternalPage.siteSettings.isAvailable(engine: engineHost.navigationSchemes),
              let url = BrowserInternalPage.siteDetailsURL(origin: origin) else { return }
        if let existing = store.displayTabs().first(where: { BrowserInternalPage.siteSettings.isShown(by: $0.url) }) {
            store.updateTab(existing.id, title: BrowserInternalPage.siteSettings.title, url: url)
            store.focusTab(existing.id)
        } else {
            let tab = store.addTab(kind: .today, title: BrowserInternalPage.siteSettings.title, url: url)
            store.selectTab(tab.id)
        }
        loadSelectedIfNeeded()
    }

    func openSiteSettings(origin: String, from prompts: PagePromptCenter) {
        openSiteSettings(origin: origin)
    }

    private func openLinkTab(_ url: URL, from prompts: PagePromptCenter, select: Bool) {
        if let session = prompts.privateSession {
            let window = openPrivateWindow(session: session, parentProfileID: prompts.profileID)
            window.engine.loadPageLink(url)
            return
        }
        // The new tab inherits the source page's profile: its own space for a sidebar tab, a
        // space of that profile for a Little ReArc, Peek or favourite (RC-0.1.0-564 S-03).
        let owner = prompts.ownerTabID.flatMap { store.spaceContaining(tabID: $0) }
        guard let space = store.space(forNewTabIn: prompts.profileID ?? store.activeProfileID, preferring: owner) else { return }
        let tab = store.addTab(kind: .today, title: url.host() ?? "New Tab", url: url, in: space)
        let engine = engineHost.engine(for: tab, profileID: profileID(for: tab))
        configureLinkPeek(on: engine)
        engine.loadPageLink(url)
        syncBoosts(for: tab)
        if select {
            if space != store.activeSpaceID { store.selectSpace(space) }
            store.selectTab(tab.id)
            loadSelectedIfNeeded()
        }
    }

    // MARK: Closing through the page

    /// Runs `close` once the tab's page agreed to close: right away unless
    /// the engine runs beforeunload (Chromium with `javascript_dialogs`),
    /// never when the user chose Stay.
    func closeThroughPage(_ id: Tab.ID, close: @escaping () -> Void) {
        guard let tab = store.tab(withID: id),
              let page = engineHost.engine(forTabID: id, profileID: profileID(for: tab)) as? PageClosing,
              page.requestPageClose({ closed in if closed { close() } }) else {
            return close()
        }
    }

    // MARK: Site permissions (URL field indicator)

    /// Answers recorded for the page a window shows, with the scope they live in.
    func sitePermissionSummary(for engine: (any WebEngine)?) -> SitePermissionSummary? {
        guard let engine, let url = engine.currentURL, let origin = PageOrigin.of(url) else { return nil }
        let scope = engine.pagePrompts.permissionScope
        let entries = sitePermissions.entries(origin: origin, scope: scope).map { SitePermissionSummary.Row(type: $0.type, entry: $0.entry) }
        guard !entries.isEmpty else { return nil }
        return SitePermissionSummary(origin: origin, scope: scope, rows: entries)
    }

    /// Chromium keeps remembered permissions itself; the shell can only send the user to them.
    var sitePermissionsLiveInEngine: Bool {
        BrowserInternalPage.siteSettings.isAvailable(engine: engineHost.navigationSchemes)
    }
}

/// One site's recorded answers, for the URL field's permissions popover.
struct SitePermissionSummary: Equatable {
    struct Row: Equatable {
        var type: PermissionType
        var entry: SitePermissionStore.Entry
    }

    var origin: String
    var scope: String
    var rows: [Row]

    var host: String { PageOrigin.promptHost(origin) ?? origin }
    /// The indicator's icon: the most significant type answered.
    var symbol: String {
        let priority = ["camera_stream", "mic_stream", "geolocation", "notifications"]
        let keys = rows.map(\.type.key)
        return priority.first(where: keys.contains).map { PermissionType($0).symbol } ?? "slider.horizontal.3"
    }
    var anyBlocked: Bool { rows.contains { $0.entry.decision == .deny } }
}
