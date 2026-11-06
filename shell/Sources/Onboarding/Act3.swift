import CoreGraphics
import Foundation

/// Act 3, "Where you're going": your spaces sit along the blue side of the
/// arc, mirroring the browsers on the navy side. Spaces that came from Arc
/// arrive with their names, icons and colours; otherwise ReArc suggests two.
/// Choose one to rename it, recolour it or give it an icon; the sky takes its
/// colour. Add, remove, then Done: "Everything has a place."
public enum Act3Event: Equatable, Sendable {
    case select(Int?)
    case rename(Int, String)
    case colour(Int, Int)
    case icon(Int, String)
    /// A new space (it gets the next id and is selected).
    case add
    case remove(Int)
    case done
}

public struct Act3Log: Equatable, Sendable {
    public var start: Double
    public var seeds: [SpaceSeed]
    public var imported: Bool
    public var events: [(time: Double, event: Act3Event)] = []

    public init(start: Double, seeds: [SpaceSeed], imported: Bool) {
        self.start = start; self.seeds = seeds; self.imported = imported
    }

    public static func == (a: Act3Log, b: Act3Log) -> Bool {
        a.start == b.start && a.seeds == b.seeds && a.imported == b.imported
            && a.events.map(\.time) == b.events.map(\.time) && a.events.map(\.event) == b.events.map(\.event)
    }

    /// A clean start: one space for life, one for work.
    public static func suggested(colour: RGBA) -> [SpaceSeed] {
        [SpaceSeed(name: "Personal", icon: "🏠", colour: colour),
         SpaceSeed(name: "Work", icon: "💼", colour: colour.mix(RGBA(hex: 0x3B8AF6), colour == RGBA(hex: 0x3B8AF6) ? 0 : 0.85))]
    }

    /// Spaces for Act 3 from what Act 2 brought over (or suggestions).
    public static func after(_ act2: Act2Log?, start: Double, colour: RGBA) -> Act3Log {
        var seeds: [SpaceSeed] = []
        if let act2, act2.bringing, let c = act2.choice?.time, act2.isOn(.spaces, at: c) {
            for (i, s) in act2.sources.enumerated() where act2.isOn(source: i, at: c) { seeds += s.spaces }
        }
        if seeds.count > Act3Timeline.maxSpaces { seeds = Array(seeds.prefix(Act3Timeline.maxSpaces)) }
        return seeds.isEmpty ? Act3Log(start: start, seeds: suggested(colour: colour), imported: false)
            : Act3Log(start: start, seeds: seeds, imported: true)
    }

    public var doneTime: Double? { events.first { $0.event == .done }?.time }
    public var handOff: Double? { doneTime.map { $0 + Act3Timeline.finale } }

    /// Someone tidies their imported spaces: recolours Work, drops Archive,
    /// adds "Side project" with a new icon, and is done.
    public static func demo(start s: Double, seeds: [SpaceSeed], imported: Bool) -> Act3Log {
        var log = Act3Log(start: s, seeds: seeds, imported: imported)
        let r = s + Act3Timeline.ready
        let work = min(1, seeds.count - 1), last = seeds.count - 1
        var e: [(Double, Act3Event)] = [(r + 0.4, .select(work)), (r + 1.3, .colour(work, 6)), (r + 2.0, .icon(work, "🎨"))]
        if imported, seeds.count > 2 { e += [(r + 2.9, .select(last)), (r + 3.6, .remove(last))] }
        let addAt = r + 4.4
        let newID = seeds.count
        e.append((addAt, .add))
        let name = "Side project"
        for i in 1 ... name.count { e.append((addAt + 0.6 + Double(i) * 0.08, .rename(newID, String(name.prefix(i))))) }
        e += [(addAt + 2.0, .icon(newID, "🎮")), (addAt + 2.6, .colour(newID, 1)), (addAt + 3.4, .select(nil)), (addAt + 4.2, .done)]
        log.events = e.map { (time: $0.0, event: $0.1) }
        return log
    }

    public struct Space: Equatable {
        public var id: Int
        public var name: String
        public var icon: String
        public var colour: RGBA
        public var previousColour: RGBA
        public var colourChanged: Double
        public var added: Double
        public var removed: Double?
        public var profile: String?
    }

