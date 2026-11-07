import AppKit
@testable import Onboarding
import SwiftUI
import XCTest

/// Every onboarding control is a button VoiceOver can press: hosted offscreen
/// (the window is never shown), each act's controls are found in the
/// accessibility tree by label and pressed with AXPress, which must reach the
/// act's controls (QA-2026-11-07 open issue 4).
@MainActor
final class OnboardingAccessibilityTests: XCTestCase {
    private let size = CGSize(width: 1440, height: 900)

    func testBeginPresses() throws {
        var begun = 0
        let tree = try host(BeginButton(height: size.height) { begun += 1 })
        try press("Begin", in: tree)
        XCTAssertEqual(begun, 1)
    }

    func testActOneSwatchesPress() throws {
        var log = Act1Log(start: 0)
        log.submitted = (1, "Kai")
        let frame = Act1Timeline.frame(log, 1 + Act1Timeline.swatchesIn + 1)
        var picked: [Int] = []
        let controls = Act1Controls(text: .constant("Kai"), submit: {}, hover: { _ in }, pick: { picked.append($0) })
        let tree = try host(Act1ControlsView(frame: frame, layout: Act1Layout(size: size), controls: controls))
        for (i, colour) in ProfilePalette.colours.enumerated() {
            try press(colour.name, in: tree)
            XCTAssertEqual(picked.last, i)
        }
    }

    /// The control QA found dead: "Start fresh" was announced as a button
    /// but did nothing on AXPress.
    func testActTwoStartFreshAndEveryOtherControlPress() throws {
        let log = Act2Log(start: 0, sources: ImportSource.demo)
        let frame = Act2Timeline.frame(log, Act2Timeline.ready + 2, Act2Layout(size: size))
        var chosen: [Bool] = [], sources: [Int] = [], categories: [ImportCategory] = []
        let controls = Act2Controls(toggleSource: { sources.append($0) }, toggleCategory: { categories.append($0) },
                                    choose: { chosen.append($0) })
        let tree = try host(Act2ControlsView(frame: frame, layout: Act2Layout(size: size), log: log, controls: controls))
        try press("Start fresh", in: tree)
        XCTAssertEqual(chosen, [false])
        try press("Bring them over", in: tree)
        XCTAssertEqual(chosen, [false, true])
        for cat in log.offered {
            try press(cat.title, in: tree)
        }
        XCTAssertEqual(categories, log.offered)
        for (i, source) in log.sources.enumerated() {
            try press("\(source.browser) \(source.profile)", in: tree)
            XCTAssertEqual(sources.last, i)
        }
    }

    func testActThreeControlsPress() throws {
        var log = Act3Log(start: 0, seeds: Act3Log.suggested(colour: MarkPalette.blue), imported: false)
        log.events = [(0.5, .select(0))]
        let frame = Act3Timeline.frame(log, Act3Timeline.ready + 2)
        var events: [String] = []
        let controls = Act3Controls(name: .constant(""), select: { events.append("select \($0.map(String.init) ?? "none")") },
                                    colour: { events.append("colour \($0)") }, icon: { events.append("icon \($0)") },
                                    add: { events.append("add") }, remove: { events.append("remove") },
                                    done: { events.append("done") })
        let tree = try host(Act3ControlsView(frame: frame, arc: Act2Layout(size: size), layout: Act3Layout(size: size),
                                             controls: controls))
        try press("Done", in: tree)
        try press("Remove space", in: tree)
        try press("Add a space", in: tree)
        XCTAssertEqual(events, ["done", "remove", "add"])
        for (i, colour) in ProfilePalette.colours.enumerated() {
            try press(colour.name, in: tree)
            XCTAssertEqual(events.last, "colour \(i)")
        }
        for icon in Act3Timeline.icons {
            let name = try XCTUnwrap(Act3ControlsView.iconNames[icon], "\(icon) has no spoken name")
            try press(name, in: tree)
            XCTAssertEqual(events.last, "icon \(icon)")
        }
        for space in frame.spaces where space.appear > 0.5 {
            try press(space.name.isEmpty ? "New space" : space.name, in: tree)
            XCTAssertEqual(events.last, "select \(space.id)")
        }
    }

    /// Controls not yet faded in are neither pressable nor in VoiceOver's way.
    func testInactiveControlsAreHidden() throws {
        let log = Act2Log(start: 0, sources: ImportSource.demo)
        let frame = Act2Timeline.frame(log, Act2Timeline.ready + 2, Act2Layout(size: size))
        let tree = try host(Act2ControlsView(frame: frame, layout: Act2Layout(size: size), log: log, controls: nil))
        XCTAssertNil(element("Start fresh", in: tree))
        XCTAssertNil(element("Bring them over", in: tree))
    }

    // MARK: Accessibility tree

    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        // SwiftUI builds its accessibility tree only once something asks for
        // it, as VoiceOver does by setting these on the app.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: name))
        }
    }

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    /// Lays `view` out in a window that is never ordered in.
    private func host(_ view: some View) throws -> NSView {
        let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        windows.append(window)
        hosting.layoutSubtreeIfNeeded()
        _ = hosting.accessibilityChildren()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return hosting
    }

    // SwiftUI's nodes implement NSAccessibility's methods without declaring
    // the protocol, so they are called by selector, as VoiceOver's requests are.

    private func value(_ element: NSObject, _ selector: Selector) -> Any? {
        element.responds(to: selector) ? element.perform(selector)?.takeUnretainedValue() : nil
    }

    private func element(_ label: String, in root: NSObject) -> NSObject? {
        if value(root, #selector(NSAccessibilityProtocol.accessibilityLabel)) as? String == label,
           value(root, #selector(NSAccessibilityProtocol.accessibilityRole)) as? String == NSAccessibility.Role.button.rawValue {
            return root
        }
        for child in value(root, #selector(NSAccessibilityProtocol.accessibilityChildren)) as? [NSObject] ?? [] {
            if let found = element(label, in: child) { return found }
        }
        return nil
    }

    private func press(_ label: String, in root: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let button = try XCTUnwrap(element(label, in: root), "no \"\(label)\" button", file: file, line: line)
        let selector = #selector(NSAccessibilityProtocol.accessibilityPerformPress)
        XCTAssertTrue(button.responds(to: selector), "\"\(label)\" has no AXPress", file: file, line: line)
        typealias Press = @convention(c) (NSObject, Selector) -> Bool
        let pressed = unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector)
        XCTAssertTrue(pressed, "\"\(label)\" ignored AXPress", file: file, line: line)
    }
}
