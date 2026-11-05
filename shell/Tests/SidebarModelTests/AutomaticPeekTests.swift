import Foundation
import Testing
@testable import SidebarModel

struct AutomaticPeekTests {
    @Test(arguments: [Tab.Kind.pinned, .favorite])
    func persistentTabsOpenOffSiteLinks(kind: Tab.Kind) {
        #expect(AutomaticPeek.shouldOpen(kind: kind, source: URL(string: "https://mail.example.com/inbox")!,
                                        destination: URL(string: "https://other.org/article")!))
    }

    @Test(arguments: [
        ("https://mail.example.com", "http://www.example.com:8080/a", false),
        ("https://a.example.co.uk", "https://b.example.co.uk", false),
        ("https://example.co.uk", "https://other.co.uk", true),
        ("https://alice.github.io", "https://bob.github.io", true),
        ("https://a.alice.github.io", "https://alice.github.io", false),
        ("https://example.com", "https://example.com.evil.org", true),
        ("http://127.0.0.1", "http://127.0.0.2", true),
        ("http://localhost:8000", "http://localhost:9000", false),
        ("https://EXAMPLE.com.", "https://example.com", false),
        ("https://example.com", "mailto:a@example.org", false),
        ("about:blank", "https://example.com", false)
    ])
    func domains(pair: (String, String, Bool)) {
        #expect(AutomaticPeek.shouldOpen(kind: .pinned, source: URL(string: pair.0)!,
                                        destination: URL(string: pair.1)!) == pair.2)
    }

    @Test func routingOptOuts() {
        let source = URL(string: "https://example.com")!, destination = URL(string: "https://other.org")!
        #expect(!AutomaticPeek.shouldOpen(kind: .today, source: source, destination: destination))
        #expect(!AutomaticPeek.shouldOpen(kind: .favorite, source: source, destination: destination, enabled: false))
        #expect(!AutomaticPeek.shouldOpen(kind: .pinned, source: source, destination: destination, mainFrame: false))
        #expect(!AutomaticPeek.shouldOpen(kind: .pinned, source: source, destination: destination, modified: true))
    }
}
