import Foundation

/// What sync reads from and writes to: the sidebar store on the main thread.
@MainActor
public protocol SidebarSyncHost: AnyObject {
    func syncSnapshot() -> SidebarSnapshot
    /// Replaces the sidebar with `snapshot` without journaling it as local edits.
    func applySyncedSnapshot(_ snapshot: SidebarSnapshot)
}

extension SidebarStore: SidebarSyncHost {
    public func syncSnapshot() -> SidebarSnapshot {
        makeSnapshot()
    }

    public func applySyncedSnapshot(_ snapshot: SidebarSnapshot) {
        applySnapshot(snapshot)
        onDidMutate?()
    }
}

/// Settings and the bottom-bar dot read this.
public struct SyncStatusDetails: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case off
        case unavailable(String)
        case signedOut(String)
        case syncing
        case upToDate
        /// Changes are queued; sync retries on its own.
        case waiting(String)
        case failed(String)
    }

    public var phase: Phase
    public var lastSyncedAt: Date?
    public var pendingCount: Int
    public var account: SyncAccountStatus?
    public var technicalError: String?

    public init(phase: Phase, lastSyncedAt: Date? = nil, pendingCount: Int = 0, account: SyncAccountStatus? = nil) {
        self.phase = phase
        self.lastSyncedAt = lastSyncedAt
        self.pendingCount = pendingCount
        self.account = account
    }

    public var engineStatus: SyncEngineStatus {
        switch phase {
        case .off: return .local
        case .unavailable(let reason), .signedOut(let reason): return .unavailable(reason: reason)
        case .syncing: return .syncing
        case .upToDate: return .idleSynced
        case .waiting(let message), .failed(let message): return .error(message)
        }
    }

    public var accountDescription: String {
        switch account {
        case .available?: return "Signed in to iCloud"
        case .noAccount?: return "No iCloud account on this Mac"
        case .restricted?: return "iCloud is restricted on this Mac"
        case .temporarilyUnavailable?: return "iCloud is temporarily unavailable"
        case .couldNotDetermine?: return "iCloud account status unknown"
        case nil: return "Not checked yet"
        }
    }
}

/// One sync cycle's result (tests assert on it).
public struct SyncCycleOutcome: Equatable, Sendable {
    public var pushed = 0
    public var pulled = 0
    public var appliedRemote = false
    public var error: SyncTransportError?
    public var skipped = false
}

/// The sidebar sync pipeline (SYNC-DESIGN §6.1), transport-agnostic.
///
/// A cycle: check the account, make sure the zone exists, stamp local edits
/// (diffing the sidebar against the last merged records), fetch and merge
/// remote changes, rebuild the sidebar from the merged records, then upload
/// what the server lacks, merging and retrying on conflicts. Records with
/// unconfirmed writes stay `pending` in the persisted state, which is the
/// offline queue: nothing is lost across a quit, and a restart resumes.
@MainActor
public final class SidebarSyncCoordinator {
    public static let batchSize = 200
    /// Tombstones live this long before they are deleted from the server (§5.4).
    public static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600
    /// A record type the server's schema rejected is offered again after
    /// this long (or on Sync Now); every other type keeps syncing meanwhile.
    public static let schemaRetryInterval: TimeInterval = 900
    /// At most this many records are kept; a pull past it sets the rest
    /// aside (RC-0.1.0-602 T-10). CloudKit caps each record at 1 MB.
    public static let maxRecords = 50_000
    /// `maxRecords`, lower in tests.
    var recordLimit = SidebarSyncCoordinator.maxRecords

    public let transport: SidebarSyncTransport
    public weak var host: SidebarSyncHost?
    public private(set) var state: SidebarSyncState
    public private(set) var details: SyncStatusDetails
    public var onDetailsChange: ((SyncStatusDetails) -> Void)?
    public var now: () -> Date

    private let stateStore: SidebarSyncStateStoring
    private var clock: HybridLogicalClock
    /// Kinds whose upload the schema rejected: until when they wait, and why.
    private var schemaRejections: [SyncRecordKind: (until: Date, error: SyncTransportError)] = [:]

