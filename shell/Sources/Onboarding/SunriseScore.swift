import AVFoundation
import Foundation
import os

/// A value over time: straight lines between points, held before the first
/// and after the last. Two points at one time make a step.
public struct Curve: Sendable, Equatable {
    var t: [Double] = []
    var v: [Double] = []

    public init(_ points: [(Double, Double)] = []) {
        let sorted = points.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element)
        t = sorted.map(\.0); v = sorted.map(\.1)
    }

    public init(constant: Double) { t = [0]; v = [constant] }

    public var isEmpty: Bool { t.isEmpty }
    public var first: Double? { t.first }
    public var last: (time: Double, value: Double)? { t.last.map { ($0, v[v.count - 1]) } }

    /// Index of the last point at or before x (x within the curve's span).
    func segment(_ x: Double) -> Int {
        var lo = 0, hi = t.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if t[mid] <= x { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func callAsFunction(_ x: Double) -> Double {
        guard let t0 = t.first else { return 0 }
        if x <= t0 { return v[0] }
        if x >= t[t.count - 1] { return v[v.count - 1] }
        let k = segment(x)
        let span = t[k + 1] - t[k]
        return span > 0 ? v[k] + (v[k + 1] - v[k]) * (x - t[k]) / span : v[k + 1]
    }
}

/// A pitch that can glide: straight lines in Hz between points. Its phase is
/// counted from time zero, so two voices on one note are always in phase and
/// a voice that is re-scored mid-note never clicks.
public struct Pitch: Sendable, Equatable {
    let t: [Double]
    let f: [Double]
    /// Cycles completed at each point.
    let cum: [Double]

    public init(_ points: [(Double, Double)]) {
        let sorted = points.sorted { $0.0 < $1.0 }
        let t = sorted.map(\.0), f = sorted.map(\.1)
        var cum = [t.isEmpty ? 0 : f[0] * t[0]]
        for k in 1 ..< max(1, t.count) {
            cum.append(cum[k - 1] + (f[k - 1] + f[k]) / 2 * (t[k] - t[k - 1]))
        }
        self.t = t; self.f = f; self.cum = cum
    }

    public init(constant hz: Double) { self.init([(0, hz)]) }

    public func hz(_ x: Double) -> Double { Curve(zip(t, f).map { ($0, $1) })(x) }

    public func cycles(_ x: Double) -> Double {
        guard let t0 = t.first else { return 0 }
        if x <= t0 { return f[0] * x }
        let n = t.count - 1
        var lo = 0, hi = n
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if t[mid] <= x { lo = mid } else { hi = mid - 1 }
        }
        let k = lo, dt = x - t[k]
        if k == n { return cum[k] + f[k] * dt }
        let slope = (f[k + 1] - f[k]) / (t[k + 1] - t[k])
        return cum[k] + f[k] * dt + 0.5 * slope * dt * dt
    }
}

/// Everything the onboarding sounds like after Begin, as a pure function of
/// time: struck sounds, held voices and moving air. `SunriseScore.build`
/// makes one from the act logs, so a live run and an offline render of the
/// same log sound the same, and a sound scheduled ahead is never lost.
public struct SunriseScore: Sendable {
    /// A struck sound.
    public struct Hit: Sendable, Equatable {
        public enum Timbre: Sendable { case bell, pluck, glass }
        public var time: Double
        public var freq: Double
        public var gain: Double
        public var pan: Double
        public var timbre: Timbre

        public init(_ time: Double, _ freq: Double, _ gain: Double, pan: Double = 0, _ timbre: Timbre = .bell) {
            self.time = time; self.freq = freq; self.gain = gain; self.pan = pan; self.timbre = timbre
        }

        var length: Double {
            switch timbre {
            case .bell: 5
            case .pluck: 3
            case .glass: 1.2
            }
        }

        /// Partials: (ratio, amplitude, decay in seconds).
        var partials: [(Double, Double, Double)] {
            switch timbre {
            case .bell: [(1.0, 1.0, 2.6), (2.756, 0.45, 1.3), (5.404, 0.2, 0.6), (8.933, 0.08, 0.3)]
            case .pluck: [(1.0, 1.0, 0.9), (2.0, 0.5, 0.45), (3.0, 0.25, 0.25), (4.0, 0.12, 0.15)]
            case .glass: [(1.0, 1.0, 0.35), (2.76, 0.3, 0.15)]
            }
        }
    }

