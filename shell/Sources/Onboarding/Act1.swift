import CoreGraphics
import Foundation

/// Act 1, "You": the mark lifts out of the way, ReArc asks your name, greets
/// you, and you pick the colour of your sky. That makes profile #1.
///
/// Like Act 0 it is drawn from time alone: what the person did is an event log
/// with scene times, so a scripted log renders the same frames offscreen.
public struct Act1Log: Equatable, Sendable {
    /// Scene time Begin was pressed.
    public var start: Double
    /// The field's text after each change.
    public var edits: [(time: Double, text: String)] = []
    public var submitted: (time: Double, name: String)?
    /// Pointer over a swatch (nil when it leaves them).
    public var hovers: [(time: Double, index: Int?)] = []
    public var picked: (time: Double, index: Int)?

    public init(start: Double) { self.start = start }

    public static func == (a: Act1Log, b: Act1Log) -> Bool {
        a.start == b.start && a.edits.map(\.time) == b.edits.map(\.time) && a.edits.map(\.text) == b.edits.map(\.text)
            && a.submitted?.time == b.submitted?.time && a.submitted?.name == b.submitted?.name
            && a.hovers.map(\.time) == b.hovers.map(\.time) && a.hovers.map(\.index) == b.hovers.map(\.index)
            && a.picked?.time == b.picked?.time && a.picked?.index == b.picked?.index
    }

    public func text(at t: Double) -> String { edits.last { $0.time <= t }?.text ?? "" }

    /// When the act is over and the flow moves on.
    public var handOff: Double? { picked.map { $0.time + Act1Timeline.confirmHold } }

    /// A person who types "Kai", tries a few colours and picks Ultramarine.
    public static func demo(start: Double, name: String = "Kai", pick: Int = 5) -> Act1Log {
        var log = Act1Log(start: start)
        let typing = start + 2.9
        for i in 1 ... name.count {
            log.edits.append((typing + Double(i - 1) * 0.24, String(name.prefix(i))))
        }
        let submit = typing + Double(name.count) * 0.24 + 0.5
        log.submitted = (submit, name)
        let hover = submit + Act1Timeline.swatchesIn + 0.9
        for (k, i) in [0, 2, 3, pick].enumerated() { log.hovers.append((hover + Double(k) * 0.55, i)) }
        log.picked = (hover + 2.4, pick)
        return log
    }
}

public enum ProfilePalette {
    public static let colours: [(name: String, rgba: RGBA)] = [
        ("Sunrise", RGBA(hex: 0xFF5B3A)),
        ("Marigold", RGBA(hex: 0xF5A524)),
        ("Sage", RGBA(hex: 0x5DB884)),
        ("Lagoon", RGBA(hex: 0x1BA9B5)),
        ("Sky", RGBA(hex: 0x3B8AF6)),
        ("Ultramarine", RGBA(hex: 0x2740FF)),
        ("Iris", RGBA(hex: 0x8B5CF6)),
        ("Rose", RGBA(hex: 0xEC4F99)),
    ]
}

public struct Act1Frame: Equatable {
    /// 0 is the mark where Act 0 left it; 1 is small and high, out of the way.
    public var lift: Double
    /// Act 0's line and Begin fade as this rises.
    public var clearAct0: Double
    public var ask: Double
    public var field: Double
    public var text: String
    public var caret: Double
    public var greet: Double
    public var name: String
    public var prompt: Double
    public var swatches: [Double]
    public var hovered: Int?
    public var hover: [Double]
    /// The sky's tint and how strongly it shows.
    public var tint: RGBA
    public var tintAmount: Double
    public var picked: Int?
    /// The picked swatch travelling to the centre and becoming your avatar.
    public var avatar: Double
    public var confirm: Double
    /// Act 2 walks the avatar to the apex of its arc.
    public var walk: Double = 0
}

public enum Act1Timeline {
    public static let swatchesIn = 1.8
    public static let confirmHold = 3.0

    /// A value that eases to each new target from wherever it was.
    static func eased(_ changes: [(Double, Double)], at t: Double, over d: Double) -> Double {
        var v = 0.0, target = 0.0, last = -Double.infinity
        for (time, value) in changes where time <= t && value != target {
            v = last.isFinite ? Ease.mix(v, target, Ease.smooth((time - last) / d)) : target
            target = value; last = time
        }
        return last.isFinite ? Ease.mix(v, target, Ease.smooth((t - last) / d)) : 0
    }

