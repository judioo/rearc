import Testing
@testable import ArcBenchCore

/// Ack and settle detection on synthetic frame sequences: real frames are
/// diffed into samples, as the capture does.
struct DetectionTests {
    let settings = DetectionSettings(areaThreshold: 0.002, quiet: 0.150, timeout: 3.0, deliveryMargin: 0.050)
    let frame = 1.0 / 120

    /// Diffs `frames` (shown at `start + i / 120`) against `baseline` and each previous frame.
    func samples(_ frames: [Frame], baseline: Frame, start: Double) -> [FrameSample] {
        var previous = baseline
        let diff = DiffSettings(channelThreshold: 24, stride: 1, areaThreshold: 0.002)
        return frames.enumerated().map { index, current in
            defer { previous = current }
            return FrameSample(time: start + Double(index) * frame, fromBaseline: FrameDiff.changedFraction(baseline, current, settings: diff),
                               fromPrevious: FrameDiff.changedFraction(previous, current, settings: diff))
        }
    }

    /// A 3-frame slide of a dark bar across a light window, then rest.
    func slide() -> (baseline: Frame, frames: [Frame]) {
        let baseline = Frame.solid(width: 100, height: 40, b: 240, g: 240, r: 240)
        var frames: [Frame] = []
        for step in 1 ... 3 {
            var next = baseline
            next.fill(x: 0 ..< step * 20, y: 0 ..< 40, b: 30, g: 30, r: 30)
            frames.append(next)
        }
        return (baseline, frames)
    }

    @Test func ackAndSettledOnASlide() throws {
        let (baseline, moving) = slide()
        // Input at t = 10; two unchanged frames, the slide, then rest frames.
        let frames = [baseline, baseline] + moving + Array(repeating: moving.last!, count: 30)
        let list = samples(frames, baseline: baseline, start: 10 + frame)
        let result = Detector.detect(list, postTime: 10, now: 12, settings: settings)
        guard case let .measured(ack, settled) = result else { Issue.record("not measured: \(result)"); return }
        #expect(abs(ack - 3 * frame) < 1e-9)
        #expect(abs(try #require(settled) - 5 * frame) < 1e-9)
    }

    @Test func pendingUntilQuietHasPassed() {
        let (baseline, moving) = slide()
        let list = samples(moving, baseline: baseline, start: 10.01)
        // Last change at 10.01 + 2 frames; quiet + margin is 200 ms.
        #expect(Detector.detect(list, postTime: 10, now: 10.1, settings: settings) == .pending)
        if case .measured = Detector.detect(list, postTime: 10, now: 10.3, settings: settings) {} else { Issue.record("expected measured") }
    }

    @Test func noiseBelowThresholdIsIgnored() {
        let baseline = Frame.solid(width: 100, height: 100, b: 0, g: 0, r: 0)
        var caret = baseline
        caret.fill(x: 50 ..< 51, y: 40 ..< 60, b: 255, g: 255, r: 255) // 20 px = 0.2 %, not > 0.2 %
        let list = samples([caret, baseline, caret, baseline], baseline: baseline, start: 10.01)
        #expect(Detector.detect(list, postTime: 10, now: 11, settings: settings) == .pending)
        #expect(Detector.detect(list, postTime: 10, now: 13.1, settings: settings) == .noChange)
    }

    @Test func changesBeforeTheInputDoNotAck() {
        let list = [
            FrameSample(time: 9.99, fromBaseline: 0.5, fromPrevious: 0.5),
            FrameSample(time: 10.0, fromBaseline: 0.5, fromPrevious: 0),
            FrameSample(time: 10.05, fromBaseline: 0.6, fromPrevious: 0.1),
        ]
        expectMeasured(Detector.detect(list, postTime: 10, now: 11, settings: settings), ack: 0.05, settled: 0.05)
    }

    func expectMeasured(_ detection: Detection, ack: Double, settled: Double?) {
        guard case let .measured(a, s) = detection else {
            Issue.record("not measured: \(detection)")
            return
        }
        #expect(abs(a - ack) < 1e-9)
        if let settled { #expect(abs((s ?? .nan) - settled) < 1e-9) } else { #expect(s == nil) }
    }

    @Test func aLaterSeparateChangeDoesNotExtendSettle() {
        let list = [
            FrameSample(time: 10.020, fromBaseline: 0.3, fromPrevious: 0.3),
            FrameSample(time: 10.040, fromBaseline: 0.4, fromPrevious: 0.1),
            // A blink 300 ms later: after the run had settled.
            FrameSample(time: 10.340, fromBaseline: 0.41, fromPrevious: 0.01),
        ]
        guard case let .measured(ack, settled) = Detector.detect(list, postTime: 10, now: 10.35, settings: settings) else {
            Issue.record("expected measured")
            return
        }
        #expect(abs(ack - 0.020) < 1e-9)
        #expect(abs(settled! - 0.040) < 1e-9)
    }

    @Test func neverQuietReportsAckWithoutSettled() {
        // A change every frame for the whole timeout (a video).
        let list = (1 ... 400).map { FrameSample(time: 10 + Double($0) * frame, fromBaseline: 0.5, fromPrevious: 0.5) }
        let result = Detector.detect(list, postTime: 10, now: 13.4, settings: settings)
        guard case let .measured(ack, settled) = result else { Issue.record("not measured: \(result)"); return }
        #expect(abs(ack - frame) < 1e-9)
        #expect(settled == nil)
        #expect(Detector.detect(list, postTime: 10, now: 12, settings: settings) == .pending)
    }

    @Test func singleChangeSettlesOnItself() {
        let list = [FrameSample(time: 10.016, fromBaseline: 1, fromPrevious: 1)]
        expectMeasured(Detector.detect(list, postTime: 10, now: 10.5, settings: settings), ack: 0.016, settled: 0.016)
    }

    @Test func returningToBaselineStillCountsAsMovement() {
        // A flash: changes, then goes back to the pre-input frame. ack at the flash, settled at the return.
        let list = [
            FrameSample(time: 10.01, fromBaseline: 0.2, fromPrevious: 0.2),
            FrameSample(time: 10.02, fromBaseline: 0, fromPrevious: 0.2),
        ]
        guard case let .measured(ack, settled) = Detector.detect(list, postTime: 10, now: 11, settings: settings) else {
            Issue.record("expected measured")
            return
        }
        #expect(abs(ack - 0.01) < 1e-9)
        #expect(abs(settled! - 0.02) < 1e-9)
    }

    @Test func quietWindow() {
        let list = [FrameSample(time: 9.5, fromBaseline: 0, fromPrevious: 0.5), FrameSample(time: 9.9, fromBaseline: 0, fromPrevious: 0.001)]
        #expect(Detector.isQuiet(list, now: 10, window: 0.3, areaThreshold: 0.002))
        #expect(!Detector.isQuiet(list, now: 9.7, window: 0.3, areaThreshold: 0.002))
        #expect(Detector.isQuiet([], now: 10, window: 0.3, areaThreshold: 0.002))
    }
}