    public init(
        transport: SidebarSyncTransport,
        stateStore: SidebarSyncStateStoring,
        deviceID: String,
        now: @escaping () -> Date = { Date() },
        initialState: SidebarSyncState? = nil
    ) {
        self.transport = transport
        self.stateStore = stateStore
        self.now = now
        var state = initialState ?? stateStore.load()
        state.normalize()
        Self.quarantineImplausible(&state, now: now())
        self.state = state
        self.clock = HybridLogicalClock(device: deviceID, last: state.clock)
        self.details = SyncStatusDetails(
            phase: state.isActive ? .waiting("Waiting to sync") : .off,
            lastSyncedAt: state.lastSyncedAt,
            pendingCount: state.pendingCount
        )
    }

    /// On, and chosen (or a new install's default): cycles run.
    public var isEnabled: Bool { state.isActive }

    /// Records whose stamps no device could have written, set aside this
    /// launch instead of merged (RC-0.1.0-602 T-03).
    public private(set) var quarantinedRecordNames: Set<String> = []

    /// A state file a crafted record already reached (build 602 adopted any
    /// stamp): its impossible records go, and a clock pushed past what
    /// remains restarts from the newest stamp left.
    static func quarantineImplausible(_ state: inout SidebarSyncState, now: Date) {
        state.records = state.records.filter { $0.value.payload.isPlausible(now: now) }
        if let clock = state.clock, !clock.isPlausible(now: now) {
            state.clock = state.records.values.compactMap(\.payload.latestStamp).max()
        }
    }

    /// The switch in Settings. On starts syncing: when iCloud already holds
    /// a sidebar the app asks first (`detectCloudSidebar`, then
    /// `apply(_:from:)`), and calls this only when it is empty.
    public func setEnabled(_ enabled: Bool) {
        guard state.enabled != enabled || state.decision != .user else { return }
        state.enabled = enabled
        state.decision = .user
        persist()
        update(state.isActive ? .waiting("Waiting to sync") : .off)
    }

    // MARK: - iCloud's sidebar

    /// What the last `detectCloudSidebar` found, held aside: none of it is
    /// in the sidebar until `apply(_:from:)`.
    public private(set) var stagedCloudSidebar: CloudSidebarFound?
    /// A look that brings nothing new for this long is reported stalled; it
    /// carries on, and its result counts whenever it comes. No limit on a
    /// look that is still reading.
    public var stallTimeout: TimeInterval = 30
    public nonisolated static let stalledMessage = "iCloud hasn't sent anything for a while. ReArc is still waiting; check your connection."

    /// Looks at iCloud without changing anything there or here. `progress`
    /// hears how far it got (never after this returns).
    public func detectCloudSidebar(progress: @escaping @MainActor (CloudLookProgress) -> Void = { _ in }) async -> CloudSidebarDetection {
        guard let reader = transport as? SidebarCloudReading else {
            return .unavailable("This build can't look at iCloud.")
        }
        let finished = LookFinished()
        let report: @Sendable (CloudLookProgress) -> Void = { step in
            Task { @MainActor in if !finished.value { progress(step) } }
        }
        let stalledMessage = Self.stalledMessage
        let watch = LookWatch(timeout: stallTimeout) { report(.stalled(stalledMessage)) }
        defer {
            finished.value = true
            watch.stop()
        }
        progress(.account)
        let account = await reader.accountStatus()
        watch.touch()
        var wires: [SyncWireRecord]?
        var failure: SyncTransportError?
        if case .available = account {
            do {
                wires = try await reader.readAllRecords { count in
                    watch.touch()
                    report(.records(count))
                }
            } catch let error as SyncTransportError {
                failure = error
            } catch {
                failure = .other(error.localizedDescription)
            }
        }
        let detection: CloudSidebarDetection
        if let failure {
            detection = failure == .notAuthenticated ? .signedOut(failure.userMessage) : .unreachable(Self.unreachableMessage(failure))
        } else {
            switch account {
            case .available(let userID):
                detection = .of(accountID: userID, records: sanitized(wires ?? []))
            case .noAccount:
                detection = .signedOut("Sign in to iCloud in System Settings to sync your sidebar.")
            case .restricted:
                detection = .signedOut("iCloud is restricted on this Mac.")
            case .temporarilyUnavailable, .couldNotDetermine:
                detection = .unreachable("iCloud is unavailable right now. Try again in a moment.")
            }
        }
        stagedCloudSidebar = detection.found
        return detection
    }

