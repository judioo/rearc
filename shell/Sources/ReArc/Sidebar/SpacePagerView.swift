import AppKit
import SwiftUI
import SidebarModel

extension EnvironmentValues {
    /// The window's space pager, shared by its sidebar and theme background.
    @Entry var spacePager: SpacePagerController?
}

private struct SwapsCreationPageKey: TransactionKey {
    static let defaultValue = false
}

extension Transaction {
    /// Create a Space's page opening or closing: the page swap animates.
    var swapsCreationPage: Bool {
        get { self[SwapsCreationPageKey.self] }
        set { self[SwapsCreationPageKey.self] = newValue }
    }
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
    /// Create a Space's page opening or closing without a swipe: the theme
    /// fades from `fade.from` over `fade.duration` while the page swaps.
    private(set) var fade: (from: Space.ID, start: TimeInterval, duration: Double)?
    @ObservationIgnored var clock: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    @ObservationIgnored private var restWork: DispatchWorkItem?
    @ObservationIgnored private var fadeWork: DispatchWorkItem?
    @ObservationIgnored private var settleActions: [() -> Void] = []
    /// The pull past the last space is full (for one haptic tick as it fills).
    @ObservationIgnored private var overscrollArmed = false

    var isTracking: Bool { paging.isTracking }

    /// The window theme follows the pager frame by frame: a swipe, or a fade.
    var drivesTheme: Bool { isSwipeDriven || fade != nil }

    /// Keeps the pager on the window's space. A reordered or different space
    /// list (another profile) snaps; a new space in the same list springs.
    /// Create a Space's page coming or going at the end keeps the view where
    /// it is; with `fade` the switch to or from it swaps the page and fades
    /// the theme instead of sliding past the spaces in between.
    func sync(spaceIDs ids: [Space.ID], focused: Space.ID, animated: Bool, fade duration: Double? = nil) {
        guard let index = ids.firstIndex(of: focused) else { return }
        let now = clock()
        if ids != spaceIDs {
            let creationPageMoved = ids.filter { $0 != SpaceCreationSession.pageID }
                == spaceIDs.filter { $0 != SpaceCreationSession.pageID } && !spaceIDs.isEmpty
            let previous = spaceIDs.indices.contains(paging.targetPage) ? spaceIDs[paging.targetPage] : nil
            spaceIDs = ids
            guard creationPageMoved else {
                paging.go(to: index, pageCount: ids.count, animated: false, at: now)
                settle()
                return
            }
            paging.setPageCount(ids.count, at: now)
            if let duration, let previous, previous != focused, !paging.isTracking {
                paging.go(to: index, pageCount: ids.count, animated: false, at: now)
                settle()
                startFade(from: previous, duration: reduceMotion ? 0.2 : duration)
                return
            }
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

    /// The page rests on, or springs to, Create a Space's page.
    var restsOnCreationPage: Bool {
        spaceIDs.indices.contains(paging.targetPage) && spaceIDs[paging.targetPage] == SpaceCreationSession.pageID
    }

    /// Runs `action` once the page is at rest (at once if it already is).
    func whenSettled(_ action: @escaping () -> Void) {
        if isAnimating { settleActions.append(action) } else { action() }
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
        let now = clock()
        paging.track(by: -points / pageWidth, at: now)
        let armed = overscroll(at: now)?.isArmed ?? false
        if armed, !overscrollArmed {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        overscrollArmed = armed
    }

    /// The pull past the last space, while there is one to show: not on
    /// Create a Space's own page, nor under Reduce Motion.
    func overscroll(at time: TimeInterval) -> SpaceOverscroll? {
        guard isSwipeDriven, !reduceMotion, spaceIDs.count == paging.pageCount,
              spaceIDs.last != SpaceCreationSession.pageID else { return nil }
        let stretch = paging.overscroll(at: time)
        return stretch > 0 ? SpaceOverscroll(stretch: stretch) : nil
    }

    /// Returns the space to focus when the swipe lands on another page, or
    /// `SpaceCreationSession.pageID` when it lets go of a full pull past the
    /// last space.
    @discardableResult
    func endSwipe() -> Space.ID? {
        guard paging.isTracking else { return nil }
        let now = clock()
        let creates = overscroll(at: now)?.isArmed ?? false
        overscrollArmed = false
        let target = paging.endTracking(at: now)
        if creates {
            startFrames()
            return SpaceCreationSession.pageID
        }
        if reduceMotion {
            paging.go(to: target, pageCount: spaceIDs.count, animated: false, at: now)
            settle()
        } else {
            startFrames()
        }
        return spaceIDs.indices.contains(target) ? spaceIDs[target] : nil
    }

    func cancelSwipe() {
        overscrollArmed = false
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

    /// The two spaces a swipe is between and how far it has gone, while a
    /// swipe drives the page; the window theme then crossfades with it. A
    /// fade to or from Create a Space's page runs on its own clock, eased out.
    func transition(at time: TimeInterval) -> (from: Space.ID, to: Space.ID, fraction: Double)? {
        if let fade, spaceIDs.indices.contains(paging.targetPage) {
            let t = fade.duration > 0 ? min(max((time - fade.start) / fade.duration, 0), 1) : 1
            return (fade.from, spaceIDs[paging.targetPage], 1 - (1 - t) * (1 - t))
        }
        guard isSwipeDriven, isAnimating, !reduceMotion, spaceIDs.count == paging.pageCount else { return nil }
        let pages = paging.visiblePages(at: time)
        return (spaceIDs[pages.from], spaceIDs[pages.to], pages.fraction)
    }

    private func startFade(from: Space.ID, duration: Double) {
        fadeWork?.cancel()
        fade = (from, clock(), duration)
        let work = DispatchWorkItem { [weak self] in self?.fade = nil }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02, execute: work)
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
        let actions = settleActions
        settleActions = []
        actions.forEach { $0() }
    }
}

/// The paged part of the sidebar: the focused space at rest; while it moves,
/// the one or two spaces in view, each a full sidebar width wide.
/// Past the last space the pull shows Create a Space's "+" at the trailing
/// edge. Each frame moves the pages and that icon only: the pages are
/// equatable, so their tables are not touched.
struct SpacePagesView<Page: View>: View {
    let pager: SpacePagerController
    let focusedSpaceID: Space.ID
    @ViewBuilder let page: (Space.ID) -> Page

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: !pager.isAnimating)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let pages = pager.visiblePages(at: time, focused: focusedSpaceID)
                ZStack(alignment: .topLeading) {
                    ForEach(pages, id: \.id) { entry in
                        page(entry.id)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .offset(x: entry.offset * geometry.size.width)
                            .transition(entry.id == SpaceCreationSession.pageID ? Self.creationPageTransition : .opacity)
                    }
                    if let pull = pager.overscroll(at: time), pull.isVisible {
                        SpaceOverscrollIcon(pull: pull)
                            .position(x: geometry.size.width - pull.centerInset, y: geometry.size.height / 2)
                    }
                }
            }
        }
        .clipped()
        // Reduce Motion swaps spaces with a crossfade instead of a slide.
        // Create a Space's page keeps the animation it was opened with.
        .transaction(value: focusedSpaceID) { transaction in
            if pager.reduceMotion {
                transaction.animation = .easeInOut(duration: 0.2)
            } else if !transaction.swapsCreationPage {
                transaction.animation = nil
            }
        }
    }

    /// Arc pops the page in from 14 pt to the right as its theme comes in.
    static var creationPageTransition: AnyTransition {
        .asymmetric(insertion: .offset(x: 14).combined(with: .opacity), removal: .opacity)
    }
}

