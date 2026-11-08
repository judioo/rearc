import AppKit
import SidebarModel
import SwiftUI

/// Settings › Account's membership card (FEATURE-SPECS/SETTINGS.md §12),
/// ReArc's own art in the anatomy of Arc's: a cream card, a gradient shape
/// with drifting blobs, the name and title, rubber stamps, the date strip
/// and the ReArc wordmark. It tilts toward the pointer with a glare, and
/// plays the Arc-to-ReArc transition from `transitionStart`. Under Reduce
/// Motion it holds still, doesn't tilt, and the transition is a cross-fade.
struct MembershipCardView: View {
    static let size = CGSize(width: 240, height: 360)
    static let artSize = CGSize(width: 208, height: 192)

    let card: MembershipCard
    let name: String
    /// The profile's theme colour (palette 0).
    let theme: SpaceColor
    /// When the transition started; nil shows the card at rest.
    var transitionStart: Date?
    /// Drift and hover; off for the exported image.
    var isLive = true
    var now: () -> Date = Date.init

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pointer in unit coordinates (0…1 across the card), while over it.
    @State private var pointer: CGPoint?

    var body: some View {
        Group {
            if isLive {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion && transitionStart == nil)) { timeline in
                    face(at: timeline.date)
                }
            } else {
                face(at: now())
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .modifier(CardHover(pointer: $pointer, enabled: isLive && !reduceMotion))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isImage)
    }

    private var accessibilityText: String {
        var parts = ["Membership card", name, card.title.capitalized]
        if let arc = card.arcMemberSince { parts.append("Arc since \(MembershipCardDates.format(arc))") }
        parts.append("ReArc since \(MembershipCardDates.format(card.rearcMemberSince))")
        parts += allStamps.map(\.accessibilityLabel)
        return parts.joined(separator: ", ")
    }

    // MARK: State at a moment

    private var allStamps: [MembershipCardStamp] {
        MembershipCardStamps.stamps(arcSince: card.arcMemberSince, rearcSince: card.rearcMemberSince, now: now())
    }

    /// The transition's frame, with Reduce Motion's cross-fade spelt out.
    private func frame(at date: Date) -> MembershipCardTransition.Frame {
        guard let start = transitionStart, card.hasArcHistory else { return MembershipCardTransition.rest }
        let t = date.timeIntervalSince(start)
        var frame = MembershipCardTransition.frame(at: t, reduceMotion: reduceMotion)
        if let fade = frame.crossfade {
            frame.label = fade
            frame.dateText = fade < 0.5 ? 0 : 2
            frame.retint = fade
            frame.stampScale = 1
            frame.stampOpacity = fade
            frame.stampShadow = 1
        }
        return frame
    }

    private func face(at date: Date) -> some View {
        let frame = frame(at: date)
        let transitionTime = transitionStart.map { date.timeIntervalSince($0) }
        let drift = isLive && !reduceMotion ? date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 86_400) : 0
        let from = MembershipCardPalette.palette(card.arcPalette ?? card.palette, theme: theme)
        let to = MembershipCardPalette.palette(card.palette, theme: theme)
        let retint = { (index: Int) -> Double in
            guard let t = transitionTime, card.hasArcHistory else { return 1 }
            return MembershipCardTransition.blobRetint(index, at: t, reduceMotion: reduceMotion)
        }
        let ink = Color(MembershipCardPalette.mix(from.ink, to.ink, frame.retint))
        return VStack(alignment: .leading, spacing: 0) {
            CardArt(shape: card.shape, seed: card.seed, from: from, to: to, retint: retint, baseRetint: frame.retint, time: drift)
                .frame(width: Self.artSize.width, height: Self.artSize.height)
            Text(name)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 16)
            Text(card.title)
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 1)
            Spacer(minLength: 0)
            stamps(frame)
            HStack(alignment: .bottom) {
                dateStrip(frame, ink: ink)
                Spacer(minLength: 6)
                CardWordmark(ink: ink)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(CardPaper())
    }

    // MARK: Stamps

    /// The newest stamps overlapping, older ones in faded ink. In the
    /// transition ReArc's appear only once the new one drops.
    private func stamps(_ frame: MembershipCardTransition.Frame) -> some View {
        let all = allStamps
        let newest = all.last { !$0.isArc }
        let stack = Array(all.filter { $0.isArc || frame.stampScale != nil }.suffix(5))
        return ZStack(alignment: .leading) {
            ForEach(Array(stack.enumerated()), id: \.element) { index, stamp in
                let dropping = stamp == newest
                CardStampView(stamp: stamp, diameter: index.isMultiple(of: 2) ? 44 : 40)
                    .opacity(index == stack.count - 1 ? 1 : 0.6)
                    .rotationEffect(.degrees(rotation(for: index)))
                    .scaleEffect(dropping ? frame.stampScale ?? 1 : 1)
                    .shadow(color: .black.opacity(dropping ? 0.18 : 0), radius: frame.stampShadow, y: frame.stampShadow / 2)
                    .opacity(stamp.isArc ? 1 : frame.stampOpacity)
                    .offset(x: CGFloat(index) * 27, y: index.isMultiple(of: 2) ? 0 : 3)
            }
        }
        .frame(height: 48, alignment: .leading)
    }

    /// −8° to +8°, the same for the same card.
    private func rotation(for index: Int) -> Double {
        let value = card.seed.isEmpty ? index : card.seed[index % card.seed.count] + index * 5
        return Double(value % 17) - 8
    }

    // MARK: Date strip

    @ViewBuilder
    private func dateStrip(_ frame: MembershipCardTransition.Frame, ink: Color) -> some View {
        let arcDate = card.arcMemberSince.map { MembershipCardDates.format($0) }
        let rearcDate = MembershipCardDates.format(card.rearcMemberSince)
        let texts: [String] = if let arcSince = card.arcMemberSince {
            [arcDate ?? "", "ARC " + MembershipCardDates.span(from: arcSince, to: card.rearcMemberSince), rearcDate]
        } else {
            [rearcDate, rearcDate, rearcDate]
        }
        VStack(alignment: .leading, spacing: 3) {
            if let arcDate {
                Text("ARC SINCE \(arcDate.uppercased())")
                    .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(ink.opacity(0.75))
                    .opacity(frame.label)
            }
            HStack(spacing: 0) {
                ZStack {
                    Text("ARC").opacity(card.hasArcHistory ? 1 - frame.label : 0)
                    Text("REARC").opacity(card.hasArcHistory ? frame.label : 1)
                }
                .padding(.horizontal, 5)
                Rectangle().fill(ink).frame(width: 1)
                CardSunCell(ink: ink).frame(width: 13)
                Rectangle().fill(ink).frame(width: 1)
                Text(texts[min(frame.dateText, 2)])
                    .padding(.horizontal, 7)
                    .rotation3DEffect(.degrees(frame.flipAngle), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            }
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(ink)
            .frame(height: 15)
            .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(ink, lineWidth: 1))
        }
    }
}

