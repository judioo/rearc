import Foundation

/// Pasteboard type carried by every drag that starts in the sidebar (tabs,
/// folders, splits, easels, favorites, space icons). Pages never see a drag
/// carrying it: Chromium refuses it in the view (`page_drops` blocked types,
/// ABI 1.29) and ReArc's WKWebView declines it. The UUID string beside it is
/// what the shell's own drop targets read.
public enum SidebarDragType {
    public static let identifier = "com.rearc.sidebar-item"
}

/// What reaches web pages from a drag (`ReArcEngineSetDropPolicy`).
public struct PageDropPolicy: Equatable, Sendable {
    public struct Accept: OptionSet, Equatable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        /// Finder file URLs; Chromium grants the page read access to exactly those files.
        public static let files = Accept(rawValue: 1)
        /// Plain text, HTML, RTF and web custom data.
        public static let text = Accept(rawValue: 2)
        public static let urls = Accept(rawValue: 4)
        /// Promised image bytes (an image dragged from another page).
        public static let images = Accept(rawValue: 8)

        public static let all: Accept = [.files, .text, .urls, .images]
    }

    public static let maxBlockedTypes = 32
    public static let maxTypeBytes = 256

    public var accept: Accept
    /// Exact pasteboard UTIs; a drag carrying one is never offered to a page.
    public var blockedTypes: [String]

    public init(accept: Accept, blockedTypes: [String]) {
        self.accept = accept
        self.blockedTypes = blockedTypes
    }

    /// The shell's policy, as Chrome and Arc behave: files, text, links and
    /// images reach pages; the sidebar's own drags never do.
    public static let shell = PageDropPolicy(accept: .all, blockedTypes: [SidebarDragType.identifier])

    /// The engine rejects the whole call (and keeps its old policy) otherwise:
    /// ≤32 types, each ASCII, 1…256 bytes, no whitespace.
    public var isValid: Bool {
        guard Accept.all.isSuperset(of: accept), blockedTypes.count <= Self.maxBlockedTypes else { return false }
        return blockedTypes.allSatisfy(Self.isValidType)
    }

    public static func isValidType(_ type: String) -> Bool {
        let bytes = type.utf8
        guard (1 ... maxTypeBytes).contains(bytes.count) else { return false }
        return bytes.allSatisfy { $0 < 0x80 && $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
    }

    /// Whether a drag with these pasteboard types is kept away from pages.
    public func blocks(dragTypes: [String]) -> Bool {
        dragTypes.contains { blockedTypes.contains($0) }
    }
}

/// Links and files dropped on the sidebar from a page or another app (Arc
/// `SidebarDropType` URL drops): each becomes a Today tab at the drop position.
public enum SidebarURLDrop {
    public static let maxTabs = 20

    /// The URLs that open as tabs: navigable on this engine, first occurrence
    /// only, at most `maxTabs`.
    public static func tabURLs(from urls: [URL], engine: NavigationURLPolicy.EngineSchemes) -> [URL] {
        var seen: Set<String> = []
        var result: [URL] = []
        for url in urls where NavigationURLPolicy.allows(url, engine: engine) {
            let scheme = url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" || scheme == "file" else { continue }
            guard seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
            if result.count == maxTabs { break }
        }
        return result
    }

    /// Sidebar title until the page reports its own: host, else file name.
    public static func placeholderTitle(for url: URL) -> String {
        if url.isFileURL { return url.lastPathComponent }
        return url.host() ?? url.absoluteString
    }
}
