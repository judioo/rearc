import AppKit
import SwiftUI

/// Drives one playback of Act 0: the clock, the score, skip, mute and Begin.
@MainActor
public final class SunrisePlayer: ObservableObject {
    @Published public private(set) var variant: SunriseVariant
    @Published public private(set) var startDate = Date()
    @Published public private(set) var exitStart: Date?
    @Published public var muted = false { didSet { audio?.muted = muted } }
    /// In a window centred on the main screen rather than over all of it.
    @Published public internal(set) var windowed = false
    var onToggleWindow: (() -> Void)?
    /// How "Onboard later" closes the scene.
    @Published public var closingStyle: SunriseClosing = .sunset
    /// When "Onboard later" was pressed, and how it is closing.
    @Published public private(set) var closingStart: Date?
    private(set) var activeClosing: SunriseClosing?
    var closingFrom = 0.0
    /// The prototype plays again after closing, so closings can be compared.
    public var replaysAfterLater = false
    /// Full screen ⇄ a window centred on the main screen; offered throughout.
    public func toggleWindow() { onToggleWindow?() }
    /// Act 1, from Begin on.
    @Published public private(set) var act1: Act1Log? { didSet { rescore() } }
    @Published public var name = "" { didSet { edited(oldValue) } }
    /// Swatch under the keyboard's arrows.
    var keyboardSwatch: Int?
    /// Act 2, from the colour pick on.
    @Published public private(set) var act2: Act2Log? { didSet { rescore() } }
    /// Other browsers' profiles; scanned (read-only) while Act 1 plays.
    public var sources: [ImportSource]?
    public var usesDemoSources = false
    /// Act 3, after the blue sweep.
    @Published public private(set) var act3: Act3Log? { didSet { rescore() } }
    /// Act 4: the motto, then the window.
    @Published public private(set) var act4: Act4Log? { didSet { rescore() } }
    public let reduced: Bool
    public var line = "A New Dawn"
    public enum Mode: Sendable { case firstRun, replay }
    /// Replay (Help › Watch the Sunrise Again) is Act 0 alone.
    public var mode: Mode = .firstRun
    /// The browser it runs in; nil in the prototype.
    public weak var host: OnboardingHost?
    /// Spaces the host's import created (Act 3's seeds).
    var importedSpaces: [SpaceSeed]?
    /// Called when the drawn window is complete, to put the real one there.
    var onReveal: (() -> Void)?
    public var onFinished: (() -> Void)?
    var audio: SunriseAudio?
    public static let exitDuration = 1.6

    public init(variant: SunriseVariant, reduced: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.variant = variant
        self.reduced = reduced
        audio = try? SunriseAudio(variant: variant, reduced: reduced)
    }

    var cues: SunriseCues { reduced ? .reduced : .of(variant) }

    /// Every act's sounds follow from its log: re-scored on each change, so
    /// what you do is heard the moment it is drawn.
    func rescore() {
        var score = SunriseScore.build(act1: act1, act2: act2, act3: act3, act4: act4)
        if let start = closingStart, let style = activeClosing {
            score.hits += SunriseClosingFrame.hits(style, start: time(at: start))
        }
        audio?.update(score, sceneTime: time(at: Date()))
    }

    /// "Onboard later" is offered until Act 4 applies what was chosen.
    public var canOnboardLater: Bool { act4 == nil && exitStart == nil && closingStart == nil }

    /// "Onboard later": the act steps back, the scene closes, nothing is applied.
    public func later() {
        guard canOnboardLater else { return }
        let style = closingStyle.resolved(reduced: reduced)
        let now = Date()
        closingFrom = min(time(at: now), cues.end)
        activeClosing = style
        closingStart = now
        rescore()
        audio?.fadeOut(over: style.duration)
        NSCursor.unhide()
        DispatchQueue.main.asyncAfter(deadline: .now() + style.duration + 0.2) { [weak self] in
            guard let self, self.closingStart == now else { return }
            if self.replaysAfterLater { self.play(); return }
            self.audio?.stop()
            self.host?.onboardingDeferred()
            self.onFinished?()
        }
    }

