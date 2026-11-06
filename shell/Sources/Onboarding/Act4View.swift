import SwiftUI

extension SunrisePainter {
    /// The motto, over the sky, before the window forms.
    static func motto(_ ctx: inout GraphicsContext, _ size: CGSize, _ g: Act4Frame) {
        let H = size.height, W = size.width
        let ink = MarkPalette.ink.color
        let y = H * 0.36
        let words = ["ReFocused.", "ReStored.", "ReArc."]
        let fonts = [Font.system(size: H * 0.036, weight: .light), .system(size: H * 0.036, weight: .light),
                     .system(size: H * 0.036, weight: .regular)]
        let resolved = words.indices.map { ctx.resolve(Text(words[$0]).font(fonts[$0]).foregroundColor(ink)) }
        let widths = resolved.map { $0.measure(in: size).width }
        let gap = H * 0.022
        var x = W / 2 - (widths.reduce(0, +) + gap * 2) / 2
        for i in words.indices {
            var c = ctx
            c.opacity *= g.words[i] * (1 - g.mottoOut)
            c.draw(resolved[i], at: CGPoint(x: x, y: y + CGFloat(1 - g.words[i]) * 10), anchor: .leading)
            x += widths[i] + gap
        }
    }

    /// Everything from the moment the window starts to form.
    static func act4(_ ctx: inout GraphicsContext, _ L: MarkLayout, _ log: Act4Log, _ g: Act4Frame) {
        let size = L.size, H = size.height
        let full = CGRect(origin: .zero, size: size)
        let A1 = Act1Layout(size: size), A2 = Act2Layout(size: size), L3 = Act3Layout(size: size), A4 = Act4Layout(size: size)
        let ink = MarkPalette.ink.color
        let w = g.window

        // The sky folds into the window; the desktop returns around it.
        let rect = CGRect(x: Ease.mix(full.minX, A4.window.minX, w), y: Ease.mix(full.minY, A4.window.minY, w),
                          width: Ease.mix(full.width, A4.window.width, w), height: Ease.mix(full.height, A4.window.height, w))
        let corner = Ease.mix(0, A4.corner, w)
        let windowPath = Path(roundedRect: rect, cornerRadius: corner, style: .continuous)
        var punch = Path(full.insetBy(dx: -2, dy: -2))
        punch.addPath(windowPath)
        var cut = ctx
        cut.blendMode = .destinationOut
        cut.fill(punch, with: .color(.black), style: FillStyle(eoFill: true))
        for i in 1 ... 6 {
            let spread = CGFloat(i) * H * 0.004
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: -spread / 2, dy: -spread / 2 + H * 0.002), cornerRadius: corner + spread / 2),
                       with: .color(.black.opacity(0.05 * w)), lineWidth: spread)
        }

        // Your first space's theme, as ReArc paints a window.
        let theme = log.theme
        var bg = ctx
        bg.opacity *= w
        bg.fill(windowPath, with: .linearGradient(
            Gradient(colors: [RGBA(1, 1, 1).mix(theme, 0.32).color, RGBA(1, 1, 1).mix(theme, 0.5).color]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))

        // The arc lets go.
        if g.arcFade < 1 {
            var c = ctx
            c.opacity *= 1 - g.arcFade
            let style = StrokeStyle(lineWidth: H * 0.016, lineCap: .round)
            c.stroke(SunrisePainter.arc(A2.center, A2.radius, Act2Layout.trailStart ... -90), with: .color(MarkPalette.navy.color), style: style)
            c.stroke(SunrisePainter.arc(A2.center, A2.radius, -90 ... -24), with: .color(MarkPalette.blue.color), style: style)
        }

        // Sidebar chrome.
        if g.chrome > 0.001 {
            var c = ctx
            c.opacity *= g.chrome
            for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                let p = CGPoint(x: A4.window.minX + H * 0.022 + CGFloat(i) * H * 0.022, y: A4.window.minY + H * 0.022)
                let r = H * 0.0068
                c.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(RGBA(hex: UInt32(hex)).color))
            }
            c.fill(Path(roundedRect: A4.urlBar, cornerRadius: H * 0.01), with: .color(.white.opacity(0.45)))
            c.draw(Text("rearc://welcome").font(.system(size: H * 0.0145)).foregroundColor(ink.opacity(0.55)),
                   at: CGPoint(x: A4.urlBar.minX + H * 0.014, y: A4.urlBar.midY), anchor: .leading)
            c.fill(Path(roundedRect: A4.tabRow, cornerRadius: H * 0.01), with: .color(.white.opacity(0.7)))
            c.draw(Text("Welcome to ReArc").font(.system(size: H * 0.0155, weight: .medium)).foregroundColor(ink),
                   at: CGPoint(x: A4.favicon.x + H * 0.02, y: A4.tabRow.midY), anchor: .leading)
            c.draw(Text("+  New Tab").font(.system(size: H * 0.0155)).foregroundColor(ink.opacity(0.45)),
                   at: CGPoint(x: A4.tabRow.minX + H * 0.014, y: A4.tabRow.maxY + H * 0.026), anchor: .leading)
        }

        // The page: a real welcome, not a blank tab.
        if g.page > 0.001 {
            var c = ctx
            c.opacity *= g.page
            let card = A4.card
            let cardPath = Path(roundedRect: card, cornerRadius: H * 0.011, style: .continuous)
            c.fill(cardPath, with: .color(.white.opacity(0.94)))
            c.stroke(cardPath, with: .color(.black.opacity(0.05)), lineWidth: 1)
            let x = card.minX + card.width * 0.12
            var y = card.minY + card.height * 0.22 + CGFloat(1 - g.page) * H * 0.01
            c.draw(Text("REFOCUSED · RESTORED · REARC").font(.system(size: H * 0.0135, weight: .semibold)).tracking(H * 0.003)
                .foregroundColor(MarkPalette.sun.color), at: CGPoint(x: x, y: y), anchor: .leading)
            y += H * 0.055
            let greeting = log.name.isEmpty ? Text("Welcome to ReArc.")
                : Text("Welcome to ReArc, ") + Text(log.name).foregroundColor(log.colour.color) + Text(".")
            c.draw(greeting.font(.system(size: H * 0.046, weight: .light)).foregroundColor(ink), at: CGPoint(x: x, y: y), anchor: .leading)
            y += H * 0.056
            let n = log.nodes.count
            c.draw(Text("Your profile and \(n) space\(n == 1 ? " is" : "s are") ready.").font(.system(size: H * 0.019))
                .foregroundColor(ink.opacity(0.75)), at: CGPoint(x: x, y: y), anchor: .leading)
            if let totals = log.totals, totals != ImportStats() {
                y += H * 0.032
                c.draw(Text(totals.summary + " came with you.").font(.system(size: H * 0.016)).foregroundColor(ink.opacity(0.5)),
                       at: CGPoint(x: x, y: y), anchor: .leading)
            }

            var tips = c
            tips.opacity *= g.tips
            var tx = x
            let ty = y + H * 0.085
            for (key, label) in [("⌘T", "New tab"), ("⌘L", "Command bar"), ("⌘S", "Hide the sidebar"), ("⌃1–9", "Switch spaces")] {
                let k = tips.resolve(Text(key).font(.system(size: H * 0.016, weight: .medium, design: .rounded)).foregroundColor(ink))
                let kw = k.measure(in: size).width + H * 0.02
                let keycap = CGRect(x: tx, y: ty - H * 0.017, width: kw, height: H * 0.034)
                tips.fill(Path(roundedRect: keycap, cornerRadius: H * 0.007), with: .color(ink.opacity(0.05)))
                tips.stroke(Path(roundedRect: keycap, cornerRadius: H * 0.007), with: .color(ink.opacity(0.12)), lineWidth: 1)
                tips.draw(k, at: CGPoint(x: keycap.midX, y: ty), anchor: .center)
                let l = tips.resolve(Text(label).font(.system(size: H * 0.016)).foregroundColor(ink.opacity(0.65)))
                tips.draw(l, at: CGPoint(x: keycap.maxX + H * 0.009, y: ty), anchor: .leading)
                tx = keycap.maxX + H * 0.009 + l.measure(in: size).width + H * 0.03
            }
            tips.draw(Text("Watch the sunrise again any time: Help ▸ Watch the Sunrise Again").font(.system(size: H * 0.0135))
                .foregroundColor(ink.opacity(0.4)), at: CGPoint(x: x, y: card.maxY - H * 0.05), anchor: .leading)
        }

        // The mark shrinks into the first tab's favicon.
        let markWidth = 730 * L.scale
        let s = Ease.mix(Act1Layout.markScale, H * 0.022 / markWidth, g.markFly)
        let to = Ease.mix(A1.markTarget, A4.favicon, g.markFly)
        let final = SunriseTimeline.finalFrame(L)
        ctx.drawLayer { mark in
            mark.translateBy(x: to.x, y: to.y)
            mark.scaleBy(x: s, y: s)
            mark.translateBy(x: -L.origin.x, y: -L.origin.y)
            sun(&mark, full.insetBy(dx: -full.width * 4, dy: -full.height * 4), final)
            arch(&mark, L, final.arch)
        }

        // Spaces into the switcher, you beside them.
        let n = log.nodes.count
        let rEnd = A4.switcherRadius(n)
        let rStart = L3.nodeRadius(slots: n + 1)
        for (i, node) in log.nodes.enumerated() {
            let k = g.fly[i]
            let p = Ease.mix(A2.point(node.angle), A4.switcher(i, of: n), k)
            let r = Ease.mix(rStart, rEnd, k)
            if i == 0, g.chrome > 0.001 {
                let ring = r + 3
                var c = ctx
                c.opacity *= g.chrome
                c.stroke(Path(ellipseIn: CGRect(x: p.x - ring, y: p.y - ring, width: ring * 2, height: ring * 2)),
                         with: .color(ink.opacity(0.35)), lineWidth: 1.2)
            }
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(node.colour.color))
            icon(&ctx, node.icon, at: p, size: r * 0.95)
        }
        let ap = Ease.mix(A2.apex, A4.avatar, g.avatarFly)
        let ar = Ease.mix(A2.avatarRadius, rEnd * 1.05, g.avatarFly)
        ctx.fill(Path(ellipseIn: CGRect(x: ap.x - ar, y: ap.y - ar, width: ar * 2, height: ar * 2)), with: .color(log.colour.color))
        if let initial = log.name.first {
            ctx.draw(Text(String(initial).uppercased()).font(.system(size: ar * 0.95, weight: .semibold, design: .rounded))
                .foregroundColor(.white), at: ap, anchor: .center)
        }
    }
}