    private static func unreachableMessage(_ error: SyncTransportError) -> String {
        switch error {
        case .networkUnavailable: return "ReArc can't reach iCloud. Check your connection and try again."
        case .permissionFailure: return error.userMessage
        default: return "iCloud is unavailable right now. Try again in a moment."
        }
    }

    /// The records a merge would accept (RC-0.1.0-602 T-03), one per name,
    /// at most `recordLimit`.
    private func sanitized(_ wires: [SyncWireRecord]) -> [String: SyncWireRecord] {
        var kept: [String: SyncWireRecord] = [:]
        for wire in wires {
            guard wire.payload.isPlausible(now: now()),
                  SyncRecordKind.parse(recordName: wire.recordName).map({ $0.kind == wire.payload.kind }) ?? false else { continue }
            guard kept[wire.recordName] != nil || kept.count < recordLimit else { continue }
            kept[wire.recordName] = wire
        }
        return kept
    }

    /// The person's answer to "iCloud already has a ReArc sidebar", for
    /// the sidebar `detectCloudSidebar` found; sync is on afterwards.
    /// Nothing is fetched or sent here: the next cycle does that.
    ///
    /// - `useCloud`: the sidebar becomes iCloud's (synced parts; Today
    ///   tabs of spaces that go are archived). The caller backs it up first.
    /// - `replaceCloud`: this Mac's sidebar wins every field, and what
    ///   only iCloud has is deleted there, so other Macs get this one's.
    /// - `merge`: a first join (iCloud's copy of rows it already has is
    ///   kept), matching spaces imported from the same Arc space.
    public func apply(_ choice: CloudSidebarChoice, from found: CloudSidebarFound) {
        guard let host else { return }
        state.resetServerState()
        transport.reset()
        state.enabled = true
        state.decision = .user
        switch choice {
        case .merge:
            break
        case .useCloud, .replaceCloud:
            state.accountID = found.accountID
            for wire in found.records { merge(wire) }
            for name in state.records.keys { state.records[name]?.pending = false }
            state.clock = clock.last
            // The zone is there (it was just read), and every record is known.
            state.zoneReady = true
            state.joined = true
            if choice == .useCloud {
                var outcome = SyncCycleOutcome()
                applyToHost(&outcome)
                tidyArcCopies()
            } else {
                capture(host.syncSnapshot())
            }
        }
        stagedCloudSidebar = nil
        persist()
        update(.waiting("Waiting to sync"))
    }

    /// Deletes ReArc's sidebar from iCloud and turns sync off on this Mac;
    /// this Mac's sidebar stays. Another Mac still syncing uploads its own again.
    public func deleteCloudSidebar() async throws {
        guard let reader = transport as? SidebarCloudReading else { throw SyncTransportError.permissionFailure }
        try await reader.deleteZone()
        state.resetServerState()
        transport.reset()
        state.enabled = false
        state.decision = .user
        stagedCloudSidebar = nil
        persist()
        update(.off)
    }

    // MARK: - One profile in iCloud

    nonisolated static let profileBackupFailedMessage = "ReArc couldn't save a copy of what would be deleted, so nothing was deleted."

