import AppKit
import ObjectiveC
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Break check 2026-11-07 evening, open issue 8: SwiftUI hover stopped in the
/// browser window after the downloads tray opened and closed. The tray is not
/// the cause: SwiftUI's hosting view drops hover while the system cursor is
/// hidden (`+[NSCursor _isHidden]`, checked in `NSHostingView.sendHoverEvent`).
/// Typing in a field hides it until the mouse moves, and input posted to a
/// process never moves the real mouse. AppKit's tracking areas ignore the
/// cursor, so the plain rows' hover fill kept working, and activating the
/// app showed the cursor again.
///
/// The bar's real downloads button presents the real tray in an off-screen
/// window. Hover goes to the hosting view as AppKit sends it: an enter from
/// the view's own tracking area, then moves.
@MainActor
final class DownloadsTrayHoverTests: XCTestCase {
    @Observable
    final class Probe {
        var entries = 0
    }

    struct Bar: View {
        let downloads: DownloadsController
        let probe: Probe

        var body: some View {
            VStack(spacing: 0) {
                // The Library button's place: the quick view follows its hover.
                Color.gray.frame(width: 100, height: 40)
                    .onHover { if $0 { probe.entries += 1 } }
                DownloadsButton(downloads: downloads, isPresented: Binding(
                    get: { downloads.isTrayPresented },
                    set: { downloads.isTrayPresented = $0 }
                ), showAll: {})
                Spacer(minLength: 0)
            }
            .frame(width: 300, height: 200)
        }
    }

    private var window: NSWindow!
    private var host: NSHostingView<Bar>!
    private let probe = Probe()
    private let downloads = DownloadsController(fileURL: nil)

    override func setUp() async throws {
        _ = NSApplication.shared
        host = NSHostingView(rootView: Bar(downloads: downloads, probe: probe))
        // Far off every screen: the popover follows it there.
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        drain()
    }

    override func tearDown() async throws {
        downloads.isTrayPresented = false
        drain()
        window.orderOut(nil)
        window = nil
        host = nil
    }

    private func drain(_ seconds: TimeInterval = 0.4) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// The hosting view's own area: mouse moves, active always, in the visible rect.
    private var hoverArea: NSTrackingArea? {
        host.trackingAreas.first { $0.owner === host && $0.options.contains(.mouseMoved) }
    }

    /// True when resting on the probe (window y 160–200) reaches its `onHover`.
    private func probeHovers() throws -> Bool {
        let area = try XCTUnwrap(hoverArea, "the hosting view lost its tracking area")
        let before = probe.entries
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered, location: NSPoint(x: 150, y: 10), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil))
        host.mouseEntered(with: enter)
        for point in [NSPoint(x: 150, y: 10), NSPoint(x: 150, y: 180), NSPoint(x: 152, y: 181), NSPoint(x: 150, y: 10)] {
            let move = try XCTUnwrap(NSEvent.mouseEvent(
                with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            host.mouseMoved(with: move)
            drain(0.05)
        }
        return probe.entries > before
    }

    private var popoverWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0 !== window && $0.className.contains("Popover") }
    }

    func testClosingTheTrayLeavesHoverAndTheWindowAsTheyWere() throws {
        try withCursor(hidden: false) {
            XCTAssertTrue(try probeHovers(), "hover before the tray")
            let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
            let key = NSApp.keyWindow
            let responder = window.firstResponder
            let areas = host.trackingAreas.count

            downloads.isTrayPresented = true
            drain(0.8)
            XCTAssertEqual(popoverWindows.count, 1, "the tray's popover is up")
            XCTAssertTrue(try probeHovers(), "hover while the tray is up")

            downloads.isTrayPresented = false
            drain(0.8)
            XCTAssertTrue(popoverWindows.isEmpty, "no popover window is left on screen")
            XCTAssertEqual(Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)), visible)
            XCTAssertTrue(NSApp.keyWindow === key)
            XCTAssertTrue(window.firstResponder === responder)
            XCTAssertEqual(host.trackingAreas.count, areas)
            XCTAssertNotNil(hoverArea)
            XCTAssertTrue(try probeHovers(), "hover after the tray closed")
        }
    }

    /// The cause: with the cursor hidden, SwiftUI drops every move.
    func testSwiftUIHoverStopsWhileTheCursorIsHidden() throws {
        try withCursor(hidden: true) {
            XCTAssertFalse(try probeHovers())
        }
        try withCursor(hidden: false) {
            XCTAssertTrue(try probeHovers())
        }
    }

    /// Runs `body` with `+[NSCursor _isHidden]` answering `hidden`: the real
    /// cursor is whatever the person at the machine last did to it.
    private func withCursor(hidden: Bool, _ body: () throws -> Void) throws {
        guard let method = class_getClassMethod(NSCursor.self, NSSelectorFromString("_isHidden")) else {
            throw XCTSkip("+[NSCursor _isHidden] is gone: SwiftUI checks the cursor some other way now")
        }
        let block: @convention(block) (AnyObject) -> Bool = { _ in hidden }
        let original = method_setImplementation(method, imp_implementationWithBlock(block))
        defer { method_setImplementation(method, original) }
        try body()
    }
}

