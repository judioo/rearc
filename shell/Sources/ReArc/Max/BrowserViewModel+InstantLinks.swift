import SidebarModel

/// Max › Instant Links in the command bar (FEATURE-SPECS/MAX.md §6). With it
/// on, ⇧↩ on a plain web search opens the top result (the default engine's
/// own first-result address where it has one) instead of the search in
/// Little ReArc; comma-separated searches open a tab each, at most five.
/// ⇧↩ on anything else (an address, a tab, a page from history, a site
/// search chip) still opens Little ReArc, as it does with Instant Links off.
extension BrowserViewModel {
    /// The search ⇧↩ would open the top result of, or nil when ⇧↩ keeps
    /// its Little ReArc meaning.
    var instantLinksQuery: String? {
        guard isMaxFeatureOn(.instantLinks), commandBarSiteSearch == nil, commandBarURLIntent == nil,
              !commandBarText.hasPrefix(">") else { return nil }
        let typed = commandBarText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        let results = commandBarResults
        guard !results.isEmpty else {
            // No rows: what Return would open is a search, not an address.
            return URLEntry.resolve(typed, engine: engineHost.navigationSchemes, provider: searchProvider) == searchProvider.searchURL(for: typed)
                ? typed : nil
        }
        let choice = results[min(max(commandBarHighlightedIndex, 0), results.count - 1)]
        switch choice.kind {
        case .search: return typed
        case .suggestion: return choice.title
        case .openTab, .openURL, .history, .command: return nil
        }
    }

    /// ⇧↩ with Instant Links: the first search's top result where the bar
    /// would open it, the others in new tabs behind it; a capped list says so.
    func submitInstantLinks(_ query: String) {
        let (routes, plan) = InstantLinks.routes(for: query, provider: searchProvider)
        guard let first = routes.first else {
            commandBarError = "Nothing to search for"
            return
        }
        routeCommandBar(to: first.url, .current)
        let shown = store.selectedTabID
        for route in routes.dropFirst() { openInNewTab(route.url) }
        if routes.count > 1, let shown {
            store.selectTab(shown)
            loadSelectedIfNeeded()
        }
        if let message = plan.cappedMessage { showToast(message, systemImage: "arrow.up.forward.square") }
    }
}
