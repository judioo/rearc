import XCTest
@testable import SidebarModel

final class EaselCaptureTests: XCTestCase {

    func testEaselDocumentBlockCRUDAndZOrder() {
        var doc = EaselDocumentOps.emptyEasel(title: "Board")
        let a = EaselBlock(frame: EaselFrame(x: 0, y: 0, width: 40, height: 40), payload: .text(runs: [EaselRichTextRun(text: "A")]))
        let b = EaselBlock(frame: EaselFrame(x: 10, y: 10, width: 40, height: 40), payload: .text(runs: [EaselRichTextRun(text: "B")]))
        EaselDocumentOps.insertBlock(a, in: &doc)
        EaselDocumentOps.insertBlock(b, in: &doc)
        XCTAssertEqual(doc.blocks.map(\.id), [a.id, b.id])

        var updated = b
        updated.frame = EaselFrame(x: 99, y: 99, width: 40, height: 40)
        EaselDocumentOps.updateBlock(updated, in: &doc)
        XCTAssertEqual(doc.blocks.last?.frame.x, 99)

        EaselDocumentOps.bringForward(id: a.id, in: &doc)
        XCTAssertEqual(doc.blocks.last?.id, a.id)

        EaselDocumentOps.removeBlock(id: b.id, from: &doc)
        XCTAssertEqual(doc.blocks.count, 1)
        XCTAssertEqual(doc.blocks[0].id, a.id)
    }

    func testViewportRoundTripInDocument() throws {
        var doc = EaselDocument(title: "V", viewport: EaselViewport(offsetX: 12, offsetY: -4, zoom: 1.25))
        let persistence = InMemoryEaselPersistence()
        let store = EaselDocumentStore(persistence: persistence)
        store.create(doc)
        doc.viewport = EaselViewport(offsetX: 40, offsetY: 20, zoom: 0.5)
        store.save(doc)
        let loaded = try XCTUnwrap(store.document(id: doc.id))
        XCTAssertEqual(loaded.viewport.offsetX, 40)
        XCTAssertEqual(loaded.viewport.zoom, 0.5)
    }

    func testEaselSidebarIdReferenceAndDocumentDeletionCleansSidebar() {
        let sidebar = SidebarStore(spaces: [Space(name: "Home")])
        let persistence = InMemoryEaselPersistence()
        let easels = EaselDocumentStore(persistence: persistence)
        let document = easels.create(EaselDocumentOps.emptyEasel(title: "Canvas"))
        let ref = sidebar.addEaselSidebarItem(documentID: document.id, section: .unpinned)
        sidebar.selectEasel(ref.id)
        XCTAssertEqual(sidebar.selectedEaselRef?.easelDocumentID, document.id)

        easels.deleteDocument(id: document.id, sidebar: sidebar)
        XCTAssertNil(sidebar.easelRef(withSidebarID: ref.id))
        XCTAssertTrue(sidebar.allEaselRefs().isEmpty)
        XCTAssertNil(sidebar.selectedEaselRef)
    }

    func testCaptureRecordLifecycleInStore() {
        let store = SidebarStore(spaces: [Space(name: "Home")])
        let record = CaptureRecord(sourceURL: URL(string: "https://example.com"), sourceTitle: "Example", scope: .visible)
        store.addCapture(record)
        XCTAssertEqual(store.captures.count, 1)
        XCTAssertEqual(store.capture(withID: record.id)?.sourceTitle, "Example")
        XCTAssertNotNil(store.removeCapture(id: record.id))
        XCTAssertTrue(store.captures.isEmpty)
    }

    func testSnapshotV6MigratesToV7() throws {
        let store = SidebarStore(spaces: [Space(name: "Legacy")])
        let snapshot = store.makeSnapshot()
        var object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(snapshot)) as! [String: Any]
        object["schemaVersion"] = 6
        object.removeValue(forKey: "easelRefsByID")
        object.removeValue(forKey: "capturesByID")
        let migrated = try JSONDecoder().decode(SidebarSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.schemaVersion, 9)
        XCTAssertTrue(migrated.easelRefsByID.isEmpty)
        XCTAssertTrue(migrated.capturesByID.isEmpty)
    }

    func testEaselPersistenceRoundTripOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let persistence = EaselFilePersistence(directoryURL: dir)
        let store = EaselDocumentStore(persistence: persistence)
        let doc = EaselDocumentOps.noteDocument(title: "Note")
        store.create(doc)
        store.flush(doc)
        let loaded = try XCTUnwrap(persistence.loadDocument(id: doc.id))
        XCTAssertEqual(loaded.title, "Note")
        XCTAssertEqual(loaded.blocks.count, 1)
        if case .text = loaded.blocks[0].payload {
            // expected
        } else {
            XCTFail("Expected text block")
        }
    }

    func testSnapshotEncodesEaselRefs() throws {
        let sidebar = SidebarStore(spaces: [Space(name: "Home")])
        let docID = UUID()
        let ref = SidebarEaselRef(easelDocumentID: docID)
        sidebar.addEaselSidebarItem(documentID: docID, section: .pinned)
        let snapshot = sidebar.makeSnapshot()
        XCTAssertFalse(snapshot.easelRefsByID.isEmpty)
        let roundTrip = SidebarStore()
        roundTrip.applySnapshot(snapshot)
        XCTAssertEqual(roundTrip.allEaselRefs().count, 1)
    }
}
