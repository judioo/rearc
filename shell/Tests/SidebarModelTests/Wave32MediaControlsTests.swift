import XCTest
@testable import SidebarModel

/// Wave 32: Arc's media strip rules (MINI-PLAYER.md §3.2) and the live
/// video's placement and size.
final class Wave32MediaControlsTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let playing = WebMediaState(isPlaying: true, isAudible: true)
    private let paused = WebMediaState(isPaused: true)

    func testAStripAppearsOnlyWhileItsPlayingTabIsNotOnScreen() {
        var model = MediaControlsModel()
        model.update(media: [a: playing])
        XCTAssertEqual(model.strips(visibleTabIDs: [a]), [], "the source is on screen: no strip")
        XCTAssertEqual(model.strips(visibleTabIDs: [b]), [a], "switched away: the strip enters")
        XCTAssertEqual(model.strips(visibleTabIDs: [a]), [], "back on the tab: it leaves")
        XCTAssertTrue(model.contains(a), "the entry stays for the next switch away")
    }

    func testAPausedStripStaysAndAnEndedSessionRemovesIt() {
        var model = MediaControlsModel()
        model.update(media: [a: playing])
        model.update(media: [a: paused])
        XCTAssertEqual(model.strips(visibleTabIDs: []), [a], "pause keeps the strip, with the play glyph")
        model.update(media: [a: .silent])
        XCTAssertEqual(model.strips(visibleTabIDs: []), [], "the session ended")
        model.update(media: [a: paused])
        XCTAssertEqual(model.strips(visibleTabIDs: []), [], "a paused tab that never played here has no strip")
    }

    func testClosingTheTabRemovesItsStrip() {
        var model = MediaControlsModel()
        model.update(media: [a: playing, b: playing])
        model.update(media: [b: playing])
        XCTAssertFalse(model.contains(a))
        XCTAssertEqual(model.strips(visibleTabIDs: []), [b])
    }

    func testCloseHidesTheStripUntilTheTabPlaysAgain() {
        var model = MediaControlsModel()
        model.update(media: [a: playing])
        model.dismiss(a)
        XCTAssertEqual(model.strips(visibleTabIDs: []), [])
        model.update(media: [a: playing])
        XCTAssertEqual(model.strips(visibleTabIDs: []), [], "still the same playback")
        model.update(media: [a: paused])
        model.update(media: [a: playing])
        XCTAssertEqual(model.strips(visibleTabIDs: []), [a], "playing again brings it back")
    }

    func testSeveralSourcesStackNewestFirstUpToThree() {
        var model = MediaControlsModel()
        model.update(media: [a: playing])
        model.update(media: [a: playing, b: playing])
        model.update(media: [a: playing, b: playing, c: playing])
        model.update(media: [a: playing, b: playing, c: playing, d: playing])
        XCTAssertEqual(model.strips(visibleTabIDs: []), [d, c, b], "newest on top, capped at 3")
        XCTAssertEqual(model.strips(visibleTabIDs: [d]), [c, b, a], "a visible source frees a slot")
        model.update(media: [a: paused, b: playing, c: playing, d: playing])
        model.update(media: [a: playing, b: playing, c: playing, d: playing])
        XCTAssertEqual(model.strips(visibleTabIDs: []).first, a, "resuming makes it the newest active")
    }

    func testAFloatingPanelSuppressesItsStripAndMinimizeBringsItBack() {
        var model = MediaControlsModel()
        model.update(media: [a: playing])
        XCTAssertTrue(LiveVideoPlacement.panel.suppressesStrip)
        XCTAssertEqual(model.strips(visibleTabIDs: [], suppressed: [a]), [])
        XCTAssertFalse(LiveVideoPlacement.minimized.suppressesStrip)
        XCTAssertTrue(LiveVideoPlacement.minimized.offersBackToPiP)
        XCTAssertFalse(LiveVideoPlacement.sidebar.offersBackToPiP)
    }

    func testPlacementFollowsTheSettingAndNeedsAVisibleSidebar() {
        XCTAssertEqual(LiveVideoPlacement.initial(embedsInSidebar: true, requestedPanel: false), .sidebar)
        XCTAssertEqual(LiveVideoPlacement.initial(embedsInSidebar: false, requestedPanel: false), .panel, "Arc mode")
        XCTAssertEqual(LiveVideoPlacement.initial(embedsInSidebar: true, requestedPanel: true), .panel, "Open Picture in Picture")
        XCTAssertEqual(LiveVideoPlacement.sidebar.effective(sidebarVisible: false), .panel)
        XCTAssertEqual(LiveVideoPlacement.minimized.effective(sidebarVisible: false), .minimized)
    }

    func testTheLiveVideoIsSixteenByNineAtTheSidebarWidth() {
        XCTAssertEqual(LiveVideoLayout.videoHeight(sidebarWidth: 228, naturalSize: nil), 119, "212 pt wide")
        XCTAssertEqual(LiveVideoLayout.videoHeight(sidebarWidth: 228, naturalSize: (1920, 1080)), 119)
        XCTAssertEqual(LiveVideoLayout.videoHeight(sidebarWidth: 228, naturalSize: (300, 528)), 160, "portrait clamps")
        XCTAssertEqual(LiveVideoLayout.videoHeight(sidebarWidth: 120, naturalSize: nil), 90)
    }

    func testOlderMediaSnapshotsDecodeWithoutTheWave32Fields() throws {
        let json = #"{"isPlaying":false,"isAudible":false,"canPictureInPicture":true}"#
        let state = try JSONDecoder().decode(WebMediaState.self, from: Data(json.utf8))
        XCTAssertFalse(state.isPaused)
        XCTAssertFalse(state.canNextTrack)
        XCTAssertFalse(state.hasLiveVideo)
        XCTAssertTrue(state.canPictureInPicture)
    }
}
