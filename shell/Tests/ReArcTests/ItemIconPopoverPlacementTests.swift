import SwiftUI
import XCTest
@testable import ReArc

/// Break check 2026-11-08 (426), issue 21: the Emoji / Icon picker, centred
/// under a sidebar row near the window's left edge, hung about 50 pt past
/// the window. It opens under the item only where that fits, else beside it.
final class ItemIconPopoverPlacementTests: XCTestCase {
    private let width = ItemIconPopover.width
    private let margin = ItemIconPopover.margin

    /// Where the popover's window lands for an edge, in window points (as
    /// measured: centred under the item, or starting at its side).
    private func horizontalSpan(_ edge: Edge, item: CGRect) -> ClosedRange<CGFloat> {
        switch edge {
        case .trailing: return item.maxX ... item.maxX + width
        case .leading: return item.minX - width ... item.minX
        default: return item.midX - width / 2 ... item.midX + width / 2
        }
    }

    func testARowNearTheLeftEdgeOpensBesideItInsideTheWindow() {
        // The break check's row: a 240 pt sidebar on the left, 1200 pt window.
        let row = CGRect(x: 14, y: 300, width: 220, height: 32)
        let edge = ItemIconPopover.arrowEdge(item: row, windowWidth: 1200)
        XCTAssertEqual(edge, .trailing)
        let span = horizontalSpan(edge, item: row)
        XCTAssertGreaterThanOrEqual(span.lowerBound, margin)
        XCTAssertLessThanOrEqual(span.upperBound, 1200 - margin)
        // Centred under the row it would have started left of the window.
        XCTAssertLessThan(horizontalSpan(.bottom, item: row).lowerBound, 0)
    }

    func testARowInASidebarOnTheRightOpensToItsLeft() {
        let row = CGRect(x: 966, y: 300, width: 220, height: 32)
        XCTAssertEqual(ItemIconPopover.arrowEdge(item: row, windowWidth: 1200), .leading)
    }

    func testAnItemWithRoomOpensUnderIt() {
        let tile = CGRect(x: 400, y: 60, width: 60, height: 44)
        XCTAssertEqual(ItemIconPopover.arrowEdge(item: tile, windowWidth: 1200), .bottom)
    }

    func testEveryPlacementStaysInsideWindowsWideEnoughForIt() {
        for width in stride(from: CGFloat(700), through: 1600, by: 100) {
            for x in stride(from: CGFloat(0), through: width - 40, by: 20) {
                let item = CGRect(x: x, y: 200, width: 40, height: 32)
                let span = horizontalSpan(ItemIconPopover.arrowEdge(item: item, windowWidth: width), item: item)
                XCTAssertGreaterThanOrEqual(span.lowerBound, margin, "window \(width), item at \(x)")
                XCTAssertLessThanOrEqual(span.upperBound, width - margin, "window \(width), item at \(x)")
            }
        }
    }
}
