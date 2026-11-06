import Onboarding
@testable import ReArc
import SidebarModel
import XCTest

@MainActor
final class FirstRunOnboardingTests: XCTestCase {
    func testWhoGetsTheSunrise() {
        XCTAssertEqual(FirstRunOnboarding.kind(isFirstRun: true, arguments: [], automated: false), .firstRun)
        XCTAssertNil(FirstRunOnboarding.kind(isFirstRun: false, arguments: [], automated: false), "an existing install opens straight away")
        XCTAssertEqual(FirstRunOnboarding.kind(isFirstRun: false, arguments: ["--onboarding"], automated: false), .rehearsal,
                       "forcing it on real data changes nothing")
        XCTAssertEqual(FirstRunOnboarding.kind(isFirstRun: true, arguments: ["--onboarding"], automated: false), .firstRun)
        XCTAssertNil(FirstRunOnboarding.kind(isFirstRun: true, arguments: ["--no-onboarding"], automated: false))
        XCTAssertNil(FirstRunOnboarding.kind(isFirstRun: true, arguments: ["--onboarding"], automated: true), "self-tests and benches never see it")
        XCTAssertTrue(FirstRunOnboarding.isAutomated(["rearc", EngineLaunchOptions.selfTestFlag]))
        XCTAssertTrue(FirstRunOnboarding.isAutomated(["rearc", EngineLaunchOptions.benchFlag + "=ui"]))
    }

    func testTheSampleGivesWayToYourChoices() throws {
        let store = SidebarStore.sample()
        let main = store.activeProfileID
        let sampleSpaces = store.spaces.map(\.id)
        let sampleFavorites = store.favorites(in: main).map(\.id)
        XCTAssertFalse(sampleFavorites.isEmpty)
        // As if Act 2 imported two spaces from Arc.
        let reading = store.addSpace(name: "Reading", iconName: "📚")
        let archive = store.addSpace(name: "Archive", iconName: "🗂️")
        let iris = ProfilePalette.colours[6].rgba
        let result = OnboardingResult(
            name: "Kai", colour: ProfilePalette.colours[5].rgba,
            spaces: [OnboardingSpace(hostID: reading.id.uuidString, name: "Books", icon: "🎨", colour: iris),
                     OnboardingSpace(hostID: nil, name: "Side project", icon: "🎮", colour: MarkPalette.sun)],
            removedHostIDs: [archive.id.uuidString])

        let first = OnboardingApplier.apply(result, to: store, mainProfileID: main,
                                            replacing: sampleSpaces, sampleFavorites: sampleFavorites)

        XCTAssertEqual(first, reading.id)
        XCTAssertEqual(store.spaces.map(\.name), ["Books", "Side project"], "sample and removed spaces are gone")
        let books = try XCTUnwrap(store.space(withID: reading.id))
        XCTAssertEqual(books.iconName, "🎨")
        XCTAssertEqual(books.theme.red, iris.r, accuracy: 1e-9)
        XCTAssertEqual(store.spaces[1].iconName, "🎮")
        XCTAssertEqual(store.spaces[1].profileID, main)
        XCTAssertEqual(store.profile(withID: main)?.name, "Kai")
        XCTAssertEqual(store.profile(withID: main)?.themeColor.blue ?? 0, ProfilePalette.colours[5].rgba.b, accuracy: 1e-9)
        XCTAssertTrue(store.favorites(in: main).isEmpty, "the sample's favorites go too")
    }

    func testNothingIsClearedWithoutSomethingToKeep() {
        let store = SidebarStore.sample()
        let before = store.spaces.map(\.id)
        OnboardingApplier.apply(OnboardingResult(name: "", colour: MarkPalette.sun, spaces: [], removedHostIDs: []),
                                to: store, mainProfileID: store.activeProfileID, replacing: before, sampleFavorites: [])
        XCTAssertEqual(store.spaces.map(\.id), before)
    }

    func testTheImportPlanFollowsAct2() {
        let sources = ImportSource.demo
        let plan = OnboardingImportPlan(sources: [sources[0], sources[2]], categories: [.spaces, .history])
        XCTAssertEqual(plan.arcDirectories, ["Default"])
        XCTAssertEqual(plan.chromium.map(\.browser), [.arc, .chrome])
        XCTAssertTrue(plan.spaces)
        XCTAssertFalse(plan.bookmarks)
        XCTAssertTrue(plan.history)
    }

    func testTheWelcomePageGreetsYouSafely() {
        let html = WelcomePage.html(name: "<Kai>", colour: MarkPalette.sun, spaces: 1,
                                    imported: ImportStats(spaces: 2, bookmarks: 1_204))
        XCTAssertTrue(html.contains("Welcome to ReArc, <span class=\"you\">&lt;Kai&gt;</span>."))
        XCTAssertTrue(html.contains("Your profile and 1 space is ready."))
        XCTAssertTrue(html.contains("1,204 bookmarks came with you."))
        XCTAssertTrue(html.contains("REFOCUSED · RESTORED · REARC"))
        XCTAssertFalse(WelcomePage.html(name: "", colour: MarkPalette.sun, spaces: 3, imported: nil).contains("came with you"))
    }
}
