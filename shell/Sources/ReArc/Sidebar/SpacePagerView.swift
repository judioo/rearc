import AppKit
import SwiftUI
import SidebarModel

extension EnvironmentValues {
    /// The window's space pager, shared by its sidebar and theme background.
    @Entry var spacePager: SpacePagerController?
}

/// One window's horizontal paging between the spaces of its profile (Arc
/// `SidebarPagingContainer`, SIDEBAR-SPEC §4.7). A two-finger swipe on the
/// sidebar drives it; other switches (click, Ctrl+N, ⌥⌘←/→) spring it to the
/// new page. The physics are `SpacePaging`; this adds the clock and tells the
/// views when frames are needed.
@Observable
final class SpacePagerController {
    private(set) var paging = SpacePaging(pageCount: 1, page: 0)
    private(set) var spaceIDs: [Space.ID] = []
    /// Frames are needed: a finger or a spring moves the page.
    private(set) var isAnimating = false
    /// The motion came from a swipe (until it rests); the window theme then
    /// follows the page instead of crossfading.
    private(set) var isSwipeDriven = false
    /// Reduce Motion: swipes still switch, but on release and without sliding.
    var reduceMotion = false
    @ObservationIgnored var clock: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    @ObservationIgnored private var restWork: DispatchWorkItem?

    var isTracking: Bool { paging.isTracking }

    /// Keeps the pager on the window's space. A reordered or different space
    /// list (another profile) snaps; a new space in the same list springs.
    func sync(spaceIDs ids: [Space.ID], focused: Space.ID, animated: Bool) {
        guard let index = ids.firstIndex(of: focused) else { return }
        let now = clock()
        if ids != spaceIDs {
            spaceIDs = ids
            paging.go(to: index, pageCount: ids.count, animated: false, at: now)
            settle()
            return
        }
        guard index != paging.targetPage, !paging.isTracking else { return }
        let animate = animated && !reduceMotion
        paging.go(to: index, pageCount: ids.count, animated: animate, at: now)
        if animate {
            isSwipeDriven = false
            startFrames()
        } else {
            settle()
        }
    }

    func beginSwipe() {
        guard !spaceIDs.isEmpty else { return }
        restWork?.cancel()
        paging.beginTracking(at: clock())
        isSwipeDriven = true
        isAnimating = true
    }

    /// `points` of finger travel, content direction (negative shows the next space).
    func swipe(byPoints points: Double, pageWidth: Double) {
        guard paging.isTracking, pageWidth > 0 else { return }
        paging.track(by: -points / pageWidth, at: clock())
    }

    /// Returns the space to focus when the swipe lands on another page.
    @discardableResult
    func endSwipe() -> Space.ID? {
        guard paging.isTracking else { return nil }
        let now = clock()
        let target = paging.endTracking(at: now)
        if reduceMotion {
            paging.go(to: target, pageCount: spaceIDs.count, animated: false, at: now)
            settle()
        } else {
            startFrames()
        }
        return spaceIDs.indices.contains(target) ? spaceIDs[target] : nil
    }

    func cancelSwipe() {
        guard paging.isTracking else { return }
        paging.cancelTracking(at: clock())
        startFrames()
    }

    /// Pages to draw at `time` with their horizontal offsets (in page widths).
    func visiblePages(at time: TimeInterval, focused: Space.ID) -> [(id: Space.ID, offset: Double)] {
        guard isAnimating, !reduceMotion, spaceIDs.count == paging.pageCount else { return [(focused, 0)] }
        let position = paging.position(at: time)
        let pages = paging.visiblePages(at: time)
        return Array(Set([pages.from, pages.to])).sorted().map { (spaceIDs[$0], Double($0) - position) }
    }

