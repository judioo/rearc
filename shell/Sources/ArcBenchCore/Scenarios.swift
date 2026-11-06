import Foundation

public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)

    /// macOS order: ⌃⌥⇧⌘.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A key press with modifiers; `keyCode` is the ANSI virtual key code.
public struct KeyChord: Hashable, Codable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    public var key: String

    public init(_ key: String, _ keyCode: UInt16, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var label: String { modifiers.symbols + key }
    /// Arrow keys carry the function and keypad flags on a real keyboard.
    public var isArrow: Bool { (123 ... 126).contains(keyCode) }

    static let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    /// ⌃n / ⌘n for n in 1…9.
    public static func digit(_ number: Int, _ modifiers: KeyModifiers) -> KeyChord {
        precondition((1 ... 9).contains(number))
        return KeyChord("\(number)", digitCodes[number - 1], modifiers)
    }

    public static let commandS = KeyChord("S", 1, .command)
    public static let commandT = KeyChord("T", 17, .command)
    public static let commandL = KeyChord("L", 37, .command)
    public static let commandW = KeyChord("W", 13, .command)
    public static let optionCommandN = KeyChord("N", 45, [.option, .command])
    public static let escape = KeyChord("Esc", 53)
    public static let controlTab = KeyChord("Tab", 48, .control)
    public static let optionCommandLeft = KeyChord("←", 123, [.option, .command])
    public static let optionCommandRight = KeyChord("→", 124, [.option, .command])
}

/// What one key press measures.
public enum Measure: Equatable, Codable, Sendable {
    /// Pixel timing: `<base>.ack[.suffix]` and `<base>.settled[.suffix]` over
    /// the scenario's region, and `<base>.content[.suffix]` (the first change
    /// in the content region) when `content` is set.
    case frames(base: String, suffix: String?, content: Bool)
    /// A new window of the app appearing in the window list.
    case windowOpens(String)
    /// The window the previous step opened leaving the window list.
    case windowCloses(String)
    /// Setup only.
    case none

    public var metricIDs: [String] {
        switch self {
        case let .frames(base, suffix, content):
            let tail = suffix.map { ".\($0)" } ?? ""
            return ["\(base).ack\(tail)", "\(base).settled\(tail)"] + (content ? ["\(base).content\(tail)"] : [])
        case let .windowOpens(id), let .windowCloses(id): return [id]
        case .none: return []
        }
    }
}

public struct Step: Equatable, Codable, Sendable {
    public var chord: KeyChord
    public var measure: Measure
    /// Post only when the key window is the window the previous step opened
    /// (⌘W must close Little Arc, never a tab of the browser window).
    public var requiresOpenedWindow: Bool

    public init(_ chord: KeyChord, _ measure: Measure = .none, requiresOpenedWindow: Bool = false) {
        self.chord = chord
        self.measure = measure
        self.requiresOpenedWindow = requiresOpenedWindow
    }
}

/// One scenario: setup keys, then warm-ups and iterations of `iteration`
/// (which returns the app to where it started), then the harness checks
/// and restores the starting state.
public struct Scenario: Equatable, Codable, Sendable {
    public var id: String
    /// The option name that selects it (`--scenarios`); several variants share one.
    public var group: String
    public var setup: [Step]
    public var iteration: [Step]
    /// Where ack and settled are diffed.
    public var region: Region
    /// The selected tab may move: restore it by title afterwards.
    public var movesTab: Bool

    public init(id: String, group: String, setup: [Step] = [], iteration: [Step], region: Region = .window, movesTab: Bool = false) {
        self.id = id
        self.group = group
        self.setup = setup
        self.iteration = iteration
        self.region = region
        self.movesTab = movesTab
    }

    public var metricIDs: [String] { iteration.flatMap(\.measure.metricIDs) }
}

/// Where the app's home space sits among its spaces (0-based).
public struct SpaceLayout: Equatable, Sendable {
    public var home: Int
    public var count: Int
    /// The ⌘n numbers that select a plain tab in the home space (folders are
    /// left out: ⌘n on one would open or close it), if known.
    public var tabNumbers: [Int]?

    public init(home: Int, count: Int, tabNumbers: [Int]? = nil) {
        self.home = home
        self.count = count
        self.tabNumbers = tabNumbers
    }

    /// The two tabs ⌘n switches between: the first two plain tabs (⌘1, ⌘2 when unknown).
    public var tabKeys: (first: Int, second: Int)? {
        let numbers = tabNumbers ?? [1, 2]
        return numbers.count >= 2 ? (numbers[0], numbers[1]) : nil
    }

    /// ⌃n reaches spaces 1–9: the home space and a neighbour, both in reach.
    public var controlNeighbour: Int? {
        guard home < 9 else { return nil }
        if home + 1 < min(count, 9) { return home + 1 }
        return home > 0 ? home - 1 : nil
    }

