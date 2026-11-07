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
}
