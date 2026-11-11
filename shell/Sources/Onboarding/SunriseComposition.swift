import CoreGraphics
import Foundation

/// The notes the onboarding plays in: D major pentatonic, over Act 0's D6/9.
enum ScoreNotes {
    /// One note per profile colour, low to high like the swatches. A colour
    /// sounds like its note wherever it appears: your sky, your avatar, a space.
    static let colours = [293.66, 329.63, 369.99, 440.0, 493.88, 587.33, 659.25, 739.99]
    static let pentatonic = [587.33, 659.25, 739.99, 880.0, 987.77, 1174.66, 1318.51, 1479.98]
    static let high = [1174.66, 1318.51, 1479.98, 1760.0, 1975.53, 2349.32]

    /// The profile colour nearest to any colour (Arc's spaces bring their own).
    static func colourIndex(_ c: RGBA) -> Int {
        func d(_ a: RGBA) -> Double { pow(a.r - c.r, 2) + pow(a.g - c.g, 2) + pow(a.b - c.b, 2) }
        return ProfilePalette.colours.indices.min { d(ProfilePalette.colours[$0].rgba) < d(ProfilePalette.colours[$1].rgba) } ?? 0
    }

    static func note(_ c: RGBA) -> Double { colours[colourIndex(c)] }
}

/// How the score is composed: every animation on screen has a sound, and the
/// things that stay on screen stay in the sound. Your colour becomes a voice
/// from the moment you pick it; each space is a voice that follows its colour,
/// swells when chosen and flies into the switcher with it; anything that
/// travels (the mark lifting, the light flowing home, the sweep, the flight
/// into the window) is air moving across the room.
extension SunriseScore {
    /// Scenes are laid out on any screen; sounds are placed as if on 16:10.
    static let stage = CGSize(width: 1440, height: 900)

    public static func build(act1: Act1Log?, act2: Act2Log?, act3: Act3Log?, act4: Act4Log?) -> SunriseScore {
        var score = SunriseScore()
        let curtain = curtain(act1: act1, act2: act2, act3: act3, act4: act4)
        if let act1 { score.compose(act1, curtain: curtain) }
        if let act2 { score.compose(act2, act3Start: act3?.start, curtain: curtain) }
        if let act3 { score.compose(act3, act4: act4, curtain: curtain) }
        if let act4 { score.compose(act4) }
        score.composeYou(act1: act1, act2: act2, act4: act4, curtain: curtain)
        score.composeLevels(act2: act2, act3: act3, act4: act4)
        return score
    }

    /// When the last act so far hands over, and held voices let go; never
    /// while that act is still being played.
    static func curtain(act1: Act1Log?, act2: Act2Log?, act3: Act3Log?, act4: Act4Log?) -> Double {
        if let act4 { return act4.handOff }
        if let act3 { return act3.handOff ?? .infinity }
        if let act2 { return act2.handOff ?? .infinity }
        return act1?.handOff ?? .infinity
    }

    /// Up over `attack`, held, and let go at the curtain.
    static func held(from t: Double, attack: Double, level: Double, until curtain: Double) -> Curve {
        var points = [(t, 0.0), (t + attack, level)]
        if curtain.isFinite {
            let end = max(curtain, t + attack)
            points += [(end, level), (end + 1.5, 0)]
        }
        return Curve(points)
    }

    /// Sounds from a to b (held on if b has not happened yet).
    static func span(_ a: Double, _ b: Double, attack: Double, release: Double, level: Double) -> Curve {
        guard b.isFinite else { return Curve([(a, 0), (a + attack, level)]) }
        let reached = level * min(1, max(0, b - a) / attack)
        return Curve([(a, 0), (min(a + attack, b), reached), (b, reached), (b + release, 0)])
    }

    static func swatchPan(_ i: Int) -> Double { (Double(i) - 3.5) / 3.5 * 0.35 }
    static func arcPan(_ angle: Double) -> Double { 0.75 * cos(angle * .pi / 180) }