    /// Every space so far (removed ones too) and the selection, at time t.
    public func state(at t: Double) -> (spaces: [Space], selected: Int?) {
        var spaces = seeds.enumerated().map { i, s in
            Space(id: i, name: s.name, icon: s.icon, colour: s.colour, previousColour: s.colour, colourChanged: -.infinity,
                  added: start + 1.0 + Double(i) * 0.08, removed: nil, profile: s.profile)
        }
        var selected: Int?
        let done = doneTime ?? .infinity
        for (time, event) in events where time <= t && time <= done {
            switch event {
            case let .select(id): selected = id
            case let .rename(id, name): if let k = spaces.firstIndex(where: { $0.id == id }) { spaces[k].name = name }
            case let .colour(id, c):
                if let k = spaces.firstIndex(where: { $0.id == id }) {
                    let s = spaces[k]
                    spaces[k].previousColour = s.previousColour.mix(s.colour, Ease.smooth((time - s.colourChanged) / 0.4))
                    spaces[k].colour = ProfilePalette.colours[c].rgba
                    spaces[k].colourChanged = time
                }
            case let .icon(id, icon): if let k = spaces.firstIndex(where: { $0.id == id }) { spaces[k].icon = icon }
            case .add:
                guard spaces.filter({ $0.removed == nil }).count < Act3Timeline.maxSpaces else { continue }
                let id = spaces.count
                let c = ProfilePalette.colours[id % ProfilePalette.colours.count].rgba
                spaces.append(Space(id: id, name: "", icon: Act3Timeline.icons[id % Act3Timeline.icons.count], colour: c,
                                    previousColour: c, colourChanged: -.infinity, added: time, removed: nil, profile: nil))
                selected = id
            case let .remove(id):
                if let k = spaces.firstIndex(where: { $0.id == id }) { spaces[k].removed = time }
                if selected == id { selected = nil }
            case .done: selected = nil
            }
        }
        if t >= done { selected = nil }
        return (spaces, selected)
    }
}

public struct Act3SpaceFrame: Equatable {
    public var id: Int
    public var name: String
    public var icon: String
    public var colour: RGBA
    public var profile: String?
    public var appear: Double
    public var angle: Double
    public var selected: Double
    public var pulse: Double
}

public struct Act3Frame: Equatable {
    public var clearAct2: Double
    public var title: Double
    public var imported: Bool
    public var spaces: [Act3SpaceFrame]
    public var plus: Double
    public var plusAngle: Double
    /// Slots on the arc (spaces and the + ), for spacing.
    public var slots: Int
    public var editor: Double
    public var editing: Act3SpaceFrame?
    public var caret: Double
    public var hint: Double
    public var done: Double
    public var finale: Double
    public var tint: RGBA
    public var tintAmount: Double
}

public enum Act3Timeline {
    public static let ready = 2.0
    public static let finale = 4.4
    public static let maxSpaces = 12
    public static let icons = ["🏠", "💼", "📚", "🎨", "🌿", "✈️", "🎵", "💡", "🎮", "☀️"]

    /// Angle on the blue side for slot i of n.
    /// Clear of your avatar at the apex, and above the bottom of the screen.
    public static let span: ClosedRange<Double> = -70 ... -32
    public static func step(_ n: Int) -> Double { min(11, (span.upperBound - span.lowerBound) / Double(max(n - 1, 1))) }
    public static func angle(_ i: Int, of n: Int) -> Double { span.lowerBound + step(n) * Double(i) }

    /// Like Act1Timeline.eased, but starting at the first value.
    static func track(_ changes: [(Double, Double)], at t: Double, over d: Double) -> Double {
        guard let first = changes.first else { return 0 }
        var v = first.1, target = first.1, last = first.0
        for (time, value) in changes.dropFirst() where time <= t && value != target {
            v = Ease.mix(v, target, Ease.smooth((time - last) / d))
            target = value; last = time
        }
        return Ease.mix(v, target, Ease.smooth((t - last) / d))
    }

