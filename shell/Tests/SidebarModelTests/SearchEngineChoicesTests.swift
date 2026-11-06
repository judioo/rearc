import XCTest
@testable import SidebarModel

/// ABI 1.46 `search_engines`: the Settings pop-up's list of default-search choices.
final class SearchEngineChoicesTests: XCTestCase {
    private let google = SearchEngineChoices.Engine(id: 2, name: "Google", keyword: "google.com",
                                                    searchTemplate: "https://www.google.com/search?q=%s",
                                                    isDefault: true, isPrepopulated: true)
    private let ddg = SearchEngineChoices.Engine(id: 7, name: "DuckDuckGo", keyword: "duckduckgo.com",
                                                 searchTemplate: "https://duckduckgo.com/?q=%s", isPrepopulated: true)

    func testCurrentIsTheDefaultRow() {
        XCTAssertEqual(SearchEngineChoices(engines: [ddg, google]).current?.id, 2)
        XCTAssertNil(SearchEngineChoices(engines: []).current)
    }

    func testSelectingMovesTheDefault() {
        let after = SearchEngineChoices(engines: [google, ddg]).selecting(7)
        XCTAssertEqual(after.current?.id, 7)
        XCTAssertEqual(after.engines.filter(\.isDefault).count, 1)
    }

    func testSelectingAnUnknownOrLockedEngineChangesNothing() {
        let choices = SearchEngineChoices(engines: [google, ddg])
        XCTAssertEqual(choices.selecting(99), choices)
        var locked = ddg
        locked.canMakeDefault = false
        let lockedChoices = SearchEngineChoices(engines: [google, locked])
        XCTAssertEqual(lockedChoices.selecting(7), lockedChoices)
    }

    func testAManagedDefaultIsNotEditable() {
        XCTAssertTrue(SearchEngineChoices(engines: [google, ddg]).isEditable)
        var g = google, d = ddg
        g.canMakeDefault = false
        d.canMakeDefault = false
        XCTAssertFalse(SearchEngineChoices(engines: [g, d], isManaged: true).isEditable)
        XCTAssertFalse(SearchEngineChoices(engines: [google], isManaged: true).isEditable, "policy wins over row flags")
    }

    func testAnEngineBecomesACommandBarProvider() {
        let provider = SearchEngineChoices.provider(ddg)
        XCTAssertEqual(provider.name, "DuckDuckGo")
        XCTAssertEqual(provider.searchURL(for: "arc browser")?.absoluteString, "https://duckduckgo.com/?q=arc%20browser")
        XCTAssertNil(provider.suggestTemplate)
    }
}
