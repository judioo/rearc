import CoreGraphics
import Foundation

/// Act 4, "Morning": the motto lands word by word — ReFocused. ReStored.
/// ReArc. — then the scene becomes a browser window on your desktop. The
/// desktop returns around it, the sky turns into your first space's theme,
/// your spaces fly off the arc into the sidebar's switcher, your avatar
/// joins them, and the mark shrinks into the favicon of the first tab: a
/// welcome page that greets you by name. In ReArc proper, the real window
/// sits underneath at the same frame and the overlay simply lets go.
public struct Act4Log: Equatable, Sendable {
    public struct Node: Equatable, Sendable {
        public var icon: String
        public var colour: RGBA
        /// Where it sat on the arc when Act 3 ended.
        public var angle: Double
    }

    public var start: Double
    public var name: String
    public var colour: RGBA
    public var nodes: [Node]
    /// What came over in Act 2, if anything did.
    public var totals: ImportStats?

    public init(start: Double, name: String, colour: RGBA, nodes: [Node], totals: ImportStats?) {
        self.start = start; self.name = name; self.colour = colour; self.nodes = nodes; self.totals = totals
    }

    /// Act 4 from the acts before it.
    public static func after(act1: Act1Log?, act2: Act2Log?, act3: Act3Log?, start: Double) -> Act4Log {
        let name = act1?.submitted?.name ?? ""
        let colour = act1?.picked.map { ProfilePalette.colours[$0.index].rgba } ?? MarkPalette.sun
        var nodes: [Node] = []
        if let act3 {
            let f = Act3Timeline.frame(act3, start)
            let visible = Set(act3.state(at: start).spaces.filter { $0.removed == nil }.map(\.id))
            nodes = f.spaces.filter { visible.contains($0.id) }.map { Node(icon: $0.icon, colour: $0.colour, angle: $0.angle) }
        }
        let totals = act2.flatMap { a in a.bringing ? a.choice.map { a.totals(at: $0.time) } : nil }
        return Act4Log(start: start, name: name, colour: colour, nodes: nodes, totals: totals)
    }

    public var handOff: Double { start + Act4Timeline.length }

    /// The theme of the first space (or yours).
    public var theme: RGBA { nodes.first?.colour ?? colour }
}

public struct Act4Frame: Equatable {
    public var clearAct3: Double
    /// "ReFocused." "ReStored." "ReArc."
    public var words: [Double]
    public var mottoOut: Double
    /// Things leave the scene for the window: 0 still in the sky, 1 in place.
    public var fly: [Double]
    public var avatarFly: Double
    public var markFly: Double
    public var arcFade: Double
    /// The window forms and the desktop comes back around it.
    public var window: Double
    public var chrome: Double
    public var page: Double
    public var tips: Double
}

public enum Act4Timeline {
    public static let flight = 3.4
    public static let length = 9.6

    public static func frame(_ log: Act4Log, _ t: Double) -> Act4Frame {
        let s = log.start
        let ease = { (a: Double, b: Double) in Ease.out(Ease.progress(t, a, b)) }
        let f = s + flight
        return Act4Frame(
            clearAct3: Ease.smooth(Ease.progress(t, s, s + 0.5)),
            words: [ease(s + 0.6, s + 1.3), ease(s + 1.15, s + 1.85), ease(s + 1.7, s + 2.5)],
            mottoOut: Ease.smooth(Ease.progress(t, f - 0.3, f + 0.4)),
            fly: log.nodes.indices.map { Ease.inOut(Ease.progress(t, f + 0.25 + Double($0) * 0.05, f + 1.35 + Double($0) * 0.05)) },
            avatarFly: Ease.inOut(Ease.progress(t, f + 0.15, f + 1.25)),
            markFly: Ease.inOut(Ease.progress(t, f, f + 1.3)),
            arcFade: Ease.smooth(Ease.progress(t, f, f + 0.8)),
            window: Ease.inOut(Ease.progress(t, f, f + 1.2)),
            chrome: ease(f + 0.8, f + 1.6),
            page: ease(f + 1.1, f + 2.0),
            tips: ease(f + 1.8, f + 2.6))
    }
}

/// The window the onboarding becomes; ReArc's real window takes this frame.
public struct Act4Layout {
    public let size: CGSize
    public init(size: CGSize) { self.size = size }
    var W: CGFloat { size.width }
    var H: CGFloat { size.height }
    public var window: CGRect {
        let w = W * 0.86, h = H * 0.86
        return CGRect(x: (W - w) / 2, y: (H - h) / 2 + H * 0.01, width: w, height: h)
    }
    public var corner: CGFloat { H * 0.014 }
    public var sidebarWidth: CGFloat { min(window.width * 0.21, H * 0.36) }
    public var card: CGRect {
        let inset = H * 0.009
        return CGRect(x: window.minX + sidebarWidth, y: window.minY + inset,
                      width: window.width - sidebarWidth - inset, height: window.height - inset * 2)
    }
    var pad: CGFloat { H * 0.016 }
    public var urlBar: CGRect { CGRect(x: window.minX + pad, y: window.minY + H * 0.05, width: sidebarWidth - pad * 2, height: H * 0.036) }
    public var tabRow: CGRect { CGRect(x: window.minX + pad * 0.6, y: window.minY + H * 0.115, width: sidebarWidth - pad * 1.2, height: H * 0.04) }
    public var favicon: CGPoint { CGPoint(x: tabRow.minX + H * 0.022, y: tabRow.midY) }
    public var switcherY: CGFloat { window.maxY - H * 0.032 }

    /// Avatar first, then a spot per space, across the bottom of the sidebar.
    public func switcher(_ i: Int, of n: Int) -> CGPoint {
        let spacing = min(H * 0.03, (sidebarWidth - pad * 2) / CGFloat(max(n + 1, 1)))
        return CGPoint(x: window.minX + pad + spacing / 2 + spacing * CGFloat(i + 1), y: switcherY)
    }
    public var avatar: CGPoint { CGPoint(x: window.minX + pad + min(H * 0.03, (sidebarWidth - pad * 2) / 2) / 2, y: switcherY) }
    public func switcherRadius(_ n: Int) -> CGFloat { min(H * 0.011, (sidebarWidth - pad * 2) / CGFloat(max(n + 1, 1)) * 0.38) }
}
