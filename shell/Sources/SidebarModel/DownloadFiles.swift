import Foundation

/// What the downloads UI knows about a row's file (docs/DOWNLOADS-AT-SCALE.md,
/// "Row icons off the main thread"). Read off the main thread only: a file on
/// a sleeping or network volume, or in a folder macOS asks the user about,
/// can block the read for seconds.
public struct FileState: Equatable, Sendable {
    public var exists: Bool
    public var isDirectory: Bool
    public var modified: Date?
    public var size: Int64

    public init(exists: Bool, isDirectory: Bool = false, modified: Date? = nil, size: Int64 = 0) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.modified = modified
        self.size = size
    }

    public static let missing = FileState(exists: false)
}

/// A small cache whose entries expire `ttl` seconds after they were stored
/// and which keeps at most `capacity` entries, dropping the least recently
/// used. Times come from the caller, so it is pure.
public struct ExpiringCache<Key: Hashable, Value> {
    private struct Slot {
        var value: Value
        var stored: TimeInterval
        var used: UInt64
    }

    public let ttl: TimeInterval
    public let capacity: Int
    private var slots: [Key: Slot] = [:]
    private var clock: UInt64 = 0

    public init(ttl: TimeInterval, capacity: Int) {
        self.ttl = ttl
        self.capacity = max(capacity, 1)
    }

    public var count: Int { slots.count }

    /// The value while it is fresh; an expired entry is dropped.
    public mutating func value(for key: Key, now: TimeInterval) -> Value? {
        guard let slot = slots[key] else { return nil }
        guard now - slot.stored < ttl else {
            slots[key] = nil
            return nil
        }
        clock += 1
        slots[key]?.used = clock
        return slot.value
    }

    /// The value, fresh or not, without counting as a use: what the UI shows
    /// while a fresh read is on its way.
    public func lastValue(for key: Key) -> Value? {
        slots[key]?.value
    }

    public mutating func insert(_ value: Value, for key: Key, now: TimeInterval) {
        clock += 1
        slots[key] = Slot(value: value, stored: now, used: clock)
        guard slots.count > capacity else { return }
        // Evict down to 3/4 at once, least recently used first, so inserts stay cheap.
        let keep = capacity * 3 / 4
        let oldest = slots.sorted { $0.value.used < $1.value.used }.prefix(slots.count - max(keep, 1))
        for (key, _) in oldest { slots[key] = nil }
    }

    public mutating func removeValue(for key: Key) {
        slots[key] = nil
    }
}

/// Which serial queue reads a path. Each lane reads one file at a time, so a
/// volume that hangs holds one thread, not one per row; files elsewhere use
/// other lanes. External and network volumes get a lane each, as do the
/// folders in the home folder (macOS asks about Downloads, Desktop and
/// Documents separately, and iCloud Drive or a cloud provider can stall on
/// its own); anything else goes by its first two path components.
public enum FileLane {
    public static func key(for path: String, home: String = NSHomeDirectory()) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let homeComponents = home.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.first == "Volumes", components.count > 1 {
            return "/" + components.prefix(2).joined(separator: "/")
        }
        if !homeComponents.isEmpty, components.count > homeComponents.count,
           Array(components.prefix(homeComponents.count)) == homeComponents {
            let rest = components.dropFirst(homeComponents.count)
            var depth = 1
            if rest.first == "Library" {
                depth = 2
                if let next = rest.dropFirst().first, next == "CloudStorage" || next == "Mobile Documents" { depth = 3 }
            }
            return "/" + components.prefix(homeComponents.count + min(depth, rest.count)).joined(separator: "/")
        }
        return "/" + components.prefix(2).joined(separator: "/")
    }
}
