import Foundation

/// ReArc's version as people read it (engine/docs/RELEASE.md, "Versioning"):
/// `2026.1112.726`, the release's date and its build. Display only: ReArc
/// decides on the build (`UpdateBuild`), never on this text.
public enum ReArcVersion {
    /// Longer than any version ReArc writes; feed text past it is not one.
    public static let maximumLength = 24

    /// `version` as About shows it: as it is when it ends with its build
    /// (2026.1112.726), with the build after it when it does not
    /// (0.1.0 (677)), or nil when it is not one to four groups of digits
    /// (feed text that is not a version, which About never draws).
    public static func display(_ version: String, build: UpdateBuild?) -> String? {
        let version = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard version.count <= maximumLength, (1 ... 4).contains(parts.count),
              parts.allSatisfy({ (1 ... 9).contains($0.count) && $0.allSatisfy { $0.isASCII && $0.isNumber } })
        else { return nil }
        guard let build, parts.last.flatMap({ Int($0) }) != build.number else { return version }
        return "\(version) (\(build.number))"
    }
}

/// About ReArc's own question to the feed: Sparkle's probe for update
/// information (`AppUpdater`), at most once a minute, and only when the
/// notice holds no update already.
public struct UpdateInformationCheck: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case checking
        /// The feed has a newer build; the notice holds it.
        case found
        case upToDate
        case failed
    }

    public enum Result: Equatable, Sendable {
        case found
        case notFound
        case failed
    }

    /// How long a check stands before opening About asks the feed again.
    public static let minimumInterval: TimeInterval = 60

    public private(set) var state: State = .idle
    public private(set) var startedAt: Date?

    public init() {}

    /// About opened (`force`: its Try Again): ask the feed now?
    public func shouldStart(at now: Date, noticeHoldsUpdate: Bool, force: Bool = false) -> Bool {
        guard !noticeHoldsUpdate, state != .checking else { return false }
        if force { return true }
        guard let startedAt else { return true }
        let elapsed = now.timeIntervalSince(startedAt)
        // A clock set back is not a check a moment ago.
        return elapsed < 0 || elapsed >= Self.minimumInterval
    }

    /// Asked, or waiting for the update session already running to answer.
    public mutating func started(at now: Date) {
        state = .checking
        startedAt = now
    }

    /// An update session ended. Only the one About waits for changes the line.
    public mutating func finished(_ result: Result) {
        guard state == .checking else { return }
        state = switch result {
        case .found: .found
        case .notFound: .upToDate
        case .failed: .failed
        }
    }
}

/// The line under About ReArc's version: the latest build in the feed. Its
/// version is the feed item's, shown only through `ReArcVersion.display`;
/// the levels use the notice's words.
public struct AboutUpdateLine: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Restart and Update: the notice's install (`UpdateNoticeCenter`).
        case install
        /// Try Again after the notice's install failed: the notice's too.
        case retryInstall
        /// Try Again after the check failed: ask the feed again.
        case checkAgain

        public var title: String {
            switch self {
            case .install: UpdateNoticeText.install
            case .retryInstall, .checkAgain: UpdateNoticeText.retry
            }
        }
    }

    public var text: String
    /// When the feed was last read, or the install's progress or failure.
    public var detail: String?
    public var action: Action?

    public init(text: String, detail: String? = nil, action: Action? = nil) {
        self.text = text
        self.detail = detail
        self.action = action
    }

    public static let checking = "Checking…"
    public static let upToDate = "You have the latest version."
    public static let failed = "Couldn't check for updates."

    public static func level(_ urgency: UpdateUrgency) -> String {
        switch urgency {
        case .normal: "Update available"
        case .critical: "Critical update available"
        case .required: "Required update"
        }
    }

    /// "2026.1114.741", "0.1.0 (677)", "build 741" when the feed's version
    /// is not one, nil when neither is readable.
    public static func latest(_ update: AvailableUpdate) -> String? {
        if let version = ReArcVersion.display(update.version, build: update.build) { return version }
        return update.build.map { "build \($0.number)" }
    }

    /// nil: nothing to say yet (no updater, or About has not asked).
    public static func line(notice: UpdateNotice, check: UpdateInformationCheck.State, lastChecked: Date?,
                            formatDate: (Date) -> String = AboutUpdateLine.lastCheckedText) -> AboutUpdateLine? {
        if let update = notice.update, notice.phase != .idle {
            let level = level(update.urgency)
            let text = latest(update).map { "Latest: \($0) — \(level)" } ?? level
            switch notice.phase {
            case .available, .ready:
                return AboutUpdateLine(text: text, action: .install)
            case let .failed(failure):
                return AboutUpdateLine(text: text, detail: UpdateNoticeText.failure(failure), action: .retryInstall)
            case .downloading, .extracting, .installing, .idle:
                return AboutUpdateLine(text: text, detail: UpdateNoticeText.status(notice.phase))
            }
        }
        switch check {
        case .idle, .found: return nil
        case .checking: return AboutUpdateLine(text: checking)
        case .upToDate: return AboutUpdateLine(text: upToDate, detail: lastChecked.map { "Last checked \(formatDate($0))" })
        case .failed: return AboutUpdateLine(text: failed, action: .checkAgain)
        }
    }

    /// "today at 2:05 PM", "Nov 11, 2026 at 2:05 PM", in the person's locale.
    public static func lastCheckedText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatter.formattingContext = .middleOfSentence
        return formatter.string(from: date)
    }
}
