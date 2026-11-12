import XCTest
import SidebarModel
@testable import ReArc

final class UpdatePreferencesTests: XCTestCase {
    func testBetaChannelPreferencePersistsAndCanBeDisabled() throws {
        let suite = "UpdatePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(UpdatePreferences.allowedChannels(in: defaults), [])
        defaults.set(true, forKey: UpdatePreferences.betaKey)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(UpdatePreferences.allowedChannels(in: reopened), ["beta"])
        reopened.set(false, forKey: UpdatePreferences.betaKey)
        XCTAssertEqual(UpdatePreferences.allowedChannels(in: defaults), [])
    }

    func testMenuStateTracksAvailableUpdateAndClearsBadge() {
        var state = UpdateMenuState()
        XCTAssertEqual(state.title, "Check for Updates…")
        XCTAssertEqual(state.badgeCount, 0)
        state.updateAvailable = true
        XCTAssertEqual(state.title, "Update Available…")
        XCTAssertEqual(state.badgeCount, 1)
        state.updateAvailable = false
        XCTAssertEqual(state, UpdateMenuState())
    }
}
