import Foundation

/// Max › Tidy Tabs (MAX.md §5): with more than six Today tabs, the broom
/// files them into folders by fixed rules: tabs of one site together, and
/// sites of one obvious kind (code, video, mail, news…) together. A group
/// whose tabs share a site is named after it. Pinned tabs, splits and
/// easels stay where they are, nothing closes or is archived, and Undo puts
/// every tab back where it was. ReArc's folders live in Pinned, so the
/// folders go at its end and their tabs become pinned until Undo.
public enum TidyTabs {
    /// The broom shows with more Today tabs than this (Arc's six).
    public static let threshold = 6
    /// At most this many folders; smaller groups beyond stay in Today.
    public static let maximumGroups = 6

    public struct Item: Equatable, Sendable {
        public var id: UUID
        public var title: String
        public var host: String

        public init(id: UUID, title: String, host: String) {
            self.id = id
            self.title = title
            self.host = host
        }
    }

    public struct Group: Equatable, Sendable {
        public var name: String
        /// In Today's order.
        public var members: [UUID]

        public init(name: String, members: [UUID]) {
            self.name = name
            self.members = members
        }
    }

    /// Kinds of site, by host (the registrable part) and then by title words.
    static let topics: [(name: String, hosts: [String], words: [String])] = [
        ("Code", ["github.com", "gitlab.com", "bitbucket.org", "stackoverflow.com", "stackexchange.com", "npmjs.com",
                  "pypi.org", "crates.io", "docs.rs", "developer.apple.com", "developer.mozilla.org", "swift.org"],
         ["pull request", "repository", "stack trace", "api reference"]),
        ("Video", ["youtube.com", "youtu.be", "vimeo.com", "twitch.tv", "netflix.com", "tv.apple.com", "dailymotion.com"], []),
        ("Mail & Chat", ["mail.google.com", "outlook.live.com", "outlook.office.com", "slack.com", "discord.com",
                         "web.whatsapp.com", "teams.microsoft.com", "messenger.com", "calendar.google.com"], ["inbox"]),
        ("Docs", ["docs.google.com", "drive.google.com", "sheets.google.com", "notion.so", "figma.com", "dropbox.com",
                  "icloud.com", "airtable.com", "miro.com", "linear.app"], []),
        ("News", ["nytimes.com", "bbc.co.uk", "bbc.com", "theguardian.com", "reuters.com", "cnn.com", "apnews.com",
                  "washingtonpost.com", "ft.com", "bloomberg.com", "news.ycombinator.com", "theverge.com", "economist.com"], []),
        ("Social", ["x.com", "twitter.com", "reddit.com", "linkedin.com", "facebook.com", "instagram.com", "threads.net",
                    "bsky.app", "mastodon.social", "tiktok.com"], []),
        ("Shopping", ["amazon.com", "amazon.co.uk", "amazon.de", "ebay.com", "ebay.co.uk", "etsy.com", "aliexpress.com"],
         ["cart", "checkout", "basket"]),
        ("Travel", ["booking.com", "airbnb.com", "expedia.com", "skyscanner.net", "tripadvisor.com", "maps.google.com"],
         ["flight", "flights", "hotel", "hotels"]),
        ("Recipes", ["allrecipes.com", "bbcgoodfood.com", "seriouseats.com"], ["recipe", "recipes"]),
        ("Reading", ["wikipedia.org", "medium.com", "substack.com"], []),
    ]

