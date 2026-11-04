import Foundation

public struct BoostInterchangeDocument: Codable, Equatable, Sendable {
    public static let formatName = "rearc.boost.package"
    public static let formatVersion = 1

    public var format: String
    public var formatVersion: Int
    public var manifest: BoostManifest
    public var styleBoost: BoostStylePayload?
    public var scriptBoost: BoostScriptPayload?
    public var metadata: BoostMetadata
    public var provenance: BoostProvenance

    public init(from package: BoostPackage) {
        format = Self.formatName
        formatVersion = Self.formatVersion
        manifest = package.manifest
        styleBoost = package.styleBoost
        scriptBoost = package.scriptBoost
        metadata = package.metadata
        provenance = package.provenance
    }

    public func toPackage() -> BoostPackage {
        BoostPackage(
            manifest: manifest,
            styleBoost: styleBoost,
            scriptBoost: scriptBoost,
            metadata: metadata,
            provenance: provenance
        )
    }
}

public enum BoostInterchangeError: Equatable, Sendable {
    case invalidFormat
    case unsupportedVersion
    case validationFailed([BoostSecurityError])
    case decodeFailed
}

public enum BoostInterchange {
    public static func exportJSON(_ package: BoostPackage) throws -> Data {
        let doc = BoostInterchangeDocument(from: package)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(doc)
    }

    public enum ImportOutcome: Equatable, Sendable {
        case success(BoostPackage)
        case failure(BoostInterchangeError)
    }

    public static func importJSON(_ data: Data, sourceURL: String? = nil) -> ImportOutcome {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let doc = try? decoder.decode(BoostInterchangeDocument.self, from: data) else {
            return .failure(.decodeFailed)
        }
        guard doc.format == BoostInterchangeDocument.formatName else {
            return .failure(.invalidFormat)
        }
        guard doc.formatVersion == BoostInterchangeDocument.formatVersion else {
            return .failure(.unsupportedVersion)
        }
        if doc.styleBoost != nil, doc.scriptBoost?.js != nil {
            return .failure(.validationFailed([BoostSecurityError.scriptInStylePackage]))
        }
        var package = doc.toPackage()
        let errors = BoostSecurity.validatePackage(package)
        if !errors.isEmpty { return .failure(.validationFailed(errors)) }

        package.manifest.id = UUID()
        package.manifest.version = 1
        package.manifest.createdAt = Date()
        package.manifest.updatedAt = Date()
        package.provenance = BoostProvenance(imported: true, sourceURL: sourceURL)
        // A file cannot grant itself permission to run: the user allows it here.
        package.scriptBoost?.userScriptEnabled = false
        return .success(package)
    }

    /// Boost files: `<name>.rearcboost`, JSON in this format.
    public static let fileExtension = "rearcboost"

    /// A file name for an exported boost: its name without path or control characters.
    public static func suggestedFileName(for package: BoostPackage) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let name = package.manifest.name.unicodeScalars.map { unsafe.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return (name.isEmpty ? "Boost" : name) + "." + fileExtension
    }

    public static func describe(_ error: BoostInterchangeError) -> String {
        switch error {
        case .invalidFormat: return "This file is not a ReArc boost."
        case .unsupportedVersion: return "This boost was made by a newer ReArc."
        case .decodeFailed: return "This file could not be read as a boost."
        case .validationFailed(let errors):
            if errors.contains(.remoteImportInCSS) || errors.contains(.remoteScriptSourceInJS) {
                return "The boost loads files from the web, which ReArc does not allow."
            }
            return "The boost did not pass ReArc's checks."
        }
    }

    public static func defaultEnabledOnImport(_ package: BoostPackage) -> Bool {
        package.hasScript ? false : true
    }
}
