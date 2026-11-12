import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 32: Arc's media strip in the sidebar and ReArc's live video
/// placement (ABI 1.43 `pip_embedded`), on the model the views read.
final class Wave32ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w32-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w32-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w32-links-\(UUID().uuidString)")!
        model.automaticPictureInPicture = false
        return model
    }

    func testCapabilitiesGateEmbeddedVideoOnABI143WithPictureInPicture() {
        let all: (String) -> Bool = { _ in true }
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 42, hasFeature: all).pipEmbedded)
        let current = ChromiumCapabilities(abiMinorVersion: 43, hasFeature: all)
        XCTAssertTrue(current.pipEmbedded)
        XCTAssertTrue(current.summary.contains("pip_embedded=1"))
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 43, hasFeature: { $0 != "picture_in_picture" }).pipEmbedded,
                       "the overlay only exists for PiP the bridge admits")
    }

    func testMediaEventsCarryPauseAndTrackAvailability() {
        var snapshot = ChromiumMediaSnapshot(playback: 1, audible: false, hasMetadata: true, title: "Song", artist: nil, album: nil)
        snapshot.actions = ChromiumMediaMapping.nextTrackBit
        let paused = ChromiumMediaMapping.apply(snapshot, to: .silent)
        XCTAssertTrue(paused.isPaused)
        XCTAssertFalse(paused.isPlaying)
        XCTAssertTrue(paused.canNextTrack)
        XCTAssertFalse(paused.canPreviousTrack)
        snapshot.actions = nil
        let legacy = ChromiumMediaMapping.apply(snapshot, to: .silent)
        XCTAssertTrue(legacy.canNextTrack && legacy.canPreviousTrack, "below ABI 1.43 the engine rejects an unsupported skip itself")
    }

    func testTheStripShowsWhileThePlayingTabIsHiddenAndStaysWhenPaused() {
        var a: Tab!
        var b: Tab!
        let model = makeModel { store in
            a = store.addTab(kind: .today, title: "Music", url: URL(string: "https://music.test")!)
            b = store.addTab(kind: .today, title: "News", url: URL(string: "https://news.test")!)
            store.selectTab(a.id)
        }
        model.mediaStateByTab[a.id] = WebMediaState(isPlaying: true, isAudible: true)
        XCTAssertEqual(model.mediaStrips(in: nil), [], "on screen")
        model.selectTab(b.id)
        XCTAssertEqual(model.mediaStrips(in: nil), [a.id])
        model.mediaStateByTab[a.id] = WebMediaState(isPaused: true)
        XCTAssertEqual(model.mediaStrips(in: nil), [a.id], "a paused strip stays")
        XCTAssertEqual(model.mediaStripInfo(for: a.id)?.isPlaying, false)
        XCTAssertEqual(model.mediaStripInfo(for: a.id)?.canPreviousTrack, false)
        model.closeMediaStrip(a.id)
        XCTAssertEqual(model.mediaStrips(in: nil), [])
        model.mediaStateByTab[a.id] = WebMediaState(isPlaying: true)
        XCTAssertEqual(model.mediaStrips(in: nil), [a.id], "playing again brings it back")
        model.mediaStateByTab[a.id] = nil
        XCTAssertEqual(model.mediaStrips(in: nil), [], "the tab's engine went away")
    }

    func testALiveVideoStartsInTheSidebarOrThePanelAndMinimizesIntoItsStrip() {
        var a: Tab!
        var b: Tab!
        let model = makeModel { store in
            a = store.addTab(kind: .today, title: "Video", url: URL(string: "https://video.test")!)
            b = store.addTab(kind: .today, title: "News", url: URL(string: "https://news.test")!)
            store.selectTab(b.id)
        }
        XCTAssertFalse(model.embedsVideoInSidebar, "Video in Sidebar is off by default, as in Arc")
        model.embedsVideoInSidebar = true
        model.mediaStateByTab[a.id] = WebMediaState(isPlaying: true, canPictureInPicture: true, isPictureInPicture: true, hasLiveVideo: true)
        XCTAssertEqual(model.livePlacements[a.id], .sidebar)
        XCTAssertEqual(model.mediaStrips(in: nil), [a.id], "the sidebar card carries the strip row")
        model.isSidebarVisible = false
        XCTAssertEqual(model.effectiveLivePlacement(for: a.id), .panel, "no sidebar on screen: the panel")
        model.isSidebarVisible = true

        model.popOutLiveVideo(a.id)
        XCTAssertEqual(model.mediaStrips(in: nil), [a.id], "no panel on screen yet: the strip stays")
        model.livePanelTabID = a.id
        XCTAssertEqual(model.mediaStrips(in: nil), [a.id], "the strip stays beside the panel: the panel may present black")
        model.livePanelTabID = nil
        model.minimizeLiveVideo(a.id)
        XCTAssertEqual(model.mediaStrips(in: nil), [a.id])
        XCTAssertEqual(model.mediaStripInfo(for: a.id)?.offersPictureInPicture, true, "Open Picture in Picture")
        model.openPictureInPicture(a.id)
        XCTAssertEqual(model.livePlacements[a.id], .minimized, "no engine video here, so nothing to pop back")

        model.mediaStateByTab[a.id]?.hasLiveVideo = false
        XCTAssertNil(model.livePlacements[a.id], "the session ended")
        model.embedsVideoInSidebar = false
        model.mediaStateByTab[a.id]?.hasLiveVideo = true
        XCTAssertEqual(model.livePlacements[a.id], .panel, "Arc mode: the floating panel")
        XCTAssertEqual(model.externalLinkDefaults.object(forKey: BrowserViewModel.embedsVideoInSidebarKey) as? Bool, false)
    }
}
