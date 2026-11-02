import XCTest
@testable import SidebarModel

final class MediaFeatureTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: - Auto-PiP policy

    func testAutoPiPTriggersWhenOccludedAndVideoPlaying() {
        let settings = AutoPiPPolicyState()
        let decision = AutoPiPPolicy.shouldAutoPiP(
            host: "youtube.com",
            occlusionState: .fullyOccluded,
            now: Date(),
            hasPlayingVideo: true,
            settings: settings
        )
        XCTAssertEqual(decision, .trigger)
    }

    func testAutoPiPSuppressedWhenHostDisabled() {
        var settings = AutoPiPPolicyState()
        settings.perHost["youtube.com"] = .disabled
        let decision = AutoPiPPolicy.shouldAutoPiP(
            host: "youtube.com",
            occlusionState: .fullyOccluded,
            now: Date(),
            hasPlayingVideo: true,
            settings: settings
        )
        if case .suppress(let reason) = decision {
            XCTAssertEqual(reason, "host disabled")
        } else {
            XCTFail("expected suppress")
        }
    }

    func testAutoPiPSuppressedWhileSnoozeActive() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var settings = AutoPiPPolicyState()
        settings.perHost["meet.google.com"] = .snoozedUntil(now.addingTimeInterval(3600))
        let decision = AutoPiPPolicy.shouldAutoPiP(
            host: "meet.google.com",
            occlusionState: .fullyOccluded,
            now: now,
            hasPlayingVideo: true,
            settings: settings
        )
        if case .suppress(let reason) = decision {
            XCTAssertEqual(reason, "host snoozed")
        } else {
            XCTFail("expected suppress")
        }
    }

    func testAutoPiPAllowedAfterSnoozeExpired() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var settings = AutoPiPPolicyState()
        settings.perHost["meet.google.com"] = .snoozedUntil(now.addingTimeInterval(-60))
        let decision = AutoPiPPolicy.shouldAutoPiP(
            host: "meet.google.com",
            occlusionState: .fullyOccluded,
            now: now,
            hasPlayingVideo: true,
            settings: settings
        )
        XCTAssertEqual(decision, .trigger)
    }

    func testAutoPiPSuppressedWhenWindowVisible() {
        let decision = AutoPiPPolicy.shouldAutoPiP(
            host: "youtube.com",
            occlusionState: .visible,
            now: Date(),
            hasPlayingVideo: true,
            settings: AutoPiPPolicyState()
        )
        if case .suppress(let reason) = decision {
            XCTAssertEqual(reason, "window not fully occluded")
        } else {
            XCTFail("expected suppress")
        }
    }

    func testAutoPiPSuppressedWithoutPlayingVideo() {
        let decision = AutoPiPPolicy.shouldAutoPiP(
            host: "youtube.com",
            occlusionState: .fullyOccluded,
            now: Date(),
            hasPlayingVideo: false,
            settings: AutoPiPPolicyState()
        )
        if case .suppress(let reason) = decision {
            XCTAssertEqual(reason, "no playing video")
        } else {
            XCTFail("expected suppress")
        }
    }

    // MARK: - Mini player visibility

    func testMiniPlayerShowsBackgroundTabWhenSelectedTabAlsoAudible() {
        let a = Tab.ID()
        let b = Tab.ID()
        let media: [Tab.ID: WebMediaState] = [
            a: WebMediaState(isPlaying: true, isAudible: true),
            b: WebMediaState(isPlaying: true, isAudible: true),
        ]
        let pick = MiniPlayerVisibility.activeMiniPlayerTab(
            mediaByTab: media,
            selectedTabID: a,
            activeSpaceID: UUID(),
            spaceForTab: { _ in UUID() }
        )
        XCTAssertEqual(pick, b)
    }

    func testMiniPlayerHiddenWhenOnlySelectedTabIsAudible() {
        let a = Tab.ID()
        let media = [a: WebMediaState(isPlaying: true, isAudible: true)]
        let pick = MiniPlayerVisibility.activeMiniPlayerTab(
            mediaByTab: media,
            selectedTabID: a,
            activeSpaceID: UUID(),
            spaceForTab: { _ in UUID() }
        )
        XCTAssertNil(pick)
    }

    func testMiniPlayerShowsForOtherSpaceTab() {
        let spaceA = UUID()
        let spaceB = UUID()
        let background = Tab.ID()
        let media = [background: WebMediaState(isPlaying: true, isAudible: true)]
        let pick = MiniPlayerVisibility.activeMiniPlayerTab(
            mediaByTab: media,
            selectedTabID: Tab.ID(),
            activeSpaceID: spaceA,
            spaceForTab: { $0 == background ? spaceB : spaceA }
        )
        XCTAssertEqual(pick, background)
    }

    // MARK: - Mute model

    func testMuteTabCommandEnablement() {
        let tabID = Tab.ID()
        XCTAssertFalse(TabMediaMuteModel.shouldEnableMuteTab(selectedTabID: tabID, media: .silent))
        XCTAssertTrue(TabMediaMuteModel.shouldEnableMuteTab(
            selectedTabID: tabID,
            media: WebMediaState(isAudible: true)
        ))
    }

    func testUnmuteAllEnablement() {
        var mute = TabMediaMuteModel()
        mute.markUserMuted(Tab.ID())
        XCTAssertTrue(TabMediaMuteModel.shouldEnableUnmuteAll(mediaByTab: [:], muteModel: mute))
    }

    func testPauseAllEnablement() {
        let tabID = Tab.ID()
        let media = [tabID: WebMediaState(isPlaying: true)]
        XCTAssertTrue(TabMediaMuteModel.shouldEnablePauseAll(mediaByTab: media))
        XCTAssertFalse(TabMediaMuteModel.shouldEnablePauseAll(mediaByTab: [:]))
    }

    // MARK: - Command bar

    func testMediaCommandsEnablement() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let tab = store.addTab(kind: .today, title: "Audio", url: url("https://music.test"))
        store.selectTab(tab.id)
        let audible = [tab.id: WebMediaState(isPlaying: true, isAudible: true)]
        let context = CommandBarContext(
            store: store,
            isSidebarVisible: true,
            closedTabStack: store.closedTabStack,
            mediaByTab: audible
        )
        let titles = Set(AppCommandRegistry.all(in: context).map(\.title))
        XCTAssertTrue(titles.contains("Mute Tab"))
        XCTAssertTrue(titles.contains("Pause All Media"))
        XCTAssertTrue(titles.contains("Snooze Auto-PiP for This Site (1 hour)"))
    }

    func testMuteTabCommandDisabledWithoutAudibleMedia() {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let tab = store.addTab(kind: .today, title: "Quiet", url: url("https://quiet.test"))
        store.selectTab(tab.id)
        let context = CommandBarContext(
            store: store,
            isSidebarVisible: true,
            closedTabStack: store.closedTabStack,
            mediaByTab: [tab.id: .silent]
        )
        XCTAssertFalse(AppCommandRegistry.all(in: context).contains(where: { $0.title == "Mute Tab" }))
    }
}
