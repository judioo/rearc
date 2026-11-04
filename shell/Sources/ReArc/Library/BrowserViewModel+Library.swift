import AppKit
import SidebarModel

/// The Library (Arc's Home button panel, SIDEBAR-SPEC §3.1.6): one page per
/// window over its page area. View Archive, View Boosts and View Media open
/// their Library page in the key window.
extension BrowserViewModel {

    func librarySection(in window: SidebarWindowID?) -> LibrarySection? {
        library.section(in: window, selection: selectedItemID(in: window))
    }

    /// Opens a page (nil: the last one) in `window`, or the key window.
    func openLibrary(_ section: LibrarySection?, in window: SidebarWindowID? = nil) {
        let target = window ?? store.keyWindowID
        library.open(section ?? library.lastSection, in: target, selection: selectedItemID(in: target))
    }

    func toggleLibrary(in window: SidebarWindowID?) {
        library.toggle(in: window, selection: selectedItemID(in: window))
    }

    func closeLibrary(in window: SidebarWindowID? = nil) {
        library.close(in: window ?? store.keyWindowID)
    }

    var isArchivePresented: Bool {
        get { librarySection(in: store.keyWindowID) == .archive }
        set { setLibraryPage(.archive, presented: newValue) }
    }

    var isBoostLibraryPresented: Bool {
        get { librarySection(in: store.keyWindowID) == .boosts }
        set { setLibraryPage(.boosts, presented: newValue) }
    }

    var isCapturesGalleryPresented: Bool {
        get { librarySection(in: store.keyWindowID) == .media }
        set { setLibraryPage(.media, presented: newValue) }
    }

    private func setLibraryPage(_ section: LibrarySection, presented: Bool) {
        if presented {
            openLibrary(section)
        } else if librarySection(in: store.keyWindowID) == section {
            closeLibrary()
        }
    }

    // MARK: Pages

    /// Easels and notes in every space, for the Easels & Notes page.
    func libraryDocumentRows(filter: LibraryDocumentFilter, query: String) -> [LibraryDocumentRow] {
        _ = easelMutationRevision
        let refs = store.spaces.flatMap { space in
            (store.content(for: space.id).pinned + store.content(for: space.id).today).compactMap { entry -> (SidebarEaselRef, String)? in
                if case .easel(let ref) = entry { return (ref, space.name) }
                return nil
            }
        }
        return LibraryDocuments.rows(
            refs: refs.map { (ref: $0.0, spaceName: $0.1) },
            document: { easelStore.document(id: $0) },
            filter: filter,
            query: query
        )
    }

    func libraryMediaItems(filter: LibraryMediaFilter, query: String) -> [LibraryMediaItem] {
        _ = easelMutationRevision
        let documents = store.allEaselRefs().compactMap { easelStore.document(id: $0.easelDocumentID) }
        return LibraryMedia.items(captures: store.captures, documents: documents, filter: filter, query: query)
    }

    /// Shows an easel or note from the Library: its space, then the item.
    func openLibraryDocument(_ sidebarItemID: UUID) {
        if let location = store.locateEasel(sidebarItemID), location.spaceID != store.activeSpaceID {
            selectSpace(location.spaceID)
        }
        selectEasel(sidebarItemID)
        closeLibrary()
    }

    func openLibrarySpace(_ spaceID: Space.ID) {
        selectSpace(spaceID)
        closeLibrary()
    }

    /// Opens a capture's page in a new tab.
    func openCaptureSource(_ record: CaptureRecord) {
        guard let url = record.sourceURL else { return }
        openInNewTab(url)
        closeLibrary()
    }
}