    /// A held voice whose loudness, place, brightness and note follow the scene.
    public struct Tone: Sendable, Equatable {
        public var pitch: Pitch
        public var gain: Curve
        public var pan: Curve
        public var bright: Curve

        public init(pitch: Pitch, gain: Curve, pan: Curve = Curve(constant: 0), bright: Curve = Curve(constant: 0.3)) {
            self.pitch = pitch; self.gain = gain; self.pan = pan; self.bright = bright
        }

        /// When it is silent for good (nil while it holds).
        var end: Double? { gain.last.flatMap { $0.value <= 0 ? $0.time : nil } }
        var start: Double { gain.first ?? 0 }
        /// The same note always starts from the same phase.
        var seed: Double { (pitch.f.first ?? 0) * 0.618_034 }
    }

    /// Filtered noise that sweeps open and moves across the stereo field:
    /// something travelling.
    public struct Air: Sendable, Equatable {
        public var id: Int
        public var start: Double
        public var end: Double
        public var cutoff: ClosedRange<Double>
        /// False sweeps the filter closed instead of open.
        public var opens = true
        public var gain: Double
        public var pan: (from: Double, to: Double)

        public init(id: Int, _ start: Double, _ end: Double, cutoff: ClosedRange<Double>, opens: Bool = true, gain: Double, pan: (Double, Double) = (0, 0)) {
            self.id = id; self.start = start; self.end = end; self.cutoff = cutoff; self.opens = opens; self.gain = gain; self.pan = pan
        }

        public static func == (a: Air, b: Air) -> Bool {
            a.id == b.id && a.start == b.start && a.end == b.end && a.cutoff == b.cutoff && a.opens == b.opens
                && a.gain == b.gain && a.pan.from == b.pan.from && a.pan.to == b.pan.to
        }
    }

    public var hits: [Hit] = []
    public var tones: [Tone] = []
    public var airs: [Air] = []
    /// The slow arpeggio that joins after your name.
    public var arpStart: Double?
    public var arpLevel = Curve(constant: 1)
    /// Act 0's chord makes room for what each act adds.
    public var padLevel = Curve(constant: 1)

    public init() {}
}

/// The Act 0 score, synthesised: a D drone, a pad whose notes arrive with the
/// light (Dadd9 opening into D6/9), a two-note chime when the mark forms, and
/// per-variant touches (heartbeats for Ember, a noise swell, star sparkles).
/// Everything after Begin comes from a `SunriseScore` laid on top of it.
/// Stateful only for the noise filters, so render it in order.
public final class SunriseSynth {
    public let sampleRate: Double
    public let variant: SunriseVariant
    public let reduced: Bool
    let cues: SunriseCues
    struct Note { let freq, start, attack, gain: Double }
    // Constant tables, hoisted out of the per-sample loop: an array literal there
    // is a heap allocation per sample in debug builds, which starves the audio thread.
    static let padVoices: [(Double, Double, Double)] = [(-1.0, 1.0, 0.45), (0.0, 0.8, 0.8), (1.0, 0.45, 1.0)]
    static let toneVoices: [(Double, Double, Double)] = [(-1.0, 1.0, 0.55), (1.0, 0.55, 1.0)]
    static let arpNotes = [440.0, 587.33, 739.99, 880.0, 739.99, 587.33]
    static let beats: [(Double, Double)] = [(0.0, 0.5), (0.28, 0.3)]
    let notes: [Note]
    let chimes: [SunriseScore.Hit]
    var sample: Int64 = 0
    /// 1 while playing; Begin fades it to 0.
    public var fadeOutStart: Double?
    /// Seconds the fade takes; a closing sets its own.
    public var fadeOutLength = 1.8
    /// The score after Begin, and how far the audio clock runs ahead of scene time.
    struct Current { var score = SunriseScore(); var offset = 0.0 }
    let current = OSAllocatedUnfairLock(initialState: Current())
    var noiseState: UInt64 = 0x9E37_79B9_7F4A_7C15
    /// Each air's filter memory, by id (render thread only).
    var airState: [Int: (Double, Double)] = [:]

