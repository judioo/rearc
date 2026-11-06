import XCTest
@testable import SidebarModel

/// The downloads quick view's motion as measured from Arc
/// (docs/arc-recordings/2026-11-06-downloads-quick-view.md).
final class DownloadsQuickViewTests: XCTestCase {
    private typealias Q = DownloadsQuickView
    private let frame = 1.0 / 60

    // MARK: Opening

    func testTheStackStartsFoldedOntoTheButton() {
        for row in 0..<4 {
            let pose = Q.pose(.opening, fromBottom: row, elapsed: 0)
            XCTAssertEqual(pose.offset, Q.originDrop + Double(row) * Q.rowPitch, accuracy: 1e-9)
            XCTAssertEqual(pose.opacity, 0)
        }
    }

    func testTheStackSettlesExactlyAtTheEnd() {
        for row in 0..<4 {
            XCTAssertEqual(Q.pose(.opening, fromBottom: row, elapsed: Q.openDuration), .rest)
        }
        XCTAssertEqual(Q.pose(.opening, fromBottom: 3, elapsed: 5), .rest)
    }

    /// Recorded spread, frame by frame: about 0.5, 0.78, 0.88, 0.94, 0.97.
    func testSpreadMatchesTheRecording() {
        let recorded = [0.5, 0.78, 0.88, 0.935, 0.97]
        for (index, value) in recorded.enumerated() {
            XCTAssertEqual(Q.spread(at: Double(index + 1) * frame), value, accuracy: 0.05, "frame \(index + 1)")
        }
    }

    func testSpreadNeverOvershoots() {
        var previous = 0.0
        for step in 0...60 {
            let value = Q.spread(at: Double(step) * Q.openDuration / 60)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 1 + 1e-12)
            previous = value
        }
    }

    /// The rows unfold: the higher a row, the further it still has to travel.
    func testHigherRowsTravelFurther() {
        let offsets = (0..<4).map { Q.pose(.opening, fromBottom: $0, elapsed: 2 * frame).offset }
        XCTAssertEqual(offsets, offsets.sorted())
        XCTAssertLessThan(offsets[0], 5)
        XCTAssertEqual(offsets[3], 40, accuracy: 6)
    }

    func testTheBottomRowFadesInFirst() {
        let opacities = (0..<4).map { Q.pose(.opening, fromBottom: $0, elapsed: 2 * frame).opacity }
        XCTAssertEqual(opacities, opacities.sorted(by: >))
        XCTAssertGreaterThan(opacities[0], opacities[3])
    }

    // MARK: Closing

    func testClosingStartsAtRest() {
        for row in 0..<4 {
            XCTAssertEqual(Q.pose(.closing, fromBottom: row, elapsed: 0), .rest)
        }
    }

    /// The bottom row is gone after about 2 frames, the top one after about 5.
    func testClosingFadesBottomRowFirst() {
        XCTAssertEqual(Q.pose(.closing, fromBottom: 0, elapsed: 2.5 * frame).opacity, 0)
        XCTAssertGreaterThan(Q.pose(.closing, fromBottom: 3, elapsed: 2.5 * frame).opacity, 0)
        XCTAssertEqual(Q.pose(.closing, fromBottom: 3, elapsed: 5 * frame).opacity, 0)
        for row in 0..<4 {
            XCTAssertEqual(Q.pose(.closing, fromBottom: row, elapsed: Q.closeDuration).opacity, 0)
        }
    }

    func testClosingRowsSinkTowardTheButton() {
        let early = Q.pose(.closing, fromBottom: 3, elapsed: 3 * frame).offset
        let late = Q.pose(.closing, fromBottom: 3, elapsed: 5 * frame).offset
        XCTAssertGreaterThan(early, 0)
        XCTAssertGreaterThan(late, early)
        XCTAssertLessThanOrEqual(Q.pose(.closing, fromBottom: 3, elapsed: 1).offset, Q.closeSink)
    }

    func testTheCloseIsQuickerThanTheOpen() {
        XCTAssertLessThan(Q.closeDuration, Q.openDuration)
        XCTAssertEqual(Q.closeDuration, 0.096, accuracy: 1e-9)
    }

    func testANegativeRowCountsAsTheBottomRow() {
        XCTAssertEqual(Q.pose(.opening, fromBottom: -1, elapsed: frame), Q.pose(.opening, fromBottom: 0, elapsed: frame))
    }
}