    /// The neighbour for ⌥⌘← / ⌥⌘→: the previous space, or the next for the first.
    public var arrowTowardNeighbour: KeyChord? {
        guard count >= 2 else { return nil }
        return home > 0 ? .optionCommandLeft : .optionCommandRight
    }

    public var neighbourIndex: Int? {
        guard count >= 2 else { return nil }
        return home > 0 ? home - 1 : home + 1
    }
}

public enum ScenarioCatalog {
    /// `--scenarios` names, in run order (⌃Tab after ⌘1/⌘2 so the tab history has two tabs).
    public static let groups = ["space_switch", "tab_switch", "tab_switcher", "sidebar_toggle", "new_tab", "open_location", "little_arc"]

    public struct Plan: Equatable, Sendable {
        public var scenarios: [Scenario]
        /// Why a scenario was left out.
        public var skipped: [String]
    }

    /// The scenarios for one app. `regions` overrides a group's diff region
    /// (default: the whole window).
    public static func plan(_ layout: SpaceLayout, groups selected: [String] = groups, regions: [String: Region] = [:]) -> Plan {
        var scenarios: [Scenario] = []
        var skipped: [String] = []
        func region(_ group: String) -> Region { regions[group] ?? .window }
        for group in groups where selected.contains(group) {
            switch group {
            case "space_switch":
                if let other = layout.controlNeighbour {
                    let measure = Measure.frames(base: "ui.space_switch", suffix: "ctrl_n", content: true)
                    scenarios.append(Scenario(id: "space_switch.ctrl_n", group: group, iteration: [
                        Step(.digit(other + 1, .control), measure),
                        Step(.digit(layout.home + 1, .control), measure),
                    ], region: region(group)))
                } else {
                    skipped.append("space_switch.ctrl_n: the home space is space \(layout.home + 1) of \(layout.count); ⌃n reaches spaces 1–9 only")
                }
                if let toward = layout.arrowTowardNeighbour {
                    let back = toward == .optionCommandLeft ? KeyChord.optionCommandRight : .optionCommandLeft
                    let measure = Measure.frames(base: "ui.space_switch", suffix: "opt_cmd_arrow", content: true)
                    scenarios.append(Scenario(id: "space_switch.opt_cmd_arrow", group: group,
                                              iteration: [Step(toward, measure), Step(back, measure)], region: region(group)))
                } else {
                    skipped.append("space_switch.opt_cmd_arrow: only one space")
                }
            case "tab_switch":
                guard let (first, second) = layout.tabKeys else {
                    skipped.append("tab_switch: fewer than two plain tabs among ⌘1…⌘8 in the home space")
                    continue
                }
                let measure = Measure.frames(base: "ui.tab_switch", suffix: "cmd_n", content: true)
                scenarios.append(Scenario(id: "tab_switch.cmd_n", group: group, setup: [Step(.digit(first, .command))],
                                          iteration: [Step(.digit(second, .command), measure), Step(.digit(first, .command), measure)],
                                          region: region(group), movesTab: true))
            case "tab_switcher":
                guard let (first, second) = layout.tabKeys else {
                    skipped.append("tab_switcher: fewer than two plain tabs among ⌘1…⌘8 in the home space")
                    continue
                }
                // Second then first tab: the most recent other tab exists, and two ⌃Tabs come back.
                let measure = Measure.frames(base: "ui.tab_switcher", suffix: nil, content: true)
                scenarios.append(Scenario(id: "tab_switcher", group: group,
                                          setup: [Step(.digit(second, .command)), Step(.digit(first, .command))],
                                          iteration: [Step(.controlTab, measure), Step(.controlTab, measure)],
                                          region: region(group), movesTab: true))
            case "sidebar_toggle":
                scenarios.append(Scenario(id: "sidebar_toggle", group: group, iteration: [
                    Step(.commandS, .frames(base: "ui.sidebar_toggle", suffix: "hide", content: false)),
                    Step(.commandS, .frames(base: "ui.sidebar_toggle", suffix: "show", content: false)),
                ], region: region(group)))
            case "new_tab":
                scenarios.append(Scenario(id: "new_tab", group: group, iteration: [
                    Step(.commandT, .frames(base: "ui.new_tab", suffix: nil, content: false)),
                    Step(.escape, .frames(base: "ui.new_tab.dismiss", suffix: nil, content: false)),
                ], region: region(group)))
            case "open_location":
                scenarios.append(Scenario(id: "open_location", group: group, iteration: [
                    Step(.commandL, .frames(base: "ui.open_location", suffix: nil, content: false)),
                    Step(.escape, .frames(base: "ui.open_location.dismiss", suffix: nil, content: false)),
                ], region: region(group)))
            case "little_arc":
                scenarios.append(Scenario(id: "little_arc", group: group, iteration: [
                    Step(.optionCommandN, .windowOpens("ui.little_arc_open.window.shortcut")),
                    Step(.commandW, .windowCloses("ui.little_arc_close.window"), requiresOpenedWindow: true),
                ]))
            default:
                break
            }
        }
        return Plan(scenarios: scenarios, skipped: skipped)
    }
}
