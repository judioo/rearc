import AppKit
import SidebarModel

/// Site search in the command bar (Arc scoped search, COMMAND-BAR §4.2):
/// the hint, the chip, its collapse to the field, its earlier queries and
/// Return. Entries come from the profile's imported keywords, its engines
/// and the seeded list (`SiteSearchCatalog.merged`); the chip, hint and the
/// address opened are always the entry's, never a page's.
extension BrowserViewModel {

    /// Every site search the active profile has, the person's own first.
    /// A container uses its parent's (`activeSearchProfileID`).
    var commandBarSiteSearchEngines: [SiteSearchEngine] {
        commandBarSiteSearchCache.value {
            let owner = activeSearchProfileID
            let engines = [searchProvider.siteSearchEngine].compactMap { $0 }
                + (activeSearchEngineSettings?.siteSearchEngines(for: owner) ?? [])
            return SiteSearchCatalog.merged(imported: importedSiteSearches.engines(for: owner), engine: engines)
        }
    }

    /// The site Tab would search for the typed word, shown as a hint: its
    /// keyword, a site the field completes to, or the start of its name.
    var commandBarSiteSearchSuggestion: SiteSearchEngine? {
        guard commandBarSiteSearch == nil, commandBarURLIntent == nil, !commandBarText.hasPrefix(">") else { return nil }
        return SiteSearchCatalog.match(commandBarText, in: commandBarSiteSearchEngines, completedHost: commandBarInlineCompletion)
    }

    /// The list is gone and only the field shows: a chip with nothing typed.
    var isCommandBarCollapsed: Bool {
        commandBarSiteSearch != nil && commandBarResults.isEmpty
    }

    /// Tab in the command bar (or a click on the hint): the offered site
    /// becomes a chip. Returns false (Tab keeps its usual meaning) when
    /// nothing is offered.
    @discardableResult
    func enterCommandBarSiteSearch() -> Bool {
        guard let engine = commandBarSiteSearchSuggestion else { return false }
        enterCommandBarSiteSearch(engine)
        return true
    }

    func enterCommandBarSiteSearch(_ engine: SiteSearchEngine) {
        let rows = commandBarResults
        commandBarTextBeforeSiteSearch = commandBarText
        cancelCommandBarLive()
        commandBarSiteSearch = engine
        commandBarSiteSearchQueries = SiteSearchQueries.collect(Array(visitHistory(for: store.activeProfileID).records.values),
                                                                template: engine.template)
        loadEngineSiteSearchQueries(for: engine)
        commandBarSiteSearchHeldRows = rows.isEmpty ? nil : rows
        commandBarText = ""
        commandBarHighlightedIndex = 0
        commandBarError = nil
        scheduleCommandBarCollapse()
    }

