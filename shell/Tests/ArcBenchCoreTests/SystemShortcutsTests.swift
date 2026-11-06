import Foundation
import Testing
@testable import ArcBenchCore

struct SystemShortcutsTests {
    /// A symbolichotkeys plist as macOS writes it: Switch to Desktop 1 and 2
    /// on (⌃1, ⌃2), Desktop 3 off, Move left a space (⌃← with the fn bit).
    static let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict><key>AppleSymbolicHotKeys</key><dict>
      <key>118</key><dict><key>enabled</key><true/><key>value</key><dict>
        <key>parameters</key><array><integer>65535</integer><integer>18</integer><integer>262144</integer></array>
        <key>type</key><string>standard</string></dict></dict>
      <key>119</key><dict><key>enabled</key><true/><key>value</key><dict>
        <key>parameters</key><array><integer>65535</integer><integer>19</integer><integer>262144</integer></array>
        <key>type</key><string>standard</string></dict></dict>
      <key>120</key><dict><key>enabled</key><false/><key>value</key><dict>
        <key>parameters</key><array><integer>65535</integer><integer>20</integer><integer>262144</integer></array>
        <key>type</key><string>standard</string></dict></dict>
      <key>79</key><dict><key>enabled</key><true/><key>value</key><dict>
        <key>parameters</key><array><integer>65535</integer><integer>123</integer><integer>8650752</integer></array>
        <key>type</key><string>standard</string></dict></dict>
      <key>164</key><dict><key>enabled</key><false/></dict>
    </dict></dict></plist>
    """

    @Test func readsTheEnabledShortcuts() {
        let reserved = SystemShortcuts.reserved(fromPlist: Data(Self.plist.utf8))
        #expect(reserved.count == 3)
        #expect(reserved.contains { $0.matches(.digit(1, .control)) && $0.name == "macOS's Mission Control › Switch to Desktop 1" })
        #expect(reserved.contains { $0.matches(.digit(2, .control)) })
        // Off in System Settings: ⌃3 reaches the app.
        #expect(!reserved.contains { $0.matches(.digit(3, .control)) })
        // ⌃← (the fn bit ignored) is taken; ⌥⌘← is not.
        #expect(reserved.contains { $0.matches(KeyChord("←", 123, .control)) })
        #expect(!reserved.contains { $0.matches(.optionCommandLeft) })
    }

    @Test func garbageGivesNothing() {
        #expect(SystemShortcuts.reserved(fromPlist: Data("not a plist".utf8)).isEmpty)
        #expect(SystemShortcuts.reserved(hotKeys: ["118": ["enabled": true]]).isEmpty)
    }

    @Test func planSkipsScenariosWithATakenKey() {
        let reserved = SystemShortcuts.reserved(fromPlist: Data(Self.plist.utf8))
        let plan = ScenarioCatalog.plan(SpaceLayout(home: 0, count: 2, tabNumbers: [1, 2, 3, 4, 5]), reserved: reserved)
        // ⌃2 would switch the macOS desktop: the ⌃n space switch is left out, the arrows stay.
        #expect(!plan.scenarios.contains { $0.id == "space_switch.ctrl_n" })
        #expect(plan.scenarios.contains { $0.id == "space_switch.opt_cmd_arrow" })
        #expect(plan.skipped == ["space_switch.ctrl_n: ⌃2 is macOS's Mission Control › Switch to Desktop 2, so the key never reaches the app"])
    }

    @Test func arcsGlobalLittleArcKeySkipsReArcsLittleArc() {
        let plan = ScenarioCatalog.plan(SpaceLayout(home: 0, count: 2, tabNumbers: [1, 2]), reserved: [SystemShortcuts.arcLittleArc])
        #expect(!plan.scenarios.contains { $0.id == "little_arc" })
        #expect(plan.skipped.contains { $0.hasPrefix("little_arc: ⌥⌘N is Arc's global New Little Arc shortcut") })
        #expect(plan.scenarios.count == ScenarioCatalog.plan(SpaceLayout(home: 0, count: 2, tabNumbers: [1, 2])).scenarios.count - 1)
    }

    @Test func escapeMayGoToTheAppsOwnPanel() {
        let plan = ScenarioCatalog.plan(SpaceLayout(home: 0, count: 2, tabNumbers: [1, 2]))
        for id in ["new_tab", "open_location"] {
            let scenario = plan.scenarios.first { $0.id == id }!
            #expect(scenario.iteration.map(\.toOwnPanel) == [false, true])
        }
        // Every other key needs the browser window itself to be key.
        #expect(plan.scenarios.filter { !["new_tab", "open_location"].contains($0.id) }.allSatisfy { $0.iteration.allSatisfy { !$0.toOwnPanel } })
    }
}
