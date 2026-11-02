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
public final class CloudKitSyncEngine: SyncEngine, @unchecked Sendable {
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
    private var serverChangeToken: CKServerChangeToken?

    public init(container: CKContainer = CKContainer(identifier: CloudKitSyncAvailability.containerIdentifier)) {
        self.container = container
        self.zoneID = CKRecordZone.ID(zoneName: CloudKitSyncZone.zoneName, ownerName: CKCurrentUserDefaultName)
        if let reason = CloudKitSyncAvailability.unavailableReasonIfNeeded() {
            _status = .unavailable(reason: reason)
        } else {
            _status = .idleSynced
        }
    }

    public func start() {
        guard case .unavailable = status else {
            updateStatus(.idleSynced)
            return
        }
    }

    public func stop() {}

    public func push(_ entries: [SidebarJournalEntry]) {
        guard case .unavailable = status else {
            updateStatus(.syncing)
            let records = entries.flatMap { CloudKitRecordMapper.map(journalEntry: $0) }
            _ = records
            updateStatus(.idleSynced)
            return
        }
    }

    public func pull(since sequence: UInt64) async throws -> SyncPullResult {
        _ = sequence
        if case .unavailable = status {
            return SyncPullResult()
        }
        updateStatus(.syncing)
        defer { updateStatus(.idleSynced) }
        return SyncPullResult()
    }

    private func updateStatus(_ newValue: SyncEngineStatus) {
        lock.lock()
        _status = newValue
        lock.unlock()
        onStatusChange?(newValue)
    }
}
#endif
