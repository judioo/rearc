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
        canResume: Bool = false
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
    }
}

/// Recent downloads, newest first.
public struct DownloadList: Codable, Equatable, Sendable {
    public static let defaultLimit = 50

    public private(set) var records: [DownloadRecord]

    public init(records: [DownloadRecord] = []) {
        self.records = records
    }

    public var activeCount: Int { records.filter(\.isActive).count }
    public var hasDangerous: Bool { records.contains(where: \.isDangerous) }

    /// Aggregate progress of the in-progress items with a known total (nil when none).
    public var activeFraction: Double? {
        let active = records.filter { $0.isActive && $0.totalBytes > 0 }
        guard !active.isEmpty else { return nil }
        let total = active.reduce(Int64(0)) { $0 + $1.totalBytes }
        let received = active.reduce(Int64(0)) { $0 + min($1.receivedBytes, $1.totalBytes) }
        return Double(received) / Double(max(total, 1))
    }

    public func record(withID id: String) -> DownloadRecord? {
        records.first { $0.id == id }
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
        let index = records.firstIndex { $0.id == event.guid }
        if event.kind == .removed {
            guard let index else { return .ignored }
            records.remove(at: index)
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
            if elapsed > 0.05 || event.state != .inProgress { record.updatedAt = now }
            records[index] = record
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
            startedAt: now
        )
        if event.kind == .created, event.state != .inProgress {
            records.append(record)
        } else {
            records.insert(record, at: 0)
        }
        return .inserted(event.guid)
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        records.remove(at: index)
        return true
    }

    /// Removes every finished row (complete, cancelled, failed); returns them.
    public mutating func clearFinished() -> [DownloadRecord] {
        let finished = records.filter { !$0.isActive }
        records.removeAll { !$0.isActive }
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
    }

    /// Keeps the newest `limit` finished rows; in-progress rows always stay.
    public mutating func trim(to limit: Int = DownloadList.defaultLimit) {
        var kept = 0
        records = records.filter { record in
            if record.isActive { return true }
            kept += 1
            return kept <= limit
        }
    }
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
