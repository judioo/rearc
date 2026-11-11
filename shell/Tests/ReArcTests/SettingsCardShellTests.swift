import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Settings rebuilt as Arc's window (FEATURE-SPECS/SETTINGS.md §11–12): the
/// membership card's file and moments on the model, its picture, the
/// account's name, and the full-screen Esc hint placed clear of the
/// toolbar's buttons (QA-2026-11-07 open issue 25).
@MainActor
final class SettingsCardShellTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-card-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeModel() -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-card-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-card-links-\(UUID().uuidString)")!
        return model
    }

    private func waitForSaves() {
        let done = expectation(description: "saved")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testTheFirstLaunchSetsReArcsStartDateOnce() throws {
        let model = makeModel()
        let day = Date(timeIntervalSinceReferenceDate: 784_000_000)
        model.membershipCard.now = { day }
        let card = model.membershipCard.ensureLoaded()
        XCTAssertEqual(card.rearcMemberSince, day)
        XCTAssertFalse(card.hasArcHistory)
        XCTAssertEqual(card.palette, 0, "a new card wears the profile's theme")
        waitForSaves()
        // The next launch reads it back: the date doesn't move.
        let later = makeModel()
        later.membershipCard.now = { day.addingTimeInterval(86_400 * 40) }
        XCTAssertEqual(later.membershipCard.ensureLoaded().rearcMemberSince, day)
        XCTAssertEqual(later.membershipCard.ensureLoaded().title, card.title)
    }

    func testTheLaunchReadLandsOffTheMainThread() {
        let first = makeModel()
        let card = first.membershipCard.ensureLoaded()
        waitForSaves()
        let model = makeModel()
        XCTAssertNil(model.membershipCard.card, "nothing read at init")
        model.membershipCard.loadInBackground()
        let deadline = Date().addingTimeInterval(2)
        while model.membershipCard.card == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(model.membershipCard.card, card)
    }

    func testAnImportedCardPlaysItsTransitionOnceThenOnReplay() throws {
        let model = makeModel()
        model.membershipCard.accountTabAppeared(reduceMotion: true)
        XCTAssertNil(model.membershipCard.transitionStart, "a plain ReArc card has no story")
        model.importArcMembershipCard(ArcMembershipCardImport(title: "STATUESQUE HUNTER", palette: 6, shape: 2,
                                                              memberSince: Date(timeIntervalSinceReferenceDate: 738_929_101.8), name: "Akilu"))
        XCTAssertFalse(model.membershipCard.ensureLoaded().transitionShown)
        model.membershipCard.accountTabAppeared(reduceMotion: true)
        XCTAssertNotNil(model.membershipCard.transitionStart)
        XCTAssertTrue(model.membershipCard.ensureLoaded().transitionShown)
        // Reduce Motion's cross-fade ends after 0.3 s.
        let ended = expectation(description: "ended")
        DispatchQueue.main.asyncAfter(deadline: .now() + MembershipCardTransition.reducedDuration + 0.2) {
            XCTAssertNil(model.membershipCard.transitionStart)
            ended.fulfill()
        }
        wait(for: [ended], timeout: 2)
        model.membershipCard.accountTabAppeared(reduceMotion: true)
        XCTAssertNil(model.membershipCard.transitionStart, "once only")
        model.membershipCard.playTransition(reduceMotion: false)
        XCTAssertNotNil(model.membershipCard.transitionStart, "Replay")
    }

    func testTheCardsNameAndTheAccountsName() {
        let model = makeModel()
        XCTAssertEqual(model.accountName, model.store.activeProfile.name)
        XCTAssertEqual(model.membershipCardName, model.accountName)
        XCTAssertEqual(SettingsPane.account.title(accountName: model.accountName), model.accountName)
        model.importArcMembershipCard(ArcMembershipCardImport(name: "Akilu"))
        XCTAssertEqual(model.membershipCardName, "Akilu")
        model.recordOnboardingName("   ")
        XCTAssertEqual(model.membershipCardName, "Akilu", "a blank Act 1 name changes nothing")
        model.changeAccountName("Ada")
        XCTAssertEqual(model.accountName, "Ada", "Change Name… renames the profile")
        XCTAssertEqual(model.membershipCardName, "Ada")
    }

    func testRandomizeIsSaved() throws {
        let model = makeModel()
        let before = model.membershipCard.ensureLoaded()
        model.randomizeMembershipCard()
        let after = model.membershipCard.ensureLoaded()
        XCTAssertNotEqual(after.title, before.title)
        XCTAssertEqual(after.rearcMemberSince, before.rearcMemberSince)
        waitForSaves()
        XCTAssertEqual(MembershipCardFile.load(from: model.membershipCard.fileURL)?.title, after.title)
    }

    func testTheCardOffersArcsCardOnlyWhenThereIsOne() throws {
        let support = directory.appendingPathComponent("Support", isDirectory: true)
        let model = makeModel()
        XCTAssertFalse(model.canImportArcMembershipCard(applicationSupport: support))
        let arc = ArcMembershipCardImport.folder(in: support)
        try FileManager.default.createDirectory(at: arc, withIntermediateDirectories: true)
        try Data(#"{"title": "X Y", "paletteNumber": 2}"#.utf8).write(to: arc.appendingPathComponent(ArcMembershipCardImport.cardFileName))
        try Data(#"{"session": {"user": {"createdAt": 738929101.8}}}"#.utf8).write(to: arc.appendingPathComponent(ArcMembershipCardImport.authFileName))
        XCTAssertTrue(model.canImportArcMembershipCard(applicationSupport: support))
        XCTAssertTrue(model.importArcMembershipCardFromArc(applicationSupport: support))
        XCTAssertFalse(model.canImportArcMembershipCard(applicationSupport: support), "imported: no second offer")
        model.randomizeMembershipCard()
        XCTAssertTrue(model.canImportArcMembershipCard(applicationSupport: support))
        XCTAssertTrue(model.importArcMembershipCardFromArc(applicationSupport: support))
        XCTAssertFalse(model.canImportArcMembershipCard(applicationSupport: support))
        model.membershipCard.update { $0.arcMemberSince = nil }
        XCTAssertTrue(model.canImportArcMembershipCard(applicationSupport: support), "recover history from older imports")
    }

    func testTheDownloadIsTheCardAtFourTimesOnItsBackdrop() throws {
        let card = MembershipCard.fresh(now: Date())
        let data = try XCTUnwrap(MembershipCardExport.pngData(card: card, name: "Ada", theme: SpaceColor(red: 0.3, green: 0.4, blue: 0.9)))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(image.pixelsWide, 1648)
        XCTAssertEqual(image.pixelsHigh, 2124)
        XCTAssertEqual(MembershipCardExport.fileName(for: "Ada"), "Ada_ReArc.png")
        XCTAssertEqual(MembershipCardExport.fileName(for: "a/b"), "a-b_ReArc.png")
    }

    func testTheIconItemDrawsReArcsMark() {
        let image = ReArcMark.templateImage()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 20, height: 20))
        let paths = ReArcMark.paths(in: CGRect(x: 0, y: 0, width: 512, height: 512))
        XCTAssertFalse(paths.mono.isEmpty)
        XCTAssertTrue(paths.sun.boundingBox.maxY < paths.blue.boundingBox.maxY, "the sun sits behind the arc")
    }

    // MARK: Full screen (open issue 25)

    func testTheFullScreenHintSitsUnderTheToolbarNotOverItsButtons() {
        let model = makeModel()
        model.showToast("Copied Current URL", systemImage: "link")
        XCTAssertEqual(model.toast?.placement, .corner, "other toasts keep Arc's corner")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        model.nativeFullscreenChanged(true, window: window)
        XCTAssertEqual(model.toast?.message, "To exit full screen, press esc")
        XCTAssertEqual(model.toast?.placement, .belowToolbar)
        model.nativeFullscreenChanged(false, window: window)
        XCTAssertNil(model.toast)
    }
}
