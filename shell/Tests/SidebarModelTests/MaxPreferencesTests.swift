import XCTest
@testable import SidebarModel

/// Settings › Max's switches (FEATURE-SPECS/MAX.md §1): off until chosen,
/// Turn On All, future features, and the tab's wording, which says these
/// are scripted rules and not AI.
final class MaxPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "MaxPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTheTabHasArcsRowsLessPreviewsInArcsPlace() {
        XCTAssertEqual(MaxFeature.allCases, [.tidyTabs, .instantLinks, .tidyTabTitles, .tidyDownloads, .assistants])
        let panes = SettingsPane.allCases
        XCTAssertEqual(panes.firstIndex(of: .max), panes.firstIndex(of: .profiles).map { $0 + 1 })
        XCTAssertEqual(panes.firstIndex(of: .links), panes.firstIndex(of: .max).map { $0 + 1 })
    }

    func testEverythingIsOffUntilChosen() {
        let preferences = MaxPreferences.load(from: defaults)
        XCTAssertTrue(preferences.enabled.isEmpty)
        XCTAssertFalse(preferences.enablesFutureFeatures)
        for feature in MaxFeature.allCases { XCTAssertFalse(preferences.isOn(feature)) }
    }

    func testSwitchesAreSavedAndLoaded() {
        var preferences = MaxPreferences.load(from: defaults)
        preferences.set(.tidyTabTitles, on: true)
        preferences.set(.tidyDownloads, on: true)
        preferences.set(.tidyDownloads, on: false)
        preferences.save(to: defaults)
        let loaded = MaxPreferences.load(from: defaults)
        XCTAssertEqual(loaded.enabled, [.tidyTabTitles])
        XCTAssertEqual(loaded, preferences)
    }

    func testTurnOnAllTurnsOnEveryHelper() {
        var preferences = MaxPreferences()
        XCTAssertFalse(preferences.allOn)
        preferences.turnOnAll()
        XCTAssertTrue(preferences.allOn)
        XCTAssertEqual(preferences.enabled, Set(MaxFeature.allCases))
    }

    func testAFeatureFromALaterBuildIsOnOnlyWithAutomaticallyEnable() {
        // A Mac that knew every feature but Instant Links (as if it came later).
        defaults.set(["tidyTabs", "tidyTabTitles", "tidyDownloads", "assistants"], forKey: MaxPreferences.knownKey)
        defaults.set(["tidyTabTitles"], forKey: MaxPreferences.enabledKey)
        XCTAssertFalse(MaxPreferences.load(from: defaults).isOn(.instantLinks))

        defaults.set(["tidyTabs", "tidyTabTitles", "tidyDownloads", "assistants"], forKey: MaxPreferences.knownKey)
        defaults.set(true, forKey: MaxPreferences.futureKey)
        let adopted = MaxPreferences.load(from: defaults)
        XCTAssertTrue(adopted.isOn(.instantLinks))
        XCTAssertFalse(adopted.isOn(.tidyTabs), "only the new one; the others keep their switches")
        XCTAssertEqual(adopted.known, Set(MaxFeature.allCases))
    }

    func testUnknownNamesInDefaultsAreIgnored() {
        defaults.set(["tidyTabTitles", "fiveSecondPreviews", "chatGPT"], forKey: MaxPreferences.enabledKey)
        XCTAssertEqual(MaxPreferences.load(from: defaults).enabled, [.tidyTabTitles])
    }

    /// The owner's condition: the product says these are scripted, not AI.
    func testTheWordingNeverSuggestsIntelligence() {
        let banned = ["ai ", " ai", "ai-", "artificial", "intelligen", "smart", "model", "understand", "learn", "magic", "gpt"]
        for feature in MaxFeature.allCases where feature != .assistants {
            let text = " \(feature.title) \(feature.detail) ".lowercased()
            for word in banned { XCTAssertFalse(text.contains(word), "\(feature): “\(word)” in “\(text)”") }
        }
    }
}
