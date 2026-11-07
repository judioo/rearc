import SwiftUI

/// What the live takeover hands Act 1 so a person can answer it.
public struct Act1Controls {
    public var text: Binding<String>
    public var submit: () -> Void
    public var hover: (Int?) -> Void
    public var pick: (Int) -> Void

    public init(text: Binding<String>, submit: @escaping () -> Void, hover: @escaping (Int?) -> Void, pick: @escaping (Int) -> Void) {
        self.text = text; self.submit = submit; self.hover = hover; self.pick = pick
    }
}

extension SunrisePainter {
    static func line(_ ctx: inout GraphicsContext, _ text: Text, at p: CGPoint, opacity: Double) {
        guard opacity > 0.001 else { return }
        var c = ctx
        c.opacity *= opacity
        c.draw(text, at: CGPoint(x: p.x, y: p.y + CGFloat(1 - opacity) * 10), anchor: .center)
    }

    static func act1(_ ctx: inout GraphicsContext, _ A: Act1Layout, _ g: Act1Frame) {
        let H = A.size.height, W = A.size.width
        let ink = MarkPalette.ink.color
        let lineFont = Font.system(size: H * 0.036, weight: .light)
        let mid = CGPoint(x: W / 2, y: A.line)

        line(&ctx, Text("First, what should I call you?").font(lineFont).foregroundColor(ink), at: mid, opacity: g.ask)

        // The name sits on its own small horizon.
        if g.field > 0.001 {
            var c = ctx
            c.opacity *= g.field
            let half = A.fieldWidth / 2
            var rule = Path()
            rule.move(to: CGPoint(x: W / 2 - half, y: A.fieldBaseline))
            rule.addLine(to: CGPoint(x: W / 2 + half, y: A.fieldBaseline))
            c.stroke(rule, with: .linearGradient(
                Gradient(colors: [ink.opacity(0), ink.opacity(0.28), ink.opacity(0)]),
                startPoint: CGPoint(x: W / 2 - half, y: 0), endPoint: CGPoint(x: W / 2 + half, y: 0)), lineWidth: 1)
            let empty = g.text.isEmpty
            let label = c.resolve(Text(empty ? "Your name" : g.text)
                .font(.system(size: H * 0.05, weight: .regular))
                .foregroundColor(ink.opacity(empty ? 0.25 : 1)))
            let size = label.measure(in: CGSize(width: W, height: H))
            let baseline = A.fieldBaseline - H * 0.014
            c.draw(label, at: CGPoint(x: W / 2, y: baseline), anchor: .bottom)
            if g.caret > 0 {
                let x = empty ? W / 2 - size.width / 2 - 4 : W / 2 + size.width / 2 + 3
                let h = H * 0.05
                c.fill(Path(roundedRect: CGRect(x: x, y: baseline - h * 0.92, width: 2, height: h * 0.86), cornerRadius: 1),
                       with: .color(MarkPalette.sun.color))
            }
        }

        let name = Text(g.name).foregroundColor(MarkPalette.sun.color)
        line(&ctx, (Text("Lovely to meet you, ") + name + Text(".")).font(lineFont).foregroundColor(ink), at: mid, opacity: g.greet)
        line(&ctx, Text("Pick a colour for your sky.").font(lineFont).foregroundColor(ink), at: mid, opacity: g.prompt)

        // Swatches; the picked one travels to the centre and becomes you.
        for (i, entry) in ProfilePalette.colours.enumerated() {
            let appear = g.swatches[i]
            guard appear > 0.001 else { continue }
            let isPicked = g.picked == i
            var p = A.swatch(i)
            var r = A.swatchRadius * CGFloat(0.6 + 0.4 * appear) * CGFloat(1 + 0.24 * g.hover[i])
            if isPicked {
                p = Ease.mix(p, A.avatarCenter, g.avatar)
                r = Ease.mix(r, A.avatarRadius, g.avatar)
                if g.walk > 0 {
                    let A2 = Act2Layout(size: A.size)
                    p = Ease.mix(p, A2.apex, g.walk)
                    r = Ease.mix(r, A2.avatarRadius, g.walk)
                }
            }
            var c = ctx
            c.opacity *= appear
            if g.hover[i] > 0.001 {
                let ring = r + 6
                c.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)),
                         with: .color(entry.rgba.alpha(0.45 * g.hover[i]).color), lineWidth: 1.5)
            }
            c.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
                Gradient(colors: [entry.rgba.mix(RGBA(1, 1, 1), 0.18).color, entry.rgba.color]),
                center: CGPoint(x: p.x - r * 0.3, y: p.y - r * 0.35), startRadius: 0, endRadius: r * 1.4))
            if isPicked, g.avatar > 0.001, let initial = g.name.first {
                var t = c
                t.opacity *= g.avatar
                t.draw(Text(String(initial).uppercased()).font(.system(size: r * 0.95, weight: .semibold, design: .rounded))
                    .foregroundColor(.white), at: p, anchor: .center)
            }
        }
        if let h = g.hovered, g.prompt > 0.001 {
            line(&ctx, Text(ProfilePalette.colours[h].name.uppercased()).font(.system(size: H * 0.013, weight: .medium))
                .tracking(H * 0.003).foregroundColor(ink.opacity(0.55)),
                 at: CGPoint(x: W / 2, y: A.swatch(0).y + H * 0.075), opacity: g.hover[h] * g.prompt)
        }

        if let i = g.picked {
            let colour = Text(g.name).foregroundColor(ProfilePalette.colours[i].rgba.color)
            line(&ctx, (Text("That's you, ") + colour + Text(".")).font(lineFont).foregroundColor(ink), at: mid, opacity: g.confirm)
            line(&ctx, Text("Your first profile. Change any of it whenever you like.")
                .font(.system(size: H * 0.016)).foregroundColor(ink.opacity(0.55)),
                 at: CGPoint(x: W / 2, y: A.avatarCenter.y + A.avatarRadius + H * 0.05), opacity: g.confirm)
        }
    }
}

/// The live, invisible half of Act 1: a text field under the drawn name and
/// hit targets over the drawn swatches.
struct Act1ControlsView: View {
    var frame: Act1Frame
    var layout: Act1Layout
    var controls: Act1Controls
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            if frame.field > 0.5 {
                TextField("", text: controls.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: layout.size.height * 0.05))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.clear)
                    .tint(.clear)
                    .focused($focused)
                    .onSubmit { controls.submit() }
                    .frame(width: layout.fieldWidth, height: layout.size.height * 0.07)
                    .position(x: layout.size.width / 2, y: layout.fieldBaseline - layout.size.height * 0.04)
                    // Focus set while appearing is dropped on macOS; a turn later it sticks.
                    .onAppear { DispatchQueue.main.async { focused = true } }
                    // And again whenever the sunrise gets the keyboard (it may not have had it yet).
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in focused = true }
                    .accessibilityLabel("Your name")
            }
            if frame.prompt > 0.5 {
                ForEach(ProfilePalette.colours.indices, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: layout.swatchRadius * 2.6, height: layout.swatchRadius * 2.6)
                        .contentShape(Circle())
                        .onHover { inside in controls.hover(inside ? i : nil) }
                        .sunriseButton(ProfilePalette.colours[i].name) { controls.pick(i) }
                        .position(layout.swatch(i))
                }
            }
        }
    }
}
