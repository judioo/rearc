import Foundation

/// Where an onboarding left off when ReArc quits for a privacy permission:
/// System Settings' "Quit & Reopen" after Full Disk Access, or the
/// onboarding's own Relaunch ReArc. The next launch of the same bundle
/// within `lifetime` goes straight back to the browser step (Act 2) with
/// Act 1's name and colour, instead of the sunrise.
///
/// It lives in the user's Caches, not the data folder: a reopen from System
/// Settings carries no `REARC_DATA_DIR`, so the ticket also remembers it.
public struct OnboardingResumeTicket: Codable, Equatable, Sendable {
    /// The launch's `REARC_DATA_DIR`, if it had one.
    public var dataDirectory: String?
    /// The bundle that wrote it; another ReArc (the installed one) ignores it.
    public var bundlePath: String
    public var name: String
    public var colourIndex: Int
    /// A rehearsal (`--onboarding` on an existing install) resumes as one.
    public var isRehearsal: Bool
    public var written: Date

    public static let lifetime: TimeInterval = 30 * 60

    public init(dataDirectory: String?, bundlePath: String, name: String, colourIndex: Int, isRehearsal: Bool, written: Date = Date()) {
        self.dataDirectory = dataDirectory
        self.bundlePath = bundlePath
        self.name = name
        self.colourIndex = colourIndex
        self.isRehearsal = isRehearsal
        self.written = written
    }

    /// `~/Library/Caches/com.rearc.browser/onboarding-resume.json`.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.rearc.browser/onboarding-resume.json")
    }

    public func write(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: [.atomic])
    }

    /// The ticket for this bundle, if one is fresh. Reading leaves it in place.
    public static func peek(at url: URL = defaultURL, bundlePath: String, now: Date = Date()) -> OnboardingResumeTicket? {
        guard let data = try? Data(contentsOf: url),
              let ticket = try? JSONDecoder().decode(OnboardingResumeTicket.self, from: data) else { return nil }
        let age = now.timeIntervalSince(ticket.written)
        guard age >= 0, age < lifetime else {
            remove(at: url)
            return nil
        }
        return ticket.bundlePath == bundlePath ? ticket : nil
    }

    /// The ticket for this bundle, removed so it resumes once.
    public static func take(at url: URL = defaultURL, bundlePath: String, now: Date = Date()) -> OnboardingResumeTicket? {
        guard let ticket = peek(at: url, bundlePath: bundlePath, now: now) else { return nil }
        remove(at: url)
        return ticket
    }

    public static func remove(at url: URL = defaultURL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The data folder a launch without `REARC_DATA_DIR` should use: the
    /// ticket's, so a reopen from System Settings lands on the same data.
    public static func dataDirectory(environment: [String: String], ticket: OnboardingResumeTicket?) -> String? {
        guard environment[ShellDataLocation.environmentKey]?.isEmpty ?? true else { return nil }
        return ticket?.dataDirectory
    }
}
