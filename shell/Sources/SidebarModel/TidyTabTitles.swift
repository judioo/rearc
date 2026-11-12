import Foundation

/// Max › Tidy Tab Titles (MAX.md §2): a pinned tab or favorite gets a short
/// title by rules alone ("Inbox (3) - you@x.com - Gmail" → "Gmail Inbox").
/// The result is the tab's custom title, marked automatic, so a title the
/// person typed is never replaced.
public enum TidyTabTitles {
    /// No tidied title is longer.
    public static let maximumLength = 40

    /// Separators between a page's name and its site's, spaced as sites write them.
    static let separators = [" - ", " | ", " — ", " – ", " · ", " • ", " :: ", " » ", " / "]

    /// Site names that differ from their host.
    static let brands: [String: String] = [
        "mail.google.com": "Gmail", "calendar.google.com": "Google Calendar", "docs.google.com": "Google Docs",
        "drive.google.com": "Google Drive", "sheets.google.com": "Google Sheets", "meet.google.com": "Google Meet",
        "github.com": "GitHub", "gitlab.com": "GitLab", "youtube.com": "YouTube", "x.com": "X", "twitter.com": "X",
        "linkedin.com": "LinkedIn", "notion.so": "Notion", "figma.com": "Figma", "linear.app": "Linear",
        "slack.com": "Slack", "outlook.live.com": "Outlook", "outlook.office.com": "Outlook", "reddit.com": "Reddit",
        "chatgpt.com": "ChatGPT", "claude.ai": "Claude", "news.ycombinator.com": "Hacker News",
        "web.whatsapp.com": "WhatsApp", "app.slack.com": "Slack", "music.apple.com": "Apple Music",
        "open.spotify.com": "Spotify", "stackoverflow.com": "Stack Overflow", "wikipedia.org": "Wikipedia",
    ]

    /// Page names that say little without their site ("Inbox" → "Gmail Inbox").
    static let generic: Set<String> = [
        "inbox", "home", "dashboard", "settings", "calendar", "feed", "notifications", "messages", "chat", "chats",
        "search", "explore", "overview", "projects", "issues", "pull requests", "files", "my drive", "recent",
        "starred", "account", "profile", "today", "upcoming", "library", "sign in", "log in", "welcome",
    ]

    /// The site's name for `host`: the known brand, or nil.
    static func brand(for host: String) -> String? {
        var host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if let brand = brands[host] { return brand }
        let parts = host.split(separator: ".")
        if parts.count > 2, let brand = brands[parts.suffix(2).joined(separator: ".")] { return brand }
        return nil
    }

    /// The host's main label ("nytimes" for www.nytimes.com).
    static func label(for host: String) -> String {
        let parts = host.lowercased().split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return parts.first ?? "" }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "ac", "gov", "edu"]
        if parts.count >= 3, secondLevel.contains(parts[parts.count - 2]) { return parts[parts.count - 3] }
        return parts[parts.count - 2]
    }

    static func letters(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The segment names the site: the brand, or what matches the host's label.
    static func isSiteName(_ segment: String, host: String, brand: String?) -> Bool {
        let folded = letters(segment)
        guard !folded.isEmpty else { return false }
        if let brand, folded == letters(brand) { return true }
        let label = letters(label(for: host))
        guard label.count >= 3 else { return false }
        return folded == label || (folded.count >= 3 && (folded.hasPrefix(label) || label.hasPrefix(folded)))
    }

    /// "(3) ", " (12)", "[4]", "• " on either end: unread counts and dots.
    static func strippingCounts(_ text: String) -> String {
        var text = text
        let patterns = [#"^\s*[\(\[]\d+\+?[\)\]]\s*"#, #"\s*[\(\[]\d+\+?[\)\]]\s*$"#, #"^\s*[•●]\s*"#]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return text
    }

    static func isNoise(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        // An address or a URL says who is signed in, not what the page is.
        if trimmed.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil { return true }
        if trimmed.range(of: #"^(https?://|www\.)\S+$"#, options: .regularExpression) != nil { return true }
        return false
    }

    static func segments(of title: String) -> [String] {
        var pieces = [title]
        for separator in separators {
            pieces = pieces.flatMap { $0.components(separatedBy: separator) }
        }
        return pieces.map { strippingCounts($0).trimmingCharacters(in: .whitespaces) }.filter { !isNoise($0) }
    }

    /// The tidy title for a page: the page's own part, the site's name
    /// in front when that part is generic, unread counts and addresses gone.
    /// nil when nothing is left or it is the title as it was.
    public static func tidyTitle(_ title: String, host: String) -> String? {
        let clean = TidyText.singleLine(title)
        guard !clean.isEmpty else { return nil }
        let brand = brand(for: host)
        var parts = segments(of: clean)
        let site = parts.first { isSiteName($0, host: host, brand: brand) }
        if parts.count > 1 { parts.removeAll { isSiteName($0, host: host, brand: brand) } }
        let siteName = brand ?? site
        guard var main = parts.first else { return siteName }
        if let siteName, generic.contains(main.lowercased()), letters(main) != letters(siteName) {
            main = "\(siteName) \(main)"
        }
        let result = TidyText.truncated(main, to: maximumLength)
        return result == clean || result.isEmpty ? nil : result
    }

    /// The page's own title has not arrived: the tab shows a stand-in
    /// (its address, host, "New Tab"), so tidying waits for it.
    public static func isPlaceholder(_ title: String, url: URL) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || ["new tab", "untitled", "loading…", "loading...", "page", "about:blank"].contains(trimmed.lowercased()) { return true }
        let host = url.host() ?? ""
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return trimmed == url.absoluteString || trimmed == host || trimmed == bareHost
    }

    /// A tab whose title should be tidied now: no custom title, or an
    /// automatic one (a page title change may tidy again); a title the
    /// person typed is theirs.
    public static func shouldTidy(_ tab: Tab) -> Bool {
        guard tab.kind != .today else { return false }
        return tab.customTitle == nil || tab.customTitleIsAutomatic
    }
}