    public init(variant: SunriseVariant, reduced: Bool = false, sampleRate: Double = 48_000) {
        self.variant = variant
        self.reduced = reduced
        self.sampleRate = sampleRate
        let cues = reduced ? SunriseCues.reduced : SunriseCues.of(variant)
        self.cues = cues
        let c = cues.chime
        // D2 A2 | D3 F#3 A3 | E4 F#4 A4 | C#5 (the light's last colour)
        let scale = reduced ? 0.3 : 1.0
        notes = [
            Note(freq: 73.42, start: 0.2, attack: 3.0 * scale, gain: 0.09),
            Note(freq: 110.0, start: 0.6, attack: 3.0 * scale, gain: 0.06),
            Note(freq: 146.83, start: c * 0.22, attack: 2.5 * scale, gain: 0.05),
            Note(freq: 185.0, start: c * 0.45, attack: 2.5 * scale, gain: 0.04),
            Note(freq: 220.0, start: c * 0.62, attack: 2.0 * scale, gain: 0.035),
            Note(freq: 329.63, start: c * 0.85, attack: 2.0 * scale, gain: 0.03),
            Note(freq: 369.99, start: c, attack: 1.6 * scale, gain: 0.024),
            Note(freq: 440.0, start: c + 0.3, attack: 2.0 * scale, gain: 0.02),
            Note(freq: 554.37, start: cues.voice - 0.2, attack: 2.4 * scale, gain: 0.014),
        ]
        var chimes = [SunriseScore.Hit(c, 880.0, 0.07, pan: -0.25), SunriseScore.Hit(c + 0.21, 1318.5, 0.05, pan: 0.3)]
        if cues.sparkles {
            // Stars, early and quiet, on a D major pentatonic.
            let pent = [1174.66, 1318.51, 1479.98, 1760.0, 1975.53, 2349.32]
            var s: UInt64 = 7
            for i in 0 ..< 14 {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let r = Double(s >> 11) / Double(1 << 53)
                chimes.append(SunriseScore.Hit(1.0 + Double(i) * 0.38 + r * 0.2, pent[Int(r * 6) % 6], 0.012 + 0.01 * r, pan: r * 1.6 - 0.8))
            }
        }
        self.chimes = chimes
    }

    /// Lays a new score over Act 0. `sceneTime` is the scene clock now (live
    /// runs); the audio clock is re-aligned to it only if they drift apart.
    public func setScore(_ score: SunriseScore, sceneTime: Double? = nil) {
        let now = time
        current.withLock { c in
            if let sceneTime, abs((now - sceneTime) - c.offset) > 0.05 { c.offset = now - sceneTime }
            c.score = score
        }
    }

    public var score: SunriseScore { current.withLock { $0.score } }
    public var time: Double { Double(sample) / sampleRate }
    public func seek(to t: Double) { sample = Int64(t * sampleRate) }
    public func fadeOut(over length: Double = 1.8) {
        guard fadeOutStart == nil else { return }
        fadeOutLength = length
        fadeOutStart = time
    }

