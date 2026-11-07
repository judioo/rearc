import Foundation

public enum LibraryDateFilter: String, CaseIterable, Sendable {
    case all, today, lastSevenDays, lastThirtyDays

    public var title: String {
        switch self {
        case .all: return "Any Date"
        case .today: return "Today"
        case .lastSevenDays: return "Last 7 Days"
        case .lastThirtyDays: return "Last 30 Days"
        }
    }

    public func includes(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard self != .all else { return true }
        let days = self == .today ? 0 : self == .lastSevenDays ? 6 : 29
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)) ?? now
        return date >= start && date <= now
    }
}

public enum LibraryDownloadState: String, CaseIterable, Sendable {
    case all, inProgress, complete, failed, dangerous

    public var title: String {
        switch self {
        case .all: return "All States"
        case .inProgress: return "In Progress"
        case .complete: return "Complete"
        case .failed: return "Failed or Cancelled"
        case .dangerous: return "Dangerous"
        }
    }
}

public enum LibraryDownloadType: String, CaseIterable, Sendable {
    case all, documents, images, archives, apps

    public var title: String {
        switch self {
        case .all: return "All Types"
        case .documents: return "Documents"
        case .images: return "Images"
        case .archives: return "Archives"
        case .apps: return "Apps"
        }
    }

    public func includes(_ record: DownloadRecord) -> Bool {
        guard self != .all else { return true }
        let ext = (record.fileName as NSString).pathExtension.lowercased()
        let mime = record.mimeType.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        switch self {
        case .all: return true
        case .documents:
            return mime.hasPrefix("text/") || ["application/pdf", "application/msword", "application/rtf"].contains(mime)
                || mime.hasPrefix("application/vnd.openxmlformats-officedocument.") || mime.hasPrefix("application/vnd.oasis.opendocument.")
                || ["pdf", "txt", "md", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "pages", "numbers", "key", "odt", "ods", "odp"].contains(ext)
        case .images:
            return mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "svg", "tiff", "bmp", "ico"].contains(ext)
        case .archives:
            return ["application/zip", "application/gzip", "application/x-tar", "application/x-7z-compressed", "application/x-rar-compressed", "application/vnd.rar"].contains(mime)
                || ["zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar"].contains(ext)
        case .apps:
            return ["application/x-apple-diskimage", "application/vnd.apple.installer+xml", "application/x-msdownload", "application/vnd.android.package-archive"].contains(mime)
                || ["app", "dmg", "pkg", "exe", "msi", "apk", "deb", "rpm"].contains(ext)
        }
    }
}

/// Library filters survive page changes in the owning controller, without
/// touching the tray's recent rows or the sidebar's list.
public struct LibraryDownloadFilter: Equatable, Sendable {
    public var state: LibraryDownloadState = .all
    public var type: LibraryDownloadType = .all
    public var date: LibraryDateFilter = .all

    public init() {}
    public var isActive: Bool { state != .all || type != .all || date != .all }

    public func includes(_ record: DownloadRecord, warning: DownloadWarning? = nil, now: Date, calendar: Calendar = .current) -> Bool {
        switch state {
        case .all: break
        case .inProgress: guard record.state == .inProgress else { return false }
        case .complete: guard record.state == .complete else { return false }
        case .failed: guard record.state == .interrupted || record.state == .cancelled else { return false }
        case .dangerous:
            if let warning {
                guard warning.offersDecision else { return false }
            } else if case .warning = DownloadDanger(dangerType: record.dangerType) {
                break
            } else {
                return false
            }
        }
        return type.includes(record) && date.includes(record.startedAt, now: now, calendar: calendar)
    }
}

public struct LibraryArchiveFilter: Equatable, Sendable {
    /// Nil includes spaces that have since been deleted as well.
    public var spaceID: Space.ID?
    public var date: LibraryDateFilter = .all

    public init() {}
    public var isActive: Bool { spaceID != nil || date != .all }

    public func includes(_ record: ArchivedTabRecord, now: Date, calendar: Calendar = .current) -> Bool {
        (spaceID == nil || record.spaceID == spaceID) && date.includes(record.archivedAt, now: now, calendar: calendar)
    }
}
