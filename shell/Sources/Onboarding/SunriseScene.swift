import SwiftUI

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// One frame of Act 0, drawn from time alone so the live takeover and the
/// offscreen preview renderer show exactly the same thing.
public struct SunriseSceneView: View {
    public var variant: SunriseVariant
    public var time: Double
    public var reduced: Bool
    /// Paints a stand-in desktop under the veil (previews only; live, the
    /// window is clear and the real desktop shows through).
    public var showsDesktop: Bool
    /// 0 while playing; runs to 1 as Begin hands over to the next act.
    public var exit: Double
    public var line: String
    public var onBegin: (() -> Void)?
    /// Act 1, once Begin is pressed.
    public var act1: Act1Log?
    /// Live input for Act 1; previews leave it nil and draw the log.
    public var controls: Act1Controls?
    /// Act 2, once a colour is picked.
    public var act2: Act2Log?
    public var act2Controls: Act2Controls?
    /// Act 3, after the blue sweep.
    public var act3: Act3Log?
    public var act3Controls: Act3Controls?
    /// Act 4: the motto, then the window.
    public var act4: Act4Log?
    /// "Onboard later": the scene closing, nil otherwise.
    public var closing: SunriseClosingFrame?

    public init(variant: SunriseVariant, time: Double, reduced: Bool = false, showsDesktop: Bool = false,
                exit: Double = 0, line: String = "Good morning.", onBegin: (() -> Void)? = nil,
                act1: Act1Log? = nil, controls: Act1Controls? = nil,
                act2: Act2Log? = nil, act2Controls: Act2Controls? = nil,
                act3: Act3Log? = nil, act3Controls: Act3Controls? = nil, act4: Act4Log? = nil,
                closing: SunriseClosingFrame? = nil) {
        self.variant = variant; self.time = time; self.reduced = reduced; self.showsDesktop = showsDesktop
        self.exit = exit; self.line = line; self.onBegin = onBegin; self.act1 = act1; self.controls = controls
        self.act2 = act2; self.act2Controls = act2Controls
        self.act3 = act3; self.act3Controls = act3Controls; self.act4 = act4; self.closing = closing
    }