// MARK: Pieces

/// The cream card stock with a soft shadow.
private struct CardPaper: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(red: 0.988, green: 0.973, blue: 0.925))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.black.opacity(0.05)))
            .shadow(color: .black.opacity(0.09), radius: 16, y: 6)
    }
}

/// The date strip's middle cell: a small sun on the horizon, ReArc's mark in brief.
private struct CardSunCell: View {
    let ink: Color

    var body: some View {
        Canvas { context, size in
            let r = size.width * 0.32
            let horizon = size.height * 0.66
            var sun = Path()
            sun.addArc(center: CGPoint(x: size.width / 2, y: horizon), radius: r, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            sun.closeSubpath()
            context.fill(sun, with: .color(ink))
            context.fill(Path(CGRect(x: 2, y: horizon + 1, width: size.width - 4, height: 1)), with: .color(ink))
        }
    }
}

/// "ReArc" with the mark, and the motto in small capitals under it.
private struct CardWordmark: View {
    let ink: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 2) {
                ReArcMarkView().frame(width: 18, height: 18)
                (Text("Re").foregroundStyle(ink) + Text("Arc").foregroundStyle(ReArcMark.blueColor))
                    .font(.system(size: 14, weight: .bold))
                    .tracking(-0.3)
            }
            Text("REFOCUSED · RESTORED · REARC")
                .font(.system(size: 4.6, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(ink.opacity(0.7))
        }
    }
}