    /// "en.m.wikipedia.org" → "wikipedia.org"; a known longer host (mail.google.com) is kept.
    static func siteKey(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if topics.contains(where: { $0.hosts.contains(host) }) { return host }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return host }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]
        let keep = secondLevel.contains(parts[parts.count - 2]) ? 3 : 2
        return parts.suffix(keep).joined(separator: ".")
    }

    static func topic(for item: Item) -> String? {
        let key = siteKey(item.host)
        if let topic = topics.first(where: { $0.hosts.contains(key) }) { return topic.name }
        let words = Set(item.title.lowercased().split { !$0.isLetter }.map(String.init))
        let lowered = item.title.lowercased()
        return topics.first { topic in
            topic.words.contains { $0.contains(" ") ? lowered.contains($0) : words.contains($0) }
        }?.name
    }

    /// The site's name for a group: its brand, else its capitalised label.
    static func siteName(_ host: String) -> String {
        TidyTabTitles.brand(for: host) ?? TidyDownloads.siteLabel(host) ?? host
    }

    /// The folders, in Today's order of their first tab. A topic with two
    /// or more tabs is a group; then a site with two or more of what is
    /// left. One whose tabs are all one site's is named after that site.
    /// Tabs in no group stay in Today.
    public static func groups(for items: [Item]) -> [Group] {
        var remaining = items
        var groups: [Group] = []
        func take(_ name: String, where matches: (Item) -> Bool) {
            let members = remaining.filter(matches)
            guard members.count >= 2 else { return }
            let sites = Set(members.map { siteKey($0.host) })
            let title = sites.count == 1 ? siteName(members[0].host) : name
            groups.append(Group(name: title, members: members.map(\.id)))
            remaining.removeAll(where: matches)
        }
        for topic in topics.map(\.name) {
            take(topic) { self.topic(for: $0) == topic }
        }
        for key in Set(remaining.map { siteKey($0.host) }) {
            take(key) { siteKey($0.host) == key }
        }
        // Two groups may share a name (two sites with one brand): one folder each, numbered.
        var seen: [String: Int] = [:]
        for index in groups.indices {
            let count = seen[groups[index].name, default: 0] + 1
            seen[groups[index].name] = count
            if count > 1 { groups[index].name += " \(count)" }
        }
        let order = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        groups.sort { (order[$0.members[0]] ?? 0) < (order[$1.members[0]] ?? 0) }
        if groups.count > maximumGroups {
            let kept = Set(groups.sorted { $0.members.count > $1.members.count }.prefix(maximumGroups).map(\.name))
            groups.removeAll { !kept.contains($0.name) }
        }
        return groups.map { group in
            Group(name: TidyText.truncated(TidyText.singleLine(group.name), to: 32), members: group.members)
        }
    }
}

/// What Tidy Tabs did, for its one-step Undo.
public struct TidyTabsUndo: Equatable, Sendable {
    public var spaceID: Space.ID
    public var folderIDs: [UUID]
    /// Each moved tab with its index in Today before the tidy, in Today's order.
    public var moved: [(id: Tab.ID, index: Int)]

    public static func == (lhs: TidyTabsUndo, rhs: TidyTabsUndo) -> Bool {
        lhs.spaceID == rhs.spaceID && lhs.folderIDs == rhs.folderIDs
            && lhs.moved.map(\.id) == rhs.moved.map(\.id) && lhs.moved.map(\.index) == rhs.moved.map(\.index)
    }
}

extension SidebarStore {
    /// The space's plain Today tabs (no splits or easels), as Tidy Tabs sees them.
    public func tidyTabsItems(in spaceID: Space.ID? = nil) -> [TidyTabs.Item] {
        let spaceID = spaceID ?? activeSpaceID
        return entries(in: .section(spaceID: spaceID, section: .unpinned)).compactMap { entry in
            guard case .tab(let tab) = entry else { return nil }
            return TidyTabs.Item(id: tab.id, title: tab.displayTitle, host: tab.url.host() ?? "")
        }
    }

    /// The broom shows: more than six Today tabs.
    public func canTidyTabs(in spaceID: Space.ID? = nil) -> Bool {
        tidyTabsItems(in: spaceID).count > TidyTabs.threshold
    }

    /// Files Today's tabs into a folder per group at the end of Pinned.
    /// nil when no two tabs group.
    @discardableResult
    public func tidyTodayTabs(in spaceID: Space.ID? = nil) -> TidyTabsUndo? {
        let spaceID = spaceID ?? activeSpaceID
        let items = tidyTabsItems(in: spaceID)
        let groups = TidyTabs.groups(for: items)
        guard !groups.isEmpty else { return nil }
        let today = entries(in: .section(spaceID: spaceID, section: .unpinned)).map(\.id)
        var undo = TidyTabsUndo(spaceID: spaceID, folderIDs: [], moved: [])
        let grouped = Set(groups.flatMap(\.members))
        undo.moved = today.enumerated().filter { grouped.contains($0.element) }.map { ($0.element, $0.offset) }
        for group in groups {
            guard let folder = createFolder(title: group.name, in: spaceID, containing: group.members) else { continue }
            undo.folderIDs.append(folder.id)
        }
        return undo
    }

    /// Undo: every tab still in a Tidy Tabs folder goes back to its place in
    /// Today, and each folder left empty is removed. A tab the person moved
    /// since stays where they put it.
    @discardableResult
    public func undoTidyTabs(_ undo: TidyTabsUndo) -> [Tab.ID] {
        let folders = Set(undo.folderIDs)
        var restored: [Tab.ID] = []
        for (id, index) in undo.moved {
            guard let folderID = parentFolderID(of: id), folders.contains(folderID) else { continue }
            if moveItem(id, to: .section(spaceID: undo.spaceID, section: .unpinned), index: index) { restored.append(id) }
        }
        for folderID in undo.folderIDs where folder(withID: folderID)?.children.isEmpty == true {
            deleteFolder(folderID, keepingChildren: true)
        }
        return restored
    }
}
