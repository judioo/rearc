#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

// Download history at scale (ABI 1.48 `download_history`, C-ABI.md "Download
// history at scale (1.48)", docs/DOWNLOADS-AT-SCALE.md). Each profile gets
// `DownloadHistoryPolicy.liveLimit` before its history loads; past it Chromium
// keeps old finished rows in its History DB only, and the tray pages them in.

/// `ReArcDownloadHistoryInfo`.
struct ChromiumDownloadHistoryInfo: Equatable {
    var profileID: UInt64
    var rows, liveRows, archivedRows: UInt32
}

private let downloadHistoryCallback: ReArcDownloadHistoryCallback = { context, info in
    guard let context, let i = info?.pointee else { return }
    let copied = ChromiumDownloadHistoryInfo(profileID: i.profile_id, rows: i.rows, liveRows: i.live_rows,
                                             archivedRows: i.archived_rows)
    MainActor.assumeIsolated {
        Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue().handleDownloadHistory(copied)
    }
}

/// One `ReArcDownloadQueryArchived` completion, retained across the call.
/// Only the main thread calls `body`.
private final class ArchivedPageBox: @unchecked Sendable {
    let body: (ReArcStatus, [DownloadRecord], UInt32) -> Void
    init(_ body: @escaping (ReArcStatus, [DownloadRecord], UInt32) -> Void) { self.body = body }
}

/// Making 1,000 records' strings took ~12 ms of the main thread per page:
/// the callback copies the borrowed rows' bytes, a worker makes the records,
/// and `body` gets them on main.
private let archivedPageCallback: ReArcDownloadRowsCallback = { context, status, rows, count, total in
    guard let context else { return }
    let box = Unmanaged<ArchivedPageBox>.fromOpaque(context).takeRetainedValue()
    guard status == .rearcOK, let rows, count > 0 else {
        return MainActor.assumeIsolated { box.body(status, [], total) }
    }
    let page = ArchivedPage(UnsafeBufferPointer(start: rows, count: Int(count)))
    DispatchQueue.global(qos: .userInitiated).async {
        let records = page.records()
        DispatchQueue.main.async { box.body(status, records, total) }
    }
}

/// Archived rows' strings as bytes in one buffer, owned past the callback.
private struct ArchivedPage: Sendable {
    private struct Row: Sendable {
        var strings: (Range<Int>, Range<Int>, Range<Int>, Range<Int>)  // guid, url, target path, MIME type
        var receivedBytes, totalBytes, startTime, endTime: Int64
        var dangerType: UInt32
    }

    private var bytes: [UInt8] = []
    private var rows: [Row] = []

    init(_ borrowed: UnsafeBufferPointer<ReArcDownloadRow>) {
        rows.reserveCapacity(borrowed.count)
        bytes.reserveCapacity(borrowed.count * 160)
        func copy(_ pointer: UnsafePointer<CChar>?) -> Range<Int> {
            let start = bytes.count
            if let pointer {
                let count = strlen(pointer)
                pointer.withMemoryRebound(to: UInt8.self, capacity: count) {
                    bytes.append(contentsOf: UnsafeBufferPointer(start: $0, count: count))
                }
            }
            return start ..< bytes.count
        }
        for row in borrowed {
            rows.append(Row(strings: (copy(row.guid), copy(row.url), copy(row.target_path), copy(row.mime_type)),
                            receivedBytes: row.received_bytes, totalBytes: row.total_bytes,
                            startTime: row.start_time_us, endTime: row.end_time_us, dangerType: row.danger_type))
        }
    }

    /// Finished tray records with their own start and end times.
    func records() -> [DownloadRecord] {
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func date(_ micros: Int64) -> Date { Date(timeIntervalSince1970: Double(micros) / 1_000_000) }
        return rows.map { row in
            DownloadRecord(id: string(row.strings.0), source: .chromium, url: string(row.strings.1),
                           targetPath: string(row.strings.2), mimeType: string(row.strings.3),
                           receivedBytes: row.receivedBytes, totalBytes: row.totalBytes, state: .complete,
                           dangerType: row.dangerType, startedAt: date(row.startTime),
                           updatedAt: row.endTime > 0 ? date(row.endTime) : nil)
        }
    }
}