    public var body: some View {
        GeometryReader { geo in
            let L = MarkLayout(size: geo.size)
            let actsOut = closing?.actsOut ?? 0
            let closingFrame = SunriseTimeline.frame(variant, closing?.act0Time(time) ?? time, L, reduced: reduced)
            let f = closing?.apply(closingFrame) ?? closingFrame
            let live = exit == 0 && closing == nil
            let A2 = Act2Layout(size: geo.size)
            let L3 = Act3Layout(size: geo.size)
            let a4 = act4.flatMap { time >= $0.start ? Act4Timeline.frame($0, time) : nil }
            let flying = act4.map { time >= $0.start + Act4Timeline.flight } ?? false
            let a3 = act3.flatMap { log -> Act3Frame? in
                guard time >= log.start else { return nil }
                var g = Act3Timeline.frame(log, time)
                if let a4 { g.finale *= 1 - a4.clearAct3 }
                return g
            }
            let a2 = act2.flatMap { log -> Act2Frame? in
                guard time >= log.start else { return nil }
                var g = Act2Timeline.frame(log, time, A2)
                if let a3 { g.next *= 1 - a3.clearAct2 }
                return g
            }
            let a1 = act1.map { log -> Act1Frame in
                var g = Act1Timeline.frame(log, time)
                if let a2 { g.confirm *= 1 - a2.clearAct1; g.walk = a2.clearAct1 }
                // The sky takes the colour of the space being edited.
                if let a3 { g.tint = g.tint.mix(a3.tint, a3.tintAmount) }
                g.tintAmount *= 1 - actsOut
                return g
            }
            let A = Act1Layout(size: geo.size)
            ZStack {
                Canvas { ctx, size in
                    if showsDesktop { SunrisePainter.desktop(&ctx, size) }
                    ctx.drawLayer { scene in
                        scene.opacity = f.veil * (1 - exit)
                        SunrisePainter.scene(&scene, L, f, line: line, time: time, act1: a1, hidesMark: flying)
                        scene.drawLayer { acts in
                            acts.opacity = 1 - actsOut
                            if flying, let a4, let act4 {
                                SunrisePainter.act4(&acts, L, act4, a4)
                            } else {
                                if let a2, let act2 { SunrisePainter.act2(&acts, A2, a2, act2, time) }
                                if let a1 { SunrisePainter.act1(&acts, A, a1) }
                                if let a3 { SunrisePainter.act3(&acts, A2, L3, a3) }
                            }
                            if let a4 { SunrisePainter.motto(&acts, geo.size, a4) }
                        }
                    }
                }
                BeginButton(height: geo.size.height, action: onBegin)
                    .opacity(f.button * (1 - exit) * (1 - (a1?.clearAct0 ?? 0)))
                    .sunriseControlsActive(f.button > 0.5 && live && act1 == nil)
                    .position(x: geo.size.width / 2, y: L.markBottom + geo.size.height * 0.19)
                if let a1, let controls, exit == 0, a2 == nil {
                    Act1ControlsView(frame: a1, layout: A, controls: controls)
                        .opacity(1 - actsOut)
                        .sunriseControlsActive(closing == nil)
                }
                if let a2, let act2, a3 == nil {
                    Act2ControlsView(frame: a2, layout: A2, log: act2, controls: live ? act2Controls : nil)
                        .opacity(f.veil * (1 - exit) * (1 - actsOut))
                }
                if let a3, a4 == nil {
                    Act3ControlsView(frame: a3, arc: A2, layout: L3, controls: live ? act3Controls : nil)
                        .opacity(f.veil * (1 - exit) * (1 - actsOut))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("ReArc. \(line)")
    }
}

struct BeginButton: View {
    var height: CGFloat
    var action: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Text("Begin")
            .font(.system(size: max(15, height * 0.019), weight: .medium))
            .tracking(0.4)
            .foregroundStyle(MarkPalette.ink.color)
            .padding(.horizontal, max(24, height * 0.03))
            .padding(.vertical, max(10, height * 0.012))
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.92 : 0.7)))
            .overlay(Capsule().strokeBorder(MarkPalette.ink.color.opacity(0.12), lineWidth: 1))
            .shadow(color: MarkPalette.sun.color.opacity(0.18), radius: 18, y: 6)
            .scaleEffect(hovering ? 1.03 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .sunriseButton("Begin") { action?() }
    }
}

enum SunrisePainter {
    static func scene(_ ctx: inout GraphicsContext, _ L: MarkLayout, _ f: SunriseFrame, line: String, time: Double,
                      act1: Act1Frame? = nil, hidesMark: Bool = false) {
        let rect = CGRect(origin: .zero, size: L.size)
        sky(&ctx, rect, f)
        if let act1, act1.tintAmount > 0.001 { tint(&ctx, rect, act1.tint, act1.tintAmount) }
        stars(&ctx, rect, f.stars, time)
        if !hidesMark { ctx.drawLayer { mark in
            // Act 1 lifts the mark up and out of the way.
            if let lift = act1?.lift, lift > 0 {
                let A = Act1Layout(size: L.size)
                let s = Ease.mix(1, Act1Layout.markScale, lift)
                let to = Ease.mix(L.origin, A.markTarget, lift)
                mark.translateBy(x: to.x, y: to.y)
                mark.scaleBy(x: s, y: s)
                mark.translateBy(x: -L.origin.x, y: -L.origin.y)
            }
            sunGlow(&mark, L, f)
            ground(&mark, f)
            sun(&mark, rect.insetBy(dx: -rect.width, dy: -rect.height), f)
            arch(&mark, L, f.arch)
        } }
        var words = ctx
        words.opacity *= 1 - (act1?.clearAct0 ?? 0)
        text(&words, L, f, line)
    }

    static func tint(_ ctx: inout GraphicsContext, _ rect: CGRect, _ c: RGBA, _ amount: Double) {
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(stops: [
                .init(color: c.alpha(0.34 * amount).color, location: 0),
                .init(color: c.alpha(0.08 * amount).color, location: 0.5),
                .init(color: c.alpha(0.2 * amount).color, location: 1),
            ]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
    }

    // MARK: Sky

    static func skyShading(_ rect: CGRect, _ dawn: Double) -> GraphicsContext.Shading {
        let c = SkyPalette.colors(dawn)
        return .linearGradient(
            Gradient(stops: [
                .init(color: c.top.color, location: 0),
                .init(color: c.mid.color, location: 0.48),
                .init(color: c.bottom.color, location: 0.72),
                .init(color: c.bottom.mix(c.mid, 0.4).color, location: 1),
            ]),
            startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY))
    }

