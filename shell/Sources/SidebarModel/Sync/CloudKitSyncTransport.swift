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
public final class CloudKitSyncTransport: SidebarSyncTransport, SidebarCloudReading, CKSyncEngineDelegate, @unchecked Sendable {
    public static let zoneName = CloudKitSyncZone.zoneName

    /// Every call that reaches iCloud, one line each ("read …" or "write …").
    /// Set for a `REARC_DATA_DIR` launch, so a test run can show what it touched.
    public var accessLog: ((String) -> Void)?
    /// `SidebarSyncCoordinator.maxRecords`: a look reads no further.
    static let readLimit = 50_000

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
        let started = Date()
        defer { accessLog?(String(format: "read account status (%.2f s)", Date().timeIntervalSince(started))) }
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
        accessLog?("write: create the sidebar zone")
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        } catch {
            throw Self.map(error, zoneID: zoneID)
        }
    }

    public func fetchChanges(since token: Data?) async throws -> SyncFetchResult {
        accessLog?("read changes (sync engine)")
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
        accessLog?("write: save \(records.count) records, delete \(names.count)")
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
            let mapped = Self.map(error, zoneID: zoneID)
            // A send may throw after delivering per-record results. Keep the
            // confirmed saves rather than making the whole batch pending again.
            let partial = withLock { () -> SyncModifyResult? in
                guard !sent.saved.isEmpty || !sent.deleted.isEmpty || !sent.failures.isEmpty else { return nil }
                let confirmed = Set(sent.saved.map(\.recordName) + sent.deleted + Array(sent.failures.keys))
                for name in records.map(\.recordName) + names where !confirmed.contains(name) {
                    sent.failures[name] = mapped
                }
                return sent
            }
            if let partial { return partial }
            throw mapped
        }
        return withLock { sent }
    }

    public func reset() {
        withLock {
            engine = nil
            serialization = nil
        }
    }

    // MARK: SidebarCloudReading

    /// How a look reads the zone (the probe compares settings).
    public struct ReadTuning: Sendable {
        /// The person is waiting: CloudKit treats lower qualities as discretionary.
        public var qualityOfService: QualityOfService = .userInitiated
        /// The server sends 200 records a batch unless asked for more, and
        /// each batch costs it 1.3 to 2 s whatever its size: against 3,048
        /// records, 1,000 took 18 to 25 s where the default took 27 to 30 s.
        /// It caps a batch itself (often about 375).
        public var resultsLimit: Int? = 1000
        public var desiredKeys: [String]?
        public init() {}
    }

    public var readTuning = ReadTuning()

    /// A plain zone read, outside CKSyncEngine (which would set up a
    /// subscription): nothing in iCloud changes. Each batch is logged with
    /// how long it took to fetch and to decode.
    public func readAllRecords(progress: @escaping @Sendable (Int) -> Void) async throws -> [SyncWireRecord]? {
        let tuning = readTuning
        let configuration = CKOperation.Configuration()
        configuration.qualityOfService = tuning.qualityOfService
        let zoneID = zoneID
        let log = accessLog
        let started = Date()
        do {
            let records = try await database.configuredWith(configuration: configuration) { database -> [SyncWireRecord] in
                var records: [SyncWireRecord] = []
                var token: CKServerChangeToken?
                var pages = 0
                while true {
                    let asked = Date()
                    let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token, desiredKeys: tuning.desiredKeys,
                                                                    resultsLimit: tuning.resultsLimit)
                    let fetched = Date()
                    for case .success(let modification) in page.modificationResultsByID.values {
                        if let wire = Self.wire(from: modification.record) { records.append(wire) }
                    }
                    token = page.changeToken
                    pages += 1
                    log?(String(format: "read batch %d: %d records (fetch %.2f s, decode %.2f s)", pages, page.modificationResultsByID.count,
                                fetched.timeIntervalSince(asked), Date().timeIntervalSince(fetched)))
                    progress(records.count)
                    // Bounded like a merge (RC-0.1.0-602 T-10): past the limit, the rest is ignored.
                    guard page.moreComing, records.count <= Self.readLimit, pages < 1000 else { break }
                }
                return records
            }
            log?(String(format: "read the sidebar zone: %d records in %.2f s", records.count, Date().timeIntervalSince(started)))
            return records
        } catch {
            let mapped = Self.map(error, zoneID: zoneID)
            if mapped == .zoneNotFound || mapped == .userDeletedZone {
                log?("read the sidebar zone: none")
                return nil
            }
            log?("read the sidebar zone: failed")
            throw mapped
        }
    }

    public func deleteZone() async throws {
        accessLog?("write: delete the sidebar zone")
        do {
            _ = try await database.modifyRecordZones(saving: [], deleting: [zoneID])
        } catch {
            let mapped = Self.map(error, zoneID: zoneID)
            guard mapped == .zoneNotFound || mapped == .userDeletedZone else { throw mapped }
        }
        reset()
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
        var batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { [weak self] id in
            guard let self else { return nil }
            return self.withLock { self.outgoing[id] }
        }
        batch?.atomicByZone = false
        return batch
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
        guard let data = record.encryptedValues["payload"] as? Data, data.count <= 1 << 20,
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
        case .serverRejectedRequest, .invalidArguments:
            // Production refuses types and fields not deployed to it: "Cannot
            // create new type X in production schema", "Cannot create or
            // modify field 'y' in record 'X' in production schema".
            let message = error.localizedDescription
            if message.range(of: "cannot (create|modify).*production schema", options: [.regularExpression, .caseInsensitive]) != nil {
                return .schemaNotDeployed(message)
            }
            return .other(message)
        case .partialFailure:
            let failures = error.partialErrorsByItemID?.values.map { map($0, zoneID: zoneID) } ?? []
            if let schema = failures.first(where: \.isSchemaError) { return schema }
            if let first = failures.first { return first }
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
