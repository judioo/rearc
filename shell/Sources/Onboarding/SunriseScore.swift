import AVFoundation
import Foundation
import os

/// The Act 0 score, synthesised: a D drone, a pad whose notes arrive with the
/// light (Dadd9 opening into D6/9), a two-note chime when the mark forms, and
/// per-variant touches (heartbeats for Ember, a noise swell, star sparkles).
/// It brightens with the dawn and then rests on the chord until Begin.
/// Stateful only for the noise filter, so render it in order.
public final class SunriseSynth {
    public let sampleRate: Double
    public let variant: SunriseVariant
    public let reduced: Bool
    let cues: SunriseCues
    struct Note { let freq, start, attack, gain: Double }
    struct Chime { let time, freq, gain, pan: Double }
    let notes: [Note]
    let chimes: [Chime]
    var sample: Int64 = 0
    /// 1 while playing; Begin fades it to 0.
    public var fadeOutStart: Double?
    /// Sounds the person sets off (Act 1), added from the main thread.
    struct Live { var chimes: [Chime] = []; var arpStart: Double?; var risers: [ClosedRange<Double>] = [] }
    let live = OSAllocatedUnfairLock(initialState: Live())
    var noiseState: UInt64 = 0x9E37_79B9_7F4A_7C15
    var lowL = 0.0, lowR = 0.0

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
        var chimes = [Chime(time: c, freq: 880.0, gain: 0.07, pan: -0.25),
                      Chime(time: c + 0.21, freq: 1318.5, gain: 0.05, pan: 0.3)]
        if cues.sparkles {
            // Stars, early and quiet, on a D major pentatonic.
            let pent = [1174.66, 1318.51, 1479.98, 1760.0, 1975.53, 2349.32]
            var s: UInt64 = 7
            for i in 0 ..< 14 {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                let r = Double(s >> 11) / Double(1 << 53)
                chimes.append(Chime(time: 1.0 + Double(i) * 0.38 + r * 0.2, freq: pent[Int(r * 6) % 6],
                                    gain: 0.012 + 0.01 * r, pan: r * 1.6 - 0.8))
            }
        }
        self.chimes = chimes
    }

    public enum Cue: Equatable, Sendable { case begin, key(Int), submit, hover(Int), pick(Int), toggle, bring, arrival(Int), restored, refocused, sweep, space(Int), addSpace, removeSpace, finale(Int), word(Int), window }
    static let pentatonic = [587.33, 659.25, 739.99, 880.0, 987.77, 1174.66, 1318.51, 1479.98]

    /// Adds a sound now, or at `time` (offline renders schedule the whole log up front).
    public func cue(_ cue: Cue, at time: Double? = nil) {
        let t = time ?? self.time
        var add: [Chime] = []
        var arp: Double?
        var riser: ClosedRange<Double>?
        switch cue {
        case .begin:
            add = [Chime(time: t, freq: 587.33, gain: 0.035, pan: 0)]
        case let .key(n):
            add = [Chime(time: t, freq: Self.pentatonic[max(0, n - 1) % 6], gain: 0.02, pan: Double(n % 5) * 0.2 - 0.4)]
        case .submit:
            add = [880.0, 1174.66, 1479.98].enumerated().map { Chime(time: t + Double($0) * 0.09, freq: $1, gain: 0.035, pan: Double($0) * 0.3 - 0.3) }
            arp = t + 0.6
        case let .hover(i):
            add = [Chime(time: t, freq: Self.pentatonic[i % Self.pentatonic.count] * 2, gain: 0.008, pan: Double(i) / 3.5 - 1)]
        case let .pick(i):
            add = [587.33, 880.0, 1479.98, Self.pentatonic[i % Self.pentatonic.count] * 2].enumerated()
                .map { Chime(time: t + Double($0) * 0.07, freq: $1, gain: 0.04, pan: Double($0) * 0.25 - 0.4) }
        case .toggle:
            add = [Chime(time: t, freq: 1318.51, gain: 0.012, pan: 0.1)]
        case .bring:
            add = [Chime(time: t, freq: 293.66, gain: 0.04, pan: 0), Chime(time: t + 0.12, freq: 440, gain: 0.03, pan: 0.2)]
            riser = (t + 0.3) ... (t + 0.3 + Act2Timeline.flow - 1.2)
        case let .arrival(n):
            add = [Chime(time: t, freq: Self.pentatonic[n % Self.pentatonic.count] * 2, gain: 0.006, pan: Double(n % 7) / 3.5 - 0.85)]
        case .restored:
            add = [146.83, 220.0, 293.66, 369.99, 440.0, 587.33, 880.0].enumerated()
                .map { Chime(time: t + Double($0) * 0.06, freq: $1, gain: $0 < 3 ? 0.07 : 0.04, pan: Double($0) * 0.2 - 0.6) }
        case .refocused:
            add = [293.66, 440.0, 587.33].enumerated().map { Chime(time: t + Double($0) * 0.12, freq: $1, gain: 0.035, pan: Double($0) * 0.3 - 0.3) }
        case let .space(n):
            add = [Chime(time: t, freq: Self.pentatonic[n % Self.pentatonic.count], gain: 0.018, pan: 0.4)]
        case .addSpace:
            add = [Chime(time: t, freq: 739.99, gain: 0.025, pan: 0.4), Chime(time: t + 0.1, freq: 1108.73, gain: 0.025, pan: 0.5)]
        case .removeSpace:
            add = [Chime(time: t, freq: 880, gain: 0.02, pan: 0.4), Chime(time: t + 0.1, freq: 587.33, gain: 0.02, pan: 0.3)]
        case let .finale(n):
            add = (0 ..< n).map { Chime(time: t + 0.4 + Double($0) * 0.12, freq: Self.pentatonic[$0 % Self.pentatonic.count] * ($0 >= Self.pentatonic.count ? 2 : 1),
                                        gain: 0.022, pan: Double($0 % 5) * 0.3 - 0.6) }
                + [146.83, 220.0, 293.66, 369.99, 554.37].map { Chime(time: t + 0.5 + Double(n) * 0.12, freq: $0, gain: 0.045, pan: 0) }
        case let .word(i):
            // ReFocused. ReStored. ReArc. — the last one lands on the chord.
            add = [Chime(time: t, freq: [587.33, 739.99, 880.0][min(i, 2)], gain: 0.045, pan: Double(i) * 0.3 - 0.3)]
            if i == 2 {
                add += [73.42, 110.0, 146.83, 220.0, 293.66, 369.99, 440.0, 1174.66]
                    .map { Chime(time: t + 0.02, freq: $0, gain: $0 < 150 ? 0.09 : 0.04, pan: 0) }
            }
        case .window:
            add = [Chime(time: t + 1.1, freq: 1760.0, gain: 0.02, pan: 0.2), Chime(time: t + 1.25, freq: 2349.32, gain: 0.014, pan: -0.2)]
            riser = t ... (t + 0.5)
        case .sweep:
            add = [Chime(time: t + 1.2, freq: 1318.51, gain: 0.03, pan: 0.6)]
            riser = t ... (t + 0.6)
        }
        let sounds = add, arpStart = arp, newRiser = riser
        live.withLock {
            $0.chimes.removeAll { t - $0.time > 6 }
            $0.chimes += sounds
            if let arpStart, $0.arpStart == nil { $0.arpStart = arpStart }
            if let newRiser { $0.risers.append(newRiser) }
        }
    }

    public var time: Double { Double(sample) / sampleRate }
    public func seek(to t: Double) { sample = Int64(t * sampleRate) }
    public func fadeOut() { if fadeOutStart == nil { fadeOutStart = time } }

    func noise() -> Double {
        noiseState ^= noiseState << 13; noiseState ^= noiseState >> 7; noiseState ^= noiseState << 17
        return Double(noiseState >> 11) / Double(1 << 52) - 1
    }

    public func render(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let twoPi = 2 * Double.pi
        let live = self.live.withLock { $0 }
        let allChimes = chimes + live.chimes
        // After your name: a slow arpeggio joins the chord.
        let arpNotes = [440.0, 587.33, 739.99, 880.0, 739.99, 587.33]
        for i in 0 ..< frames {
            let t = Double(sample) / sampleRate
            sample += 1
            let bright = SunriseTimeline.dawn(variant, t, reduced: reduced)
            var l = 0.0, r = 0.0

            for (k, n) in notes.enumerated() where t > n.start {
                let env = Ease.smooth((t - n.start) / n.attack) * (0.86 + 0.14 * sin(twoPi * 0.09 * t + Double(k)))
                let g = env * n.gain
                for (d, (wl, wr)) in [(-1.0, (1.0, 0.45)), (0.0, (0.8, 0.8)), (1.0, (0.45, 1.0))] {
                    let ph = twoPi * n.freq * (1 + d * 0.0023) * t + Double(k) * 1.7 + d
                    var v = sin(ph)
                    if bright > 0.05 { v += bright * (0.22 * sin(2 * ph) + 0.07 * sin(3 * ph)) }
                    l += g * wl * v; r += g * wr * v
                }
            }

            if let a = live.arpStart, t >= a {
                let step = 0.26, k = Int((t - a) / step)
                let swell = Ease.smooth((t - a) / 3)
                for j in max(0, k - 3) ... k {
                    let dt = t - a - Double(j) * step
                    let f = arpNotes[j % arpNotes.count]
                    let v = 0.016 * swell * exp(-dt / 0.8) * min(1, dt / 0.006) * (sin(twoPi * f * dt) + 0.3 * sin(twoPi * 2 * f * dt))
                    let pan = j % 2 == 0 ? -0.35 : 0.35
                    l += v * (1 - pan); r += v * (1 + pan)
                }
            }

            for c in allChimes {
                let dt = t - c.time
                guard dt >= 0, dt < 5 else { continue }
                let attack = min(1, dt / 0.004)
                var v = 0.0
                for (p, (ratio, amp, decay)) in [(1.0, 1.0, 2.6), (2.756, 0.45, 1.3), (5.404, 0.2, 0.6), (8.933, 0.08, 0.3)].enumerated() {
                    v += amp * exp(-dt / decay) * sin(twoPi * c.freq * ratio * dt + Double(p))
                }
                v *= c.gain * attack
                l += v * (1 - c.pan) * 0.5 * 2; r += v * (1 + c.pan) * 0.5 * 2
            }

            for h in cues.heartbeats {
                for (offset, gain) in [(0.0, 0.5), (0.28, 0.3)] {
                    let dt = t - h - offset
                    guard dt >= 0, dt < 0.7 else { continue }
                    let ph = twoPi * (46 * dt + 64 * (1 - exp(-26 * dt)) / 26)
                    let v = gain * exp(-dt * 7) * sin(ph) * min(1, dt / 0.003)
                    l += v; r += v
                }
            }

            for riser in [cues.riser].compactMap({ $0 }) + live.risers {
                let p = Ease.progress(t, riser.lowerBound, riser.upperBound + 1.2)
                if p > 0, p < 1 {
                    let cutoff = 180 + 2600 * p * p
                    let a = 1 - exp(-twoPi * cutoff / sampleRate)
                    lowL += a * (noise() - lowL); lowR += a * (noise() - lowR)
                    let env = 0.05 * sin(.pi * p) * sin(.pi * p)
                    l += env * lowL; r += env * lowR
                }
            }

            var master = Ease.smooth(t / 0.4)
            if let f = fadeOutStart { master *= 1 - Ease.smooth((t - f) / 1.8) }
            left[i] = Float(tanh(l * master * 1.1) * 0.85)
            right[i] = Float(tanh(r * master * 1.1) * 0.85)
        }
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

    public func fadeOut() { synth.fadeOut() }

    public func cue(_ cue: SunriseSynth.Cue, at time: Double? = nil) { synth.cue(cue, at: time) }

    /// Schedules every sound a scripted Act 1 log sets off (offline renders).
    public func schedule(_ log: Act1Log) {
        synth.cue(.begin, at: log.start)
        var last = 0
        for e in log.edits {
            if e.text.count > last { synth.cue(.key(e.text.count), at: e.time) }
            last = e.text.count
        }
        if let s = log.submitted { synth.cue(.submit, at: s.time) }
        for h in log.hovers { if let i = h.index { synth.cue(.hover(i), at: h.time) } }
        if let p = log.picked { synth.cue(.pick(p.index), at: p.time) }
    }

    /// Act 4 plays on its own: the motto's three words, then the window.
    public func schedule(_ log: Act4Log, now: Double? = nil) {
        let offset = now.map { synth.time - $0 } ?? 0
        let s = log.start + offset
        for (i, d) in [0.6, 1.15, 1.7].enumerated() { synth.cue(.word(i), at: s + d) }
        synth.cue(.window, at: s + Act4Timeline.flight)
    }

    /// Schedules every sound a scripted Act 3 log sets off (offline renders).
    public func schedule(_ log: Act3Log) {
        for (time, event) in log.events {
            switch event {
            case let .select(id?): synth.cue(.space(id), at: time)
            case .colour, .icon: synth.cue(.toggle, at: time)
            case .add: synth.cue(.addSpace, at: time)
            case .remove: synth.cue(.removeSpace, at: time)
            case .done: synth.cue(.finale(log.state(at: time).spaces.filter { $0.removed == nil }.count), at: time)
            default: break
            }
        }
    }

    /// Schedules every sound a scripted Act 2 log sets off (offline renders).
    public func schedule(_ log: Act2Log) {
        for e in log.toggles { synth.cue(.toggle, at: e.time) }
        for e in log.categories { synth.cue(.toggle, at: e.time) }
        guard let c = log.choice, let done = log.done else { return }
        if log.bringing {
            synth.cue(.bring, at: c.time)
            for (time, n) in Act2Timeline.arrivalTimes(log) { synth.cue(.arrival(n), at: time) }
            synth.cue(.restored, at: done)
        } else {
            synth.cue(.refocused, at: done)
        }
        synth.cue(.sweep, at: done + 1.4)
    }

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
