import Foundation

/// A CloudKit stand-in for tests and dev runs: per-account private zones with
/// change tokens, optimistic-concurrency tags (stale saves are rejected with
/// the server copy, like `CKError.serverRecordChanged`), zone resets, account
/// switches and injectable network, quota and rate-limit failures.
/// Never touches the network.
public final class InMemorySyncServer: @unchecked Sendable {
    public enum Fault: Equatable, Sendable {
        case networkUnavailable
        case quotaExceeded
        case rateLimited(retryAfter: TimeInterval)
        case serviceUnavailable
    }

    struct StoredRecord {
        var wire: SyncWireRecord
        var changeSequence: Int
    }

    struct Zone {
        var generation: Int
        var records: [String: StoredRecord] = [:]
        /// Hard deletes with the sequence they happened at.
        var deletions: [String: Int] = [:]
    }

    private let lock = NSLock()
    private var zones: [String: Zone] = [:]
    private var deletedByUser: Set<String> = []
    private var sequence = 0
    private var generationCounter = 0
    /// Tokens issued before the account's current epoch report `changeTokenExpired`.
    private var tokenEpoch: [String: Int] = [:]

    public var fault: Fault?
    /// Fails only the next N operations with `fault`, then clears it (nil = until cleared).
    public var faultBudget: Int?
    public var pageSize = 1000
    /// Runs once at the start of the next modify (tests: another Mac saves in between).
    public var beforeModify: ((InMemorySyncServer) -> Void)?
    public private(set) var modifyCount = 0
    public private(set) var fetchCount = 0
    /// Read-only looks (`SidebarCloudReading.readAllRecords`).
    public private(set) var readCount = 0
    /// Zones created, and zones deleted, by any device.
    public private(set) var zoneCreations = 0
    public private(set) var zoneDeletions = 0
    /// Whether `account` has a sidebar zone.
    public func hasZone(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return zones[account] != nil
    }

    public init() {}

    /// A device's view of the server, signed in as `account` (nil = signed out).
    public func transport(account: String?) -> InMemorySyncTransport {
        InMemorySyncTransport(server: self, account: account)
    }

    // MARK: Test controls

    /// The zone disappears (CloudKit `zoneNotFound` on the next call).
    public func resetZone(account: String) {
        lock.lock(); defer { lock.unlock() }
        zones[account] = nil
    }

    /// The user deleted ReArc data from iCloud settings (`userDeletedZone`).
    public func userDeletesData(account: String) {
        lock.lock(); defer { lock.unlock() }
        zones[account] = nil
        deletedByUser.insert(account)
    }

    /// Tokens issued before now stop working (`changeTokenExpired`).
    public func expireTokens(account: String) {
        lock.lock(); defer { lock.unlock() }
        tokenEpoch[account, default: 0] += 1
    }

    /// Saves `record` as another device would, ignoring its server tag.
    public func overwrite(account: String, record: SyncWireRecord) {
        lock.lock(); defer { lock.unlock() }
        guard var zone = zones[account] else { return }
        sequence += 1
        var stored = record
        stored.serverTag = Data("\(zone.generation)-\(sequence)".utf8)
        zone.records[record.recordName] = StoredRecord(wire: stored, changeSequence: sequence)
        zones[account] = zone
    }

    public func records(account: String) -> [String: SyncWireRecord] {
        lock.lock(); defer { lock.unlock() }
        return zones[account]?.records.mapValues(\.wire) ?? [:]
    }

    // MARK: Operations

    func checkFault() throws {
        lock.lock()
        guard let fault else { lock.unlock(); return }
        if let budget = faultBudget {
            if budget <= 1 { self.fault = nil; faultBudget = nil } else { faultBudget = budget - 1 }
        }
        lock.unlock()
        switch fault {
        case .networkUnavailable: throw SyncTransportError.networkUnavailable
        case .quotaExceeded: throw SyncTransportError.quotaExceeded
        case .rateLimited(let after): throw SyncTransportError.rateLimited(retryAfter: after)
        case .serviceUnavailable: throw SyncTransportError.serviceUnavailable(retryAfter: nil)
        }
    }

    func prepareZone(account: String) throws {
        try checkFault()
        lock.lock(); defer { lock.unlock() }
        deletedByUser.remove(account)
        if zones[account] == nil {
            zoneCreations += 1
            generationCounter += 1
            zones[account] = Zone(generation: generationCounter)
        }
    }

