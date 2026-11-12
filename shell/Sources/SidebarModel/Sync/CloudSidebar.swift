import Foundation

/// Reads the sidebar zone without changing anything in iCloud: no zone is
/// created, nothing is saved, no subscription is made. Turning Sync Sidebar
/// on looks first, so the person is told what iCloud holds before anything
/// is downloaded into the sidebar or uploaded (docs/SYNC-RUNTIME.md).
public protocol SidebarCloudReading: AnyObject, Sendable {
    func accountStatus() async -> SyncAccountStatus
    /// Every live record in the sidebar zone; nil when the zone does not exist.
    /// `progress` gets the running count after each batch.
    func readAllRecords(progress: @escaping @Sendable (Int) -> Void) async throws -> [SyncWireRecord]?
    /// Deletes the sidebar zone and everything in it.
    func deleteZone() async throws
}

/// Changes records already in the sidebar zone outside CKSyncEngine, so it
/// works with Sync Sidebar off: no zone is created, no record is added, and
/// this Mac's sync state is not involved (deleting one profile from iCloud).
public protocol SidebarCloudEditing: SidebarCloudReading {
    /// New versions of records a look read: all of them or none, each only
    /// while it is unchanged in iCloud since that read (its `serverTag`).
    func saveExisting(_ records: [SyncWireRecord]) async throws -> SyncModifyResult
}

/// What iCloud holds, in the numbers Settings and the turn-on sheet show.
public struct CloudSidebarSummary: Equatable, Sendable {
    public var spaces: Int
    public var pinnedTabs: Int
    public var favorites: Int
    /// The newest edit any Mac made to it.
    public var lastUpdated: Date?
    /// Of `spaces`, empty or same-profile copies of one Arc space (608 and
    /// earlier), which using or merging it tidies away.
    public var arcCopies: Int

    public init(spaces: Int, pinnedTabs: Int, favorites: Int, lastUpdated: Date?, arcCopies: Int = 0) {
        self.spaces = spaces
        self.pinnedTabs = pinnedTabs
        self.favorites = favorites
        self.lastUpdated = lastUpdated
        self.arcCopies = arcCopies
    }

    /// "14 spaces, 210 pinned tabs and 12 favorites", with "(26 of them
    /// copies of the same Arc spaces)" after the spaces when there are some.
    public var counts: String {
        func part(_ n: Int, _ one: String, _ many: String) -> String { "\(n.formatted()) \(n == 1 ? one : many)" }
        var spacesPart = part(spaces, "space", "spaces")
        if arcCopies > 0 {
            spacesPart += " (\(arcCopies.formatted()) of them \(arcCopies == 1 ? "a copy" : "copies") of the same Arc spaces)"
        }
        let parts = [spacesPart, part(pinnedTabs, "pinned tab", "pinned tabs"), part(favorites, "favorite", "favorites")]
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
    /// Its profiles, by name (Settings › Profiles).
    public var profiles: [CloudProfile] = []
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

/// How a look at iCloud is going, while it runs.
public enum CloudLookProgress: Equatable, Sendable {
    /// Asking iCloud which account is signed in.
    case account
    /// Records read so far.
    case records(Int)
    /// Nothing new for `SidebarSyncCoordinator.stallTimeout`: the look carries
    /// on, and its result still counts when it comes.
    case stalled(String)
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
        CloudProjection(records).summary
    }
}