    // MARK: Act 1, "You"

    mutating func compose(_ a: Act1Log, curtain: Double) {
        let s = a.start
        hits.append(Hit(s, 587.33, 0.035))
        // The mark lifts out of the way; the question; the field.
        airs.append(Air(id: 10, s, s + 1.4, cutoff: 300 ... 1500, gain: 0.022))
        hits.append(Hit(s + 1.05, 440, 0.014, pan: -0.1))
        hits.append(Hit(s + 1.7, 1174.66, 0.008, pan: 0.1, .glass))
        var length = 0
        for e in a.edits {
            let n = e.text.count
            if n > length {
                hits.append(Hit(e.time, ScoreNotes.pentatonic[max(0, n - 1) % 6], 0.022, pan: Double(n % 5) * 0.2 - 0.4, .pluck))
            } else if n < length {
                hits.append(Hit(e.time, 392, 0.01, .glass))
            }
            length = n
        }
        guard let submit = a.submitted?.time else { return }
        for (k, f) in [880.0, 1174.66, 1479.98].enumerated() {
            hits.append(Hit(submit + Double(k) * 0.09, f, 0.035, pan: Double(k) * 0.3 - 0.3))
        }
        // Your name joins the chord: a voice of its own, and the arpeggio.
        arpStart = submit + 0.6
        for (f, g, pan) in [(246.94, 0.011, -0.2), (587.33, 0.006, 0.2)] {
            tones.append(Tone(pitch: Pitch(constant: f), gain: Self.held(from: submit + 0.4, attack: 1.6, level: g, until: curtain),
                              pan: Curve(constant: pan), bright: Curve(constant: 0.2)))
        }
        hits.append(Hit(submit + 2.65, 659.25, 0.013, pan: 0.1))
        // The swatches rise one by one, each on its colour's note.
        let swatches = submit + Act1Timeline.swatchesIn
        for i in ProfilePalette.colours.indices {
            hits.append(Hit(swatches + Double(i) * 0.07 + 0.05, ScoreNotes.colours[i] * 2, 0.011, pan: Self.swatchPan(i), .glass))
        }
        // The sky follows the pointer, and so does the sound: each colour hums its note.
        let pick = a.picked?.time ?? .infinity
        var pointer = a.hovers.filter { $0.time < pick }
        if let p = a.picked { pointer.append((p.time, nil)) }
        for (k, h) in pointer.enumerated() {
            guard let i = h.index else { continue }
            hits.append(Hit(h.time, ScoreNotes.colours[i] * 2, 0.014, pan: Self.swatchPan(i), .glass))
            let end = k + 1 < pointer.count ? pointer[k + 1].time : .infinity
            tones.append(Tone(pitch: Pitch(constant: ScoreNotes.colours[i]),
                              gain: Self.span(h.time, end, attack: 0.35, release: 0.6, level: 0.012),
                              pan: Curve(constant: Self.swatchPan(i) * 0.5), bright: Curve(constant: 0.45)))
        }
        guard let p = a.picked else { return }
        for (k, f) in [587.33, 880.0, 1479.98, ScoreNotes.colours[p.index] * 2].enumerated() {
            hits.append(Hit(p.time + Double(k) * 0.07, f, 0.04, pan: Double(k) * 0.25 - 0.4))
        }
        // The swatch swirls into your avatar; a low bloom under it.
        airs.append(Air(id: 11, p.time, p.time + 1.0, cutoff: 500 ... 2200, opens: false, gain: 0.02, pan: (Self.swatchPan(p.index), 0)))
        tones.append(Tone(pitch: Pitch(constant: 146.83), gain: Curve([(p.time, 0), (p.time + 0.8, 0.022), (p.time + 2.6, 0)]),
                          bright: Curve(constant: 0.1)))
        hits.append(Hit(p.time + 0.75, 880, 0.012, pan: 0.1))
        // "That's you, Kai." on your note; then the line under it.
        hits.append(Hit(p.time + 0.95, ScoreNotes.colours[p.index], 0.018, .pluck))
        hits.append(Hit(p.time + 1.5, 1174.66, 0.006, .glass))
    }

