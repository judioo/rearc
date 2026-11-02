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

    /// Builds ranked results. Tab matches precede commands, then URL/search fallbacks.
    public static func results(
        for query: String,
        in store: SidebarStore,
        isSidebarVisible: Bool = true,
        peekURL: URL? = nil,
        focusedLittleArcID: LittleArcWindow.ID? = nil,
        mediaByTab: [Tab.ID: WebMediaState] = [:],
        tabMuteModel: TabMediaMuteModel = TabMediaMuteModel(),
        navigationSchemes: NavigationURLPolicy.EngineSchemes = []
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
            navigationSchemes: navigationSchemes
        )

        switch mode {
        case .commandsOnly:
            return commandResults(matching: needle, context: context, store: store, allowEmpty: true)
        case .blended:
            guard !needle.isEmpty else { return [] }
            var output = tabResults(for: needle, in: store)
            output.append(contentsOf: commandResults(matching: needle, context: context, store: store, allowEmpty: false))
            if let url = URLEntry.resolve(query, engine: navigationSchemes), looksLikeDirectNavigation(query) {
                output.append(Result(
                    id: "url-\(url.absoluteString)",
                    kind: .openURL,
                    title: "Open \(url.host() ?? url.absoluteString)",
                    subtitle: url.absoluteString,
                    destinationURL: url
                ))
            } else if let searchURL = URLEntry.resolve(query, engine: navigationSchemes) {
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
                title: item.tab.title,
                subtitle: item.spaceName,
                tabID: item.tab.id,
                spaceID: item.spaceID,
                destinationURL: item.tab.url
            )
        }
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
        }
    }

    private static func matches(tab: Tab, needle: String) -> Bool {
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
