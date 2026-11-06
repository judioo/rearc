import XCTest
@testable import SidebarModel

/// Wave 34: the bottom bar's space dots, the Library button's downloads
/// stack and the update slot (docs/ARC-RECORDING-2026-11-06.md §4, §5).
final class Wave34BottomBarTests: XCTestCase {

    // MARK: Space dots

    private let plain = Space(name: "Plain")
    private let heart = Space(name: "Heart", iconName: "heart.fill")
    private let house = Space(name: "House", iconName: "house.fill")

    func testDefaultIconCountsAsNoIcon() {
        XCTAssertFalse(plain.hasIcon)
        XCTAssertFalse(Space(name: "Empty", iconName: "").hasIcon)
        XCTAssertTrue(heart.hasIcon)
        XCTAssertTrue(Space(name: "Emoji", iconName: "🦊").hasIcon)
    }

    func testAtRestTheCurrentSpaceShowsItsIconOrALargerDot() {
        let spaces = [plain, heart, house]
        XCTAssertEqual(SpaceDots.appearances(spaces: spaces, current: heart.id, hovered: nil), [.dot, .icon, .dot])
        XCTAssertEqual(SpaceDots.appearances(spaces: spaces, current: plain.id, hovered: nil), [.largeDot, .dot, .dot])
    }

    func testTheHoveredDotWinsAndTheCurrentIconFallsBackToItsLargerDot() {
        let spaces = [plain, heart, house]
        XCTAssertEqual(SpaceDots.appearances(spaces: spaces, current: heart.id, hovered: house.id), [.dot, .largeDot, .icon])
        XCTAssertEqual(SpaceDots.appearances(spaces: spaces, current: plain.id, hovered: house.id), [.largeDot, .dot, .icon])
    }

    func testOnlyOneIconShowsAtATime() {
        let spaces = [plain, heart, house]
        for current in spaces {
            for hovered in [nil] + spaces.map(\.id) {
                let icons = SpaceDots.appearances(spaces: spaces, current: current.id, hovered: hovered).filter { $0 == .icon }
                XCTAssertLessThanOrEqual(icons.count, 1)
            }
        }
    }

    func testHoveringTheCurrentSpaceIsTheRestState() {
        let spaces = [plain, heart]
        XCTAssertEqual(SpaceDots.appearances(spaces: spaces, current: heart.id, hovered: heart.id), [.dot, .icon])
        XCTAssertEqual(SpaceDots.appearances(spaces: spaces, current: plain.id, hovered: plain.id), [.largeDot, .dot])
    }

    func testAHoveredSpaceWithoutAnIconShowsALargerDot() {
        let other = Space(name: "Other")
        XCTAssertEqual(SpaceDots.appearances(spaces: [heart, other], current: heart.id, hovered: other.id), [.largeDot, .largeDot])
    }

    func testAHoveredIDNotInTheRowIsIgnored() {
        XCTAssertEqual(SpaceDots.appearances(spaces: [plain, heart], current: heart.id, hovered: UUID()), [.dot, .icon])
    }

    // MARK: Hover reveal

    func testRevealsShortlyAfterRestingOnTheButton() {
        var reveal = HoverReveal()
        XCTAssertEqual(reveal.showDelay, 0.15)
        reveal.setHovering(true, .trigger, at: 10)
        XCTAssertEqual(reveal.deadline, 10.15)
        XCTAssertFalse(reveal.advance(to: 10.1))
        XCTAssertFalse(reveal.isShown)
        XCTAssertTrue(reveal.advance(to: 10.15))
        XCTAssertTrue(reveal.isShown)
        XCTAssertNil(reveal.deadline)
    }

    func testLeavingBeforeTheDelayCancels() {
        var reveal = HoverReveal()
        reveal.setHovering(true, .trigger, at: 0)
        reveal.setHovering(false, .trigger, at: 0.1)
        XCTAssertNil(reveal.deadline)
        XCTAssertFalse(reveal.advance(to: 1))
        XCTAssertFalse(reveal.isShown)
    }

    func testCrossingFromTheButtonToTheStackKeepsItShown() {
        var reveal = HoverReveal()
        reveal.setHovering(true, .trigger, at: 0)
        reveal.advance(to: 0.15)
        reveal.setHovering(false, .trigger, at: 1)
        reveal.setHovering(true, .content, at: 1.3)
        XCTAssertNil(reveal.deadline)
        XCTAssertFalse(reveal.advance(to: 2))
        XCTAssertTrue(reveal.isShown)
    }

    /// Arc keeps the stack about half a second after the pointer leaves.
    func testMovingAwayHidesAfterTheGrace() {
        var reveal = HoverReveal()
        reveal.setHovering(true, .trigger, at: 0)
        reveal.advance(to: 0.15)
        reveal.setHovering(true, .content, at: 1)
        reveal.setHovering(false, .trigger, at: 1)
        reveal.setHovering(false, .content, at: 2)
        XCTAssertEqual(reveal.deadline, 2.5)
        XCTAssertFalse(reveal.advance(to: 2.4))
        XCTAssertTrue(reveal.advance(to: 2.5))
        XCTAssertFalse(reveal.isShown)
    }

    func testTheHiddenStackCannotOpenItself() {
        var reveal = HoverReveal()
        reveal.setHovering(true, .content, at: 0)
        XCTAssertNil(reveal.deadline)
        XCTAssertFalse(reveal.advance(to: 1))
    }

    func testDismissHidesAtOnce() {
        var reveal = HoverReveal()
        reveal.setHovering(true, .trigger, at: 0)
        reveal.advance(to: 0.15)
        reveal.dismiss()
        XCTAssertFalse(reveal.isShown)
        XCTAssertNil(reveal.deadline)
    }

    // MARK: Recent downloads

    private func record(_ id: String, _ state: DownloadState, path: String = "/tmp/f", updated: TimeInterval) -> DownloadRecord {
        DownloadRecord(id: id, source: .chromium, url: "https://example.com/\(id)", targetPath: path, state: state,
                       startedAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: updated))
    }

    func testLatestFourFinishedFilesNewestFirst() {
        let records = [
            record("a", .complete, updated: 1), record("b", .complete, updated: 5), record("c", .inProgress, updated: 9),
            record("d", .complete, updated: 3), record("e", .cancelled, updated: 8), record("f", .complete, path: "", updated: 7),
            record("g", .complete, updated: 4), record("h", .complete, updated: 2),
        ]
        XCTAssertEqual(RecentDownloads.latest(records).map(\.id), ["b", "g", "d", "h"])
        XCTAssertEqual(RecentDownloads.latest([]).count, 0)
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 100_000)
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(RecentDownloads.relativeTime(now.addingTimeInterval(-20), now: now, locale: locale), "Just now")
        XCTAssertEqual(RecentDownloads.relativeTime(now.addingTimeInterval(-24 * 60), now: now, locale: locale), "24 minutes ago")
        XCTAssertEqual(RecentDownloads.relativeTime(now.addingTimeInterval(-2 * 3600), now: now, locale: locale), "2 hours ago")
    }

    // MARK: Update slot

    func testUpdateBannerTitle() {
        XCTAssertEqual(AvailableUpdate.title, "New Version Available")
        XCTAssertEqual(AvailableUpdate(version: "1.2"), AvailableUpdate(version: "1.2"))
    }
}
