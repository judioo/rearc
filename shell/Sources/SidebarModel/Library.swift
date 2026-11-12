import Foundation

/// One page of Arc's Library, the panel behind the sidebar's Home button
/// (`SidebarHomeButton`, SIDEBAR-SPEC §3.1.6). The pages follow the Lottie
/// icons in `ARC_HomeButton.bundle`: spaces, downloads, screenshots (Media),
/// easels (Easels & Notes), archive and boosts.
public enum LibrarySection: String, CaseIterable, Codable, Sendable {
    case spaces
    case downloads
    case media
    case easels
    case archive
    case boosts

    public var title: String {
        switch self {
        case .spaces: return "Spaces"
        case .downloads: return "Downloads"
        case .media: return "Media"
        case .easels: return "Easels & Notes"
        case .archive: return "Archive"
        case .boosts: return "Boosts"
        }
    }

    public var systemImage: String {
        switch self {
        case .spaces: return "rectangle.portrait.on.rectangle.portrait"
        case .downloads: return "arrow.down.circle"
        case .media: return "photo.on.rectangle.angled"
        case .easels: return "scribble.variable"
        case .archive: return "archivebox"
        case .boosts: return "paintbrush.pointed"
        }
    }

    /// Arc's View menu items (`viewEaselsAndNotes`, `viewScreenshotsAndCaptures`,
    /// `openDownloads`, `viewArchive`, `viewBoosts`).
    public var menuTitle: String { "View \(title)" }

    /// The sidebar rail's order, top to bottom
    /// (arc-recordings/2026-11-06-library-in-sidebar.md).
    public static let railOrder: [LibrarySection] = [.media, .downloads, .easels, .spaces, .boosts, .archive]

    /// The rail's label, shorter than the menu's.
    public var railTitle: String {
        switch self {
        case .easels: return "Easels"
        case .archive: return "Archived Tabs"
        default: return title
        }
    }

    /// The column's search field. Spaces has no column.
    public var searchPrompt: String? {
        switch self {
        case .spaces: return nil
        case .archive: return "Search Archive…"
        default: return "Search \(railTitle)…"
        }
    }

    /// Spaces lays every space out beside the rail, over the page; every
    /// other page is a column in the sidebar with the page beside it.
    public var coversPage: Bool { self == .spaces }
}

/// The sidebar's geometry in the Library, measured on the recording (1 px =
/// 1 pt): a 111 pt rail and a 305 pt column, so a 228 pt sidebar grows to
/// 416. Entering grows it on a critically damped spring; leaving is a cut.
public enum LibrarySidebarLayout {
    public static let railWidth: Double = 111
    public static let columnWidth: Double = 305
    /// Rail item centres are 100 pt apart; the selected one sits on a 97 × 80 chip.
    public static let railPitch: Double = 100
    public static let chipWidth: Double = 97
    public static let chipHeight: Double = 80
    /// Fits the column's measured travel: 22 % at 50 ms, 67 % at 117, 91 %
    /// at 167, settled by about 250 (ω ≈ 20 /s, no overshoot).
    public static let growResponse: Double = 0.31

    /// The sidebar's width for a page (nil: outside the Library). The column
    /// is never narrower than Arc's, nor than the sidebar it replaces.
    public static func width(for section: LibrarySection?, sidebarWidth: Double) -> Double {
        guard let section else { return sidebarWidth }
        if section.coversPage { return railWidth }
        return railWidth + max(columnWidth, sidebarWidth - railWidth)
    }
}

/// The sidebar mid-way through the Library's widening. The page is still
/// laid out beside the old width and moves with the sidebar's edge, so
/// Chromium resizes once, at the end (as ⌘S does). The sidebar is drawn
/// at its new width, shifted left: the rail comes in from the window's edge.
public struct LibrarySidebarGrowth: Equatable, Sendable {
    public var from: Double
    /// The sidebar's right edge as drawn, from `from` to the new width.
    public var shown: Double

    public init(from: Double, shown: Double) {
        self.from = from
        self.shown = shown
    }

    public var pageOffset: Double { shown - from }

    public func sidebarOffset(width: Double) -> Double { shown - width }

    /// Only a wider sidebar grows; a narrower one, or leaving, is a cut. A
    /// change mid-way carries on from where the sidebar is drawn.
    public static func start(from old: Double, to new: Double, current: LibrarySidebarGrowth? = nil) -> LibrarySidebarGrowth? {
        if let current { return new > current.from ? current : nil }
        return new > old ? LibrarySidebarGrowth(from: old, shown: old) : nil
    }
}

public enum LibraryDownloads {
    /// Downloads whose file name or site holds the query, in their order.
    public static func matching(_ records: [DownloadRecord], query: String) -> [DownloadRecord] {
        let needle = LibrarySearch.normalized(query)
        guard !needle.isEmpty else { return records }
        return records.filter { record in
            [record.fileName, URL(string: record.url)?.host() ?? ""].contains { LibrarySearch.normalized($0).contains(needle) }
        }
    }