    // MARK: Act 2, "Where you've been"

    mutating func compose(_ a: Act2Log, act3Start: Double?, curtain: Double) {
        let L = Act2Layout(size: Self.stage)
        let s = a.start, n = a.nodeCount
        let nodePan = { (i: Int) in Self.arcPan(L.nodeAngle(i, of: n)) }
        let nodeNote = { (i: Int) in ScoreNotes.colours[(i * 3) % ScoreNotes.colours.count] }
        let c = a.choice?.time ?? .infinity
        let done = a.done ?? .infinity
        // A browser allowed in System Settings arrives on its own note.
        for (i, t) in a.arrivals { hits.append(Hit(t + 0.15, nodeNote(i), 0.016, .pluck)) }

        // Your avatar walks to the apex; the trail draws in from the past, on the left.
        airs.append(Air(id: 20, s, s + 1.2, cutoff: 500 ... 1300, gain: 0.018))
        airs.append(Air(id: 21, s + 0.6, s + 2.0, cutoff: 400 ... 2400, gain: 0.026, pan: (-0.85, 0)))
        // The past: low, on the navy side, until the trail fades.
        let pastEnd = done.isFinite ? done + 0.8 : curtain
        for (f, g) in [(82.41, 0.03), (123.47, 0.018)] {
            tones.append(Tone(pitch: Pitch(constant: f), gain: Self.span(s + 0.6, pastEnd, attack: 1.4, release: 1.2, level: g),
                              pan: Curve(constant: -0.45), bright: Curve(constant: 0.15)))
        }
        hits.append(Hit(s + 1.25, 587.33, 0.014))
        // Each browser takes its place on the trail with a note of its own.
        for i in 0 ..< n {
            hits.append(Hit(s + 2.05 + Double(i) * 0.14, nodeNote(i), 0.02, pan: nodePan(i), .pluck))
        }
        for k in a.offered.indices {
            hits.append(Hit(s + 2.65 + Double(k) * 0.05, ScoreNotes.high[k % 6], 0.006,
                            pan: (Double(k) - Double(a.offered.count - 1) / 2) * 0.15, .glass))
        }
        hits += [Hit(s + 3.0, 587.33, 0.01, .pluck), Hit(s + 3.08, 880, 0.008, .pluck)]
        // Leaving one behind falls; taking it again rises.
        for e in a.toggles where e.time <= c {
            let on = a.isOn(source: e.index, at: e.time), f = nodeNote(e.index)
            hits.append(Hit(e.time, on ? f * 2 : f, 0.018, pan: nodePan(e.index), .pluck))
            hits.append(Hit(e.time + 0.08, on ? f * 3 : f / 2, 0.01, pan: nodePan(e.index), .pluck))
        }
        for e in a.categories where e.time <= c {
            hits.append(Hit(e.time, a.isOn(e.category, at: e.time) ? 1318.51 : 987.77, 0.012, pan: 0.1, .glass))
        }
        guard a.choice != nil else { return }

        if a.bringing, let flowStart = a.flowStart {
            hits += [Hit(c, 293.66, 0.04), Hit(c + 0.12, 440, 0.03, pan: 0.2)]
            // The light flows home: the swell, the stream along the arc, a grain
            // for every point of light leaving its browser, a bell as they arrive.
            airs.append(Air(id: 22, c + 0.3, c + 0.3 + Act2Timeline.flow, cutoff: 180 ... 2780, gain: 0.05))
            airs.append(Air(id: 23, flowStart, flowStart + Act2Timeline.flow, cutoff: 500 ... 3400, gain: 0.03, pan: (-0.5, 0)))
            for i in a.sources.indices where a.isOn(source: i, at: c) {
                for j in 0 ..< Act2Timeline.particlesPerSource {
                    hits.append(Hit(Act2Timeline.emission(i, j, flowStart), ScoreNotes.high[(i * 3 + j) % 6], 0.0045,
                                    pan: nodePan(i) * 0.9, .glass))
                }
            }
            for (time, k) in Act2Timeline.arrivalTimes(a) {
                hits.append(Hit(time, ScoreNotes.pentatonic[k % 8] * 2, 0.01, pan: Double(k % 5) * 0.07 - 0.14))
            }
            for (k, f) in [146.83, 220.0, 293.66, 369.99, 440.0, 587.33, 880.0].enumerated() {
                hits.append(Hit(done + Double(k) * 0.06, f, k < 3 ? 0.07 : 0.04, pan: Double(k) * 0.2 - 0.6))
            }
            for i in a.sources.indices where a.isOn(source: i, at: c) {
                hits.append(Hit(done + 0.15 + Double(i) * 0.06, nodeNote(i) * 2, 0.008, pan: nodePan(i), .glass))
            }
        } else {
            for (k, f) in [293.66, 440.0, 587.33].enumerated() {
                hits.append(Hit(done + Double(k) * 0.12, f, 0.035, pan: Double(k) * 0.3 - 0.3))
            }
            for i in 0 ..< n { hits.append(Hit(c + 0.1 + Double(i) * 0.06, nodeNote(i), 0.008, pan: nodePan(i), .glass)) }
        }
        // The blue sweeps ahead, to the right: where you're going, a brighter voice.
        airs.append(Air(id: 24, done + 1.4, done + 2.8, cutoff: 800 ... 3600, gain: 0.035, pan: (0, 0.75)))
        hits.append(Hit(done + 2.6, 1318.51, 0.03, pan: 0.6))
        let futureEnd = act3Start.map { $0 + 3 } ?? curtain
        for (f, g) in [(493.88, 0.009), (739.99, 0.005)] {
            tones.append(Tone(pitch: Pitch(constant: f), gain: Self.span(done + 1.6, futureEnd, attack: 1.5, release: 2.0, level: g),
                              pan: Curve(constant: 0.45), bright: Curve(constant: 0.5)))
        }
        hits.append(Hit(done + 3.3, 659.25, 0.012, pan: 0.2))
    }

