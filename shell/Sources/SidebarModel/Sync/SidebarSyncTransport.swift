import Foundation

/// The iCloud account as the server sees it.
public enum SyncAccountStatus: Equatable, Sendable {
    /// Signed in; `userID` is stable per Apple Account (CloudKit user record name).
    case available(userID: String)
    case noAccount
    case restricted
    case temporarilyUnavailable
    case couldNotDetermine
}

/// Errors a transport reports, already reduced from CKError (CloudKitSyncTransport).
public enum SyncTransportError: Error, Equatable, Sendable {
    /// The save carried a stale server tag; `server` is the current server copy.
    case serverRecordChanged(server: SyncWireRecord)
    /// The zone is gone (first use on a new account, or reset elsewhere).
    case zoneNotFound
    /// The user deleted ReArc's iCloud data (Settings > Apple Account > iCloud).
    case userDeletedZone
    /// The change token is too old; fetch everything again.
    case changeTokenExpired
    /// The record named in a save or delete no longer exists on the server.
    case unknownItem
    case networkUnavailable
    case serviceUnavailable(retryAfter: TimeInterval?)
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExceeded
    case notAuthenticated
    case permissionFailure
    case other(String)

    /// Worth retrying later without anything changing on this Mac.
    public var isTransient: Bool {
        switch self {
        case .networkUnavailable, .serviceUnavailable, .rateLimited: return true
        default: return false
        }
    }

    public var retryAfter: TimeInterval? {
        switch self {
        case .serviceUnavailable(let after), .rateLimited(let after): return after
        default: return nil
        }
    }

    public var userMessage: String {
        switch self {
        case .serverRecordChanged: return "A change from another Mac is being merged."
        case .zoneNotFound: return "The iCloud sync zone is missing; it will be created again."
        case .userDeletedZone: return "ReArc's iCloud data was deleted. Turn sync on again to upload this Mac's sidebar."
        case .changeTokenExpired: return "Sync history expired; fetching everything again."
        case .unknownItem: return "A synced item no longer exists in iCloud."
        case .networkUnavailable: return "No network connection. Changes are queued."
        case .serviceUnavailable: return "iCloud is unavailable right now. Changes are queued."
        case .rateLimited: return "iCloud asked ReArc to slow down. Changes are queued."
        case .quotaExceeded: return "Your iCloud storage is full. Changes are queued until there is space."
        case .notAuthenticated: return "Sign in to iCloud to sync."
        case .permissionFailure: return "iCloud refused access to ReArc's container."
        case .other(let message): return message
        }
    }
}

public struct SyncFetchResult: Equatable, Sendable {
    public var changed: [SyncWireRecord]
    /// Records removed from the server for good (tombstone garbage collection).
    public var deleted: [String]
    /// Opaque position to pass to the next fetch (persisted by the coordinator).
    public var token: Data?
    public var moreComing: Bool

    public init(changed: [SyncWireRecord] = [], deleted: [String] = [], token: Data?, moreComing: Bool = false) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
        self.moreComing = moreComing
    }
}

public struct SyncModifyResult: Equatable, Sendable {
    /// Saved records with their new server tags.
    public var saved: [SyncWireRecord]
    public var deleted: [String]
    public var failures: [String: SyncTransportError]

    public init(saved: [SyncWireRecord] = [], deleted: [String] = [], failures: [String: SyncTransportError] = [:]) {
        self.saved = saved
        self.deleted = deleted
        self.failures = failures
    }
}

/// Everything sync needs from a server. CloudKit implements it on a private
/// database custom zone (CloudKitSyncTransport); tests use InMemorySyncServer.
/// Operation-wide failures throw `SyncTransportError`; per-record failures of
/// a modify come back in `SyncModifyResult.failures`.
public protocol SidebarSyncTransport: AnyObject {
    func accountStatus() async -> SyncAccountStatus
    /// Creates the sidebar zone when it does not exist yet.
    func prepareZone() async throws
    func fetchChanges(since token: Data?) async throws -> SyncFetchResult
    func modify(saving records: [SyncWireRecord], deleting names: [String]) async throws -> SyncModifyResult
    /// Forget server state tied to the current account (account switch, zone reset).
    func reset()
}

public extension SidebarSyncTransport {
    func reset() {}
}