    /// `matching` for a search typed over a long list: each row's folded file
    /// name and site are kept between keystrokes (and while transfers update
    /// the list), and worked out again only when its path or URL changes.
    public struct SearchIndex: Sendable {
        private struct Key: Sendable {
            var targetPath: String
            var url: String
            var fileName: Folded
            var host: Folded
        }

        private var keys: [String: Key] = [:]

        public init() {}

        public mutating func matching(_ records: [DownloadRecord], query: String) -> [DownloadRecord] {
            let needle = Folded(folded: LibrarySearch.normalized(query))
            guard !needle.text.isEmpty else { return records }
            // Rows that left the list are dropped once they outnumber the rest.
            if keys.count > 2 * records.count + 64 { keys = [:] }
            return records.filter { record in
                var key = keys[record.id]
                if key?.targetPath != record.targetPath || key?.url != record.url {
                    key = Key(targetPath: record.targetPath, url: record.url,
                              fileName: Folded(folded: LibrarySearch.normalized(record.fileName)),
                              host: Folded(folded: LibrarySearch.normalized(URL(string: record.url)?.host() ?? "")))
                    keys[record.id] = key
                }
                return key!.fileName.contains(needle) || key!.host.contains(needle)
            }
        }
    }

    /// Folded text, with its bytes when it is ASCII and has no carriage
    /// return: between two such texts a byte search finds exactly what
    /// `contains` finds (each byte is a whole character), many times faster.
    struct Folded: Sendable {
        let text: String
        let ascii: [UInt8]?

        init(folded text: String) {
            self.text = text
            let bytes = Array(text.utf8)
            ascii = bytes.allSatisfy { $0 < 0x80 && $0 != 0x0D } ? bytes : nil
        }

        func contains(_ needle: Folded) -> Bool {
            guard let haystack = ascii, let bytes = needle.ascii else { return text.contains(needle.text) }
            guard haystack.count >= bytes.count else { return false }
            return haystack.withUnsafeBytes { h in
                bytes.withUnsafeBytes { n in memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil }
            }
        }
    }
}

/// Which windows show the Library, and on which page. The Library takes over
/// a window's sidebar; it closes when that window shows another item, so a
/// restored tab, a command bar pick or a space switch leaves it.
public struct LibraryPresentation: Equatable {
    struct Page: Equatable {
        var section: LibrarySection
        /// The window's selected sidebar item when the Library opened.
        var openedOver: UUID?
    }

    private var pages: [SidebarWindowID?: Page] = [:]
    /// The page the Home button opens next (Arc reopens the last one; the
    /// first time, the rail's top page).
    public private(set) var lastSection: LibrarySection = LibrarySection.railOrder[0]

    public init() {}

    /// The page a window shows, or nil when it shows its sidebar selection.
    public func section(in window: SidebarWindowID?, selection: UUID?) -> LibrarySection? {
        guard let page = pages[window], page.openedOver == selection else { return nil }
        return page.section
    }

    public mutating func open(_ section: LibrarySection, in window: SidebarWindowID?, selection: UUID?) {
        pages[window] = Page(section: section, openedOver: selection)
        lastSection = section
    }

    /// The Home button: opens the last page, or closes the Library.
    public mutating func toggle(in window: SidebarWindowID?, selection: UUID?) {
        if section(in: window, selection: selection) != nil {
            close(in: window)
        } else {
            open(lastSection, in: window, selection: selection)
        }
    }

    public mutating func close(in window: SidebarWindowID?) {
        pages[window] = nil
    }

    public mutating func forgetWindow(_ window: SidebarWindowID) {
        pages[window] = nil
    }

    /// Drops every page whose window has shown another item since it
    /// opened, so going back to that item later does not bring it back.
    public mutating func closeStale(selection: (SidebarWindowID?) -> UUID?) {
        guard !pages.isEmpty else { return }
        pages = pages.filter { $0.value.openedOver == selection($0.key) }
    }
}

/// A capture on the Media page (Arc `screenshotsAndCaptures`): the PNG with
/// where it came from and the easels that show it.
public struct LibraryMediaItem: Identifiable, Equatable {
    public var record: CaptureRecord
    /// Titles of the easels and notes whose canvas holds this capture.
    public var easelTitles: [String]

    public var id: UUID { record.id }
}

public enum LibraryMediaFilter: String, CaseIterable, Sendable {
    case all
    case inEasels
    case notInEasels

    public var title: String {
        switch self {
        case .all: return "All"
        case .inEasels: return "In Easels"
        case .notInEasels: return "Not in Easels"
        }
    }
}

