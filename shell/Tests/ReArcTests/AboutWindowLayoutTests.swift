import AppKit
import XCTest
@testable import ReArc

/// The sting sits in its own band and the text stacks below it (QA-483 B11).
@MainActor
final class AboutWindowLayoutTests: XCTestCase {
    private func stingView(in view: NSView) -> AboutStingView? {
        if let sting = view as? AboutStingView { return sting }
        return view.subviews.lazy.compactMap { self.stingView(in: $0) }.first
    }

    func testTheStingKeepsItsBandWhateverTheGIFsSize() throws {
        // The sting falls back to NSApp's icon without its GIF (as under xctest).
        _ = NSApplication.shared
        let controller = AboutWindowController { _ in }
        let window = try XCTUnwrap(controller.window), content = try XCTUnwrap(window.contentView)
        let sting = try XCTUnwrap(stingView(in: content))
        // The GIF's own size, which used to set the view's.
        sting.image = NSImage(size: NSSize(width: 720, height: 406))
        window.setContentSize(content.fittingSize)
        content.layoutSubtreeIfNeeded()

        let band = (AboutWindowController.width * AboutStingView.aspect).rounded()
        let frame = sting.convert(sting.bounds, to: content)
        XCTAssertEqual(frame.width, AboutWindowController.width, accuracy: 0.5)
        XCTAssertEqual(frame.height, band, accuracy: 0.5)
        XCTAssertEqual(window.frame.width, AboutWindowController.width, accuracy: 0.5, "the window keeps Arc's compact width")
        // Version, engine, copyright and the credits paragraph need more than 100 points below the band.
        XCTAssertGreaterThan(content.bounds.height - band, 100, "the text has its own room below the sting")
        XCTAssertTrue(sting.clipsToBounds)
        XCTAssertEqual(sting.convert(sting.bounds, to: nil).maxY, content.bounds.height, accuracy: 0.5,
                       "the sting starts at the window's top edge, under the title bar")
    }
}