    // MARK: Act 3, "Where you're going"

    mutating func compose(_ a: Act3Log, act4: Act4Log?, curtain: Double) {
        let s = a.start
        let done = a.doneTime
        hits.append(Hit(s + 0.6, 587.33, 0.014))
        hits.append(Hit(s + 1.7, 1479.98, 0.008, pan: 0.55, .glass))
        hits.append(Hit(s + 1.9, 1174.66, 0.007, .glass))

        // The scene drives the voices: sampled as drawn, so each one swells
        // exactly as its node is chosen, moves as the arc re-lays, fades as it goes.
        let all = a.state(at: .infinity).spaces
        let lastEvent = min(a.events.last?.time ?? s, done ?? .infinity)
        let sampleEnd = max(s + Act3Timeline.ready + 0.5,
                            done.map { $0 + 0.4 + Double(all.count) * 0.12 + 0.8 } ?? lastEvent + 1.0)
        let rate = 15.0
        let times = Array(stride(from: s, through: sampleEnd, by: 1 / rate))
        let frames = times.map { Act3Timeline.frame(a, $0) }
        func pan(_ id: Int, at t: Double) -> Double {
            let k = min(max(Int(((t - s) * rate).rounded()), 0), frames.count - 1)
            return Self.arcPan(frames[k].spaces.first { $0.id == id }?.angle ?? Act3Timeline.span.upperBound)
        }
        func seedColour(_ id: Int) -> RGBA {
            id < a.seeds.count ? a.seeds[id].colour : ProfilePalette.colours[id % ProfilePalette.colours.count].rgba
        }
        let level = 0.026 / sqrt(Double(max(1, a.seeds.count)))
        let flight = act4.map { $0.start + Act4Timeline.flight }
        let visibleAtEnd = act4.map { _ in all.filter { $0.removed == nil }.map(\.id) } ?? []

        for sp in all {
            // Its note follows its colour, gliding as the colour fades.
            var note = ScoreNotes.note(seedColour(sp.id)) / 2
            var pitch = [(sp.added, note)]
            for (time, event) in a.events where time <= (done ?? .infinity) {
                guard case let .colour(id, c) = event, id == sp.id else { continue }
                let next = ScoreNotes.colours[c] / 2
                pitch += [(time, note), (time + 0.4, next)]
                note = next
            }
            var gain: [(Double, Double)] = [], panPoints: [(Double, Double)] = [], bright: [(Double, Double)] = []
            for (k, f) in frames.enumerated() {
                guard let node = f.spaces.first(where: { $0.id == sp.id }) else { continue }
                gain.append((times[k], level * node.appear * (1 + 1.4 * node.selected) * (1 + 1.6 * node.pulse)))
                panPoints.append((times[k], Self.arcPan(node.angle)))
                bright.append((times[k], 0.25 + 0.75 * node.selected))
            }
            guard !gain.isEmpty else { continue }
            if sp.removed == nil {
                if let flight, let i = visibleAtEnd.firstIndex(of: sp.id) {
                    // Into the switcher with its node, then quieter: it has landed.
                    let leave = flight + 0.25 + Double(i) * 0.05, land = flight + 1.35 + Double(i) * 0.05
                    panPoints += [(leave, panPoints.last!.1), (land, -0.85 + Double(i) * 0.02)]
                    gain += [(land, level), (land + 1.0, level * 0.75)]
                }
                if curtain.isFinite { gain += [(curtain, gain.last!.1), (curtain + 1.5, 0)] }
            }
            tones.append(Tone(pitch: Pitch(pitch), gain: Curve(gain), pan: Curve(panPoints), bright: Curve(bright)))
            // It arrives on the arc with its note.
            hits.append(Hit(sp.added + 0.05, ScoreNotes.note(seedColour(sp.id)), 0.018, pan: pan(sp.id, at: sp.added + 0.3), .pluck))
        }

        var names: [Int: Int] = [:]
        for (k, (time, event)) in a.events.enumerated() where time <= (done ?? .infinity) {
            switch event {
            case let .select(id?):
                let colour = a.state(at: time).spaces.first { $0.id == id }?.colour ?? MarkPalette.sun
                hits.append(Hit(time, ScoreNotes.note(colour) * 2, 0.024, pan: pan(id, at: time)))
            case .select(nil):
                hits.append(Hit(time, 440, 0.008, .glass))
            case let .rename(id, name):
                let before = names[id] ?? (id < a.seeds.count ? a.seeds[id].name.count : 0)
                if name.count > before {
                    hits.append(Hit(time, ScoreNotes.pentatonic[max(0, name.count - 1) % 6], 0.014, pan: 0, .pluck))
                } else if name.count < before {
                    hits.append(Hit(time, 392, 0.008, .glass))
                }
                names[id] = name.count
            case let .colour(id, c):
                hits.append(Hit(time, ScoreNotes.colours[c], 0.022, pan: pan(id, at: time), .pluck))
                hits.append(Hit(time + 0.06, ScoreNotes.colours[c] * 2, 0.01, pan: pan(id, at: time), .glass))
            case let .icon(id, _):
                hits.append(Hit(time, 2349.32, 0.012, pan: pan(id, at: time), .glass))
                hits.append(Hit(time + 0.07, 1975.53, 0.01, pan: pan(id, at: time), .glass))
            case .add:
                hits += [Hit(time, 739.99, 0.022, pan: 0.4, .pluck), Hit(time + 0.1, 1108.73, 0.02, pan: 0.5, .pluck)]
                airs.append(Air(id: 300 + k, time, time + 0.6, cutoff: 1500 ... 4200, gain: 0.014, pan: (0.45, 0.55)))
            case .remove:
                hits += [Hit(time, 880, 0.02, pan: 0.4, .pluck), Hit(time + 0.1, 587.33, 0.02, pan: 0.3, .pluck)]
                airs.append(Air(id: 300 + k, time, time + 0.6, cutoff: 1500 ... 4200, opens: false, gain: 0.014, pan: (0.55, 0.45)))
            case .done:
                // Each space rings its own note as it pulses, then the chord.
                let kept = a.state(at: time).spaces.filter { $0.removed == nil }
                for (i, sp) in kept.enumerated() {
                    let t = time + 0.4 + Double(i) * 0.12
                    hits.append(Hit(t, ScoreNotes.note(sp.colour) * 2, 0.022, pan: pan(sp.id, at: t), .pluck))
                }
                for f in [146.83, 220.0, 293.66, 369.99, 554.37] {
                    hits.append(Hit(time + 0.5 + Double(kept.count) * 0.12, f, 0.045))
                }
            default: break
            }
        }
    }

