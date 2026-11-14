import Foundation

// Field-level last-writer-wins records (SYNC-DESIGN §5.3). Every synced field
// carries the hybrid-logical-clock stamp of its last write; a record's
// existence is one more LWW register (the tombstone). Merging two copies of a
// record keeps, per field, the value with the greater stamp, so merge is
// commutative, associative and idempotent: devices that have seen the same
// writes hold the same records, in any delivery order.

/// A JSON value: the type-agnostic payload of one synced field.
public enum SyncValue: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SyncValue])
    case object([String: SyncValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([SyncValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: SyncValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: SyncValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Any Codable value as a `SyncValue` (dates as seconds since 1970, sorted keys).
    public static func encoding<T: Encodable>(_ value: T) throws -> SyncValue {
        let data = try SyncCoding.encoder.encode(value)
        return try SyncCoding.decoder.decode(SyncValue.self, from: data)
    }

    public func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try SyncCoding.decoder.decode(T.self, from: SyncCoding.encoder.encode(self))
    }

    /// Stable text form, used to break ties between equal stamps deterministically.
    var canonicalText: String {
        (try? String(decoding: SyncCoding.encoder.encode(self), as: UTF8.self)) ?? ""
    }
}

enum SyncCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

/// Hybrid logical clock stamp: wall milliseconds, a counter for writes in the
/// same millisecond (or behind a peer's clock), and the writing device as the
/// final tie-break. Total order, so every device picks the same winner.
public struct SyncStamp: Hashable, Codable, Comparable, Sendable {
    public var millis: Int64
    public var counter: UInt32
    public var device: String

    public init(millis: Int64, counter: UInt32 = 0, device: String) {
        self.millis = millis
        self.counter = counter
        self.device = device
    }

    public static func < (lhs: SyncStamp, rhs: SyncStamp) -> Bool {
        (lhs.millis, lhs.counter, lhs.device) < (rhs.millis, rhs.counter, rhs.device)
    }

    /// How far ahead of this Mac's clock another Mac's stamp may be.
    public static let maxSkew: TimeInterval = 24 * 3600
    /// No real device writes this many times within one millisecond, or
    /// runs this far behind a peer.
    public static let maxCounter: UInt32 = 1 << 24

    static func millis(of date: Date) -> Int64 {
        let value = (date.timeIntervalSince1970 * 1000).rounded(.down)
        return value.isFinite ? Int64(exactly: value) ?? (value < 0 ? .min : .max) : 0
    }

    /// A stamp a real device could have written by `now`. Others come from a
    /// crafted record: adopted, they would push every later stamp to the end
    /// of time and, before the fix, overflow the clock (RC-0.1.0-602 T-03).
    public func isPlausible(now: Date) -> Bool {
        millis >= 0 && millis <= SyncStamp.millis(of: now.addingTimeInterval(Self.maxSkew)) && counter <= Self.maxCounter
    }
}

/// Issues strictly increasing stamps that also stay ahead of every stamp seen
/// from other devices, so a write made after observing a peer's write wins
/// even when this Mac's clock is behind.
public struct HybridLogicalClock: Codable, Equatable, Sendable {
    public private(set) var last: SyncStamp
    public let device: String

    public init(device: String, last: SyncStamp? = nil) {
        self.device = device
        self.last = last ?? SyncStamp(millis: 0, device: device)
    }

    /// Total for any saved or observed stamp: a counter at its limit moves
    /// on to the next millisecond instead of overflowing (RC-0.1.0-602 T-03).
    public mutating func tick(now: Date) -> SyncStamp {
        let wall = SyncStamp.millis(of: now)
        if wall > last.millis {
            last = SyncStamp(millis: wall, counter: 0, device: device)
        } else if last.counter < UInt32.max {
            last = SyncStamp(millis: last.millis, counter: last.counter + 1, device: device)
        } else if last.millis < Int64.max {
            last = SyncStamp(millis: last.millis + 1, counter: 0, device: device)
        }
        return last
    }

    public mutating func observe(_ stamp: SyncStamp) {
        if stamp.millis > last.millis || (stamp.millis == last.millis && stamp.counter > last.counter) {
            last = SyncStamp(millis: stamp.millis, counter: stamp.counter, device: device)
        }
    }
}

public struct SyncField: Hashable, Codable, Sendable {
    public var value: SyncValue
    public var stamp: SyncStamp

    public init(value: SyncValue, stamp: SyncStamp) {
        self.value = value
        self.stamp = stamp
    }

    /// The winner of two writes to one field; equal stamps fall back to the value text.
    static func winner(_ a: SyncField, _ b: SyncField) -> SyncField {
        if a.stamp != b.stamp { return a.stamp > b.stamp ? a : b }
        return a.value.canonicalText >= b.value.canonicalText ? a : b
    }
}

/// The kinds of record in the sidebar zone (docs/SYNC-RECORDS.md, SYNC-DESIGN §4.2).
public enum SyncRecordKind: String, Codable, CaseIterable, Sendable {
    case profile = "SidebarProfileRecord"
    case space = "SidebarSpaceRecord"
    case item = "SidebarItemRecord"
    case boost = "SidebarBoostRecord"
    /// A space's gradient, grain and appearance (wave 28). Older builds fail
    /// to decode its kind and drop it, so they never overwrite it.
    case spaceStyle = "SidebarSpaceStyleRecord"
    /// An archived space's archive date (Archive Space), alive only while it
    /// is archived. Its own record for the same reason as `spaceStyle`: older
    /// builds drop it instead of writing the space back unarchived.
    case spaceArchive = "SidebarSpaceArchiveRecord"

    var namePrefix: String {
        switch self {
        case .profile: return "profile_"
        case .space: return "space_"
        case .item: return "item_"
        case .boost: return "boost_"
        case .spaceStyle: return "spacestyle_"
        case .spaceArchive: return "spacearchive_"
        }
    }

    public func recordName(for id: UUID) -> String {
        namePrefix + id.uuidString.lowercased()
    }

    public static func parse(recordName: String) -> (kind: SyncRecordKind, id: UUID)? {
        for kind in allCases where recordName.hasPrefix(kind.namePrefix) {
            guard let id = UUID(uuidString: String(recordName.dropFirst(kind.namePrefix.count))) else { return nil }
            return (kind, id)
        }
        return nil
    }
}

/// One record's synced state: stamped fields plus an optional tombstone.
public struct SyncRecordPayload: Hashable, Codable, Sendable {
    public static let schemaVersion = 1

    public var kind: SyncRecordKind
    public var fields: [String: SyncField]
    public var tombstone: SyncStamp?

    public init(kind: SyncRecordKind, fields: [String: SyncField] = [:], tombstone: SyncStamp? = nil) {
        self.kind = kind
        self.fields = fields
        self.tombstone = tombstone
    }

    /// Delete wins over every write it saw; a field written after the delete
    /// (an offline edit that raced it) brings the record back.
    public var isAlive: Bool {
        guard let tombstone else { return true }
        return fields.values.contains { $0.stamp > tombstone }
    }

    public var latestStamp: SyncStamp? {
        ([tombstone].compactMap { $0 } + fields.values.map(\.stamp)).max()
    }

    /// Every stamp is one a device could have written (see `SyncStamp.isPlausible`).
    public func isPlausible(now: Date) -> Bool {
        (tombstone?.isPlausible(now: now) ?? true) && fields.values.allSatisfy { $0.stamp.isPlausible(now: now) }
    }

    /// Current field values, without stamps.
    public var values: [String: SyncValue] {
        fields.mapValues(\.value)
    }

    public static func merge(_ a: SyncRecordPayload, _ b: SyncRecordPayload) -> SyncRecordPayload {
        var fields = a.fields
        for (name, field) in b.fields {
            fields[name] = fields[name].map { SyncField.winner($0, field) } ?? field
        }
        let tombstone = [a.tombstone, b.tombstone].compactMap { $0 }.max()
        return SyncRecordPayload(kind: a.kind, fields: fields, tombstone: tombstone)
    }

    public func encoded() throws -> Data {
        try SyncCoding.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SyncRecordPayload {
        try SyncCoding.decoder.decode(SyncRecordPayload.self, from: data)
    }
}

/// A record as exchanged with the server. `serverTag` is the server's opaque
/// version (CloudKit system fields, or the fake server's change counter); a
/// save carrying a stale tag is rejected with the server's copy.
public struct SyncWireRecord: Hashable, Codable, Sendable {
    public var recordName: String
    public var payload: SyncRecordPayload
    public var serverTag: Data?

    public init(recordName: String, payload: SyncRecordPayload, serverTag: Data? = nil) {
        self.recordName = recordName
        self.payload = payload
        self.serverTag = serverTag
    }
}
