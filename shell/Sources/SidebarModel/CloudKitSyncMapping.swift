import Foundation

/// CloudKit record field mapping (SYNC-DESIGN §4.2) decoupled from CloudKit types for unit tests.
public enum CloudKitSidebarRecordType: String, Equatable, Sendable {
    case syncKeyRing = "SyncKeyRing"
    case sidebarSpace = "SidebarSpaceRecord"
    case sidebarItem = "SidebarItemRecord"
    case containerMeta = "SidebarContainerMetaRecord"
}

public struct CloudKitMappedRecord: Equatable, Sendable {
    public var recordType: CloudKitSidebarRecordType
    public var recordName: String
    public var sortRank: String?
    public var parentID: String?
    public var spaceID: String?
    public var isDeleted: Bool
    public var clientTimestampMs: Int64
    public var focusedSpaceID: String?
    public var encryptedPayload: Data?

    public init(
        recordType: CloudKitSidebarRecordType,
        recordName: String,
        sortRank: String? = nil,
        parentID: String? = nil,
        spaceID: String? = nil,
        isDeleted: Bool = false,
        clientTimestampMs: Int64 = 0,
        focusedSpaceID: String? = nil,
        encryptedPayload: Data? = nil
    ) {
        self.recordType = recordType
        self.recordName = recordName
        self.sortRank = sortRank
        self.parentID = parentID
        self.spaceID = spaceID
        self.isDeleted = isDeleted
        self.clientTimestampMs = clientTimestampMs
        self.focusedSpaceID = focusedSpaceID
        self.encryptedPayload = encryptedPayload
    }
}

public enum CloudKitSyncZone {
    public static let zoneName = "com.rearc.sidebar.graph.v1"
}

public enum CloudKitRecordMapper {
    public static func map(journalEntry: SidebarJournalEntry) -> [CloudKitMappedRecord] {
        let timestampMs = Int64(journalEntry.timestamp.timeIntervalSince1970 * 1000)
        switch journalEntry.mutation {
        case .insertItem(let id, let spaceID, let container, let sortRank),
             .moveItem(let id, let spaceID, let container, let sortRank):
            return [
                CloudKitMappedRecord(
                    recordType: .sidebarItem,
                    recordName: "item_\(id.uuidString.lowercased())",
                    sortRank: sortRank,
                    parentID: parentKey(spaceID: spaceID, container: container),
                    spaceID: spaceID.map { $0.uuidString.lowercased() } ?? "global",
                    clientTimestampMs: timestampMs,
                    encryptedPayload: Data()
                ),
            ]
        case .placeItemInFolder(let id, let folderID, let sortRank):
            return [
                CloudKitMappedRecord(
                    recordType: .sidebarItem,
                    recordName: "item_\(id.uuidString.lowercased())",
                    sortRank: sortRank,
                    parentID: "item_\(folderID.uuidString.lowercased())",
                    clientTimestampMs: timestampMs,
                    encryptedPayload: Data()
                ),
            ]
        case .upsertItem(let id):
            return [
                CloudKitMappedRecord(
                    recordType: .sidebarItem,
                    recordName: "item_\(id.uuidString.lowercased())",
                    clientTimestampMs: timestampMs,
                    encryptedPayload: Data()
                ),
            ]
        case .deleteItem(let id):
            return [
                CloudKitMappedRecord(
                    recordType: .sidebarItem,
                    recordName: "item_\(id.uuidString.lowercased())",
                    isDeleted: true,
                    clientTimestampMs: timestampMs
                ),
            ]
        case .insertSpace(let id, let sortRank),
             .moveSpace(let id, let sortRank):
            return [
                CloudKitMappedRecord(
                    recordType: .sidebarSpace,
                    recordName: "space_\(id.uuidString.lowercased())",
                    sortRank: sortRank,
                    clientTimestampMs: timestampMs,
                    encryptedPayload: Data()
                ),
            ]
        case .upsertSpace(let id):
            return [
                CloudKitMappedRecord(
                    recordType: .sidebarSpace,
                    recordName: "space_\(id.uuidString.lowercased())",
                    clientTimestampMs: timestampMs,
                    encryptedPayload: Data()
                ),
            ]
        case .deleteSpace(let id):
            return [
                CloudKitMappedRecord(
                    recordType: .sidebarSpace,
                    recordName: "space_\(id.uuidString.lowercased())",
                    isDeleted: true,
                    clientTimestampMs: timestampMs
                ),
            ]
        case .focusSpace(let spaceID):
            return [
                CloudKitMappedRecord(
                    recordType: .containerMeta,
                    recordName: "rearc-sidebar-global-meta",
                    clientTimestampMs: timestampMs,
                    focusedSpaceID: spaceID.uuidString.lowercased()
                ),
            ]
        }
    }

    private static func parentKey(spaceID: Space.ID?, container: SidebarItemContainer?) -> String? {
        guard let container else { return nil }
        switch container {
        case .favorite:
            return "global:favorites"
        case .pinned, .unpinned:
            guard let spaceID else { return nil }
            return "\(spaceID.uuidString.lowercased()):\(container.rawValue)"
        }
    }
}
