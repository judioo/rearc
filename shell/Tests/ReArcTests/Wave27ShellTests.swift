import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

private final class FakeAutofillPanels: AutofillPanelPresenting {
    var shown: [AutofillPopup] = []
    var hidden = 0
    func show(_ popup: AutofillPopup, for prompts: PagePromptCenter) { shown.append(popup) }
    func hide(for prompts: PagePromptCenter) { hidden += 1 }
}

private final class FakeBackend: ExtensionToolbarBackend {
    var refreshed = 0
    var runs: [String] = []
    var changes = 0
    func refreshActions(for engine: any WebEngine, scale: CGFloat) { refreshed += 1 }
    func runAction(_ extensionID: String, for engine: any WebEngine, anchor: NSView?) { runs.append(extensionID) }
    func selectedEngineChanged(_ engine: (any WebEngine)?) { changes += 1 }
}

/// Wave 27: the page's autofill list, save offers and sign-in sheet; the
/// extensions controller; the self-test's Chromium switches.
final class Wave27ShellTests: XCTestCase {

    private func popup(_ id: UInt64, rows: [AutofillSuggestionRow]) -> AutofillPopup {
        AutofillPopup(requestID: id, tabID: 1, product: .address, field: CGRect(x: 0, y: 0, width: 300, height: 30), rows: rows)
    }

    func testAutofillListShowsSelectsAcceptsAndHides() {
        let prompts = PagePromptCenter()
        let panels = FakeAutofillPanels()
        prompts.autofillPanels = panels
        var accepted: [(UInt64, Int)] = [], selected: [Int?] = [], dismissed: [UInt64] = []
        let actions = PagePromptCenter.AutofillActions(
            accept: { accepted.append(($0, $1)); return .accepted },
            select: { _, row in selected.append(row) },
            dismiss: { dismissed.append($0) }
        )
        let rows = [AutofillSuggestionRow(id: 0, value: "Rearc Tester"),
                    AutofillSuggestionRow(id: 1, value: "", kind: .separator, isAcceptable: false),
                    AutofillSuggestionRow(id: 2, value: "Manage…", kind: .manage)]
        prompts.showAutofill(popup(7, rows: rows), actions: actions)
        XCTAssertEqual(panels.shown.count, 1)
        prompts.selectAutofillRow(requestID: 7, row: 0)
        XCTAssertEqual(prompts.autofill?.selected, 0)
        prompts.selectAutofillRow(requestID: 99, row: 2)
        XCTAssertEqual(prompts.autofill?.selected, 0, "a stale list's selection is ignored")
        prompts.previewAutofillRow(0)
        prompts.previewAutofillRow(2)
        XCTAssertEqual(selected, [0, nil], "only fill rows preview")
        prompts.acceptAutofillRow(1)
        XCTAssertTrue(accepted.isEmpty, "separators are not accepted")
        prompts.acceptAutofillRow(0)
        XCTAssertEqual(accepted.first?.0, 7)
        XCTAssertEqual(accepted.first?.1, 0)
        prompts.hideAutofill(requestID: 99)
        XCTAssertNotNil(prompts.autofill, "another list's hide changes nothing")
        prompts.dismissAutofill()
        XCTAssertEqual(dismissed, [7])
        XCTAssertNil(prompts.autofill)
        XCTAssertEqual(panels.hidden, 1)
    }

    func testBusyAcceptIsRetriedAfterTheGuard() {
        let prompts = PagePromptCenter()
        prompts.autofillPanels = FakeAutofillPanels()
        var attempts = 0
        let retried = expectation(description: "retried")
        let actions = PagePromptCenter.AutofillActions(
            accept: { _, _ in
                attempts += 1
                if attempts == 2 { retried.fulfill() }
                return attempts == 1 ? .busy : .accepted
            },
            select: { _, _ in }, dismiss: { _ in })
        prompts.showAutofill(popup(1, rows: [AutofillSuggestionRow(id: 0, value: "a")]), actions: actions)
        prompts.acceptAutofillRow(0)
        XCTAssertEqual(attempts, 1)
        wait(for: [retried], timeout: 2)
    }

    func testSaveOfferRepliesOnceAndANewerOneReplacesIt() {
        let prompts = PagePromptCenter()
        var replies: [(UInt64, AutofillSaveAction)] = []
        prompts.presentAutofillSave(AutofillSaveOffer(id: 1, kind: .card, isUpdate: false, origin: "", summary: "Visa •••• 1111")) { replies.append((1, $0)) }
        prompts.presentAutofillSave(AutofillSaveOffer(id: 2, kind: .address, isUpdate: false, origin: "", summary: "1 Test Way")) { replies.append((2, $0)) }
        XCTAssertEqual(replies.first?.1, .ignore)
        XCTAssertTrue(prompts.hasPendingPrompt)
        prompts.answerAutofillSave(.decline)
        prompts.answerAutofillSave(.accept)
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(replies.last?.1, .decline)
        prompts.presentAutofillSave(AutofillSaveOffer(id: 3, kind: .card, isUpdate: true, origin: "", summary: "")) { _ in XCTFail("withdrawn") }
        prompts.cancelAutofillSave(id: 3)
        XCTAssertNil(prompts.autofillSave)
    }