    // MARK: Act 4, "Morning"

    mutating func compose(_ a: Act4Log) {
        let s = a.start, f = s + Act4Timeline.flight
        // A breath in as the spaces clear for the motto.
        airs.append(Air(id: 42, s - 0.4, s + 0.7, cutoff: 400 ... 1600, gain: 0.018))
        // ReFocused. ReStored. ReArc. The last word lands on the chord.
        for (i, d) in [0.6, 1.15, 1.7].enumerated() {
            hits.append(Hit(s + d, [587.33, 739.99, 880.0][i], 0.045, pan: Double(i) * 0.3 - 0.3))
        }
        for f0 in [73.42, 110.0, 146.83, 220.0, 293.66, 369.99, 440.0, 1174.66] {
            hits.append(Hit(s + 1.72, f0, f0 < 150 ? 0.09 : 0.04))
        }
        // The mark shrinks into the first tab: it rises as it goes, and lands with a tink.
        airs.append(Air(id: 40, f - 0.1, f + 1.3, cutoff: 700 ... 2600, opens: false, gain: 0.03, pan: (0, -0.7)))
        tones.append(Tone(pitch: Pitch([(f, 880), (f + 1.3, 1760)]), gain: Curve([(f, 0), (f + 0.5, 0.008), (f + 1.3, 0)]),
                          pan: Curve([(f, 0), (f + 1.3, -0.7)]), bright: Curve(constant: 0.2)))
        hits += [Hit(f + 1.3, 1760, 0.02, pan: -0.7, .glass), Hit(f + 1.42, 2349.32, 0.014, pan: -0.7, .glass)]
        // The window forms: a floor under everything, and the room opening out.
        tones.append(Tone(pitch: Pitch(constant: 73.42), gain: Curve([(f, 0), (f + 0.6, 0.05), (f + 3.0, 0)]),
                          bright: Curve(constant: 0.1)))
        airs.append(Air(id: 41, f, f + 1.2, cutoff: 300 ... 1800, gain: 0.03))
        // Your avatar and spaces land in the switcher, each on its note.
        hits.append(Hit(f + 1.25, ScoreNotes.note(a.colour), 0.022, pan: -0.88, .pluck))
        for (i, node) in a.nodes.enumerated() {
            hits.append(Hit(f + 1.35 + Double(i) * 0.05, ScoreNotes.note(node.colour), 0.018, pan: -0.85 + Double(i) * 0.02, .pluck))
        }
        // The chrome, the page, the tips; then home.
        hits += [Hit(f + 0.85, 1174.66, 0.007, pan: -0.6, .glass), Hit(f + 0.93, 1479.98, 0.006, pan: -0.55, .glass)]
        hits.append(Hit(f + 1.15, 587.33, 0.016, pan: 0.2))
        for (k, f0) in [880.0, 987.77, 1174.66, 1318.51].enumerated() {
            hits.append(Hit(f + 1.85 + Double(k) * 0.09, f0, 0.008, pan: 0.25, .glass))
        }
        for (k, f0) in [293.66, 369.99, 440.0, 587.33].enumerated() {
            hits.append(Hit(f + 2.1 + Double(k) * 0.05, f0, 0.018, pan: Double(k) * 0.1 - 0.15))
        }
        // Home: a slow chord under the finished window, the motto's three notes
        // once more, softly and falling, and a last bell as the scene lets go.
        for (f0, g) in [(146.83, 0.012), (220.0, 0.008), (369.99, 0.006)] {
            tones.append(Tone(pitch: Pitch(constant: f0), gain: Self.held(from: f + 3.0, attack: 1.5, level: g, until: a.handOff),
                              bright: Curve(constant: 0.3)))
        }
        for (k, f0) in [880.0, 739.99, 587.33].enumerated() {
            hits.append(Hit(f + 4.4 + Double(k) * 0.22, f0, 0.012, pan: 0.3 - Double(k) * 0.3))
        }
        hits += [Hit(a.handOff - 0.2, 1174.66, 0.012), Hit(a.handOff - 0.12, 2349.32, 0.005, .glass)]
    }