    static func sky(_ ctx: inout GraphicsContext, _ rect: CGRect, _ f: SunriseFrame) {
        guard let reach = f.lightReach else {
            ctx.fill(Path(rect), with: skyShading(rect, f.dawn))
            return
        }
        ctx.fill(Path(rect), with: skyShading(rect, 0))
        guard reach > 0 else { return }
        ctx.drawLayer { light in
            light.fill(Path(rect), with: skyShading(rect, f.dawn))
            light.blendMode = .destinationIn
            light.fill(Path(rect), with: .radialGradient(
                Gradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: 0.45),
                    .init(color: .white.opacity(0), location: 1),
                ]),
                center: f.sun.center, startRadius: 0, endRadius: reach))
        }
    }

    static func stars(_ ctx: inout GraphicsContext, _ rect: CGRect, _ amount: Double, _ time: Double) {
        guard amount > 0.001 else { return }
        var seed: UInt64 = 0x5EED_A2C
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        let count = 220
        for _ in 0 ..< count {
            let x = next(), y = next() * next() // more stars higher up
            let size = 0.5 + 1.6 * pow(next(), 3)
            let phase = next() * 2 * .pi, speed = 0.6 + 2.2 * next()
            let twinkle = 0.65 + 0.35 * sin(phase + speed * time)
            let a = amount * twinkle * (0.35 + 0.65 * next())
            let p = CGPoint(x: rect.width * x, y: rect.height * 0.78 * y)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)),
                     with: .color(.white.opacity(a)))
        }
    }

    // MARK: Sun

    static func sunGlow(_ ctx: inout GraphicsContext, _ L: MarkLayout, _ f: SunriseFrame) {
        let g = f.sun.glow * f.sun.opacity
        guard g > 0.001 else { return }
        let reach = f.sun.radius * 3 + L.size.height * 0.32
        ctx.fill(Path(CGRect(origin: .zero, size: L.size)), with: .radialGradient(
            Gradient(stops: [
                .init(color: RGBA(1, 0.62, 0.42, 0.55 * g).color, location: 0),
                .init(color: RGBA(1, 0.45, 0.32, 0.2 * g).color, location: 0.3),
                .init(color: RGBA(0.9, 0.35, 0.4, 0.06 * g).color, location: 0.6),
                .init(color: .clear, location: 1),
            ]),
            center: f.sun.center, startRadius: 0, endRadius: reach))
    }

    static func ground(_ ctx: inout GraphicsContext, _ f: SunriseFrame) {
        guard f.ground > 0.001 else { return }
        let a = f.arch, c = SkyPalette.colors(f.dawn), night = SkyPalette.colors(0)
        let disk = Path(ellipseIn: CGRect(x: a.center.x - a.radius, y: a.center.y - a.radius, width: a.radius * 2, height: a.radius * 2))
        let top = c.bottom.mix(night.bottom, 0.55), deep = night.mid.mix(night.top, 0.5)
        ctx.fill(disk, with: .linearGradient(
            Gradient(colors: [top.alpha(f.ground).color, deep.alpha(f.ground).color]),
            startPoint: CGPoint(x: a.center.x, y: a.center.y - a.radius),
            endPoint: CGPoint(x: a.center.x, y: a.center.y - a.radius + f.sun.radius * 4)))
    }

    static func sun(_ ctx: inout GraphicsContext, _ rect: CGRect, _ f: SunriseFrame) {
        guard f.sun.opacity > 0.001, f.sun.radius > 0.1 else { return }
        let arch = f.arch
        ctx.drawLayer { layer in
            layer.opacity *= f.sun.opacity
            // Nothing of the sun shows below the horizon.
            var clip = Path(rect.insetBy(dx: -rect.width, dy: -rect.height))
            clip.addEllipse(in: CGRect(x: arch.center.x - arch.radius, y: arch.center.y - arch.radius,
                                       width: arch.radius * 2, height: arch.radius * 2))
            layer.clip(to: clip, style: FillStyle(eoFill: true))
            let r = f.sun.radius, c = f.sun.center
            let disk = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let core = MarkPalette.sun.mix(MarkPalette.sunCore, 0.85 * f.sun.glow)
            layer.fill(disk, with: .radialGradient(
                Gradient(colors: [core.color, MarkPalette.sun.mix(core, 0.3 * f.sun.glow).color]),
                center: c, startRadius: 0, endRadius: r))
        }
    }

    // MARK: Arch

    static func arc(_ center: CGPoint, _ radius: CGFloat, _ range: ClosedRange<Double>) -> Path {
        var p = Path()
        let steps = max(8, Int((range.upperBound - range.lowerBound) * 1.5))
        for i in 0 ... steps {
            let a = (range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(steps)) * .pi / 180
            let pt = CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y + radius * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    static func arch(_ ctx: inout GraphicsContext, _ L: MarkLayout, _ a: ArchState) {
        guard a.opacity > 0.001 else { return }
        let style = { (w: CGFloat) in StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }
        let paths = a.baseRanges.map { arc(a.center, a.radius, $0) }

        // A soft bloom around the lit line, built from widening strokes.
        if a.glow > 0.001 {
            for i in 1 ... 6 {
                let w = a.width + CGFloat(i * i) * L.size.height * 0.0016
                for p in paths {
                    ctx.stroke(p, with: .color(RGBA(1, 0.72, 0.55, 0.07 * a.glow * a.opacity).color), style: style(w))
                }
            }
        }
        if a.colorMix > 0.001 {
            ctx.drawLayer { marks in
                marks.opacity *= a.opacity
                let navy = a.navy.map { arc(a.center, a.radius, $0) }
                let blue = a.blue.map { arc(a.center, a.radius, $0) }
                if let navy { marks.stroke(navy, with: .color(MarkPalette.navy.color), style: style(a.width)) }
                if let blue { marks.stroke(blue, with: .color(MarkPalette.blue.color), style: style(a.width)) }
                if let navy, let blue {
                    marks.drawLayer { overlap in
                        overlap.clip(to: navy.strokedPath(style(a.width)))
                        overlap.stroke(blue, with: .color(MarkPalette.deep.color), style: style(a.width))
                    }
                }
            }
        }
        if a.colorMix < 1 {
            for p in paths {
                ctx.stroke(p, with: .color(a.base.alpha((1 - a.colorMix) * a.opacity).color), style: style(a.width))
            }
        }
        // Backlight: the light behind catches the arch's upper edge.
        if a.rim > 0.001, let first = a.baseRanges.first, let last = a.baseRanges.last {
            let edge = arc(a.center, a.radius + a.width / 2 - 1, first.lowerBound ... last.upperBound)
            ctx.stroke(edge, with: .color(RGBA(1, 0.7, 0.5, 0.18 * a.rim).color), style: style(9))
            ctx.stroke(edge, with: .color(RGBA(1, 0.8, 0.62, 0.35 * a.rim).color), style: style(4))
            ctx.stroke(edge, with: .color(RGBA(1, 0.92, 0.82, 0.9 * a.rim).color), style: style(1.5))
        }
    }

    // MARK: Words

    static func text(_ ctx: inout GraphicsContext, _ L: MarkLayout, _ f: SunriseFrame, _ line: String) {
        guard f.text > 0.001 else { return }
        let H = L.size.height
        var c = ctx
        c.opacity *= f.text
        let t = Text(line)
            .font(.system(size: H * 0.042, weight: .light))
            .tracking(H * 0.0004)
            .foregroundColor(MarkPalette.ink.color)
        c.draw(t, at: CGPoint(x: L.size.width / 2, y: L.markBottom + H * 0.085 + CGFloat(1 - f.text) * H * 0.014))
    }

    // MARK: Stand-in desktop (previews)

    static func desktop(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: [RGBA(hex: 0x2B2FB8).color, RGBA(hex: 0x4B3FC9).color, RGBA(hex: 0x8C9BEF).color]),
            startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        var wave = Path()
        wave.move(to: CGPoint(x: 0, y: size.height * 0.42))
        wave.addCurve(to: CGPoint(x: size.width, y: size.height * 0.55),
                      control1: CGPoint(x: size.width * 0.35, y: size.height * 0.75),
                      control2: CGPoint(x: size.width * 0.65, y: size.height * 0.25))
        ctx.stroke(wave, with: .color(.white.opacity(0.55)), lineWidth: 2)
    }
}