    public func cycleClosing() {
        let all = SunriseClosing.allCases
        closingStyle = all[((all.firstIndex(of: closingStyle) ?? 0) + 1) % all.count]
    }

    public func closing(at date: Date) -> SunriseClosingFrame? {
        guard let start = closingStart, let style = activeClosing else { return nil }
        return SunriseClosingFrame(style: style, progress: min(1, date.timeIntervalSince(start) / style.duration), from: closingFrom)
    }

    public func time(at date: Date) -> Double { date.timeIntervalSince(startDate) }

    public func exit(at date: Date) -> Double {
        guard let exitStart else { return 0 }
        return Ease.inOut(date.timeIntervalSince(exitStart) / Self.exitDuration)
    }

    /// From the top: also "Watch the Sunrise Again".
    public func play(_ variant: SunriseVariant? = nil) {
        if let variant { self.variant = variant }
        exitStart = nil
        closingStart = nil
        activeClosing = nil
        act1 = nil
        act2 = nil
        act3 = nil
        act4 = nil
        name = ""
        try? audio?.start(variant: self.variant, reduced: reduced)
        audio?.muted = muted
        startDate = Date()
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    public func skip() {
        guard act1 == nil, time(at: Date()) < cues.end else { return }
        startDate = Date().addingTimeInterval(-cues.end)
        audio?.skip()
    }

    /// Begin: on to Act 1.
    public func begin() {
        if mode == .replay { finish(); return }
        guard act1 == nil, exitStart == nil else { return }
        act1 = Act1Log(start: time(at: Date()))
        if sources == nil {
            if let host {
                host.discoverSources { [weak self] found in self?.sources = found }
            } else if usesDemoSources { sources = ImportSource.demo } else {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let found = BrowserScanner.scan()
                    DispatchQueue.main.async { self?.sources = found }
                }
            }
        }
    }

    func edited(_ old: String) {
        guard var log = act1, log.submitted == nil, name != old else { return }
        if name.count > 40 { name = String(name.prefix(40)); return }
        log.edits.append((time(at: Date()), name))
        act1 = log
    }

