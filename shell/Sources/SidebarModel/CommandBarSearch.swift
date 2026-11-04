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

        public init(
            id: String,
            kind: ResultKind,
            title: String,
            subtitle: String? = nil,
            tabID: Tab.ID? = nil,
            spaceID: Space.ID? = nil,
            destinationURL: URL? = nil,
            commandAction: AppCommandAction? = nil,
            commandID: String? = nil
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
        externalLinkDestination: ExternalLinkDestination = .littleArc,
        live: CommandBarLiveResults? = nil,
        searchProvider: SearchProvider = .duckDuckGo,
        inlineCompletion: String? = nil,
        now: Date = Date()
    ) -> [Result] {
        let (mode, needle) = parseMode(query)
        let context = CommandBarContext(
            store: store,
            isSidebarVisible: isSidebarVisible,
            closedTabStack: store.closedTabStack,
            peekURL: peekURL,
            focusedLittleArcID: focusedLittleArcID,
            mediaByTab: mediaByTab,
            tabMuteModel: tabMuteModel,
            navigationSchemes: navigationSchemes,
            externalLinkDestination: externalLinkDestination
        )

        switch mode {
        case .commandsOnly:
            return commandResults(matching: needle, context: context, store: store, allowEmpty: true)
        case .blended:
            guard !needle.isEmpty else { return [] }
            let tabs = tabResults(for: needle, in: store)
            var output: [Result] = []
            // The inline-completed domain is the first row, so Return goes where the field shows.
            let completed = inlineCompletion.flatMap { URL(string: "https://\($0)/") }
            if let completed, let inlineCompletion {
                output.append(Result(
                    id: "inline-\(inlineCompletion)",
                    kind: .openURL,
                    title: inlineCompletion,
                    subtitle: completed.absoluteString,
                    destinationURL: completed
                ))
            }
            output.append(contentsOf: tabs)
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
            if let url = direct, url.host() != completed?.host() {
                output.append(Result(
                    id: "url-\(url.absoluteString)",
                    kind: .openURL,
                    title: "Open \(url.host() ?? url.absoluteString)",
                    subtitle: url.absoluteString,
                    destinationURL: url
                ))
            }
            // Pages already open as tabs (or typed exactly) are not repeated as history.
            var shown = Set(tabs.compactMap { $0.destinationURL.flatMap(VisitHistory.key(for:)) })
            if let completed, let key = VisitHistory.key(for: completed) { shown.insert(key) }
            if let url = direct, let key = VisitHistory.key(for: url) { shown.insert(key) }
            let historySource = current?.history.map { VisitHistory(records: $0) } ?? history
            let historyRows = historyResults(for: needle, in: historySource, now: now, excluding: shown)
            output.append(contentsOf: historyRows)
            historyRows.compactMap { $0.destinationURL.flatMap(VisitHistory.key(for:)) }.forEach { shown.insert($0) }
            output.append(contentsOf: suggestionResults(current?.suggestions ?? [], query: query, excluding: shown, fallback: resolved))
            output.append(contentsOf: commandResults(matching: needle, context: context, store: store, allowEmpty: false))
            if direct == nil, let searchURL = resolved {
                output.append(Result(
                    id: "search-\(searchURL.absoluteString)",
                    kind: .search,
                    title: "Search for \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\"",
                    subtitle: searchURL.host(),
                    destinationURL: searchURL
                ))
            }
            return output
        }
    }

    // MARK: - Tabs

    private struct RankedTab {
        var tab: Tab
        var spaceID: Space.ID?
        var spaceName: String?
        var tier: Int
        var recency: Int
    }

    private static func tabResults(for needle: String, in store: SidebarStore) -> [Result] {
        var ranked: [RankedTab] = []

        for (index, tab) in store.favorites.enumerated() {
            guard matches(tab: tab, needle: needle) else { continue }
            ranked.append(RankedTab(tab: tab, spaceID: nil, spaceName: nil, tier: 0, recency: index))
        }

        for space in store.spaces {
            let content = store.content(for: space.id)
            for (index, entry) in content.pinned.enumerated() {
                for tab in tabs(in: entry) {
                    guard matches(tab: tab, needle: needle) else { continue }
                    ranked.append(RankedTab(
                        tab: tab,
                        spaceID: space.id,
                        spaceName: space.name,
                        tier: 1,
                        recency: index
                    ))
                }
            }
            for (index, entry) in content.today.enumerated() {
                for tab in tabs(in: entry) {
                    guard matches(tab: tab, needle: needle) else { continue }
                    ranked.append(RankedTab(
                        tab: tab,
                        spaceID: space.id,
                        spaceName: space.name,
                        tier: 2,
                        recency: -index
                    ))
                }
            }
        }

        ranked.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.recency > rhs.recency
        }

        return ranked.map { item in
            Result(
                id: "tab-\(item.tab.id.uuidString)",
                kind: .openTab,
                title: item.tab.displayTitle,
                subtitle: item.spaceName,
                tabID: item.tab.id,
                spaceID: item.spaceID,
                destinationURL: item.tab.url
            )
        }
    }

    // MARK: - History

    private static func historyResults(
        for needle: String,
        in history: VisitHistory,
        now: Date,
        excluding shown: Set<String>
    ) -> [Result] {
        history.matches(for: needle, now: now, limit: historyLimit, excluding: shown).map { match in
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
        context: CommandBarContext,
        store: SidebarStore,
        allowEmpty: Bool
    ) -> [Result] {
        let catalog = AppCommandRegistry.all(in: context)
        var ranked: [RankedCommand] = []

        for command in catalog {
            if needle.isEmpty {
                guard allowEmpty else { continue }
                let bump = store.commandBarUsageBumps[command.id, default: 0]
                ranked.append(RankedCommand(command: command, score: bump * 100, titleLength: command.title.count))
                continue
            }
            guard needle.count >= command.minQueryLength else { continue }
            guard let match = TypeTravelFuzzyMatch.bestScore(
                query: needle,
                title: command.title,
                keywords: command.keywords
            ) else { continue }
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

    private static func tabs(in entry: SidebarEntry) -> [Tab] {
        switch entry {
        case .tab(let tab): return [tab]
        case .split(let split): return split.tabs
        case .easel: return []
        case .folder(let folder): return SidebarTree.tabs(folder.children)
        }
    }

    private static func matches(tab: Tab, needle: String) -> Bool {
        if tab.displayTitle.lowercased().contains(needle) { return true }
        if tab.title.lowercased().contains(needle) { return true }
        if tab.url.absoluteString.lowercased().contains(needle) { return true }
        if let host = tab.url.host()?.lowercased(), host.contains(needle) { return true }
        return false
    }

    private static func looksLikeDirectNavigation(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" ") { return false }
        if trimmed.contains(".") { return true }
        if let url = URL(string: trimmed), url.scheme != nil { return true }
        return false
    }
}
