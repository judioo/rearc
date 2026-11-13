import Foundation

/// The last merged copy of one record, as this Mac knows it.
public struct SyncShadowRecord: Equatable, Codable, Sendable {
    public var payload: SyncRecordPayload
    public var serverTag: Data?
    /// Holds local writes the server has not confirmed yet (the offline queue).
    public var pending: Bool

    public init(payload: SyncRecordPayload, serverTag: Data? = nil, pending: Bool = false) {
        self.payload = payload
        self.serverTag = serverTag
        self.pending = pending
    }
}

/// Who set the sync toggle. Sync Sidebar is off until the person turns it
/// on in Settings: only `.user` with `enabled` syncs.
public enum SyncDecision: String, Codable, Sendable {
    /// The person: the switch in Settings, the sheet it shows when iCloud
    /// already holds a sidebar, or 605's and 608's "Turn On" prompt.
    case user
    /// Written by 605 and 608: on by default once a new install's onboarding
    /// finished. Never written now; such a file loads as off.
    case newInstall
    /// Written by 605 and 608 for a `REARC_DATA_DIR` launch. Loads as off.
    case isolated
}

/// Everything sync persists between launches (`sync-state.json` next to
/// `sidebar.json`): the user's toggle, the account it synced with, the zone
/// and change-token position, every record's merged state and the queue.
public struct SidebarSyncState: Equatable, Codable, Sendable {
    public static let version = 1

    public var version = SidebarSyncState.version
    /// The saved toggle. Sync runs only when it is on and `decision` is `.user`.
    public var enabled = false
    /// Who set `enabled`. Files from 602 have none.
    public var decision: SyncDecision?
    public var accountID: String?
    public var zoneReady = false
    /// Opaque transport position (a CKSyncEngine state serialization, or the
    /// fake server's change counter).
    public var transportToken: Data?
    /// True once a first sync settled (pristine adoption happens only before).
    public var joined = false
    public var records: [String: SyncShadowRecord] = [:]
    public var clock: SyncStamp?
    public var lastSyncedAt: Date?
    public var lastError: String?
    /// Profiles the person put in iCloud (Settings › Profiles, Put in
    /// iCloud…) before this Mac joined: the join stamps their records as
    /// this Mac's, over iCloud's deleted copies of them. Kept across
    /// `resetServerState` (a choice resets it before the join), dropped
    /// once joined and when sync is switched off.
    public var putInICloud: Set<Profile.ID>?

    public init() {}

    public var pendingCount: Int { records.values.filter(\.pending).count }

    /// Whether cycles run: switched on, by the person.
    public var isActive: Bool { enabled && decision == .user }

    /// Drops everything tied to the server account, keeping the toggle.
    /// The clock goes too: a stamp a crafted record pushed it to must not
    /// outlive the records (RC-0.1.0-602 T-03).
    public mutating func resetServerState() {
        accountID = nil
        zoneReady = false
        transportToken = nil
        joined = false
        records = [:]
        clock = nil
        lastSyncedAt = nil
    }

    /// Off unless the person switched it on. 602 (on with no decision) and
    /// 605/608 (on as a new install's default) switched sync on by
    /// themselves: those files load off, and what they merged is forgotten
    /// here (the sidebar and iCloud stay as they are), so turning it on
    /// again is a first join that asks first.
    mutating func normalize() {
        guard !isActive else { return }
        if enabled || decision == .newInstall || decision == .isolated { resetServerState() }
        putInICloud = nil
        enabled = false
        if decision != .user { decision = nil }
    }
}

public protocol SidebarSyncStateStoring: AnyObject {
    func load() -> SidebarSyncState
    func save(_ state: SidebarSyncState)
}

public final class SidebarSyncStateFile: SidebarSyncStateStoring {
    public static let fileName = "sync-state.json"
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Never on without the person's choice. No file, a file a build
    /// switched on by itself (`normalize`), or a file that does not fully
    /// decode load off; a later switch-on looks at iCloud first.
    public func load() -> SidebarSyncState {
        guard let data = try? Data(contentsOf: fileURL),
              var state = try? SyncCoding.decoder.decode(SidebarSyncState.self, from: data),
              state.version == SidebarSyncState.version else { return SidebarSyncState() }
        state.normalize()
        return state
    }

    public func save(_ state: SidebarSyncState) {
        guard let data = try? SyncCoding.encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic])
    }
}

public final class InMemorySyncStateStore: SidebarSyncStateStoring {
    public var state: SidebarSyncState
    public private(set) var saveCount = 0

    public init(_ state: SidebarSyncState = SidebarSyncState()) {
        self.state = state
    }

    public func load() -> SidebarSyncState { state }

    public func save(_ state: SidebarSyncState) {
        self.state = state
        saveCount += 1
    }
}
