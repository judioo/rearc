import Foundation

/// Pure command-bar result ranking and filtering (no UI imports).
public enum CommandBarSearch {

    public enum Mode: Equatable {
        case blended
        case commandsOnly
    }

    public enum ResultKind: Equatable {
        case openTab
        case openURL
        /// A page from visit history (the shell's `VisitHistory`, or the engine's on Chromium).
        case history
        /// A search provider's autocomplete suggestion.
        case suggestion
        case search
        case command
    }

    public struct Result: Equatable, Identifiable {
        public var id: String
        public var kind: ResultKind
        public var title: String
        public var subtitle: String?
        public var tabID: Tab.ID?
        public var spaceID: Space.ID?
        public var destinationURL: URL?
        public var commandAction: AppCommandAction?
        public var commandID: String?
        public var menuCommandID: String?
        public var keyEquivalent: String?
        /// The site search (`SiteSearchEngine.id`) whose template made `destinationURL`.
        public var siteSearchID: String?

        public init(
            id: String,
            kind: ResultKind,
            title: String,
            subtitle: String? = nil,
            tabID: Tab.ID? = nil,
            spaceID: Space.ID? = nil,
            destinationURL: URL? = nil,
            commandAction: AppCommandAction? = nil,
            commandID: String? = nil,
            menuCommandID: String? = nil,
            keyEquivalent: String? = nil,
            siteSearchID: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.tabID = tabID
            self.spaceID = spaceID
            self.destinationURL = destinationURL
            self.commandAction = commandAction
            self.commandID = commandID
            self.menuCommandID = menuCommandID
            self.keyEquivalent = keyEquivalent
            self.siteSearchID = siteSearchID
        }
    }

