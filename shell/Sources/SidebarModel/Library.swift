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
}

/// Which windows show the Library, and on which page. The Library covers a
/// window's page area; it closes when that window shows another item, so a
/// sidebar click, a restored tab or a space switch brings the page back.
public struct LibraryPresentation: Equatable {
    struct Page: Equatable {
        var section: LibrarySection
        /// The window's selected sidebar item when the Library opened.
        var openedOver: UUID?
    }

    private var pages: [SidebarWindowID?: Page] = [:]
    /// The page the Home button opens next (Arc reopens the last one).
    public private(set) var lastSection: LibrarySection = .spaces

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
    /// Profiles in order, each with its spaces in sidebar order.
    public static func groups(in store: SidebarStore) -> [(profile: Profile, rows: [LibrarySpaceRow])] {
        store.profiles.map { profile in
            let rows = store.spaces(in: profile.id).map { space in
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
