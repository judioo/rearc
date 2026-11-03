import Foundation

public enum SyncEngineStatus: Equatable, Sendable {
    case local
    case syncing
    case idleSynced
    case error(String)
    case unavailable(reason: String)
}

public struct SyncPullResult: Equatable, Sendable {
    public var appliedEntries: [SidebarJournalEntry]
    public var serverHighSequence: UInt64

    public init(appliedEntries: [SidebarJournalEntry] = [], serverHighSequence: UInt64 = 0) {
        self.appliedEntries = appliedEntries
        self.serverHighSequence = serverHighSequence
    }
}

public protocol SyncEngine: AnyObject, Sendable {
    var status: SyncEngineStatus { get }
    var onStatusChange: (@Sendable (SyncEngineStatus) -> Void)? { get set }
    func start()
    func stop()
    func push(_ entries: [SidebarJournalEntry])
    func pull(since sequence: UInt64) async throws -> SyncPullResult
}

// MARK: - Local (no CloudKit)

public final class LocalSyncEngine: SyncEngine, @unchecked Sendable {
    public private(set) var status: SyncEngineStatus = .local
    public var onStatusChange: (@Sendable (SyncEngineStatus) -> Void)?

    public init() {}

    public func start() {
        updateStatus(.local)
    }

    public func stop() {
        updateStatus(.local)
    }

    public func push(_ entries: [SidebarJournalEntry]) {
        guard !entries.isEmpty else { return }
        _ = entries
    }

    public func pull(since sequence: UInt64) async throws -> SyncPullResult {
        _ = sequence
        return SyncPullResult()
    }

    private func updateStatus(_ newValue: SyncEngineStatus) {
        status = newValue
        onStatusChange?(newValue)
    }
}

public final class UnavailableSyncEngine: SyncEngine, @unchecked Sendable {
    public private(set) var status: SyncEngineStatus
    public var onStatusChange: (@Sendable (SyncEngineStatus) -> Void)?

    public init(reason: String) {
        self.status = .unavailable(reason: reason)
    }

    public func start() {}
    public func stop() {}
    public func push(_ entries: [SidebarJournalEntry]) { _ = entries }

    public func pull(since sequence: UInt64) async throws -> SyncPullResult {
        _ = sequence
        return SyncPullResult()
    }
}

// MARK: - Outbound coalescing (§6.2)

public final class MutationCoalescer: @unchecked Sendable {
    public let window: TimeInterval
    private let lock = NSLock()
    private var pending: [SidebarJournalEntry] = []
    private var flushWorkItem: DispatchWorkItem?
    private let queue: DispatchQueue
    private var deliver: (@Sendable ([SidebarJournalEntry]) -> Void)?

    public init(window: TimeInterval = 0.5, queue: DispatchQueue = DispatchQueue(label: "net.rearc.sync.coalesce")) {
        self.window = window
        self.queue = queue
    }

    public func setHandler(_ handler: @escaping @Sendable ([SidebarJournalEntry]) -> Void) {
        lock.lock()
        deliver = handler
        lock.unlock()
    }

    public func enqueue(_ entries: [SidebarJournalEntry]) {
        lock.lock()
        for entry in entries {
            pending.append(entry)
        }
        pending = Self.squash(pending)
        scheduleFlushLocked()
        lock.unlock()
    }

    /// Immediate flush (tests / shutdown).
    public func flushNow() {
        lock.lock()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let batch = pending
        pending = []
        let deliver = deliver
        lock.unlock()
        if !batch.isEmpty {
            deliver?(batch)
        }
    }