    public static func parseMode(_ rawQuery: String) -> (mode: Mode, needle: String) {
        if rawQuery.hasPrefix(">") {
            let rest = String(rawQuery.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            return (.commandsOnly, rest.lowercased())
        }
        let needle = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (.blended, needle)
    }

    /// Most history rows shown for one query.
    public static let historyLimit = 5

    /// Builds ranked results: open tabs first, then visit history (pages not
    /// already open), then the provider's suggestions, then commands, then the
    /// search fallback. A query that is itself an address puts its "Open" row
    /// ahead of history, so Enter goes where the user typed. `live` results
    /// for this exact text replace the shell's history and URL-vs-search
    /// guess (Chromium) and add suggestions; for other text they are ignored.
    /// The prepared indexes (`tabIndex`, `commandIndex`, `menuIndex`) and
    /// `liveHistory` (`live`'s history as a store) are built here when not
    /// given; the shell keeps them across keystrokes.
    public static func results(
        for query: String,
        in store: SidebarStore,
        isSidebarVisible: Bool = true,
        peekURL: URL? = nil,
        focusedLittleArcID: LittleArcWindow.ID? = nil,
        mediaByTab: [Tab.ID: WebMediaState] = [:],
        tabMuteModel: TabMediaMuteModel = TabMediaMuteModel(),
        navigationSchemes: NavigationURLPolicy.EngineSchemes = [],
        history: VisitHistory = VisitHistory(),
        historyIndex: VisitHistorySearchIndex? = nil,
        liveHistory: VisitHistory? = nil,
        commandCatalog: [AppCommand]? = nil,
        menuCommands: [MenuCommand] = [],
        tabIndex: TabIndex? = nil,
        commandIndex: CommandIndex? = nil,
        menuIndex: MenuCommandSearch.Index? = nil,
        externalLinkDestination: ExternalLinkDestination = .littleArc,
        live: CommandBarLiveResults? = nil,
        searchProvider: SearchProvider = .duckDuckGo,
        inlineCompletion: String? = nil,
        now: Date = Date()
    ) -> [Result] {
        let (mode, needle) = parseMode(query)
        let commands = commandIndex ?? CommandIndex(catalog: commandCatalog ?? AppCommandRegistry.all(in: CommandBarContext(
            store: store,
            isSidebarVisible: isSidebarVisible,
            closedTabStack: store.closedTabStack,
            peekURL: peekURL,
            focusedLittleArcID: focusedLittleArcID,
            mediaByTab: mediaByTab,
            tabMuteModel: tabMuteModel,
            navigationSchemes: navigationSchemes,
            externalLinkDestination: externalLinkDestination
        )))
        let menuMatches = (menuIndex ?? MenuCommandSearch.Index(menuCommands, registered: commands.catalog)).matches(query: needle)
        let menus = menuMatches.map {
            Result(id: "menu-\($0.id)", kind: .command, title: $0.title, subtitle: $0.path,
                   menuCommandID: $0.id, keyEquivalent: $0.keyEquivalent)
        }
        switch mode {
        case .commandsOnly:
            return commandResults(matching: needle, index: commands, store: store, allowEmpty: true) + menus
        case .blended:
            guard !needle.isEmpty else { return [] }
            let index = tabIndex ?? TabIndex(store: store)
            let ranked = index.ranked(needle, activeSpaceID: store.activeSpaceID)
            var output: [Result] = []
            // Rows already listed, by page and by title on a host (Arc
            // `dedupByTitleAndHostList`, for every host here).
            var shown: Set<String> = []
            var titles: Set<String> = []
            func isNew(_ url: URL?, title: String) -> Bool {
                let key = url.flatMap(VisitHistory.key(for:))
                if let key, shown.contains(key) { return false }
                let named = Self.titleKey(title, url)
                if let named, titles.contains(named) { return false }
                if let key { shown.insert(key) }
                if let named { titles.insert(named) }
                return true
            }
            // The inline-completed domain is listed before any tab on another
            // site, so Return goes where the field shows.
            let completed = inlineCompletion.flatMap { URL(string: "https://\($0)/") }
            let completedHost = completed.flatMap { Self.plainHost($0) }
            let firstTabs = ranked.first.filter { completedHost == nil || Self.plainHost($0.tab.url) == completedHost }
            let laterFirst = ranked.first.filter { completedHost != nil && Self.plainHost($0.tab.url) != completedHost }
            for entry in firstTabs.prefix(tabLimit) where isNew(entry.tab.url, title: entry.tab.displayTitle) {
                output.append(TabIndex.row(entry))
            }
            if let completed, let inlineCompletion, !firstTabs.contains(where: { Self.plainHost($0.tab.url) == completedHost }),
               isNew(completed, title: inlineCompletion) {
                output.append(Result(
                    id: "inline-\(inlineCompletion)",
                    kind: .openURL,
                    title: inlineCompletion,
                    subtitle: completed.absoluteString,
                    destinationURL: completed
                ))
            }
            for entry in laterFirst.prefix(tabLimit) where isNew(entry.tab.url, title: entry.tab.displayTitle) {
                output.append(TabIndex.row(entry))
            }
            let current = live.flatMap { $0.applies(to: query) ? $0 : nil }
            let resolved: URL?
            let direct: URL?
            switch current?.classification {
            case .url(let url) where NavigationURLPolicy.allows(url, engine: navigationSchemes):
                resolved = url
                direct = url
            case .search(let url):
                resolved = url
                direct = nil
            default:
                resolved = URLEntry.resolve(query, engine: navigationSchemes, provider: searchProvider)
                direct = resolved.flatMap { looksLikeDirectNavigation(query) ? $0 : nil }
            }
            if let url = direct, url.host() != completed?.host(), isNew(url, title: url.host() ?? url.absoluteString) {
                output.append(Result(
                    id: "url-\(url.absoluteString)",
                    kind: .openURL,
                    title: "Open \(url.host() ?? url.absoluteString)",
                    subtitle: url.absoluteString,
                    destinationURL: url
                ))
            }
            // A plain search for the typed text comes before pages (Arc's second row).
            if direct == nil, let searchURL = resolved {
                output.append(Result(
                    id: "search-\(searchURL.absoluteString)",
                    kind: .search,
                    title: query.trimmingCharacters(in: .whitespacesAndNewlines),
                    subtitle: searchURL.host(),
                    destinationURL: searchURL
                ))
            }
            // Pages already open as tabs (or typed exactly) are not repeated as history.
            let allTabs = ranked.first + ranked.later
            let historyExcluded = shown.union(allTabs.compactMap(\.historyKey))
            let historySource = current?.history.map { liveHistory ?? VisitHistory(records: $0) } ?? history
            let historyRows = historyResults(for: needle, in: historySource,
                                             index: current?.history == nil ? historyIndex : nil, now: now,
                                             excluding: historyExcluded, limit: historyLimit + 3)
            var historyShown = 0
            for row in historyRows where historyShown < historyLimit && isNew(row.destinationURL, title: row.title) {
                output.append(row)
                historyShown += 1
            }
            // Weaker tab matches (an address that merely contains the text,
            // a bookmark-import space) only after history, and few.
            var later = 0
            for entry in ranked.first.dropFirst(tabLimit) + ranked.later where later < laterTabLimit {
                guard isNew(entry.tab.url, title: entry.tab.displayTitle) else { continue }
                output.append(TabIndex.row(entry))
                later += 1
            }
            output.append(contentsOf: suggestionResults(current?.suggestions ?? [], query: query, excluding: shown, fallback: resolved))
            output.append(contentsOf: commandResults(matching: needle, index: commands, store: store, allowEmpty: false))
            output.append(contentsOf: menus)
            return output
        }
    }

    /// Most open tabs listed first; the rest of the strong matches wait until after history.
    public static let tabLimit = 3
    /// Most weaker tab matches listed.
    public static let laterTabLimit = 2

    /// A row's title on its host: two rows with both equal are one page to the reader.
    static func titleKey(_ title: String, _ url: URL?) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, let host = url.flatMap(plainHost) else { return nil }
        return trimmed + "\n" + host
    }

