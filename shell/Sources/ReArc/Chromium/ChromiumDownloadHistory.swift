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
private final class ArchivedPageBox {
    let body: (ReArcStatus, [DownloadRecord], UInt32) -> Void
    init(_ body: @escaping (ReArcStatus, [DownloadRecord], UInt32) -> Void) { self.body = body }
}

private let archivedPageCallback: ReArcDownloadRowsCallback = { context, status, rows, count, total in
    guard let context else { return }
    let box = Unmanaged<ArchivedPageBox>.fromOpaque(context).takeRetainedValue()
    var records: [DownloadRecord] = []
    if status == .rearcOK, let rows {
        records.reserveCapacity(Int(count))
        for row in UnsafeBufferPointer(start: rows, count: Int(count)) {
            records.append(ChromiumDownloadHistory.record(row))
        }
    }
    MainActor.assumeIsolated { box.body(status, records, total) }
}

enum ChromiumDownloadHistory {
    /// An archived row as a finished tray record (its own start and end times).
    static func record(_ row: ReArcDownloadRow) -> DownloadRecord {
        func string(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
        func date(_ micros: Int64) -> Date { Date(timeIntervalSince1970: Double(micros) / 1_000_000) }
        return DownloadRecord(id: string(row.guid), source: .chromium, url: string(row.url), targetPath: string(row.target_path),
                              mimeType: string(row.mime_type), receivedBytes: row.received_bytes, totalBytes: row.total_bytes,
                              state: .complete, dangerType: row.danger_type, startedAt: date(row.start_time_us),
                              updatedAt: row.end_time_us > 0 ? date(row.end_time_us) : nil)
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
