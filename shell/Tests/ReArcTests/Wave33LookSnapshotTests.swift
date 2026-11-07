import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 33: offscreen renders of the theme editor, dark mode and the command
/// bar for docs/observations/recording-vs-rearc/. They run only when
/// `REARC_W33_DIR` names the directory to write into (the window renders
/// also need `REARC_LOOK_FIXTURE`, as wave 31's do). Nothing is put on
/// screen: the windows are never ordered in and sit far off any display.
@MainActor
final class Wave33LookSnapshotTests: XCTestCase {
    private func outputDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["REARC_W33_DIR"] else {
            throw XCTSkip("set REARC_W33_DIR to write the wave 33 snapshots")
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func theme(_ hexes: [String], appearance: SpaceAppearance = .light, intensity: Double = 0.8) -> SpaceTheme {
        let colors = hexes.map { SpaceColor(hex: $0)! }
        return SpaceTheme(red: colors[0].red, green: colors[0].green, blue: colors[0].blue,
                          gradientColors: Array(colors.dropFirst()), appearance: appearance, intensity: intensity)
    }

    /// The editor states the recording shows (§2): empty, a preset, the
    /// three-colour split, and two colours in dark.
    func testEditorSnapshots() throws {
        let directory = try outputDirectory()
        let green = ThemeColorPad.Point(angle: 141.8, radius: 0.22)
        let split = ThemeColorPad.theme(Self.theme(["#2AE48A"]), with: ThemeColorPad.adding(to: ThemeColorPad.adding(to: [green])))
        let yellow = ThemeColorPad.Point(angle: 51, radius: 0.38)
        var dark = ThemeColorPad.theme(.arcDefault, with: ThemeColorPad.adding(to: [yellow]))
        dark.appearance = .dark
        let states: [(String, SpaceTheme)] = [
            ("editor-empty", .arcDefault),
            ("editor-preset-red", ThemeColorPad.theme(.arcDefault, preset: SpaceTheme.editorVibrant[3])),
            ("editor-three-colours", split),
            ("editor-dark", dark),
        ]
        for (name, theme) in states {
            let host = EditorHost(theme: theme)
                .frame(width: SpaceStyleEditor.width, height: SpaceStyleEditor.height)
            let rep = try render(host, size: NSSize(width: SpaceStyleEditor.width, height: SpaceStyleEditor.height),
                                 dark: theme.appearance == .dark)
            try write(rep, to: directory.appendingPathComponent("\(name).png"))
        }
    }

    /// The window in dark on the default theme (frame 2365), in dark on a
    /// two-colour theme (frame 1000), and with the sidebar hidden (frame 100).
    func testWindowSnapshots() throws {
        let directory = try outputDirectory()
        guard let fixture = ProcessInfo.processInfo.environment["REARC_LOOK_FIXTURE"] else {
            throw XCTSkip("set REARC_LOOK_FIXTURE to the wave 31 fixture")
        }
        let yellowBlue = ThemeColorPad.theme(.arcDefault, with: ThemeColorPad.adding(to: [.init(angle: 51, radius: 0.38)]))
        let cases: [(name: String, theme: SpaceTheme?, dark: Bool, hideSidebar: Bool, commandBar: Bool)] = [
            ("window-dark-default", nil, true, false, false),
            ("window-dark-colour", yellowBlue, true, false, false),
            ("window-light-sidebar-hidden", nil, false, true, false),
            ("window-command-bar", nil, false, false, true),
        ]
        for item in cases {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w33-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: copy)
            let persistence = SidebarFilePersistence(fileURL: copy)
            let store = SidebarFilePersistence.loadStore(persistence: persistence)
            let space = store.spaces.first { $0.name == "Imara" } ?? store.spaces[0]
            var theme = item.theme ?? space.theme
            theme.appearance = item.dark ? .dark : .light
            store.setSpaceTheme(space.id, theme: theme)
            store.selectedItemID = nil
            let model = BrowserViewModel(store: store, persistence: persistence, syncEngine: LocalSyncEngine(),
                                         faviconStore: FaviconStore(directory: nil))
            model.sidebarWidth = 228
            if item.hideSidebar { model.toggleSidebar() }
            if item.commandBar {
                model.isCommandBarPresented = true
                model.commandBarText = ""
            }
            let rep = try render(BrowserView(model: model), size: NSSize(width: 1707, height: 1410), dark: item.dark, frameView: true) {
                store.selectedItemID = nil
            }
            try write(rep, to: directory.appendingPathComponent("\(item.name).png"))
        }
    }

    /// The bar alone over a black page, as in frame 2900: switch-to-tab rows
    /// with their space and → chip, the first selected.
    func testCommandBarSnapshot() throws {
        let directory = try outputDirectory()
        let space = UUID()
        let results: [CommandBarSearch.Result] = [
            .init(id: "1", kind: .openTab, title: "KELVIN MOMO | Flying Fish Surprisingly Good Sets", tabID: UUID(), spaceID: space),
            .init(id: "2", kind: .openTab, title: "Field Notes", tabID: UUID(), spaceID: space),
            .init(id: "3", kind: .openTab, title: "Ada Lovelace", tabID: UUID(), spaceID: space),
            .init(id: "4", kind: .openTab, title: "Extensions - Field Notes", tabID: UUID(), spaceID: space),
            .init(id: "5", kind: .command, title: "Contact the Team"),
        ]
        let bar = CommandBarOverlay(text: .constant(""), results: results, highlightedIndex: 0, onMoveHighlight: { _ in },
                                    onSelectResult: { _ in }, onSubmit: {}, onCancel: {}, spaceName: { _ in "Demo" })
            .environment(\.themeChrome, ThemeChromeColors(theme: .arcDefault, dark: false))
            .padding(40)
            .background(Color.black)
        let rep = try render(bar, size: NSSize(width: CommandBarOverlay.arcWidth + 80, height: 460), dark: false)
        try write(rep, to: directory.appendingPathComponent("command-bar.png"))
    }

    // MARK: Offscreen rendering

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, frameView: Bool = false,
                                 settle: () -> Void = {}) throws -> NSBitmapImageRep {
        let window = OffscreenWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                     styleMask: frameView ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.setContentSize(size)
        for pass in 0 ..< 3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(pass == 0 ? 0.5 : 0.3))
            settle()
        }
        let target: NSView = frameView ? host.superview ?? host : host
        let bounds = target.bounds
        let rep = try XCTUnwrap(target.bitmapImageRepForCachingDisplay(in: bounds))
        target.cacheDisplay(in: bounds, to: rep)
        window.close()
        return rep
    }

    private func write(_ rep: NSBitmapImageRep, to url: URL) throws {
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    private struct EditorHost: View {
        @State var theme: SpaceTheme
        var body: some View { SpaceStyleEditor(theme: $theme) }
    }
}

/// Never constrained onto a screen, never ordered in.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
