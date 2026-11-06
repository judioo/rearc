import Foundation
import Testing
@testable import ArcBenchCore

struct PlanTests {
    @Test func arcDemoBeyondNineUsesArrowsOnly() {
        // The user's Arc: Demo is space 13 of 14; 3 pinned folders, then 5 tabs.
        let plan = ScenarioCatalog.plan(SpaceLayout(home: 12, count: 14, tabNumbers: [4, 5, 6, 7, 8]))
        #expect(!plan.scenarios.contains { $0.id == "space_switch.ctrl_n" })
        #expect(plan.skipped.contains { $0.hasPrefix("space_switch.ctrl_n") })
        let arrows = plan.scenarios.first { $0.id == "space_switch.opt_cmd_arrow" }!
        #expect(arrows.iteration.map(\.chord) == [.optionCommandLeft, .optionCommandRight])
        let tabs = plan.scenarios.first { $0.id == "tab_switch.cmd_n" }!
        #expect(tabs.setup.map(\.chord.label) == ["⌘4"])
        #expect(tabs.iteration.map(\.chord.label) == ["⌘5", "⌘4"])
        let switcher = plan.scenarios.first { $0.id == "tab_switcher" }!
        #expect(switcher.setup.map(\.chord.label) == ["⌘5", "⌘4"])
        #expect(arrows.metricIDs == ["ui.space_switch.ack.opt_cmd_arrow", "ui.space_switch.settled.opt_cmd_arrow", "ui.space_switch.content.opt_cmd_arrow",
                                     "ui.space_switch.ack.opt_cmd_arrow", "ui.space_switch.settled.opt_cmd_arrow", "ui.space_switch.content.opt_cmd_arrow"])
    }

    @Test func rearcSeedRunsBothSpaceKeys() {
        let plan = ScenarioCatalog.plan(SpaceLayout(home: 0, count: 2, tabNumbers: [1, 2, 3, 4, 5]))
        let ctrl = plan.scenarios.first { $0.id == "space_switch.ctrl_n" }!
        #expect(ctrl.iteration.map(\.chord.label) == ["⌃2", "⌃1"])
        let arrows = plan.scenarios.first { $0.id == "space_switch.opt_cmd_arrow" }!
        // The first space has no previous one: next, then back.
        #expect(arrows.iteration.map(\.chord.label) == ["⌥⌘→", "⌥⌘←"])
        #expect(plan.skipped.isEmpty)
        #expect(plan.scenarios.map(\.id) == ["space_switch.ctrl_n", "space_switch.opt_cmd_arrow", "tab_switch.cmd_n", "tab_switcher",
                                             "sidebar_toggle", "new_tab", "open_location", "little_arc"])
    }

    @Test func controlNeighbour() {
        #expect(SpaceLayout(home: 0, count: 2).controlNeighbour == 1)
        #expect(SpaceLayout(home: 8, count: 12).controlNeighbour == 7)
        #expect(SpaceLayout(home: 4, count: 5).controlNeighbour == 3)
        #expect(SpaceLayout(home: 9, count: 12).controlNeighbour == nil)
        #expect(SpaceLayout(home: 0, count: 1).controlNeighbour == nil)
        #expect(SpaceLayout(home: 0, count: 1).arrowTowardNeighbour == nil)
    }

    @Test func everyIterationReturnsToItsStart() {
        // Each iteration is a there-and-back pair: same key twice, or a key and its inverse.
        let inverse: [String: String] = ["⌃2": "⌃1", "⌥⌘→": "⌥⌘←", "⌥⌘←": "⌥⌘→", "⌘2": "⌘1", "⌘T": "Esc", "⌘L": "Esc", "⌥⌘N": "⌘W"]
        for scenario in ScenarioCatalog.plan(SpaceLayout(home: 0, count: 2, tabNumbers: [1, 2, 3, 4, 5])).scenarios {
            let keys = scenario.iteration.map(\.chord.label)
            #expect(keys.count == 2, "\(scenario.id)")
            #expect(keys[0] == keys[1] || inverse[keys[0]] == keys[1], "\(scenario.id): \(keys)")
        }
    }

    @Test func littleArcCloseNeedsItsOwnWindow() {
        let plan = ScenarioCatalog.plan(SpaceLayout(home: 0, count: 2), groups: ["little_arc"])
        let steps = plan.scenarios[0].iteration
        #expect(steps[0].measure == .windowOpens("ui.little_arc_open.window.shortcut"))
        #expect(!steps[0].requiresOpenedWindow)
        #expect(steps[1].chord == .commandW)
        #expect(steps[1].requiresOpenedWindow)
    }

    @Test func metricIDsMatchTheInAppBench() {
        let ids = Set(ScenarioCatalog.plan(SpaceLayout(home: 0, count: 2, tabNumbers: [1, 2, 3, 4, 5])).scenarios.flatMap(\.metricIDs))
        for id in ["ui.space_switch.ack.ctrl_n", "ui.tab_switch.ack.cmd_n", "ui.tab_switch.content.cmd_n", "ui.sidebar_toggle.ack.show",
                   "ui.sidebar_toggle.ack.hide", "ui.new_tab.ack", "ui.open_location.ack", "ui.little_arc_open.window.shortcut",
                   "ui.tab_switcher.ack"] {
            #expect(ids.contains(id), "\(id)")
        }
    }

    @Test func selectionAndRegions() {
        let content = Region.content(0.22)
        let plan = ScenarioCatalog.plan(SpaceLayout(home: 0, count: 2), groups: ["new_tab", "sidebar_toggle"], regions: ["new_tab": content])
        #expect(plan.scenarios.map(\.id) == ["sidebar_toggle", "new_tab"])
        #expect(plan.scenarios[1].region == content)
        #expect(plan.scenarios[0].region == .window)
    }

    @Test func tooFewItemsSkipTabScenarios() throws {
        let plan = ScenarioCatalog.plan(SpaceLayout(home: 0, count: 2, tabNumbers: [3]), groups: ["tab_switch", "tab_switcher"])
        #expect(plan.scenarios.isEmpty)
        #expect(plan.skipped.count == 2)
        // Unknown layout: ⌘1 and ⌘2.
        let keys = try #require(SpaceLayout(home: 0, count: 2).tabKeys)
        #expect(keys.first == 1 && keys.second == 2)
    }

    @Test func digitKeyCodes() {
        #expect(KeyChord.digit(1, .control).keyCode == 18)
        #expect(KeyChord.digit(5, .command).keyCode == 23)
        #expect(KeyChord.digit(9, .control).keyCode == 25)
        #expect(KeyChord.optionCommandLeft.isArrow)
        #expect(!KeyChord.controlTab.isArrow)
        #expect(KeyChord.controlTab.label == "⌃Tab")
    }
}

