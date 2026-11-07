import Foundation

/// The downloads tray's rows (pure, no UI imports). Chromium's DownloadManager
/// owns its items (ABI 1.17 events, keyed by GUID); WebKit downloads are the
/// shell's own and get a shell GUID. Both reduce to the same records, which
/// are persisted so the recent list survives relaunch.
public enum DownloadState: String, Codable, Equatable, Sendable {
    case inProgress, complete, cancelled, interrupted

    /// `ReArcDownloadEvent.state`: 0 in_progress, 1 complete, 2 cancelled, 3 interrupted.
    public init(engineState: UInt32) {
        switch engineState {
        case 1: self = .complete
        case 2: self = .cancelled
        case 3: self = .interrupted
        default: self = .inProgress
        }
    }
}

public enum DownloadSource: String, Codable, Equatable, Sendable {
    case chromium, webKit
}

/// Chromium `download::DownloadDangerType`, reduced to what the tray shows.
public enum DownloadDanger: Equatable, Sendable {
    case none
    /// The safety check is still running (maybe-dangerous content, async scanning).
    case checking
    case warning(String)

    public init(dangerType: UInt32) {
        switch dangerType {
        case 0, 6, 9, 15: self = .none // not dangerous, user validated, allowlisted, deep-scanned safe
        case 4, 10, 22: self = .checking
        case 1: self = .warning("This type of file can harm your computer")
        case 2, 3, 7, 19: self = .warning("This file is dangerous")
        case 5: self = .warning("This file isn't commonly downloaded")
        case 8: self = .warning("This file may be unwanted software")
        case 11, 21: self = .warning("Encrypted file — can't be checked")
        case 12: self = .warning("File too large to check")
        default: self = .warning("This file may be harmful")
        }
    }
}

/// Chromium's current warning on an unfinished download (ABI 1.24
/// `ReArcDownloadGetWarning`). The danger code alone does not say whether a
/// decision is possible (4 is a pending check, 6 user-validated): the
/// booleans do. Keep validates the insecure warning first, then the danger
/// one, so a kept item can still ask again.
public struct DownloadWarning: Equatable, Sendable {
    public var dangerType: UInt32
    /// 0 unknown, 1 safe, 2 validated, 3 warn, 4 block, 5 silent block.
    public var insecureStatus: UInt32
    public var isDangerous: Bool
    public var isInsecure: Bool

    public init(dangerType: UInt32, insecureStatus: UInt32, isDangerous: Bool, isInsecure: Bool) {
        self.dangerType = dangerType
        self.insecureStatus = insecureStatus
        self.isDangerous = isDangerous
        self.isInsecure = isInsecure
    }

    /// Keep and Discard apply.
    public var offersDecision: Bool { isDangerous || isInsecure }

    public var message: String {
        if isInsecure { return "This file can't be downloaded securely" }
        if case .warning(let text) = DownloadDanger(dangerType: dangerType) { return text }
        return "This file may be harmful"
    }
}

/// Downloads at scale (docs/DOWNLOADS-AT-SCALE.md): how the shell asks
/// Chromium to load a long download history. Chromium counts its history rows
/// when it loads them; up to `liveLimit` finished rows it makes every row a
/// live download item, as stock Chromium does. Past it only the newest
/// `liveLimit` (and every unfinished row) become items; older rows stay in
/// the History DB as archived rows, which the tray pages in from a worker
/// (`archivedPageSize` per main-thread turn) and keeps as plain records.
/// A live item costs ~6.4 KB of engine memory and ~12 µs of main thread to
/// create; an archived row ~0.3 KB and nothing on the main thread.
public enum DownloadHistoryPolicy {
    /// Finished rows Chromium keeps as live items (ABI 1.48 live_limit).
    public static let liveLimit: UInt32 = 5_000
    /// Archived rows per `ReArcDownloadQueryArchived` page.
    public static let archivedPageSize: UInt32 = 1_000
}

/// Keep or Discard for a download Chromium warned about (`ReArcDownloadResolveDanger`).
public enum DownloadDangerDecision: UInt32, Sendable {
    case keep = 0, discard = 1
}

