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

    private var data: URL!

    override func setUp() {
        super.setUp()
        data = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-first-run-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: data)
        super.tearDown()
    }

    private var sidebarFile: URL { data.appendingPathComponent("sidebar.json") }
    private var marker: URL { SidebarFilePersistence(fileURL: sidebarFile).onboardingMarkerURL }

    /// A launch on `data`, the store loaded as the app loads it.
    private func launch() -> BrowserViewModel {
        let model = BrowserViewModel(persistence: SidebarFilePersistence(fileURL: sidebarFile, debounceInterval: 0.01),
                                     syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-first-run-\(UUID().uuidString)")!
        return model
    }

    private func quit(_ model: BrowserViewModel) {
        model.store.addTab(kind: .today, title: "Mid-onboarding", url: URL(string: "https://example.com")!)
        model.persistence.flush()
        model.persistence.stop()
    }

    func testAFirstRunHasNoSampleContent() {
        let model = launch()
        XCTAssertTrue(model.isFirstRun)
        XCTAssertEqual(model.store.spaces.count, 1)
        XCTAssertTrue(model.store.displayTabs().isEmpty)
        XCTAssertTrue(model.store.profiles.allSatisfy { model.store.favorites(in: $0.id).isEmpty })
        XCTAssertNil(model.store.selectedItemID)
        XCTAssertEqual(FirstRunOnboarding.forLaunch(model, arguments: [], automated: false), .firstRun)
    }

    func testAnInterruptedOnboardingIsAFirstRunAgain() {
        let first = launch()
        XCTAssertEqual(FirstRunOnboarding.forLaunch(first, arguments: [], automated: false), .firstRun)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "marked before the onboarding changes anything")
        quit(first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidebarFile.path), "the sidebar is saved meanwhile")

        let second = launch()
        XCTAssertTrue(second.isFirstRun)
        XCTAssertEqual(FirstRunOnboarding.forLaunch(second, arguments: [], automated: false), .firstRun)
        // Its end, as the sunrise reports it.
        FirstRunOnboarding(kind: .firstRun, model: second) { [] }.onboardingFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        quit(second)

        let third = launch()
        XCTAssertFalse(third.isFirstRun)
        XCTAssertNil(FirstRunOnboarding.forLaunch(third, arguments: [], automated: false))
    }

    func testOnboardLaterShowsAReminderInsteadOfReplayingTheSunrise() {
        let model = launch()
        XCTAssertEqual(FirstRunOnboarding.forLaunch(model, arguments: [], automated: false), .firstRun)
        FirstRunOnboarding(kind: .firstRun, model: model) { [] }.onboardingDeferred()
        XCTAssertTrue(model.onboardingSetupState.showsCard)
        XCTAssertTrue(model.onboardingSetupState.showsMenuItem)
        XCTAssertEqual(ShellMenus.finishSetup(model).first?.first?.shownTitle, "Finish Setting Up ReArc…")
        quit(model)
        let relaunched = launch()
        XCTAssertFalse(relaunched.isFirstRun)
        XCTAssertTrue(relaunched.onboardingSetupState.showsCard)
        XCTAssertNil(FirstRunOnboarding.forLaunch(relaunched, arguments: [], automated: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "deferral is not completion")
    }

    func testDismissingTheCardKeepsTheMenuAcrossRestartsUntilCompletion() {
        let model = launch()
        _ = FirstRunOnboarding.forLaunch(model, arguments: [], automated: false)
        FirstRunOnboarding(kind: .firstRun, model: model) { [] }.onboardingDeferred()
        model.dismissOnboardingCard()
        XCTAssertFalse(model.onboardingSetupState.showsCard)
        XCTAssertTrue(model.onboardingSetupState.showsMenuItem)
        let menuItem = ShellMenus.finishSetup(model).first?.first
        XCTAssertEqual(menuItem?.shownTitle, "Finish Setting Up ReArc…")
        model.persistence.stop()

        let second = launch()
        XCTAssertFalse(second.onboardingSetupState.showsCard)
        XCTAssertTrue(second.onboardingSetupState.showsMenuItem)
        XCTAssertNil(FirstRunOnboarding.forLaunch(second, arguments: [], automated: false))
        second.finishFirstRunOnboarding()
        XCTAssertFalse(second.onboardingSetupState.showsMenuItem)
        second.persistence.stop()

        let third = launch()
        XCTAssertFalse(third.onboardingSetupState.showsCard)
        XCTAssertFalse(third.onboardingSetupState.showsMenuItem)
        XCTAssertNil(ShellMenus.finishSetup(third).first?.first?.shownTitle)
        XCTAssertNil(FirstRunOnboarding.forLaunch(third, arguments: [], automated: false))
    }

    func testStartFreshExplicitlyFinishesDeferredSetupWithoutASourceBrowser() {
        let model = launch()
        _ = FirstRunOnboarding.forLaunch(model, arguments: [], automated: false)
        FirstRunOnboarding(kind: .firstRun, model: model) { [] }.onboardingDeferred()
        let menuItem = ShellMenus.finishSetup(model).first?.first
        let session = BrowserImportSession(model: model, applicationSupport: data.appendingPathComponent("no-browsers"), arcDefaults: { [:] })
        XCTAssertTrue(session.canFinishSetup)
        session.performImport()
        XCTAssertTrue(model.onboardingSetupState.showsMenuItem, "opening or attempting an empty import does not finish setup")
        session.finishWithoutImporting()
        XCTAssertFalse(session.canFinishSetup)
        XCTAssertFalse(model.onboardingSetupState.showsCard)
        XCTAssertNil(menuItem?.shownTitle, "the existing menu entry updates on completion")
        model.persistence.stop()
        XCTAssertFalse(launch().onboardingSetupState.showsMenuItem)
    }

    func testAnUneditedFirstRunStillResumesAfterQuittingImmediately() {
        let first = launch()
        XCTAssertEqual(FirstRunOnboarding.forLaunch(first, arguments: [], automated: false), .firstRun)
        let profileID = first.store.activeProfileID
        first.persistence.stop()
        let second = launch()
        XCTAssertEqual(FirstRunOnboarding.forLaunch(second, arguments: [], automated: false), .firstRun)
        XCTAssertEqual(second.store.activeProfileID, profileID)
        XCTAssertFalse(second.onboardingSetupState.showsMenuItem)
    }

    func testAnExistingSidebarWithoutTheMarkerIsNotOnboarded() {
        let persistence = SidebarFilePersistence(fileURL: sidebarFile)
        persistence.start(autoSave: SidebarStore.sample())
        persistence.flush()
        persistence.stop()

        let model = launch()
        XCTAssertFalse(model.isFirstRun)
        XCTAssertFalse(model.onboardingSetupState.showsCard)
        XCTAssertFalse(model.onboardingSetupState.showsMenuItem)
        XCTAssertNil(ShellMenus.finishSetup(model).first?.first?.shownTitle)
        XCTAssertNil(FirstRunOnboarding.forLaunch(model, arguments: [], automated: false))
        XCTAssertEqual(FirstRunOnboarding.forLaunch(model, arguments: ["--onboarding"], automated: false), .rehearsal,
                       "--onboarding only rehearses")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(launch().isFirstRun)
    }

    func testSkippingTheOnboardingLeavesOneEmptySpace() {
        let model = launch()
        XCTAssertNil(FirstRunOnboarding.forLaunch(model, arguments: ["--no-onboarding"], automated: false))
        XCTAssertEqual(model.store.spaces.count, 1)
        XCTAssertTrue(model.store.displayTabs().isEmpty)
        XCTAssertTrue(model.store.profiles.allSatisfy { model.store.favorites(in: $0.id).isEmpty })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        // Nothing changed the starter; it is saved all the same.
        model.persistence.stop()
        let relaunch = launch()
        XCTAssertFalse(relaunch.isFirstRun, "skipped is over")
        XCTAssertEqual(relaunch.store.spaces.count, 1)
        XCTAssertTrue(relaunch.store.displayTabs().isEmpty)
    }

    func testSkippingAnInterruptedOnboardingEndsTheFirstRun() {
        let first = launch()
        _ = FirstRunOnboarding.forLaunch(first, arguments: [], automated: false)
        quit(first)
        let second = launch()
        XCTAssertNil(FirstRunOnboarding.forLaunch(second, arguments: ["--no-onboarding"], automated: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(launch().isFirstRun)
    }

    func testAutomatedLaunchesLeaveTheMarkerAlone() {
        let model = launch()
        XCTAssertNil(FirstRunOnboarding.forLaunch(model, arguments: [EngineLaunchOptions.selfTestFlag], automated: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let interrupted = launch()
        _ = FirstRunOnboarding.forLaunch(interrupted, arguments: [], automated: false)
        XCTAssertNil(FirstRunOnboarding.forLaunch(interrupted, arguments: [], automated: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
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
                                            replacing: sampleSpaces, starterFavorites: sampleFavorites)

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
                                to: store, mainProfileID: store.activeProfileID, replacing: before, starterFavorites: [])
        XCTAssertEqual(store.spaces.map(\.id), before)
    }

    func testTheImportPlanFollowsAct2() {
        let sources = ImportSource.demo
        let plan = OnboardingImportPlan(sources: [sources[0], sources[2]], categories: [.spaces, .history, .extensions])
        XCTAssertEqual(plan.arcDirectories, ["Default"])
        XCTAssertEqual(plan.chromium.map(\.browser), [.arc, .chrome])
        XCTAssertTrue(plan.spaces)
        XCTAssertFalse(plan.bookmarks)
        XCTAssertTrue(plan.history)
        XCTAssertTrue(plan.extensions)
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