    static func plainHost(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Up to `limit` recent tabs of the active profile for an empty ⌘T bar
    /// (Arc lists about five, "Switch to Tab"), not the one on screen.
    public static func recentTabResults(in store: SidebarStore, limit: Int = 5) -> [Result] {
        let selected = store.selectedTabID
        return store.recentTabSwitcherItems(limit: limit + 1)
            .filter { $0.id != selected }
            .prefix(limit)
            .map { item in
                Result(id: "tab-\(item.id.uuidString)", kind: .openTab, title: item.title, subtitle: item.spaceName,
                       tabID: item.id, spaceID: store.spaceContaining(tabID: item.id), destinationURL: item.url)
            }
    }

    // MARK: - History

    private static func historyResults(
        for needle: String,
        in history: VisitHistory,
        index: VisitHistorySearchIndex?,
        now: Date,
        excluding shown: Set<String>,
        limit: Int = historyLimit
    ) -> [Result] {
        let matches = (index ?? history.searchIndex).matches(for: needle, now: now, limit: limit, excluding: shown)
        return matches.map { match in
            let record = match.record
            return Result(
                id: "history-\(record.url.absoluteString)",
                kind: .history,
                title: record.displayTitle,
                subtitle: VisitHistory.strippedAddress(record.url),
                destinationURL: record.url
            )
        }
    }

    // MARK: - Suggestions

    /// Provider suggestions, minus the typed text itself (the search row
    /// covers it) and pages already listed.
    private static func suggestionResults(
        _ suggestions: [SearchSuggestion],
        query: String,
        excluding shown: Set<String>,
        fallback: URL?
    ) -> [Result] {
        let typed = CommandBarLiveResults.normalized(query)
        var seen: Set<String> = [typed]
        var rows: [Result] = []
        for suggestion in suggestions {
            let text = CommandBarLiveResults.normalized(suggestion.text)
            guard !text.isEmpty, seen.insert(text).inserted, suggestion.destinationURL != fallback else { continue }
            if let key = VisitHistory.key(for: suggestion.destinationURL), shown.contains(key) { continue }
            rows.append(Result(
                id: "suggest-\(suggestion.destinationURL.absoluteString)",
                kind: .suggestion,
                title: suggestion.text,
                subtitle: suggestion.destinationURL.host(),
                destinationURL: suggestion.destinationURL
            ))
            if rows.count == suggestionLimit { break }
        }
        return rows
    }

    // MARK: - Commands

    private struct RankedCommand {
        var command: AppCommand
        var score: Int
        var titleLength: Int
    }

    private static func commandResults(
        matching needle: String,
        index: CommandIndex,
        store: SidebarStore,
        allowEmpty: Bool
    ) -> [Result] {
        var ranked: [RankedCommand] = []
        let prepared = TypeTravelFuzzyMatch.Needle(needle)
        let needleLength = needle.count

        for entry in index.entries {
            let command = entry.command
            if needle.isEmpty {
                guard allowEmpty else { continue }
                let bump = store.commandBarUsageBumps[command.id, default: 0]
                ranked.append(RankedCommand(command: command, score: bump * 100, titleLength: command.title.count))
                continue
            }
            guard needleLength >= command.minQueryLength else { continue }
            guard let match = TypeTravelFuzzyMatch.bestScore(prepared, title: entry.title, keywords: entry.keywords) else { continue }
            let bump = store.commandBarUsageBumps[command.id, default: 0]
            let score = match.score + bump * 25
            ranked.append(RankedCommand(command: command, score: score, titleLength: match.haystackLength))
        }

        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.titleLength < rhs.titleLength
        }

        return ranked.map { item in
            Result(
                id: "cmd-\(item.command.id)",
                kind: .command,
                title: item.command.title,
                subtitle: "Command",
                commandAction: item.command.action,
                commandID: item.command.id
            )
        }
    }

    static func tabs(in entry: SidebarEntry) -> [Tab] {
        switch entry {
        case .tab(let tab): return [tab]
        case .split(let split): return split.tabs
        case .easel: return []
        case .folder(let folder): return SidebarTree.tabs(folder.children)
        }
    }

    private static func looksLikeDirectNavigation(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") { return false }
        if trimmed.contains(".") { return true }
        if let url = URL(string: trimmed), url.scheme != nil { return true }
        return false
    }
}
