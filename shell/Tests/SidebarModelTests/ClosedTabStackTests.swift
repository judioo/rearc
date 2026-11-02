import XCTest
@testable import SidebarModel

final class ClosedTabStackTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testStackCapacity() {
        var stack = ClosedTabStack()
        let spaceID = UUID()
        for index in 0 ..< 30 {
            stack.push(ClosedTabRecord(
                tab: Tab(kind: .today, title: "T\(index)", url: url("https://t\(index).test")),
                spaceID: spaceID
            ))
        }
        XCTAssertEqual(stack.records.count, ClosedTabStack.capacity)
        XCTAssertEqual(stack.records.first?.tab.title, "T5")
        XCTAssertEqual(stack.records.last?.tab.title, "T29")
    }

    func testCloseTabPushesAndReopenRestores() {
        let space = Space(name: "Home")
        let store = SidebarStore(spaces: [space])
        let tab = store.addTab(kind: .today, title: "Gone", url: url("https://gone.test"))
        store.selectTab(tab.id)
        store.closeTab(tab.id)
        XCTAssertTrue(store.closedTabStack.canReopen)
        let restored = store.reopenMostRecentClosedTab()
        XCTAssertEqual(restored?.title, "Gone")
        XCTAssertEqual(store.selectedTabID, restored?.id)
        XCTAssertEqual(store.content(for: space.id).today.count, 1)
    }

    func testV2SnapshotMigratesToV3Fields() throws {
        let store = SidebarStore.sample()
        let data = try JSONEncoder().encode(store.makeSnapshot())
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["schemaVersion"] = 2
        object.removeValue(forKey: "closedTabStack")
        object.removeValue(forKey: "commandBarUsageBumps")
        let v2Data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: v2Data)
        XCTAssertEqual(decoded.schemaVersion, 9)
        XCTAssertTrue(decoded.closedTabStack.records.isEmpty)
        XCTAssertTrue(decoded.commandBarUsageBumps.isEmpty)
    }

    func testV3RoundTripsBumpsAndClosedStack() throws {
        let store = SidebarStore(spaces: [Space(name: "One")])
        let tab = store.addTab(kind: .today, title: "Bye", url: url("https://bye.test"))
        store.closeTab(tab.id)
        store.bumpCommandUsage("close-tab")
        let data = try JSONEncoder().encode(store.makeSnapshot())
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 9)
        XCTAssertEqual(decoded.closedTabStack.records.count, 1)
        XCTAssertEqual(decoded.commandBarUsageBumps["close-tab"], 1)
    }
}
