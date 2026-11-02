import XCTest
@testable import SidebarModel

final class TypeTravelFuzzyMatchTests: XCTestCase {

    func testSubsequenceRequired() {
        XCTAssertNil(TypeTravelFuzzyMatch.match(query: "xyz", in: "New Tab"))
        XCTAssertNotNil(TypeTravelFuzzyMatch.match(query: "nt", in: "New Tab"))
    }

    func testConsecutiveCharactersScoreHigher() {
        let scattered = TypeTravelFuzzyMatch.match(query: "nt", in: "New Tab")!.score
        let consecutive = TypeTravelFuzzyMatch.match(query: "new", in: "New Tab")!.score
        XCTAssertGreaterThan(consecutive, scattered)
    }

    func testWordBoundaryBonus() {
        let boundary = TypeTravelFuzzyMatch.match(query: "tab", in: "Close Tab")!.score
        let mid = TypeTravelFuzzyMatch.match(query: "los", in: "Close Tab")!.score
        XCTAssertGreaterThan(boundary, mid)
    }

    func testShorterTitleTiebreakViaBestScore() {
        let a = TypeTravelFuzzyMatch.bestScore(query: "pin", title: "Pin Tab", keywords: [])!.score
        let b = TypeTravelFuzzyMatch.bestScore(query: "pin", title: "Pin Tab to Space", keywords: [])!.score
        XCTAssertGreaterThan(a, b)
    }
}
