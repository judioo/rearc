import SwiftUI

public struct Act2Controls {
    public var toggleSource: (Int) -> Void
    public var toggleCategory: (ImportCategory) -> Void
    public var choose: (Bool) -> Void

    public init(toggleSource: @escaping (Int) -> Void, toggleCategory: @escaping (ImportCategory) -> Void, choose: @escaping (Bool) -> Void) {
        self.toggleSource = toggleSource; self.toggleCategory = toggleCategory; self.choose = choose
    }
}

extension ImportStats {
    /// "9 spaces · 111 tabs · 1,300 bookmarks …", leaving out what is zero.
    public var summary: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        func part(_ n: Int, _ one: String, _ many: String) -> String? {
            n > 0 ? "\(f.string(from: NSNumber(value: n)) ?? "\(n)") \(n == 1 ? one : many)" : nil
        }
        return [part(spaces, "space", "spaces"), part(tabs, "tab", "tabs"), part(bookmarks, "bookmark", "bookmarks"),
                part(pages, "page of history", "pages of history"), part(passwords, "password", "passwords"),
                part(extensions, "extension", "extensions")].compactMap { $0 }.joined(separator: "  ·  ")
    }
}

extension SunrisePainter {
    static func act2(_ ctx: inout GraphicsContext, _ A: Act2Layout, _ g: Act2Frame, _ log: Act2Log, _ t: Double) {
        let H = A.size.height, W = A.size.width
        let ink = MarkPalette.ink.color
        let lineFont = Font.system(size: H * 0.036, weight: .light)
        let round = { (w: CGFloat) in StrokeStyle(lineWidth: w, lineCap: .round) }

        // The trail: where you've been, drawn back from you into the past.
        if g.trail > 0.001 {
            let range = (-90 - (-90 - Act2Layout.trailStart) * g.trail) ... -90.0
            let path = SunrisePainter.arc(A.center, A.radius, range)
            for i in 1 ... 5 {
                ctx.stroke(path, with: .color(RGBA(1, 0.78, 0.6, 0.06 * g.trailGlow).color), style: round(g.trailWidth + CGFloat(i * i) * H * 0.0012))
            }
            let colour = MarkPalette.light.mix(MarkPalette.navy, g.flow)
            ctx.stroke(path, with: .color(colour.alpha(0.95).color), style: round(g.trailWidth))
        }
        // And ahead of you, where you're going.
        if g.sweep > 0.001 {
            let path = SunrisePainter.arc(A.center, A.radius, -90 ... (-90 + 66 * g.sweep))
            ctx.stroke(path, with: .color(MarkPalette.blue.alpha(0.18).color), style: round(H * 0.03))
            ctx.stroke(path, with: .color(MarkPalette.blue.color), style: round(H * 0.016))
        }

        for p in Act2Timeline.particles(log, t, A) {
            let glow = p.radius * 3.2
            ctx.fill(Path(ellipseIn: CGRect(x: p.point.x - glow, y: p.point.y - glow, width: glow * 2, height: glow * 2)),
                     with: .radialGradient(Gradient(colors: [p.colour.alpha(0.35 * p.alpha).color, .clear]),
                                           center: p.point, startRadius: 0, endRadius: glow))
            ctx.fill(Path(ellipseIn: CGRect(x: p.point.x - p.radius, y: p.point.y - p.radius, width: p.radius * 2, height: p.radius * 2)),
                     with: .color(p.colour.alpha(p.alpha).color))
        }
        if g.arrivals > 0.001 {
            let r = A.avatarRadius * (1.35 + 0.25 * CGFloat(g.arrivals))
            ctx.fill(Path(ellipseIn: CGRect(x: A.apex.x - r, y: A.apex.y - r, width: r * 2, height: r * 2)),
                     with: .radialGradient(Gradient(colors: [RGBA(1, 0.85, 0.7, 0.45 * g.arrivals).color, .clear]),
                                           center: A.apex, startRadius: A.avatarRadius * 0.8, endRadius: r))
        }

        // Your other browsers, sitting on the trail.
        for (i, source) in log.sources.enumerated() {
            let appear = g.nodes[i]
            guard appear > 0.001 else { continue }
            var c = ctx
            c.opacity *= appear
            let p = A.point(A.nodeAngle(i, of: log.sources.count))
            let r = A.nodeRadius * CGFloat(0.7 + 0.3 * appear)
            let on = g.nodeOn[i]
            let disk = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            c.fill(disk, with: .color(RGBA(1, 1, 1, 0.55).mix(source.colour, on).color))
            c.stroke(disk, with: .color(source.colour.alpha(0.5 + 0.5 * on).color), lineWidth: 1.5)
            c.draw(Text(String(source.profile.first ?? source.browser.first ?? "?").uppercased())
                .font(.system(size: r * 0.9, weight: .semibold, design: .rounded))
                .foregroundColor(RGBA(hex: 0x1D2160).mix(RGBA(1, 1, 1), on).color), at: p, anchor: .center)
            let showsProfile = source.profile != "Default" && source.profile != source.browser
            var label = c
            label.opacity *= 0.45 + 0.55 * on
            let x = p.x - r - H * 0.014
            label.draw(Text(source.browser).font(.system(size: H * 0.017, weight: .semibold)).foregroundColor(ink),
                       at: CGPoint(x: x, y: showsProfile ? p.y - H * 0.011 : p.y), anchor: .trailing)
            if showsProfile {
                label.draw(Text(source.profile).font(.system(size: H * 0.015)).foregroundColor(ink.opacity(0.6)),
                           at: CGPoint(x: x, y: p.y + H * 0.012), anchor: .trailing)
            }
        }

        let mid = CGPoint(x: W / 2, y: A.line), sub = CGPoint(x: W / 2, y: A.subline)
        let small = Font.system(size: H * 0.017)
        line(&ctx, Text("Coming from another browser?").font(lineFont).foregroundColor(ink), at: mid, opacity: g.ask)
        line(&ctx, Text("Bring what matters. Leave the rest.").font(small).foregroundColor(ink.opacity(0.6)), at: sub, opacity: g.ask)
        line(&ctx, Text(g.totals.summary).font(.system(size: H * 0.016)).foregroundColor(ink.opacity(0.55)),
             at: CGPoint(x: W / 2, y: A.buttons + H * 0.062), opacity: g.buttons)

        line(&ctx, Text("Bringing it home.").font(lineFont).foregroundColor(ink), at: mid, opacity: g.bringingLine)
        line(&ctx, Text(g.shown.summary).font(.system(size: H * 0.018).monospacedDigit()).foregroundColor(ink.opacity(0.7)),
             at: sub, opacity: g.bringingLine)

        line(&ctx, Text("ReStored.").font(.system(size: H * 0.05, weight: .light)).foregroundColor(ink), at: mid, opacity: g.restored)
        line(&ctx, Text(g.totals.summary).font(small).foregroundColor(ink.opacity(0.6)), at: sub, opacity: g.restored)
        line(&ctx, Text("A clean start.").font(small).foregroundColor(ink.opacity(0.6)), at: sub, opacity: g.refocused)
        line(&ctx, Text("ReFocused.").font(.system(size: H * 0.05, weight: .light)).foregroundColor(ink), at: mid, opacity: g.refocused)
        line(&ctx, Text("Now, where are you going?").font(lineFont).foregroundColor(ink), at: mid, opacity: g.next)
    }
}