    private func scheduleFlushLocked() {
        flushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushNow()
        }
        flushWorkItem = work
        queue.asyncAfter(deadline: .now() + window, execute: work)
    }

    /// Squash consecutive moves (section or folder) of the same item; coalesce upserts.
    public static func squash(_ entries: [SidebarJournalEntry]) -> [SidebarJournalEntry] {
        var output: [SidebarJournalEntry] = []
        for entry in entries {
            switch entry.mutation {
            case .moveItem(let id, let spaceID, let container, let sortRank):
                if let lastIndex = output.lastIndex(where: { matchesMoveTarget($0, itemID: id) }) {
                    let last = output[lastIndex]
                    if case .moveItem = last.mutation {
                        output[lastIndex] = SidebarJournalEntry(
                            sequence: last.sequence,
                            timestamp: entry.timestamp,
                            deviceID: entry.deviceID,
                            mutation: .moveItem(id: id, spaceID: spaceID, container: container, sortRank: sortRank)
                        )
                        continue
                    }
                }
                output.append(entry)
            case .placeItemInFolder(let id, _, _):
                if let lastIndex = output.lastIndex(where: { matchesMoveTarget($0, itemID: id) }),
                   case .placeItemInFolder = output[lastIndex].mutation {
                    let last = output[lastIndex]
                    output[lastIndex] = SidebarJournalEntry(
                        sequence: last.sequence,
                        timestamp: entry.timestamp,
                        deviceID: entry.deviceID,
                        mutation: entry.mutation
                    )
                    continue
                }
                output.append(entry)
            case .upsertItem(let id):
                if let lastIndex = output.lastIndex(where: {
                    if case .upsertItem(let other) = $0.mutation { return other == id }
                    return false
                }) {
                    output[lastIndex] = entry
                    continue
                }
                output.append(entry)
            default:
                output.append(entry)
            }
        }
        return cancelCreateDeletePairs(output)
    }

    private static func matchesMoveTarget(_ entry: SidebarJournalEntry, itemID: UUID) -> Bool {
        switch entry.mutation {
        // Folder placements are moves too, so a section move never squashes across one.
        case .moveItem(let id, _, _, _), .placeItemInFolder(let id, _, _): return id == itemID
        default: return false
        }
    }

    private static func cancelCreateDeletePairs(_ entries: [SidebarJournalEntry]) -> [SidebarJournalEntry] {
        var inserted = Set<UUID>()
        var output: [SidebarJournalEntry] = []
        for entry in entries {
            switch entry.mutation {
            case .insertItem(let id, _, _, _):
                inserted.insert(id)
                output.append(entry)
            case .deleteItem(let id) where inserted.contains(id):
                inserted.remove(id)
                if let insertIndex = output.lastIndex(where: {
                    if case .insertItem(let other, _, _, _) = $0.mutation { return other == id }
                    return false
                }) {
                    output.remove(at: insertIndex)
                }
            default:
                output.append(entry)
            }
        }
        return output
    }
}

public final class SyncOutboundPipeline: @unchecked Sendable {
    public let coalescer: MutationCoalescer
    private weak var engine: SyncEngine?
    private let journal: SidebarMutationJournal

    public init(journal: SidebarMutationJournal, engine: SyncEngine, coalescer: MutationCoalescer? = nil) {
        self.journal = journal
        self.engine = engine
        self.coalescer = coalescer ?? MutationCoalescer()
        self.coalescer.setHandler { [weak self] batch in
            self?.pushBatch(batch)
        }
    }

    public func handleJournalEntry(_ entry: SidebarJournalEntry) {
        coalescer.enqueue([entry])
    }

    public func flush() {
        coalescer.flushNow()
    }

    private func pushBatch(_ entries: [SidebarJournalEntry]) {
        guard let engine, !entries.isEmpty else { return }
        switch engine.status {
        case .local, .unavailable:
            engine.push(entries)
            if let maxSeq = entries.map(\.sequence).max() {
                journal.markFlushed(upTo: maxSeq)
            }
        case .error, .idleSynced, .syncing:
            engine.onStatusChange?(.syncing)
            engine.push(entries)
            if let maxSeq = entries.map(\.sequence).max() {
                journal.markFlushed(upTo: maxSeq)
            }
            if case .unavailable = engine.status {
                break
            }
            engine.onStatusChange?(.idleSynced)
        }
    }
}
