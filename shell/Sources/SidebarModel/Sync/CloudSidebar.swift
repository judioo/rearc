import Foundation

/// Reads the sidebar zone without changing anything in iCloud: no zone is
/// created, nothing is saved, no subscription is made. Turning Sync Sidebar
/// on looks first, so the person is told what iCloud holds before anything
/// is downloaded into the sidebar or uploaded (docs/SYNC-RUNTIME.md).
public protocol SidebarCloudReading: AnyObject {
    func accountStatus() async -> SyncAccountStatus
    /// Every live record in the sidebar zone; nil when the zone does not exist.
    func readAllRecords() async throws -> [SyncWireRecord]?
    /// Deletes the sidebar zone and everything in it.
    func deleteZone() async throws
}

/// What iCloud holds, in the numbers Settings and the turn-on sheet show.
public struct CloudSidebarSummary: Equatable, Sendable {
    public var spaces: Int
    public var pinnedTabs: Int
    public var favorites: Int
    /// The newest edit any Mac made to it.
    public var lastUpdated: Date?

    public init(spaces: Int, pinnedTabs: Int, favorites: Int, lastUpdated: Date?) {
        self.spaces = spaces
        self.pinnedTabs = pinnedTabs
        self.favorites = favorites
        self.lastUpdated = lastUpdated
    }

    /// "14 spaces, 210 pinned tabs and 12 favorites".
    public var counts: String {
        func part(_ n: Int, _ one: String, _ many: String) -> String { "\(n.formatted()) \(n == 1 ? one : many)" }
        let parts = [part(spaces, "space", "spaces"), part(pinnedTabs, "pinned tab", "pinned tabs"), part(favorites, "favorite", "favorites")]
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    /// "last updated 3 days ago", or nil when no edit time is known.
    public func updatedText(now: Date = Date()) -> String? {
        guard let lastUpdated else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "last updated " + formatter.localizedString(for: min(lastUpdated, now), relativeTo: now)
    }
}

/// A sidebar found in iCloud, held aside: nothing of it is in the store
/// until the person chooses to use or merge it.
public struct CloudSidebarFound: Equatable, Sendable {
    public var accountID: String
    /// Plausible, well-formed records only, at most `SidebarSyncCoordinator.maxRecords`
    /// (the T-03 rules a merge applies).
    public var records: [SyncWireRecord]
    public var summary: CloudSidebarSummary
}

/// The result of looking at iCloud.
public enum CloudSidebarDetection: Equatable, Sendable {
    /// Signed in, and iCloud holds no ReArc sidebar (no zone, or no live space).
    case empty(accountID: String)
    case found(CloudSidebarFound)
    /// Not signed in to iCloud.
    case signedOut(String)
    /// iCloud could not be reached, did not answer in time, or refused.
    case unreachable(String)
    /// This build cannot use iCloud.
    case unavailable(String)

    public var found: CloudSidebarFound? {
        if case .found(let found) = self { return found }
        return nil
    }
}

/// What to do with a sidebar already in iCloud, when sync is turned on or
/// from Settings › Account.
public enum CloudSidebarChoice: String, Equatable, Sendable, CaseIterable {
    /// iCloud's sidebar replaces this Mac's (the app backs this Mac's up first).
    case useCloud
    /// This Mac's sidebar replaces iCloud's; other Macs get this one's.
    case replaceCloud
    /// Both together: the first-join merge, matching spaces imported from the same Arc space.
    case merge
}

extension CloudSidebarSummary {
    /// Counts what the records would show, through the same projection sync
    /// applies (orphans rescued, unreadable rows left out), on a scratch store.
    @MainActor
    static func of(_ records: [String: SyncRecordPayload]) -> CloudSidebarSummary {
        let scratch = SidebarStore(mutationJournal: SidebarMutationJournal(deviceID: UUID()))
        let base = scratch.makeSnapshot()
        scratch.applySnapshot(SidebarSyncProjection.apply(records, onto: base))
        let synced = Set(records.filter { $0.value.isAlive && $0.value.kind == .space }.keys)
        let spaces = scratch.spaces.filter { synced.contains(SyncRecordKind.space.recordName(for: $0.id)) }
        let pinned = spaces.reduce(0) { $0 + SidebarTree.leaves(scratch.content(for: $1.id).pinned).count }
        let favorites = scratch.profiles.reduce(0) { $0 + scratch.favorites(in: $1.id).count }
        let newest = records.values.compactMap(\.latestStamp).map(\.millis).max()
        return CloudSidebarSummary(spaces: spaces.count, pinnedTabs: pinned, favorites: favorites,
                                   lastUpdated: newest.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }
}
