import XCTest
@testable import SidebarModel

/// Security RC-0.1.0-564 S-02 (the auto-hiding bar shows a new origin) and RC-0.1.0-544 N-06
/// (long hosts keep their real domain in prompts).
final class TrustedOriginDisplayTests: XCTestCase {
    func testAnOriginChangeRevealsTheBarForAFewSeconds() {
        var state = AddressBarVisibility(autoHideEnabled: true)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 0)
        XCTAssertFalse(state.isRevealed)
        state.reveal(for: AddressBarVisibility.originRevealDuration, now: 10)
        XCTAssertTrue(state.isRevealed)
        // Pointer moves elsewhere: the reveal is not cut short.
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 10.5)
        state.hideIfDue(at: 11)
        XCTAssertTrue(state.isRevealed)
        // Hovering the bar and leaving early keeps it until the reveal ends.
        state.update(autoHideEnabled: true, pointer: .toolbar, hasKeyboardFocus: false, now: 11)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 11.2)
        state.hideIfDue(at: 11.6)
        XCTAssertTrue(state.isRevealed)
        state.hideIfDue(at: 10 + AddressBarVisibility.originRevealDuration)
        XCTAssertFalse(state.isRevealed)
        XCTAssertNil(state.revealedUntil)
    }

    func testRevealIsANoOpWithAFixedBar() {
        var state = AddressBarVisibility(autoHideEnabled: false)
        state.reveal(for: 3, now: 0)
        XCTAssertNil(state.revealedUntil)
        XCTAssertNil(state.hideDeadline)
    }

    func testAPromptHoldsTheBarLikeFocus() {
        var state = AddressBarVisibility(autoHideEnabled: true)
        // The container treats a page prompt as focus: shown with no deadline while it is up.
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: true, now: 0)
        state.hideIfDue(at: 100)
        XCTAssertTrue(state.isRevealed)
        state.update(autoHideEnabled: true, pointer: .outside, hasKeyboardFocus: false, now: 100)
        XCTAssertEqual(state.hideDeadline, 100 + AddressBarVisibility.hideDelay)
    }

    func testLongHostsKeepTheirRegistrableDomain() {
        let host = "accounts.google.com.verify-session.evil.example"
        let short = PageOrigin.shortenedHost(host)
        XCTAssertTrue(short.hasSuffix("evil.example"), short)
        XCTAssertTrue(short.hasPrefix("…"), short)
        XCTAssertFalse(short.contains("google"), short)
        XCTAssertLessThanOrEqual(short.count, 36)
        XCTAssertEqual(PageOrigin.shortenedHost("meet.google.com"), "meet.google.com", "short hosts are untouched")
        let insecure = PageOrigin.shortenedHost("http://login.bank.example.attacker-controlled-subdomain.co.uk:8443")
        XCTAssertTrue(insecure.hasPrefix("http://…"), insecure)
        XCTAssertTrue(insecure.hasSuffix(".co.uk:8443"), insecure)
        // A registrable domain longer than the limit is still shown whole.
        let long = "a.\(String(repeating: "x", count: 60)).example"
        XCTAssertEqual(PageOrigin.shortenedHost(long), "…\(String(repeating: "x", count: 60)).example")
    }
}
