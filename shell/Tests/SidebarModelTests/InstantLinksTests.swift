import XCTest
@testable import SidebarModel

/// Max › Instant Links' rules (MAX.md §6): which searches, and the address
/// each engine has for its first result. Nothing is fetched.
final class InstantLinksTests: XCTestCase {
    func testCommasSplitSearchesBlanksAndRepeatsGoAndFiveAreKept() {
        XCTAssertEqual(InstantLinks.plan(for: "swift testing").queries, ["swift testing"])
        XCTAssertEqual(InstantLinks.plan(for: " arc browser ,, Arc Browser, kagi ,").queries, ["arc browser", "kagi"])
        let many = InstantLinks.plan(for: "a1, b2, c3, d4, e5, f6, g7")
        XCTAssertEqual(many.queries, ["a1", "b2", "c3", "d4", "e5"])
        XCTAssertEqual(many.dropped, 2)
        XCTAssertEqual(many.cappedMessage, "Opened the first 5 searches; 2 more were left out.")
        XCTAssertNil(InstantLinks.plan(for: "one").cappedMessage)
        XCTAssertTrue(InstantLinks.plan(for: " , ").queries.isEmpty)
        XCTAssertEqual(InstantLinks.plan(for: "line\none").queries, ["line one"])
    }

    func testDuckDuckGoUsesItsBackslashGoogleItsLuckyButtonOthersTheirResultsPage() {
        XCTAssertEqual(InstantLinks.route(for: "swift testing", provider: .duckDuckGo),
                       .firstResult(URL(string: "https://duckduckgo.com/?q=%5Cswift%20testing")!))
        XCTAssertEqual(InstantLinks.route(for: "swift testing", provider: .google),
                       .firstResult(URL(string: "https://www.google.com/search?q=swift%20testing&btnI=1")!))
        XCTAssertEqual(InstantLinks.route(for: "swift testing", provider: .bing),
                       .resultsPage(URL(string: "https://www.bing.com/search?q=swift%20testing")!))
        XCTAssertEqual(InstantLinks.route(for: "x", provider: .ecosia)?.url.host(), "www.ecosia.org")
        XCTAssertEqual(InstantLinks.route(for: "x", provider: .brave), .resultsPage(URL(string: "https://search.brave.com/search?q=x")!))
        let regional = SearchProvider(id: "g-uk", name: "Google", keyword: "google.co.uk", searchTemplate: "https://www.google.co.uk/search?q=%s")
        XCTAssertEqual(InstantLinks.route(for: "x", provider: regional)?.url.absoluteString, "https://www.google.co.uk/search?q=x&btnI=1")
        XCTAssertNil(InstantLinks.route(for: "  ", provider: .google))
    }

    func testTermsCannotAddParametersToTheFirstResultAddress() throws {
        let route = try XCTUnwrap(InstantLinks.route(for: "a&btnI=0#frag", provider: .google))
        let items = URLComponents(url: route.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["q", "btnI"])
        XCTAssertEqual(items.first?.value, "a&btnI=0#frag")
        XCTAssertNil(route.url.fragment)
    }
}
