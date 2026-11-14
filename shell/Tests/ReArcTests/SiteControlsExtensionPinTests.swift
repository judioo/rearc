import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

private final class QuietBackend: ExtensionToolbarBackend {
    func refreshActions(for engine: any WebEngine, scale: CGFloat) {}
    func runAction(_ extensionID: String, for engine: any WebEngine, anchor: NSView?) {}
    func selectedEngineChanged(_ engine: (any WebEngine)?) {}
}

/// The site controls' Extensions grid as Arc draws it (2026-11-14
/// captures): a solid blue pin button on a pinned tile's corner, a faint
/// one on the tile under the pointer, the extension's name over it. The
/// renders are offscreen, in a borderless window far off any display that
/// is never ordered in; `REARC_SITE_CONTROLS_DIR` names a directory to
/// keep them in.
@MainActor
final class SiteControlsExtensionPinTests: XCTestCase {
    private var backend = QuietBackend()

    private func fixture(pinned: [String]) -> (model: BrowserViewModel, engine: WKEngine) {
        let model = Perf2PipelineTests.model()
        let controller = model.extensions
        let defaults = UserDefaults(suiteName: "rearc-site-controls-pins-\(UUID())")!
        ExtensionPins(pinnedIDs: pinned).save(to: defaults)
        controller.defaults = defaults
        controller.isAvailable = true
        controller.backend = backend
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID()))
        let names = ["Ad Blocker", "Passwords", "Translate", "Grammar", "Shield", "Reader"]
        controller.setActions(names.enumerated().map { index, name in
            ExtensionActionItem(id: name.lowercased(), name: name, iconPNG: Self.icon(hue: CGFloat(index) / CGFloat(names.count)))
        }, for: engine)
        return (model, engine)
    }

    func testThePinButtonOnATilePinsToTheToolbarAndUnpins() {
        let (model, engine) = fixture(pinned: ["passwords"])
        let controller = model.extensions
        func tile(_ id: String) -> SiteControlCenter.ExtensionTile? {
            SiteControlCenter.extensionTiles(controller.actions(for: engine), pins: controller.pins).first { $0.id == id }
        }
        XCTAssertEqual(controller.pinnedActions(for: engine).map(\.id), ["passwords"])
        XCTAssertNil(tile("shield")?.pinBadge(hovered: false))
        XCTAssertEqual(tile("shield")?.pinBadge(hovered: true), .offered)

        controller.togglePin("shield")
        XCTAssertEqual(controller.pinnedActions(for: engine).map(\.id), ["passwords", "shield"], "the toolbar shows it, after the others")
        XCTAssertEqual(tile("shield")?.pinBadge(hovered: false), .pinned)
        XCTAssertEqual(ExtensionPins.load(from: controller.defaults).pinnedIDs, ["passwords", "shield"], "kept across launches")

        controller.togglePin("shield")
        XCTAssertEqual(controller.pinnedActions(for: engine).map(\.id), ["passwords"])
        XCTAssertNil(tile("shield")?.pinBadge(hovered: false))
        XCTAssertEqual(ExtensionPins.load(from: controller.defaults).pinnedIDs, ["passwords"])
    }

    func testThePreviewFlagRunsOnlyWhereVerificationMay() {
        let flag = ["ReArc", SiteControlsPreview.flagPrefix + "Shield:pin"]
        let development: [String: Any] = [:]
        let verification: [String: Any] = [ShippedBuild.releaseKey: true, ShippedBuild.verificationKey: true]
        let shipped: [String: Any] = [ShippedBuild.releaseKey: true]
        let asked = [EngineLaunchOptions.releaseVerificationEnvironmentKey: "1"]
        XCTAssertEqual(SiteControlsPreview.requestedTile(arguments: flag, environment: [:], infoDictionary: development), "Shield:pin")
        XCTAssertEqual(SiteControlsPreview.requestedTile(arguments: flag, environment: asked, infoDictionary: verification), "Shield:pin")
        XCTAssertNil(SiteControlsPreview.requestedTile(arguments: flag, environment: [:], infoDictionary: verification))
        XCTAssertNil(SiteControlsPreview.requestedTile(arguments: flag, environment: asked, infoDictionary: shipped), "a shipped bundle ignores it")
        XCTAssertNil(SiteControlsPreview.requestedTile(arguments: ["ReArc"], environment: [:], infoDictionary: development))
        // Its pins are the flag's, never the person's.
        XCTAssertEqual(SiteControlsPreview.requestedPins(arguments: flag + [SiteControlsPreview.pinsFlagPrefix + "aaaa,bbbb"]).pinnedIDs, ["aaaa", "bbbb"])
        XCTAssertTrue(SiteControlsPreview.requestedPins(arguments: flag).pinnedIDs.isEmpty)
    }

    /// The preview's pins live in memory only: nothing reaches a defaults file (AA-02).
    @MainActor
    func testPreviewPinsAreNeverSaved() {
        let suite = "rearc-preview-pins-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ExtensionPins(pinnedIDs: ["mine"]).save(to: defaults)
        let controller = ExtensionsController(defaults: defaults)
        controller.usePinsInMemory(ExtensionPins(pinnedIDs: ["aaaa"]))
        XCTAssertEqual(controller.pins.pinnedIDs, ["aaaa"])
        controller.togglePin("bbbb")
        XCTAssertEqual(controller.pins.pinnedIDs, ["aaaa", "bbbb"])
        XCTAssertEqual(ExtensionPins.load(from: defaults).pinnedIDs, ["mine"], "the person's pins are untouched")
    }

    /// Pixels at Arc's places: the disc is centred 4 pt inside the tile's
    /// bottom-right corner and reaches 3 pt past it.
    func testPinnedTilesCarryABlueDiscAndTheTileUnderThePointerAFaintOne() throws {
        let (model, engine) = fixture(pinned: ["ad blocker", "passwords"])
        // Tiles: Ad Blocker and Passwords pinned, then Translate, Grammar; Shield, Reader, +.
        let plain = try render(model, engine, preview: nil)
        let hovered = try render(model, engine, preview: "Shield")
        let onPin = try render(model, engine, preview: "Shield:pin")
        try keep(plain, "grid-pinned")
        try keep(hovered, "grid-unpinned-hover-name")
        try keep(onPin, "grid-unpinned-hover-pin")

        // A spot on the disc clear of the pin glyph, and one past the tile's corner.
        func disc(_ column: Int, _ row: Int) -> [NSPoint] {
            let corner = NSPoint(x: Self.margin + CGFloat(column) * 56 + 48, y: Self.margin + CGFloat(row) * 40 + 32)
            return [NSPoint(x: corner.x - 8.5, y: corner.y - 8.5), NSPoint(x: corner.x + 1, y: corner.y - 4)]
        }
        for point in disc(0, 0) + disc(1, 0) {
            XCTAssertTrue(Self.isArcBlue(Self.color(plain, at: point)), "pinned: solid blue at \(point)")
        }
        for point in disc(2, 0) + disc(0, 1) {
            XCTAssertFalse(Self.isBluish(Self.color(plain, at: point)), "unpinned, no pointer: nothing at \(point)")
        }
        for image in [hovered, onPin] {
            for point in disc(0, 1) {
                let color = Self.color(image, at: point)
                XCTAssertTrue(Self.isBluish(color), "under the pointer: the faint disc at \(point)")
                XCTAssertFalse(Self.isArcBlue(color), "faint, not solid, at \(point)")
            }
            for point in disc(1, 1) {
                XCTAssertFalse(Self.isBluish(Self.color(image, at: point)), "the next tile has none")
            }
        }
        // The name sits over the tile under the pointer: dark, above its top
        // edge. The spot is in the label's inset, left of the text.
        let label = NSPoint(x: Self.margin + 3, y: Self.margin + 40 - 4 - 10)
        XCTAssertTrue(Self.isDark(Self.color(hovered, at: label)), "the label's ground over Shield")
        XCTAssertFalse(Self.isDark(Self.color(plain, at: label)), "no label without the pointer")
    }

    /// The pin button and the tile are two buttons: pressing one pins, the
    /// other runs the extension. Pressed through accessibility, in a window
    /// that is never on screen: no event is posted.
    func testPressingThePinButtonPinsAndPressingTheTileRunsTheExtension() throws {
        let (model, engine) = fixture(pinned: ["passwords"])
        let controller = model.extensions
        var ran: [String] = []
        let grid = SiteControlsExtensionGrid(model: model, engine: engine, preview: "Shield", manage: {}, run: { ran.append($0) }, add: {})
            .padding(Self.margin)
        let window = OffscreenWindow(contentRect: NSRect(x: -30000, y: -30000, width: 300, height: 140),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: grid)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        func press(_ label: String) throws {
            let element = try XCTUnwrap(Self.element(labelled: label, in: host), "no button \"\(label)\"")
            XCTAssertTrue((element.accessibilityPerformPress?() as Bool?) ?? false, "\"\(label)\" takes a press")
            settle()
        }
        settle()
        // SwiftUI builds its accessibility tree only for a client that asked.
        let assistive = [NSAccessibility.Attribute(rawValue: "AXManualAccessibility"), NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")]
        for attribute in assistive { (NSApplication.shared as NSObject).accessibilitySetValue(true, forAttribute: attribute) }
        defer { for attribute in assistive { (NSApplication.shared as NSObject).accessibilitySetValue(false, forAttribute: attribute) } }
        _ = host.accessibilityChildren()
        settle()
        XCTAssertNotNil(Self.element(labelled: "Unpin Passwords", in: host), "a pinned tile always has its pin button")
        XCTAssertNil(Self.element(labelled: "Pin Translate", in: host), "an unpinned tile has none away from the pointer")

        try press("Pin Shield")
        XCTAssertEqual(controller.pins.pinnedIDs, ["passwords", "shield"])
        XCTAssertTrue(ran.isEmpty, "the pin button does not run the extension")
        try press("Unpin Shield")
        XCTAssertEqual(controller.pins.pinnedIDs, ["passwords"], "a second press on the same button undoes the first")
        try press("Unpin Passwords")
        XCTAssertTrue(controller.pins.pinnedIDs.isEmpty)
        try press("Shield")
        XCTAssertEqual(ran, ["shield"], "the tile itself still runs the extension")
        XCTAssertTrue(controller.pins.pinnedIDs.isEmpty)
    }

    private static func element(labelled label: String, in root: Any, depth: Int = 0) -> AnyObject? {
        let node = root as AnyObject
        guard depth < 12 else { return nil }
        if (node.accessibilityLabel?() as String?) == label { return node }
        for child in (node.accessibilityChildren?() as [Any]?) ?? [] {
            if let found = element(labelled: label, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The whole panel, for a look beside Arc's.
    func testPanelSnapshots() throws {
        guard ProcessInfo.processInfo.environment["REARC_SITE_CONTROLS_DIR"] != nil else {
            throw XCTSkip("set REARC_SITE_CONTROLS_DIR to write the site controls snapshots")
        }
        let (model, engine) = fixture(pinned: ["ad blocker", "passwords"])
        let site = try XCTUnwrap(SiteControlCenter.site(for: URL(string: "https://example.com/")))
        for (name, preview, dark) in [("panel-pinned", String?.none, false), ("panel-unpinned-hover-name", "Shield", false),
                                      ("panel-unpinned-hover-pin", "Shield:pin", false), ("panel-pinned-hover-unpin", "Passwords:pin", false),
                                      ("panel-dark-hover-name", "Shield", true)] {
            let panel = SiteControlCenterView(model: model, engine: engine, site: site, preview: preview, dismiss: {})
                .background(dark ? Color(white: 0.16) : Color(white: 0.97))
            try keep(try render(panel, size: NSSize(width: SiteControlCenterView.width + 20, height: 330), dark: dark), name)
        }
    }

    // MARK: Offscreen rendering

    private static let margin: CGFloat = 30

    private func render(_ model: BrowserViewModel, _ engine: WKEngine, preview: String?) throws -> NSBitmapImageRep {
        let grid = SiteControlsExtensionGrid(model: model, engine: engine, preview: preview, manage: {}, run: { _ in }, add: {})
            .padding(Self.margin)
            .frame(width: SiteControlCenterView.width + 2 * Self.margin, height: 72 + 2 * Self.margin, alignment: .topLeading)
            .background(Color.white)
        return try render(grid, size: NSSize(width: SiteControlCenterView.width + 2 * Self.margin, height: 72 + 2 * Self.margin), dark: false)
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool) throws -> NSBitmapImageRep {
        let window = OffscreenWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.setContentSize(size)
        for _ in 0 ..< 2 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func keep(_ rep: NSBitmapImageRep, _ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["REARC_SITE_CONTROLS_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// The colour at a point of the view, from its top-left corner.
    private static func color(_ rep: NSBitmapImageRep, at point: NSPoint) -> NSColor? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))
    }

    private static func components(_ color: NSColor?) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        guard let color = color?.usingColorSpace(.sRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    /// The solid disc, #1F2AFF.
    private static func isArcBlue(_ color: NSColor?) -> Bool {
        guard let c = components(color) else { return false }
        return c.red < 0.25 && c.green < 0.3 && c.blue > 0.9
    }

    private static func isBluish(_ color: NSColor?) -> Bool {
        guard let c = components(color) else { return false }
        return c.blue - max(c.red, c.green) > 0.04
    }

    private static func isDark(_ color: NSColor?) -> Bool {
        guard let c = components(color) else { return false }
        return max(c.red, c.green, c.blue) < 0.4
    }

    private static func icon(hue: CGFloat) -> Data? {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor(hue: hue, saturation: 0.7, brightness: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8).fill()
            return true
        }
        return image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:])
    }
}

/// Never constrained onto a screen, never ordered in.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
