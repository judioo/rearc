import SwiftUI

/// The marquee's timing, kept apart from the view so tests can check it.
enum MarqueeMotion {
    /// Points per second: slow enough to read (Arc's mini player title crawls).
    static let speed: Double = 24
    /// Space between the title and its repeat.
    static let gap: Double = 36
    /// The title rests at its start before each pass.
    static let pause: Double = 1.6

    /// Leftward offset `elapsed` seconds into the scroll of a title `overflow`
    /// points wider than its frame; 0 while resting. One pass moves the
    /// title by its width plus the gap, so the repeat lands where it began.
    static func offset(elapsed: Double, textWidth: Double, overflow: Double) -> Double {
        guard overflow > 0.5, textWidth > 0 else { return 0 }
        let travel = textWidth + gap
        let cycle = pause + travel / speed
        let t = elapsed.truncatingRemainder(dividingBy: cycle)
        return t < pause ? 0 : (t - pause) * speed
    }

    static func scrolls(overflow: Double, isActive: Bool, reduceMotion: Bool) -> Bool {
        overflow > 0.5 && isActive && !reduceMotion
    }
}

/// One line of text that scrolls when it is too long for its frame and
/// `isActive`; otherwise (and under Reduce Motion) it truncates with an ellipsis.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    let isActive: Bool
    @State private var textWidth: Double = 0
    @State private var frameWidth: Double = 0
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var overflow: Double { textWidth - frameWidth }

    var body: some View {
        let label = Text(text).font(font).foregroundStyle(color).lineLimit(1)
        ZStack(alignment: .leading) {
            if MarqueeMotion.scrolls(overflow: overflow, isActive: isActive, reduceMotion: reduceMotion) {
                TimelineView(.animation) { context in
                    let x = MarqueeMotion.offset(elapsed: context.date.timeIntervalSince(start), textWidth: textWidth, overflow: overflow)
                    HStack(spacing: MarqueeMotion.gap) {
                        label.fixedSize()
                        label.fixedSize()
                    }
                    .offset(x: -x)
                }
                // minWidth 0: without it the frame takes the doubled title's width
                // and the hovered strip grows past the sidebar.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .mask(fadeMask)
            } else {
                label.truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.onAppear { frameWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in frameWidth = width }
        })
        .background(label.fixedSize().hidden().background(GeometryReader { proxy in
            Color.clear.onAppear { textWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { _, width in textWidth = width }
        }))
        // Each pass starts from rest at the title's beginning.
        .onChange(of: isActive) { _, active in if active { start = Date() } }
        .onChange(of: text) { _, _ in start = Date() }
        .accessibilityElement()
        .accessibilityLabel(text)
    }

    /// Soft edges so the title slides in and out rather than being cut.
    private var fadeMask: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.04),
            .init(color: .black, location: 0.92), .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }
}
