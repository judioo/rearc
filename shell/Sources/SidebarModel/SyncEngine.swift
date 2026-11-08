import Foundation

public enum SyncEngineStatus: Equatable, Sendable {
    case local
    case syncing
    /// Only for an engine whose last upload a server confirmed.
    case idleSynced
    case error(String)
    case unavailable(reason: String)
}

/// The bottom-bar sync dot and its tooltip. Green means a server confirmed
/// the upload (`idleSynced`); local-only and unavailable sync are grey.
public struct SyncStatusPresentation: Equatable, Sendable {
    public enum Indicator: Equatable, Sendable { case grey, blue, green, red }

    public var indicator: Indicator
    public var help: String

    public init(_ status: SyncEngineStatus) {
        switch status {
        case .local:
            self.init(indicator: .grey, help: "Sidebar sync: off, changes stay on this Mac")
        case .syncing:
            self.init(indicator: .blue, help: "Sidebar sync: syncing…")
        case .idleSynced:
            self.init(indicator: .green, help: "Sidebar sync: up to date")
        case .error(let message):
            self.init(indicator: .red, help: "Sidebar sync error: \(message)")
        case .unavailable(let reason):
            self.init(indicator: .grey, help: "Sidebar sync: off. \(reason)")
        }
    }

    init(indicator: Indicator, help: String) {
        self.indicator = indicator
        self.help = help
    }
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
    private var pending = Squasher()
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
        // Each entry squashes into what is pending, which is squashed already:
        // a burst (an import of thousands of rows) costs one step per entry,
        // not a re-squash of everything pending per entry.
        for entry in entries {
            pending.add(entry)
        }
        scheduleFlushLocked()
        lock.unlock()
    }

    /// Immediate flush (tests / shutdown).
    public func flushNow() {
        lock.lock()
        flushWorkItem?.cancel()
        flushWorkItem = nil
        let batch = pending.entries
        pending = Squasher()
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

    /// Squash consecutive moves (section or folder) of the same item; coalesce
    /// upserts; an insert and a later delete of the same item cancel out.
    public static func squash(_ entries: [SidebarJournalEntry]) -> [SidebarJournalEntry] {
        var squasher = Squasher()
        for entry in entries { squasher.add(entry) }
        return squasher.entries
    }

    /// The squashed entries so far, with the indexes that let the next entry
    /// squash in constant time.
    struct Squasher {
        private(set) var entries: [SidebarJournalEntry] = []
        /// Each item's last move or folder placement.
        private var lastMove: [UUID: Int] = [:]
        private var lastUpsert: [UUID: Int] = [:]
        /// Items whose insert is still pending (a later delete cancels it).
        private var lastInsert: [UUID: Int] = [:]

        mutating func add(_ entry: SidebarJournalEntry) {
            switch entry.mutation {
            case .moveItem(let id, let spaceID, let container, let sortRank):
                if let i = lastMove[id], case .moveItem = entries[i].mutation {
                    let last = entries[i]
                    entries[i] = SidebarJournalEntry(sequence: last.sequence, timestamp: entry.timestamp, deviceID: entry.deviceID,
                                                     mutation: .moveItem(id: id, spaceID: spaceID, container: container, sortRank: sortRank))
                    return
                }
                lastMove[id] = entries.count
            case .placeItemInFolder(let id, _, _):
                if let i = lastMove[id], case .placeItemInFolder = entries[i].mutation {
                    let last = entries[i]
                    entries[i] = SidebarJournalEntry(sequence: last.sequence, timestamp: entry.timestamp, deviceID: entry.deviceID,
                                                     mutation: entry.mutation)
                    return
                }
                lastMove[id] = entries.count
            case .upsertItem(let id):
                if let i = lastUpsert[id] {
                    entries[i] = entry
                    return
                }
                lastUpsert[id] = entries.count
            case .insertItem(let id, _, _, _):
                lastInsert[id] = entries.count
            case .deleteItem(let id):
                if let i = lastInsert[id] {
                    // Created and deleted before either was sent: neither goes.
                    entries.remove(at: i)
                    reindex()
                    lastInsert[id] = nil
                    return
                }
            default:
                break
            }
            entries.append(entry)
        }

        /// After a removal shifts the entries (rare: an insert deleted in the same burst).
        private mutating func reindex() {
            lastMove = [:]
            lastUpsert = [:]
            let inserted = Set(lastInsert.keys)
            lastInsert = [:]
            for (i, entry) in entries.enumerated() {
                switch entry.mutation {
                case .moveItem(let id, _, _, _), .placeItemInFolder(let id, _, _): lastMove[id] = i
                case .upsertItem(let id): lastUpsert[id] = i
                case .insertItem(let id, _, _, _) where inserted.contains(id): lastInsert[id] = i
                default: break
                }
            }
        }
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

    /// Hands a batch to the engine. Status belongs to the engine alone: the
    /// pipeline never reports "syncing" or "up to date" on its behalf, since
    /// only the engine knows whether anything reached a server.
    private func pushBatch(_ entries: [SidebarJournalEntry]) {
        guard let engine, !entries.isEmpty else { return }
        engine.push(entries)
        if let maxSeq = entries.map(\.sequence).max() {
            journal.markFlushed(upTo: maxSeq)
        }
    }
}