private final class HistoryBackend: DownloadBackend {
    func perform(_ action: DownloadAction, id: String) -> Bool { false }
    func directoryChanged(_ directory: URL) {}
    var reportsHistorySize: Bool { true }
}

/// The same check's small fixes: the tray's Show All counts the whole
/// history, and Esc closes the tray.
@MainActor
final class DownloadsTrayTests: XCTestCase {
    private func record(_ id: String) -> DownloadRecord {
        DownloadRecord(id: id, source: .chromium, url: "https://example.test/\(id)", state: .complete, startedAt: Date())
    }

    private func finished(_ id: String) -> DownloadEvent {
        DownloadEvent(kind: .created, guid: id, url: "https://example.test/\(id)", state: .complete)
    }

    func testShowAllCountsArchivedRowsNotYetLoaded() {
        let downloads = DownloadsController(fileURL: nil)
        XCTAssertEqual(downloads.historyCount, 0, "without an engine history the list is all of it")
        let backend = HistoryBackend()
        downloads.chromium = backend
        downloads.apply((0 ..< 53).map { finished("live-\($0)") }, source: .chromium)
        XCTAssertNil(downloads.historyCount, "no count until the engine's history reports its size")

        downloads.noteEngineHistory(profile: 1, archived: 39_414)
        XCTAssertEqual(downloads.historyCount, 39_467)
        downloads.appendArchived((0 ..< 1_000).map { record("old-\($0)") }, profile: 1)
        XCTAssertEqual(downloads.records.count, 1_053)
        XCTAssertEqual(downloads.historyCount, 39_467, "a page in moves rows from outstanding to the list")

        downloads.perform(.remove, on: "old-0")
        XCTAssertEqual(downloads.historyCount, 39_466)
        // Restored to live items, the profile reports no archived rows.
        downloads.noteEngineHistory(profile: 1, archived: 0)
        XCTAssertEqual(downloads.historyCount, 1_052)
    }

    func testShowAllTitle() {
        XCTAssertEqual(DownloadsTrayView.showAllTitle(total: 39_467, shown: 50), "Show All \(39_467.formatted()) Downloads")
        XCTAssertEqual(DownloadsTrayView.showAllTitle(total: nil, shown: 50), "Show All Downloads")
        XCTAssertNil(DownloadsTrayView.showAllTitle(total: 12, shown: 12))
    }

    func testEscClosesTheTray() throws {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")))
        func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                           isARepeat: false, keyCode: code))
        }
        XCTAssertFalse(model.handleDownloadsTrayEscape(try key(53)), "no tray: Esc goes on to the Library and the page")
        model.downloads.isTrayPresented = true
        XCTAssertFalse(model.handleDownloadsTrayEscape(try key(53, .command)))
        XCTAssertFalse(model.handleDownloadsTrayEscape(try key(12)))
        XCTAssertTrue(model.downloads.isTrayPresented)
        XCTAssertTrue(model.handleDownloadsTrayEscape(try key(53)))
        XCTAssertFalse(model.downloads.isTrayPresented)
    }
}
