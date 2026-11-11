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

/// Who set the sync toggle (RC-0.1.0-602 T-01).
public enum SyncDecision: String, Codable, Sendable {
    /// The person: the "Sync your sidebar with iCloud?" prompt, Settings, or
    /// an explicit off saved by an earlier build.
    case user
    /// On by default once a new install's onboarding finished.
    case newInstall
    /// Off without asking: a `REARC_DATA_DIR` launch's throwaway sidebar.
    case isolated
}

/// Everything sync persists between launches (`sync-state.json` next to
/// `sidebar.json`): the user's toggle, the account it synced with, the zone
/// and change-token position, every record's merged state and the queue.
public struct SidebarSyncState: Equatable, Codable, Sendable {
    public static let version = 1

    public var version = SidebarSyncState.version
    /// The saved toggle. Sync runs only when it is on and `decision` is set.
    public var enabled = false
    /// Nil until someone chose. Files from 602 and earlier have none: 602
    /// wrote `enabled` on by default, so an on there is not a choice.
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

    public init() {}

    public var pendingCount: Int { records.values.filter(\.pending).count }

    /// Nobody chose yet: ask before the first cycle, and sync nothing until then.
    public var isUndecided: Bool { decision == nil }

    /// Whether cycles run: on, and on by someone's choice or a new install's default.
    public var isActive: Bool { enabled && decision != nil }

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
}

public protocol SidebarSyncStateStoring: AnyObject {
    func load() -> SidebarSyncState
    func save(_ state: SidebarSyncState)
}

public final class SidebarSyncStateFile: SidebarSyncStateStoring {
    public static let fileName = "sync-state.json"
    public let fileURL: URL
    /// False in a `REARC_DATA_DIR` launch (benchmarks, manual tests): a
    /// throwaway folder with no state file stays off and is never asked
    /// about, so it cannot merge into the user's iCloud sidebar unless sync
    /// is turned on there.
    public let asksWhenUndecided: Bool

    public init(fileURL: URL, asksWhenUndecided: Bool = !ShellDataLocation.isOverridden) {
        self.fileURL = fileURL
        self.asksWhenUndecided = asksWhenUndecided
    }

    /// Never on without a choice (RC-0.1.0-602 T-01). No file, or a file
    /// whose toggle was on without a recorded decision (602's default),
    /// is undecided and off. A file that does not fully decode keeps only
    /// a readable explicit choice, and otherwise reads as undecided.
    public func load() -> SidebarSyncState {
        guard let data = try? Data(contentsOf: fileURL) else { return Self.fresh(asks: asksWhenUndecided) }
        guard var state = try? SyncCoding.decoder.decode(SidebarSyncState.self, from: data),
              state.version == SidebarSyncState.version else {
            var state = Self.fresh(asks: asksWhenUndecided)
            if let toggle = try? SyncCoding.decoder.decode(Toggle.self, from: data), let saved = toggle.enabled {
                if !saved {
                    state.decision = .user
                } else if let decision = toggle.decision {
                    // A chosen on, with its records unreadable: the next cycle joins again.
                    state.enabled = true
                    state.decision = decision
                }
            }
            return state
        }
        if state.decision == nil {
            // Earlier builds saved an off only when the person chose it. An on
            // without a decision asks, in a REARC_DATA_DIR launch too: there
            // someone put the file in place (how the prompt is checked).
            if !state.enabled { state.decision = .user } else { state.enabled = false }
        }
        return state
    }

    private static func fresh(asks: Bool) -> SidebarSyncState {
        var state = SidebarSyncState()
        if !asks { state.decision = .isolated }
        return state
    }

    /// The two fields read on their own from a file the full state cannot decode.
    private struct Toggle: Decodable {
        var enabled: Bool?
        var decision: SyncDecision?
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