    /// Arc keeps the recoloured rows a moment, then cuts to the field.
    private func scheduleCommandBarCollapse() {
        commandBarSiteSearchHold?.cancel()
        commandBarSiteSearchHold = nil
        guard commandBarSiteSearchHeldRows != nil else {
            commandBarCollapseCount += 1
            return
        }
        guard commandBarCollapseHold > 0 else {
            collapseCommandBarSiteSearchRows()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.collapseCommandBarSiteSearchRows() }
        commandBarSiteSearchHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + commandBarCollapseHold, execute: work)
    }

    /// The held rows go and the card is the field alone.
    func collapseCommandBarSiteSearchRows() {
        commandBarSiteSearchHold?.cancel()
        commandBarSiteSearchHold = nil
        guard commandBarSiteSearchHeldRows != nil else { return }
        commandBarSiteSearchHeldRows = nil
        if commandBarText.isEmpty { commandBarCollapseCount += 1 }
    }

    /// Delete on an empty query removes the chip and restores the text.
    @discardableResult
    func exitCommandBarSiteSearch() -> Bool {
        guard commandBarSiteSearch != nil, commandBarText.isEmpty else { return false }
        let text = commandBarTextBeforeSiteSearch
        resetCommandBarSiteSearch()
        commandBarText = text
        return true
    }

    func resetCommandBarSiteSearch() {
        commandBarSiteSearchHold?.cancel()
        commandBarSiteSearchHold = nil
        commandBarSiteSearch = nil
        commandBarSiteSearchHeldRows = nil
        commandBarSiteSearchQueries = []
        commandBarTextBeforeSiteSearch = ""
    }

    /// The engine's history pages at the site join the shell's (Chromium's
    /// HistoryService, which Clear Browsing Data clears). A page in both counts once.
    private func loadEngineSiteSearchQueries(for engine: SiteSearchEngine) {
        let profileID = store.activeProfileID
        commandBarServices.siteSearchHistory(host: engine.displayHost, profileID: profileID) { [weak self] records in
            guard let self, !records.isEmpty, self.commandBarSiteSearch?.id == engine.id,
                  self.store.activeProfileID == profileID else { return }
            var history = self.visitHistory(for: profileID)
            history.merge(records)
            self.commandBarSiteSearchQueries = SiteSearchQueries.collect(Array(history.records.values), template: engine.template)
        }
    }

    /// The best earlier query the typed text begins (none after a deletion).
    var commandBarSiteSearchCompletion: String? {
        guard commandBarSiteSearch != nil, !commandBarSuppressesInlineCompletion else { return nil }
        return SiteSearchQueries.completion(for: commandBarText, in: commandBarSiteSearchQueries)
    }

    /// The default engine's own suggestions for the chip's text, when the
    /// chip is that engine (the lookup the plain bar makes anyway).
    var commandBarSiteSearchSuggestions: [SearchSuggestion] {
        guard commandBarSiteSearch?.suggestTemplate != nil, let live = commandBarLive, live.applies(to: commandBarText) else { return [] }
        return live.suggestions
    }

    /// The last engine answer, for the text typed since, while its own is pending.
    var commandBarCarriedLive: CommandBarLiveResults? {
        guard let carry = commandBarLiveCarry, !commandBarText.isEmpty else { return nil }
        let typed = commandBarText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CommandBarLiveResults(
            query: commandBarText,
            history: carry.history,
            suggestions: carry.suggestions.filter { $0.text.lowercased().hasPrefix(typed) }
        )
    }

    /// Return with a chip: the highlighted row (the query, completed as the
    /// field shows it, or an earlier one), opened from the entry's own
    /// template where a plain search would open; nothing typed opens the site.
    func submitCommandBarSiteSearch(route: CommandBarRoute) {
        guard let engine = commandBarSiteSearch else { return }
        let url: URL?
        if commandBarText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            url = engine.url(for: "")
        } else {
            let rows = commandBarResults
            let index = min(max(commandBarHighlightedIndex, 0), max(rows.count - 1, 0))
            url = rows.indices.contains(index) ? rows[index].destinationURL : engine.url(for: commandBarText)
        }
        guard let url else {
            commandBarError = "This site search has no valid address"
            return
        }
        routeCommandBar(to: url, route)
    }

    /// The chip's and selected row's fill for `engine`: its own colour, else
    /// its favicon's, fitted for white text (`CommandBarInk.siteFill`).
    func commandBarSiteFill(_ engine: SiteSearchEngine, accentFill: SpaceColor, dark: Bool) -> SpaceColor {
        CommandBarInk.siteFill(engine.color ?? faviconColor(host: engine.displayHost), accentFill: accentFill, dark: dark)
    }

    /// A host's favicon colour, sampled once the icon is cached.
    func faviconColor(host: String) -> SpaceColor? {
        if let known = siteSearchFaviconColors[host] { return known }
        guard let url = URL(string: "https://\(host)/"), let image = faviconStore.image(for: url) else { return nil }
        let color = FaviconColorSampler.dominant(of: image)
        siteSearchFaviconColors[host] = .some(color)
        return color
    }

    // MARK: - Import

    /// Adds another browser profile's site searches to `profileID`'s owner.
    /// Returns how many were new.
    @discardableResult
    func importSiteSearches(_ rows: [ChromiumKeywordsReader.Row], from sourceID: String, into profileID: Profile.ID) -> Int {
        let owner = store.owningProfileID(of: profileID)
        let added = importedSiteSearches.merge(rows, from: sourceID, into: owner)
        if added > 0, let url = importedSiteSearchesURL {
            do {
                try importedSiteSearches.save(to: url)
            } catch {
                FileHandle.standardError.write(Data("[ReArc] could not save \(url.lastPathComponent): \(error.localizedDescription)\n".utf8))
            }
        }
        return added
    }
}

/// An icon's dominant colour, read from a small bitmap of it.
enum FaviconColorSampler {
    static let side = 32

    static func dominant(of image: NSImage) -> SpaceColor? {
        let side = Self.side
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // Unpremultiply: the sampler compares straight colours.
        for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] > 0 && pixels[i + 3] < 255 {
            let a = Double(pixels[i + 3]) / 255
            for c in 0 ..< 3 { pixels[i + c] = UInt8(min(255, Double(pixels[i + c]) / a)) }
        }
        return FaviconColor.dominant(rgba: pixels, width: side, height: side, bytesPerRow: side * 4)
    }
}
