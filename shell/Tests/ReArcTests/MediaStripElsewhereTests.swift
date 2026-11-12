import XCTest
@testable import ReArc
@testable import SidebarModel

/// The owner's report on build 726: a YouTube video plays in a tab inside a
/// folder in one space; in the other spaces the sidebar showed no player and
/// nothing led back to it. Arc shows its strip in every space while the tab
/// is off screen, and the strip goes back to the tab (MINI-PLAYER.md §3.2, §3.6).
final class MediaStripElsewhereTests: XCTestCase {

    private struct Fixture {
        let model: BrowserViewModel
        let demo: Space
        let playground: Space
        let blogging: Space
        let video: SidebarModel.Tab
        let folder: SidebarFolder
    }

    private func makeModel(_ store: SidebarStore) -> BrowserViewModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-strip-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-strip-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-strip-links-\(UUID().uuidString)")!
        // The owner's settings: Automatic Picture in Picture on, Video in Sidebar off.
        model.automaticPictureInPicture = true
        model.embedsVideoInSidebar = false
        return model
    }

    /// Demo holds the video in folder Project C, selected; Playground and Blogging have a tab each.
    private func makeFixture(collapsed: Bool) throws -> Fixture {
        let demo = Space(name: "Demo", sortRank: "a")
        let playground = Space(name: "Playground", sortRank: "b")
        let blogging = Space(name: "Blogging", sortRank: "c")
        let store = SidebarStore(spaces: [demo, playground, blogging])
        _ = store.addTab(kind: .pinned, title: "ReArc Overview", url: URL(string: "https://overview.test")!, in: demo.id)
        let video = store.addTab(kind: .today, title: "YouTube Video Title", url: URL(string: "https://www.youtube.com/watch?v=1")!, in: demo.id)
        let folder = try XCTUnwrap(store.createFolder(title: "Project C", in: demo.id, containing: [video.id]))
        store.setFolderExpanded(folder.id, true)
        _ = store.addTab(kind: .today, title: "Animated UI", url: URL(string: "https://ui.test")!, in: playground.id)
        _ = store.addTab(kind: .today, title: "Substack", url: URL(string: "https://substack.test")!, in: blogging.id)
        store.selectSpace(demo.id)
        store.selectTab(video.id)
        if collapsed { store.setFolderExpanded(folder.id, false) }
        let model = makeModel(store)
        return Fixture(model: model, demo: demo, playground: playground, blogging: blogging, video: video, folder: folder)
    }

    /// YouTube's session: playing, with a video Picture in Picture can take.
    private let youTube = WebMediaState(isPlaying: true, isAudible: true, title: "Star Wars: Bass Windu", canPictureInPicture: true)

    // MARK: The strip in every space

    func testAPlayingTabInAFolderHasItsStripInEveryOtherSpace() throws {
        for collapsed in [false, true] {
            let f = try makeFixture(collapsed: collapsed)
            f.model.mediaStateByTab[f.video.id] = youTube
            XCTAssertEqual(f.model.mediaStrips(in: nil), [], "on screen in Demo")
            f.model.selectSpace(f.playground.id)
            XCTAssertEqual(f.model.mediaStrips(in: nil), [f.video.id], "Playground, folder \(collapsed ? "collapsed" : "open")")
            f.model.selectSpace(f.blogging.id)
            XCTAssertEqual(f.model.mediaStrips(in: nil), [f.video.id], "Blogging, folder \(collapsed ? "collapsed" : "open")")
            XCTAssertEqual(f.model.mediaStripInfo(for: f.video.id)?.title, "YouTube Video Title", "the tab's name, as in Arc")
        }
    }

    /// Each window shows its own space: a second window on Demo has no strip, the key window on Playground has one.
    func testTheStripBelongsToEachWindowNotToTheSpace() throws {
        let f = try makeFixture(collapsed: true)
        let first = SidebarWindowID(), second = SidebarWindowID()
        f.model.store.registerWindow(first)
        f.model.store.registerWindow(second, spaceID: f.demo.id)
        f.model.mediaStateByTab[f.video.id] = youTube
        f.model.selectSpace(f.playground.id)
        XCTAssertEqual(f.model.mediaStrips(in: first), [f.video.id])
        XCTAssertEqual(f.model.mediaStrips(in: second), [], "that window shows the tab")
    }

    // MARK: A Picture in Picture window that is not on screen

    /// Cause 1. Automatic PiP (or the strip's own button) gave the video the
    /// floating panel's placement, which hid the strip whether or not the
    /// panel was on screen. Nothing showed the video when the panel never
    /// came up (no engine view for it, another live video in it, ordered out).
    func testAPanelPlacementWithNoPanelOnScreenKeepsTheStrip() throws {
        let f = try makeFixture(collapsed: true)
        f.model.mediaStateByTab[f.video.id] = youTube
        f.model.selectSpace(f.playground.id)
        var live = youTube
        live.isPictureInPicture = true
        live.hasLiveVideo = true
        f.model.mediaStateByTab[f.video.id] = live
        XCTAssertEqual(f.model.livePlacements[f.video.id], .panel, "Arc mode: the floating panel")
        XCTAssertNil(f.model.livePanelTabID)
        XCTAssertEqual(f.model.mediaStrips(in: nil), [f.video.id], "no panel on screen: the strip is the player")

        f.model.livePanelTabID = f.video.id
        XCTAssertEqual(f.model.mediaStrips(in: nil), [], "the panel on screen is the player (Arc swaps them)")
        f.model.livePanelTabID = nil
        XCTAssertEqual(f.model.mediaStrips(in: nil), [f.video.id], "the panel went: the strip comes back")
    }

    /// Cause 2. A PiP session reported before (or without) its embedded
    /// overlay hid the strip as if the engine's own PiP window showed it.
    /// With `pip_embedded` the engine opens no window of its own.
    func testAnEmbeddedPictureInPictureWithoutItsViewHidesNoStrip() {
        let id = UUID()
        var media = youTube
        media.isPictureInPicture = true
        XCTAssertEqual(MediaControlsModel.playersOnScreen(media: [id: media], placements: [:], panelTabID: nil, engineHasOwnPiPWindow: true),
                       [id], "WebKit or Chromium's own overlay window shows the video")
        XCTAssertEqual(MediaControlsModel.playersOnScreen(media: [id: media], placements: [:], panelTabID: nil, engineHasOwnPiPWindow: false),
                       [], "pip_embedded: nothing shows it until the shell's panel does")
        XCTAssertEqual(MediaControlsModel.playersOnScreen(media: [id: media], placements: [id: .panel], panelTabID: id, engineHasOwnPiPWindow: false),
                       [id])
        XCTAssertEqual(MediaControlsModel.playersOnScreen(media: [id: media], placements: [id: .minimized], panelTabID: nil, engineHasOwnPiPWindow: false),
                       [], "minimized into the strip")
        XCTAssertEqual(MediaControlsModel.playersOnScreen(media: [id: media], placements: [id: .sidebar], panelTabID: nil, engineHasOwnPiPWindow: true),
                       [], "the sidebar card carries the strip row")
    }

    /// The mini sidebar has no live card: a sidebar video goes to the panel there, as with the sidebar hidden.
    func testTheMiniSidebarSendsASidebarVideoToThePanel() throws {
        let f = try makeFixture(collapsed: true)
        let window = SidebarWindowID()
        f.model.store.registerWindow(window)
        f.model.openSidebarMode(for: window, restoring: .mini)
        f.model.embedsVideoInSidebar = true
        f.model.selectSpace(f.playground.id)
        f.model.mediaStateByTab[f.video.id] = WebMediaState(isPlaying: true, canPictureInPicture: true, isPictureInPicture: true, hasLiveVideo: true)
        XCTAssertEqual(f.model.livePlacements[f.video.id], .sidebar)
        XCTAssertEqual(f.model.effectiveLivePlacement(for: f.video.id), .panel, "no live card in the mini column")
        XCTAssertNil(f.model.sidebarLiveVideoTabID(in: window))
        XCTAssertEqual(f.model.mediaStrips(in: window), [f.video.id], "its icon shows until the panel is on screen")
        f.model.sidebarModes.set(.full, in: window)
        XCTAssertEqual(f.model.effectiveLivePlacement(for: f.video.id), .sidebar)
    }

    // MARK: Go to the tab

    /// Cause 3. The strip's favicon and title selected the tab but left its
    /// folder collapsed, so the selected tab was nowhere in the sidebar.
    func testGoingToTheTabOpensItsCollapsedFolderAndRevealsIt() throws {
        let f = try makeFixture(collapsed: true)
        f.model.mediaStateByTab[f.video.id] = youTube
        f.model.selectSpace(f.blogging.id)
        f.model.goToMediaTab(f.video.id)
        XCTAssertEqual(f.model.store.activeSpaceID, f.demo.id)
        XCTAssertEqual(f.model.store.selectedTabID, f.video.id)
        XCTAssertTrue(f.model.store.isFolderExpanded(f.folder.id), "Project C opened")
        XCTAssertEqual(f.model.sidebarRowReveal?.id, f.video.id, "the list scrolls to the row")
        XCTAssertEqual(f.model.mediaStrips(in: nil), [], "on screen again")

        let serial = try XCTUnwrap(f.model.sidebarRowReveal?.serial)
        f.model.goToMediaTab(f.video.id)
        XCTAssertGreaterThan(try XCTUnwrap(f.model.sidebarRowReveal?.serial), serial, "each press asks again, though the selection did not move")
    }

    /// ReArc's folders hold tabs only (`canPlace`), so a split sits in its space's list.
    func testGoingToATabInASplitFocusesItsPane() throws {
        let f = try makeFixture(collapsed: true)
        let store = f.model.store
        let notes = store.addTab(kind: .today, title: "Notes", url: URL(string: "https://notes.test")!, in: f.demo.id)
        let clip = store.addTab(kind: .today, title: "Clip", url: URL(string: "https://www.youtube.com/watch?v=2")!, in: f.demo.id)
        let split = try XCTUnwrap(store.createSplit(tabIDs: [notes.id, clip.id], orientation: .horizontal, in: f.demo.id))
        store.selectSplit(split.id, focusTabID: notes.id)
        f.model.mediaStateByTab[clip.id] = youTube
        XCTAssertEqual(f.model.mediaStrips(in: nil), [], "its split is on screen")
        f.model.selectSpace(f.playground.id)
        XCTAssertEqual(f.model.mediaStrips(in: nil), [clip.id])

        f.model.goToMediaTab(clip.id)
        XCTAssertEqual(store.activeSpaceID, f.demo.id)
        XCTAssertEqual(store.selectedItemID, split.id)
        XCTAssertEqual(store.split(withID: split.id)?.focusTabID, clip.id)
        XCTAssertEqual(f.model.sidebarRowReveal?.id, split.id, "the list scrolls to the split's row")
    }

    func testGoingToATabInAContainerSpaceSelectsThatSpace() throws {
        let f = try makeFixture(collapsed: true)
        let store = f.model.store
        let container = try XCTUnwrap(store.createContainer(forSpace: f.demo.id))
        XCTAssertEqual(f.model.profileID(for: f.video), container.id)
        f.model.mediaStateByTab[f.video.id] = youTube
        f.model.selectSpace(f.playground.id)
        XCTAssertEqual(f.model.mediaStrips(in: nil), [f.video.id])

        f.model.goToMediaTab(f.video.id)
        XCTAssertEqual(store.activeSpaceID, f.demo.id)
        XCTAssertEqual(store.activeProfileID, container.id)
        XCTAssertEqual(store.selectedTabID, f.video.id)
        XCTAssertTrue(store.isFolderExpanded(f.folder.id))
    }

    /// Another profile's space in the same window: the strip shows, and going there switches profile.
    func testGoingToATabInAnotherProfileSwitchesProfile() throws {
        let f = try makeFixture(collapsed: true)
        let store = f.model.store
        let home = store.activeProfileID
        let work = store.addProfile(name: "Work")
        let workSpace = try XCTUnwrap(store.spaces(in: work.id).first)
        let music = store.addTab(kind: .today, title: "Music", url: URL(string: "https://music.test")!, in: workSpace.id)
        f.model.selectSpace(workSpace.id)
        store.selectTab(music.id)
        f.model.mediaStateByTab[music.id] = WebMediaState(isPlaying: true, isAudible: true)
        f.model.selectSpace(f.playground.id)
        XCTAssertEqual(store.activeProfileID, home)
        XCTAssertEqual(f.model.mediaStrips(in: nil), [music.id])

        f.model.goToMediaTab(music.id)
        XCTAssertEqual(store.activeProfileID, work.id)
        XCTAssertEqual(store.activeSpaceID, workSpace.id)
        XCTAssertEqual(store.selectedTabID, music.id)
    }

    func testGoingToAnotherProfilesFavoriteSwitchesProfile() throws {
        let f = try makeFixture(collapsed: true)
        let store = f.model.store
        let home = store.activeProfileID
        let work = store.addProfile(name: "Work")
        let workSpace = try XCTUnwrap(store.spaces(in: work.id).first)
        let favorite = store.addTab(kind: .favorite, title: "Radio", url: URL(string: "https://radio.test")!, in: workSpace.id)
        f.model.mediaStateByTab[favorite.id] = WebMediaState(isPlaying: true, isAudible: true)
        XCTAssertEqual(store.activeProfileID, home)
        XCTAssertEqual(f.model.mediaStrips(in: nil), [favorite.id])

        f.model.goToMediaTab(favorite.id)
        XCTAssertEqual(store.activeProfileID, work.id)
        XCTAssertEqual(store.selectedTabID, favorite.id)
    }

    // MARK: States the owner's run did not try

    /// The folder collapsed while another tab of its space is selected: the strip shows there and elsewhere.
    func testACollapsedFolderWhosePlayingTabIsNotSelectedKeepsItsStrip() throws {
        let f = try makeFixture(collapsed: false)
        let store = f.model.store
        f.model.mediaStateByTab[f.video.id] = youTube
        let overview = try XCTUnwrap(store.displayTabs(in: f.demo.id).first { $0.title == "ReArc Overview" })
        f.model.selectTab(overview.id)
        store.setFolderExpanded(f.folder.id, false)
        XCTAssertEqual(f.model.mediaStrips(in: nil), [f.video.id], "its own space, folder collapsed")
        f.model.selectSpace(f.playground.id)
        XCTAssertEqual(f.model.mediaStrips(in: nil), [f.video.id])
        f.model.goToMediaTab(f.video.id)
        XCTAssertEqual(store.selectedTabID, f.video.id)
        XCTAssertTrue(store.isFolderExpanded(f.folder.id))
    }

    /// Close Mini Player hides the strip for the video playing now; the next
    /// item of a playlist (a new media title) or playing again brings it back.
    func testADismissedStripReturnsWithTheNextPlaylistItem() throws {
        let f = try makeFixture(collapsed: true)
        f.model.mediaStateByTab[f.video.id] = youTube
        f.model.selectSpace(f.playground.id)
        f.model.closeMediaStrip(f.video.id)
        XCTAssertEqual(f.model.mediaStrips(in: nil), [])
        f.model.mediaStateByTab[f.video.id]?.isAudible = false
        XCTAssertEqual(f.model.mediaStrips(in: nil), [], "the same video plays on: still closed")
        f.model.mediaStateByTab[f.video.id]?.title = "Devin Morrison - Men's Club"
        XCTAssertEqual(f.model.mediaStrips(in: nil), [f.video.id], "the playlist's next video")
        f.model.mediaStateByTab[f.video.id] = WebMediaState(isPaused: true, title: "Devin Morrison - Men's Club")
        XCTAssertEqual(f.model.mediaStrips(in: nil), [f.video.id], "a paused strip stays")
    }

    /// Auto-archive closed a Today tab that had been playing in another space for its whole threshold.
    func testAutoArchiveSparesATabThatIsPlaying() throws {
        let f = try makeFixture(collapsed: true)
        let store = f.model.store
        var clock = Date()
        store.now = { clock }
        let radio = store.addTab(kind: .today, title: "Radio", url: URL(string: "https://radio.test")!, in: f.demo.id)
        let idle = store.addTab(kind: .today, title: "Idle", url: URL(string: "https://idle.test")!, in: f.demo.id)
        f.model.mediaStateByTab[radio.id] = WebMediaState(isPlaying: true, isAudible: true)
        f.model.selectSpace(f.playground.id)
        clock = clock.addingTimeInterval(13 * 3600)
        f.model.runAutoArchive()
        XCTAssertNotNil(store.tab(withID: radio.id), "still playing: not archived")
        XCTAssertNil(store.tab(withID: idle.id))
        XCTAssertEqual(f.model.mediaStrips(in: nil), [radio.id])
    }

    // MARK: Where the tab is

    func testTheStripSaysWhichSpaceAndFolderHoldTheTab() throws {
        let f = try makeFixture(collapsed: true)
        let store = f.model.store
        let inner = try XCTUnwrap(store.createFolder(title: "Clips", in: f.demo.id, parentFolderID: f.folder.id, containing: [f.video.id]))
        XCTAssertEqual(store.parentFolderID(of: inner.id), f.folder.id)
        f.model.mediaStateByTab[f.video.id] = youTube
        f.model.selectSpace(f.playground.id)
        XCTAssertEqual(f.model.mediaStripInfo(for: f.video.id)?.location, "Demo › Project C › Clips")

        let loose = store.addTab(kind: .today, title: "Loose", url: URL(string: "https://loose.test")!, in: f.blogging.id)
        XCTAssertEqual(f.model.mediaStripInfo(for: loose.id)?.location, "Blogging")

        let work = store.addProfile(name: "Work")
        let workSpace = try XCTUnwrap(store.spaces(in: work.id).first)
        let music = store.addTab(kind: .today, title: "Music", url: URL(string: "https://music.test")!, in: workSpace.id)
        XCTAssertEqual(f.model.mediaStripInfo(for: music.id)?.location, "Work › \(workSpace.name)", "another profile names it first")
        let favorite = store.addTab(kind: .favorite, title: "Radio", url: URL(string: "https://radio.test")!, in: workSpace.id)
        XCTAssertEqual(f.model.mediaStripInfo(for: favorite.id)?.location, "Work › Favorites")
        let mine = store.addTab(kind: .favorite, title: "Mail", url: URL(string: "https://mail.test")!, in: f.demo.id)
        XCTAssertEqual(f.model.mediaStripInfo(for: mine.id)?.location, "Favorites")
    }

    // MARK: The Picture in Picture panel's display

    /// The owner's window is on the external display; a panel remembered on the
    /// main display opened there, out of sight, while it counted as the player.
    func testThePanelOpensOnTheDisplayOfTheWindow() {
        let main = NSRect(x: 0, y: 0, width: 1728, height: 1079)
        let external = NSRect(x: -1696, y: 1117, width: 5120, height: 1415)
        let screens = [main, external]
        let fresh = LiveVideoPanelController.frame(last: nil, naturalSize: CGSize(width: 1920, height: 1080), screens: screens, on: external)
        XCTAssertEqual(fresh, NSRect(x: external.maxX - 336, y: external.minY + 16, width: 320, height: 180), "bottom right of the window's display")

        let onMain = NSRect(x: 1392, y: 16, width: 320, height: 180)
        XCTAssertEqual(LiveVideoPanelController.frame(last: onMain, naturalSize: nil, screens: screens, on: main), onMain,
                       "where it was, on the same display")
        let moved = LiveVideoPanelController.frame(last: onMain, naturalSize: nil, screens: screens, on: external)
        XCTAssertTrue(external.contains(moved), "moved onto the window's display: \(moved)")
        XCTAssertEqual(moved.size, onMain.size)
        XCTAssertGreaterThan(moved.midX, external.midX, "its place there: still the bottom right")
        XCTAssertLessThan(moved.midY, external.midY)

        let gone = NSRect(x: 9000, y: 9000, width: 320, height: 180)
        XCTAssertEqual(LiveVideoPanelController.frame(last: gone, naturalSize: nil, screens: screens, on: external).origin,
                       NSPoint(x: external.maxX - 336, y: external.minY + 16), "a display that went: the corner")
    }

    // MARK: A live video with no picture

    /// The owner's black panel: the read-back of a view with no picture is
    /// nothing or black; a still picture that is not black is a picture.
    func testABlankLiveVideoIsNothingOrBlack() {
        XCTAssertTrue(LiveVideoDrawing.isBlank([nil, nil, nil, nil]), "not drawing")
        XCTAssertTrue(LiveVideoDrawing.isBlank([0x000000FF, 0x000000FF, 0x101010FF, nil]), "the overlay's black")
        XCTAssertFalse(LiveVideoDrawing.isBlank([0xD2492CFF, 0x74E249FF, 0x2C8AD2FF, 0xD2492CFF]), "the self-test's video")
        XCTAssertFalse(LiveVideoDrawing.isBlank([0x806040FF, 0x806040FF, 0x806040FF, 0x806040FF]), "a song's still artwork")
        XCTAssertFalse(LiveVideoDrawing.isBlank([0x000000FF, 0x000000FF, 0xF0F0F0FF, 0x000000FF]), "a fade from black")
    }

    /// A panel on screen that shows black is no player: the strip comes back.
    func testABlankPanelKeepsTheStrip() throws {
        let f = try makeFixture(collapsed: true)
        var live = youTube
        live.isPictureInPicture = true
        live.hasLiveVideo = true
        f.model.mediaStateByTab[f.video.id] = youTube
        f.model.selectSpace(f.playground.id)
        f.model.mediaStateByTab[f.video.id] = live
        f.model.livePanelTabID = f.video.id
        XCTAssertEqual(f.model.mediaStrips(in: nil), [], "a panel with a picture is the player")
        f.model.blankLiveVideos.insert(f.video.id)
        XCTAssertEqual(f.model.mediaStrips(in: nil), [f.video.id], "black in the panel: the strip shows")
        f.model.mediaStateByTab[f.video.id]?.hasLiveVideo = false
        XCTAssertTrue(f.model.blankLiveVideos.isEmpty, "the session ended")
    }
}
