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
                      let url = URL(string: href), let scheme = url.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", url.host() != nil else { continue }
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

extension SidebarStore {
    /// A new space in the active profile holding `nodes` as pinned tabs and
    /// folders, in file order. Returns the space and how many tabs it got.
    @discardableResult
    public func importBookmarks(_ nodes: [BookmarkNode], spaceName: String) -> (space: Space, tabs: Int)? {
        guard nodes.contains(where: { $0.linkCount > 0 }) else { return nil }
        let name = spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = addSpace(name: name.isEmpty ? "Imported" : name, theme: SpaceTheme.presets[spaces.count % SpaceTheme.presets.count],
                             iconName: "bookmark.fill")
        var tabs = 0
        func place(_ nodes: [BookmarkNode], folder: UUID?) {
            for node in nodes {
                switch node {
                case .link(let title, let url):
                    let tab = addTab(kind: .pinned, title: title, url: url, in: space.id)
                    if let folder {
                        _ = moveItem(tab.id, to: .folder(folder), index: Int.max)
                    }
                    tabs += 1
                case .folder(let title, let children):
                    guard let created = createFolder(title: title, in: space.id, parentFolderID: folder) else { continue }
                    place(children, folder: created.id)
                }
            }
        }
        place(nodes, folder: nil)
        // Imported folders start closed, as a bookmarks bar does.
        setAllFoldersExpanded(false, in: space.id)
        return (space, tabs)
    }
}