    public func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var log = act1, log.submitted == nil, !trimmed.isEmpty else { return }
        log.submitted = (time(at: Date()), trimmed)
        act1 = log
    }

    var choosing: Bool {
        guard let log = act1, let s = log.submitted, log.picked == nil else { return false }
        return time(at: Date()) > s.time + Act1Timeline.swatchesIn + 0.6
    }

    public func hover(_ index: Int?) {
        guard choosing, var log = act1, log.hovers.last?.index != index else { return }
        log.hovers.append((time(at: Date()), index))
        act1 = log
    }

    public func pick(_ index: Int) {
        guard choosing, var log = act1 else { return }
        log.picked = (time(at: Date()), index)
        act1 = log
        DispatchQueue.main.asyncAfter(deadline: .now() + Act1Timeline.confirmHold) { [weak self] in
            guard self?.act1?.picked != nil else { return }
            self?.startAct2()
        }
    }

    /// Arrow keys walk the swatches; Return picks.
    func moveSwatch(_ delta: Int) {
        guard choosing else { return }
        let n = ProfilePalette.colours.count
        let next = keyboardSwatch.map { min(max($0 + delta, 0), n - 1) } ?? (delta > 0 ? 0 : n - 1)
        keyboardSwatch = next
        hover(next)
    }

    func pickKeyboardSwatch() { if let i = keyboardSwatch ?? act1?.hovers.last?.index { pick(i) } }

    func startAct2() {
        guard act2 == nil, exitStart == nil else { return }
        let log = Act2Log(start: time(at: Date()), sources: sources ?? [],
                          offered: host?.importCategories ?? ImportCategory.allCases)
        act2 = log
        if log.sources.isEmpty {
            // Nothing to bring: a clean start, without asking.
            DispatchQueue.main.asyncAfter(deadline: .now() + Act2Timeline.ready) { [weak self] in self?.choose(false) }
        }
    }

    var act2Ready: Bool {
        guard let log = act2, log.choice == nil else { return false }
        return time(at: Date()) > log.start + Act2Timeline.ready - 0.3
    }

    public func toggleSource(_ i: Int) {
        guard act2Ready, var log = act2 else { return }
        log.toggles.append((time(at: Date()), i))
        act2 = log
    }

    public func toggleCategory(_ c: ImportCategory) {
        guard act2Ready, var log = act2 else { return }
        log.categories.append((time(at: Date()), c))
        act2 = log
    }

    public func choose(_ bring: Bool) {
        guard var log = act2, log.choice == nil else { return }
        let now = time(at: Date())
        log.choice = (now, bring)
        act2 = log
        guard let handOff = log.handOff else { return }
        if log.bringing, let host {
            let kept = log.sources.indices.filter { log.isOn(source: $0, at: now) }.map { log.sources[$0] }
            let categories = log.offered.filter { log.isOn($0, at: now) }
            host.bring(kept, categories: categories) { [weak self] outcome in
                guard let self, var current = self.act2 else { return }
                current.outcome = outcome.totals
                self.act2 = current
                self.importedSpaces = outcome.spaces
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + handOff - now) { [weak self] in
            guard self?.act2?.choice != nil else { return }
            self?.startAct3()
        }
    }

    var act2Controls: Act2Controls {
        Act2Controls(toggleSource: { self.toggleSource($0) }, toggleCategory: { self.toggleCategory($0) },
                     choose: { self.choose($0) })
    }

    var yourColour: RGBA {
        act1?.picked.map { ProfilePalette.colours[$0.index].rgba } ?? MarkPalette.sun
    }

    func startAct3() {
        guard act3 == nil, exitStart == nil else { return }
        let start = time(at: Date())
        if host != nil {
            // The spaces that really exist now, or suggestions for a clean start.
            let imported = importedSpaces ?? []
            act3 = imported.isEmpty
                ? Act3Log(start: start, seeds: Act3Log.suggested(colour: yourColour), imported: false)
                : Act3Log(start: start, seeds: Array(imported.prefix(Act3Timeline.maxSpaces)), imported: true)
        } else {
            act3 = Act3Log.after(act2, start: start, colour: yourColour)
        }
    }

    var act3Ready: Bool {
        guard let log = act3, log.doneTime == nil else { return false }
        return time(at: Date()) > log.start + Act3Timeline.ready - 0.3
    }

    func record(_ event: Act3Event) {
        guard act3Ready, var log = act3 else { return }
        log.events.append((time(at: Date()), event))
        act3 = log
    }

    var selectedSpace: Int? { act3.flatMap { $0.state(at: time(at: Date())).selected } }

    public func selectSpace(_ id: Int?) {
        guard id != selectedSpace else { return }
        record(.select(id))
    }

    public func addSpace() { record(.add) }

    public func removeSelectedSpace() {
        guard let id = selectedSpace else { return }
        record(.remove(id))
    }

    public func spacesDone() {
        guard act3Ready else { return }
        record(.done)
        DispatchQueue.main.asyncAfter(deadline: .now() + Act3Timeline.finale) { [weak self] in self?.startAct4() }
    }

    func startAct4() {
        guard act4 == nil, exitStart == nil else { return }
        let now = time(at: Date())
        let log = Act4Log.after(act1: act1, act2: act2, act3: act3, start: now)
        act4 = log
        host?.apply(OnboardingResult.from(act1: act1, act3: act3, at: now))
        // The real window goes in under the drawn one once that is complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + Act4Timeline.flight + 2.7) { [weak self] in self?.onReveal?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Act4Timeline.length) { [weak self] in self?.finish() }
    }

    var act3Controls: Act3Controls {
        Act3Controls(
            name: Binding(
                get: { self.act3.flatMap { log in log.state(at: self.time(at: Date())).spaces.first { $0.id == self.selectedSpace }?.name } ?? "" },
                set: { name in if let id = self.selectedSpace { self.record(.rename(id, String(name.prefix(32)))) } }),
            select: { self.selectSpace($0) },
            colour: { c in if let id = self.selectedSpace { self.record(.colour(id, c)) } },
            icon: { i in if let id = self.selectedSpace { self.record(.icon(id, i)) } },
            add: { self.addSpace() },
            remove: { self.removeSelectedSpace() },
            done: { self.spacesDone() })
    }

    /// The act is over: hand back (Act 2 comes next; the prototype ends here).
    public func finish() {
        guard exitStart == nil else { return }
        exitStart = Date()
        audio?.fadeOut()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDuration + 0.3) { [weak self] in
            guard let self, self.exitStart != nil else { return }
            self.audio?.stop()
            self.host?.onboardingFinished()
            self.onFinished?()
        }
    }

    var controls: Act1Controls {
        Act1Controls(text: Binding(get: { self.name }, set: { self.name = $0 }),
                     submit: { self.submit() }, hover: { self.hover($0) }, pick: { self.pick($0) })
    }

    public var isAtRest: Bool { time(at: Date()) >= cues.end }
}

