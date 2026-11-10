import Foundation

/// Popular sites for inline domain completion (Arc `TopDomainsCandidatesProvider`,
/// COMMAND-BAR §3). ReArc's own list, most popular first; the user's visited
/// hosts rank ahead of it.
public enum TopDomains {
    public static let bundled: [String] = [
        "google.com", "youtube.com", "facebook.com", "wikipedia.org", "instagram.com", "amazon.com",
        "x.com", "twitter.com", "reddit.com", "linkedin.com", "netflix.com", "github.com", "apple.com",
        "microsoft.com", "yahoo.com", "bing.com", "whatsapp.com", "tiktok.com", "openai.com", "chatgpt.com",
        "claude.ai", "anthropic.com", "office.com", "live.com", "outlook.com", "zoom.us", "twitch.tv",
        "pinterest.com", "ebay.com", "paypal.com", "spotify.com", "dropbox.com", "adobe.com", "figma.com",
        "notion.so", "slack.com", "discord.com", "medium.com", "substack.com", "stackoverflow.com",
        "gitlab.com", "bitbucket.org", "npmjs.com", "developer.apple.com", "docs.google.com",
        "drive.google.com", "mail.google.com", "maps.google.com", "calendar.google.com", "meet.google.com",
        "news.google.com", "translate.google.com", "photos.google.com", "play.google.com", "gmail.com",
        "icloud.com", "imdb.com", "nytimes.com", "theguardian.com", "bbc.com", "bbc.co.uk", "cnn.com",
        "washingtonpost.com", "wsj.com", "bloomberg.com", "reuters.com", "theverge.com", "wired.com",
        "techcrunch.com", "arstechnica.com", "news.ycombinator.com", "producthunt.com", "quora.com",
        "tumblr.com", "vimeo.com", "soundcloud.com", "bandcamp.com", "duckduckgo.com", "wolframalpha.com",
        "archive.org", "craigslist.org", "etsy.com", "walmart.com", "target.com", "bestbuy.com",
        "costco.com", "ikea.com", "aliexpress.com", "booking.com", "airbnb.com", "expedia.com",
        "tripadvisor.com", "uber.com", "lyft.com", "doordash.com", "instacart.com", "yelp.com",
        "zillow.com", "indeed.com", "glassdoor.com", "coursera.org", "khanacademy.org", "duolingo.com",
        "udemy.com", "canva.com", "trello.com", "asana.com", "atlassian.com", "jira.atlassian.com",
        "linear.app", "vercel.com", "netlify.com", "heroku.com", "cloudflare.com", "aws.amazon.com",
        "azure.microsoft.com", "cloud.google.com", "digitalocean.com", "stripe.com", "shopify.com",
        "squarespace.com", "wix.com", "wordpress.com", "wordpress.org", "mozilla.org", "python.org",
        "rust-lang.org", "swift.org", "go.dev", "nodejs.org", "react.dev", "developer.mozilla.org",
        "w3.org", "kaggle.com", "huggingface.co", "arxiv.org", "nature.com", "sciencedirect.com",
        "nih.gov", "who.int", "weather.com", "espn.com", "nfl.com", "nba.com", "fifa.com",
        "steampowered.com", "epicgames.com", "playstation.com", "xbox.com", "nintendo.com", "roblox.com",
        "chess.com", "lichess.org", "goodreads.com", "audible.com", "kindle.amazon.com", "hulu.com",
        "disneyplus.com", "max.com", "primevideo.com", "crunchyroll.com", "letterboxd.com", "deviantart.com",
        "behance.net", "dribbble.com", "unsplash.com", "pexels.com", "flickr.com", "500px.com",
        "telegram.org", "signal.org", "messenger.com", "threads.net", "bsky.app", "mastodon.social",
        "protonmail.com", "proton.me", "fastmail.com", "1password.com", "bitwarden.com", "lastpass.com",
        "calendly.com", "loom.com", "miro.com", "airtable.com", "monday.com", "clickup.com", "todoist.com",
        "evernote.com", "obsidian.md", "readwise.io", "pocket.com", "feedly.com", "grammarly.com",
        "deepl.com", "perplexity.ai", "gemini.google.com", "copilot.microsoft.com", "arc.net",
    ]
}

/// Inline completion of a typed domain (the classic omnibox fill): "git"
/// completes to "github.com" and shows "hub.com" after the caret.
public enum InlineDomainCompletion {
    /// The domain `typed` completes to, or nil. `candidates` are hosts, best first.
    public static func complete(_ typed: String, candidates: [String]) -> String? {
        guard !typed.isEmpty, !typed.contains(where: \.isWhitespace), !typed.hasPrefix(">") else { return nil }
        var needle = typed.lowercased()
        for scheme in ["https://", "http://"] where needle.hasPrefix(scheme) { needle.removeFirst(scheme.count) }
        if needle.hasPrefix("www.") { needle.removeFirst(4) }
        guard !needle.isEmpty, !needle.contains("/"), !needle.contains(":") else { return nil }
        for candidate in candidates {
            let host = candidate.lowercased()
            let plain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if plain.hasPrefix(needle), plain.count > needle.count { return plain }
        }
        return nil
    }