/// A round rubber stamp: two rings, the ring's text set round it, the number in the middle.
struct CardStampView: View {
    let stamp: MembershipCardStamp
    var diameter: CGFloat = 44

    static let arcInk = Color(red: 0.36, green: 0.40, blue: 0.86)
    static let reArcInk = Color(red: 0.153, green: 0.251, blue: 1)

    var body: some View {
        let ink = stamp.isArc ? Self.arcInk : Self.reArcInk
        ZStack {
            Circle().strokeBorder(ink, lineWidth: 1.6)
            Circle().strokeBorder(ink.opacity(0.8), lineWidth: 0.8).padding(diameter * 0.2)
            RingText(text: stamp.ring, radius: diameter * 0.4 - 1, size: diameter * 0.12)
                .foregroundStyle(ink)
            Text(stamp.centre)
                .font(.system(size: diameter * (stamp.centre.count > 2 ? 0.2 : 0.3), weight: .heavy, design: .rounded))
                .foregroundStyle(ink)
        }
        .frame(width: diameter, height: diameter)
        .background(Circle().fill(Color(red: 0.988, green: 0.973, blue: 0.925).opacity(0.65)))
        .compositingGroup()
    }
}

/// Text set round a circle, clockwise from the top.
private struct RingText: View {
    let text: String
    let radius: CGFloat
    let size: CGFloat

    var body: some View {
        let characters = Array(text)
        let step = 300.0 / Double(max(characters.count, 1))
        ZStack {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(.system(size: size, weight: .bold))
                    .offset(y: -radius)
                    .rotationEffect(.degrees(-150 + step * (Double(index) + 0.5)))
            }
        }
    }
}

/// The gradient shape: ReArc's shape filled with drifting, blurred blobs over
/// the palette's middle colour, and a fine grain.
private struct CardArt: View {
    let shape: Int
    let seed: [Int]
    let from: MembershipCardPalette
    let to: MembershipCardPalette
    /// Each blob's share of the new palette.
    let retint: (Int) -> Double
    let baseRetint: Double
    let time: Double

    var body: some View {
        let blobs = MembershipCardBlob.layout(seed: seed, colours: to.colours.count)
        Canvas { context, size in
            let base = MembershipCardPalette.mix(from.colours[2], to.colours[2], baseRetint)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(base)))
            for (index, blob) in blobs.enumerated() {
                let colour = Color(MembershipCardPalette.mix(from.colours[blob.colour % from.colours.count],
                                                             to.colours[blob.colour], retint(index)))
                let centre = blob.centre(at: time)
                let point = CGPoint(x: centre.x * size.width, y: centre.y * size.height)
                let radius = blob.size * size.width / 2
                context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                             with: .radialGradient(Gradient(colors: [colour.opacity(0.95), colour.opacity(0)]),
                                                   center: point, startRadius: 0, endRadius: radius))
            }
        }
        .overlay(GrainView().blendMode(.overlay).opacity(0.35))
        .clipShape(MembershipCardShape(number: shape))
    }
}

/// A fixed field of noise, tiled.
private struct GrainView: View {
    private static let tile: NSImage = {
        let side = 96
        var rng = SplitMix64(seed: 0x5EED_CA2D)
        var bytes = (0..<(side * side)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let image = NSImage(size: NSSize(width: side / 2, height: side / 2))
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let cgImage = context.makeImage() else { return }
            image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        }
        return image
    }()

    var body: some View {
        Image(nsImage: Self.tile).resizable(resizingMode: .tile)
    }
}