/// Act 2's chips and buttons, drawn as views in previews and live alike;
/// live, they also take clicks (and invisible targets sit over the nodes).
struct Act2ControlsView: View {
    var frame: Act2Frame
    var layout: Act2Layout
    var log: Act2Log
    var controls: Act2Controls?

    var body: some View {
        let H = layout.size.height
        let ink = MarkPalette.ink.color
        ZStack {
            HStack(spacing: H * 0.01) {
                ForEach(log.offered, id: \.self) { cat in
                    let on = frame.chipOn[cat.rawValue]
                    HStack(spacing: H * 0.006) {
                        Circle().fill(MarkPalette.sun.color.opacity(on)).frame(width: H * 0.008, height: H * 0.008)
                            .overlay(Circle().stroke(ink.opacity(0.3 * (1 - on)), lineWidth: 1))
                        Text(cat.title)
                    }
                    .font(.system(size: H * 0.017, weight: .medium))
                    .foregroundStyle(ink.opacity(0.45 + 0.5 * on))
                    .padding(.horizontal, H * 0.014).padding(.vertical, H * 0.007)
                    .background(Capsule().fill(Color.white.opacity(0.25 + 0.4 * on)))
                    .overlay(Capsule().strokeBorder(ink.opacity(0.1), lineWidth: 1))
                    .contentShape(Capsule())
                    .onTapGesture { controls?.toggleCategory(cat) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("\(cat.title), \(on > 0.5 ? "on" : "off")")
                }
            }
            .opacity(frame.chips)
            .position(x: layout.size.width / 2, y: layout.chips)
            .allowsHitTesting(controls != nil && frame.chips > 0.5)

            if log.offered.contains(.passwords), frame.chipOn[ImportCategory.passwords.rawValue] > 0.5 {
                Text("macOS will ask once before ReArc reads each browser's passwords.")
                    .font(.system(size: H * 0.0145))
                    .foregroundStyle(ink.opacity(0.45))
                    .opacity(frame.chips)
                    .position(x: layout.size.width / 2, y: layout.chips + H * 0.037)
            }

            HStack(spacing: H * 0.03) {
                Text("Start fresh")
                    .font(.system(size: H * 0.018, weight: .medium))
                    .foregroundStyle(ink.opacity(0.6))
                    .contentShape(Rectangle())
                    .onTapGesture { controls?.choose(false) }
                    .accessibilityAddTraits(.isButton)
                Text("Bring them over")
                    .font(.system(size: H * 0.019, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, H * 0.03).padding(.vertical, H * 0.012)
                    .background(Capsule().fill(MarkPalette.navy.color))
                    .shadow(color: MarkPalette.navy.color.opacity(0.25), radius: 14, y: 5)
                    .contentShape(Capsule())
                    .onTapGesture { controls?.choose(true) }
                    .accessibilityAddTraits(.isButton)
            }
            .opacity(frame.buttons)
            .position(x: layout.size.width / 2, y: layout.buttons)
            .allowsHitTesting(controls != nil && frame.buttons > 0.5)

            if let controls, frame.buttons > 0.5 {
                ForEach(log.sources.indices, id: \.self) { i in
                    Circle().fill(Color.white.opacity(0.001))
                        .frame(width: layout.nodeRadius * 2.8, height: layout.nodeRadius * 2.8)
                        .contentShape(Circle())
                        .onTapGesture { controls.toggleSource(i) }
                        .position(layout.point(layout.nodeAngle(i, of: log.sources.count)))
                        .accessibilityElement()
                        .accessibilityLabel("\(log.sources[i].browser) \(log.sources[i].profile)")
                        .accessibilityAddTraits(.isButton)
                }
            }
        }
    }
}
