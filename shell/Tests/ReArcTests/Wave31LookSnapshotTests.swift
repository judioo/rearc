import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 31: the window look. The renderer checks always run; the full-window
/// snapshot for docs/observations/rearc-vs-arc/ runs only when
/// `REARC_LOOK_SNAPSHOT` names the PNG to write (and `REARC_LOOK_FIXTURE`
/// the sidebar.json to show), because it opens an offscreen window.
@MainActor
final class Wave31LookSnapshotTests: XCTestCase {
    func testRenderedThemeImageMatchesTheShaderAtItsCorners() throws {
        let gradient = ThemeGradient(theme: .arcDefault, dark: false)
        let image = ThemeImageCache.render(gradient, width: 64, height: 64)
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let context = CGContext(data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        func sample(_ x: Int, _ y: Int) -> SpaceColor {
            let i = (y * 64 + x) * 4
            return SpaceColor(red: Double(pixels[i]) / 255, green: Double(pixels[i + 1]) / 255, blue: Double(pixels[i + 2]) / 255)
        }
        let topLeft = sample(0, 0), bottomRight = sample(63, 63)
        XCTAssertLessThan(OKLab(topLeft).distance(to: OKLab(SpaceColor(hex: "#D8D9F4")!)), 0.01, topLeft.hex)
        XCTAssertLessThan(OKLab(bottomRight).distance(to: OKLab(SpaceColor(hex: "#F4E5E5")!)), 0.01, bottomRight.hex)
        XCTAssertIdentical(ThemeImageCache.image(for: gradient), ThemeImageCache.image(for: gradient), "cached")
    }

    func testTextureTilesAreTwoHundredPointsAtTwoX() {
        for texture in SpaceTexture.allCases {
            let tile = ThemeTextureTiles.tile(texture)
            XCTAssertEqual(tile.size, NSSize(width: 200, height: 200))
            XCTAssertEqual(tile.representations.first?.pixelsWide, 400)
        }
    }

    func testChromeColoursComeFromTheTheme() {
        let light = ThemeChromeColors(theme: .arcDefault, dark: false)
        let dark = ThemeChromeColors(theme: .arcDefault, dark: true)
        XCTAssertFalse(light.isDark)
        XCTAssertTrue(dark.isDark)
        XCTAssertNotEqual(light.title, dark.title)
        XCTAssertEqual(CardToolbarView.displayURL(URL(string: "https://www.github.com/example/notes?tab=1")!), "github.com/example/notes?tab=1")
        XCTAssertEqual(CardToolbarView.displayURL(URL(string: "https://arc.net/")!), "arc.net")
        XCTAssertNil(CardToolbarView.displayURL(URL(string: "about:blank")!))
        XCTAssertTrue(ToolbarURLPreference.defaultValue, "URL in toolbar is the default, as in the user's Arc")
        XCTAssertEqual(SidebarWidth.standard, 228, "Arc's stored sidebar width")
    }

    func testWindowSnapshot() throws {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["REARC_LOOK_SNAPSHOT"], let fixture = env["REARC_LOOK_FIXTURE"] else {
            throw XCTSkip("set REARC_LOOK_SNAPSHOT and REARC_LOOK_FIXTURE to write the window snapshot")
        }
        let size = NSSize(width: Double(env["REARC_LOOK_WIDTH"] ?? "") ?? 1707, height: Double(env["REARC_LOOK_HEIGHT"] ?? "") ?? 1410)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w31-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("sidebar.json")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: copy)
        let persistence = SidebarFilePersistence(fileURL: copy)
        let store = SidebarFilePersistence.loadStore(persistence: persistence)
        let model = BrowserViewModel(store: store, persistence: persistence, syncEngine: LocalSyncEngine(),
                                     faviconStore: FaviconStore(directory: nil))
        model.sidebarWidth = 228
        if env["REARC_LOOK_SELECT"] == nil {
            // Nothing selected, as in the Arc capture: an empty card.
            store.selectedItemID = nil
        }
        if env["REARC_LOOK_URL_IN_SIDEBAR"] != nil {
            UserDefaults.standard.set(false, forKey: ToolbarURLPreference.key)
        }
        defer { UserDefaults.standard.removeObject(forKey: ToolbarURLPreference.key) }

        let window = UnconstrainedWindow(contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: env["REARC_LOOK_DARK"] == nil ? .aqua : .darkAqua)
        window.contentView = NSHostingView(rootView: BrowserView(model: model))
        window.setContentSize(size)
        window.orderFrontRegardless()
        var deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if env["REARC_LOOK_SELECT"] == nil { store.selectedItemID = nil }
        deadline = Date().addingTimeInterval(2)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        // The theme frame, so the traffic lights are in the picture; 1 px = 1 pt like the Arc capture.
        let frameView = window.contentView!.superview!
        let bounds = frameView.bounds
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = bounds.size
        frameView.cacheDisplay(in: bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: output))
        window.close()
    }
}

extension Wave31LookSnapshotTests {
    /// The theme editor on a stored three-colour Arc theme (cyan, violet, mint).
    func testEditorSnapshot() throws {
        guard let output = ProcessInfo.processInfo.environment["REARC_LOOK_EDITOR"] else {
            throw XCTSkip("set REARC_LOOK_EDITOR to write the editor snapshot")
        }
        let colors = ["#6CBAD9", "#7F7EDC", "#5CD8B8"].map { SpaceColor(hex: $0)! }
        var theme = SpaceTheme(red: colors[0].red, green: colors[0].green, blue: colors[0].blue,
                               gradientColors: Array(colors.dropFirst()), noise: 0.65)
        theme.texture = .grain
        let host = NSHostingView(rootView: EditorHost(theme: theme).padding(20).background(Color(nsColor: .windowBackgroundColor)))
        let window = UnconstrainedWindow(contentRect: NSRect(x: 40, y: 40, width: 340, height: 560),
                                         styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let size = host.fittingSize
        window.setContentSize(size)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        window.close()
    }

    private struct EditorHost: View {
        @State var theme: SpaceTheme
        var body: some View { SpaceStyleEditor(theme: $theme) }
    }
}

/// Keeps the snapshot window at Arc's capture size on a smaller screen.
private final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