struct SunriseLiveView: View {
    @ObservedObject var player: SunrisePlayer
    var showsVariantPicker: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = player.time(at: timeline.date)
            let exit = player.exit(at: timeline.date)
            let dawn = SunriseTimeline.dawn(player.variant, t, reduced: player.reduced)
            let closing = player.closing(at: timeline.date)
            ZStack {
                SunriseSceneView(variant: player.variant, time: t, reduced: player.reduced,
                                 exit: exit, line: player.line, onBegin: { player.begin() },
                                 act1: player.act1, controls: player.controls,
                                 act2: player.act2, act2Controls: player.act2Controls,
                                 act3: player.act3, act3Controls: player.act3Controls, act4: player.act4,
                                 closing: closing)
                hints(t: t, dawn: dawn, exit: max(exit, closing.map { Ease.smooth(Ease.progress($0.progress, 0, 0.2)) } ?? 0))
                    .sunriseControlsActive(closing == nil)
            }
        }
        .ignoresSafeArea()
    }

    func hints(t: Double, dawn: Double, exit: Double) -> some View {
        let ink = RGBA(1, 1, 1, 0.55).mix(MarkPalette.ink.alpha(0.5), Ease.smooth((dawn - 0.6) / 0.4)).color
        let veil = Ease.smooth(t / 1.6) * (1 - exit)
        let cues = player.reduced ? SunriseCues.reduced : SunriseCues.of(player.variant)
        let skip = player.act1 == nil ? 1 - Ease.smooth(Ease.progress(t, cues.text - 0.6, cues.text)) : 0
        return VStack {
            Spacer()
            HStack(alignment: .bottom) {
                if showsVariantPicker {
                    HStack(spacing: 14) {
                        ForEach(Array(SunriseVariant.allCases.enumerated()), id: \.element) { i, v in
                            Text("\(i + 1)  \(v.title)")
                                .fontWeight(v == player.variant ? .semibold : .regular)
                                .opacity(v == player.variant ? 1 : 0.6)
                                .sunriseButton(v.title) { player.play(v) }
                                .accessibilityAddTraits(v == player.variant ? .isSelected : [])
                        }
                        Text(player.muted ? "M  Sound off" : "M  Sound on")
                            .opacity(0.6)
                            .sunriseButton(player.muted ? "Sound off" : "Sound on") { player.muted.toggle() }
                        Text("R  Watch again").opacity(0.6).sunriseButton("Watch again") { player.play() }
                        Text("C  Close: \(player.closingStyle.title)").opacity(0.6)
                            .sunriseButton("Closing: \(player.closingStyle.title)") { player.cycleClosing() }
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: player.muted ? "speaker.slash" : "speaker.wave.2")
                        Text(player.muted ? "Sound off" : "Sound on")
                    }
                    .contentShape(Rectangle())
                    .opacity(0.8)
                    .sunriseButton(player.muted ? "Sound off" : "Sound on") { player.muted.toggle() }
                }
                Spacer()
                if player.canOnboardLater {
                    Text("Onboard later")
                        .contentShape(Rectangle())
                        .opacity(0.8)
                        .sunriseButton("Onboard later") { player.later() }
                        .padding(.trailing, 18)
                }
                HStack(spacing: 8) {
                    Text(player.windowed ? "Full screen" : "Use a window")
                    Text("⌃⌘F")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ink, lineWidth: 1))
                }
                .contentShape(Rectangle())
                .opacity(0.8)
                .sunriseButton(player.windowed ? "Full screen" : "Use a window") { player.toggleWindow() }
                .padding(.trailing, skip > 0 ? 18 : 0)
                if skip > 0 {
                HStack(spacing: 8) {
                    Text("Skip intro")
                    Text("esc")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(ink, lineWidth: 1))
                }
                .contentShape(Rectangle())
                .opacity(skip)
                .sunriseButton("Skip intro") { player.skip() }
                .sunriseControlsActive(skip > 0.5)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(ink)
            .padding(.horizontal, 28).padding(.bottom, 22)
        }
        .opacity(veil)
    }
}

