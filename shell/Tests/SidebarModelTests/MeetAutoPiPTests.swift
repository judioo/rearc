import XCTest
@testable import SidebarModel

/// P3.28: leaving a tab in a call opens Picture in Picture for it, as Arc
/// does for Google Meet; coming back closes it.
final class MeetAutoPiPTests: XCTestCase {
    private let meet = UUID(), video = UUID(), other = UUID()
    private let now = Date(timeIntervalSince1970: 1_000_000)
    /// A call's tiles: a video that can go into PiP but reports no playback.
    private let callTiles = WebMediaState(isPlaying: false, isAudible: true, canPictureInPicture: true)

    private func plan(
        from previous: Set<UUID>, to visible: Set<UUID>, media: [UUID: WebMediaState], inCall: Set<UUID>,
        autoEntered: Set<UUID> = [], enabled: Bool = true, settings: AutoPiPPolicyState = AutoPiPPolicyState()
    ) -> AutoPiPTabSwitchPlan {
        AutoPiPPolicy.tabSwitchPlan(
            previouslyVisible: previous, nowVisible: visible, media: media,
            hosts: [meet: "meet.google.com", video: "video.test", other: "other.test"],
            autoEntered: autoEntered, inCall: inCall, isEnabled: enabled, settings: settings, now: now
        )
    }

    func testLeavingACallEntersPiPWithoutAPlayingVideo() {
        XCTAssertEqual(plan(from: [meet], to: [other], media: [meet: callTiles], inCall: [meet]), AutoPiPTabSwitchPlan(enter: meet))
        XCTAssertNil(plan(from: [meet], to: [other], media: [meet: callTiles], inCall: []).enter,
                     "not capturing: a paused video stays put")
    }

    func testTheCallNeedsAVideoThePageCanPutInPiP() {
        let audioOnly = WebMediaState(isPlaying: true, isAudible: true)
        XCTAssertNil(plan(from: [meet], to: [other], media: [meet: audioOnly], inCall: [meet]).enter)
        XCTAssertNil(plan(from: [meet], to: [other], media: [:], inCall: [meet]).enter, "no media state yet")
    }

    func testTheSettingAndTheSitesSnoozeStillApply() {
        XCTAssertNil(plan(from: [meet], to: [other], media: [meet: callTiles], inCall: [meet], enabled: false).enter)
        let snoozed = AutoPiPPolicy.snooze(host: "meet.google.com", from: AutoPiPPolicyState(), now: now, duration: 60)
        XCTAssertNil(plan(from: [meet], to: [other], media: [meet: callTiles], inCall: [meet], settings: snoozed).enter)
        let expired = AutoPiPPolicy.snooze(host: "meet.google.com", from: AutoPiPPolicyState(), now: now.addingTimeInterval(-120), duration: 60)
        XCTAssertEqual(plan(from: [meet], to: [other], media: [meet: callTiles], inCall: [meet], settings: expired).enter, meet)
    }

    func testACallBeatsAPlayingVideoLeftAtTheSameTime() {
        let playing = WebMediaState(isPlaying: true, isAudible: true, canPictureInPicture: true)
        // Leaving a split with both: one PiP window, and it goes to the call.
        XCTAssertEqual(plan(from: [meet, video], to: [other], media: [meet: callTiles, video: playing], inCall: [meet]).enter, meet)
    }

    func testComingBackClosesTheCallsPiPButNotOneOpenedByHand() {
        var inPiP = callTiles
        inPiP.isPictureInPicture = true
        let back = plan(from: [other], to: [meet], media: [meet: inPiP], inCall: [meet], autoEntered: [meet])
        XCTAssertEqual(back.exit, [meet])
        XCTAssertNil(back.enter)
        XCTAssertEqual(plan(from: [other], to: [meet], media: [meet: inPiP], inCall: [meet]).exit, [], "opened by hand")
    }

    func testOnlyLiveStreamsCountAsInACall() {
        XCTAssertTrue(MediaCaptureState(isCapturingAudio: true).isCapturingCallMedia)
        XCTAssertTrue(MediaCaptureState(isCapturingVideo: true).isCapturingCallMedia)
        XCTAssertFalse(MediaCaptureState(camera: .off, microphone: .off).isCapturingCallMedia,
                       "a card for reported devices, but nothing live to keep in sight")
        XCTAssertFalse(MediaCaptureState(isCapturingDisplay: true).isCapturingCallMedia)
    }
}
