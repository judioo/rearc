#if REARC_CHROMIUM
import Foundation
import ReArcEngine

/// Owned copy of `ReArcPageTimingEvent` (ABI 1.44): a main-frame milestone
/// of one navigation, on the engine's clock (microseconds of mach time, the
/// clock of `CACurrentMediaTime` and `NSEvent.timestamp`).
struct ChromiumPageTiming: Equatable {
    enum Kind: UInt32 {
        case responseStart = 0, firstPaint, firstContentfulPaint, domContentLoaded, loadEventStart, largestContentfulPaint
    }
    var profileID, tabID, contentGeneration, navigationID: UInt64
    var kind: Kind
    var navigationStartMicros, valueMicros: Int64
    var size: UInt64
    var url: String

    var milliseconds: Double { Double(valueMicros - navigationStartMicros) / 1000 }
}

/// Owned copy of `ReArcViewPresentationEvent`: the frame Chromium presented
/// after a lease turned visible (`shown`) or was resized (`resized`).
struct ChromiumViewPresentation: Equatable {
    enum Kind: UInt32 { case shown = 0, resized = 1 }
    enum Status: UInt32 { case presented = 0, incomplete = 1, superseded = 2, timedOut = 3 }
    var profileID, tabID, attachmentID, requestID: UInt64
    var kind: Kind
    var status: Status
    var startMicros, activatedMicros, presentedMicros: Int64
    var width, height: Int32
}

struct ChromiumHistogram: Equatable {
    struct Bucket: Equatable { var min, max, count: Int64 }
    var name: String
    var count, sum: Int64
    var buckets: [Bucket]
}

struct ChromiumProcessInfo: Equatable {
    enum Kind: UInt32 { case browser = 0, renderer, gpu, utility, other }
    var pid: Int32
    var kind: Kind
    var name: String
    var profileID: UInt64
    var isExtension: Bool
    var tabIDs: [UInt64]
    var physFootprint, residentSize: UInt64
    var cpuMicros: Int64
}

/// The bench's engine measurement channels. `install` registers both
/// callbacks once, before any tab exists (page timing attaches at tab
/// creation); the normal app never installs them.
@MainActor
final class ChromiumPerfMetrics {
    static let shared = ChromiumPerfMetrics()

    var onPageTiming: ((ChromiumPageTiming) -> Void)?
    var onViewPresentation: ((ChromiumViewPresentation) -> Void)?
    private(set) var isInstalled = false

    func install(capabilities: ChromiumCapabilities) -> Bool {
        guard capabilities.perfMetrics else { return false }
        guard !isInstalled else { return true }
        ReArcEngineSetPageTimingCallback(pageTimingCallback, nil)
        ReArcEngineSetViewPresentationCallback(viewPresentationCallback, nil)
        isInstalled = true
        return true
    }

    func histogram(_ name: String) async -> ChromiumHistogram? {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(Box(continuation)).toOpaque()
            let status = name.withCString { ReArcMetricsGetHistogram($0, histogramCallback, box) }
            if status != .rearcOK {
                Unmanaged<Box<ChromiumHistogram?>>.fromOpaque(box).release()
                continuation.resume(returning: nil)
            }
        }
    }

    func processes() async -> [ChromiumProcessInfo] {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(Box(continuation)).toOpaque()
            if ReArcEngineGetProcesses(processesCallback, box) != .rearcOK {
                Unmanaged<Box<[ChromiumProcessInfo]>>.fromOpaque(box).release()
                continuation.resume(returning: [])
            }
        }
    }

    fileprivate final class Box<Value> {
        let continuation: CheckedContinuation<Value, Never>
        init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    }
}

private let pageTimingCallback: ReArcPageTimingCallback = { _, event in
    guard let e = event?.pointee, let kind = ChromiumPageTiming.Kind(rawValue: e.kind) else { return }
    let timing = ChromiumPageTiming(
        profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation, navigationID: e.navigation_id,
        kind: kind, navigationStartMicros: e.navigation_start_us, valueMicros: e.value_us, size: e.size,
        url: e.url.map { String(cString: $0) } ?? ""
    )
    MainActor.assumeIsolated { ChromiumPerfMetrics.shared.onPageTiming?(timing) }
}

private let viewPresentationCallback: ReArcViewPresentationCallback = { _, event in
    guard let e = event?.pointee, let kind = ChromiumViewPresentation.Kind(rawValue: e.kind),
          let status = ChromiumViewPresentation.Status(rawValue: e.status) else { return }
    let presentation = ChromiumViewPresentation(
        profileID: e.profile_id, tabID: e.tab_id, attachmentID: e.attachment_id, requestID: e.request_id,
        kind: kind, status: status, startMicros: e.start_us, activatedMicros: e.activated_us,
        presentedMicros: e.presented_us, width: e.width, height: e.height
    )
    MainActor.assumeIsolated { ChromiumPerfMetrics.shared.onViewPresentation?(presentation) }
}

private let histogramCallback: ReArcHistogramCallback = { context, status, histogram in
    let box = Unmanaged<ChromiumPerfMetrics.Box<ChromiumHistogram?>>.fromOpaque(context!).takeRetainedValue()
    guard status == .rearcOK, let h = histogram?.pointee else { return box.continuation.resume(returning: nil) }
    let buckets = UnsafeBufferPointer(start: h.buckets, count: h.bucket_count).map {
        ChromiumHistogram.Bucket(min: $0.min, max: $0.max, count: $0.count)
    }
    box.continuation.resume(returning: ChromiumHistogram(name: String(cString: h.name), count: h.count, sum: h.sum, buckets: buckets))
}

private let processesCallback: ReArcProcessListCallback = { context, status, processes, count in
    let box = Unmanaged<ChromiumPerfMetrics.Box<[ChromiumProcessInfo]>>.fromOpaque(context!).takeRetainedValue()
    guard status == .rearcOK else { return box.continuation.resume(returning: []) }
    let rows = UnsafeBufferPointer(start: processes, count: count).map { p in
        ChromiumProcessInfo(
            pid: p.pid, kind: ChromiumProcessInfo.Kind(rawValue: p.type) ?? .other,
            name: p.name.map { String(cString: $0) } ?? "", profileID: p.profile_id, isExtension: p.is_extension,
            tabIDs: Array(UnsafeBufferPointer(start: p.tab_ids, count: p.tab_count)),
            physFootprint: p.phys_footprint, residentSize: p.resident_size, cpuMicros: p.cpu_time_us
        )
    }
    box.continuation.resume(returning: rows)
}
#endif