    public static func frame(_ log: Act3Log, _ t: Double) -> Act3Frame {
        let s = log.start
        let done = log.doneTime ?? .infinity
        let out = { (a: Double, b: Double) in 1 - Ease.smooth(Ease.progress(t, a, b)) }
        let ease = { (a: Double, b: Double) in Ease.out(Ease.progress(t, a, b)) }
        let (spaces, selected) = log.state(at: t)

        // Where each space sits, re-laid out after every add or remove.
        var layoutTimes = [s] + log.events.filter { e in
            if case .add = e.event { return true }
            if case .remove = e.event { return true }
            return false
        }.map(\.time).filter { $0 <= min(t, done) }
        layoutTimes.sort()
        var angles: [Int: [(Double, Double)]] = [:]
        var plusAngles: [(Double, Double)] = []
        var slots = 1
        for time in layoutTimes {
            let visible = log.state(at: time).spaces.filter { $0.removed == nil }
            slots = visible.count + 1
            for (i, sp) in visible.enumerated() { angles[sp.id, default: []].append((time, angle(i, of: slots))) }
            plusAngles.append((time, angle(visible.count, of: slots)))
        }

        let selectionChanges: [(Double, Int?)] = [(s, nil)] + log.events.compactMap { e -> (Double, Int?)? in
            guard e.time <= min(t, done) else { return nil }
            switch e.event {
            case let .select(id): return (e.time, id)
            case .add: return (e.time, log.state(at: e.time).selected)
            case .remove: return (e.time, log.state(at: e.time).selected)
            default: return nil
            }
        } + (t >= done ? [(done, nil)] : [])

        let frames = spaces.enumerated().map { order, sp -> Act3SpaceFrame in
            let shown = log.state(at: t).spaces.filter { $0.removed == nil }
            let index = Double(shown.firstIndex { $0.id == sp.id } ?? order)
            let appear = ease(sp.added, sp.added + 0.5) * (sp.removed.map { out($0, $0 + 0.4) } ?? 1)
            return Act3SpaceFrame(
                id: sp.id, name: sp.name, icon: sp.icon,
                colour: sp.previousColour.mix(sp.colour, Ease.smooth((t - sp.colourChanged) / 0.4)),
                profile: sp.profile,
                appear: appear,
                angle: track(angles[sp.id] ?? [], at: t, over: 0.45),
                selected: Act1Timeline.eased(selectionChanges.map { ($0.0, $0.1 == sp.id ? 1.0 : 0.0) }, at: t, over: 0.25),
                pulse: Ease.bump(t, done + 0.4 + index * 0.12, 0.5))
        }

        let editorAmount = Act1Timeline.eased(selectionChanges.map { ($0.0, $0.1 == nil ? 0.0 : 1.0) }, at: t, over: 0.3)
        let lastSelected = selectionChanges.last { $0.1 != nil && $0.0 <= t }?.1
        let editing = frames.first { $0.id == (selected ?? lastSelected) }
        let main = ease(s + 0.5, s + 1.3) * out(done, done + 0.5)

        return Act3Frame(
            clearAct2: Ease.smooth(Ease.progress(t, s, s + 0.5)),
            title: main,
            imported: log.imported,
            spaces: frames,
            plus: ease(s + 1.6, s + 2.1) * out(done, done + 0.4)
                * (spaces.filter { $0.removed == nil }.count < maxSpaces ? 1 : 0),
            plusAngle: track(plusAngles, at: t, over: 0.45),
            slots: slots,
            editor: editorAmount * main,
            editing: editing,
            caret: t < done && selected != nil && sin((t - s) * 2 * .pi * 0.9) > -0.2 ? 1 : 0,
            hint: (1 - editorAmount) * main * ease(s + 1.6, s + 2.4),
            done: ease(s + 1.8, s + ready) * out(done, done + 0.4),
            finale: ease(done + 0.6, done + 1.4),
            tint: editing?.colour ?? MarkPalette.light,
            tintAmount: editorAmount * 0.85)
    }
}

public struct Act3Layout {
    public let size: CGSize
    public init(size: CGSize) { self.size = size }
    var H: CGFloat { size.height }
    public var title: CGFloat { H * 0.33 }
    public var subtitle: CGFloat { H * 0.372 }
    public var name: CGFloat { H * 0.445 }
    public var colours: CGFloat { H * 0.5 }
    public var icons: CGFloat { H * 0.552 }
    public var bottom: CGFloat { H * 0.612 }
    public var hint: CGFloat { H * 0.47 }

    public func nodeRadius(slots: Int) -> CGFloat {
        let step = Act3Timeline.step(slots) * .pi / 180
        return min(H * 0.026, Act2Layout(size: size).radius * CGFloat(step) * 0.42)
    }
}
