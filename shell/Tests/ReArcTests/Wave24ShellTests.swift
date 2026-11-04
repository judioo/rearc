import AppKit
import PDFKit
import WebKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// A page for `PagePrinter`: hands out a plain print operation or PDF bytes.
private final class FakePrintablePage: PagePrinting {
    var pageTitle: String? = "Quarterly: report"
    var currentURL: URL? = URL(string: "https://example.test/report")
    var printWindow: NSWindow?
    var pdf = FakePrintablePage.onePagePDF()
    var operations = 0

    func makePDF(for paper: PrintPaperSetup) async throws -> Data { pdf }

    func makePrintOperation(printInfo: NSPrintInfo) async throws -> NSPrintOperation {
        operations += 1
        return NSPrintOperation(view: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), printInfo: printInfo)
    }

    static func onePagePDF() -> Data {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        return view.dataWithPDF(inside: view.bounds)
    }
}

private final class RecordingRunner: PrintOperationRunning {
    var operations: [NSPrintOperation] = []
    var completions: [(Bool) -> Void] = []

    func run(_ operation: NSPrintOperation, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        operations.append(operation)
        completions.append(completion)
    }
}

private struct FixedDestination: PDFDestinationChoosing {
    let url: URL?
    func chooseDestination(suggestedName: String, in window: NSWindow?, completion: @escaping (URL?) -> Void) {
        completion(url)
    }
}

/// A drag offered to a view directly (no drag session).
private final class FakeDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