public struct DownloadRecord: Codable, Equatable, Identifiable, Sendable {
    /// Chromium's GUID, or a shell UUID for WebKit downloads.
    public var id: String
    public var source: DownloadSource
    public var url: String
    /// Empty until the engine chose the destination.
    public var targetPath: String
    public var mimeType: String
    public var receivedBytes: Int64
    /// 0 = unknown.
    public var totalBytes: Int64
    public var state: DownloadState
    public var dangerType: UInt32
    public var interruptReason: UInt32
    public var isPaused: Bool
    public var canResume: Bool
    public var startedAt: Date
    public var updatedAt: Date
    /// Session only: smoothed transfer rate for the "x/s" label.
    public var bytesPerSecond: Double?

    enum CodingKeys: String, CodingKey {
        case id, source, url, targetPath, mimeType, receivedBytes, totalBytes, state
        case dangerType, interruptReason, isPaused, canResume, startedAt, updatedAt
    }

    public init(
        id: String,
        source: DownloadSource,
        url: String,
        targetPath: String = "",
        mimeType: String = "",
        receivedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        state: DownloadState = .inProgress,
        dangerType: UInt32 = 0,
        interruptReason: UInt32 = 0,
        isPaused: Bool = false,
        canResume: Bool = false,
        startedAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.source = source
        self.url = url
        self.targetPath = targetPath
        self.mimeType = mimeType
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.state = state
        self.dangerType = dangerType
        self.interruptReason = interruptReason
        self.isPaused = isPaused
        self.canResume = canResume
        self.startedAt = startedAt
        self.updatedAt = updatedAt ?? startedAt
    }

    public var fileName: String {
        if !targetPath.isEmpty { return (targetPath as NSString).lastPathComponent }
        if let last = URL(string: url)?.lastPathComponent, !last.isEmpty, last != "/" { return last }
        return URL(string: url)?.host() ?? "Download"
    }

    public var danger: DownloadDanger {
        state == .inProgress ? DownloadDanger(dangerType: dangerType) : .none
    }

    public var isDangerous: Bool {
        if case .warning = danger { return true }
        return false
    }

    public var isActive: Bool { state == .inProgress }

    /// 0...1, nil when the total is unknown.
    public var fractionCompleted: Double? {
        guard totalBytes > 0 else { return state == .complete ? 1 : nil }
        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }

    public var hasFileOnDisk: Bool { state == .complete && !targetPath.isEmpty }

