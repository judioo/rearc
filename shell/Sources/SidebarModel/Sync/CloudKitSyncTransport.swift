#if canImport(CloudKit)
import CloudKit
import Foundation

/// `SidebarSyncTransport` on CloudKit: the private database, custom zone
/// `com.rearc.sidebar.graph.v1`, driven by CKSyncEngine (macOS 14) with
/// automatic sync off so `SidebarSyncCoordinator` decides when to fetch and
/// send. CKSyncEngine keeps the change tokens; its state serialization is the
/// opaque token the coordinator persists.
///
/// Each record stores the stamped payload (`SyncRecordPayload` JSON) in
/// `encryptedValues["payload"]`, which CloudKit encrypts end to end with keys
/// held in the user's iCloud Keychain; `isDeleted`, `schemaVersion` and
/// `clientTimestamp` stay plain for garbage collection and diagnostics.
///
/// Only construct after `CloudKitSyncAvailability` said `.available`:
/// `CKContainer` traps without the entitlement.
public final class CloudKitSyncTransport: SidebarSyncTransport, CKSyncEngineDelegate, @unchecked Sendable {
    public static let zoneName = CloudKitSyncZone.zoneName

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let lock = NSLock()
    private var engine: CKSyncEngine?
    private var serialization: CKSyncEngine.State.Serialization?
    // Collected while a fetch or send runs (CKSyncEngine reports through events).
    private var outgoing: [CKRecord.ID: CKRecord] = [:]
    private var fetched: [SyncWireRecord] = []
    private var fetchedDeletions: [String] = []
    private var zoneDeletion: SyncTransportError?
    private var sent = SyncModifyResult()

    public init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    // MARK: SidebarSyncTransport

    public func accountStatus() async -> SyncAccountStatus {
        do {
            switch try await container.accountStatus() {
            case .available:
                let user = try await container.userRecordID()
                return .available(userID: user.recordName)
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .temporarilyUnavailable: return .temporarilyUnavailable
            case .couldNotDetermine: return .couldNotDetermine
            @unknown default: return .couldNotDetermine
            }
        } catch {
            return .couldNotDetermine
        }
    }