    func testSignInSheetQueuesSendsCredentialsOnceAndClearsThem() {
        let prompts = PagePromptCenter()
        var replies: [(UInt64, String?)] = []
        func challenge(_ id: UInt64) -> HTTPAuthChallenge {
            HTTPAuthChallenge(id: id, challenger: "http://127.0.0.1:1", scheme: "basic", realm: "r", isProxy: false)
        }
        prompts.presentHTTPAuth(challenge(1)) { replies.append((1, $0?.username)) }
        prompts.presentHTTPAuth(challenge(2)) { replies.append((2, $0.map { "\($0.username):\($0.password)" })) }
        prompts.authUsername = "rearc"
        prompts.authPassword = "secret"
        prompts.answerHTTPAuth(signIn: false)
        XCTAssertEqual(replies.first?.0, 1)
        XCTAssertNil(replies.first?.1 ?? nil, "cancel sends no credentials")
        XCTAssertEqual(prompts.httpAuth?.id, 2)
        XCTAssertEqual(prompts.authPassword, "", "the next sheet starts empty")
        prompts.authUsername = "rearc"
        prompts.authPassword = String(repeating: "x", count: 4097)
        prompts.answerHTTPAuth(signIn: true)
        XCTAssertEqual(replies.count, 1, "over-long credentials are not sent")
        prompts.authPassword = "local-secret"
        prompts.answerHTTPAuth(signIn: true)
        XCTAssertEqual(replies.last?.1, "rearc:local-secret")
        XCTAssertEqual(prompts.authPassword, "")
        XCTAssertNil(prompts.httpAuth)
        prompts.presentHTTPAuth(challenge(3)) { _ in XCTFail("withdrawn") }
        prompts.presentHTTPAuth(challenge(4)) { _ in XCTFail("withdrawn") }
        prompts.cancelHTTPAuth(id: 4)
        prompts.cancelHTTPAuth(id: 3)
        XCTAssertNil(prompts.httpAuth)
    }

    func testTeardownAnswersWebKitSignInsAndWithdrawsTheRest() {
        let prompts = PagePromptCenter()
        prompts.autofillPanels = FakeAutofillPanels()
        var cancelled = 0
        prompts.presentHTTPAuth(HTTPAuthChallenge(id: 1, challenger: "https://a.test:443", scheme: "digest", realm: "", isProxy: false)) {
            if $0 == nil { cancelled += 1 }
        }
        prompts.answerAllConservatively()
        XCTAssertEqual(cancelled, 1, "WebKit's completion handler is always called")
        prompts.presentAutofillSave(AutofillSaveOffer(id: 2, kind: .card, isUpdate: false, origin: "", summary: "")) { _ in XCTFail("withdrawn") }
        prompts.showAutofill(popup(3, rows: [AutofillSuggestionRow(id: 0, value: "a")]),
                             actions: .init(accept: { _, _ in .accepted }, select: { _, _ in }, dismiss: { _ in }))
        prompts.withdrawAll()
        XCTAssertNil(prompts.autofillSave)
        XCTAssertNil(prompts.autofill)
        XCTAssertFalse(prompts.hasPendingPrompt)
    }

    func testExtensionsControllerKeepsActionsPerEngineAndPinsInItsDefaults() {
        let defaults = UserDefaults(suiteName: "wave27-controller-\(UUID().uuidString)")!
        let controller = ExtensionsController(defaults: defaults)
        let backend = FakeBackend()
        controller.backend = backend
        let engine = WKEngine(context: EngineProfileContext(profileID: UUID()))
        controller.refresh(engine, scale: 2)
        XCTAssertEqual(backend.refreshed, 0, "unavailable (WebKit): nothing is asked")
        controller.run("a", for: engine, anchor: nil)
        XCTAssertTrue(backend.runs.isEmpty)
        controller.isAvailable = true
        controller.refresh(engine, scale: 2)
        XCTAssertEqual(backend.refreshed, 1)
        controller.setActions([ExtensionActionItem(id: "a", name: "A"), ExtensionActionItem(id: "b", name: "B")], for: engine)
        XCTAssertEqual(controller.actions(for: engine).map(\.id), ["a", "b"])
        controller.togglePin("b")
        XCTAssertEqual(controller.pinnedActions(for: engine).map(\.id), ["b"])
        XCTAssertEqual(ExtensionPins.load(from: defaults).pinnedIDs, ["b"])
        controller.run("b", for: engine, anchor: nil)
        XCTAssertEqual(backend.runs, ["b"])
        controller.forgetEngine(engine)
        XCTAssertTrue(controller.actions(for: engine).isEmpty)
        XCTAssertEqual(ExtensionsController.webStoreURL.host(), "chromewebstore.google.com")
    }

    func testSelfTestSwitchesKeepTheRunOffTheNetworkAndLoadTheFixtures() {
        let product = ["ReArc", "--user-data-dir=/tmp/x"]
        let arguments = ChromiumLaunchArguments.selfTestArguments(product, extensionDirs: ["/tmp/a", "/tmp/b"])
        for flag in ChromiumLaunchArguments.selfTestNoOutsideNetworkSwitches { XCTAssertTrue(arguments.contains(flag)) }
        XCTAssertTrue(arguments.contains("--load-extension=/tmp/a,/tmp/b"))
        XCTAssertTrue(arguments.contains(ChromiumLaunchArguments.selfTestAutofillFocusSwitch))
        XCTAssertFalse(ChromiumLaunchArguments.selfTestArguments(product).contains { $0.hasPrefix("--load-extension") })
        let product2 = ChromiumLaunchArguments.browserArguments(["ReArc"], defaultUserDataDir: { "/tmp/p" }, keychain: .system)
        XCTAssertFalse(product2.contains { $0.hasPrefix("--host-resolver-rules") }, "the product never gets the test switches")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wave27-localstate-\(UUID().uuidString)")
        ChromiumLaunchArguments.prepareSelfTestUserDataDir(dir)
        let state = try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("Local State"))) as? [String: Any]
        XCTAssertEqual((state?["dns_over_https"] as? [String: String])?["mode"], "off")
        try? FileManager.default.removeItem(at: dir)
    }
}
