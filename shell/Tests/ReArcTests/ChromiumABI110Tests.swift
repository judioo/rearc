import XCTest
@testable import ReArc
@testable import SidebarModel

final class ChromiumABI110CapabilitiesTests: XCTestCase {
    private let allFeatures: (String) -> Bool = { _ in true }

    func testMinorTenAdoptsEveryAdvertisedFeature() {
        let capabilities = ChromiumCapabilities(abiMinorVersion: 10, hasFeature: allFeatures)
        XCTAssertTrue(capabilities.profiles && capabilities.profileOffTheRecord)
        XCTAssertTrue(capabilities.scriptEvaluationIdentity && capabilities.pageZoom)
        XCTAssertTrue(capabilities.isolatedPageMessages && capabilities.safeStorageBranding)
        XCTAssertEqual(capabilities.safeStorageKeychainItem, "ReArc Safe Storage")
        XCTAssertTrue(capabilities.summary.contains("profiles=1"))
        XCTAssertTrue(capabilities.summary.contains("isolated_page_messages=1"))
    }

    func testEachFeatureWaitsForTheMinorThatIntroducedIt() {
        let minor6 = ChromiumCapabilities(abiMinorVersion: 6, hasFeature: allFeatures)
        XCTAssertTrue(minor6.profiles && minor6.profileOffTheRecord)
        XCTAssertFalse(minor6.scriptEvaluationIdentity || minor6.pageZoom || minor6.isolatedPageMessages)
        XCTAssertFalse(minor6.safeStorageBranding)
        XCTAssertEqual(minor6.safeStorageKeychainItem, "Chromium Safe Storage")

        let minor8 = ChromiumCapabilities(abiMinorVersion: 8, hasFeature: allFeatures)
        XCTAssertTrue(minor8.scriptEvaluationIdentity && minor8.pageZoom)
        XCTAssertFalse(minor8.isolatedPageMessages)
    }

    func testDependentFeaturesNeedTheirBase() {
        let noProfiles = ChromiumCapabilities(abiMinorVersion: 10) { $0 != "profiles" }
        XCTAssertFalse(noProfiles.profiles)
        XCTAssertFalse(noProfiles.profileOffTheRecord, "off-the-record needs named profiles")

        let noEvaluation = ChromiumCapabilities(abiMinorVersion: 10) { $0 != "script_evaluation" }
        XCTAssertFalse(noEvaluation.scriptEvaluationIdentity, "identity needs script evaluation")
    }
}

final class ChromiumDocumentIdentityTests: XCTestCase {
    private let base = ChromiumDocumentIdentity(profileID: 2, tabID: 7, contentGeneration: 1, documentGeneration: 3, navigationID: 40)

    func testSameDocumentIgnoresNavigationUnlessRequired() {
        var sameDocumentNavigation = base
        sameDocumentNavigation.navigationID = 41
        XCTAssertTrue(base.isSameDocument(as: sameDocumentNavigation))
        XCTAssertFalse(base.isSameDocument(as: sameDocumentNavigation, sameNavigation: true))
        XCTAssertTrue(base.isSameDocument(as: base, sameNavigation: true))
    }

    func testAnyOtherFieldMeansAnotherDocument() {
        for change in [
            { (id: inout ChromiumDocumentIdentity) in id.profileID += 1 },
            { (id: inout ChromiumDocumentIdentity) in id.tabID += 1 },
            { (id: inout ChromiumDocumentIdentity) in id.contentGeneration += 1 },
            { (id: inout ChromiumDocumentIdentity) in id.documentGeneration += 1 },
        ] {
            var other = base
            change(&other)
            XCTAssertFalse(base.isSameDocument(as: other), "\(other)")
        }
    }
}

final class ChromiumProfileKeyTests: XCTestCase {
    private let profile = UUID(uuidString: "0A1B2C3D-4E5F-4061-8728-394A5B6C7D8E")!

    func testPersistentContextUsesTheLowercasedProfileUUID() {
        let key = ChromiumProfileKey(context: EngineProfileContext(profileID: profile), privateSession: UUID())
        XCTAssertEqual(key, .persistent(profile))
        XCTAssertEqual(key.storageKey, "0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e")
        XCTAssertTrue(ChromiumProfileKey.isValidStorageKey(key.storageKey!))
        XCTAssertFalse(key.isOffTheRecord)
    }

    func testEphemeralContextIsTheSessionsOffTheRecordProfile() {
        let session = UUID()
        let key = ChromiumProfileKey(context: EngineProfileContext(profileID: profile, isEphemeral: true), privateSession: session)
        XCTAssertEqual(key, .offTheRecord(session: session, parent: profile))
        XCTAssertTrue(key.isOffTheRecord)
        XCTAssertEqual(key.parentProfileID, profile)
        XCTAssertNil(key.storageKey, "off-the-record profiles are never opened by name")
        XCTAssertEqual(
            ChromiumProfileKey(context: EngineProfileContext(profileID: profile, isEphemeral: true), privateSession: session),
            key,
            "engines of one private session share one profile"
        )
    }