    public var statusText: String {
        let received = DownloadFormat.bytes(receivedBytes)
        let total = totalBytes > 0 ? DownloadFormat.bytes(totalBytes) : nil
        switch state {
        case .complete:
            return total ?? received
        case .cancelled:
            return "Cancelled"
        case .interrupted:
            return "Failed — \(DownloadFormat.interruptReason(interruptReason))"
        case .inProgress:
            if case .warning(let message) = danger { return message }
            let amount = total.map { "\(received) of \($0)" } ?? received
            if isPaused { return "Paused — \(amount)" }
            if case .checking = danger, totalBytes > 0, receivedBytes >= totalBytes { return "Checking — \(amount)" }
            guard let rate = bytesPerSecond, rate > 0 else { return amount }
            var parts = [amount, "\(DownloadFormat.bytes(Int64(rate)))/s"]
            if totalBytes > receivedBytes {
                parts.append(DownloadFormat.remaining(seconds: Double(totalBytes - receivedBytes) / rate))
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// One engine download update, copied out of the callback (strings owned).
public struct DownloadEvent: Equatable, Sendable {
    /// `ReArcDownloadEvent.kind`: 0 created, 1 updated, 2 completed,
    /// 3 interrupted, 4 cancelled, 5 removed.
    public enum Kind: UInt32, Sendable {
        case created = 0, updated, completed, interrupted, cancelled, removed
    }

    public var kind: Kind
    public var guid: String
    public var url: String
    public var targetPath: String
    public var mimeType: String
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var state: DownloadState
    public var dangerType: UInt32
    public var interruptReason: UInt32
    public var isPaused: Bool
    public var canResume: Bool
    /// The engine's own times, when it reported them (ABI 1.48
    /// `ReArcDownloadGetTimes`): an item restored from history keeps its
    /// dates instead of taking the time its event arrived.
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        kind: Kind,
        guid: String,
        url: String,
        targetPath: String = "",
        mimeType: String = "",
        receivedBytes: Int64 = 0,
        totalBytes: Int64 = 0,
        state: DownloadState = .inProgress,
        dangerType: UInt32 = 0,
        interruptReason: UInt32 = 0,
        isPaused: Bool = false,
        canResume: Bool = false,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.kind = kind
        self.guid = guid
        self.url = url
        self.targetPath = targetPath
        self.mimeType = mimeType
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.state = state
        self.dangerType = dangerType
        self.interruptReason = interruptReason
        self.isPaused = isPaused
        self.canResume = canResume
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Recent downloads, newest first.
public struct DownloadList: Codable, Equatable, Sendable {
    public static let defaultLimit = 50

    public private(set) var records: [DownloadRecord]
    /// How many rows carry each id: an event for a GUID the list does not
    /// hold skips the scan of every row (Chromium replays its whole download
    /// history at launch, one new GUID after another).
    private var idCounts: [String: Int]
    /// The counts the bar and the tray show, kept per change.
    public private(set) var summary = Summary()
    /// Each row's place in list order, parallel to `records`: rows only go
    /// in at the front or the back, so a row keeps its key while others come
    /// and go, and keys ascend down the list.
    private var orders: [Int]
    private var frontOrder = 0
    private var backOrder = -1
    private var recent = RecentIndex()

    enum CodingKeys: String, CodingKey {
        case records
    }

    public init(records: [DownloadRecord] = []) {
        self.records = records
        idCounts = records.reduce(into: [:]) { $0[$1.id, default: 0] += 1 }
        orders = Array(records.indices)
        backOrder = records.count - 1
        rebuildIndexes()
    }

    /// `DownloadListFile.load(from:limit:)` passes a limit: only the first
    /// that many rows are decoded and the rest of the file is not read.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let limit = decoder.userInfo[.downloadRecordLimit] as? Int else {
            self.init(records: try container.decode([DownloadRecord].self, forKey: .records))
            return
        }
        var rows = try container.nestedUnkeyedContainer(forKey: .records)
        var records: [DownloadRecord] = []
        while records.count < limit, !rows.isAtEnd {
            records.append(try rows.decode(DownloadRecord.self))
        }
        self.init(records: records)
    }

    public static func == (lhs: DownloadList, rhs: DownloadList) -> Bool {
        lhs.records == rhs.records
    }

    private func index(of id: String) -> Int? {
        guard idCounts[id] != nil else { return nil }
        return records.firstIndex { $0.id == id }
    }

    private mutating func removeRecord(at index: Int) {
        let record = records.remove(at: index)
        let order = orders.remove(at: index)
        if let count = idCounts[record.id], count > 1 { idCounts[record.id] = count - 1 } else { idCounts[record.id] = nil }
        summary.add(record, -1)
        recent.remove(record, order: order)
        refillRecentIfShort()
    }

    private mutating func replaceRecords(_ kept: [DownloadRecord]) {
        self = DownloadList(records: kept)
    }

    private mutating func insertRecord(_ record: DownloadRecord, atFront: Bool) {
        let order: Int
        if atFront {
            frontOrder -= 1
            order = frontOrder
            records.insert(record, at: 0)
            orders.insert(order, at: 0)
        } else {
            backOrder += 1
            order = backOrder
            records.append(record)
            orders.append(order)
        }
        idCounts[record.id, default: 0] += 1
        summary.add(record)
        recent.add(record, order: order)
    }

    private mutating func replaceRecord(at index: Int, with record: DownloadRecord) {
        let old = records[index]
        records[index] = record
        summary.add(old, -1)
        summary.add(record)
        recent.remove(old, order: orders[index])
        recent.add(record, order: orders[index])
        refillRecentIfShort()
    }

    /// Counts and the quick view's rows from scratch (after a bulk edit).
    private mutating func rebuildIndexes() {
        summary = Summary()
        for record in records { summary.add(record) }
        recent.rebuild(records, orders: orders)
    }

    /// The quick view's index ran short of rows (its newest were removed or
    /// lost their file) while the list holds more: one pass refills it.
    private mutating func refillRecentIfShort() {
        if recent.isShort { recent.rebuild(records, orders: orders) }
    }

    public var activeCount: Int { summary.active }
    public var hasDangerous: Bool { summary.dangerous > 0 }

    /// Aggregate progress of the in-progress items with a known total (nil when none).
    public var activeFraction: Double? { summary.activeFraction }

    /// `RecentDownloads.latest(records, limit:)` from the kept index, without
    /// a pass over every row (the bar asks on every change).
    public func latest(_ limit: Int = RecentDownloads.limit) -> [DownloadRecord] {
        recent.latest(limit) ?? RecentDownloads.latest(records, limit: limit)
    }

    public func record(withID id: String) -> DownloadRecord? {
        index(of: id).map { records[$0] }
    }

    public enum Change: Equatable, Sendable {
        case inserted(String)
        case updated(String)
        case removed(String)
        case ignored
    }

    /// Reduces one engine event. Kind 5 drops the row; kind 0 for an item
    /// already finished is history the engine restored at launch, which merges
    /// into the persisted row (or is appended as an older entry).
    @discardableResult
    public mutating func apply(_ event: DownloadEvent, source: DownloadSource, now: Date) -> Change {
        guard !event.guid.isEmpty else { return .ignored }
        let index = index(of: event.guid)
        if event.kind == .removed {
            guard let index else { return .ignored }
            removeRecord(at: index)
            return .removed(event.guid)
        }
        if let index {
            var record = records[index]
            let elapsed = now.timeIntervalSince(record.updatedAt)
            if event.state == .inProgress, !event.isPaused, elapsed > 0.05, event.receivedBytes > record.receivedBytes {
                let sample = Double(event.receivedBytes - record.receivedBytes) / elapsed
                record.bytesPerSecond = record.bytesPerSecond.map { $0 * 0.7 + sample * 0.3 } ?? sample
            } else if event.state != .inProgress || event.isPaused {
                record.bytesPerSecond = nil
            }
            record.url = event.url.isEmpty ? record.url : event.url
            if !event.targetPath.isEmpty { record.targetPath = event.targetPath }
            if !event.mimeType.isEmpty { record.mimeType = event.mimeType }
            record.receivedBytes = event.receivedBytes
            record.totalBytes = event.totalBytes
            record.state = event.state
            record.dangerType = event.dangerType
            record.interruptReason = event.interruptReason
            record.isPaused = event.isPaused
            record.canResume = event.canResume
            if let endedAt = event.endedAt, event.state != .inProgress {
                record.updatedAt = endedAt
            } else if elapsed > 0.05 || event.state != .inProgress {
                record.updatedAt = now
            }
            replaceRecord(at: index, with: record)
            return .updated(event.guid)
        }
        let record = DownloadRecord(
            id: event.guid,
            source: source,
            url: event.url,
            targetPath: event.targetPath,
            mimeType: event.mimeType,
            receivedBytes: event.receivedBytes,
            totalBytes: event.totalBytes,
            state: event.state,
            dangerType: event.dangerType,
            interruptReason: event.interruptReason,
            isPaused: event.isPaused,
            canResume: event.canResume,
            startedAt: event.startedAt ?? now,
            updatedAt: event.state != .inProgress ? event.endedAt : nil
        )
        insertRecord(record, atFront: !(event.kind == .created && event.state != .inProgress))
        return .inserted(event.guid)
    }

    /// `apply` for each event in order, each at its own time, in one change
    /// to the list (one observation of it, not one per event).
    @discardableResult
    public mutating func apply<Events: Sequence>(_ events: Events) -> [Change]
    where Events.Element == (event: DownloadEvent, source: DownloadSource, now: Date) {
        events.map { apply($0.event, source: $0.source, now: $0.now) }
    }

    /// Appends history rows the engine keeps in its database only (archived
    /// rows, ABI 1.48) as older entries, newest first; a row the list already
    /// holds (a persisted one) keeps its place. Returns how many were added.
    @discardableResult
    public mutating func appendArchived(_ archived: [DownloadRecord]) -> Int {
        var added = 0
        records.reserveCapacity(records.count + archived.count)
        orders.reserveCapacity(records.count + archived.count)
        for record in archived where idCounts[record.id] == nil {
            insertRecord(record, atFront: false)
            added += 1
        }
        return added
    }

    /// Removes every row whose id is in `ids` in one pass.
    public mutating func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        replaceRecords(records.filter { !ids.contains($0.id) })
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        guard let index = index(of: id) else { return false }
        removeRecord(at: index)
        return true
    }

    /// Removes every finished row (complete, cancelled, failed); returns them.
    public mutating func clearFinished() -> [DownloadRecord] {
        let finished = records.filter { !$0.isActive }
        replaceRecords(records.filter(\.isActive))
        return finished
    }

    /// After a relaunch nothing is still transferring: a row persisted in
    /// progress becomes interrupted (Chromium re-reports its own items).
    public mutating func markStaleTransfersInterrupted() {
        for index in records.indices where records[index].state == .inProgress {
            records[index].state = .interrupted
            records[index].interruptReason = DownloadFormat.shutdownInterruptReason
            records[index].isPaused = false
            records[index].canResume = false
            records[index].bytesPerSecond = nil
        }
        rebuildIndexes()
    }

    /// Keeps the newest `limit` finished rows; in-progress rows always stay.
    public mutating func trim(to limit: Int = DownloadList.defaultLimit) {
        var kept = 0
        replaceRecords(records.filter { record in
            if record.isActive { return true }
            kept += 1
            return kept <= limit
        })
    }
}

extension DownloadList {
    /// Counts over every row, kept as rows change: the bar's badges and the
    /// tray's progress ring read these on every change, and with a long
    /// history a pass over the rows each time showed as stalls.
    public struct Summary: Equatable, Sendable {
        public private(set) var rows = 0
        public private(set) var active = 0
        /// In-progress rows with a danger warning (`DownloadRecord.isDangerous`).
        public private(set) var dangerous = 0
        /// Rows `hasFileOnDisk`: what the quick view can show.
        public private(set) var onDisk = 0
        private var activeWithTotal = 0
        private var activeTotalBytes: Int64 = 0
        private var activeReceivedBytes: Int64 = 0

        public init() {}

        public var finished: Int { rows - active }

        /// Aggregate progress of the in-progress rows with a known total (nil when none).
        public var activeFraction: Double? {
            guard activeWithTotal > 0 else { return nil }
            return Double(activeReceivedBytes) / Double(max(activeTotalBytes, 1))
        }

        /// Adds a row's share (`sign` 1), or takes it back (-1).
        mutating func add(_ record: DownloadRecord, _ sign: Int = 1) {
            rows += sign
            if record.hasFileOnDisk { onDisk += sign }
            guard record.isActive else { return }
            active += sign
            if record.isDangerous { dangerous += sign }
            if record.totalBytes > 0 {
                activeWithTotal += sign
                activeTotalBytes += Int64(sign) * record.totalBytes
                activeReceivedBytes += Int64(sign) * min(record.receivedBytes, record.totalBytes)
            }
        }
    }

    /// The newest rows with a file on disk, newest first and ties in list
    /// order, as `RecentDownloads.latest` picks them. It holds the true top
    /// `entries.count` of those rows (all of them when there are fewer than
    /// `capacity`), so a row that changes or arrives is placed or skipped
    /// against the last entry; only removing the newest rows can leave it
    /// short, and then one pass refills it.
    struct RecentIndex: Sendable {
        static let capacity = 4 * RecentDownloads.limit

        struct Entry: Sendable {
            var record: DownloadRecord
            var order: Int
        }

        private(set) var entries: [Entry] = []
        /// Rows `hasFileOnDisk`, indexed or not.
        private(set) var eligible = 0

        private static func precedes(_ record: DownloadRecord, _ order: Int, _ other: Entry) -> Bool {
            record.updatedAt > other.record.updatedAt || (record.updatedAt == other.record.updatedAt && order < other.order)
        }

        /// Fewer entries than the quick view shows while more rows qualify.
        var isShort: Bool { entries.count < RecentDownloads.limit && eligible > entries.count }

        func latest(_ limit: Int) -> [DownloadRecord]? {
            guard limit <= entries.count || entries.count == eligible else { return nil }
            return entries.prefix(max(limit, 0)).map(\.record)
        }

        mutating func add(_ record: DownloadRecord, order: Int) {
            guard record.hasFileOnDisk else { return }
            let holdsAll = entries.count == eligible
            eligible += 1
            if !holdsAll, let last = entries.last, !Self.precedes(record, order, last) { return }
            let place = entries.firstIndex { Self.precedes(record, order, $0) } ?? entries.endIndex
            entries.insert(Entry(record: record, order: order), at: place)
            if entries.count > Self.capacity { entries.removeLast() }
        }

        mutating func remove(_ record: DownloadRecord, order: Int) {
            guard record.hasFileOnDisk else { return }
            eligible -= 1
            if let index = entries.firstIndex(where: { $0.order == order }) { entries.remove(at: index) }
        }

        mutating func rebuild(_ records: [DownloadRecord], orders: [Int]) {
            entries = []
            eligible = 0
            for index in records.indices where records[index].hasFileOnDisk {
                eligible += 1
                let record = records[index], order = orders[index]
                if entries.count == Self.capacity, let last = entries.last, !Self.precedes(record, order, last) { continue }
                let place = entries.firstIndex { Self.precedes(record, order, $0) } ?? entries.endIndex
                entries.insert(Entry(record: record, order: order), at: place)
                if entries.count > Self.capacity { entries.removeLast() }
            }
        }
    }
}

extension CodingUserInfoKey {
    /// An `Int`: `DownloadList` decodes at most this many rows.
    public static let downloadRecordLimit = CodingUserInfoKey(rawValue: "net.rearc.downloadRecordLimit")!
}

public enum DownloadFormat {
    /// Chromium `DOWNLOAD_INTERRUPT_REASON_USER_SHUTDOWN`.
    public static let shutdownInterruptReason: UInt32 = 41

    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(count, 0), countStyle: .file)
    }

