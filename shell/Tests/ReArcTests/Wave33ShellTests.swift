import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 33: shell timing and behaviour corrected against the user's
/// recording of Arc (docs/ARC-RECORDING-ANALYSIS.md).
@MainActor
final class Wave33ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a"), Space(name: "Work", sortRank: "b")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w33-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w33-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w33-links-\(UUID().uuidString)")!
        model.automaticPictureInPicture = false
        return model
    }

    // MARK: ⌘S (§3)

    func testSidebarToggleIsAQuickPushWithNoOvershoot() {
        // One intermediate frame at 10 fps in 4 of 4 events: ≈ 100–150 ms.
        XCTAssertGreaterThanOrEqual(BrowserViewModel.sidebarAnimationDuration, 0.1)
        XCTAssertLessThanOrEqual(BrowserViewModel.sidebarAnimationDuration, 0.15)
        XCTAssertLessThan(BrowserViewModel.sidebarAnimationDuration, 0.18, "faster than the old 180 ms budget")
        // A timing curve, not a spring: its control points stay inside 0…1, so it cannot pass its end.
        XCTAssertEqual(String(describing: BrowserViewModel.sidebarAnimation).contains("spring"), false)
    }

    func testHideLaysThePageOutWideAtOnceAndShowOnlyAtTheEnd() {
        let model = makeModel()
        XCTAssertTrue(model.isSidebarVisible)
        XCTAssertTrue(model.isSidebarLaidOut)
        model.toggleSidebar()
        XCTAssertFalse(model.isSidebarVisible)
        XCTAssertFalse(model.isSidebarLaidOut, "hide: the page goes wide in the first frame (frame 90)")
        XCTAssertEqual(model.sidebarReveal, 0)
        // With no views on screen the animation completes at once.
        model.toggleSidebar()
        XCTAssertTrue(model.isSidebarVisible)
        XCTAssertEqual(model.sidebarReveal, 1)
        XCTAssertTrue(model.isSidebarLaidOut, "laid out narrow once the show completes")
        XCTAssertFalse(model.isSidebarSliding)
    }

    func testTheCardSlidesRigidlyAndIsNeverResizedMidSlide() {
        // Recording px at 0.703 px/pt: sidebar 160 px = 228 pt, card inset 10 pt.
        let width: CGFloat = 228, inset: CGFloat = 10
        // Hide, frame 125 (44 % done): the wide page is in place and the sidebar still covers part of it.
        let hiding = SidebarSlide(reveal: 0.56, width: width, inset: inset, showing: false, laidOut: false)
        XCTAssertEqual(hiding.offset, 0, "the page does not move: the receding sidebar uncovers it")
        XCTAssertEqual(hiding.cut, 0.56 * width - inset, accuracy: 0.01)
        // Show, frame 135 (63 % done): the wide page moves with the edge (logo 601 + (edge − 47)).
        let showing = SidebarSlide(reveal: 0.63, width: width, inset: inset, showing: true, laidOut: false)
        XCTAssertEqual(showing.cut, 0)
        XCTAssertEqual(inset + showing.offset, 0.63 * width + inset * 0.37, accuracy: 0.01, "card edge follows the sidebar's")
        XCTAssertGreaterThanOrEqual(inset + showing.offset, 0.63 * width, "never under the sidebar")
        // At rest the card is laid out, so neither applies.
        XCTAssertEqual(SidebarSlide(reveal: 1, width: width, inset: inset, showing: true, laidOut: true), SidebarSlide())
        XCTAssertEqual(SidebarSlide(reveal: 0, width: width, inset: inset, showing: false, laidOut: false), SidebarSlide())
    }

    func testCardShapeCutsTheStripTheSlidingSidebarCovers() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(CardShape(radius: 8).path(in: rect).boundingRect, rect)
        let cut = CardShape(radius: 8, leadingCut: 150).path(in: rect).boundingRect
        XCTAssertEqual(cut.minX, 150, accuracy: 0.01)
        XCTAssertEqual(cut.maxX, 400, accuracy: 0.01)
        XCTAssertEqual(CardShape(radius: 8, leadingCut: 900).path(in: rect).boundingRect.width, 0, accuracy: 0.01)
    }

    // MARK: Space switch (§4)

    func testClickedSpaceSwitchSettlesInTwoToThreeHundredMillisecondsWithNoBlend() {
        XCTAssertEqual(ThemeCrossfadeView.duration, 0, "the theme changes between two frames")
        var paging = SpacePaging(pageCount: 3, page: 0)
        paging.go(to: 1, pageCount: 3, animated: true, at: 0)
        var maximum = 0.0
        var settled: Double?
        for step in 1 ... 60 {
            let t = Double(step) * 0.005
            let position = paging.position(at: t)
            maximum = max(maximum, position)
            if settled == nil, abs(position - 1) < 0.02 { settled = t }
        }
        XCTAssertLessThanOrEqual(maximum, 1.0 + 1e-9, "no overshoot")
        let time = try? XCTUnwrap(settled)
        XCTAssertGreaterThanOrEqual(time ?? 0, 0.2)
        XCTAssertLessThanOrEqual(time ?? 1, 0.3)
        XCTAssertLessThan(paging.position(at: 0.02), 0.1, "the slide starts slowly")
        // A swipe release keeps the softer paging spring.
        XCTAssertEqual(paging.spring, .page)
        XCTAssertEqual(paging.clickSpring, .click)
    }

    // MARK: Command bar (§8)

    func testCommandBarIsCentredOnTheWindowAndOnlyItsSelectedRowIsTinted() {
        XCTAssertEqual(CommandBarOverlay.arcWidth, 765, "538 px at 0.703 px/pt")
        XCTAssertEqual(CommandBarOverlay.topFraction, 0.38, accuracy: 0.005, "top 378 px down a 990 px window")
        let accent = SpaceColor(hex: "#2731FF")!
        let selected = ThemeChromeColors.selection(accent: accent)
        XCTAssertLessThan(OKLab(selected).distance(to: OKLab(SpaceColor(hex: "#858AFF")!)), 0.01, selected.hex)
    }

    // MARK: Toasts (§6)

    func testTitlebarDoesNotInterceptTheToastOrPageToolbar() {
        let frame = TrafficLightPositioner.titlebarFrame(windowSize: NSSize(width: 1280, height: 820))
        XCTAssertEqual(frame.height, 47)
        XCTAssertEqual(frame.maxX, 84)
        for index in 0..<3 {
            let center = NSPoint(x: TrafficLightPositioner.firstCentreX + CGFloat(index) * TrafficLightPositioner.pitch,
                                 y: 820 - TrafficLightPositioner.centreY)
            XCTAssertTrue(frame.contains(center))
        }
        // Logged failing Share frame: (1535, 920, 22, 20), window origin (299, 140).
        XCTAssertFalse(frame.contains(NSPoint(x: 1546 - 299, y: 930 - 140)))
        XCTAssertFalse(frame.contains(NSPoint(x: 100, y: 790)), "sidebar toggle also stays clickable")
    }

    func testToastsStayAboutFiveSecondsAndCarryTheirAction() {
        XCTAssertEqual(ShellToast.defaultDuration, 5, accuracy: 0.5, "on screen 4.6–5.0 s")
        let model = makeModel()
        model.showToast("Copied Current URL", systemImage: "link", action: .share(URL(string: "https://arc.net")!))
        XCTAssertEqual(model.toast?.message, "Copied Current URL")
        XCTAssertEqual(model.toast?.action, .share(URL(string: "https://arc.net")!))
        XCTAssertEqual(ShellToast.segments("Space deleted! Use ⌘Z to undo.", keycaps: ["⌘Z"]).map(\.isKeycap), [false, true, false])
    }

    func testDeletingASpaceSaysSo() {
        let model = makeModel()
        let work = model.store.spaces[1].id
        model.deleteSpace(work)
        XCTAssertEqual(model.toast?.message, "Space deleted")
    }

    // MARK: Media strip (§7)

    func testTheStripHidesWhileItsVideoIsInPictureInPicture() {
        var a: SidebarModel.Tab!
        var b: SidebarModel.Tab!
        let model = makeModel { store in
            a = store.addTab(kind: .today, title: "Video", url: URL(string: "https://video.test")!)
            b = store.addTab(kind: .today, title: "News", url: URL(string: "https://news.test")!)
            store.selectTab(b.id)
        }
        model.mediaStateByTab[a.id] = WebMediaState(isPlaying: true, canPictureInPicture: true)
        XCTAssertEqual(model.mediaStrips(in: nil), [a.id])
        model.mediaStateByTab[a.id] = WebMediaState(isPlaying: true, canPictureInPicture: true, isPictureInPicture: true)
        XCTAssertEqual(model.mediaStrips(in: nil), [], "pop-out removes the strip while PiP is open (270.1 s)")
        model.mediaStateByTab[a.id] = WebMediaState(isPaused: true, canPictureInPicture: true)
        XCTAssertEqual(model.mediaStrips(in: nil), [a.id], "it comes back when PiP closes (276.5 s)")
    }
}