    /// The window palette part-way between the two visible spaces, each in
    /// its own appearance (`systemDark` is the Mac's).
    func palette(at time: TimeInterval, theme: (Space.ID) -> SpaceTheme?, darkAppearance systemDark: Bool) -> SpaceThemePalette? {
        guard isSwipeDriven, isAnimating, !reduceMotion, spaceIDs.count == paging.pageCount else { return nil }
        let pages = paging.visiblePages(at: time)
        guard let from = theme(spaceIDs[pages.from]), let to = theme(spaceIDs[pages.to]) else { return nil }
        return SpaceThemePalette(theme: from, darkAppearance: from.appearance.isDark(systemDark: systemDark))
            .mixed(with: SpaceThemePalette(theme: to, darkAppearance: to.appearance.isDark(systemDark: systemDark)),
                   fraction: pages.fraction)
    }

    private func startFrames() {
        isAnimating = true
        restWork?.cancel()
        guard let rest = paging.restTime else { return }
        let work = DispatchWorkItem { [weak self] in self?.settleIfResting() }
        restWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, rest - clock()) + 0.02, execute: work)
    }

    private func settleIfResting() {
        if paging.isTracking || paging.isAnimating(at: clock()) {
            startFrames()
        } else {
            settle()
        }
    }

    private func settle() {
        restWork?.cancel()
        restWork = nil
        isAnimating = false
        isSwipeDriven = false
    }
}

/// The paged part of the sidebar: the focused space at rest; while it moves,
/// the one or two spaces in view, each a full sidebar width wide.
struct SpacePagesView<Page: View>: View {
    let pager: SpacePagerController
    let focusedSpaceID: Space.ID
    @ViewBuilder let page: (Space.ID) -> Page

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: !pager.isAnimating)) { context in
                let pages = pager.visiblePages(at: context.date.timeIntervalSinceReferenceDate, focused: focusedSpaceID)
                ZStack(alignment: .topLeading) {
                    ForEach(pages, id: \.id) { entry in
                        page(entry.id)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .offset(x: entry.offset * geometry.size.width)
                            .transition(.opacity)
                    }
                }
            }
        }
        .clipped()
        // Reduce Motion swaps spaces with a crossfade instead of a slide.
        .animation(pager.reduceMotion ? .easeInOut(duration: 0.2) : nil, value: focusedSpaceID)
    }
}

/// The window background behind the sidebar and around the page, drawn from
/// the focused space's theme (Arc `WindowTheme`, SIDEBAR-SPEC §4.8). It
/// follows a swipe frame by frame and crossfades on other switches.
struct SpaceThemeBackground: View {
    let model: BrowserViewModel
    let window: SidebarWindowID?
    let pager: SpacePagerController?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let space = model.space(in: window)
        let systemDark = SystemAppearance.isDark(colorScheme)
        TimelineView(.animation(paused: !(pager?.isSwipeDriven ?? false))) { context in
            let palette = pager?.palette(
                at: context.date.timeIntervalSinceReferenceDate,
                theme: { model.store.space(withID: $0)?.theme },
                darkAppearance: systemDark
            ) ?? SpaceThemePalette(theme: space.theme, darkAppearance: space.theme.appearance.isDark(systemDark: systemDark))
            SpaceThemeFill(palette: palette)
        }
        .animation((pager?.isSwipeDriven ?? false) ? nil : .easeInOut(duration: 0.3), value: space.theme)
        .animation((pager?.isSwipeDriven ?? false) ? nil : .easeInOut(duration: 0.3), value: space.id)
    }
}

/// A theme palette drawn: its stops (top to bottom for one colour, corner
/// to corner for a gradient) under procedural grain (Arc draws its
/// `grain` texture with Metal, DESIGN-TOKENS §2.2; this tile is generated).
struct SpaceThemeFill: View {
    let palette: SpaceThemePalette
    var diagonalStart: UnitPoint = .topLeading
    var diagonalEnd: UnitPoint = .bottomTrailing