    /// What follows the typed text in the field (the scheme and "www." the
    /// user typed stay as typed).
    public static func suffix(typed: String, completion: String) -> String? {
        let lower = typed.lowercased()
        var lead = ""
        var rest = lower
        for scheme in ["https://", "http://"] where rest.hasPrefix(scheme) {
            lead = scheme
            rest.removeFirst(scheme.count)
        }
        if rest.hasPrefix("www.") { lead += "www." }
        let full = lead + completion
        guard full.hasPrefix(lower), full.count > lower.count else { return nil }
        return String(full.dropFirst(lower.count))
    }

    /// Visited hosts first (most visits), then the bundled list.
    public static func candidates(history: VisitHistory) -> [String] {
        var seen = Set<String>()
        var hosts: [String] = []
        let visited = history.records.values
            .compactMap { record -> (String, Int)? in record.url.host().map { ($0, record.visitCount) } }
            .reduce(into: [String: Int]()) { $0[$1.0, default: 0] += $1.1 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        for host in visited.map(\.key) + TopDomains.bundled {
            let key = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            if seen.insert(key).inserted { hosts.append(key) }
        }
        return hosts
    }
}

/// Where Return sends a command-bar result (Arc `CommandBarForceRouteDestination`,
/// COMMAND-BAR §6.3). The spec evidences ⌘-key force routing but not the keys
/// (§9.3); ReArc uses ⌘↩ new tab, ⌥↩ split view and ⇧↩ Little Arc.
public enum CommandBarRoute: String, CaseIterable, Sendable {
    /// The tab the bar was opened for (⌘L) or its new tab (⌘T).
    case current
    case newTab
    case splitView
    case littleArc

    public init(command: Bool, option: Bool, shift: Bool) {
        if shift, !command, !option {
            self = .littleArc
        } else if option, !command, !shift {
            self = .splitView
        } else if command, !option, !shift {
            self = .newTab
        } else {
            self = .current
        }
    }

    /// The modifier hint shown in the bar's footer.
    public var hint: String {
        switch self {
        case .current: return "↩ Open"
        case .newTab: return "⌘↩ New Tab"
        case .splitView: return "⌥↩ Split View"
        case .littleArc: return "⇧↩ Little ReArc"
        }
    }
}

/// One row of the Ctrl+Tab switcher (Arc `ModalItemSwitcher`,
/// `LinearTabSwitcherState`; SIDEBAR-SPEC §4.7).
public struct TabSwitcherItem: Equatable, Identifiable, Sendable {
    public var id: Tab.ID
    public var title: String
    public var url: URL
    public var spaceName: String?
    public var lastActiveAt: Date?
}

extension SidebarStore {
    /// The active profile's tabs, most recently shown first (`lastActiveAt`),
    /// across its spaces and favorites. A split counts once, as its pane that
    /// was shown last. The selected tab comes first.
    public func recentTabSwitcherItems(limit: Int = 12) -> [TabSwitcherItem] {
        var items: [TabSwitcherItem] = []
        var seenSplits = Set<UUID>()
        func add(_ entries: [SidebarEntry], space: Space?) {
            for entry in entries {
                switch entry {
                case .tab(let tab):
                    items.append(TabSwitcherItem(id: tab.id, title: tab.displayTitle, url: tab.url,
                                                 spaceName: space?.name, lastActiveAt: tab.lastActiveAt))
                case .split(let split):
                    guard seenSplits.insert(split.id).inserted,
                          let pane = split.tabs.max(by: { ($0.lastActiveAt ?? .distantPast) < ($1.lastActiveAt ?? .distantPast) })
                    else { continue }
                    items.append(TabSwitcherItem(id: pane.id, title: split.tabs.map(\.displayTitle).joined(separator: " | "),
                                                 url: pane.url, spaceName: space?.name, lastActiveAt: pane.lastActiveAt))
                case .easel, .folder:
                    continue
                }
            }
        }
        add(favorites(in: activeProfileID).map(SidebarEntry.tab), space: nil)
        for space in spacesInActiveProfile {
            add(content(for: space.id).allLeaves, space: space)
        }
        let selected = selectedTabID
        let selectedSplit = selected.flatMap { splitContaining(tabID: $0)?.split.tabs.map(\.id) } ?? []
        items.sort { lhs, rhs in
            let l = lhs.id == selected || selectedSplit.contains(lhs.id), r = rhs.id == selected || selectedSplit.contains(rhs.id)
            if l != r { return l }
            return (lhs.lastActiveAt ?? .distantPast) > (rhs.lastActiveAt ?? .distantPast)
        }
        return Array(items.prefix(limit))
    }
}

/// A Ctrl+Tab session: Tab steps forward through the MRU list, Shift+Tab
/// back, releasing Control picks the highlighted row, Escape cancels.
public struct TabSwitcherSession: Equatable, Sendable {
    public private(set) var items: [TabSwitcherItem]
    public private(set) var index: Int

    /// Starts one step from the current tab: the previous one (forward) or
    /// the least recent (backward).
    public init?(items: [TabSwitcherItem], forward: Bool) {
        guard !items.isEmpty else { return nil }
        self.items = items
        index = 0
        step(forward: forward)
    }

    public mutating func step(forward: Bool) {
        guard items.count > 1 else { return }
        index = (index + (forward ? 1 : -1) + items.count) % items.count
    }

    public var highlighted: TabSwitcherItem { items[index] }
}
