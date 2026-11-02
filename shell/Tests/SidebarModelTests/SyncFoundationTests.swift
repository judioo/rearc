import XCTest
@testable import SidebarModel

final class LexoRankTests: XCTestCase {
    func testBetweenAfterBeforeOrdering() {
        let a = LexoRank.initial
        let b = LexoRank.after(a)
        let mid = LexoRank.between(a, b)
        XCTAssertTrue(a < mid)
        XCTAssertTrue(mid < b)
        XCTAssertEqual(LexoRank.before(b), a)
    }

    func testInitialSequenceIsSorted() {
        let ranks = LexoRank.initialSequence(count: 5)
        XCTAssertEqual(ranks.count, 5)
        for index in 0 ..< ranks.count - 1 {
            XCTAssertTrue(ranks[index] < ranks[index + 1])
        }
    }

    func testRebalanceTriggersOnCollision() {
        let ranks = ["A", "A"]
        XCTAssertTrue(LexoRank.needsRebalance(ranks))
        let balanced = LexoRank.rebalance(ranks)
        XCTAssertEqual(Set(balanced).count, balanced.count)
    }

    func testThousandSequentialAfterWithoutForcedRebalance() {
        var current: String? = LexoRank.initial
        for _ in 0 ..< 1000 {
            current = LexoRank.after(current)
        }
        let rank = current!
        XCTAssertFalse(LexoRank.needsRebalance([rank]))
        XCTAssertLessThan(rank.count, LexoRank.rebalanceLengthThreshold)
    }
}

final class MutationJournalTests: XCTestCase {
    func testMonotonicSequenceAndRing() {
        let device = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let journal = SidebarMutationJournal(deviceID: device)
        for index in 0 ..< 520 {
            journal.record(.focusSpace(spaceID: UUID()))
            if index == 519 {
                let all = journal.allEntries()
                XCTAssertLessThanOrEqual(all.count, SidebarMutationJournal.ringCapacity + 20)
            }
        }
        XCTAssertGreaterThan(journal.allEntries().last?.sequence ?? 0, 500)
    }

    func testInsertMoveDeleteItemJournalTypes() throws {
        let store = SidebarStore()
        let space = store.spaces[0].id
        let tab = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!, in: space)
        _ = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!, in: space)
        store.updateTab(tab.id, title: "A2")
        _ = store.moveTab(tab.id, to: 1)
        store.closeTab(tab.id)
        let extra = store.addSpace(name: "Extra")
        store.selectSpace(extra.id)
        let mutations = store.mutationJournal.allEntries().map(\.mutation)
        _ = space
        XCTAssertTrue(mutations.contains { if case .insertItem = $0 { return true }; return false })
        XCTAssertTrue(mutations.contains { if case .upsertItem = $0 { return true }; return false })
        XCTAssertTrue(mutations.contains { if case .moveItem = $0 { return true }; return false })
        XCTAssertTrue(mutations.contains { if case .deleteItem = $0 { return true }; return false })
        XCTAssertTrue(mutations.contains { if case .insertSpace = $0 { return true }; return false })
        XCTAssertTrue(mutations.contains { if case .focusSpace = $0 { return true }; return false })
    }
}

final class MutationCoalescerTests: XCTestCase {
    func testSquashesTwentyMovesToSingleEntry() {
        let device = UUID()
        var entries: [SidebarJournalEntry] = []
        for index in 0 ..< 20 {
            entries.append(
                SidebarJournalEntry(
                    sequence: UInt64(index + 1),
                    timestamp: Date(),
                    deviceID: device,
                    mutation: .moveItem(
                        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                        spaceID: UUID(),
                        container: .unpinned,
                        sortRank: "R\(index)"
                    )
                )
            )
        }
        let squashed = MutationCoalescer.squash(entries)
        XCTAssertEqual(squashed.count, 1)
        if case .moveItem(_, _, _, let rank) = squashed[0].mutation {
            XCTAssertEqual(rank, "R19")
        } else {
            XCTFail("Expected moveItem")
        }
    }