    /// Deletes one profile from iCloud (`CloudProfileDeletion`): the person
    /// confirmed `confirmed`, and the caller has just looked again (`found`).
    /// The plan is worked out again from what iCloud holds now; when it
    /// differs from `confirmed`, nothing happens and the new plan comes back
    /// to be confirmed. `backup` gets the records as read before anything is
    /// written, and if it throws nothing is.
    ///
    /// Sync off: targeted writes of at most `batchSize` records
    /// (`SidebarCloudEditing`), each all or none and only while its records
    /// are as read; rows first, the profile last. No zone is created, nothing
    /// of this Mac's is uploaded and the sync state is not touched.
    /// `deleteLocally` runs once iCloud's part is done. Sync on: a cycle
    /// first, then `deleteLocally`, then the changes go in as this Mac's
    /// edits and a cycle uploads them, so the sidebar, the queue and iCloud
    /// agree.
    public func deleteCloudProfile(
        _ confirmed: CloudProfileDeletion,
        in found: CloudSidebarFound,
        backup: ([SyncWireRecord]) throws -> URL,
        deleteLocally: (() -> Void)? = nil
    ) async -> CloudProfileDeletionResult {
        if state.isActive { return await deleteCloudProfileThroughSync(confirmed, found: found, backup: backup, deleteLocally: deleteLocally) }
        guard let editor = transport as? SidebarCloudEditing else { return .failed("This build can't change iCloud.") }
        var records = Dictionary(found.records.map { ($0.recordName, $0) }) { _, last in last }
        guard let plan = CloudProfileDeletion(profileID: confirmed.profileID, in: records) else {
            return .gone(.of(accountID: found.accountID, records: records))
        }
        guard plan.changes == confirmed.changes else { return .changed(plan) }
        let saved: URL
        do {
            saved = try backup(plan.fetched.values.sorted { $0.recordName < $1.recordName })
        } catch {
            return .failed(Self.profileBackupFailedMessage)
        }
        // Newer than every stamp read, so each change wins; nothing is persisted.
        var stamps = HybridLogicalClock(device: clock.device, last: clock.last)
        for wire in found.records { if let latest = wire.payload.latestStamp { stamps.observe(latest) } }
        let writes = plan.writes(clock: &stamps, now: now())
        var written = 0
        for start in stride(from: 0, to: writes.count, by: Self.batchSize) {
            let batch = Array(writes[start ..< min(start + Self.batchSize, writes.count)])
            let result: SyncModifyResult
            do {
                result = try await editor.saveExisting(batch)
            } catch SyncTransportError.zoneNotFound, SyncTransportError.userDeletedZone {
                return written == 0 ? .gone(.empty(accountID: found.accountID)) : .failed(Self.cutShort(written, of: writes.count))
            } catch {
                return .failed(Self.cutShort(written, of: writes.count, reachable: false))
            }
            guard result.failures.isEmpty else { return .failed(Self.cutShort(written, of: writes.count)) }
            for wire in result.saved { records[wire.recordName] = wire }
            written += result.saved.count
        }
        deleteLocally?()
        let detection = CloudSidebarDetection.of(accountID: found.accountID, records: records)
        stagedCloudSidebar = detection.found
        return .deleted(backup: saved, detection: detection, queued: false)
    }

    private func deleteCloudProfileThroughSync(
        _ confirmed: CloudProfileDeletion,
        found: CloudSidebarFound,
        backup: ([SyncWireRecord]) throws -> URL,
        deleteLocally: (() -> Void)?
    ) async -> CloudProfileDeletionResult {
        let first = await sync()
        if let error = first.error, !error.isSchemaError { return .failed(error.userMessage) }
        guard let host else { return .failed("Sync isn't ready yet. Try again in a moment.") }
        let account = state.accountID ?? found.accountID
        guard let plan = CloudProfileDeletion(profileID: confirmed.profileID, in: syncedWires()) else {
            return .gone(.of(accountID: account, records: syncedWires()))
        }
        guard plan.changes == confirmed.changes else { return .changed(plan) }
        let saved: URL
        do {
            saved = try backup(plan.fetched.values.sorted { $0.recordName < $1.recordName })
        } catch {
            return .failed(Self.profileBackupFailedMessage)
        }
        deleteLocally?()
        // The local delete is stamped first; the plan's changes come after it.
        capture(host.syncSnapshot())
        let at = now()
        for (name, change) in plan.changes {
            guard var record = state.records[name], change != .delete || record.payload.isAlive else { continue }
            record.payload = CloudProfileDeletion.applying(change, to: record.payload) { clock.tick(now: at) }
            record.pending = true
            state.records[name] = record
        }
        state.clock = clock.last
        var outcome = SyncCycleOutcome()
        applyToHost(&outcome)
        update(.waiting("Waiting to sync"))
        let upload = await sync()
        return .deleted(backup: saved, detection: .of(accountID: account, records: syncedWires()), queued: upload.error != nil || state.pendingCount > 0)
    }

