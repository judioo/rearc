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

/// Everything sync persists between launches (`sync-state.json` next to
/// `sidebar.json`): the user's toggle, the account it synced with, the zone
/// and change-token position, every record's merged state and the queue.
public struct SidebarSyncState: Equatable, Codable, Sendable {
    public static let version = 1

    public var version = SidebarSyncState.version
    /// Missing state means the user never chose: sync by default. Existing
    /// files decode their saved Bool, including an explicit earlier off.
    public var enabled = true
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

    public init() {}

    public var pendingCount: Int { records.values.filter(\.pending).count }

    /// Drops everything tied to the server account, keeping the toggle.
    public mutating func resetServerState() {
        accountID = nil
        zoneReady = false
        transportToken = nil
        joined = false
        records = [:]
        lastSyncedAt = nil
    }
}

public protocol SidebarSyncStateStoring: AnyObject {
    func load() -> SidebarSyncState
    func save(_ state: SidebarSyncState)
}

public final class SidebarSyncStateFile: SidebarSyncStateStoring {
    public static let fileName = "sync-state.json"
    public let fileURL: URL
    /// The toggle when the file is missing: on, except in a `REARC_DATA_DIR`
    /// launch (benchmarks, manual tests), whose throwaway sidebar must not
    /// merge into the user's iCloud one unless sync is turned on there.
    public let defaultEnabled: Bool

    public init(fileURL: URL, defaultEnabled: Bool = !ShellDataLocation.isOverridden) {
        self.fileURL = fileURL
        self.defaultEnabled = defaultEnabled
    }

    public func load() -> SidebarSyncState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? SyncCoding.decoder.decode(SidebarSyncState.self, from: data),
              state.version == SidebarSyncState.version else {
            var state = SidebarSyncState()
            state.enabled = defaultEnabled
            return state
        }
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
