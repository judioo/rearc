import XCTest
@testable import SidebarModel

/// Build 677's avatar types, as in its Profile.swift (unchanged since before
/// 608): synthesized decoding, which skips keys it does not know.
private struct Avatar677: Codable, Equatable {
    enum Kind: Codable, Equatable {
        case sfSymbol(name: String)
        case emoji(String)
    }

    var kind: Kind
}

final class ProfileAvatarCompatibilityTests: XCTestCase {
    private let picture = ProfileAvatarImageName(rawValue: String(repeating: "ab", count: 32) + ".jpg")!

    private func encoded(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func load677() throws -> (SidebarSnapshot, SidebarFilePersistence) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-677-\(UUID().uuidString)/sidebar.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Sidebar677Fixture.json.utf8).write(to: file)
        let persistence = SidebarFilePersistence(fileURL: file)
        return (try XCTUnwrap(persistence.loadSnapshot()), persistence)
    }

    // MARK: Descriptor

    func testDescriptorWithoutAPictureEncodesAsBefore() throws {
        XCTAssertEqual(try encoded(ProfileAvatarDescriptor.personalDefault()), #"{"kind":{"sfSymbol":{"name":"person.fill"}}}"#)
        XCTAssertEqual(try encoded(ProfileAvatarDescriptor(kind: .emoji("💖"))), #"{"kind":{"emoji":{"_0":"💖"}}}"#)
    }

    func testDescriptorWithAPictureRoundTrips() throws {
        let avatar = ProfileAvatarDescriptor(kind: .emoji("💖"), image: picture)
        let json = try encoded(avatar)
        XCTAssertEqual(json, #"{"image":"\#(picture.rawValue)","kind":{"emoji":{"_0":"💖"}}}"#)
        XCTAssertEqual(try JSONDecoder().decode(ProfileAvatarDescriptor.self, from: Data(json.utf8)), avatar)
    }

    func testDecodingIsTotal() throws {
        func decode(_ json: String) throws -> ProfileAvatarDescriptor {
            try JSONDecoder().decode(ProfileAvatarDescriptor.self, from: Data(json.utf8))
        }
        // A kind from a later build: the default symbol, the picture kept.
        XCTAssertEqual(try decode(#"{"kind":{"photo":{"_0":"x"}},"image":"\#(picture.rawValue)"}"#),
                       ProfileAvatarDescriptor(kind: .sfSymbol(name: "person.fill"), image: picture))
        // A name that is not ours (here one reaching out of the folder): the kind alone.
        XCTAssertEqual(try decode(#"{"kind":{"emoji":{"_0":"🙂"}},"image":"../../sidebar.json"}"#), ProfileAvatarDescriptor(kind: .emoji("🙂")))
        XCTAssertEqual(try decode(#"{"kind":{"emoji":{"_0":"🙂"}},"image":42}"#), ProfileAvatarDescriptor(kind: .emoji("🙂")))
        XCTAssertEqual(try decode(#"{}"#), .personalDefault())

        let id = UUID()
        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"\#(id)","name":"Work","avatar":5}"#.utf8))
        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.avatar, .personalDefault(), "a broken avatar never fails the profile")
    }

    func testBuild677ReadsAPictureAvatarAsItsSymbolOrEmoji() throws {
        let json = try encoded(ProfileAvatarDescriptor(kind: .emoji("💖"), image: picture))
        XCTAssertEqual(try JSONDecoder().decode(Avatar677.self, from: Data(json.utf8)), Avatar677(kind: .emoji("💖")))
        // A Kind case instead would have thrown in 677, so its sidebar.json would have been quarantined.
        XCTAssertThrowsError(try JSONDecoder().decode(Avatar677.self, from: Data(#"{"kind":{"image":{"_0":"x"}}}"#.utf8)))
    }

    // MARK: sidebar.json

    func testA677SidebarFileLoadsAsItWas() throws {
        let (snapshot, persistence) = try load677()
        XCTAssertEqual(persistence.loadOutcome, .loaded)
        let ids = Sidebar677Fixture.profileIDs
        XCTAssertEqual(snapshot.profiles.map(\.id), [ids.personal, ids.akilu, ids.akliu])
        XCTAssertEqual(snapshot.profiles.map(\.avatar), [
            ProfileAvatarDescriptor(kind: .sfSymbol(name: "briefcase.fill")),
            ProfileAvatarDescriptor(kind: .emoji("💖")),
            .personalDefault(),
        ])
        XCTAssertEqual(SidebarStore(snapshot: snapshot).profileMenuRows(active: ids.personal).map(\.spaceCountText),
                       ["2 spaces", "2 spaces", "1 space"])
    }

    func testAPictureAddsOneKeyThatOlderBuildsSkip() throws {
        let (snapshot, _) = try load677()
        var withPicture = snapshot
        withPicture.profiles[1].avatar.image = picture
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func object(_ snapshot: SidebarSnapshot) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? NSDictionary)
        }
        let before = try object(snapshot)
        let after = try object(withPicture)
        let profiles = try XCTUnwrap(after["profiles"] as? [[String: Any]])
        let avatar = try XCTUnwrap(profiles[1]["avatar"] as? [String: Any])
        XCTAssertEqual(avatar["image"] as? String, picture.rawValue)

        // Take the one key away and the file is what 677 wrote from the same sidebar.
        let stripped = after.mutableCopy() as! NSMutableDictionary
        stripped["profiles"] = profiles.map { profile -> [String: Any] in
            var profile = profile
            var avatar = profile["avatar"] as? [String: Any] ?? [:]
            avatar["image"] = nil
            profile["avatar"] = avatar
            return profile
        }
        XCTAssertEqual(stripped, before)

        // 677's avatar decoding of every profile in the new file.
        let data = try JSONSerialization.data(withJSONObject: profiles.map { $0["avatar"]! })
        XCTAssertEqual(try JSONDecoder().decode([Avatar677].self, from: data),
                       [Avatar677(kind: .sfSymbol(name: "briefcase.fill")), Avatar677(kind: .emoji("💖")),
                        Avatar677(kind: .sfSymbol(name: "person.fill"))])

        // And this build reads its own file back with the picture.
        let reread = try JSONDecoder().decode(SidebarSnapshot.self, from: encoder.encode(withPicture))
        XCTAssertEqual(reread.profiles[1].avatar.image, picture)
    }

    func testThePictureAddsOnlyItsNameToTheSyncedProfileRecord() throws {
        let (snapshot, _) = try load677()
        var withPicture = snapshot
        withPicture.profiles[1].avatar.image = picture
        let name = SyncRecordKind.profile.recordName(for: Sidebar677Fixture.profileIDs.akilu)
        let before = try JSONEncoder().encode(XCTUnwrap(SidebarSyncProjection.extract(snapshot)[name]?.values))
        let after = try JSONEncoder().encode(XCTUnwrap(SidebarSyncProjection.extract(withPicture)[name]?.values))
        XCTAssertLessThan(after.count - before.count, 128, "the name, never the picture")
    }
}

private extension SidebarStore {
    convenience init(snapshot: SidebarSnapshot) {
        self.init()
        applySnapshot(snapshot)
    }
}
