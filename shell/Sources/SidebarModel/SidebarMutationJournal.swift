import Foundation

// MARK: - Vocabulary (SIDEBAR-SPEC §2.8 / SYNC-DESIGN §5.1)

public enum SidebarJournalTarget: Equatable, Codable, Sendable {
    case item(UUID)
    case space(UUID)
    case focusSpace
}

public enum SidebarJournalMutation: Equatable, Codable, Sendable {
    case insertItem(id: UUID, spaceID: Space.ID?, container: SidebarItemContainer?, sortRank: String)
    case upsertItem(id: UUID)
    case moveItem(id: UUID, spaceID: Space.ID?, container: SidebarItemContainer?, sortRank: String)
    /// Insert or move an item under a folder (Arc parentID = the folder's item id).
    case placeItemInFolder(id: UUID, folderID: UUID, sortRank: String)
    case deleteItem(id: UUID)
    case insertSpace(id: UUID, sortRank: String)
    case upsertSpace(id: UUID)
    case moveSpace(id: UUID, sortRank: String)
    case deleteSpace(id: UUID)
    case focusSpace(spaceID: Space.ID)
}

public enum SidebarItemContainer: String, Equatable, Codable, Sendable {
    case favorite
    case pinned
    case unpinned
}

public struct SidebarJournalEntry: Equatable, Codable, Sendable, Identifiable {
    public var id: UInt64 { sequence }

    public let sequence: UInt64
    public let timestamp: Date
    public let deviceID: UUID
    public let mutation: SidebarJournalMutation

    public init(sequence: UInt64, timestamp: Date, deviceID: UUID, mutation: SidebarJournalMutation) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.deviceID = deviceID
        self.mutation = mutation
    }
}

// MARK: - Device identity

public enum SyncDeviceIdentity {
    private static let defaultsKey = "net.rearc.sync.deviceID"

    public static var persistedDeviceID: UUID {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let fresh = UUID()
        UserDefaults.standard.set(fresh.uuidString, forKey: defaultsKey)
        return fresh
    }

    /// Test hook — inject a stable device id without touching global defaults.
    public static func deviceID(storage: UserDefaults = .standard) -> UUID {
        if let stored = storage.string(forKey: defaultsKey),
           let uuid = UUID(uuidString: stored) {
            return uuid
        }
        let fresh = UUID()
        storage.set(fresh.uuidString, forKey: defaultsKey)
        return fresh
    }
}

// MARK: - Journal store

public final class SidebarMutationJournal: @unchecked Sendable {
    public static let ringCapacity = 500

    private let lock = NSLock()
    private var nextSequence: UInt64
    private var ring: [SidebarJournalEntry]
    private var ringStart: Int
    public private(set) var persistedTail: [SidebarJournalEntry]
    public private(set) var lastFlushedSequence: UInt64
    public let deviceID: UUID

    public var onAppend: ((SidebarJournalEntry) -> Void)?

    public init(
        deviceID: UUID = SyncDeviceIdentity.persistedDeviceID,
        lastFlushedSequence: UInt64 = 0,
        persistedTail: [SidebarJournalEntry] = []
    ) {
        self.deviceID = deviceID
        self.lastFlushedSequence = lastFlushedSequence
        self.persistedTail = persistedTail
        let maxSeq = persistedTail.map(\.sequence).max() ?? lastFlushedSequence
        self.nextSequence = max(lastFlushedSequence, maxSeq) + 1
        self.ring = []
        self.ringStart = 0
    }

    public func record(_ mutation: SidebarJournalMutation, at timestamp: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let entry = SidebarJournalEntry(
            sequence: nextSequence,
            timestamp: timestamp,
            deviceID: deviceID,
            mutation: mutation
        )
        nextSequence += 1
        appendToRing(entry)
        if entry.sequence > lastFlushedSequence {
            persistedTail.append(entry)
        }
        onAppend?(entry)
    }

    public func entriesSince(_ sequence: UInt64) -> [SidebarJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return allEntries().filter { $0.sequence > sequence }
    }

    public func allEntries() -> [SidebarJournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        var combined = persistedTail
        combined.append(contentsOf: ringInOrder())
        combined.sort { $0.sequence < $1.sequence }
        var seen = Set<UInt64>()
        return combined.filter { seen.insert($0.sequence).inserted }
    }

    public func markFlushed(upTo sequence: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        lastFlushedSequence = max(lastFlushedSequence, sequence)
        persistedTail.removeAll { $0.sequence <= lastFlushedSequence }
    }

    public func restore(from snapshot: SidebarSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        lastFlushedSequence = snapshot.lastFlushedSequence
        persistedTail = snapshot.journalPersistedTail
        let maxSeq = persistedTail.map(\.sequence).max() ?? lastFlushedSequence
        nextSequence = max(lastFlushedSequence, maxSeq) + 1
        ring.removeAll()
        ringStart = 0
    }

    public func snapshotTail() -> (lastFlushedSequence: UInt64, tail: [SidebarJournalEntry]) {
        lock.lock()
        defer { lock.unlock() }
        let pending = persistedTail.filter { $0.sequence > lastFlushedSequence }
        return (lastFlushedSequence, pending)
    }

    private func appendToRing(_ entry: SidebarJournalEntry) {
        if ring.count < Self.ringCapacity {
            ring.append(entry)
        } else {
            ring[ringStart] = entry
            ringStart = (ringStart + 1) % Self.ringCapacity
        }
    }

    private func ringInOrder() -> [SidebarJournalEntry] {
        guard !ring.isEmpty else { return [] }
        if ring.count < Self.ringCapacity {
            return ring
        }
        return Array(ring[ringStart...]) + Array(ring[..<ringStart])
    }
}