final class TakeoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The first click on the sunrise counts even while ReArc is not yet the active
/// app (launched from Terminal, say): it activates the app and presses Begin.
final class TakeoverHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Act 0 over the whole screen: the desktop dims under the night sky, the menu
/// bar and Dock step aside, and everything comes back when it hands over.
@MainActor
public final class SunriseTakeover {
    public let player: SunrisePlayer
    private(set) var windowed: Bool
    var presented = false
    /// The browser has come in under the drawn window (Act 4).
    var revealed = false
    var window: NSWindow?
    var monitor: Any?
    var activation: NSObjectProtocol?

    let isPrototype: Bool

    public init(variant: SunriseVariant = .horizon, windowed: Bool = false, showsVariantPicker: Bool = false,
                host: OnboardingHost? = nil, mode: SunrisePlayer.Mode = .firstRun) {
        player = SunrisePlayer(variant: variant)
        player.host = host
        player.mode = mode
        isPrototype = showsVariantPicker
        player.replaysAfterLater = showsVariantPicker
        self.windowed = windowed
        player.windowed = windowed
        let window = TakeoverWindow(contentRect: Self.frame(windowed: windowed), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = windowed
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.contentView = TakeoverHostingView(rootView: SunriseLiveView(player: player, showsVariantPicker: showsVariantPicker))
        self.window = window
        player.onReveal = { [weak self] in self?.reveal() }
        player.onToggleWindow = { [weak self] in
            guard let self else { return }
            self.setWindowed(!self.windowed)
        }
    }

    /// The main screen: the one with the menu bar (System Settings › Displays),
    /// not whichever screen holds the key window. `NSScreen.main` is the latter,
    /// so launched from a window on another display the intro would open there.
    static var mainScreen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    /// The whole main screen, or a 16:10 window centred on it (1440 x 900 where
    /// that fits, else 85% of the space beside the menu bar and Dock).
    static func frame(windowed: Bool) -> NSRect {
        guard let screen = mainScreen else { return NSRect(x: 0, y: 0, width: 1440, height: 900) }
        guard windowed else { return screen.frame }
        let area = screen.visibleFrame
        let scale = min(1, area.width * 0.85 / 1440, area.height * 0.85 / 900)
        let size = NSSize(width: (1440 * scale).rounded(), height: (900 * scale).rounded())
        return NSRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// Full screen ⇄ a window centred on the main screen. The scene lays itself
    /// out for whatever size it is given, so the intro carries on where it was.
    public func setWindowed(_ on: Bool) {
        guard let window else { return }
        windowed = on
        player.windowed = on
        window.hasShadow = on
        if presented { NSApp.presentationOptions = on ? [] : [.hideDock, .hideMenuBar] }
        window.setFrame(Self.frame(windowed: on), display: true, animate: true)
        // Once the browser is in, it follows the drawn window to its new place.
        if revealed, let frame = revealFrame { player.host?.revealBrowser(in: frame, below: window) }
    }

    public func present(onFinished: @escaping () -> Void) {
        player.onFinished = { [weak self] in
            self?.dismiss()
            onFinished()
        }
        presented = true
        if !windowed { NSApp.presentationOptions = [.hideDock, .hideMenuBar] }
        // macOS only lets an app take the keyboard from the frontmost one when
        // it was launched to the front (Finder, the Dock, `open`); from a bare
        // `swift run` it asks and may be refused. The sunrise is on top either
        // way, and whenever ReArc becomes active it takes the keyboard back.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let window = self?.window, window.isVisible else { return }
                window.makeKeyAndOrderFront(nil)
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        player.play()
    }

    func handle(_ event: NSEvent) -> Bool {
        if player.closingStart != nil { return !event.modifierFlags.contains(.command) }
        // ⌃⌘F, the system's full-screen shortcut, works in every act.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains([.command, .control]), event.charactersIgnoringModifiers?.lowercased() == "f" {
            setWindowed(!windowed)
            return true
        }
        if event.modifierFlags.contains(.command) { return false }
        if player.act4 != nil { return false }
        if player.act3 != nil {
            // Return leaves the name field; with nothing selected it is Done.
            guard player.act3Ready, event.keyCode == 36 || event.keyCode == 76, player.selectedSpace == nil else { return false }
            player.spacesDone()
            return true
        }
        if player.act2 != nil {
            guard player.act2Ready, event.keyCode == 36 || event.keyCode == 76 else { return false }
            player.choose(true)
            return true
        }
        if player.act1 != nil {
            // Act 1's field owns typing; only the swatches take keys.
            guard player.choosing else { return false }
            switch event.keyCode {
            case 123: player.moveSwatch(-1)
            case 124: player.moveSwatch(1)
            case 36, 76, 49: player.pickKeyboardSwatch()
            default: return false
            }
            return true
        }
        switch event.keyCode {
        case 53: // esc
            if !player.isAtRest { player.skip() }
            return true
        case 36, 76: // return, enter
            if player.isAtRest { player.begin() } else { player.skip() }
            return true
        default: break
        }
        if !isPrototype {
            if event.charactersIgnoringModifiers?.lowercased() == "m" { player.muted.toggle(); return true }
            return false
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1": player.play(.horizon)
        case "2": player.play(.ember)
        case "3": player.play(.path)
        case "r": player.play()
        case "m": player.muted.toggle()
        case "c": player.cycleClosing()
        case "l": player.later()
        default: return false
        }
        return true
    }

    /// Where Act 4's drawn window sits, in screen coordinates.
    public var revealFrame: NSRect? {
        guard let window else { return nil }
        let r = Act4Layout(size: window.frame.size).window
        return NSRect(x: window.frame.minX + r.minX, y: window.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    func reveal() {
        guard let window, let frame = revealFrame else { return }
        revealed = true
        player.host?.revealBrowser(in: frame, below: window)
        // Keep the overlay on top of the window that just came in.
        window.orderFrontRegardless()
    }

    public func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let activation { NotificationCenter.default.removeObserver(activation) }
        activation = nil
        window?.orderOut(nil)
        presented = false
        NSApp.presentationOptions = []
    }
}
