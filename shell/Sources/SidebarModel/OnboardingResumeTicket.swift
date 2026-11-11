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
    /// Tells this ticket from an older one with the same contents.
    public var nonce: String

    public static let lifetime: TimeInterval = 30 * 60

    public init(dataDirectory: String?, bundlePath: String, name: String, colourIndex: Int, isRehearsal: Bool, written: Date = Date(),
                nonce: String = UUID().uuidString) {
        self.dataDirectory = dataDirectory
        self.bundlePath = bundlePath
        self.name = name
        self.colourIndex = colourIndex
        self.isRehearsal = isRehearsal
        self.written = written
        self.nonce = nonce
    }

    /// `~/Library/Caches/com.rearc.browser/onboarding-resume.json`; under
    /// XCTest a private temporary folder, so tests never touch the real one.
    public static var defaultURL: URL { folder.appendingPathComponent("onboarding-resume.json") }

    /// Beside it, one line per launch a ticket decided, and per relaunch.
    public static var logURL: URL { folder.appendingPathComponent("relaunch.log") }

    static let folder: URL = {
        // XCTest is loaded in a test process (`swift test` sets no environment variable for it).
        if NSClassFromString("XCTestCase") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("ReArcResumeTests-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.rearc.browser")
    }()

    /// Appends a timestamped line to `relaunch.log` (kept under 64 KB).
    public static func log(_ line: String, to url: URL = logURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = "\(ISO8601DateFormatter().string(from: Date())) pid \(ProcessInfo.processInfo.processIdentifier) \(line)\n"
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 64_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }

    public func write(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: url, options: [.atomic])
    }

    /// A fresh ticket from any copy of ReArc; a stale one is removed.
    public static func current(at url: URL = defaultURL, now: Date = Date()) -> OnboardingResumeTicket? {
        guard let data = try? Data(contentsOf: url),
              let ticket = try? JSONDecoder().decode(OnboardingResumeTicket.self, from: data) else { return nil }
        let age = now.timeIntervalSince(ticket.written)
        guard age >= 0, age < lifetime else {
            remove(at: url)
            return nil
        }
        return ticket
    }

    /// The ticket for this bundle, if one is fresh. Reading leaves it in place.
    public static func peek(at url: URL = defaultURL, bundlePath: String, now: Date = Date()) -> OnboardingResumeTicket? {
        current(at: url, now: now).flatMap { $0.bundlePath == bundlePath ? $0 : nil }
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

    /// What a launch does about a fresh ticket, decided before anything
    /// reads or writes the data folder.
    public enum LaunchAction: Equatable, Sendable {
        /// No ticket, or this launch already names its data folder.
        case none
        /// This copy's ticket: use its data folder (nil: the default one) and
        /// resume at the browser step.
        case adopt(dataDirectory: String?)
        /// Another copy's ticket (System Settings reopens by bundle id, and
        /// may pick this one): open that copy and quit, touching nothing.
        case handOff(bundlePath: String, dataDirectory: String?)
        /// The ticket's data folder is gone: forget it, launch as usual.
        case discard
    }

    public static func launchAction(environment: [String: String], bundlePath: String, ticket: OnboardingResumeTicket?,
                                    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> LaunchAction {
        guard let ticket else { return .none }
        if !(environment[ShellDataLocation.environmentKey]?.isEmpty ?? true) { return .none }
        if let dir = ticket.dataDirectory, !exists(dir) { return .discard }
        if ticket.bundlePath != bundlePath, exists(ticket.bundlePath) {
            return .handOff(bundlePath: ticket.bundlePath, dataDirectory: ticket.dataDirectory)
        }
        return .adopt(dataDirectory: ticket.dataDirectory)
    }
}