/// ReArc's four card shapes, from the mark: a sun rising (a dome on the
/// horizon), the horizon's swell, a sextant's fan, and an arch.
struct MembershipCardShape: Shape {
    let number: Int

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, r: CGFloat = 12
        var p = Path()
        switch number {
        case 2:
            // The horizon's swell: a soft rise along the top, square below.
            let shoulder = h * 0.24
            p.move(to: CGPoint(x: 0, y: shoulder + r))
            p.addQuadCurve(to: CGPoint(x: r, y: shoulder), control: CGPoint(x: 0, y: shoulder))
            p.addCurve(to: CGPoint(x: w - r, y: shoulder), control1: CGPoint(x: w * 0.3, y: -h * 0.08),
                       control2: CGPoint(x: w * 0.7, y: -h * 0.08))
            p.addQuadCurve(to: CGPoint(x: w, y: shoulder + r), control: CGPoint(x: w, y: shoulder))
            p.addLine(to: CGPoint(x: w, y: h - r))
            p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: r, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        case 3:
            // A sextant's fan: a quarter ellipse from the bottom-left corner.
            p.move(to: CGPoint(x: 0, y: r))
            p.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero)
            p.addCurve(to: CGPoint(x: w, y: h - r), control1: CGPoint(x: w * 0.6, y: 0), control2: CGPoint(x: w, y: h * 0.42))
            p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: r, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        case 4:
            // An arch: straight sides, a round head.
            let spring = h * 0.5
            p.move(to: CGPoint(x: 0, y: spring))
            p.addCurve(to: CGPoint(x: w / 2, y: 0), control1: CGPoint(x: 0, y: spring * 0.45), control2: CGPoint(x: w * 0.22, y: 0))
            p.addCurve(to: CGPoint(x: w, y: spring), control1: CGPoint(x: w * 0.78, y: 0), control2: CGPoint(x: w, y: spring * 0.45))
            p.addLine(to: CGPoint(x: w, y: h - r))
            p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: r, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        default:
            // The sun rising: a wide dome whose foot sits on the horizon.
            let foot = h * 0.82
            p.move(to: CGPoint(x: 0, y: foot))
            p.addCurve(to: CGPoint(x: w / 2, y: 0), control1: CGPoint(x: 0, y: foot * 0.3), control2: CGPoint(x: w * 0.2, y: 0))
            p.addCurve(to: CGPoint(x: w, y: foot), control1: CGPoint(x: w * 0.8, y: 0), control2: CGPoint(x: w, y: foot * 0.3))
            p.addLine(to: CGPoint(x: w, y: h - 4))
            p.addQuadCurve(to: CGPoint(x: w - 4, y: h), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: 4, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - 4), control: CGPoint(x: 0, y: h))
        }
        p.closeSubpath()
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// Hover: about 5 % larger, tilted toward the pointer (the nearest corner
/// comes forward, at most 8°), with a glare where the pointer is. Springs in
/// and out; nothing at all under Reduce Motion.
private struct CardHover: ViewModifier {
    @Binding var pointer: CGPoint?
    let enabled: Bool

    func body(content: Content) -> some View {
        let p = enabled ? pointer : nil
        let dx = p.map { $0.x - 0.5 } ?? 0, dy = p.map { $0.y - 0.5 } ?? 0
        let tilt = min(1, (dx * dx + dy * dy).squareRoot() * 2) * 8
        content
            .overlay {
                if let p {
                    RadialGradient(colors: [.white.opacity(0.32), .white.opacity(0.1)],
                                   center: UnitPoint(x: p.x, y: p.y), startRadius: 0, endRadius: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .rotation3DEffect(.degrees(tilt), axis: (x: -dy, y: dx, z: 0), perspective: 0.5)
            .scaleEffect(p == nil ? 1 : 1.05)
            .animation(enabled ? .spring(response: 0.35, dampingFraction: 0.8) : nil, value: p)
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard enabled else { return }
                switch phase {
                case .active(let location):
                    pointer = CGPoint(x: location.x / MembershipCardView.size.width, y: location.y / MembershipCardView.size.height)
                case .ended:
                    pointer = nil
                }
            }
    }
}
