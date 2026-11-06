import CoreGraphics
import XCTest
@testable import SidebarModel

/// Browser-window session restore (docs/WINDOW-RESTORE.md): the file, display
/// matching, per-window spaces and the save debounce. Displays are injected;
/// nothing here reads NSScreen.
final class WindowSessionTests: XCTestCase {
    // The user's setup: built-in Retina (primary) with the LG DQHD above it.
    let builtIn = DisplayDescriptor(uuid: "BUILTIN", frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084))
    let lg = DisplayDescriptor(uuid: "LG", frame: CGRect(x: -1673, y: 1117, width: 5120, height: 1440),
                               visibleFrame: CGRect(x: -1673, y: 1117, width: 5120, height: 1410))

    private func saved(_ frame: CGRect, on display: DisplayDescriptor?, key: Bool = false) -> SavedBrowserWindow {
        SavedBrowserWindow(
            frame: frame,
            display: display.map { SavedDisplay(uuid: $0.uuid, frame: $0.frame, visibleFrame: $0.visibleFrame) },
            isKey: key
        )
    }

    private func assertInside(_ frame: CGRect, _ bounds: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(bounds.contains(frame), "\(frame) is not inside \(bounds)", file: file, line: line)
    }

    // MARK: Persistence model

    func testSnapshotRoundTripsThroughTheFile() throws {
        let space = UUID(), profile = UUID()
        var window = saved(CGRect(x: 1740, y: 1117, width: 1707, height: 1410), on: lg, key: true)
        window.spaceID = space
        window.profileID = profile
        window.isFullScreen = true
        window.appKitState = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74])
        let snapshot = WindowSessionSnapshot(
            windows: [window, saved(CGRect(x: 100, y: 100, width: 900, height: 700), on: builtIn)],
            lastClosed: saved(CGRect(x: 10, y: 10, width: 800, height: 600), on: builtIn)
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("window-session-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try WindowSessionFile.save(snapshot, to: url)
        let loaded = try XCTUnwrap(WindowSessionFile.load(from: url))
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(loaded.version, WindowSessionSnapshot.currentVersion)
        XCTAssertEqual(loaded.windows[0].spaceID, space)
        XCTAssertEqual(loaded.windows[0].profileID, profile)
        XCTAssertEqual(loaded.windows[0].display?.uuid, "LG")
    }

    func testSchemaVersionGuardsTheDecode() throws {
        var newer = WindowSessionSnapshot(windows: [saved(CGRect(x: 0, y: 0, width: 800, height: 600), on: builtIn)])
        newer.version = WindowSessionSnapshot.currentVersion + 1
        XCTAssertNil(WindowSessionFile.decode(try WindowSessionFile.encode(newer)), "a newer schema is not guessed at")
        XCTAssertNil(WindowSessionFile.decode(Data("not json".utf8)))
        XCTAssertNil(WindowSessionFile.load(from: URL(fileURLWithPath: "/nonexistent/window-session.json")))
        let json = String(decoding: try WindowSessionFile.encode(WindowSessionSnapshot(windows: [])), as: UTF8.self)
        XCTAssertTrue(json.contains("\"version\" : 1"), json)
    }

    func testDataRootHonoursREARC_DATA_DIR() {
        let root = ShellDataLocation.root(environment: ["REARC_DATA_DIR": "/tmp/rearc-isolated"])
        XCTAssertEqual(root.path, "/tmp/rearc-isolated")
        XCTAssertEqual(WindowSessionFile.defaultFileURL.deletingLastPathComponent(), ShellDataLocation.root)
    }

    func testMigratesAppKitsAutosaveString() throws {
        let legacy = try XCTUnwrap(SavedBrowserWindow(appKitFrameString: "1740 1117 1707 1410 -1673 1117 5120 1410 "))
        XCTAssertEqual(legacy.frame, CGRect(x: 1740, y: 1117, width: 1707, height: 1410))
        XCTAssertNil(legacy.display?.uuid)
        XCTAssertEqual(legacy.display?.visibleFrame, lg.visibleFrame)
        XCTAssertTrue(legacy.isKey)
        // Matched by the visible frame it recorded: it goes back on the LG, not the primary.
        let placed = WindowPlacement.resolve(legacy, displays: [builtIn, lg])
        XCTAssertEqual(placed.display, lg)
        XCTAssertEqual(placed.frame, legacy.frame)
        XCTAssertNil(SavedBrowserWindow(appKitFrameString: ""))
        XCTAssertNil(SavedBrowserWindow(appKitFrameString: "1 2 0 0"))
    }

    func testLaunchWindowIsTheKeyWindowAndTheRestKeepTheirOrder() {
        let a = saved(CGRect(x: 0, y: 0, width: 800, height: 600), on: builtIn)
        let b = saved(CGRect(x: 10, y: 0, width: 800, height: 600), on: lg, key: true)
        let c = saved(CGRect(x: 20, y: 0, width: 800, height: 600), on: builtIn)
        let snapshot = WindowSessionSnapshot(windows: [a, b, c])
        XCTAssertEqual(snapshot.launchWindow, b)
        XCTAssertEqual(snapshot.otherWindows, [a, c])
        XCTAssertEqual(WindowSessionSnapshot(windows: [a, c]).launchWindow, a, "no key window: the frontmost")
        XCTAssertEqual(WindowSessionSnapshot(windows: [a, c]).otherWindows, [c])
        let closedAll = WindowSessionSnapshot(windows: [], lastClosed: c)
        XCTAssertEqual(closedAll.launchWindow, c)
        XCTAssertEqual(closedAll.otherWindows, [])
    }

    // MARK: Display matching

    func testSameDisplayKeepsTheFrameExactly() {
        let frame = CGRect(x: 1740, y: 1117, width: 1707, height: 1410)
        let placed = WindowPlacement.resolve(saved(frame, on: lg), displays: [builtIn, lg])
        XCTAssertEqual(placed.match, .sameDisplay)
        XCTAssertEqual(placed.display, lg)
        XCTAssertEqual(placed.frame, frame)
        // Even with the primary listed second: matching is by UUID, never by focus.
        XCTAssertEqual(WindowPlacement.resolve(saved(frame, on: lg), displays: [lg, builtIn]).frame, frame)
        // Partly off its display on purpose: left as the user had it.
        let hanging = CGRect(x: -1900, y: 1300, width: 900, height: 700)
        XCTAssertEqual(WindowPlacement.resolve(saved(hanging, on: lg), displays: [builtIn, lg]).frame, hanging)
    }

    func testMatchesByUUIDAfterTheDisplaysAreRearranged() {
        // The LG moved beside the built-in display: same UUID, new origin.
        var beside = lg
        beside.frame.origin = CGPoint(x: 1728, y: 0)
        beside.visibleFrame = CGRect(x: 1728, y: 0, width: 5120, height: 1410)
        let frame = CGRect(x: 1740, y: 1117, width: 1707, height: 1410)
        let placed = WindowPlacement.resolve(saved(frame, on: lg), displays: [builtIn, beside])
        XCTAssertEqual(placed.match, .displayChanged)
        XCTAssertEqual(placed.display?.uuid, "LG")
        XCTAssertEqual(placed.frame, CGRect(x: 1728 + 3413, y: 0, width: 1707, height: 1410), "same place on the LG")
    }

    func testResolutionChangeKeepsTheWindowFullyOnScreen() {
        // The LG switched to a scaled 3840x1080 mode.
        var scaled = lg
        scaled.frame = CGRect(x: -1673, y: 1117, width: 3840, height: 1080)
        scaled.visibleFrame = CGRect(x: -1673, y: 1117, width: 3840, height: 1050)
        let frame = CGRect(x: 1740, y: 1117, width: 1707, height: 1410)
        let placed = WindowPlacement.resolve(saved(frame, on: lg), displays: [builtIn, scaled])
        XCTAssertEqual(placed.match, .displayChanged)
        XCTAssertEqual(placed.display, scaled)
        assertInside(placed.frame, scaled.visibleFrame)
        XCTAssertEqual(placed.frame.width, 1707)
        XCTAssertEqual(placed.frame.height, 1050, "height clamped to the visible frame")
        XCTAssertEqual(placed.frame.maxX, scaled.visibleFrame.maxX, "pushed back in from the right edge")
    }

    func testMissingDisplayMovesOntoThePrimaryClampedToItsVisibleFrame() {
        let frame = CGRect(x: 1740, y: 1117, width: 1707, height: 1410)
        let placed = WindowPlacement.resolve(saved(frame, on: lg), displays: [builtIn])
        XCTAssertEqual(placed.match, .displayMissing)
        XCTAssertEqual(placed.display, builtIn)
        assertInside(placed.frame, builtIn.visibleFrame)
        XCTAssertEqual(placed.frame.size, CGSize(width: 1707, height: 1084))

        let small = CGRect(x: -1500, y: 1500, width: 900, height: 600)
        let moved = WindowPlacement.resolve(saved(small, on: lg), displays: [builtIn]).frame
        XCTAssertEqual(moved.size, small.size, "a window that fits keeps its size")
        assertInside(moved, builtIn.visibleFrame)
        XCTAssertEqual(moved.minX, 173, "same offset from the left of the visible frame")
        XCTAssertEqual(moved.maxY, builtIn.visibleFrame.maxY - (lg.visibleFrame.maxY - small.maxY), "same offset from the top")
    }

    func testNoSavedDisplayOrNoDisplays() {
        let offscreen = CGRect(x: 9000, y: 9000, width: 800, height: 600)
        let placed = WindowPlacement.resolve(saved(offscreen, on: nil), displays: [builtIn, lg])
        XCTAssertEqual(placed.display, builtIn)
        assertInside(placed.frame, builtIn.visibleFrame)
        XCTAssertEqual(WindowPlacement.resolve(saved(offscreen, on: lg), displays: []).frame, offscreen)
    }

    // MARK: Per-window space

    func testRestoredSpaceFallsBackToTheProfilesLastSpace() {
        let store = SidebarStore()
        let first = store.activeSpace
        let work = store.addSpace(name: "Work")
        let profile = first.profileID
        XCTAssertEqual(store.restoredSpaceID(saved: work.id, profileID: profile), work.id)
        store.selectSpace(work.id)
        store.selectSpace(first.id)
        XCTAssertEqual(store.restoredSpaceID(saved: UUID(), profileID: profile), first.id, "space deleted: the profile's last")
        XCTAssertNil(store.restoredSpaceID(saved: UUID(), profileID: UUID()), "profile gone too: the key window's space")
        XCTAssertNil(store.restoredSpaceID(saved: nil, profileID: nil))
    }

    func testEachRestoredWindowShowsItsOwnSpace() {
        let store = SidebarStore()
        let home = store.activeSpace
        let work = store.addSpace(name: "Work")
        let key = SidebarWindowID(), behind = SidebarWindowID()
        // As ChromiumShell restores: the key window first, then one behind it on another space.
        store.registerWindow(key, spaceID: store.restoredSpaceID(saved: home.id, profileID: home.profileID))
        store.windowBecameKey(key)
        store.registerWindow(behind, spaceID: store.restoredSpaceID(saved: work.id, profileID: work.profileID))
        XCTAssertEqual(store.focusedSpaceID(in: key), home.id)
        XCTAssertEqual(store.focusedSpaceID(in: behind), work.id)
        XCTAssertEqual(store.activeSpaceID, home.id, "a window restored behind does not switch the key window's space")
        store.windowBecameKey(behind)
        XCTAssertEqual(store.activeSpaceID, work.id)
        XCTAssertEqual(store.focusedSpaceID(in: key), home.id)
    }

    // MARK: Debounce

    private final class ManualScheduler {
        var now: TimeInterval = 0
        var pending: [(at: TimeInterval, block: () -> Void, cancelled: Bool)] = []
        lazy var schedule: Debouncer.Schedule = { [unowned self] delay, block in
            let index = self.pending.count
            self.pending.append((self.now + delay, block, false))
            return { [unowned self] in self.pending[index].cancelled = true }
        }

        func advance(_ seconds: TimeInterval) {
            now += seconds
            for index in pending.indices where !pending[index].cancelled && pending[index].at <= now {
                pending[index].cancelled = true
                pending[index].block()
            }
        }
    }

    func testDebounceCoalescesABurstIntoOneSave() {
        let clock = ManualScheduler()
        var saves = 0
        let debouncer = Debouncer(delay: 0.5, schedule: clock.schedule) { saves += 1 }
        for _ in 0 ..< 30 {
            debouncer.signal()
            clock.advance(0.1)
        }
        XCTAssertEqual(saves, 0, "still dragging")
        XCTAssertTrue(debouncer.isPending)
        clock.advance(0.4)
        XCTAssertEqual(saves, 1)
        XCTAssertFalse(debouncer.isPending)
        clock.advance(5)
        XCTAssertEqual(saves, 1)
    }

    func testDebounceFlushAndCancel() {
        let clock = ManualScheduler()
        var saves = 0
        let debouncer = Debouncer(delay: 0.5, schedule: clock.schedule) { saves += 1 }
        debouncer.flush()
        XCTAssertEqual(saves, 0, "nothing pending, nothing written")
        debouncer.signal()
        debouncer.flush()
        XCTAssertEqual(saves, 1, "quit writes the pending save at once")
        clock.advance(1)
        XCTAssertEqual(saves, 1, "and it does not run again")
        debouncer.signal()
        debouncer.cancel()
        clock.advance(1)
        XCTAssertEqual(saves, 1)
    }

    func testDebounceOnTheMainQueue() {
        let done = expectation(description: "saved once")
        var saves = 0
        let debouncer = Debouncer(delay: 0.05) {
            saves += 1
            done.fulfill()
        }
        debouncer.signal()
        debouncer.signal()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(saves, 1)
    }
}
