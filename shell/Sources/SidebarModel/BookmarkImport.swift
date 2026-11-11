import Foundation

/// A bookmark or a folder of them, from another browser's export.
public indirect enum BookmarkNode: Equatable, Sendable {
    case link(title: String, url: URL)
    case folder(title: String, children: [BookmarkNode])

    public var linkCount: Int {
        switch self {
        case .link: return 1
        case .folder(_, let children): return children.reduce(0) { $0 + $1.linkCount }
        }
    }
}

/// The bookmarks file every browser exports (Netscape `NETSCAPE-Bookmark-file-1`:
/// Safari, Chrome, Firefox, Edge and Arc). Arc imports another browser's
/// bookmarks into a space's pinned tabs and folders (PROFILES §4.3); ReArc
/// reads the exported file, so it needs no access to the other browser.
public enum BookmarkHTMLImport {
    /// More than this many links is a whole history, not a sidebar.
    public static let maxLinks = 2000
    /// Folders nested deeper than this keep their links in the deepest folder.
    public static let maxDepth = 6

    public static func isBookmarkFile(_ html: String) -> Bool {
        html.range(of: "NETSCAPE-Bookmark-file-1", options: .caseInsensitive) != nil
            || (html.range(of: "<DL", options: .caseInsensitive) != nil && html.range(of: "<A ", options: .caseInsensitive) != nil)
    }

