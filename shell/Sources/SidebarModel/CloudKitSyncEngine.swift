import Foundation

#if canImport(CloudKit)
import CloudKit
#endif

public enum CloudKitSyncAvailability {
    public static let containerIdentifier = "iCloud.net.rearc.sidebar"

    /// True when the host bundle declares an iCloud container (signed app / Xcode run).
    public static var hasCloudKitEntitlement: Bool {
        guard let ids = Bundle.main.object(forInfoDictionaryKey: "com.apple.developer.icloud-container-identifiers") as? [String] else {
            return false
        }
        return ids.contains(containerIdentifier)
    }

    public static func unavailableReasonIfNeeded() -> String? {
        #if canImport(CloudKit)
        guard hasCloudKitEntitlement else {
            return "iCloud container entitlement missing (SwiftPM dev builds need manual signing — see shell/README.md Sync section)."
        }
        return nil
        #else
        return "CloudKit framework unavailable on this platform."
        #endif
    }

    public static func makeEngine() -> SyncEngine {
        if let reason = unavailableReasonIfNeeded() {
            return UnavailableSyncEngine(reason: reason)
        }
        #if canImport(CloudKit)
        return CloudKitSyncEngine()
        #else
        return UnavailableSyncEngine(reason: "CloudKit not available.")
        #endif
    }
}

#if canImport(CloudKit)
/// Not a sync engine yet: no zone, no upload, no fetch. It maps journal
/// entries to CloudKit records (so the mapping stays exercised) and discards
/// them. It always reports `notImplementedStatus`, never "syncing" or "up to
/// date", because nothing leaves this Mac (PARITY-AUDIT "Sync status
/// indicator reflects reality").
public final class CloudKitSyncEngine: SyncEngine, @unchecked Sendable {
    public static let notImplementedReason = "CloudKit upload is not implemented; sidebar changes stay on this Mac"
    public static let notImplementedStatus = SyncEngineStatus.unavailable(reason: notImplementedReason)

    private let lock = NSLock()
    private var _status: SyncEngineStatus
    public var onStatusChange: (@Sendable (SyncEngineStatus) -> Void)?

    public var status: SyncEngineStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    private let container: CKContainer
    private let zoneID: CKRecordZone.ID

    public init(container: CKContainer = CKContainer(identifier: CloudKitSyncAvailability.containerIdentifier)) {
        self.container = container
        self.zoneID = CKRecordZone.ID(zoneName: CloudKitSyncZone.zoneName, ownerName: CKCurrentUserDefaultName)
        if let reason = CloudKitSyncAvailability.unavailableReasonIfNeeded() {
            _status = .unavailable(reason: reason)
        } else {
            _status = Self.notImplementedStatus
        }
    }

    public func start() {
        onStatusChange?(status)
    }

    public func stop() {}

    public func push(_ entries: [SidebarJournalEntry]) {
        _ = entries.flatMap { CloudKitRecordMapper.map(journalEntry: $0) }
    }

    public func pull(since sequence: UInt64) async throws -> SyncPullResult {
        _ = sequence
        return SyncPullResult()
    }
}
#endif