struct ArcSidebarTests {
    /// The shape of StorableSidebar.json (ids and items alternate).
    let json = """
    {"sidebar": {"containers": [
      {"global": {}},
      {"topAppsContainerIDs": [{"default": true}, "F1"],
       "spaces": [
        "S1", {"id": "S1", "title": "Personal", "profile": {"default": true},
               "containerIDs": ["unpinned", "U1", "pinned", "P1"]},
        "S2", {"id": "S2", "title": "Demo", "profile": {"custom": {"_0": {"directoryBasename": "Profile 1"}}},
               "containerIDs": ["unpinned", "U2", "pinned", "P2"]}
      ],
       "items": [
        "F1", {"id": "F1", "childrenIds": ["fav"]},
        "U1", {"id": "U1", "childrenIds": ["a", "b"]},
        "P1", {"id": "P1", "childrenIds": ["k"]},
        "U2", {"id": "U2", "childrenIds": ["c", "d", "e", "f", "g"]},
        "P2", {"id": "P2", "childrenIds": ["h", "i", "j"]},
        "a", {"id": "a", "data": {"tab": {}}}, "b", {"id": "b", "data": {"tab": {}}}, "k", {"id": "k", "data": {"list": {}}},
        "c", {"id": "c", "data": {"tab": {}}}, "d", {"id": "d", "data": {"tab": {}}}, "e", {"id": "e", "data": {"tab": {}}},
        "f", {"id": "f", "data": {"tab": {}}}, "g", {"id": "g", "data": {"tab": {}}},
        "h", {"id": "h", "data": {"list": {}}}, "i", {"id": "i", "data": {"list": {}}}, "j", {"id": "j", "data": {"easel": {}}}
       ]}
    ]}}
    """

