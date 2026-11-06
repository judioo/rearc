import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// P3.14: the shell's side of the sidebar position. The card's cut, the
/// SwiftUI and AppKit edges, and the setting's save and flip.
@MainActor
final class SidebarSideLayoutTests: XCTestCase {

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-side-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-side-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-side-links-\(UUID().uuidString)")!
        model.automaticPictureInPicture = false
        return model
    }

    func testTheCardIsCutOnTheSidebarsSide() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 300)
        let leftCut = CardShape(radius: 8, sidebarCut: 150, cutEdge: .left).path(in: rect).boundingRect
        XCTAssertEqual(leftCut.minX, 150, accuracy: 0.01)
        XCTAssertEqual(leftCut.maxX, 400, accuracy: 0.01)
        let rightCut = CardShape(radius: 8, sidebarCut: 150, cutEdge: .right).path(in: rect).boundingRect
        XCTAssertEqual(rightCut.minX, 0, accuracy: 0.01)
        XCTAssertEqual(rightCut.maxX, 250, accuracy: 0.01, "the strip a receding right sidebar covers")
        XCTAssertEqual(CardShape(radius: 8, cutEdge: .right).path(in: rect).boundingRect, rect)
    }

    func testTheSlideMirrorsThroughThePlacement() {
        // Showing, 63 % done: the card moves left by as much as it moves right on the left side.
        let slide = SidebarSlide(reveal: 0.63, width: 228, inset: 10, showing: true, laidOut: false)
        let leftOffset = SidebarPlacement(side: .left).pageOffset(slide: Double(slide.offset))
        let rightOffset = SidebarPlacement(side: .right).pageOffset(slide: Double(slide.offset))
        XCTAssertGreaterThan(leftOffset, 0)
        XCTAssertEqual(rightOffset, -leftOffset)
    }

    func testEachSideMapsToItsSwiftUIAndAppKitEdges() {
        XCTAssertEqual(SidebarSide.left.edge, .leading)
        XCTAssertEqual(SidebarSide.right.edge, .trailing)
        XCTAssertEqual(SidebarSide.left.edgeSet, .leading)
        XCTAssertEqual(SidebarSide.right.edgeSet, .trailing)
        XCTAssertEqual(SidebarSide.left.rectEdge, .minX)
        XCTAssertEqual(SidebarSide.right.rectEdge, .maxX)
        XCTAssertEqual(SidebarSide.left.toggleSymbol, "sidebar.left")
        XCTAssertEqual(SidebarSide.right.toggleSymbol, "sidebar.right")
    }

    func testTheTrafficLightsClearTheCardWithoutAToolbar() {
        // The buttons' bottom is 7 pt below their centre.
        XCTAssertGreaterThan(TrafficLightPositioner.cardClearance, TrafficLightPositioner.centreY + 7)
        XCTAssertLessThan(TrafficLightPositioner.cardClearance, TrafficLightPositioner.titlebarHeight)
        // In the toolbar strip they are centred on it, inside the card.
        let inStrip = BrowserView.cardInset + CardToolbarView.height / 2
        XCTAssertGreaterThan(inStrip - 7, BrowserView.cardInset)
    }

    func testSettingTheSideSavesItAndFlipsTheLayout() {
        let model = makeModel()
        model.sidebarSide = .left
        model.isSidebarPeeking = true
        model.setSidebarSide(.right)
        XCTAssertEqual(SidebarSide.load(from: model.externalLinkDefaults), .right)
        XCTAssertFalse(model.isSidebarPeeking, "a floating sidebar is dismissed")
        // The flip is instant under Reduce Motion, else after the fade-out.
        XCTAssertEqual(model.pendingSidebarSide ?? model.sidebarSide, .right)
        model.setSidebarSide(.left)
        XCTAssertEqual(SidebarSide.load(from: model.externalLinkDefaults), .left)
        XCTAssertEqual(model.pendingSidebarSide ?? model.sidebarSide, .left, "the newer choice wins")
    }
}