    func testStorageKeyRule() {
        XCTAssertTrue(ChromiumProfileKey.isValidStorageKey("A_b-9"))
        XCTAssertTrue(ChromiumProfileKey.isValidStorageKey(String(repeating: "a", count: 64)))
        XCTAssertFalse(ChromiumProfileKey.isValidStorageKey(""))
        XCTAssertFalse(ChromiumProfileKey.isValidStorageKey(String(repeating: "a", count: 65)))
        for bad in ["../x", "a/b", "a b", "a.b", "é"] {
            XCTAssertFalse(ChromiumProfileKey.isValidStorageKey(bad), bad)
        }
    }

    func testTeardownClosesOffTheRecordChildrenBeforeTheParent() {
        let other = UUID()
        let parent = ChromiumProfileKey.persistent(profile)
        let child1 = ChromiumProfileKey.offTheRecord(session: UUID(), parent: profile)
        let child2 = ChromiumProfileKey.offTheRecord(session: UUID(), parent: profile)
        let unrelated = ChromiumProfileKey.offTheRecord(session: UUID(), parent: other)
        let open = [parent, child1, .persistent(other), unrelated, child2]
        XCTAssertEqual(ChromiumProfileTeardown.closeOrder(for: parent, among: open), [child1, child2, parent])
        XCTAssertEqual(ChromiumProfileTeardown.closeOrder(for: child2, among: open), [child2])
        XCTAssertEqual(ChromiumProfileTeardown.closeOrder(for: .persistent(other), among: open), [unrelated, .persistent(other)])
    }
}

final class PageZoomTests: XCTestCase {
    func testStepsFollowThePresets() {
        XCTAssertEqual(PageZoom.factor(after: .zoomIn, from: 1.0), 1.1)
        XCTAssertEqual(PageZoom.factor(after: .zoomOut, from: 1.0), 0.9)
        XCTAssertEqual(PageZoom.factor(after: .reset, from: 2.5), 1.0)
        // A factor between presets moves to the next preset in that direction.
        XCTAssertEqual(PageZoom.factor(after: .zoomIn, from: 1.17), 1.25)
        XCTAssertEqual(PageZoom.factor(after: .zoomOut, from: 1.17), 1.1)
        // Round-trip noise from the engine counts as the same preset.
        XCTAssertEqual(PageZoom.factor(after: .zoomIn, from: 1.1001), 1.25)
    }

    func testStepsStayInRange() {
        XCTAssertEqual(PageZoom.factor(after: .zoomIn, from: 5.0), 5.0)
        XCTAssertEqual(PageZoom.factor(after: .zoomOut, from: 0.25), 0.25)
        XCTAssertEqual(PageZoom.factor(after: .zoomIn, from: .nan), 1.1, "an invalid factor steps from 100%")
    }

    func testValidityAndDisplay() {
        XCTAssertTrue(PageZoom.isValid(0.25) && PageZoom.isValid(5.0))
        XCTAssertFalse(PageZoom.isValid(0.2) || PageZoom.isValid(5.1) || PageZoom.isValid(.infinity))
        XCTAssertTrue(PageZoom.isDefault(1.0004))
        XCTAssertFalse(PageZoom.isDefault(1.1))
        XCTAssertEqual(PageZoom.percent(1.25), 125)
    }

    func testPickerPointsAreDividedByTheZoomFactor() {
        let css = PageZoom.cssPoint(fromViewPoint: CGPoint(x: 150, y: 300), zoom: 1.5)
        XCTAssertEqual(css.x, 100, accuracy: 0.0001)
        XCTAssertEqual(css.y, 200, accuracy: 0.0001)
        let view = PageZoom.viewPoint(fromCSSPoint: css, zoom: 1.5)
        XCTAssertEqual(view.x, 150, accuracy: 0.0001)
        XCTAssertEqual(PageZoom.cssPoint(fromViewPoint: CGPoint(x: 40, y: 8), zoom: .nan), CGPoint(x: 40, y: 8))
    }
}

final class BoostEditorPageMessageTests: XCTestCase {
    func testPickDecodesLikeTheWebKitBridge() throws {
        let json = #"{"type":"pick","descriptor":{"tag":"h1","classes":["title"],"structuralPath":["body","h1"]},"bounds":{"x":1,"y":2,"width":30,"height":4}}"#
        guard case .pick(let snapshot) = BoostEditorPageMessage.decode(json: json) else {
            return XCTFail("pick not decoded")
        }
        XCTAssertEqual(snapshot.descriptor.tag, "h1")
        XCTAssertEqual(snapshot.descriptor.structuralPath, ["body", "h1"])
        XCTAssertEqual(snapshot.bounds.width, 30)
    }

