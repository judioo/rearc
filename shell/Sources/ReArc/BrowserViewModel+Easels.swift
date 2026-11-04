import AppKit
import SwiftUI
import SidebarModel

extension BrowserViewModel {

    var easelDocumentStore: EaselDocumentStore { easelStore }
    var easelRevision: Int { easelMutationRevision }

    func easelTitle(for ref: SidebarEaselRef) -> String {
        easelStore.document(id: ref.easelDocumentID)?.title ?? "Easel"
    }

    func easelDocument(forSidebarItem id: UUID) -> EaselDocument? {
        guard let ref = store.easelRef(withSidebarID: id) else { return nil }
        return easelStore.document(id: ref.easelDocumentID)
    }

    func updateEaselDocument(_ document: EaselDocument) {
        easelStore.save(document)
        easelMutationRevision &+= 1
    }

    @discardableResult
    func createEasel(title: String = "Untitled Easel", note: Bool = false) -> SidebarEaselRef? {
        let document = note
            ? EaselDocumentOps.noteDocument(title: title)
            : EaselDocumentOps.emptyEasel(title: title)
        easelStore.create(document)
        let ref = store.addEaselSidebarItem(documentID: document.id)
        store.selectEasel(ref.id)
        easelMutationRevision &+= 1
        return ref
    }

    func selectEasel(_ sidebarItemID: UUID) {
        closeLibrary()
        store.selectEasel(sidebarItemID)
    }

    func renameEasel(documentID: UUID, title: String) {
        easelStore.renameDocument(id: documentID, title: title)
        easelMutationRevision &+= 1
    }

    func deleteEaselSidebarItem(_ sidebarItemID: UUID) {
        store.removeEaselSidebarItem(sidebarItemID)
        loadSelectedIfNeeded()
    }

    func deleteEaselDocument(_ documentID: UUID) {
        easelStore.deleteDocument(id: documentID, sidebar: store)
        easelMutationRevision &+= 1
        loadSelectedIfNeeded()
    }

    func captureThumbnail(_ captureID: UUID) -> NSImage? {
        guard let record = store.capture(withID: captureID),
              let data = captureFileStore.loadPNG(for: record) else { return nil }
        return NSImage(data: data)
    }

    func performCapture(scope: CaptureScope) async {
        guard let tab = store.selectedTab else { return }
        let engine = engineHost.engine(for: tab, profileID: profileID(for: tab))
        do {
            let png = try await engine.captureSnapshot(scope: scope)
            let record = CaptureRecord(
                sourceURL: engine.currentURL ?? tab.url,
                sourceTitle: engine.pageTitle ?? tab.title,
                scope: scope
            )
            try captureFileStore.savePNG(png, for: record)
            store.addCapture(record)
            lastCapturePreview = record
            isCapturePreviewPresented = true
        } catch {
            captureErrorMessage = error.localizedDescription
        }
    }

    func copyCaptureToClipboard(_ record: CaptureRecord) {
        guard let data = captureFileStore.loadPNG(for: record),
              let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    func deleteCapture(_ record: CaptureRecord) {
        captureFileStore.deletePNG(for: record)
        store.removeCapture(id: record.id)
    }

    func insertCapture(_ record: CaptureRecord, intoEasel documentID: UUID) {
        guard var document = easelStore.document(id: documentID) else { return }
        let block = EaselBlock(
            frame: EaselFrame(x: 80, y: 80, width: 320, height: 240),
            payload: .image(captureID: record.id)
        )
        EaselDocumentOps.insertBlock(block, in: &document)
        easelStore.save(document)
        easelMutationRevision &+= 1
        if let ref = store.easelRef(forDocumentID: documentID) {
            store.selectEasel(ref.id)
        }
    }

    func insertCaptureIntoNewEasel(_ record: CaptureRecord) {
        guard let ref = createEasel(title: record.sourceTitle) else { return }
        insertCapture(record, intoEasel: ref.easelDocumentID)
    }
}