    public func prepareZone() async throws {
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        } catch {
            throw Self.map(error, zoneID: zoneID)
        }
    }

    public func fetchChanges(since token: Data?) async throws -> SyncFetchResult {
        let engine = syncEngine(token: token)
        withLock {
            fetched = []
            fetchedDeletions = []
            zoneDeletion = nil
        }
        do {
            try await engine.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .zoneIDs([zoneID])))
        } catch {
            throw Self.map(error, zoneID: zoneID)
        }
        return try withLock {
            if let zoneDeletion { throw zoneDeletion }
            return SyncFetchResult(changed: fetched, deleted: fetchedDeletions, token: encodedState(), moreComing: false)
        }
    }

    public func modify(saving records: [SyncWireRecord], deleting names: [String]) async throws -> SyncModifyResult {
        let engine = syncEngine(token: nil)
        let ckRecords = records.map(makeRecord)
        let deleteIDs = names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        withLock {
            outgoing = Dictionary(uniqueKeysWithValues: ckRecords.map { ($0.recordID, $0) })
            sent = SyncModifyResult()
        }
        engine.state.add(pendingRecordZoneChanges: ckRecords.map { .saveRecord($0.recordID) } + deleteIDs.map { .deleteRecord($0) })
        defer { withLock { outgoing = [:] } }
        do {
            try await engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .recordIDs(ckRecords.map(\.recordID) + deleteIDs)))
        } catch {
            throw Self.map(error, zoneID: zoneID)
        }
        return withLock { sent }
    }

    public func reset() {
        withLock {
            engine = nil
            serialization = nil
        }
    }

    // MARK: CKSyncEngineDelegate

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        withLock {
            switch event {
            case .stateUpdate(let update):
                serialization = update.stateSerialization
            case .fetchedDatabaseChanges(let changes):
                for deletion in changes.deletions where deletion.zoneID == zoneID {
                    switch deletion.reason {
                    case .purged: zoneDeletion = .userDeletedZone
                    default: zoneDeletion = .zoneNotFound
                    }
                }
            case .fetchedRecordZoneChanges(let changes):
                for modification in changes.modifications where modification.record.recordID.zoneID == zoneID {
                    if let wire = Self.wire(from: modification.record) { fetched.append(wire) }
                }
                for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
                    fetchedDeletions.append(deletion.recordID.recordName)
                }
            case .sentRecordZoneChanges(let changes):
                for record in changes.savedRecords {
                    if let wire = Self.wire(from: record) { sent.saved.append(wire) }
                }
                for failure in changes.failedRecordSaves {
                    sent.failures[failure.record.recordID.recordName] = Self.map(failure.error, zoneID: zoneID)
                }
                sent.deleted.append(contentsOf: changes.deletedRecordIDs.map(\.recordName))
                for (id, error) in changes.failedRecordDeletes {
                    sent.failures[id.recordName] = Self.map(error, zoneID: zoneID)
                }
            default:
                break
            }
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !changes.isEmpty else { return nil }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] id in
            guard let self else { return nil }
            return self.withLock { self.outgoing[id] }
        }
    }

    // MARK: Records

    private func syncEngine(token: Data?) -> CKSyncEngine {
        withLock {
            if let engine { return engine }
            if let token { serialization = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: token) }
            var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: serialization, delegate: self)
            configuration.automaticallySync = false
            let created = CKSyncEngine(configuration)
            engine = created
            return created
        }
    }

    private func encodedState() -> Data? {
        serialization.flatMap { try? JSONEncoder().encode($0) }
    }

    private func makeRecord(_ wire: SyncWireRecord) -> CKRecord {
        let record = wire.serverTag.flatMap(Self.record(fromSystemFields:))
            ?? CKRecord(recordType: wire.payload.kind.rawValue, recordID: CKRecord.ID(recordName: wire.recordName, zoneID: zoneID))
        record.encryptedValues["payload"] = try? wire.payload.encoded()
        record["isDeleted"] = Int64(wire.payload.isAlive ? 0 : 1)
        record["schemaVersion"] = Int64(SyncRecordPayload.schemaVersion)
        record["clientTimestamp"] = wire.payload.latestStamp?.millis ?? 0
        return record
    }

    static func wire(from record: CKRecord) -> SyncWireRecord? {
        guard let data = record.encryptedValues["payload"] as? Data,
              let payload = try? SyncRecordPayload.decode(data) else { return nil }
        return SyncWireRecord(recordName: record.recordID.recordName, payload: payload, serverTag: systemFields(of: record))
    }

    static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    static func map(_ error: Error, zoneID: CKRecordZone.ID) -> SyncTransportError {
        guard let error = error as? CKError else { return .other(error.localizedDescription) }
        switch error.code {
        case .serverRecordChanged:
            if let server = error.serverRecord, let wire = wire(from: server) { return .serverRecordChanged(server: wire) }
            return .other(error.localizedDescription)
        case .zoneNotFound: return .zoneNotFound
        case .userDeletedZone: return .userDeletedZone
        case .changeTokenExpired: return .changeTokenExpired
        case .unknownItem: return .unknownItem
        case .networkUnavailable, .networkFailure: return .networkUnavailable
        case .serviceUnavailable, .zoneBusy: return .serviceUnavailable(retryAfter: error.retryAfterSeconds)
        case .requestRateLimited: return .rateLimited(retryAfter: error.retryAfterSeconds)
        case .quotaExceeded: return .quotaExceeded
        case .notAuthenticated, .accountTemporarilyUnavailable: return .notAuthenticated
        case .permissionFailure, .missingEntitlement, .badContainer: return .permissionFailure
        case .partialFailure:
            if let first = error.partialErrorsByItemID?.values.first { return map(first, zoneID: zoneID) }
            return .other(error.localizedDescription)
        default:
            return .other(error.localizedDescription)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
#endif