    func testCancelAndRejectedMessages() {
        guard case .cancel = BoostEditorPageMessage.decode(json: #"{"type":"cancel"}"#) else {
            return XCTFail("cancel not decoded")
        }
        XCTAssertNil(BoostEditorPageMessage.decode(json: #"{"type":"navigate","url":"https://x.test"}"#), "unknown kinds are data, not commands")
        XCTAssertNil(BoostEditorPageMessage.decode(json: #"{"type":"pick"}"#), "a pick without a descriptor")
        XCTAssertNil(BoostEditorPageMessage.decode(json: "not json"))
        XCTAssertNil(BoostEditorPageMessage.decode(json: #"["cancel"]"#))
        let oversized = #"{"type":"cancel","pad":""# + String(repeating: "x", count: BoostEditorPageMessage.maxJSONBytes) + #""}"#
        XCTAssertNil(BoostEditorPageMessage.decode(json: oversized))
    }
}

final class PrivateWindowTests: XCTestCase {
    private final class Presenter: BrowserWindowPresenting {
        var littleArc: [LittleArcWindow.ID] = []
        var privateWindows: [UUID] = []
        func presentLittleArcWindow(_ id: LittleArcWindow.ID) { littleArc.append(id) }
        func dismissLittleArcWindow(_ id: LittleArcWindow.ID) {}
        func presentPrivateWindow(_ window: PrivateWindowModel) { privateWindows.append(window.id) }
    }

    private func makeModel() -> (BrowserViewModel, Tab) {
        let store = SidebarStore(spaces: [Space(name: "Main")])
        let tab = store.addTab(kind: .today, title: "Start", url: URL(string: "https://a.test")!)
        store.selectTab(tab.id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString).json")
        return (BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: file)), tab)
    }

    func testWebKitPrivateWindowIsANonPersistentSceneRequest() {
        let (model, _) = makeModel()
        let window = model.openPrivateWindow()
        XCTAssertEqual(model.privateWindowOpenRequests, [window.id], "WebKit opens the private WindowGroup scene")
        XCTAssertEqual(window.parentProfileID, model.store.activeProfileID)
        let engine = window.engine as? WKEngine
        XCTAssertNotNil(engine)
        XCTAssertTrue(engine?.profileContext.isEphemeral == true)
        XCTAssertTrue(model.store.displayTabs().allSatisfy { $0.title == "Start" }, "nothing reaches the sidebar")
    }

    func testPresenterOpensWindowsWithoutScenes() {
        let (model, _) = makeModel()
        let presenter = Presenter()
        model.windowPresenter = presenter
        let window = model.openPrivateWindow()
        let record = model.openLittleArc(url: URL(string: "https://b.test")!)
        XCTAssertEqual(presenter.privateWindows, [window.id])
        XCTAssertEqual(presenter.littleArc, [record.id])
        XCTAssertTrue(model.privateWindowOpenRequests.isEmpty && model.littleArcOpenRequests.isEmpty)
    }

    func testSessionEndsWithItsLastWindow() {
        let (model, _) = makeModel()
        var ended: [UUID] = []
        model.onPrivateSessionEnded = { ended.append($0.session) }
        let first = model.openPrivateWindow()
        let popup = model.openPrivateWindow(session: first.session, parentProfileID: first.parentProfileID)
        let other = model.openPrivateWindow()
        model.privateWindowClosed(first.id)
        XCTAssertTrue(ended.isEmpty, "the popup keeps the session alive")
        model.privateWindowClosed(popup.id)
        XCTAssertEqual(ended, [first.session])
        model.privateWindowClosed(popup.id)
        XCTAssertEqual(ended, [first.session], "closing twice is a no-op")
        model.privateWindowClosed(other.id)
        XCTAssertEqual(ended, [first.session, other.session])
        XCTAssertTrue(model.privateWindows.isEmpty)
    }

    func testZoomCommandsTargetTheFocusedTab() {
        let (model, _) = makeModel()
        guard let engine = model.focusedEngine else { return XCTFail("no focused engine") }
        model.zoom(.zoomIn)
        XCTAssertEqual(engine.zoomFactor, 1.1, accuracy: 0.0001)
        model.zoom(.zoomIn)
        XCTAssertEqual(engine.zoomFactor, 1.25, accuracy: 0.0001)
        model.zoom(.reset)
        XCTAssertEqual(engine.zoomFactor, 1.0, accuracy: 0.0001)
        XCTAssertNil(model.keyPrivateWindow)
    }
}
