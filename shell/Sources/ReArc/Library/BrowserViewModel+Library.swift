import AppKit
import SwiftUI
import SidebarModel

/// The Library (Arc's Home button, SIDEBAR-SPEC §3.1.6): one page per
/// window, in its sidebar, with the page still in the main frame
/// (arc-recordings/2026-11-06-library-in-sidebar.md). View Archive, View
/// Boosts and View Media open their Library page in the key window.
extension BrowserViewModel {

    func librarySection(in window: SidebarWindowID?) -> LibrarySection? {
        library.section(in: window, selection: selectedItemID(in: window))
    }

    /// The sidebar's width in `window`: wider in the Library, the rail alone on Spaces.
    func sidebarWidth(in window: SidebarWindowID?) -> CGFloat {
        CGFloat(LibrarySidebarLayout.width(for: librarySection(in: window), sidebarWidth: Double(sidebarListWidth(in: window))))
    }

    /// The Library widening `window`'s sidebar, if it is mid-way.
    func sidebarGrowth(in window: SidebarWindowID?) -> LibrarySidebarGrowth? {
        librarySection(in: window) == nil ? nil : libraryGrowth[window]
    }

    /// Opens a page (nil: the last one) in `window`, or the key window. The
    /// Library lives in the sidebar, so a hidden sidebar comes back for it.
    func openLibrary(_ section: LibrarySection?, in window: SidebarWindowID? = nil) {
        let target = window ?? store.keyWindowID
        changeLibrary(in: target) {
            library.open(section ?? library.lastSection, in: target, selection: selectedItemID(in: target))
        }
        if !isSidebarVisible, !isSidebarPeeking { toggleSidebar() }
    }

    func toggleLibrary(in window: SidebarWindowID?) {
        changeLibrary(in: window) {
            library.toggle(in: window, selection: selectedItemID(in: window))
        }
    }

    func closeLibrary(in window: SidebarWindowID? = nil) {
        let target = window ?? store.keyWindowID
        library.close(in: target)
        libraryGrowth[target] = nil
    }

    /// Arc widens the sidebar into the Library in about 0.25 s and cuts back
    /// on leaving (arc-recordings/2026-11-06-library-in-sidebar.md).
    private func changeLibrary(in window: SidebarWindowID?, _ change: () -> Void) {
        let before = Double(sidebarWidth(in: window))
        change()
        let after = Double(sidebarWidth(in: window))
        guard isSidebarVisible, !isSidebarSliding, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let growth = LibrarySidebarGrowth.start(from: before, to: after, current: libraryGrowth[window]) else {
            libraryGrowth[window] = nil
            return
        }
        libraryGrowth[window] = growth
        withAnimation(.spring(response: LibrarySidebarLayout.growResponse, dampingFraction: 1)) {
            libraryGrowth[window]?.shown = after
        } completion: { [weak self] in
            // A newer change owns it now.
            if self?.libraryGrowth[window]?.shown == after { self?.libraryGrowth[window] = nil }
        }
    }

    /// Esc leaves the key window's Library, unless the page has keyboard
    /// focus: the page beside the Library keeps its own Esc. Sheets, panels
    /// and the command bar keep theirs too.
    func handleLibraryEscape(_ event: NSEvent, pageHasFocus: Bool) -> Bool {
        guard event.type == .keyDown, event.keyCode == 53,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              !pageHasFocus, !isCommandBarPresented,
              event.window.map({ !($0 is NSPanel) && $0.attachedSheet == nil }) ?? true,
              librarySection(in: store.keyWindowID) != nil else { return false }
        closeLibrary()
        return true
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
        let refs = store.visibleSpaces.flatMap { space in
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
