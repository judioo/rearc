import Foundation

/// What Safe Browsing is actually doing, read from the engine's list stores rather than
/// from its configuration (security RC-0.1.0-544 F-02). Chromium keeps the downloaded
/// lists in `<user-data-dir>/Safe Browsing/*.store`; the first update runs 1 to 5 minutes
/// after launch and later ones about every 30 minutes. A key that Google refuses, or a list
/// protocol it does not serve, leaves the folder empty while the configuration says "on".
public enum SafeBrowsingStatus: Equatable, Sendable {
    /// The engine has no usable key: nothing is checked.
    case unavailable
    /// No lists yet and the engine has not been running long enough to expect them.
    case waitingForLists
    /// Lists are stored and were updated recently.
    case active(lastUpdate: Date)
    /// The engine has run long enough and still has no lists: nothing is being checked.
    case notUpdating
    /// Lists exist but have not been updated for a long time while the engine runs.
    case stale(lastUpdate: Date)

    public static let folderName = "Safe Browsing"
    public static let storeExtension = "store"
    /// Longer than Chromium's first-update window (60 to 300 s) plus a retry.
    public static let firstUpdateGrace: TimeInterval = 10 * 60
    /// Updates arrive about every 30 minutes; a day without one is a failure.
    public static let staleAfter: TimeInterval = 24 * 60 * 60

    /// `configured`: the engine says it can run Safe Browsing (`ReArcEngineSafeBrowsingAvailable`).
    /// `engineRunning`: how long the engine has been up.
    public static func evaluate(configured: Bool, userDataDir: URL?, engineRunning: TimeInterval, now: Date = Date(),
                                fileManager: FileManager = .default) -> SafeBrowsingStatus {
        guard configured else { return .unavailable }
        let newest = userDataDir.flatMap { newestStore(in: $0.appendingPathComponent(folderName, isDirectory: true), fileManager: fileManager) }
        guard let newest else { return engineRunning < firstUpdateGrace ? .waitingForLists : .notUpdating }
        if now.timeIntervalSince(newest) > staleAfter, engineRunning >= firstUpdateGrace { return .stale(lastUpdate: newest) }
        return .active(lastUpdate: newest)
    }

    /// The modification date of the newest non-empty list store, or nil when there is none.
    public static func newestStore(in folder: URL, fileManager: FileManager = .default) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return nil }
        return files.compactMap { url -> Date? in
            guard url.pathExtension == storeExtension, let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
            return values.contentModificationDate
        }.max()
    }

    public var isProtecting: Bool {
        if case .active = self { return true }
        return false
    }
}