    func noise() -> Double {
        noiseState ^= noiseState << 13; noiseState ^= noiseState >> 7; noiseState ^= noiseState << 17
        return Double(noiseState >> 11) / Double(1 << 52) - 1
    }

    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let twoPi = 2 * Double.pi
        let (score, offset) = current.withLock { ($0.score, $0.offset) }
        // Scene time for this buffer; only what sounds in it is looked at.
        let s0 = time - offset, s1 = s0 + Double(frames) / sampleRate
        let hits = (chimes + score.hits).filter { $0.time <= s1 && $0.time + $0.length >= s0 }
        let hitPartials = hits.map(\.partials)
        let tones = score.tones.filter { $0.start <= s1 && ($0.end ?? .infinity) >= s0 }
        let airs = (cues.riser.map { [SunriseScore.Air(id: -1, $0.lowerBound, $0.upperBound + 1.2, cutoff: 180 ... 2780, gain: 0.05)] } ?? [])
            + score.airs.filter { $0.start <= s1 && $0.end >= s0 }
        var airMemory = airs.map { airState[$0.id] ?? (0, 0) }
        // After your name: a slow arpeggio joins the chord.
        let arpNotes = Self.arpNotes, padVoices = Self.padVoices, toneVoices = Self.toneVoices, beats = Self.beats
        for i in 0 ..< frames {
            let t = Double(sample) / sampleRate - offset
            sample += 1
            let bright = SunriseTimeline.dawn(variant, t, reduced: reduced)
            var l = 0.0, r = 0.0

            let pad = score.padLevel(t)
            for (k, n) in notes.enumerated() where t > n.start {
                let env = Ease.smooth((t - n.start) / n.attack) * (0.86 + 0.14 * sin(twoPi * 0.09 * t + Double(k)))
                let g = env * n.gain * pad
                for (d, wl, wr) in padVoices {
                    let ph = twoPi * n.freq * (1 + d * 0.0023) * t + Double(k) * 1.7 + d
                    var v = sin(ph)
                    if bright > 0.05 { v += bright * (0.22 * sin(2 * ph) + 0.07 * sin(3 * ph)) }
                    l += g * wl * v; r += g * wr * v
                }
            }

            if let a = score.arpStart, t >= a {
                let step = 0.26, k = Int((t - a) / step)
                let swell = Ease.smooth((t - a) / 3) * score.arpLevel(t)
                for j in max(0, k - 3) ... k {
                    let dt = t - a - Double(j) * step
                    let f = arpNotes[j % arpNotes.count]
                    let v = 0.016 * swell * exp(-dt / 0.8) * min(1, dt / 0.006) * (sin(twoPi * f * dt) + 0.3 * sin(twoPi * 2 * f * dt))
                    let pan = j % 2 == 0 ? -0.35 : 0.35
                    l += v * (1 - pan); r += v * (1 + pan)
                }
            }

            for tone in tones {
                let g = tone.gain(t)
                guard g > 1e-5 else { continue }
                let cyc = tone.pitch.cycles(t)
                let b = tone.bright(t), pan = tone.pan(t)
                for (d, wl, wr) in toneVoices {
                    let ph = twoPi * cyc * (1 + d * 0.0021) + tone.seed + d
                    let v = g * (sin(ph) + b * (0.28 * sin(2 * ph) + 0.1 * sin(3 * ph)))
                    l += v * wl * (1 - pan); r += v * wr * (1 + pan)
                }
            }

            for (h, c) in hits.enumerated() {
                let dt = t - c.time
                guard dt >= 0, dt < c.length else { continue }
                let attack = min(1, dt / 0.004)
                var v = 0.0
                for (p, (ratio, amp, decay)) in hitPartials[h].enumerated() {
                    v += amp * exp(-dt / decay) * sin(twoPi * c.freq * ratio * dt + Double(p))
                }
                v *= c.gain * attack
                l += v * (1 - c.pan); r += v * (1 + c.pan)
            }

            for h in cues.heartbeats {
                for (offset, gain) in beats {
                    let dt = t - h - offset
                    guard dt >= 0, dt < 0.7 else { continue }
                    let ph = twoPi * (46 * dt + 64 * (1 - exp(-26 * dt)) / 26)
                    let v = gain * exp(-dt * 7) * sin(ph) * min(1, dt / 0.003)
                    l += v; r += v
                }
            }

            for (k, air) in airs.enumerated() {
                let p = Ease.progress(t, air.start, air.end)
                guard p > 0, p < 1 else { continue }
                let sweep = air.opens ? p * p : 1 - (1 - p) * (1 - p)
                let cutoff = air.opens
                    ? air.cutoff.lowerBound + (air.cutoff.upperBound - air.cutoff.lowerBound) * sweep
                    : air.cutoff.upperBound - (air.cutoff.upperBound - air.cutoff.lowerBound) * sweep
                let a = 1 - exp(-twoPi * cutoff / sampleRate)
                var (fl, fr) = airMemory[k]
                fl += a * (noise() - fl); fr += a * (noise() - fr)
                airMemory[k] = (fl, fr)
                let env = air.gain * sin(.pi * p) * sin(.pi * p)
                let pan = Ease.mix(air.pan.from, air.pan.to, Ease.inOutSine(p))
                l += env * fl * (1 - pan); r += env * fr * (1 + pan)
            }

            var master = Ease.smooth((t + offset) / 0.4)
            if let f = fadeOutStart { master *= 1 - Ease.smooth((t + offset - f) / fadeOutLength) }
            left[i] = Float(tanh(l * master * 1.1) * 0.85)
            right[i] = Float(tanh(r * master * 1.1) * 0.85)
        }
        for (k, air) in airs.enumerated() { airState[air.id] = airMemory[k] }
        if airState.count > 64 { airState = airState.filter { id, _ in airs.contains { $0.id == id } } }
    }
}

