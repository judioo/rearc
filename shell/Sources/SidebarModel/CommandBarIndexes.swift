import Foundation

// Prepared indexes for the command bar's local results. The shell builds them
// when their source changes (the sidebar, the command catalog, the menu
// snapshot), so a keystroke only compares prepared text. Each ranks exactly as
// the unprepared code in `CommandBarSearch` did (CommandBarIndexTests).

extension CommandBarSearch {

    /// Open tabs in rank order (favorites, then each space's pinned, then its
    /// Today tabs newest first), with their text lowercased.
    public struct TabIndex {
        struct Entry {
            var tab: Tab
            var spaceID: Space.ID?
            var spaceName: String?
            var displayTitle: PreparedText
            var title: PreparedText
            var url: PreparedText
            var host: PreparedText?
            /// `VisitHistory.key(for: tab.url)`: an open page is not repeated as history.
            var historyKey: String?

            func matches(_ needle: PreparedText.Needle) -> Bool {
                displayTitle.contains(needle) || title.contains(needle) || url.contains(needle)
                    || host?.contains(needle) == true
            }
        }

        let entries: [Entry]

        public init(store: SidebarStore) {
            var ranked: [(entry: Entry, tier: Int, recency: Int)] = []
            func add(_ tab: Tab, _ space: Space?, tier: Int, recency: Int) {
                ranked.append((Entry(tab: tab, spaceID: space?.id, spaceName: space?.name,
                                     displayTitle: PreparedText(tab.displayTitle.lowercased()),
                                     title: PreparedText(tab.title.lowercased()),
                                     url: PreparedText(tab.url.absoluteString.lowercased()),
                                     host: tab.url.host().map { PreparedText($0.lowercased()) },
                                     historyKey: VisitHistory.key(for: tab.url)),
                               tier, recency))
            }
            for (index, tab) in store.favorites.enumerated() { add(tab, nil, tier: 0, recency: index) }
            for space in store.spaces {
                let content = store.content(for: space.id)
                for (index, entry) in content.pinned.enumerated() {
                    for tab in CommandBarSearch.tabs(in: entry) { add(tab, space, tier: 1, recency: index) }
                }
                for (index, entry) in content.today.enumerated() {
                    for tab in CommandBarSearch.tabs(in: entry) { add(tab, space, tier: 2, recency: -index) }
                }
            }
            // The same stable sort the unprepared ranking ran on the matches:
            // filtering a stably sorted list keeps the order sorting the
            // filtered list would give.
            ranked.sort { lhs, rhs in
                if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
                return lhs.recency > rhs.recency
            }
            entries = ranked.map(\.entry)
        }

        public var count: Int { entries.count }

        public func results(for needle: String) -> [Result] {
            Self.rows(matching(needle))
        }

        func matching(_ needle: String) -> [Entry] {
            let prepared = PreparedText.Needle(needle)
            return entries.filter { $0.matches(prepared) }
        }

        static func rows(_ entries: [Entry]) -> [Result] {
            entries.map { item in
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
    }

    /// The enabled command catalog with its titles and keywords prepared for
    /// `TypeTravelFuzzyMatch`.
    public struct CommandIndex {
        struct Entry {
            var command: AppCommand
            var title: TypeTravelFuzzyMatch.Haystack
            var keywords: [TypeTravelFuzzyMatch.Haystack]
        }

        let entries: [Entry]
        public let catalog: [AppCommand]

        public init(catalog: [AppCommand]) {
            self.catalog = catalog
            entries = catalog.map { command in
                Entry(command: command, title: TypeTravelFuzzyMatch.Haystack(command.title),
                      keywords: command.keywords.map(TypeTravelFuzzyMatch.Haystack.init))
            }
        }
    }
}

extension MenuCommandSearch {
    /// A menu snapshot filtered against the command catalog and prepared for
    /// matching: the work `matches` repeats on every query.
    public struct Index {
        struct Entry {
            var command: MenuCommand
            var title: String
            var titleCount: Int
            var dedupeKey: String
            var haystack: TypeTravelFuzzyMatch.Haystack
            var path: TypeTravelFuzzyMatch.Haystack
        }