    var body: some View {
        let colors = palette.colors.map { Color($0) }
        LinearGradient(colors: colors,
                       startPoint: palette.isDiagonal ? diagonalStart : .top,
                       endPoint: palette.isDiagonal ? diagonalEnd : .bottom)
            .overlay {
                if palette.noise > 0 {
                    Image(nsImage: GrainTexture.tile)
                        .resizable(resizingMode: .tile)
                        .blendMode(.overlay)
                        .opacity(min(palette.noise, 1) * 0.9)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A 128-point tile of monochrome noise, the same on every launch.
enum GrainTexture {
    static let tile: NSImage = {
        let side = 128
        var generator = SplitMix64(seed: 0x5EED_A7C0)
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for index in 0 ..< side * side {
            let value = UInt8(truncatingIfNeeded: generator.next() >> 56)
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = 255
        }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: side * 4, bitsPerPixel: 32)!
        pixels.withUnsafeBufferPointer { buffer in
            rep.bitmapData!.update(from: buffer.baseAddress!, count: buffer.count)
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }()

    struct SplitMix64 {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// The Mac's own appearance, whatever a window was set to. `colorScheme`
/// is passed so SwiftUI redraws when it changes.
enum SystemAppearance {
    static func isDark(_ colorScheme: ColorScheme) -> Bool {
        _ = colorScheme
        return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Sets its window's appearance from the shown space (nil follows the Mac).
struct WindowAppearanceSetter: NSViewRepresentable {
    let appearance: SpaceAppearance

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        let target: NSAppearance? = switch appearance {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        DispatchQueue.main.async {
            guard let window = nsView.window, window.appearance?.name != target?.name else { return }
            window.appearance = target
        }
    }
}

extension Color {
    init(_ theme: SpaceTheme) {
        self.init(red: theme.red, green: theme.green, blue: theme.blue)
    }
}

/// Turns two-finger horizontal scrolls over the sidebar into space swipes.
/// The first few points decide the axis: vertical scrolls pass through to
/// the sidebar's scroll view; a horizontal one is consumed, momentum included.
struct SidebarSwipeMonitor: NSViewRepresentable {
    var isEnabled: Bool
    var onBegin: () -> Void
    var onChange: (Double) -> Void
    var onEnd: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak coordinator = context.coordinator] event in
            coordinator?.handle(event) ?? event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
        if coordinator.claimed { coordinator.parent.onCancel() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: SidebarSwipeMonitor
        weak var view: NSView?
        var monitor: Any?
        private var tracking = false
        private(set) var claimed = false
        private var swallowMomentum = false
        private var lock = SwipeAxisLock()

        init(parent: SidebarSwipeMonitor) { self.parent = parent }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard event.hasPreciseScrollingDeltas, let view, let window = view.window, event.window === window else {
                return event
            }
            if !event.momentumPhase.isEmpty {
                let swallow = swallowMomentum
                if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                    swallowMomentum = false
                }
                return swallow ? nil : event
            }
            if event.phase.contains(.began) {
                let point = view.convert(event.locationInWindow, from: nil)
                tracking = parent.isEnabled && window.isKeyWindow && view.bounds.contains(point)
                claimed = false
                swallowMomentum = false
                lock = SwipeAxisLock()
                if tracking { _ = lock.add(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY) }
                return event
            }
            guard tracking else { return event }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                tracking = false
                if claimed {
                    claimed = false
                    swallowMomentum = true
                    if event.phase.contains(.ended) { parent.onEnd() } else { parent.onCancel() }
                }
                return event
            }
            guard event.phase.contains(.changed) else { return event }
            if claimed {
                parent.onChange(event.scrollingDeltaX)
                return nil
            }
            switch lock.add(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY) {
            case .horizontal:
                claimed = true
                parent.onBegin()
                parent.onChange(lock.dx)
                return nil
            case .vertical:
                tracking = false
                return event
            case .undecided:
                return event
            }
        }
    }
}