    /// This Mac's merged records, as the server last confirmed them.
    private func syncedWires() -> [String: SyncWireRecord] {
        Dictionary(uniqueKeysWithValues: state.records.map { ($0.key, SyncWireRecord(recordName: $0.key, payload: $0.value.payload, serverTag: $0.value.serverTag)) })
    }

    private nonisolated static func cutShort(_ written: Int, of total: Int, reachable: Bool = true) -> String {
        let why = reachable ? "iCloud changed while ReArc was deleting" : "ReArc lost touch with iCloud while deleting"
        guard written > 0 else { return why + ", so nothing was deleted. Look at iCloud again and try again." }
        return why + ": \(written.formatted()) of \(total.formatted()) changes were made. Look at iCloud again to see what is left."
    }

    /// Sync Now: offer schema-rejected kinds again (after a schema deployment).
    public func retrySchemaRejectedKinds() {
        schemaRejections = [:]
    }

    // MARK: - Cycle

    @discardableResult
    public func sync() async -> SyncCycleOutcome {
        var outcome = SyncCycleOutcome()
        guard state.isActive, host != nil else {
            outcome.skipped = true
            return outcome
        }
        details.technicalError = nil
        update(.syncing)
        let account = await transport.accountStatus()
        details.account = account
        guard case .available(let userID) = account else {
            update(.signedOut(SyncStatusDetails(phase: .off, account: account).accountDescription))
            outcome.error = .notAuthenticated
            return outcome
        }
        if let known = state.accountID, known != userID {
            // Another Apple Account: its zone is a different sidebar. Keep this
            // Mac's sidebar and join the new account as a fresh device.
            state.resetServerState()
            transport.reset()
        }
        state.accountID = userID

        do {
            try await runCycle(&outcome)
        } catch let error as SyncTransportError {
            if error == .zoneNotFound {
                resetZone()
                do {
                    try await runCycle(&outcome)
                } catch let retry as SyncTransportError {
                    fail(retry, &outcome)
                } catch {
                    fail(.other(error.localizedDescription), &outcome)
                }
            } else {
                fail(error, &outcome)
            }
        } catch {
            fail(.other(error.localizedDescription), &outcome)
        }
        return outcome
    }

    private func runCycle(_ outcome: inout SyncCycleOutcome) async throws {
        guard let host else { return }
        if !state.zoneReady {
            try await transport.prepareZone()
            state.zoneReady = true
            persist()
        }
        var remoteChanged: Bool
        let joining = !state.joined
        if joining {
            // First sync: look at the server before stamping local rows, so a
            // fresh install adopts the iCloud sidebar instead of duplicating it.
            remoteChanged = try await pullAll(&outcome)
            let hasRemoteSidebar = state.records.values.contains { $0.payload.kind == .space && $0.payload.isAlive }
            let adopt = hasRemoteSidebar && SidebarSyncProjection.isPristine(host.syncSnapshot())
            // Rows only the server has are new to this Mac, not deleted here;
            // rows it already has, alive or deleted, keep the server's copy.
            if !adopt {
                // A space imported from an Arc space iCloud already has becomes that space.
                let snapshot = host.syncSnapshot()
                let matched = ArcTwinSpaces.matchingServer(snapshot, records: state.records.mapValues(\.payload))
                if matched != snapshot {
                    host.applySyncedSnapshot(matched)
                    remoteChanged = true
                }
                capture(matched, joining: true)
            }
            if adopt { remoteChanged = true }
            state.joined = true
        } else {
            capture(host.syncSnapshot())
            remoteChanged = try await pullAll(&outcome)
        }
        if remoteChanged { applyToHost(&outcome) }
        if joining { tidyArcCopies() }

        for _ in 0 ..< 3 {
            let mergedConflicts = try await pushPending(&outcome)
            guard mergedConflicts else { break }
            applyToHost(&outcome)
        }
        state.lastSyncedAt = now()
        state.lastError = nil
        persist()
        if !quarantinedRecordNames.isEmpty {
            details.technicalError = "Ignored \(quarantinedRecordNames.count) record(s) with impossible timestamps or kinds, or past \(recordLimit) records: \(quarantinedRecordNames.sorted().prefix(3).joined(separator: ", "))"
        }
        // The rest synced; still report a type the schema keeps out.
        if let rejected = activeSchemaRejection() { throw rejected }
        update(state.pendingCount == 0 ? .upToDate : .waiting("\(state.pendingCount) changes waiting to upload"))
    }

