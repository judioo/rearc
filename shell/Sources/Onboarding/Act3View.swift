import SwiftUI

public struct Act3Controls {
    public var name: Binding<String>
    public var select: (Int?) -> Void
    public var colour: (Int) -> Void
    public var icon: (String) -> Void
    public var add: () -> Void
    public var remove: () -> Void
    public var done: () -> Void

    public init(name: Binding<String>, select: @escaping (Int?) -> Void, colour: @escaping (Int) -> Void,
                icon: @escaping (String) -> Void, add: @escaping () -> Void, remove: @escaping () -> Void, done: @escaping () -> Void) {
        self.name = name; self.select = select; self.colour = colour; self.icon = icon
        self.add = add; self.remove = remove; self.done = done
    }
}

extension SunrisePainter {
    /// ReArc space icons are emoji or SF Symbol names.
    static func isSymbol(_ icon: String) -> Bool {
        !icon.isEmpty && icon.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "." }
    }

    static func icon(_ ctx: inout GraphicsContext, _ icon: String, at p: CGPoint, size: CGFloat) {
        if isSymbol(icon) {
            ctx.draw(Text(Image(systemName: icon)).font(.system(size: size * 0.8, weight: .semibold)).foregroundColor(.white),
                     at: p, anchor: .center)
        } else {
            ctx.draw(Text(icon).font(.system(size: size)), at: p, anchor: .center)
        }
    }

    static func act3(_ ctx: inout GraphicsContext, _ A2: Act2Layout, _ L: Act3Layout, _ g: Act3Frame) {
        let H = L.size.height, W = L.size.width
        let ink = MarkPalette.ink.color
        let lineFont = Font.system(size: H * 0.036, weight: .light)
        let small = Font.system(size: H * 0.017)
        let r0 = L.nodeRadius(slots: g.slots)
        let labels = g.slots <= 7

        for sp in g.spaces where sp.appear > 0.001 {
            var c = ctx
            c.opacity *= sp.appear
            let p = A2.point(sp.angle)
            let r = r0 * CGFloat(0.7 + 0.3 * sp.appear) * CGFloat(1 + 0.22 * sp.selected + 0.3 * sp.pulse)
            if sp.selected > 0.001 || sp.pulse > 0.001 {
                let ring = r + 6
                c.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)),
                         with: .color(sp.colour.alpha(0.55 * max(sp.selected, sp.pulse)).color), lineWidth: 2)
            }
            c.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .radialGradient(
                Gradient(colors: [sp.colour.mix(RGBA(1, 1, 1), 0.25).color, sp.colour.color]),
                center: CGPoint(x: p.x - r * 0.3, y: p.y - r * 0.35), startRadius: 0, endRadius: r * 1.4))
            icon(&c, sp.icon, at: p, size: r * 0.95)
            if labels || sp.selected > 0.001 {
                var label = c
                if !labels { label.opacity *= sp.selected }
                let x = p.x + r + H * 0.014
                let name = sp.name.isEmpty ? Text("New space").foregroundColor(ink.opacity(0.4)) : Text(sp.name).foregroundColor(ink)
                label.draw(name.font(.system(size: H * 0.017, weight: .semibold)),
                           at: CGPoint(x: x, y: sp.profile == nil ? p.y : p.y - H * 0.011), anchor: .leading)
                if let profile = sp.profile {
                    label.draw(Text(profile).font(.system(size: H * 0.014)).foregroundColor(ink.opacity(0.55)),
                               at: CGPoint(x: x, y: p.y + H * 0.012), anchor: .leading)
                }
            }
        }
        if g.plus > 0.001 {
            var c = ctx
            c.opacity *= g.plus
            let p = A2.point(g.plusAngle), r = r0 * 0.85
            c.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                     with: .color(ink.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            c.draw(Text("+").font(.system(size: r * 1.1, weight: .light)).foregroundColor(ink.opacity(0.6)), at: p, anchor: .center)
        }

        let mid = CGPoint(x: W / 2, y: L.title), sub = CGPoint(x: W / 2, y: L.subtitle)
        line(&ctx, Text(g.imported ? "Your spaces came with you." : "Give your days some shape.").font(lineFont).foregroundColor(ink),
             at: mid, opacity: g.title)
        line(&ctx, Text(g.imported ? "Keep them as they are, or tidy up now."
                                   : "Spaces keep work, life and the rest apart. A few is plenty to start.")
                .font(small).foregroundColor(ink.opacity(0.6)), at: sub, opacity: g.title)
        line(&ctx, Text("Choose a space to rename it, recolour it or give it an icon.").font(small).foregroundColor(ink.opacity(0.5)),
             at: CGPoint(x: W / 2, y: L.hint), opacity: g.hint)

        if let e = g.editing, g.editor > 0.001 {
            var c = ctx
            c.opacity *= g.editor
            let empty = e.name.isEmpty
            let label = c.resolve(Text(empty ? "Name this space" : e.name)
                .font(.system(size: H * 0.034, weight: .regular)).foregroundColor(ink.opacity(empty ? 0.3 : 1)))
            let size = label.measure(in: L.size)
            c.draw(label, at: CGPoint(x: W / 2, y: L.name), anchor: .center)
            if g.caret > 0 {
                let x = empty ? W / 2 - size.width / 2 - 4 : W / 2 + size.width / 2 + 3
                c.fill(Path(roundedRect: CGRect(x: x, y: L.name - H * 0.019, width: 2, height: H * 0.038), cornerRadius: 1),
                       with: .color(MarkPalette.sun.color))
            }
            var rule = Path()
            rule.move(to: CGPoint(x: W / 2 - H * 0.16, y: L.name + H * 0.027))
            rule.addLine(to: CGPoint(x: W / 2 + H * 0.16, y: L.name + H * 0.027))
            c.stroke(rule, with: .linearGradient(Gradient(colors: [ink.opacity(0), ink.opacity(0.25), ink.opacity(0)]),
                                                 startPoint: CGPoint(x: W / 2 - H * 0.16, y: 0), endPoint: CGPoint(x: W / 2 + H * 0.16, y: 0)),
                     lineWidth: 1)
        }
        line(&ctx, Text("Everything has a place.").font(lineFont).foregroundColor(ink), at: mid, opacity: g.finale)
    }
}

