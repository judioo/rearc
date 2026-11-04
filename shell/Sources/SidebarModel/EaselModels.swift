import Foundation

// MARK: - Document

public struct EaselViewport: Equatable, Codable {
    public var offsetX: Double
    public var offsetY: Double
    public var zoom: Double

    public init(offsetX: Double = 0, offsetY: Double = 0, zoom: Double = 1) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.zoom = max(zoom, 0.05)
    }
}

/// An easel is a free canvas; a note is a text document (Arc keeps both in
/// one library page, `EaselsAndNotesPage`, EASEL-CAPTURE §2-3).
public enum EaselDocumentKind: String, Codable, CaseIterable, Sendable {
    case easel
    case note
}

public struct EaselDocument: Identifiable, Equatable, Codable {
    public var id: UUID
    public var title: String
    public var kind: EaselDocumentKind
    public var createdAt: Date
    public var updatedAt: Date
    public var viewport: EaselViewport
    /// Canvas objects in back-to-front (z) order.
    public var blocks: [EaselBlock]

    public init(
        id: UUID = UUID(),
        title: String,
        kind: EaselDocumentKind = .easel,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        viewport: EaselViewport = EaselViewport(),
        blocks: [EaselBlock] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.viewport = viewport
        self.blocks = blocks
    }

    enum CodingKeys: String, CodingKey {
        case id, title, kind, createdAt, updatedAt, viewport, blocks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        viewport = try c.decode(EaselViewport.self, forKey: .viewport)
        blocks = try c.decode([EaselBlock].self, forKey: .blocks)
        kind = try c.decodeIfPresent(EaselDocumentKind.self, forKey: .kind)
            ?? Self.inferredKind(title: title, blocks: blocks)
    }

    /// Documents saved before wave 28 have no kind. New Note made one text
    /// block at a fixed frame in a document titled "Note", so a document of
    /// one text block that keeps either reads as a note.
    static func inferredKind(title: String, blocks: [EaselBlock]) -> EaselDocumentKind {
        guard blocks.count == 1, case .text = blocks[0].payload else { return .easel }
        let noteFrame = EaselFrame(x: 120, y: 120, width: 420, height: 200)
        return title == "Note" || blocks[0].frame == noteFrame ? .note : .easel
    }
}

// MARK: - Blocks

public struct EaselRichTextRun: Equatable, Codable {
    public var text: String
    public var isBold: Bool
    public var isItalic: Bool
    public var isUnderline: Bool
    /// When set (1–3), renders as a heading level for the run.
    public var headingLevel: Int?

    public init(
        text: String,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        headingLevel: Int? = nil
    ) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.headingLevel = headingLevel
    }
}

public struct EaselColor: Equatable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = EaselColor(red: 0.1, green: 0.1, blue: 0.12)
    public static let accent = EaselColor(red: 0.35, green: 0.45, blue: 0.95)
}

public struct EaselFrame: Equatable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(width, 8)
        self.height = max(height, 8)
    }
}

public enum EaselShapeKind: String, Codable, CaseIterable {
    case rectangle
    case ellipse
    case arrow
}

public enum EaselBlockPayload: Equatable, Codable {
    case text(runs: [EaselRichTextRun])
    case image(captureID: UUID)
    case shape(kind: EaselShapeKind, color: EaselColor, arrowEnd: EaselPoint?)
}

public struct EaselPoint: Equatable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct EaselBlock: Identifiable, Equatable, Codable {
    public var id: UUID
    public var frame: EaselFrame
    public var payload: EaselBlockPayload

    public init(id: UUID = UUID(), frame: EaselFrame, payload: EaselBlockPayload) {
        self.id = id
        self.frame = frame
        self.payload = payload
    }
}

// MARK: - Sidebar reference (document id only)

/// Sidebar row pointing at an easel document stored outside the sidebar snapshot.
public struct SidebarEaselRef: Identifiable, Equatable, Codable {
    public let id: UUID
    public var easelDocumentID: UUID
    public var sortRank: String

    public init(id: UUID = UUID(), easelDocumentID: UUID, sortRank: String = "") {
        self.id = id
        self.easelDocumentID = easelDocumentID
        self.sortRank = sortRank
    }

    enum CodingKeys: String, CodingKey {
        case id, easelDocumentID, sortRank
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        easelDocumentID = try c.decode(UUID.self, forKey: .easelDocumentID)
        sortRank = try c.decodeIfPresent(String.self, forKey: .sortRank) ?? ""
    }
}

// MARK: - Document mutations (pure)

public enum EaselDocumentOps {
    public static func insertBlock(_ block: EaselBlock, at index: Int? = nil, in document: inout EaselDocument) {
        let clamped = min(max(index ?? document.blocks.count, 0), document.blocks.count)
        document.blocks.insert(block, at: clamped)
        document.updatedAt = Date()
    }

    public static func updateBlock(_ block: EaselBlock, in document: inout EaselDocument) {
        guard let index = document.blocks.firstIndex(where: { $0.id == block.id }) else { return }
        document.blocks[index] = block
        document.updatedAt = Date()
    }

    public static func removeBlock(id: UUID, from document: inout EaselDocument) {
        document.blocks.removeAll { $0.id == id }
        document.updatedAt = Date()
    }

    public static func moveBlock(id: UUID, toZIndex index: Int, in document: inout EaselDocument) {
        guard let from = document.blocks.firstIndex(where: { $0.id == id }) else { return }
        var blocks = document.blocks
        let block = blocks.remove(at: from)
        let clamped = min(max(index, 0), blocks.count)
        blocks.insert(block, at: clamped)
        document.blocks = blocks
        document.updatedAt = Date()
    }

    public static func bringForward(id: UUID, in document: inout EaselDocument) {
        guard let from = document.blocks.firstIndex(where: { $0.id == id }),
              from < document.blocks.count - 1 else { return }
        document.blocks.swapAt(from, from + 1)
        document.updatedAt = Date()
    }

    public static func noteDocument(title: String = "Note") -> EaselDocument {
        let textBlock = EaselBlock(
            frame: EaselFrame(x: 120, y: 120, width: 420, height: 200), // inferredKind matches this frame
            payload: .text(runs: [EaselRichTextRun(text: "")])
        )
        return EaselDocument(title: title, kind: .note, blocks: [textBlock])
    }

    public static func emptyEasel(title: String = "Untitled Easel") -> EaselDocument {
        EaselDocument(title: title)
    }
}
