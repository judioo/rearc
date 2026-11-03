import Foundation

/// Why a tab entered the archive (Arc `ArchivedItem.reason`, DATA-SCHEMA §3.1).
public enum TabArchiveReason: String, Codable, Sendable {
    case manual
    case auto
}

/// A closed or auto-archived sidebar tab, kept whole so restore is lossless
/// (Arc `StorableArchiveItems.json` keeps the full `SidebarItem`).
public struct ArchivedTabRecord: Identifiable, Equatable, Codable {
    /// The archived tab's id (restore reuses it).
    public var id: UUID { tab.id }
    public var tab: Tab
    /// Source space (Arc `source.space`); nil if it no longer exists.
    public var spaceID: Space.ID?
    public var archivedAt: Date
    public var reason: TabArchiveReason

    public init(tab: Tab, spaceID: Space.ID?, archivedAt: Date, reason: TabArchiveReason) {
        self.tab = tab
        self.spaceID = spaceID
        self.archivedAt = archivedAt
        self.reason = reason
    }
}

/// How long a Today tab may sit unselected before it is archived
/// (Arc `autoArchiveTimeThresholdsPerProfile`, PROFILES §1.1).
public enum AutoArchiveThreshold: String, Codable, CaseIterable, Sendable {
    case twelveHours
    case oneDay
    case sevenDays
    case thirtyDays

    /// Arc's default.
    public static let `default`: AutoArchiveThreshold = .twelveHours

    public var interval: TimeInterval {
        switch self {
        case .twelveHours: return 12 * 3600
        case .oneDay: return 24 * 3600
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        }
    }

    public var title: String {
        switch self {
        case .twelveHours: return "12 Hours"
        case .oneDay: return "24 Hours"
        case .sevenDays: return "7 Days"
        case .thirtyDays: return "30 Days"
        }
    }
}

public enum TabArchivePolicy {
    /// Arc data shows a rolling ~59-day window (DATA-SCHEMA §3.1).
    public static let retention: TimeInterval = 60 * 86_400
    public static let capacity = 2000

    /// Drops records older than `retention` and keeps the newest `capacity`.
    public static func pruned(_ records: [ArchivedTabRecord], now: Date) -> [ArchivedTabRecord] {
        let cutoff = now.addingTimeInterval(-retention)
        let kept = records.filter { $0.archivedAt >= cutoff }
        guard kept.count > capacity else { return kept }
        return Array(kept.sorted { $0.archivedAt > $1.archivedAt }.prefix(capacity))
    }

    /// Archive view time buckets (Arc `archive_ui_time_bucket`).
    public enum Bucket: Int, CaseIterable, Comparable, Sendable {
        case today, yesterday, lastWeek, lastMonth, older

        public var title: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .lastWeek: return "Last 7 Days"
            case .lastMonth: return "Last 30 Days"
            case .older: return "Older"
            }
        }

        public static func < (lhs: Bucket, rhs: Bucket) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public static func bucket(for date: Date, now: Date, calendar: Calendar = .current) -> Bucket {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        let age = now.timeIntervalSince(date)
        if age < 7 * 86_400 { return .lastWeek }
        if age < 30 * 86_400 { return .lastMonth }
        return .older
    }

    /// Newest first, grouped by bucket, filtered by a case-insensitive title/URL query.
    public static func grouped(
        _ records: [ArchivedTabRecord],
        matching query: String = "",
        now: Date,
        calendar: Calendar = .current
    ) -> [(bucket: Bucket, records: [ArchivedTabRecord])] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = records
            .filter { record in
                needle.isEmpty
                    || record.tab.displayTitle.lowercased().contains(needle)
                    || record.tab.url.absoluteString.lowercased().contains(needle)
            }
            .sorted { $0.archivedAt > $1.archivedAt }
        let byBucket = Dictionary(grouping: matching) { bucket(for: $0.archivedAt, now: now, calendar: calendar) }
        return Bucket.allCases.compactMap { bucket in
            byBucket[bucket].map { (bucket, $0) }
        }
    }
}