/// Wave 24: ABI 1.28–1.30 gating, PiP media mapping, the shared printer,
/// sidebar drag payloads, link drops on the sidebar and automatic PiP.
final class Wave24ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w24-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w24-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w24-links-\(UUID().uuidString)")!
        return model
    }

    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("rearc-w24-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    // MARK: Capabilities and media

    func testWave24FeaturesNeedTheirMinorAndFlag() {
        let all: (String) -> Bool = { _ in true }
        for (minor, feature) in [(28, "printing"), (29, "page_drops"), (30, "picture_in_picture")] {
            XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: UInt32(minor - 1), hasFeature: all).summary.contains("\(feature)=0"),
                          "\(feature) waits for 1.\(minor)")
            XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: UInt32(minor), hasFeature: all).summary.contains("\(feature)=1"))
            XCTAssertTrue(ChromiumCapabilities(abiMinorVersion: 99) { $0 != feature }.summary.contains("\(feature)=0"),
                          "\(feature) needs its feature string")
        }
        let at30 = ChromiumCapabilities(abiMinorVersion: 30, hasFeature: all)
        XCTAssertTrue(at30.printing && at30.pageDrops && at30.pictureInPicture)
    }

    func testPiPAvailabilityAndStateComeFromTheMediaEvent() {
        let snapshot = ChromiumMediaSnapshot(playback: 0, audible: true, hasMetadata: false, pipAvailable: true, pipActive: true)
        let state = ChromiumMediaMapping.apply(snapshot, to: .silent)
        XCTAssertTrue(state.canPictureInPicture && state.isPictureInPicture && state.isPlaying)
        let off = ChromiumMediaMapping.apply(ChromiumMediaSnapshot(playback: 1, audible: false, hasMetadata: false), to: state)
        XCTAssertFalse(off.canPictureInPicture || off.isPictureInPicture, "pre-1.30 events carry false")
    }

    func testSelfTestAutoplayIsNotInTheProduct() {
        let product = ChromiumLaunchArguments.browserArguments(["ReArc"], defaultUserDataDir: { "/tmp/p" }, keychain: .system)
        XCTAssertFalse(product.contains { $0.hasPrefix("--autoplay-policy") })
        XCTAssertTrue(ChromiumLaunchArguments.selfTestArguments(product).contains(ChromiumLaunchArguments.selfTestAutoplaySwitch))
    }

    // MARK: Printing

    func testPrintOperationFromAPDFDropsTheSheetMargins() throws {
        let info = NSPrintInfo()
        info.topMargin = 72
        let operation = try PagePrinter.printOperation(forPDF: FakePrintablePage.onePagePDF(), printInfo: info)
        XCTAssertEqual(operation.printInfo.topMargin, 0, "the PDF carries its own margins")
        XCTAssertThrowsError(try PagePrinter.printOperation(forPDF: Data("<html>".utf8), printInfo: NSPrintInfo()))
    }

    func testOnePrintAtATimePerPage() throws {
        let printer = PagePrinter()
        let runner = RecordingRunner()
        printer.runner = runner
        let page = FakePrintablePage()
        printer.print(page)
        let started = expectation(description: "print operation")
        DispatchQueue.main.async { started.fulfill() }
        wait(for: [started], timeout: 2)
        let deadline = Date().addingTimeInterval(2)
        while runner.operations.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(runner.operations.count, 1)
        XCTAssertEqual(runner.operations.first?.jobTitle, "Quarterly- report")
        XCTAssertTrue(printer.isPrinting(page))
        printer.print(page)
        XCTAssertEqual(printer.droppedRequests, 1, "a request while the panel is open is dropped")
        runner.completions.first?(true)
        XCTAssertFalse(printer.isPrinting(page))
    }

    func testExportWritesThePDFWhereTheUserChose() throws {
        let printer = PagePrinter()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w24-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        printer.destinationChooser = FixedDestination(url: url)
        let page = FakePrintablePage()
        let done = expectation(description: "export")
        var result: Result<URL, Error>?
        printer.exportPDF(page) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try result?.get(), url)
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 1)

        page.pdf = Data("not a pdf".utf8)
        let failed = expectation(description: "export of a non-PDF")
        printer.exportPDF(page) { result = $0; failed.fulfill() }
        wait(for: [failed], timeout: 5)
        XCTAssertThrowsError(try result?.get())
        XCTAssertFalse(printer.isPrinting(page))

        printer.destinationChooser = FixedDestination(url: nil)
        printer.exportPDF(page)
        XCTAssertFalse(printer.isPrinting(page), "cancelling the save panel ends the job")
    }

    func testMenusOfferPrintExportAndPiP() {
        let model = makeModel()
        let printing = ShellMenus.printing(model).flatMap { $0 }
        XCTAssertEqual(printing.map(\.title), ["Export as PDF…", "Print…"])
        XCTAssertEqual(printing.last?.menuKeyEquivalent, "p")
        XCTAssertEqual(ShellMenus.pictureInPicture(model).flatMap { $0 }.map(\.title), ["Picture in Picture"])
    }

    // MARK: Drags

    func testSidebarDragsCarryThePrivateTypeAndTheirID() {
        let id = UUID()
        let provider = SidebarDragPayload.itemProvider(for: id)
        XCTAssertEqual(provider.registeredTypeIdentifiers, ["public.utf8-plain-text", SidebarDragType.identifier])
        let board = pasteboard()
        board.declareTypes([SidebarDragPayload.pasteboardType, .string], owner: nil)
        board.setData(Data(id.uuidString.utf8), forType: SidebarDragPayload.pasteboardType)
        board.setString("not the id", forType: .string)
        XCTAssertTrue(SidebarDragPayload.isSidebarDrag(board))
        XCTAssertEqual(SidebarDragPayload.itemID(from: board), id, "the private type wins over the text")
        let text = pasteboard()
        text.setString(id.uuidString, forType: .string)
        XCTAssertFalse(SidebarDragPayload.isSidebarDrag(text))
        XCTAssertEqual(SidebarDragPayload.itemID(from: text), id)
    }

    func testWebKitPagesDeclineSidebarDrags() {
        let view = ReArcWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: WKWebViewConfiguration())
        let board = pasteboard()
        board.declareTypes([SidebarDragPayload.pasteboardType, .string], owner: nil)
        board.setString(UUID().uuidString, forType: .string)
        let drag = FakeDraggingInfo(board)
        XCTAssertEqual(view.draggingEntered(drag), [])
        XCTAssertEqual(view.draggingUpdated(drag), [])
        XCTAssertFalse(view.prepareForDragOperation(drag))
        XCTAssertFalse(view.performDragOperation(drag))
    }

    func testLinksDroppedOnTheSidebarOpenAtTheDropPosition() throws {
        var a: Tab!
        var b: Tab!
        let model = makeModel { store in
            a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
            b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!)
            store.selectTab(a.id)
        }
        let ids = model.openDroppedURLs(
            [URL(string: "https://one.test")!, URL(string: "javascript:void(0)")!, URL(string: "https://two.test")!],
            relativeTo: a.id, after: true
        )
        XCTAssertEqual(ids.count, 2, "javascript: is not a tab")
        let order = model.store.content(for: model.store.activeSpaceID).todayLeaves.map(\.id)
        let at = try XCTUnwrap(order.firstIndex(of: a.id))
        XCTAssertEqual(Array(order[at ... at + 2]), [a.id] + ids)
        XCTAssertEqual(model.store.selectedTabID, ids.first, "the first dropped link is shown")
        XCTAssertEqual(model.store.tab(withID: ids[0])?.url, URL(string: "https://one.test"))
        XCTAssertTrue(order.contains(b.id))
        XCTAssertEqual(model.openDroppedURLs([URL(string: "about:blank")!], relativeTo: a.id, after: false), [])
    }

    // MARK: Automatic Picture in Picture

    func testSwitchingAwayAndBackDrivesAutomaticPiP() {
        var a: Tab!
        var b: Tab!
        let model = makeModel { store in
            a = store.addTab(kind: .today, title: "Video", url: URL(string: "https://video.test")!)
            b = store.addTab(kind: .today, title: "News", url: URL(string: "https://news.test")!)
            store.selectTab(a.id)
        }
        model.automaticPictureInPicture = true
        model.loadSelectedIfNeeded()
        model.mediaStateByTab[a.id] = WebMediaState(isPlaying: true, isAudible: true, canPictureInPicture: true)
        model.selectTab(b.id)
        XCTAssertEqual(model.autoPiPEnteredTabIDs, [a.id], "leaving the playing video put it in PiP")

        model.mediaStateByTab[a.id]?.isPictureInPicture = true
        model.selectTab(a.id)
        XCTAssertTrue(model.autoPiPEnteredTabIDs.isEmpty, "showing it again brought the video back")

        // A PiP you start yourself stays when you switch around.
        model.setPictureInPicture(true, tabID: a.id)
        model.selectTab(b.id)
        model.selectTab(a.id)
        XCTAssertTrue(model.autoPiPEnteredTabIDs.isEmpty)

        model.mediaStateByTab[a.id]?.isPictureInPicture = false
        model.automaticPictureInPicture = false
        model.selectTab(b.id)
        XCTAssertTrue(model.autoPiPEnteredTabIDs.isEmpty, "the setting is off")
        XCTAssertEqual(model.externalLinkDefaults.object(forKey: BrowserViewModel.automaticPictureInPictureKey) as? Bool, false)
    }

    func testTheSidebarBadgeFollowsTheTabsPiPState() {
        var a: Tab!
        let model = makeModel { store in
            a = store.addTab(kind: .today, title: "Video", url: URL(string: "https://video.test")!)
        }
        XCTAssertFalse(model.isPictureInPicture(a.id))
        model.mediaStateByTab[a.id] = WebMediaState(isPlaying: true, canPictureInPicture: true, isPictureInPicture: true)
        XCTAssertTrue(model.isPictureInPicture(a.id))
    }
}