public enum LibraryMedia {
    /// Captures newest first, each with the easels that hold it, filtered by
    /// title, site and easel title.
    public static func items(
        captures: [CaptureRecord],
        documents: [EaselDocument],
        filter: LibraryMediaFilter = .all,
        query: String = ""
    ) -> [LibraryMediaItem] {
        var titlesByCapture: [UUID: [String]] = [:]
        for document in documents.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            for block in document.blocks {
                guard case .image(let captureID) = block.payload else { continue }
                if titlesByCapture[captureID]?.contains(document.title) != true {
                    titlesByCapture[captureID, default: []].append(document.title)
                }
            }
        }
        let needle = LibrarySearch.normalized(query)
        return captures
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id.uuidString < $1.id.uuidString }
            .map { LibraryMediaItem(record: $0, easelTitles: titlesByCapture[$0.id] ?? []) }
            .filter { item in
                switch filter {
                case .all: return true
                case .inEasels: return !item.easelTitles.isEmpty
                case .notInEasels: return item.easelTitles.isEmpty
                }
            }
            .filter { item in
                guard !needle.isEmpty else { return true }
                let haystack = [item.record.sourceTitle, item.record.sourceURL?.host() ?? ""] + item.easelTitles
                return haystack.contains { LibrarySearch.normalized($0).contains(needle) }
            }
    }
}

/// A row on the Easels & Notes page.
public struct LibraryDocumentRow: Identifiable, Equatable {
    public var sidebarItemID: UUID
    public var documentID: UUID
    public var title: String
    public var kind: EaselDocumentKind
    public var updatedAt: Date
    /// The space whose sidebar holds the row.
    public var spaceName: String
    /// Canvas objects (easel) or a text preview's first line (note).
    public var summary: String

    public var id: UUID { sidebarItemID }
}

public enum LibraryDocumentFilter: String, CaseIterable, Sendable {
    case all
    case easels
    case notes

    public var title: String {
        switch self {
        case .all: return "All"
        case .easels: return "Easels"
        case .notes: return "Notes"
        }
    }

    func admits(_ kind: EaselDocumentKind) -> Bool {
        switch self {
        case .all: return true
        case .easels: return kind == .easel
        case .notes: return kind == .note
        }
    }
}

public enum LibraryDocuments {
    /// Every easel and note in the sidebar, most recently edited first.
    public static func rows(
        refs: [(ref: SidebarEaselRef, spaceName: String)],
        document: (UUID) -> EaselDocument?,
        filter: LibraryDocumentFilter = .all,
        query: String = ""
    ) -> [LibraryDocumentRow] {
        let needle = LibrarySearch.normalized(query)
        return refs.compactMap { entry -> LibraryDocumentRow? in
            guard let doc = document(entry.ref.easelDocumentID), filter.admits(doc.kind) else { return nil }
            let row = LibraryDocumentRow(
                sidebarItemID: entry.ref.id,
                documentID: doc.id,
                title: doc.title.isEmpty ? (doc.kind == .note ? "Untitled Note" : "Untitled Easel") : doc.title,
                kind: doc.kind,
                updatedAt: doc.updatedAt,
                spaceName: entry.spaceName,
                summary: summary(of: doc)
            )
            guard needle.isEmpty
                || LibrarySearch.normalized(row.title).contains(needle)
                || LibrarySearch.normalized(row.summary).contains(needle) else { return nil }
            return row
        }
        .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.sidebarItemID.uuidString < $1.sidebarItemID.uuidString }
    }

    static func summary(of document: EaselDocument) -> String {
        if let note = document.note {
            return note.blocks.map(\.text).first { !$0.isEmpty } ?? ""
        }
        if document.kind == .note {
            for block in document.blocks {
                if case .text(let runs) = block.payload {
                    let text = runs.map(\.text).joined()
                    if let line = text.split(whereSeparator: \.isNewline).first { return String(line) }
                }
            }
            return ""
        }
        let images = document.blocks.filter { if case .image = $0.payload { return true }; return false }.count
        let count = document.blocks.count
        if count == 0 { return "Empty" }
        let objects = "\(count) object\(count == 1 ? "" : "s")"
        return images > 0 ? "\(objects), \(images) image\(images == 1 ? "" : "s")" : objects
    }
}

/// A space on the Spaces page: its profile, theme and what its sidebar holds.
public struct LibrarySpaceRow: Identifiable, Equatable {
    public var space: Space
    public var profileName: String
    public var pinnedCount: Int
    public var todayCount: Int

    public var id: Space.ID { space.id }
}

public enum LibrarySpaces {
    /// Profiles in order, each with its spaces in sidebar order (its containers' too).
    public static func groups(in store: SidebarStore) -> [(profile: Profile, rows: [LibrarySpaceRow])] {
        store.listedProfiles.map { profile in
            let rows = store.spaces(listedIn: profile.id).map { space in
                let content = store.content(for: space.id)
                return LibrarySpaceRow(
                    space: space,
                    profileName: profile.name,
                    pinnedCount: SidebarTree.leaves(content.pinned).count,
                    todayCount: SidebarTree.leaves(content.today).count
                )
            }
            return (profile, rows)
        }
    }
}

enum LibrarySearch {
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// The Spaces panel's unfold and fold, measured in the Library recording.
public enum LibrarySpacesMotion {
    public static func duration(opening: Bool) -> Double { opening ? 0.08 : 0.17 }
}