    func testBurstTwentyMovesProducesAtMostTwoBatches() throws {
        let engine = RecordingSyncEngine()
        let journal = SidebarMutationJournal(deviceID: UUID())
        let coalescer = MutationCoalescer(window: 0.05)
        let pipeline = SyncOutboundPipeline(journal: journal, engine: engine, coalescer: coalescer)
        let itemID = UUID()
        let spaceID = UUID()
        for index in 0 ..< 20 {
            let entry = SidebarJournalEntry(
                sequence: UInt64(index + 1),
                timestamp: Date(),
                deviceID: UUID(),
                mutation: .moveItem(id: itemID, spaceID: spaceID, container: .unpinned, sortRank: "S\(index)")
            )
            pipeline.handleJournalEntry(entry)
        }
        let expectation = expectation(description: "coalesced flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) {
            coalescer.flushNow()
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
        XCTAssertLessThanOrEqual(engine.pushBatches.count, 2)
        let lastBatch = try XCTUnwrap(engine.pushBatches.last)
        XCTAssertEqual(lastBatch.count, 1)
        if case .moveItem(_, _, _, let rank) = lastBatch[0].mutation {
            XCTAssertEqual(rank, "S19")
        }
    }
}

private final class RecordingSyncEngine: SyncEngine, @unchecked Sendable {
    var status: SyncEngineStatus = .idleSynced
    var onStatusChange: (@Sendable (SyncEngineStatus) -> Void)?
    private(set) var pushBatches: [[SidebarJournalEntry]] = []

    func start() {}
    func stop() {}
    func push(_ entries: [SidebarJournalEntry]) {
        pushBatches.append(entries)
    }

    func pull(since sequence: UInt64) async throws -> SyncPullResult {
        _ = sequence
        return SyncPullResult()
    }
}

final class CloudKitMappingTests: XCTestCase {
    func testMapsItemMoveToSidebarItemRecord() {
        let itemID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let entry = SidebarJournalEntry(
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            deviceID: UUID(),
            mutation: .moveItem(id: itemID, spaceID: nil, container: .favorite, sortRank: "M")
        )
        let mapped = CloudKitRecordMapper.map(journalEntry: entry)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].recordType, .sidebarItem)
        XCTAssertEqual(mapped[0].recordName, "item_\(itemID.uuidString.lowercased())")
        XCTAssertEqual(mapped[0].sortRank, "M")
        XCTAssertEqual(mapped[0].spaceID, "global")
    }

    func testFocusSpaceMapsToContainerMeta() {
        let spaceID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let entry = SidebarJournalEntry(
            sequence: 2,
            timestamp: Date(),
            deviceID: UUID(),
            mutation: .focusSpace(spaceID: spaceID)
        )
        let mapped = CloudKitRecordMapper.map(journalEntry: entry)
        XCTAssertEqual(mapped[0].recordType, .containerMeta)
        XCTAssertEqual(mapped[0].focusedSpaceID, spaceID.uuidString.lowercased())
    }
}

final class SnapshotV9MigrationTests: XCTestCase {
    func testV8PayloadMigratesToV9WithRanks() throws {
        let store = SidebarStore.sample()
        var snapshot = store.makeSnapshot()
        for id in snapshot.tabsByID.keys {
            snapshot.tabsByID[id]?.sortRank = ""
        }
        for index in snapshot.spaces.indices {
            snapshot.spaces[index].sortRank = ""
        }
        var data = try JSONEncoder().encode(snapshot)
        if var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object["schemaVersion"] = 8
            data = try JSONSerialization.data(withJSONObject: object)
        }
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 9)
        XCTAssertFalse(decoded.tabsByID.values.contains { $0.sortRank.isEmpty })
        XCTAssertFalse(decoded.spaces.contains { $0.sortRank.isEmpty })
    }
}

final class RankIntegrationTests: XCTestCase {
    func testReorderPreservesRankOrder() {
        let store = SidebarStore()
        let space = store.spaces[0].id
        let a = store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!, in: space)
        let b = store.addTab(kind: .today, title: "B", url: URL(string: "https://b.test")!, in: space)
        _ = store.moveTab(b.id, to: 0)
        let ranks = store.content(for: space).today.compactMap { entry -> String? in
            if case .tab(let tab) = entry { return tab.sortRank }
            return nil
        }
        XCTAssertEqual(ranks.count, 2)
        XCTAssertTrue(ranks[0] < ranks[1])
        _ = a
    }
}

final class CloudKitAvailabilityTests: XCTestCase {
    func testDevBuildDetectsMissingEntitlement() {
        XCTAssertFalse(CloudKitSyncAvailability.hasCloudKitEntitlement)
        let engine = CloudKitSyncAvailability.makeEngine()
        if case .unavailable = engine.status {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected unavailable sync without entitlements, got \(engine.status)")
        }
    }
}
