import Foundation
import Testing
@testable import SidebarModel

/// `cloudkit/schema.ckdb` is what each release imports into Development and
/// deploys to Production (docs/ICLOUD-SETUP.md §7). Production only ever adds,
/// so the file must keep every type, field and index already deployed.
struct CloudKitSchemaTests {
    private static let shell = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Record type → field or GRANT line → its normalized definition.
    private static func recordTypes(_ schema: String) throws -> [String: [String: String]] {
        let block = try NSRegularExpression(pattern: #"RECORD TYPE (\w+)\s*\(([^;]*)\)\s*;"#)
        var types: [String: [String: String]] = [:]
        for match in block.matches(in: schema, range: NSRange(schema.startIndex..., in: schema)) {
            let name = String(schema[Range(match.range(at: 1), in: schema)!])
            let body = String(schema[Range(match.range(at: 2), in: schema)!])
            var fields: [String: String] = [:]
            for line in body.split(separator: ",").map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }) where !line.isEmpty {
                if line.hasPrefix("GRANT ") {
                    fields[line] = line
                } else {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    fields[parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))] = parts.count > 1 ? parts[1] : ""
                }
            }
            types[name] = fields
        }
        return types
    }

    @Test func theFileIsWellFormedSchemaLanguage() throws {
        let schema = try String(contentsOf: Self.shell.appendingPathComponent("cloudkit/schema.ckdb"), encoding: .utf8)
        #expect(schema.hasPrefix("DEFINE SCHEMA\n"))
        let types = try Self.recordTypes(schema)
        #expect(schema.components(separatedBy: "RECORD TYPE ").count - 1 == types.count, "every RECORD TYPE block parses")
        let definition = try NSRegularExpression(pattern: #"^(ENCRYPTED )?(ASSET|BYTES|DOUBLE|INT64|LOCATION|REFERENCE|STRING|TIMESTAMP|LIST<\w+>)( QUERYABLE| SORTABLE| SEARCHABLE)*$"#)
        let grant = try NSRegularExpression(pattern: #"^GRANT (READ|WRITE|CREATE)( ?, ?(READ|WRITE|CREATE))* TO "_\w+"$"#)
        for (type, fields) in types {
            for (field, value) in fields {
                let pattern = field.hasPrefix("GRANT ") ? grant : definition
                #expect(pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil, "\(type).\(field): \(value)")
            }
        }
        // The default Users type stays as the Development export has it (no index on the record ID).
        #expect(types["Users"]?["roles"] == "LIST<INT64>")
        #expect(types["Users"]?["___recordID"] == "REFERENCE")
    }

    @Test func everyRuntimeKindAndTransportWriteHasADeployedSchemaDefinition() throws {
        let schema = try String(contentsOf: Self.shell.appendingPathComponent("cloudkit/schema.ckdb"), encoding: .utf8)
        let transport = try String(contentsOf: Self.shell.appendingPathComponent("Sources/SidebarModel/Sync/CloudKitSyncTransport.swift"), encoding: .utf8)
        let types = try Self.recordTypes(schema)
        let writePattern = try NSRegularExpression(pattern: #"record(?:\.encryptedValues)?\["([^"\n]+)"\]\s*="#)
        let writes = writePattern.matches(in: transport, range: NSRange(transport.startIndex..., in: transport))
        let keys = Set(writes.map { String(transport[Range($0.range(at: 1), in: transport)!]) })
        #expect(keys == ["payload", "isDeleted", "schemaVersion", "clientTimestamp"], "a new field needs a schema line (and a deployment)")
        // Keep writes inspectable: a computed key would slip past the check above.
        let allWrites = try NSRegularExpression(pattern: #"record(?:\.encryptedValues)?\[[^\n]+?\]\s*="#)
        #expect(allWrites.numberOfMatches(in: transport, range: NSRange(transport.startIndex..., in: transport)) == writes.count)
        let expected = ["payload": "ENCRYPTED BYTES", "isDeleted": "INT64 QUERYABLE SORTABLE",
                        "schemaVersion": "INT64 QUERYABLE SORTABLE", "clientTimestamp": "INT64 QUERYABLE SORTABLE"]
        for kind in SyncRecordKind.allCases {
            let fields = try #require(types[kind.rawValue], "Missing record type \(kind.rawValue) in cloudkit/schema.ckdb")
            for key in keys {
                #expect(fields[key] == expected[key], "\(kind.rawValue).\(key)")
            }
            // Deployed: QUERYABLE and SORTABLE on the three integers, nothing else.
            let indexes = fields.filter { !$0.key.hasPrefix("GRANT ") }.values
                .flatMap { $0.split(separator: " ") }.filter { ["QUERYABLE", "SORTABLE", "SEARCHABLE"].contains($0) }
            #expect(indexes.count == 6, "\(kind.rawValue) has \(indexes.count) indexes")
            for grant in [#"GRANT WRITE TO "_creator""#, #"GRANT CREATE TO "_icloud""#, #"GRANT READ TO "_world""#] {
                #expect(fields[grant] != nil, "\(kind.rawValue) keeps \(grant)")
            }
        }
    }
}