    @Test func spacesInSidebarOrder() throws {
        let spaces = try ArcSidebar.spaces(from: Data(json.utf8))
        #expect(spaces.map(\.title) == ["Personal", "Demo"])
        #expect(spaces.map(\.index) == [0, 1])
        #expect(spaces[1].pinned == 3)
        #expect(spaces[1].unpinned == 5)
        #expect(spaces[1].items == 8)
        #expect(spaces[0].defaultProfile)
        #expect(!spaces[1].defaultProfile)
    }

    @Test func commandNumbersSkipFolders() throws {
        let spaces = try ArcSidebar.spaces(from: Data(json.utf8))
        // Personal: its profile's favorite, then pinned folder k, then Today tabs a, b.
        #expect(spaces[0].favorites == 1)
        #expect(spaces[0].sidebarItems == [.tab, .folder, .tab, .tab])
        #expect(spaces[0].tabNumbers == [1, 3, 4])
        // Demo (another profile, no favorites): folders h, i, an easel j, then five tabs.
        #expect(spaces[1].favorites == 0)
        #expect(spaces[1].sidebarItems == [.folder, .folder, .other, .tab, .tab, .tab, .tab, .tab])
        #expect(spaces[1].tabNumbers == [4, 5, 6, 7, 8])
    }

    @Test func commandNineIsTheLastItem() {
        var space = ArcSpace(id: "x", title: "x", index: 0, favorites: 0, pinned: 0, unpinned: 10, defaultProfile: true)
        space.sidebarItems = Array(repeating: .tab, count: 10)
        #expect(space.tabNumbers == Array(1 ... 8))
        space.sidebarItems = Array(repeating: .tab, count: 9)
        #expect(space.tabNumbers == Array(1 ... 9))
    }

    @Test func malformedFileThrows() {
        #expect(throws: ArcSidebar.ParseError.self) { try ArcSidebar.spaces(from: Data(#"{"sidebar": {}}"#.utf8)) }
    }
}

struct OptionsTests {
    @Test func defaults() throws {
        let options = try #require(try Options.parse([]))
        #expect(options.apps == [.arc, .rearc])
        #expect(options.iterations == 20)
        #expect(options.groups == ScenarioCatalog.groups)
        #expect(!options.dryRun && !options.restartArc && options.keepFrames == nil)
        #expect(options.detection.quiet == 0.150)
    }

    @Test func parsesEverything() throws {
        let options = try #require(try Options.parse([
            "--dry-run", "--apps", "rearc", "--scenarios", "new_tab,tab_switch", "--iterations", "5", "--warmups", "1",
            "--keep-frames", "/tmp/f", "--restart-arc", "--region", "tab_switch=sidebar", "--sidebar-fraction", "0.3",
            "--quiet-ms", "200", "--area-threshold", "0.01", "--bundle", "/x/ReArc.app", "--arc-sidebar", "hidden",
        ]))
        #expect(options.arcSidebar == "hidden")
        #expect(options.dryRun && options.restartArc)
        #expect(options.apps == [.rearc])
        #expect(options.groups == ["new_tab", "tab_switch"])
        #expect(options.iterations == 5 && options.warmups == 1)
        #expect(options.keepFrames == "/tmp/f")
        // The named region uses the fraction given after it.
        #expect(options.regions["tab_switch"] == .sidebar(0.3))
        #expect(options.detection.quiet == 0.2)
        #expect(options.detection.areaThreshold == 0.01)
        #expect(options.bundle == "/x/ReArc.app")
    }

    @Test func helpReturnsNil() throws {
        #expect(try Options.parse(["--help"]) == nil)
    }

    @Test(arguments: [["--apps", "chrome"], ["--scenarios", "peek"], ["--iterations", "0"], ["--region", "new_tab"],
                      ["--region", "new_tab=middle"], ["--frobnicate"], ["--iterations"], ["--arc-sidebar", "maybe"]])
    func rejects(arguments: [String]) {
        #expect(throws: Options.UsageError.self) { try Options.parse(arguments) }
    }
}
