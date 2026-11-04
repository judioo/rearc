import Foundation

public enum BoostPayloadKind: String, Codable, Equatable, Sendable {
    case style
    case script
}

public struct BoostManifest: Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var version: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var hostScope: [BoostHostRule]
    public var payloadKinds: [BoostPayloadKind]

    public init(
        id: UUID = UUID(),
        name: String,
        version: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        hostScope: [BoostHostRule],
        payloadKinds: [BoostPayloadKind]
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.hostScope = hostScope
        self.payloadKinds = payloadKinds
    }
}

public struct BoostStylePayload: Codable, Equatable, Hashable, Sendable {
    public var css: String

    public init(css: String) {
        self.css = css
    }
}

public struct BoostScriptPayload: Codable, Equatable, Hashable, Sendable {
    public var css: String?
    public var js: String?
    /// User must explicitly enable before JS runs in the page.
    public var userScriptEnabled: Bool

    public init(css: String? = nil, js: String? = nil, userScriptEnabled: Bool = false) {
        self.css = css
        self.js = js
        self.userScriptEnabled = userScriptEnabled
    }
}

public struct BoostMetadata: Codable, Equatable, Hashable, Sendable {
    public var authorNote: String
    public var colorHex: String

    public init(authorNote: String = "", colorHex: String = "#6366F1") {
        self.authorNote = authorNote
        self.colorHex = colorHex
    }
}

public struct BoostProvenance: Codable, Equatable, Hashable, Sendable {
    public var imported: Bool
    public var sourceURL: String?

    public init(imported: Bool = false, sourceURL: String? = nil) {
        self.imported = imported
        self.sourceURL = sourceURL
    }
}

public struct BoostPackage: Codable, Equatable, Hashable, Sendable {
    public var manifest: BoostManifest
    public var styleBoost: BoostStylePayload?
    public var scriptBoost: BoostScriptPayload?
    public var metadata: BoostMetadata
    public var provenance: BoostProvenance

    public init(
        manifest: BoostManifest,
        styleBoost: BoostStylePayload? = nil,
        scriptBoost: BoostScriptPayload? = nil,
        metadata: BoostMetadata = BoostMetadata(),
        provenance: BoostProvenance = BoostProvenance()
    ) {
        self.manifest = manifest
        self.styleBoost = styleBoost
        self.scriptBoost = scriptBoost
        self.metadata = metadata
        self.provenance = provenance
    }

    public var hasScript: Bool {
        scriptBoost?.js?.isEmpty == false
    }

    public static func newStyle(name: String, hostScope: [BoostHostRule], css: String) -> BoostPackage {
        BoostPackage(
            manifest: BoostManifest(
                name: name,
                hostScope: hostScope,
                payloadKinds: [.style]
            ),
            styleBoost: BoostStylePayload(css: css)
        )
    }

    /// The script a new legacy boost starts with.
    public static let legacyScriptTemplate = "// Runs on matching pages once you allow this boost's script.\n"

    public static func newScript(name: String, hostScope: [BoostHostRule], js: String, css: String? = nil) -> BoostPackage {
        BoostPackage(
            manifest: BoostManifest(
                name: name,
                hostScope: hostScope,
                payloadKinds: [.script]
            ),
            scriptBoost: BoostScriptPayload(css: css, js: js, userScriptEnabled: false)
        )
    }
}