        let entries: [Entry]
        public let commands: [MenuCommand]
        public let registered: [AppCommand]

        public init(_ commands: [MenuCommand], registered: [AppCommand]) {
            self.commands = commands
            self.registered = registered
            let registeredTitles = Set(registered.map { MenuCommandSearch.normalized($0.title) })
            entries = commands.compactMap { command in
                let title = MenuCommandSearch.normalized(command.title)
                guard command.isEnabled, command.hasAction, !title.isEmpty, !registeredTitles.contains(title) else { return nil }
                return Entry(command: command, title: title, titleCount: command.title.count,
                             dedupeKey: command.path + "\n" + command.keyEquivalent,
                             haystack: TypeTravelFuzzyMatch.Haystack(command.title),
                             path: TypeTravelFuzzyMatch.Haystack(command.path))
            }
        }

        public func matches(query: String) -> [MenuCommand] {
            let needle = MenuCommandSearch.normalized(query)
            let prepared = TypeTravelFuzzyMatch.Needle(needle)
            var seen: Set<String> = []
            var found: [(entry: Entry, score: Int)] = []
            for entry in entries {
                guard !entry.command.requiresExactQuery || needle == entry.title,
                      seen.insert(entry.dedupeKey).inserted else { continue }
                if needle.isEmpty { found.append((entry, 0)); continue }
                guard let match = TypeTravelFuzzyMatch.bestScore(prepared, title: entry.haystack, keywords: [entry.path]) else { continue }
                found.append((entry, match.score))
            }
            return found.sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.entry.titleCount != $1.entry.titleCount { return $0.entry.titleCount < $1.entry.titleCount }
                return $0.entry.command.path < $1.entry.command.path
            }.map(\.entry.command)
        }
    }
}

extension TypeTravelFuzzyMatch {
    /// A lowercased haystack as Characters, with its word boundaries found once.
    public struct Haystack: Sendable {
        let characters: [Character]
        let boundaries: [Bool]

        public init(_ text: String) {
            let characters = Array(text.lowercased())
            self.characters = characters
            boundaries = characters.indices.map { index in
                if index == 0 { return true }
                let previous = characters[index - 1]
                return !previous.isLetter && !previous.isNumber && characters[index].isLetter
            }
        }
    }

    /// A query trimmed and lowercased once per keystroke.
    public struct Needle: Sendable {
        let characters: [Character]

        public init(_ query: String) {
            characters = Array(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    /// `match(query:in:)` on prepared text: the same scores.
    public static func match(_ query: Needle, in haystack: Haystack) -> Match? {
        let q = query.characters, h = haystack.characters
        guard !q.isEmpty, !h.isEmpty, q.count <= h.count else { return nil }
        var score = 0
        var qi = 0
        var hi = 0
        var prevMatched = false
        var consecutiveRun = 0
        while qi < q.count, hi < h.count {
            if q[qi] == h[hi] {
                score += 10
                if prevMatched {
                    consecutiveRun += 1
                    score += 8 + consecutiveRun
                } else {
                    consecutiveRun = 0
                }
                if haystack.boundaries[hi] { score += 12 }
                prevMatched = true
                qi += 1
            } else {
                prevMatched = false
                consecutiveRun = 0
            }
            hi += 1
        }
        guard qi == q.count else { return nil }
        score += max(0, 40 - h.count)
        return Match(score: score, haystackLength: h.count)
    }

    /// `bestScore(query:title:keywords:)` on prepared text.
    public static func bestScore(_ query: Needle, title: Haystack, keywords: [Haystack]) -> Match? {
        var best = match(query, in: title)
        for keyword in keywords {
            guard let m = match(query, in: keyword) else { continue }
            if let current = best, m.score < current.score || (m.score == current.score && m.haystackLength >= current.haystackLength) { continue }
            best = m
        }
        return best
    }
}