/// Create a Space's pull icon (§2.3): a pale disc with a "+" whose ring
/// closes anticlockwise from 12 o'clock as the pull grows. Full, the ring
/// floods inward to a solid disc and the "+" turns pale, with a slight pop.
struct SpaceOverscrollIcon: View {
    let pull: SpaceOverscroll
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        let diameter = SpaceOverscroll.diameter
        let armed = pull.isArmed
        ZStack {
            Circle().fill(chrome.toast)
            Circle()
                .trim(from: 0, to: pull.ring)
                .stroke(chrome.accent, style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .scaleEffect(x: -1)
                .padding(0.875)
            Circle()
                .fill(chrome.accent)
                .scaleEffect(armed ? 1 : 0.001)
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(armed ? chrome.toast : chrome.accent)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(armed ? 1.07 : 1)
        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
        .animation(.spring(response: 0.16, dampingFraction: 0.62), value: armed)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The window background behind the sidebar and around the page, drawn from
/// the focused space's theme (Arc `WindowTheme`, THEMES.md §3.4): the whole
/// window is the theme, with no sidebar panel of its own. A swipe mixes the
/// two spaces' rendered themes frame by frame, so the colour moves with the
/// fingers; Create a Space's page fades in and out; other switches swap.
/// Only this view and the page offsets redraw per frame.
struct SpaceThemeBackground: View {
    let model: BrowserViewModel
    let window: SidebarWindowID?
    let pager: SpacePagerController?
    @Environment(\.colorScheme) private var colorScheme

    /// The window's space; Create a Space shows the new space's theme in
    /// its window as it is edited (ARC-RECORDING-ANALYSIS.md §5.2).
    private var shownSpace: Space {
        var space = model.space(in: window)
        space.theme = model.shownTheme(in: window)
        return space
    }

    var body: some View {
        let space = shownSpace
        let systemDark = SystemAppearance.isDark(colorScheme)
        TimelineView(.animation(paused: !(pager?.drivesTheme ?? false))) { context in
            let swipe = pager?.transition(at: context.date.timeIntervalSinceReferenceDate)
            let from = swipe.flatMap { model.pageTheme($0.from) }
            let to = swipe.flatMap { model.pageTheme($0.to) }
            if let swipe, let from, let to {
                ThemeCrossfadeView(
                    theme: space.theme,
                    dark: from.appearance.isDark(systemDark: systemDark),
                    swipe: (from, to, swipe.fraction),
                    dark2: to.appearance.isDark(systemDark: systemDark)
                )
            } else {
                ThemeCrossfadeView(theme: space.theme, dark: space.theme.appearance.isDark(systemDark: systemDark))
            }
        }
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
        return isSystemDark
    }

    static var isSystemDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
/// `isEnabled` is asked when a gesture begins, so the sidebar never observes
/// what it reads.
struct SidebarSwipeMonitor: NSViewRepresentable {
    var isEnabled: () -> Bool
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
                tracking = window.isKeyWindow && view.bounds.contains(point) && parent.isEnabled()
                claimed = false
                swallowMomentum = false
                lock = SwipeAxisLock()
                if tracking { _ = lock.add(dx: contentDelta(event), dy: event.scrollingDeltaY) }
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
                parent.onChange(contentDelta(event))
                return nil
            }
            switch lock.add(dx: contentDelta(event), dy: event.scrollingDeltaY) {
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

        private func contentDelta(_ event: NSEvent) -> Double {
            SwipeAxisLock.contentDelta(event.scrollingDeltaX, invertedFromDevice: event.isDirectionInvertedFromDevice)
        }
    }
}