/// Act 3's pickers and buttons (drawn as views in previews too), and live
/// hit targets over the spaces.
struct Act3ControlsView: View {
    var frame: Act3Frame
    var arc: Act2Layout
    var layout: Act3Layout
    var controls: Act3Controls?
    @FocusState private var focused: Bool

    var body: some View {
        let H = layout.size.height
        let ink = MarkPalette.ink.color
        let editing = frame.editing
        ZStack {
            if let editing {
                HStack(spacing: H * 0.012) {
                    ForEach(ProfilePalette.colours.indices, id: \.self) { i in
                        let c = ProfilePalette.colours[i].rgba
                        let chosen = c == editing.colour
                        Circle().fill(c.color)
                            .frame(width: H * 0.026, height: H * 0.026)
                            .overlay(Circle().stroke(Color.white, lineWidth: chosen ? 2.5 : 0).padding(2))
                            .overlay(Circle().stroke(c.color.opacity(chosen ? 0.6 : 0), lineWidth: 1.5).padding(-3))
                            .contentShape(Circle())
                            .onTapGesture { controls?.colour(i) }
                            .accessibilityLabel(ProfilePalette.colours[i].name)
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .position(x: layout.size.width / 2, y: layout.colours)
                .opacity(frame.editor)
                .allowsHitTesting(controls != nil && frame.editor > 0.5)

                HStack(spacing: H * 0.008) {
                    ForEach(Act3Timeline.icons, id: \.self) { icon in
                        Text(icon)
                            .font(.system(size: H * 0.024))
                            .frame(width: H * 0.042, height: H * 0.042)
                            .background(RoundedRectangle(cornerRadius: H * 0.01)
                                .fill(Color.white.opacity(icon == editing.icon ? 0.75 : 0.25)))
                            .overlay(RoundedRectangle(cornerRadius: H * 0.01)
                                .strokeBorder(ink.opacity(icon == editing.icon ? 0.2 : 0.06), lineWidth: 1))
                            .contentShape(Rectangle())
                            .onTapGesture { controls?.icon(icon) }
                            .accessibilityAddTraits(.isButton)
                    }
                }
                .position(x: layout.size.width / 2, y: layout.icons)
                .opacity(frame.editor)
                .allowsHitTesting(controls != nil && frame.editor > 0.5)
            }

            HStack(spacing: H * 0.03) {
                if editing != nil, frame.editor > 0.5 {
                    Text("Remove space")
                        .font(.system(size: H * 0.017, weight: .medium))
                        .foregroundStyle(ink.opacity(0.55))
                        .contentShape(Rectangle())
                        .onTapGesture { controls?.remove() }
                        .accessibilityAddTraits(.isButton)
                }
                Text("Done")
                    .font(.system(size: H * 0.019, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, H * 0.034).padding(.vertical, H * 0.012)
                    .background(Capsule().fill(MarkPalette.blue.color))
                    .shadow(color: MarkPalette.blue.color.opacity(0.25), radius: 14, y: 5)
                    .contentShape(Capsule())
                    .onTapGesture { controls?.done() }
                    .accessibilityAddTraits(.isButton)
            }
            .opacity(frame.done)
            .position(x: layout.size.width / 2, y: layout.bottom)
            .allowsHitTesting(controls != nil && frame.done > 0.5)

            if let controls, frame.done > 0.5 {
                let r = layout.nodeRadius(slots: frame.slots)
                ForEach(frame.spaces.filter { $0.appear > 0.5 }, id: \.id) { sp in
                    Circle().fill(Color.white.opacity(0.001))
                        .frame(width: r * 2.8, height: r * 2.8)
                        .contentShape(Circle())
                        .onTapGesture { controls.select(sp.id) }
                        .position(arc.point(sp.angle))
                        .accessibilityElement()
                        .accessibilityLabel(sp.name.isEmpty ? "New space" : sp.name)
                        .accessibilityAddTraits(.isButton)
                }
                if frame.plus > 0.5 {
                    Circle().fill(Color.white.opacity(0.001))
                        .frame(width: r * 2.6, height: r * 2.6)
                        .contentShape(Circle())
                        .onTapGesture { controls.add() }
                        .position(arc.point(frame.plusAngle))
                        .accessibilityElement()
                        .accessibilityLabel("Add a space")
                        .accessibilityAddTraits(.isButton)
                }
                if editing != nil, frame.editor > 0.5 {
                    TextField("", text: controls.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: H * 0.034))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.clear)
                        .tint(.clear)
                        .focused($focused)
                        .onSubmit { controls.select(nil) }
                        .frame(width: H * 0.32, height: H * 0.05)
                        .position(x: layout.size.width / 2, y: layout.name)
                        // Focus set while appearing is dropped on macOS; a turn later it sticks.
                        .onAppear { DispatchQueue.main.async { focused = true } }
                        .accessibilityLabel("Space name")
                }
            }
        }
    }
}
