@testable import Onboarding
import XCTest

final class ScoreTests: XCTestCase {
    /// The whole scripted onboarding, as the preview tool renders it.
    func acts() -> (Act1Log, Act2Log, Act3Log, Act4Log) {
        let act1 = Act1Log.demo(start: SunriseCues.of(.horizon).end + 0.8)
        let act2 = Act2Log.demo(start: act1.handOff!)
        let base = Act3Log.after(act2, start: act2.handOff!, colour: ProfilePalette.colours[5].rgba)
        let act3 = Act3Log.demo(start: base.start, seeds: base.seeds, imported: base.imported)
        return (act1, act2, act3, Act4Log.after(act1: act1, act2: act2, act3: act3, start: act3.handOff!))
    }

    /// The bug that silenced Acts 1–3 in the full render: scheduling a later
    /// act dropped the sounds of the acts before it.
    func testLaterActsKeepEarlierSounds() {
        let (act1, act2, act3, act4) = acts()
        let early = SunriseScore.build(act1: act1, act2: act2, act3: nil, act4: nil)
        let all = SunriseScore.build(act1: act1, act2: act2, act3: act3, act4: act4)
        let before = early.hits.filter { $0.time < act3.start }
        XCTAssertGreaterThan(before.count, 100)
        for hit in before { XCTAssertTrue(all.hits.contains(hit), "\(hit) went missing") }
        XCTAssertEqual(all.airs.filter { $0.start < act3.start }, early.airs.filter { $0.start < act3.start })
    }

    /// Something on screen happens every moment, and every moment answers.
    func testEveryMomentIsHeard() {
        let (act1, act2, act3, act4) = acts()
        let score = SunriseScore.build(act1: act1, act2: act2, act3: act3, act4: act4)
        let starts = (score.hits.map(\.time) + score.airs.map(\.start) + score.tones.map(\.start)).sorted()
        for t in stride(from: act1.start, through: act4.handOff - 2.5, by: 0.25) {
            XCTAssertTrue(starts.contains { $0 >= t && $0 < t + 2.5 }, "nothing new sounds from \(t)s")
        }
    }

    /// A space's voice: its note begins when the space appears.
    func voice(_ score: SunriseScore, of space: Act3Log.Space) -> SunriseScore.Tone? {
        score.tones.first { $0.pitch.t.first == space.added && abs($0.pitch.hz(space.added) - ScoreNotes.note(space.colour) / 2) < 0.01 }
    }

    func testASpaceSoundsLikeItsColourAndSwellsWhenChosen() throws {
        let (act1, act2, act3, act4) = acts()
        let score = SunriseScore.build(act1: act1, act2: act2, act3: act3, act4: act4)
        let work = act3.state(at: act3.start + 1.5).spaces[1]
        let voice = try XCTUnwrap(self.voice(score, of: work))
        let chosen = try XCTUnwrap(act3.events.first { $0.event == .select(1) }?.time)
        let recoloured = try XCTUnwrap(act3.events.first { $0.event == .colour(1, 6) }?.time)
        XCTAssertGreaterThan(voice.gain(chosen + 0.4), 2 * voice.gain(chosen - 0.2), "choosing it brings its voice forward")
        XCTAssertEqual(voice.pitch.hz(recoloured + 0.5), ScoreNotes.colours[6] / 2, accuracy: 1e-9, "Iris has Iris's note")
        XCTAssertGreaterThan(voice.gain(act4.start + 1), 0, "it carries on into Act 4")
        XCTAssertLessThan(voice.pan(act4.handOff - 1), -0.5, "and lands in the switcher, bottom left")
        XCTAssertEqual(voice.gain(act4.handOff + 2), 0)
    }

    func testARemovedSpaceFallsSilent() throws {
        let (act1, act2, act3, act4) = acts()
        let score = SunriseScore.build(act1: act1, act2: act2, act3: act3, act4: act4)
        let removed = try XCTUnwrap(act3.state(at: .infinity).spaces.first { $0.removed != nil })
        let voice = try XCTUnwrap(self.voice(score, of: removed))
        XCTAssertGreaterThan(voice.gain(removed.removed! - 0.1), 0)
        XCTAssertEqual(voice.gain(removed.removed! + 1), 0)
    }

    func testYourColourStaysWithYou() throws {
        let (act1, act2, act3, act4) = acts()
        let score = SunriseScore.build(act1: act1, act2: act2, act3: act3, act4: act4)
        let pick = try XCTUnwrap(act1.picked)
        let you = try XCTUnwrap(score.tones.first { $0.start == pick.time && abs($0.pitch.hz(0) - ScoreNotes.colours[pick.index]) < 0.01 })
        XCTAssertGreaterThan(you.gain(act2.done!), you.gain(act2.flowStart!), "it brightens as the light comes home")
        XCTAssertEqual(you.pan(act4.start), 0)
        XCTAssertLessThan(you.pan(act4.start + Act4Timeline.flight + 2), -0.8, "it travels with your avatar")
    }

    /// Hovering a swatch hums its colour; picking keeps it.
    func testTheSkyIsHeard() {
        let (act1, _, _, _) = acts()
        let score = SunriseScore.build(act1: act1, act2: nil, act3: nil, act4: nil)
        let first = act1.hovers[0]
        XCTAssertNotNil(score.tones.first { abs($0.pitch.hz(0) - ScoreNotes.colours[first.index!]) < 0.01 && $0.gain(first.time + 0.4) > 0 })
    }

    /// A glide's phase is continuous, so re-scoring mid-note never clicks.
    func testAGlideIsSmooth() {
        let p = Pitch([(1, 200), (1.4, 300)])
        let dt = 1e-5
        for t in stride(from: 0.5, to: 2.0, by: 0.01) {
            XCTAssertEqual((p.cycles(t + dt) - p.cycles(t - dt)) / (2 * dt), p.hz(t), accuracy: 0.05)
        }
        XCTAssertEqual(Pitch(constant: 440).cycles(3), Pitch([(2, 440)]).cycles(3), accuracy: 1e-9, "one note, one phase")
    }

    func testTheFullScoreIsAudibleAndClean() {
        let (act1, act2, act3, act4) = acts()
        let synth = SunriseSynth(variant: .horizon)
        synth.setScore(SunriseScore.build(act1: act1, act2: act2, act3: act3, act4: act4))
        let f = act4.start + Act4Timeline.flight
        for moment in [act1.submitted!.time + 1, act2.flowStart! + 2, act2.done!, act3.doneTime! + 1, act4.start + 1.7, f + 1.3] {
            let n = 4800
            var l = [Float](repeating: 0, count: n), r = l
            synth.seek(to: moment)
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in synth.render(frames: n, left: lp.baseAddress!, right: rp.baseAddress!) }
            }
            let peak = zip(l, r).map { max(abs($0), abs($1)) }.max()!
            XCTAssertTrue(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite))
            XCTAssertLessThan(peak, 0.8, "at \(moment)s")
            XCTAssertGreaterThan(l.map { $0 * $0 }.reduce(0, +) / Float(n), 1e-4, "at \(moment)s")
        }
    }
}