    /// iCloud's sidebar just came in (Use, or a first join): copies of one Arc
    /// space that 608 and earlier left in it are merged as on load
    /// (`ArcTwinSpaces.repair`, which loses no row), and the merge syncs as an edit.
    private func tidyArcCopies() {
        guard let host else { return }
        let (tidied, report) = ArcTwinSpaces.repair(host.syncSnapshot())
        guard report.changed else { return }
        host.applySyncedSnapshot(tidied)
        capture(host.syncSnapshot())
    }

    /// Rebuilds the sidebar from the merged records, then stamps whatever the
    /// rebuild repaired (rescued orphans, re-ranked ties) as local writes.
    private func applyToHost(_ outcome: inout SyncCycleOutcome) {
        guard let host else { return }
        let merged = SidebarSyncProjection.apply(state.records.mapValues(\.payload), onto: host.syncSnapshot(), now: now())
        host.applySyncedSnapshot(merged)
        outcome.appliedRemote = true
        capture(host.syncSnapshot())
    }

    // MARK: - Local edits

    /// Stamps local edits now, without the network, so a write's stamp is the
    /// time it was made even when it uploads hours later (offline). The
    /// scheduler calls this for every coalesced batch of sidebar edits.
    public func captureLocalChanges() {
        guard state.isActive, state.joined, let host else { return }
        capture(host.syncSnapshot())
        details.pendingCount = state.pendingCount
    }

    /// Stamps every field that differs from the last merged record; rows gone
    /// from the sidebar get a tombstone.
    ///
    /// `joining`: the first sync of a Mac that already has a sidebar. Its
    /// rows carry no edit times, so a value differing from the server's is
    /// as likely stale (the same Arc import, months older) as new. Stamping
    /// it now would beat another Mac's later edit and bring back what it
    /// deleted (RC-0.1.0-602 T-02), so only rows the server lacks are
    /// stamped; nothing is tombstoned.
    func capture(_ snapshot: SidebarSnapshot, joining: Bool = false) {
        let bodies = SidebarSyncProjection.extract(snapshot)
        let at = now()
        for (name, body) in bodies {
            let known = state.records[name]
            if joining, known != nil { continue }
            var record = known ?? SyncShadowRecord(payload: SyncRecordPayload(kind: body.kind))
            let alive = known != nil && record.payload.isAlive
            var changed = false
            for (key, value) in body.values where !alive || record.payload.fields[key]?.value != value {
                record.payload.fields[key] = SyncField(value: value, stamp: clock.tick(now: at))
                changed = true
            }
            if alive {
                for (key, field) in record.payload.fields where body.values[key] == nil && field.value != .null {
                    record.payload.fields[key] = SyncField(value: .null, stamp: clock.tick(now: at))
                    changed = true
                }
            }
            if changed {
                record.pending = true
                state.records[name] = record
            }
        }
        for (name, record) in state.records where !joining && record.payload.isAlive && bodies[name] == nil
            && SidebarSyncProjection.canMaterialize(name, record.payload) {
            var deleted = record
            deleted.payload.tombstone = clock.tick(now: at)
            deleted.pending = true
            state.records[name] = deleted
        }
        state.clock = clock.last
        persist()
    }

    // MARK: - Fetch

    private func pullAll(_ outcome: inout SyncCycleOutcome) async throws -> Bool {
        var changed = false
        var restarts = 0
        while true {
            let result: SyncFetchResult
            do {
                result = try await transport.fetchChanges(since: state.transportToken)
            } catch SyncTransportError.changeTokenExpired where restarts < 2 {
                // Merging is idempotent, so fetching everything again is safe.
                restarts += 1
                state.transportToken = nil
                persist()
                continue
            }
            for wire in result.changed where merge(wire) {
                changed = true
                outcome.pulled += 1
            }
            for name in result.deleted {
                guard var record = state.records[name] else { continue }
                if record.pending {
                    record.serverTag = nil
                    state.records[name] = record
                } else {
                    state.records[name] = nil
                    changed = true
                }
            }
            state.transportToken = result.token
            state.clock = clock.last
            persist()
            if !result.moreComing { break }
        }
        return changed
    }