    /// The file's tree. Only http and https links are kept; a file whose
    /// top level is a single folder (the bookmarks bar) is unwrapped.
    public static func parse(_ html: String) -> [BookmarkNode] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<(?:DT>\s*)?H3[^>]*>(.*?)</H3>|<A\s([^>]*)>(.*?)</A>|<DL[^>]*>|</DL>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let text = html as NSString
        var stack: [(title: String, children: [BookmarkNode])] = [("", [])]
        var pendingFolder: String?
        var links = 0
        // Folders deeper than maxDepth do not open a level of their own.
        var flattenedLevels = 0

        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let token = text.substring(with: match.range)
            if match.range(at: 1).location != NSNotFound {
                pendingFolder = decodeEntities(stripTags(text.substring(with: match.range(at: 1))))
            } else if match.range(at: 2).location != NSNotFound {
                guard links < maxLinks,
                      let href = attribute("HREF", in: text.substring(with: match.range(at: 2))),
                      let url = URL(string: href), NavigationURLPolicy.isImportableWebPage(url) else { continue }
                let title = decodeEntities(stripTags(text.substring(with: match.range(at: 3))))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stack[stack.count - 1].children.append(.link(title: title.isEmpty ? (url.host() ?? href) : title, url: url))
                links += 1
            } else if token.hasPrefix("</") {
                if flattenedLevels > 0 {
                    flattenedLevels -= 1
                } else if stack.count > 1 {
                    let folder = stack.removeLast()
                    stack[stack.count - 1].children.append(.folder(title: folder.title, children: folder.children))
                }
            } else {
                // <DL>: the list of the folder named just before it.
                if let title = pendingFolder {
                    if stack.count - 1 < maxDepth {
                        stack.append((title.isEmpty ? "Folder" : title, []))
                    } else {
                        flattenedLevels += 1
                    }
                } else if stack.count > 1 || !stack[0].children.isEmpty {
                    flattenedLevels += 1
                }
                pendingFolder = nil
            }
        }
        while stack.count > 1 {
            let folder = stack.removeLast()
            stack[stack.count - 1].children.append(.folder(title: folder.title, children: folder.children))
        }
        var roots = pruned(stack[0].children)
        if roots.count == 1, case .folder(_, let children) = roots[0] { roots = children }
        return roots
    }

    /// Empty folders go.
    static func pruned(_ nodes: [BookmarkNode]) -> [BookmarkNode] {
        nodes.compactMap { node in
            guard case .folder(let title, let children) = node else { return node }
            let kept = pruned(children)
            return kept.isEmpty ? nil : .folder(title: title, children: kept)
        }
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: name + #"\s*=\s*"([^"]*)""#, options: .caseInsensitive),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        return decodeEntities((tag as NSString).substring(with: match.range(at: 1)))
    }

    static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") {
            for match in regex.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length)).reversed() {
                let ns = out as NSString
                let hex = ns.substring(with: match.range(at: 1)) == "x"
                guard let code = UInt32(ns.substring(with: match.range(at: 2)), radix: hex ? 16 : 10),
                      let scalar = Unicode.Scalar(code) else { continue }
                out = ns.replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// What a browser profile's bookmarks would add to the sidebar
/// (`SidebarStore.bookmarkImportPlan`): only the links it does not hold yet.
public struct BookmarkImportPlan: Equatable, Sendable {
    /// The bookmarks still to bring, in file order; folders left empty go.
    public var nodes: [BookmarkNode]
    /// Links in the source.
    public var total: Int
    /// The space an earlier import of this source made; new links join it.
    public var existingSpaceID: Space.ID?
    /// Arc's own bookmarks, which mirror its sidebar's spaces.
    public var mirrorsArcSidebar = false

    public var newLinks: Int { nodes.reduce(0) { $0 + $1.linkCount } }
    public var isEmpty: Bool { newLinks == 0 }

    /// Arc writes its sidebar into its profile's Chromium `Bookmarks` too (a
    /// folder such as "Imported From Brave" is in both), so once that Arc
    /// profile's spaces are here its bookmarks are mostly copies. They make
    /// no space unless at least one link in ten is new, and then only the
    /// new links come; below that, the few new ones stay in Arc.
    public static let arcMirrorNewShare = 0.1

    /// `nodes` without the links in `known` (by `key(_:)`), folders left
    /// empty dropped. With `mirrorsArcSidebar` the plan is empty unless at
    /// least `arcMirrorNewShare` of the links are new.
    public static func make(_ nodes: [BookmarkNode], known: Set<String>, mirrorsArcSidebar: Bool = false,
                            existingSpaceID: Space.ID? = nil) -> BookmarkImportPlan {
        func unseen(_ nodes: [BookmarkNode]) -> [BookmarkNode] {
            nodes.compactMap { node in
                switch node {
                case .link(_, let url): return known.contains(key(url)) ? nil : node
                case .folder(let title, let children):
                    let kept = unseen(children)
                    return kept.isEmpty ? nil : .folder(title: title, children: kept)
                }
            }
        }
        let total = nodes.reduce(0) { $0 + $1.linkCount }
        var plan = BookmarkImportPlan(nodes: unseen(nodes), total: total, existingSpaceID: existingSpaceID,
                                      mirrorsArcSidebar: mirrorsArcSidebar)
        if mirrorsArcSidebar, Double(plan.newLinks) < Double(total) * arcMirrorNewShare { plan.nodes = [] }
        return plan
    }

    /// A link's identity for import dedupe: `VisitHistory.key` (scheme and
    /// host lowercased, no fragment, no lone trailing slash).
    public static func key(_ url: URL) -> String {
        VisitHistory.key(for: url) ?? url.absoluteString
    }
}

extension ArcSidebarImport {
    /// Every link the sidebar of the Arc profile in `directory` holds:
    /// pinned and Today tabs, splits, folders and favorites.
    public func bookmarkKeys(directory: String) -> Set<String> {
        var keys = Set<String>()
        func walk(_ nodes: [ArcSidebarNode]) {
            for node in nodes {
                switch node {
                case .tab(let tab): keys.insert(BookmarkImportPlan.key(tab.url))
                case .folder(_, _, let children, _): walk(children)
                case .split(_, _, let tabs, _): for tab in tabs { keys.insert(BookmarkImportPlan.key(tab.url)) }
                }
            }
        }
        for space in export.spaces where space.profile.directory == directory {
            walk(space.pinned)
            walk(space.today)
        }
        for (profile, tabs) in export.favorites where profile.directory == directory {
            for tab in tabs { keys.insert(BookmarkImportPlan.key(tab.url)) }
        }
        return keys
    }
}

extension SidebarStore {
    /// What importing `nodes` from the profile `sourceID`
    /// (`ImportSourceProfile.id`) into `profileID` would add. Links already in
    /// the space an earlier import of the same source made are skipped, so
    /// importing twice adds nothing. `arcProfileDirectory` marks Arc's own
    /// bookmarks: once spaces from that Arc profile's sidebar are here, links
    /// already in them (or in their profile's favorites) are skipped too, and
    /// the `arcMirrorNewShare` rule applies.
    public func bookmarkImportPlan(_ nodes: [BookmarkNode], sourceID: String?, arcProfileDirectory: String? = nil,
                                   profileID: Profile.ID? = nil) -> BookmarkImportPlan {
        let target = profileID ?? activeProfileID
        let ledger = sourceID.flatMap { id in spaces.first { $0.profileID == target && $0.bookmarkSourceID == id } }
        var known = Set<String>()
        if let ledger { known.formUnion(bookmarkKeys(in: ledger.id)) }
        var mirrors = false
        if let directory = arcProfileDirectory {
            let arcSpaces = spaces.filter { $0.arcSourceID?.hasPrefix("\(directory):") == true }
            mirrors = !arcSpaces.isEmpty
            for space in arcSpaces { known.formUnion(bookmarkKeys(in: space.id)) }
            for profile in Set(arcSpaces.map(\.profileID) + [target]) {
                known.formUnion(favorites(in: profile).flatMap { [$0.url, $0.savedURL].compactMap { $0 }.map(BookmarkImportPlan.key) })
            }
        }
        return .make(nodes, known: known, mirrorsArcSidebar: mirrors, existingSpaceID: ledger?.id)
    }

    /// Every pinned and Today link in the space (folders and splits included).
    public func bookmarkKeys(in spaceID: Space.ID) -> Set<String> {
        var keys = Set<String>()
        func walk(_ entries: [SidebarEntry]) {
            for entry in entries {
                switch entry {
                case .tab(let tab): keys.insert(BookmarkImportPlan.key(tab.savedURL ?? tab.url)); keys.insert(BookmarkImportPlan.key(tab.url))
                case .split(let split): for tab in split.tabs { keys.insert(BookmarkImportPlan.key(tab.savedURL ?? tab.url)); keys.insert(BookmarkImportPlan.key(tab.url)) }
                case .folder(let folder): walk(folder.children)
                case .easel: break
                }
            }
        }
        let content = content(for: spaceID)
        walk(content.pinned)
        walk(content.today)
        return keys
    }

    /// A browser profile's bookmarks as pinned tabs and folders, in file
    /// order, without the ones already here (`bookmarkImportPlan`). The first
    /// import of `sourceID` makes a new space in `profileID` (the active
    /// profile by default); a later one adds only new links to that space.
    /// Returns the space and how many tabs it got, or nil when nothing is new.
    @discardableResult
    public func importBookmarks(_ nodes: [BookmarkNode], spaceName: String, profileID: Profile.ID? = nil,
                                sourceID: String? = nil, arcProfileDirectory: String? = nil) -> (space: Space, tabs: Int)? {
        let plan = bookmarkImportPlan(nodes, sourceID: sourceID, arcProfileDirectory: arcProfileDirectory, profileID: profileID)
        guard !plan.isEmpty else { return nil }
        if let id = plan.existingSpaceID, let space = space(withID: id) {
            return (space, appendBookmarks(plan.nodes, to: id))
        }
        let name = spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = addSpace(name: name.isEmpty ? "Imported" : name, theme: SpaceTheme.presets[spaces.count % SpaceTheme.presets.count],
                             iconName: "bookmark.fill", profileID: profileID)
        if let index = spaces.firstIndex(where: { $0.id == space.id }) { spaces[index].bookmarkSourceID = sourceID }
        // The whole tree is built first and set once, as the Arc import does:
        // placing thousands of bookmarks a row at a time re-indexed the
        // sidebar per row and froze the onboarding's import.
        var tabs = 0
        // A new space: its pinned section is empty.
        let pinned = bookmarkEntries(plan.nodes, ranks: LexoRank.initialSequence(count: plan.nodes.count), tabs: &tabs)
        setSectionEntries(pinned, for: .pinned, spaceID: space.id)
        journalImported(pinned, spaceID: space.id, container: .pinned)
        notifyMutation()
        // Imported folders start closed, as a bookmarks bar does.
        setAllFoldersExpanded(false, in: space.id)
        return (self.space(withID: space.id) ?? space, tabs)
    }

    private func bookmarkEntries(_ nodes: [BookmarkNode], ranks: [String], tabs: inout Int) -> [SidebarEntry] {
        let date = now()
        return zip(nodes, ranks).map { node, rank in
            switch node {
            case .link(let title, let url):
                tabs += 1
                return .tab(Tab(kind: .pinned, title: title, url: url, sortRank: rank, lastActiveAt: date))
            case .folder(let title, let children):
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                return .folder(SidebarFolder(title: name.isEmpty ? "New Folder" : name,
                                             children: bookmarkEntries(children, ranks: LexoRank.initialSequence(count: children.count), tabs: &tabs),
                                             sortRank: rank))
            }
        }
    }

    /// New bookmarks after the space's own rows; a folder of the same title
    /// at the same level takes the new links inside it. Existing rows keep
    /// their ranks, so sync sees only the inserts.
    private func appendBookmarks(_ nodes: [BookmarkNode], to spaceID: Space.ID) -> Int {
        var tabs = 0
        func merge(_ nodes: [BookmarkNode], into entries: [SidebarEntry], folderID: UUID?) -> [SidebarEntry] {
            var out = entries
            var last = entries.map(rank(of:)).max()
            for node in nodes {
                if case .folder(let title, let children) = node,
                   let index = out.firstIndex(where: { if case .folder(let f) = $0 { return f.title == title }; return false }),
                   case .folder(var folder) = out[index] {
                    folder.children = merge(children, into: folder.children, folderID: folder.id)
                    out[index] = .folder(folder)
                    continue
                }
                let rank = LexoRank.after(last)
                last = rank
                let entry = bookmarkEntries([node], ranks: [rank], tabs: &tabs)[0]
                out.append(entry)
                journalImported([entry], spaceID: spaceID, container: .pinned, folderID: folderID)
            }
            return out
        }
        let merged = merge(nodes, into: content(for: spaceID).pinned, folderID: nil)
        setSectionEntries(merged, for: .pinned, spaceID: spaceID)
        notifyMutation()
        return tabs
    }
}
