import Foundation

/// Where an onboarding left off when ReArc quits for a privacy permission:
/// System Settings' "Quit & Reopen" after Full Disk Access, or the
/// onboarding's own Relaunch ReArc. The next launch of the same bundle
/// within `lifetime` goes straight back to the browser step (Act 2) with
/// Act 1's name and colour, instead of the sunrise.
///
/// It lives in the user's Caches, not the data folder: a reopen from System
/// Settings carries no `REARC_DATA_DIR`, so the ticket also remembers it.
///
/// Any process running as the person can write that file, so a ticket
/// steers nothing else (RC-0.1.0-602 T-06): it is read only when it is a
/// plain file of theirs that only they can read, and only by the bundle that
/// wrote it (never another app). A shipped bundle accepts no data folder
/// from it; elsewhere the folder must hold the ticket's nonce, which
/// `bindDataDirectory` wrote there. It expires after `lifetime` and is
/// removed on the launch it resumes, or on any launch that runs no onboarding.
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

    /// Appends a timestamped line to `relaunch.log` (kept under 64 KB). The
    /// log is never followed through a symlink, and the line loses its control
    /// characters: parts of it come from the environment (RC-0.1.0-602 T-09).
    public static func log(_ line: String, to url: URL = logURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let clean = String(String.UnicodeScalarView(line.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }).prefix(1000))
        let text = "\(ISO8601DateFormatter().string(from: Date())) pid \(ProcessInfo.processInfo.processIdentifier) \(clean)\n"
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size > 64_000 {
            unlink(url.path)
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return }
        _ = Array(text.utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    /// Owner-only, so only the person (and what runs as them) can read or replace it.
    public func write(to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: [.atomic])
        chmod(url.path, 0o600)
    }

    /// The marker beside a non-default data folder's files: the ticket's
    /// nonce, which a launch must find there before it adopts the folder.
    public static let markerName = ".rearc-onboarding-resume"

    /// Records that ReArc itself is onboarding in `directory` under this ticket.
    public func bindDataDirectory(_ directory: URL) {
        let marker = directory.appendingPathComponent(Self.markerName)
        try? Data(nonce.utf8).write(to: marker, options: [.atomic])
        chmod(marker.path, 0o600)
    }

    /// The nonce a data folder was bound to, from a plain owner-only file of this user's.
    public static func boundNonce(in directory: String) -> String? {
        let path = (directory as NSString).appendingPathComponent(markerName)
        guard isPrivateFile(path), let data = FileManager.default.contents(atPath: path), data.count < 256 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A regular file (not a link) owned by this user, with no group or other access.
    static func isPrivateFile(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == getuid() && (info.st_mode & 0o077) == 0
    }

    /// A fresh ticket from any copy of ReArc; a stale or unsafe one is removed.
    public static func current(at url: URL = defaultURL, now: Date = Date()) -> OnboardingResumeTicket? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        guard isPrivateFile(url.path) else {
            remove(at: url)
            return nil
        }
        guard let data = try? Data(contentsOf: url), data.count < 64_000,
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
        /// No ticket, another copy's ticket (left for that copy), or this
        /// launch already names its data folder.
        case none
        /// This copy's ticket: use its data folder (nil: the default one) and
        /// resume at the browser step.
        case adopt(dataDirectory: String?)
        /// The ticket cannot be honoured (its folder is gone, or not one this
        /// ReArc bound to it): forget it, launch as usual.
        case discard
    }

    /// Never another bundle: System Settings may reopen a different copy of
    /// ReArc by bundle id, and that copy simply launches as usual.
    public static func launchAction(environment: [String: String], bundlePath: String, ticket: OnboardingResumeTicket?,
                                    shipped: Bool = ShippedBuild.current,
                                    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                    boundNonce: (String) -> String? = OnboardingResumeTicket.boundNonce(in:)) -> LaunchAction {
        guard let ticket else { return .none }
        if !shipped, !(environment[ShellDataLocation.environmentKey]?.isEmpty ?? true) { return .none }
        guard ticket.bundlePath == bundlePath else { return .none }
        guard let dir = ticket.dataDirectory else { return .adopt(dataDirectory: nil) }
        // A shipped bundle always runs on the person's own folder (T-04).
        if shipped || !exists(dir) || boundNonce(dir) != ticket.nonce { return .discard }
        return .adopt(dataDirectory: dir)
    }
}