    public static func frame(_ log: Act1Log, _ t: Double) -> Act1Frame {
        let s = log.start
        let submit = log.submitted?.time ?? .infinity
        let pick = log.picked?.time ?? .infinity
        let out = { (a: Double, b: Double) in 1 - Ease.smooth(Ease.progress(t, a, b)) }

        // What the pointer is over, as a list of changes; picking ends hovering.
        var pointer: [(time: Double, index: Int?)] = log.hovers.filter { $0.time < pick }
        if let p = log.picked { pointer.append((p.time, nil)) }
        let current = pointer.last { $0.time <= t }?.index

        let hover = ProfilePalette.colours.indices.map { i in
            Act1Timeline.eased(pointer.map { ($0.time, $0.index == i ? 1.0 : 0.0) }, at: t, over: 0.25)
        }

        // The sky follows the swatch under the pointer, and keeps the one picked.
        var sky: [(time: Double, colour: RGBA?)] = log.hovers.filter { $0.time < pick }
            .map { ($0.time, $0.index.map { ProfilePalette.colours[$0].rgba }) }
        if let p = log.picked { sky.append((p.time, ProfilePalette.colours[p.index].rgba)) }
        let amount = Act1Timeline.eased(sky.map { ($0.time, $0.colour == nil ? 0.0 : 1.0) }, at: t, over: 0.6)
        // The colour only moves while there is one to move to, so leaving a
        // swatch fades its tint out instead of greying it.
        var tint = MarkPalette.light, from = MarkPalette.light, to: RGBA?, since = -Double.infinity
        for e in sky where e.time <= t {
            guard let c = e.colour else { continue }
            from = to.map { from.mix($0, Ease.smooth((e.time - since) / 0.6)) } ?? c
            to = c; since = e.time
        }
        if let to { tint = from.mix(to, Ease.smooth((t - since) / 0.6)) }

        let swatchesStart = submit + swatchesIn
        let swatches = ProfilePalette.colours.indices.map { i -> Double in
            let appear = Ease.out(Ease.progress(t, swatchesStart + Double(i) * 0.07, swatchesStart + Double(i) * 0.07 + 0.6))
            let gone = log.picked?.index == i ? 1 : out(pick, pick + 0.5)
            return appear * gone
        }

        return Act1Frame(
            lift: Ease.inOut(Ease.progress(t, s, s + 1.4)),
            clearAct0: Ease.smooth(Ease.progress(t, s, s + 0.6)),
            ask: Ease.out(Ease.progress(t, s + 1.0, s + 2.0)) * out(submit, submit + 0.5),
            field: Ease.out(Ease.progress(t, s + 1.6, s + 2.4)) * out(submit + 0.1, submit + 0.6),
            text: log.text(at: t),
            caret: t < submit ? (sin((t - s) * 2 * .pi * 0.9) > -0.2 ? 1 : 0) : 0,
            greet: Ease.out(Ease.progress(t, submit + 0.5, submit + 1.3)) * out(submit + 2.2, submit + 2.8),
            name: log.submitted?.name ?? "",
            prompt: Ease.out(Ease.progress(t, submit + 2.6, submit + 3.4)) * out(pick, pick + 0.5),
            swatches: swatches,
            hovered: current,
            hover: hover,
            tint: tint,
            tintAmount: amount,
            picked: t >= pick ? log.picked?.index : nil,
            avatar: Ease.inOut(Ease.progress(t, pick, pick + 1.0)),
            confirm: Ease.out(Ease.progress(t, pick + 0.7, pick + 1.5)))
    }
}

/// Where Act 1 puts things, from the canvas size.
public struct Act1Layout {
    public let size: CGSize
    public init(size: CGSize) { self.size = size }
    var W: CGFloat { size.width }
    var H: CGFloat { size.height }
    public var markTarget: CGPoint { CGPoint(x: W / 2, y: H * 0.2) }
    public static let markScale: CGFloat = 0.5
    public var line: CGFloat { H * 0.47 }
    public var fieldBaseline: CGFloat { H * 0.6 }
    public var fieldWidth: CGFloat { min(W * 0.3, H * 0.6) }
    public var swatchRadius: CGFloat { H * 0.024 }
    var arcRadius: CGFloat { H * 0.5 }
    var arcCenter: CGPoint { CGPoint(x: W / 2, y: H * 0.63 + arcRadius) }
    /// Swatches stand on a shallow arc, an echo of the mark.
    public func swatch(_ i: Int) -> CGPoint {
        let n = ProfilePalette.colours.count
        let a = (-90 + (Double(i) - Double(n - 1) / 2) * 9.5) * .pi / 180
        return CGPoint(x: arcCenter.x + arcRadius * CGFloat(cos(a)), y: arcCenter.y + arcRadius * CGFloat(sin(a)))
    }
    public var avatarCenter: CGPoint { CGPoint(x: W / 2, y: H * 0.62) }
    public var avatarRadius: CGFloat { H * 0.055 }
}
