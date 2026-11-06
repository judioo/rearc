import Foundation

/// One delivered frame, reduced to numbers: its presentation time (seconds
/// on the host clock, from SCStreamFrameInfo.displayTime) and how much of the
/// measured region differs from the pre-input frame and from the frame before it.
public struct FrameSample: Equatable, Codable, Sendable {
    public var time: Double
    public var fromBaseline: Double
    public var fromPrevious: Double

    public init(time: Double, fromBaseline: Double, fromPrevious: Double) {
        self.time = time
        self.fromBaseline = fromBaseline
        self.fromPrevious = fromPrevious
    }
}

public struct DetectionSettings: Equatable, Codable, Sendable {
    /// A frame changed when this fraction of its compared pixels did (DiffSettings.areaThreshold).
    public var areaThreshold: Double
    /// Settled: the change after which nothing changes for this long.
    public var quiet: Double
    /// Give up this long after the input.
    public var timeout: Double
    /// Frames reach the harness a little after their display time; quiet is
    /// only trusted once this much more wall time has passed.
    public var deliveryMargin: Double

    public init(areaThreshold: Double = 0.002, quiet: Double = 0.150, timeout: Double = 3.0, deliveryMargin: Double = 0.050) {
        self.areaThreshold = areaThreshold
        self.quiet = quiet
        self.timeout = timeout
        self.deliveryMargin = deliveryMargin
    }
}

public enum Detection: Equatable, Sendable {
    /// Still waiting for the ack or for quiet.
    case pending
    /// Nothing changed beyond the threshold before the timeout.
    case noChange
    /// Seconds from the input to the ack frame and to the settled frame (nil:
    /// the window never went quiet before the timeout).
    case measured(ack: Double, settled: Double?)
}

public enum Detector {
    /// ack: the first frame presented after `postTime` that differs from the
    /// pre-input frame. settled: the last change of the run that starts at the
    /// ack, i.e. the first changed frame followed by `quiet` seconds without a
    /// change. Samples must be in time order; `now` is the host clock.
    public static func detect(_ samples: [FrameSample], postTime: Double, now: Double,
                              settings: DetectionSettings = DetectionSettings()) -> Detection {
        let expired = now - postTime >= settings.timeout
        guard let ackIndex = samples.firstIndex(where: { $0.time > postTime && $0.fromBaseline > settings.areaThreshold }) else {
            return expired ? .noChange : .pending
        }
        let ack = samples[ackIndex].time
        var last = ack
        var closed = false
        for sample in samples[(ackIndex + 1)...] where sample.fromPrevious > settings.areaThreshold {
            if sample.time - last >= settings.quiet {
                // A separate, later change: the run before it had already settled.
                closed = true
                break
            }
            last = sample.time
        }
        if closed || now - last >= settings.quiet + settings.deliveryMargin {
            return .measured(ack: ack - postTime, settled: last - postTime)
        }
        return expired ? .measured(ack: ack - postTime, settled: nil) : .pending
    }

    /// True when no frame changed in the `window` seconds before `now`: the
    /// harness posts input only into a still window.
    public static func isQuiet(_ samples: [FrameSample], now: Double, window: Double, areaThreshold: Double) -> Bool {
        !samples.contains { $0.time > now - window && $0.fromPrevious > areaThreshold }
    }
}
