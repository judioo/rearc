import SwiftUI
import SidebarModel

/// A bottom-bar hover chip as Arc draws "Exit Library" and "Share Arc"
/// (ARC-RECORDING-2026-11-06.md §5.1): a small rounded label with a hairline
/// edge and a soft shadow, the shortcut after the name in a lighter tone.
struct BarChip: View {
    let label: BarChipLabel
    var fill: Color
    var text: Color
    var secondary: Color
    /// A space chip leads with the space's colour.
    var swatch: Color?

    /// Names the bar's coordinate space, which spans the sidebar's width.
    static let coordinateSpace = "rearc.bottomBar"
    /// Chip to the button beside it.
    static let gap: CGFloat = 6
    /// Chip to the top of the dot's 24 pt hit box under it.
    static let aboveGap: CGFloat = 2
    /// Kept this far inside the sidebar's edges.
    static let margin: CGFloat = 8

    /// Arc's own chips: white, or a dark grey in a dark space.
    static func neutral(_ label: BarChipLabel, dark: Bool) -> BarChip {
        BarChip(label: label,
                fill: dark ? Color(white: 0.2) : .white,
                text: dark ? .white : Color(white: 0.1),
                secondary: dark ? Color(white: 0.62) : Color(white: 0.45))
    }

    var body: some View {
        HStack(spacing: 5) {
            if let swatch {
                Circle().fill(swatch).frame(width: 7, height: 7)
            }
            Text(label.title)
                .foregroundStyle(text)
                .truncationMode(.tail)
            if let shortcut = label.shortcut {
                Text(shortcut)
                    .foregroundStyle(secondary)
                    .layoutPriority(1)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Places one chip just above `anchor`, centred on it and slid to stay inside
/// `minX…maxX` (the sidebar's edges in this layout's coordinates).
struct BarChipAboveLayout: Layout {
    var anchor: CGRect
    var minX: CGFloat
    var maxX: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let room = maxX - minX
        let fit = ProposedViewSize(width: max(room - 2 * BarChip.margin, 0), height: nil)
        for subview in subviews {
            let size = subview.sizeThatFits(fit)
            let x = BarChipPlacement.centredX(anchorMidX: Double(anchor.midX - minX), width: Double(size.width),
                                              containerWidth: Double(room), margin: Double(BarChip.margin))
            subview.place(at: CGPoint(x: bounds.minX + minX + CGFloat(x), y: bounds.minY + anchor.minY - BarChip.aboveGap),
                          anchor: .bottomLeading, proposal: ProposedViewSize(size))
        }
    }
}

/// A bottom-bar button's chip after a rest on it: beside it, as Arc places
/// "Exit Library", or above it at the bar's right end, where beside would
/// run off the sidebar. The hover state is the button's own.
struct BarButtonChip: ViewModifier {
    enum Placement { case trailing, above }

    let label: BarChipLabel
    var placement: Placement = .trailing
    var isEnabled = true
    @State private var timing = HoverChipTiming<Bool>()
    @State private var task: Task<Void, Never>?
    @Environment(\.themeChrome) private var chrome

    func body(content: Content) -> some View {
        content
            .onHover { hoverChip($timing, $task, hovering: $0, id: true) }
            .overlay(alignment: placement == .trailing ? .trailing : .topTrailing) {
                if isEnabled, timing.shown != nil {
                    BarChip.neutral(label, dark: chrome.isWindowDark)
                        .fixedSize()
                        .alignmentGuide(.trailing) { placement == .trailing ? $0[.leading] - BarChip.gap : $0[.trailing] }
                        .alignmentGuide(.top) { $0[.bottom] + BarChip.gap }
                        .transition(.opacity)
                }
            }
            .onChange(of: isEnabled) { _, enabled in
                if !enabled { timing.dismiss() }
            }
    }
}

/// Feeds one hover change to a chip's timing and, when a chip is pending,
/// wakes to show it. Chips fade in and out in ≈ 0.12 s.
@MainActor
func hoverChip<ID>(_ timing: Binding<HoverChipTiming<ID>>, _ task: Binding<Task<Void, Never>?>, hovering: Bool, id: ID) {
    task.wrappedValue?.cancel()
    withAnimation(BarChipMotion.fade) {
        timing.wrappedValue.setHovering(hovering, id, at: ProcessInfo.processInfo.systemUptime)
    }
    guard let deadline = timing.wrappedValue.deadline else { return }
    task.wrappedValue = Task { @MainActor in
        let wait = max(deadline - ProcessInfo.processInfo.systemUptime, 0)
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        guard !Task.isCancelled else { return }
        withAnimation(BarChipMotion.fade) {
            _ = timing.wrappedValue.advance(to: max(ProcessInfo.processInfo.systemUptime, deadline))
        }
    }
}

enum BarChipMotion {
    static let fade = Animation.easeOut(duration: 0.12)
}
