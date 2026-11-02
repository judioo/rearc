import Foundation

public enum CaptureScope: String, Codable, CaseIterable {
    case visible
    case fullPage
}

public struct CaptureRecord: Identifiable, Equatable, Codable {
    public var id: UUID
    public var sourceURL: URL?
    public var sourceTitle: String
    public var createdAt: Date
    public var scope: CaptureScope
    /// PNG filename under the captures directory (`{id}.png`).
    public var fileName: String

    public init(
        id: UUID = UUID(),
        sourceURL: URL?,
        sourceTitle: String,
        createdAt: Date = Date(),
        scope: CaptureScope,
        fileName: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.createdAt = createdAt
        self.scope = scope
        self.fileName = Self.canonicalFileName(id: id, proposed: fileName)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceURL = try c.decodeIfPresent(URL.self, forKey: .sourceURL)
        sourceTitle = try c.decode(String.self, forKey: .sourceTitle)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        scope = try c.decode(CaptureScope.self, forKey: .scope)
        let decodedName = try c.decodeIfPresent(String.self, forKey: .fileName)
        fileName = CaptureRecord.canonicalFileName(id: id, proposed: decodedName)
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceURL, sourceTitle, createdAt, scope, fileName
    }

    public static func canonicalFileName(id: UUID, proposed: String?) -> String {
        let expected = "\(id.uuidString).png"
        guard let proposed, proposed == expected else { return expected }
        return expected
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encode(sourceTitle, forKey: .sourceTitle)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(scope, forKey: .scope)
        try c.encode(fileName, forKey: .fileName)
    }
}

public enum CaptureStoreOps {
    public static func insert(_ record: CaptureRecord, into captures: inout [UUID: CaptureRecord]) {
        captures[record.id] = record
    }

    public static func remove(id: UUID, from captures: inout [UUID: CaptureRecord]) -> CaptureRecord? {
        captures.removeValue(forKey: id)
    }
}
