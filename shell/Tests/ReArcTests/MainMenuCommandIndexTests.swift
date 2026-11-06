import AppKit
import Testing
import SidebarModel
@testable import ReArc

@MainActor
struct MainMenuCommandIndexTests {
    private final class Target: NSObject {
        var calls = 0
        @objc func run(_ sender: Any?) { calls += 1 }
    }

    @Test func menuTraversalAndDispatchUseLiveEnabledItems() throws {
        _ = NSApplication.shared
        let target = Target(), menu = NSMenu(title: "Main"), view = NSMenu(title: "View")
        menu.autoenablesItems = false
        view.autoenablesItems = false
        let parent = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        parent.submenu = view
        menu.addItem(parent)
        let item = NSMenuItem(title: "Actual Size", action: #selector(Target.run(_:)), keyEquivalent: "0")
        item.target = target
        view.addItem(item)
        view.addItem(.separator())
        view.addItem(NSMenuItem(title: "No Action", action: nil, keyEquivalent: ""))
        let row = try #require(MainMenuCommandIndex.commands(in: menu).first)
        #expect(row.path == "View › Actual Size")
        #expect(row.keyEquivalent == "⌘0")
        #expect(MainMenuCommandIndex.commands(in: menu).count == 1)
        #expect(MainMenuCommandIndex.perform(row.id, in: menu))
        #expect(target.calls == 1)
        item.isEnabled = false
        #expect(MainMenuCommandIndex.commands(in: menu).isEmpty)
        #expect(!MainMenuCommandIndex.perform(row.id, in: menu))
        item.isEnabled = true
        item.title = "Other Action"
        #expect(!MainMenuCommandIndex.perform(row.id, in: menu))
    }

    @Test func menuSnapshotMarksAppActionsExactAndFormatsShiftedKeys() throws {
        _ = NSApplication.shared
        let menu = NSMenu(title: "ReArc")
        menu.autoenablesItems = false
        menu.addItem(NSMenuItem(title: "Hide ReArc", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Quit ReArc", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        let rows = MainMenuCommandIndex.commands(in: menu)
        #expect(rows.filter(\.requiresExactQuery).map(\.title) == ["Hide ReArc", "Quit ReArc"])
        #expect(rows.last?.keyEquivalent == "⇧⌘Z")
    }

}
