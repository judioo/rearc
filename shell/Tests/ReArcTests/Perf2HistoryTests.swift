import Foundation
import Testing
@testable import SidebarModel

struct Perf2HistoryTests {
    static func history() -> VisitHistory {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return VisitHistory(records: (0..<5_000).map { index in
            VisitRecord(url: URL(string: "https://site\(index).test/docs/\(index)")!,
                        title: "Design notes release \(index)", visitCount: index % 40 + 1,
                        firstVisit: now.addingTimeInterval(-Double(index) * 600))
        })
    }


    @Test func preparedHistoryPreservesRankingAndExclusions() {
        let history = Self.history()
        let index = VisitHistorySearchIndex(history: history)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let excluded = Set(history.records.keys.sorted().prefix(80))
        for query in ["d", "design n", "SITE4", " notes  release ", "site4 docs", "4999", "missing", "", ">tab"] {
            for limit in [0, 1, 5, 50] {
                #expect(index.matches(for: query, now: now, limit: limit, excluding: excluded)
                        == history.matches(for: query, now: now, limit: limit, excluding: excluded))
            }
        }
        let store = BenchFixture.make(.items500, seed: 1) { URL(string: "https://tabs.test/\($0)")! }.store
        for query in ["d", "design", "site4", "https://site4.test/docs/4", ">tab"] {
            #expect(CommandBarSearch.results(for: query, in: store, history: history, historyIndex: index, now: now)
                    == CommandBarSearch.results(for: query, in: store, history: history, now: now))
        }
    }

    @Test func preparedHistoryTracksWritesEvictionAndDecoding() throws {
        var history = Self.history()
        let snapshot = history
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let newURL = URL(string: "https://www.unicode.test/Über#section")!
        history.recordVisit(url: newURL, title: "Über design — notes", at: now)
        #expect(history.count == VisitHistory.capacity)
        history.recordVisit(url: newURL, title: "Design revised", at: now.addingTimeInterval(1))
        history.updateTitle(url: newURL, title: "Über design revised")
        history.remove(url: URL(string: "https://site0.test/docs/0")!)
        func check(_ value: VisitHistory) {
            for query in ["design", "über", "unicode", "notes", "site0", "site4999", "revised"] {
                #expect(value.searchIndex.matches(for: query, now: now, limit: 20)
                        == value.matches(for: query, now: now, limit: 20))
            }
        }
        check(history)
        check(snapshot)
        let encoded = try JSONEncoder().encode(history)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == ["records"], "the derived index must not change the persisted format")
        let decoded = try JSONDecoder().decode(VisitHistory.self, from: encoded)
        #expect(decoded == history)
        check(decoded)
        history.removeAll()
        #expect(history.searchIndex.matches(for: "design", now: now).isEmpty)
    }

}