    // MARK: Across the acts

    /// Your colour, from the pick to the end: it brightens as the light comes
    /// home to you, and travels with your avatar into the switcher.
    mutating func composeYou(act1: Act1Log?, act2: Act2Log?, act4: Act4Log?, curtain: Double) {
        guard let p = act1?.picked else { return }
        var gain = [(p.time, 0.0), (p.time + 1.0, 0.013)]
        if let a2 = act2, a2.bringing, let flowStart = a2.flowStart, let done = a2.done {
            gain += [(flowStart, 0.013), (done, 0.024), (done + 2.0, 0.013)]
        }
        if curtain.isFinite { gain += [(curtain, 0.013), (curtain + 1.5, 0)] }
        var pan = [(p.time, 0.0)]
        if let a4 = act4 {
            let f = a4.start + Act4Timeline.flight
            pan += [(f + 0.15, 0), (f + 1.25, -0.88)]
        }
        tones.append(Tone(pitch: Pitch(constant: ScoreNotes.colours[p.index]), gain: Curve(gain), pan: Curve(pan),
                          bright: Curve(constant: 0.45)))
    }

    /// Act 0's chord and the arpeggio step back for what each act brings, and
    /// come forward again for the motto.
    mutating func composeLevels(act2: Act2Log?, act3: Act3Log?, act4: Act4Log?) {
        var pad = [(0.0, 1.0)], arp = [(0.0, 1.0)]
        if let a2 = act2 {
            pad += [(a2.start, 1), (a2.start + 2, 0.8)]
            if let flowStart = a2.flowStart, let done = a2.done {
                arp += [(flowStart - 0.2, 1), (flowStart + 0.8, 0.55), (done, 0.55), (done + 1.5, 0.8)]
            }
        }
        if let a3 = act3 {
            pad += [(a3.start, 0.8), (a3.start + 1.5, 0.7)]
            arp += [(a3.start, 0.8), (a3.start + 1.5, 0.55)]
        }
        if let a4 = act4 {
            pad += [(a4.start + 1.6, 0.7), (a4.start + 1.8, 1.0)]
            arp += [(a4.start + 1.6, 0.55), (a4.start + 1.8, 0.9)]
        }
        padLevel = Curve(pad)
        arpLevel = Curve(arp)
    }
}