    public static func remaining(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        if seconds < 60 { return "\(max(Int(seconds.rounded()), 1)) s left" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded())) min left" }
        return "\(Int((seconds / 3600).rounded())) h left"
    }

    /// Chromium `DownloadInterruptReason` groups (file 1–19, network 20–29, server 30–39).
    public static func interruptReason(_ reason: UInt32) -> String {
        switch reason {
        case 3: return "Disk full"
        case 2: return "Permission denied"
        case 7: return "Virus detected"
        case 11, 12: return "Blocked"
        case 1 ..< 20: return "File error"
        case 21: return "Network timeout"
        case 22: return "Network disconnected"
        case 20 ..< 30: return "Network error"
        case 34, 36: return "Forbidden"
        case 30 ..< 40: return "Server error"
        case 40: return "Cancelled"
        case 41: return "Interrupted when ReArc quit"
        case 50: return "Browser crashed"
        default: return "Interrupted"
        }
    }

    /// A destination in `directory` for `suggestedName` that does not exist yet:
    /// "name.ext", then "name (1).ext", "name (2).ext", … (Chromium's uniquifier).
    public static func uniqueDestination(
        for suggestedName: String,
        in directory: URL,
        exists: (URL) -> Bool
    ) -> URL {
        let sanitized = sanitizedFileName(suggestedName)
        let base = (sanitized as NSString).deletingPathExtension
        let ext = (sanitized as NSString).pathExtension
        var candidate = directory.appendingPathComponent(sanitized)
        var counter = 1
        while exists(candidate) {
            let name = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    public static func sanitizedFileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "download" : cleaned
    }
}