    /// Merges a server copy into the local one. True when the local copy changed.
    @discardableResult
    private func merge(_ wire: SyncWireRecord) -> Bool {
        guard wire.payload.isPlausible(now: now()),
              SyncRecordKind.parse(recordName: wire.recordName).map({ $0.kind == wire.payload.kind }) ?? true else {
            // Never merged, never observed: one crafted record must not stop sync on every Mac.
            quarantinedRecordNames.insert(wire.recordName)
            return false
        }
        if state.records[wire.recordName] == nil, state.records.count >= recordLimit {
            quarantinedRecordNames.insert(wire.recordName)
            return false
        }
        if let latest = wire.payload.latestStamp { clock.observe(latest) }
        guard var record = state.records[wire.recordName] else {
            state.records[wire.recordName] = SyncShadowRecord(payload: wire.payload, serverTag: wire.serverTag)
            return true
        }
        let merged = SyncRecordPayload.merge(record.payload, wire.payload)
        let changed = merged != record.payload
        record.payload = merged
        record.serverTag = wire.serverTag
        record.pending = merged != wire.payload
        state.records[wire.recordName] = record
        return changed
    }

    // MARK: - Upload

    /// Uploads pending records. True when a conflict merged remote writes in.
    private func pushPending(_ outcome: inout SyncCycleOutcome) async throws -> Bool {
        var mergedRemote = false
        var skipped = Set<String>()
        for _ in 0 ..< 4 {
            let pending = state.records.filter { $0.value.pending && !skipped.contains($0.key) && !isSchemaRejected($0.value.payload.kind) }
                .sorted { $0.key < $1.key }
            let expired = expiredTombstones()
            guard !pending.isEmpty || !expired.isEmpty else { break }
            var conflicts = false
            // A rejected type must not hold every later type behind it.
            var batches = SyncRecordKind.allCases.flatMap { kind in
                let sameKind = pending.filter { $0.value.payload.kind == kind }
                return stride(from: 0, to: sameKind.count, by: Self.batchSize).map {
                    Array(sameKind[$0 ..< min($0 + Self.batchSize, sameKind.count)])
                }
            }
            if batches.isEmpty { batches = [[]] }
            var deletesSent = false
            for batch in batches {
                // A later batch of a kind rejected earlier in this pass waits too.
                if let kind = batch.first?.value.payload.kind, isSchemaRejected(kind) {
                    skipped.formUnion(batch.map(\.key))
                    continue
                }
                let wires = batch.map { SyncWireRecord(recordName: $0.key, payload: $0.value.payload, serverTag: $0.value.serverTag) }
                let deletes = deletesSent ? [] : expired
                let result: SyncModifyResult
                do {
                    result = try await transport.modify(saving: wires, deleting: deletes)
                } catch let error as SyncTransportError where error.isSchemaError {
                    if let kind = batch.first?.value.payload.kind { rejectSchema(of: kind, error) }
                    skipped.formUnion(batch.map(\.key))
                    continue
                }
                deletesSent = true
                let sent = Dictionary(uniqueKeysWithValues: wires.map { ($0.recordName, $0.payload) })
                for saved in result.saved {
                    guard var record = state.records[saved.recordName] else { continue }
                    record.serverTag = saved.serverTag
                    if record.payload == sent[saved.recordName] { record.pending = false }
                    state.records[saved.recordName] = record
                    outcome.pushed += 1
                }
                for name in result.deleted { state.records[name] = nil }
                for (name, error) in result.failures.sorted(by: { $0.key < $1.key }) {
                    switch error {
                    case .serverRecordChanged(let server):
                        if merge(server) { mergedRemote = true }
                        conflicts = true
                    case .unknownItem:
                        if deletes.contains(name) {
                            state.records[name] = nil
                        } else if var record = state.records[name] {
                            record.serverTag = nil
                            state.records[name] = record
                            conflicts = true
                        }
                    case .schemaNotDeployed:
                        if let kind = state.records[name]?.payload.kind { rejectSchema(of: kind, error) }
                        skipped.insert(name)
                    case .zoneNotFound, .userDeletedZone, .notAuthenticated, .quotaExceeded:
                        persist()
                        throw error
                    default:
                        if error.isTransient {
                            persist()
                            throw error
                        }
                        skipped.insert(name)
                        state.lastError = error.userMessage
                    }
                }
                state.clock = clock.last
                persist()
            }
            if !conflicts { break }
        }
        return mergedRemote
    }