/// Plays the score and the voice line, live or into a file.
public final class SunriseAudio {
    public let engine = AVAudioEngine()
    public private(set) var synth: SunriseSynth
    let player = AVAudioPlayerNode()
    let reverb = AVAudioUnitReverb()
    let voiceReverb = AVAudioUnitReverb()
    /// Turns the mono voice into stereo for the reverb.
    let voiceMixer = AVAudioMixerNode()
    var source: AVAudioSourceNode!
    let voice: AVAudioPCMBuffer?
    let format: AVAudioFormat

    public init(variant: SunriseVariant, reduced: Bool = false, offline: Bool = false) throws {
        format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        synth = SunriseSynth(variant: variant, reduced: reduced)
        voice = Self.loadVoice()
        if offline {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
        source = AVAudioSourceNode(format: format) { [unowned self] _, _, frames, buffers in
            let abl = UnsafeMutableAudioBufferListPointer(buffers)
            let l = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let r = abl[1].mData!.assumingMemoryBound(to: Float.self)
            self.synth.render(frames: Int(frames), left: l, right: r)
            return noErr
        }
        reverb.loadFactoryPreset(.largeHall2)
        reverb.wetDryMix = 36
        voiceReverb.loadFactoryPreset(.mediumRoom)
        voiceReverb.wetDryMix = 14
        [source, reverb, player, voiceMixer, voiceReverb].forEach { engine.attach($0) }
        engine.connect(source, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.connect(player, to: voiceMixer, format: voice?.format)
        engine.connect(voiceMixer, to: voiceReverb, format: format)
        engine.connect(voiceReverb, to: engine.mainMixerNode, format: format)
    }

    /// The target's resource bundle, found without SwiftPM's `Bundle.module`, which traps
    /// when the bundle is missing: Contents/Resources in the app, next to the binary for
    /// `swift run`, next to the test bundle for `swift test`. Missing means no voice.
    static let resourceBundle: Bundle? = {
        let name = "ReArcShell_Onboarding.bundle"
        let code = Bundle(for: BundleFinder.self)
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, code.resourceURL,
                     code.bundleURL.deletingLastPathComponent()]
        return roots.lazy.compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent(name)) } }.first
    }()

    static func loadVoice() -> AVAudioPCMBuffer? {
        guard let url = resourceBundle?.url(forResource: "voice-placeholder", withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        try? file.read(into: buffer)
        return buffer
    }

    public var muted: Bool {
        get { engine.mainMixerNode.outputVolume == 0 }
        set { engine.mainMixerNode.outputVolume = newValue ? 0 : 1 }
    }

    /// Starts from the top with a new variant.
    public func start(variant: SunriseVariant, reduced: Bool = false) throws {
        player.stop()
        // The render thread reads the synth; swap it only while stopped.
        if engine.isRunning { engine.stop() }
        synth = SunriseSynth(variant: variant, reduced: reduced)
        try engine.start()
        player.play()
        scheduleVoice(at: synth.cues.voice)
    }

    func scheduleVoice(at t: Double?) {
        guard let voice else { return }
        let when = t.map { AVAudioTime(sampleTime: AVAudioFramePosition($0 * voice.format.sampleRate), atRate: voice.format.sampleRate) }
        player.scheduleBuffer(voice, at: when)
    }

    /// Jumps to the rest frame; the voice speaks now if it has not yet.
    public func skip() {
        let end = synth.cues.end
        let spoken = synth.time >= synth.cues.voice
        synth.seek(to: end)
        if !spoken {
            player.stop(); player.play()
            scheduleVoice(at: nil)
        }
    }

    public func fadeOut(over length: Double = 1.8) { synth.fadeOut(over: length) }

    /// The score for what has happened so far (and what that sets in motion).
    /// Live runs pass the scene clock so the two stay aligned.
    public func update(_ score: SunriseScore, sceneTime: Double? = nil) { synth.setScore(score, sceneTime: sceneTime) }

    public func stop() { player.stop(); engine.stop() }

    /// Renders `duration` seconds to a WAV file.
    public func render(duration: Double, to url: URL) throws {
        try engine.start()
        player.play()
        scheduleVoice(at: synth.cues.voice)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ])
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        var remaining = AVAudioFramePosition(duration * 48_000)
        while remaining > 0 {
            let n = AVAudioFrameCount(min(Int64(4096), remaining))
            let status = try engine.renderOffline(n, to: buffer)
            guard status == .success else { break }
            try file.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        engine.stop()
    }
}

private final class BundleFinder {}
