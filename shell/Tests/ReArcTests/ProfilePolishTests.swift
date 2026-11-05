import XCTest
@testable import ReArc
@testable import SidebarModel

final class ProfilePolishTests: XCTestCase {
    func testAvatarEditIsScopedAndSurvivesEncoding() throws {
        let store = SidebarStore()
        let personal = store.activeProfile
        let work = store.addProfile(name: "Work")
        let emoji = ProfileAvatarDescriptor(kind: .emoji("💼"))
        XCTAssertNil(store.setProfileAvatar(emoji, for: work.id))
        XCTAssertEqual(store.profile(withID: personal.id)?.avatar, personal.avatar)
        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(store.profile(withID: work.id)!))
        XCTAssertEqual(decoded.avatar, emoji)
        XCTAssertEqual(store.setProfileAvatar(emoji, for: UUID()), .profileNotFound)
        store.selectProfile(work.id)
        XCTAssertEqual(store.activeSpace.profileID, work.id)
        XCTAssertEqual(store.activeProfile.avatar, emoji)
        store.selectProfile(personal.id)
        XCTAssertEqual(store.activeSpace.profileID, personal.id)
    }

    func testColdProfileDiskProbeRunsOffMainAndReturnsOnMain() {
        let done = expectation(description: "profile plan")
        let id = UUID()
        ChromiumProfileStorageIO.plan(for: id, map: .init(), legacyOwner: id,
                                     engine: .init(canOpenDirectory: true, startupDirectory: "Default"),
                                     userDataDir: URL(fileURLWithPath: "/unused"), directoryExists: { _ in
            XCTAssertFalse(Thread.isMainThread)
            return true
        }) { plan in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(plan, .keepNamed(ChromiumProfileKey.storageKey(for: id)))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testProfileMapWritesAreOrdered() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("map.json")
        var first = ChromiumProfileStorageMap()
        first.recordDirectory("First", for: UUID())
        var second = first
        second.recordDirectory("Second", for: UUID())
        let done = expectation(description: "ordered writes")
        done.expectedFulfillmentCount = 2
        ChromiumProfileStorageIO.save(first, to: url) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        ChromiumProfileStorageIO.save(second, to: url) { error in
            XCTAssertNil(error)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(ChromiumProfileStorageMap.load(from: url), second)
    }
}
