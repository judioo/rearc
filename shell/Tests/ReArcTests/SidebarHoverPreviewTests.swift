import AppKit
import SwiftUI
import XCTest
@testable import ReArc

/// Break check 2026-11-07 night: a tab's hover card hung about 170 pt above
/// its row. A new NSPopover is 320 × 320 until its hosting controller reports
/// a size, which it does after the popover is placed, so the popover was
/// centred on the row at 320 pt and then shrank to the card from the bottom
/// up. The card is now sized before it's shown.
@MainActor
final class SidebarHoverPreviewTests: XCTestCase {
    func testTheCardIsSizedBeforeThePopoverShows() {
        let popover = NSPopover()
        let card = AnyView(Text("about:blank").padding(10).frame(width: 280, alignment: .leading))
        SidebarHoverPreview.setContent(card, of: popover)
        XCTAssertEqual(popover.contentSize.width, 280, accuracy: 0.5)
        XCTAssertLessThan(popover.contentSize.height, 60, "still the popover's 320 pt default")
        XCTAssertGreaterThan(popover.contentSize.height, 20)
    }

    /// Issue 9: the card closes when polls find the pointer off its row, so
    /// the row test must hold for flipped rows, a scrolled list and points
    /// on screen. The window is never ordered in.
    func testThePointerIsOverTheVisiblePartOfARowOnly() {
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 240, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // The list's clip view clips; a plain view no longer does by default.
        let clip = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        clip.clipsToBounds = true
        let row = FlippedView(frame: NSRect(x: 8, y: 70, width: 220, height: 41))
        clip.addSubview(row)
        window.contentView?.addSubview(clip)
        func screen(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: -30000 + x, y: -30000 + y) }
        XCTAssertTrue(SidebarHoverPreview.pointer(at: screen(100, 80), isOver: row))
        XCTAssertFalse(SidebarHoverPreview.pointer(at: screen(100, 60), isOver: row), "below the row")
        XCTAssertFalse(SidebarHoverPreview.pointer(at: screen(4, 80), isOver: row), "beside it")
        XCTAssertFalse(SidebarHoverPreview.pointer(at: screen(100, 105), isOver: row), "the part scrolled out of the list")
        XCTAssertFalse(SidebarHoverPreview.pointer(at: screen(100, 80), isOver: NSView(frame: row.frame)), "a row in no window")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