extension ChromiumRuntime {
    /// Registered at `ready` with the download callback.
    func registerDownloadHistoryChannel(context: UnsafeMutableRawPointer) {
        if capabilities.downloadHistory { ReArcEngineSetDownloadHistoryCallback(downloadHistoryCallback, context) }
    }

    fileprivate func handleDownloadHistory(_ info: ChromiumDownloadHistoryInfo) {
        ChromiumLog.info("download history: profile \(info.profileID) rows \(info.rows) live \(info.liveRows) archived \(info.archivedRows)")
        onDownloadHistoryLoaded?(info)
    }

    /// With each profile's download policy, before its history can load.
    /// After the load (or for an off-the-record profile) the engine refuses: fine.
    func applyDownloadHistoryPolicy(profile: UInt64) {
        guard capabilities.downloadHistory else { return }
        let status = ReArcDownloadSetHistoryPolicy(profile, DownloadHistoryPolicy.liveLimit)
        ChromiumLog.trace("download history policy: profile \(profile) live limit \(DownloadHistoryPolicy.liveLimit) -> \(status.rearcName)")
    }

    /// Starts every open profile's history load (no-op once started).
    func loadDownloadHistory() {
        guard capabilities.downloadHistory, isReady, !isStopping else { return }
        for profile in openEngineProfileIDs {
            let status = ReArcDownloadLoadHistory(profile)
            if status != .rearcOK, status != ReArcStatus(REARC_UNSUPPORTED) {
                ChromiumLog.info("ReArcDownloadLoadHistory(profile \(profile)) rejected: \(status.rearcName)")
            }
        }
    }

    /// One page of a profile's archived rows, newest first; `completion` gets the total.
    @discardableResult
    func queryArchivedDownloads(profile: UInt64, offset: UInt32, limit: UInt32,
                                _ completion: @escaping (ReArcStatus, [DownloadRecord], UInt32) -> Void) -> ReArcStatus {
        guard capabilities.downloadHistory, isReady, !isStopping else { return ReArcStatus(REARC_UNSUPPORTED) }
        let box = Unmanaged.passRetained(ArchivedPageBox(completion))
        let status = ReArcDownloadQueryArchived(profile, offset, limit, archivedPageCallback, box.toOpaque())
        if status != .rearcOK {
            box.release()
            ChromiumLog.info("ReArcDownloadQueryArchived(profile \(profile), \(offset), \(limit)) rejected: \(status.rearcName)")
        }
        return status
    }

    /// A live item's own start and end (nil end until it finishes); nil when unsupported or unknown.
    func downloadTimes(profile: UInt64, id: UInt32) -> (started: Date, ended: Date?)? {
        guard capabilities.downloadHistory, isReady, !isStopping else { return nil }
        var start: Int64 = 0
        var end: Int64 = 0
        guard ReArcDownloadGetTimes(profile, id, &start, &end) == .rearcOK, start > 0 else { return nil }
        return (Date(timeIntervalSince1970: Double(start) / 1_000_000), end > 0 ? Date(timeIntervalSince1970: Double(end) / 1_000_000) : nil)
    }

    /// Deletes archived rows from the profile's History DB; returns how many.
    func removeArchivedDownloads(profile: UInt64, guids: [String]) -> UInt32 {
        guard capabilities.downloadHistory, isReady, !isStopping, !guids.isEmpty else { return 0 }
        var removed: UInt32 = 0
        var total: UInt32 = 0
        // At most 100,000 GUIDs a call.
        for start in stride(from: 0, to: guids.count, by: 100_000) {
            let chunk = Array(guids[start ..< min(start + 100_000, guids.count)])
            let pointers = chunk.map { strdup($0) }
            defer { pointers.forEach { free($0) } }
            let status = pointers.map { UnsafePointer($0) }.withUnsafeBufferPointer {
                ReArcDownloadRemoveArchived(profile, $0.baseAddress, UInt32(chunk.count), &removed)
            }
            if status != .rearcOK { ChromiumLog.info("ReArcDownloadRemoveArchived(profile \(profile)) rejected: \(status.rearcName)") }
            total += removed
        }
        return total
    }
}
#endif