    private func isSchemaRejected(_ kind: SyncRecordKind) -> Bool {
        guard let rejection = schemaRejections[kind] else { return false }
        return rejection.until > now()
    }

    private func rejectSchema(of kind: SyncRecordKind, _ error: SyncTransportError) {
        schemaRejections[kind] = (now().addingTimeInterval(Self.schemaRetryInterval), error)
    }

    /// A schema rejection still keeping queued records of its kind back.
    private func activeSchemaRejection() -> SyncTransportError? {
        let waiting = Set(state.records.values.filter(\.pending).map(\.payload.kind))
        return schemaRejections.filter { waiting.contains($0.key) && isSchemaRejected($0.key) }
            .min { $0.key.rawValue < $1.key.rawValue }?.value.error
    }

    private func expiredTombstones() -> [String] {
        let cutoff = Int64((now().timeIntervalSince1970 - Self.tombstoneLifetime) * 1000)
        return state.records.filter { _, record in
            guard !record.pending, !record.payload.isAlive, let tombstone = record.payload.tombstone else { return false }
            return tombstone.millis < cutoff
        }.map(\.key).sorted()
    }

    // MARK: - Errors

    /// The zone vanished (reset by another Mac, or a new environment): create
    /// it again and upload every record, tombstones included.
    private func resetZone() {
        state.zoneReady = false
        state.transportToken = nil
        for name in state.records.keys {
            state.records[name]?.serverTag = nil
            state.records[name]?.pending = true
        }
        transport.reset()
        persist()
    }

    private func fail(_ error: SyncTransportError, _ outcome: inout SyncCycleOutcome) {
        outcome.error = error
        details.technicalError = error.technicalDetail
        state.lastError = error.userMessage
        switch error {
        case .userDeletedZone:
            // The user removed the data on purpose: never re-upload on our own.
            state.resetServerState()
            state.enabled = false
            persist()
            update(.failed(error.userMessage))
        case .notAuthenticated:
            persist()
            update(.signedOut(error.userMessage))
        default:
            persist()
            update(error.isTransient || error == .quotaExceeded ? .waiting(error.userMessage) : .failed(error.userMessage))
        }
    }

    private func update(_ phase: SyncStatusDetails.Phase) {
        details.phase = phase
        details.lastSyncedAt = state.lastSyncedAt
        details.pendingCount = state.pendingCount
        onDetailsChange?(details)
    }

    private func persist() {
        stateStore.save(state)
    }
}

/// Set on the main actor once a look returned: its late progress is dropped.
@MainActor
private final class LookFinished: @unchecked Sendable {
    var value = false
}

/// Calls `stalled` once each time nothing new arrives for `timeout` seconds.
private final class LookWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    private var reported = false
    private var task: Task<Void, Never>?

    init(timeout: TimeInterval, stalled: @escaping @Sendable () -> Void) {
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let (since, alreadyReported) = self.state()
                let wait = alreadyReported ? timeout : max(0.01, timeout - Date().timeIntervalSince(since))
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                if self.markStalledIfQuiet(timeout) { stalled() }
            }
        }
    }

    func touch() {
        lock.lock(); defer { lock.unlock() }
        last = Date()
        reported = false
    }

    func stop() { task?.cancel() }

    private func state() -> (Date, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (last, reported)
    }

    private func markStalledIfQuiet(_ timeout: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !reported, Date().timeIntervalSince(last) >= timeout else { return false }
        reported = true
        return true
    }
}