    private func zoneError(account: String) -> SyncTransportError {
        deletedByUser.contains(account) ? .userDeletedZone : .zoneNotFound
    }

    func fetch(account: String, token: Data?) throws -> SyncFetchResult {
        try checkFault()
        lock.lock(); defer { lock.unlock() }
        fetchCount += 1
        guard let zone = zones[account] else { throw zoneError(account: account) }
        var since = 0
        if let token {
            let position = try JSONDecoder().decode(Token.self, from: token)
            guard position.generation == zone.generation else { throw SyncTransportError.zoneNotFound }
            if position.epoch != tokenEpoch[account, default: 0] { throw SyncTransportError.changeTokenExpired }
            since = position.sequence
        }
        let changed = zone.records.values.filter { $0.changeSequence > since }.sorted { $0.changeSequence < $1.changeSequence }
        let page = Array(changed.prefix(pageSize))
        let more = changed.count > page.count
        let through = more ? page.last!.changeSequence : sequence
        let deleted = zone.deletions.filter { $0.value > since && $0.value <= through }.map(\.key).sorted()
        let token = try JSONEncoder().encode(Token(generation: zone.generation, sequence: through, epoch: tokenEpoch[account, default: 0]))
        return SyncFetchResult(changed: page.map(\.wire), deleted: deleted, token: token, moreComing: more)
    }

    func read(account: String) throws -> [SyncWireRecord]? {
        try checkFault()
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        guard let zone = zones[account] else { return nil }
        return zone.records.values.sorted { $0.changeSequence < $1.changeSequence }.map(\.wire)
    }

    func deleteZone(account: String) throws {
        try checkFault()
        lock.lock(); defer { lock.unlock() }
        if zones.removeValue(forKey: account) != nil { zoneDeletions += 1 }
    }

    func modify(account: String, saving records: [SyncWireRecord], deleting names: [String]) throws -> SyncModifyResult {
        if let hook = beforeModify {
            beforeModify = nil
            hook(self)
        }
        try checkFault()
        lock.lock(); defer { lock.unlock() }
        modifyCount += 1
        guard var zone = zones[account] else { throw zoneError(account: account) }
        var result = SyncModifyResult()
        for record in records {
            if let existing = zone.records[record.recordName] {
                guard record.serverTag == existing.wire.serverTag else {
                    result.failures[record.recordName] = .serverRecordChanged(server: existing.wire)
                    continue
                }
            } else if record.serverTag != nil {
                result.failures[record.recordName] = .unknownItem
                continue
            }
            sequence += 1
            var stored = record
            stored.serverTag = Data("\(zone.generation)-\(sequence)".utf8)
            zone.records[record.recordName] = StoredRecord(wire: stored, changeSequence: sequence)
            zone.deletions[record.recordName] = nil
            result.saved.append(stored)
        }
        for name in names {
            guard zone.records.removeValue(forKey: name) != nil else {
                result.failures[name] = .unknownItem
                continue
            }
            sequence += 1
            zone.deletions[name] = sequence
            result.deleted.append(name)
        }
        zones[account] = zone
        return result
    }

    private struct Token: Codable {
        var generation: Int
        var sequence: Int
        var epoch: Int
    }
}

public final class InMemorySyncTransport: SidebarSyncTransport, SidebarCloudReading, @unchecked Sendable {
    public let server: InMemorySyncServer
    /// The signed-in account; set to simulate sign-out or switching accounts.
    public var account: String?

    init(server: InMemorySyncServer, account: String?) {
        self.server = server
        self.account = account
    }

    public func accountStatus() async -> SyncAccountStatus {
        account.map { .available(userID: $0) } ?? .noAccount
    }

    public func prepareZone() async throws {
        try server.prepareZone(account: try signedIn())
    }

    public func fetchChanges(since token: Data?) async throws -> SyncFetchResult {
        try server.fetch(account: try signedIn(), token: token)
    }

    public func modify(saving records: [SyncWireRecord], deleting names: [String]) async throws -> SyncModifyResult {
        try server.modify(account: try signedIn(), saving: records, deleting: names)
    }

    public func readAllRecords() async throws -> [SyncWireRecord]? {
        try server.read(account: try signedIn())
    }

    public func deleteZone() async throws {
        try server.deleteZone(account: try signedIn())
    }

    private func signedIn() throws -> String {
        guard let account else { throw SyncTransportError.notAuthenticated }
        return account
    }
}
