import XCTest
@testable import SidebarModel

/// Wave 27: extension toolbar, prompts and logical windows; autofill rows and
/// placement; save offers; HTTP auth; the leak check preference.
final class Wave27ModelTests: XCTestCase {

    // MARK: Extension actions

    func testActionItemBadgeTooltipAndColors() {
        let item = ExtensionActionItem(id: "a", name: "Popup", title: "ReArc popup", badgeText: " 12345 ",
                                       badgeBackgroundColor: 0xFFFF0000, hasPopup: true)
        XCTAssertEqual(item.displayBadge, "1234", "Chrome shows four characters at most")
        XCTAssertEqual(item.tooltip, "Popup\nReArc popup")
        XCTAssertEqual(item.badgeBackgroundColor, ExtensionBadgeColor(skColor: 0xFFFF0000))
        XCTAssertEqual(item.badgeBackgroundColor?.red, 1)
        XCTAssertEqual(item.badgeBackgroundColor?.green, 0)
        XCTAssertNil(item.badgeTextColor, "0 means Chromium's default")
        XCTAssertNil(ExtensionActionItem(id: "b", name: "B").displayBadge)
        XCTAssertEqual(ExtensionActionItem(id: "b", name: "B", title: "B").tooltip, "B")
    }

    func testPinsKeepPinOrderAndSurviveUnlistedExtensions() {
        let a = ExtensionActionItem(id: "a", name: "A"), b = ExtensionActionItem(id: "b", name: "B"), c = ExtensionActionItem(id: "c", name: "C")
        var pins = ExtensionPins(pinnedIDs: ["c", "a", "c"])
        XCTAssertEqual(pins.pinnedIDs, ["c", "a"], "duplicates dropped")
        XCTAssertEqual(pins.pinned([a, b, c]).map(\.id), ["c", "a"])
        pins.toggle("b")
        pins.toggle("c")
        XCTAssertEqual(pins.pinnedIDs, ["a", "b"])
        XCTAssertEqual(pins.pinned([b]).map(\.id), ["b"], "an incognito tab lists fewer; the pin of a stays")
        XCTAssertTrue(pins.isPinned("a"))
        let defaults = UserDefaults(suiteName: "wave27-pins-\(UUID().uuidString)")!
        pins.save(to: defaults)
        XCTAssertEqual(ExtensionPins.load(from: defaults), pins)
    }

    func testPopupSizeStaysInChromiumBounds() {
        XCTAssertEqual(ExtensionPopupGeometry.clamped(width: 320, height: 180), CGSize(width: 320, height: 180))
        XCTAssertEqual(ExtensionPopupGeometry.clamped(width: 1, height: 9000), CGSize(width: 25, height: 600))
        XCTAssertEqual(ExtensionPopupGeometry.clamped(width: 4000, height: -3), CGSize(width: 800, height: 25))
    }

    // MARK: Extension prompts

    func testPromptKindsAndFallbackText() {
        XCTAssertEqual(ExtensionPromptKind(rawValue: 0), .install)
        XCTAssertEqual(ExtensionPromptKind(rawValue: 3), .reEnable)
        XCTAssertEqual(ExtensionPromptKind(rawValue: 4), .permissions)
        XCTAssertEqual(ExtensionPromptKind(rawValue: 14), .request)
        XCTAssertEqual(ExtensionPromptKind(rawValue: 100), .uninstall)
        XCTAssertEqual(ExtensionPromptKind(rawValue: 42), .other(42))

        let install = ExtensionPromptRequest(id: 1, kind: .install, extensionID: "x", name: "Dark Reader",
                                             permissions: ["Read your browsing history", " "])
        XCTAssertEqual(install.displayTitle, "Add “Dark Reader”?")
        XCTAssertEqual(install.displayAcceptLabel, "Add Extension")
        XCTAssertEqual(install.displayCancelLabel, "Cancel")
        XCTAssertEqual(install.informativeText, "It can:\n• Read your browsing history")
        XCTAssertFalse(install.isDestructive)

        let uninstall = ExtensionPromptRequest(id: 2, kind: .uninstall, extensionID: "x", name: "Dark Reader",
                                               triggeringExtension: "Manager")
        XCTAssertEqual(uninstall.displayTitle, "Remove “Dark Reader”?")
        XCTAssertEqual(uninstall.displayAcceptLabel, "Remove")
        XCTAssertTrue(uninstall.isDestructive)
        XCTAssertEqual(uninstall.informativeText, "“Manager” wants to remove it.")

        let localized = ExtensionPromptRequest(id: 3, kind: .install, extensionID: "x", name: "N", title: "Add 'N'?",
                                               acceptLabel: "Add extension", cancelLabel: "Cancel")
        XCTAssertEqual(localized.displayTitle, "Add 'N'?", "Chromium's localized strings win")
        XCTAssertEqual(localized.displayAcceptLabel, "Add extension")
    }

    func testInstallNotices() {
        XCTAssertEqual(ExtensionInstallNotice(extensionID: "x", name: "N", succeeded: true).message, "Added “N”")
        XCTAssertEqual(ExtensionInstallNotice(extensionID: "x", name: "N", succeeded: false, error: "CRX_REQUIRED_PROOF_MISSING").message,
                       "Couldn't add “N”: CRX_REQUIRED_PROOF_MISSING")
    }

    // MARK: Logical extension windows

    private func window(_ key: UUID, _ tabs: [UInt64], active: UInt64?, focused: Bool) -> ExtensionLogicalWindow {
        ExtensionLogicalWindow(key: key, tabs: tabs, activeTab: active, focused: focused)
    }

    func testWindowIDsAreStablePerSpace() {
        var reporter = ExtensionWindowReporter()
        let work = UUID(), home = UUID()
        XCTAssertEqual(reporter.windowID(for: work), 1)
        XCTAssertEqual(reporter.windowID(for: home), 2)
        XCTAssertEqual(reporter.windowID(for: work), 1)
        XCTAssertEqual(reporter.key(forWindowID: 2), home)
        XCTAssertNil(reporter.key(forWindowID: 9))
    }

    func testPlanReportsMembershipThenTheActiveTabAndFocusesLast() {
        var reporter = ExtensionWindowReporter()
        let work = UUID(), home = UUID()
        let calls = reporter.plan([window(work, [10, 11], active: 11, focused: true), window(home, [20], active: 20, focused: false)])
        XCTAssertEqual(calls.map(\.tab), [20, 11, 10], "unfocused windows first; each window's active tab first")
        XCTAssertEqual(calls[1].state, ExtensionWindowState(windowID: 1, active: true, focused: true))
        XCTAssertEqual(reporter.reported[10], ExtensionWindowState(windowID: 1, active: false, focused: true))
        XCTAssertEqual(reporter.reported[20], ExtensionWindowState(windowID: 2, active: true, focused: false))
        XCTAssertTrue(reporter.plan([window(work, [10, 11], active: 11, focused: true), window(home, [20], active: 20, focused: false)]).isEmpty,
                      "nothing changed, nothing sent")
    }

    func testSelectionAndFocusChangesSendOnlyWhatTheEngineDoesNotInfer() {
        var reporter = ExtensionWindowReporter()
        let work = UUID(), home = UUID()
        _ = reporter.plan([window(work, [10, 11], active: 11, focused: true), window(home, [20], active: 20, focused: false)])
        // Selecting 10 clears 11's active flag in the engine: one call.
        let select = reporter.plan([window(work, [10, 11], active: 10, focused: true), window(home, [20], active: 20, focused: false)])
        XCTAssertEqual(select, [ExtensionWindowCall(tab: 10, state: ExtensionWindowState(windowID: 1, active: true, focused: true))])
        XCTAssertEqual(reporter.reported[11]?.active, false)
        // Focusing home unfocuses work in the engine: one call for home.
        let focus = reporter.plan([window(work, [10, 11], active: 10, focused: false), window(home, [20], active: 20, focused: true)])
        XCTAssertEqual(focus.last, ExtensionWindowCall(tab: 20, state: ExtensionWindowState(windowID: 2, active: true, focused: true)))
        XCTAssertEqual(focus.count, 2, "one unfocus call for work clears both of its tabs")
        XCTAssertEqual(reporter.reported.values.filter(\.focused).count, 1)
    }

    func testClosedOrMovedTabsLeaveTheirWindow() {
        var reporter = ExtensionWindowReporter()
        let work = UUID(), home = UUID()
        _ = reporter.plan([window(work, [10, 11], active: 10, focused: true)])
        let removed = reporter.plan([window(work, [10], active: 10, focused: true)])
        XCTAssertEqual(removed, [ExtensionWindowCall(tab: 11, state: .none)])
        XCTAssertNil(reporter.reported[11])
        let moved = reporter.plan([window(work, [], active: nil, focused: true), window(home, [10], active: 10, focused: false)])
        XCTAssertEqual(moved, [ExtensionWindowCall(tab: 10, state: ExtensionWindowState(windowID: 2, active: true, focused: false))])
        reporter.forget(tab: 10)
        XCTAssertEqual(reporter.plan([window(home, [10], active: 10, focused: false)]).count, 1, "a refused call is sent again")
    }

    func testEachTabInOneWindowAndOneFocusedWindow() {
        var reporter = ExtensionWindowReporter()
        let a = UUID(), b = UUID()
        // A favorite listed by two spaces of its profile belongs to the first.
        let states = reporter.desiredStates([window(a, [5, 6], active: 5, focused: true), window(b, [6, 7], active: 6, focused: true)])
        XCTAssertEqual(states[6], ExtensionWindowState(windowID: 1, active: false, focused: true))
        XCTAssertEqual(states[7], ExtensionWindowState(windowID: 2, active: false, focused: false), "one focused window")
        XCTAssertNil(states[0])
    }

    // MARK: Extension tab requests

    func testTabRequestPlacement() {
        let current = UUID(), other = UUID(), otherProfile = UUID()
        let spaces = [current, other, otherProfile]
        let matches: (UUID) -> Bool = { $0 != otherProfile }
        func place(_ request: ExtensionTabRequest, current c: UUID? = current, window: UUID? = nil) -> ExtensionTabPlacement {
            ExtensionTabPlacement.resolve(request, currentSpace: c, windowSpace: window, spaces: spaces, profileMatches: matches)
        }
        XCTAssertEqual(place(ExtensionTabRequest(id: 1, profileID: 1, kind: .createTab)), .newTab(space: current))
        XCTAssertEqual(place(ExtensionTabRequest(id: 1, profileID: 1, kind: .optionsPage)), .newTab(space: current))
        XCTAssertEqual(place(ExtensionTabRequest(id: 1, profileID: 1, kind: .createTab), current: otherProfile), .newTab(space: current),
                       "the current space is another profile's: the extension's own profile")
        XCTAssertEqual(place(ExtensionTabRequest(id: 1, profileID: 1, windowID: 2, kind: .createTab), window: other), .newTab(space: other))
        XCTAssertEqual(place(ExtensionTabRequest(id: 1, profileID: 1, windowID: 3, kind: .createTab), window: otherProfile),
                       .decline("window 3 is in another profile"))
        XCTAssertEqual(place(ExtensionTabRequest(id: 1, profileID: 1, windowID: 4, kind: .createTab), window: nil),
                       .decline("window 4 is not a space"))
        XCTAssertEqual(place(ExtensionTabRequest(id: 1, profileID: 1, kind: .createWindow)), .littleArc)
        XCTAssertEqual(place(ExtensionTabRequest(id: 1, profileID: 1, tabID: 9, kind: .activate)), .activate(tab: 9))
        XCTAssertEqual(place(ExtensionTabRequest(id: 1, profileID: 1, kind: .activate)), .decline("no tab to activate"))
        XCTAssertEqual(ExtensionTabPlacement.resolve(ExtensionTabRequest(id: 1, profileID: 1, kind: .createTab), currentSpace: nil,
                                                     windowSpace: nil, spaces: [otherProfile], profileMatches: matches),
                       .decline("no space in the extension's profile"))
    }

    // MARK: Autofill suggestions

    private func popup(_ product: AutofillProduct, _ rows: [AutofillSuggestionRow], field: CGRect = CGRect(x: 10, y: 10, width: 300, height: 30)) -> AutofillPopup {
        AutofillPopup(requestID: 1, tabID: 2, product: product, field: field, rows: rows)
    }

    func testRowsShowValuesIconsAndManageFooters() {
        let rows = [
            AutofillSuggestionRow(id: 0, value: "Rearc Tester", label: "1 Test Way", icon: "account"),
            AutofillSuggestionRow(id: 1, value: "", kind: .separator, isAcceptable: false),
            AutofillSuggestionRow(id: 2, value: "", icon: "settings", kind: .manage),
        ]
        let address = popup(.address, rows)
        XCTAssertEqual(address.primaryText(of: rows[0]), "Rearc Tester")
        XCTAssertEqual(address.secondaryText(of: rows[0]), "1 Test Way")
        XCTAssertEqual(address.primaryText(of: rows[2]), "Manage addresses…")
        XCTAssertEqual(rows[0].symbolName, "person.crop.circle")
        XCTAssertEqual(rows[2].symbolName, "gearshape")
        XCTAssertTrue(address.hasRows)
        let card = AutofillSuggestionRow(id: 0, value: "Visa  •••• 1111", icon: "card_visa")
        XCTAssertEqual(card.symbolName, "creditcard")
        XCTAssertEqual(card.cardNetwork, "Visa")
        XCTAssertEqual(popup(.creditCard, [card]).secondaryText(of: card), "Visa")
        XCTAssertEqual(AutofillSuggestionRow(id: 0, value: "", icon: "card_amex").cardNetwork, "Amex")
    }

    func testPasswordRowsNeverShowTheLabel() {
        let row = AutofillSuggestionRow(id: 0, value: "rearc-w18f", label: "hunter2-not-masked", icon: "key")
        let passwords = popup(.password, [row, AutofillSuggestionRow(id: 1, value: "Manage passwords…", label: "x", kind: .manage)])
        XCTAssertEqual(passwords.primaryText(of: row), "rearc-w18f")
        XCTAssertEqual(passwords.secondaryText(of: row), AutofillPopup.maskedPassword, "fixed bullets, never engine text")
        XCTAssertEqual(passwords.manageTitle, "Manage passwords…")
    }

    func testKeyboardSelectionSkipsSeparatorsAndWraps() {
        let rows = [
            AutofillSuggestionRow(id: 0, value: "a"),
            AutofillSuggestionRow(id: 1, value: "", kind: .separator, isAcceptable: false),
            AutofillSuggestionRow(id: 2, value: "Manage…", kind: .manage),
        ]
        let list = popup(.address, rows)
        XCTAssertEqual(list.nextSelectable(from: nil, forward: true), 0)
        XCTAssertEqual(list.nextSelectable(from: nil, forward: false), 2)
        XCTAssertEqual(list.nextSelectable(from: 0, forward: true), 2)
        XCTAssertEqual(list.nextSelectable(from: 2, forward: true), 0)
        XCTAssertNil(popup(.address, [rows[1]]).nextSelectable(from: nil, forward: true))
    }

    func testPanelGoesBelowTheFieldOrAboveNearTheScreenBottom() {
        let rows = (0..<3).map { AutofillSuggestionRow(id: $0, value: "row \($0)") }
        let list = popup(.address, rows)
        let size = AutofillPopupLayout.size(for: list)
        XCTAssertEqual(size, CGSize(width: 300, height: 6 * 2 + 36 * 3))
        XCTAssertEqual(AutofillPopupLayout.size(for: popup(.address, rows, field: CGRect(x: 0, y: 0, width: 80, height: 20))).width, 240)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Tab view at (200, 100)…(1200, 800) on screen; field 10,10 300×30 from its top-left.
        let view = CGRect(x: 200, y: 100, width: 1000, height: 700)
        let below = AutofillPopupLayout.frame(field: list.field, viewOnScreen: view, size: size, screen: screen)
        XCTAssertEqual(below.origin.x, 210)
        XCTAssertEqual(below.maxY, 800 - 40 - 2, "2 pt under the field's bottom edge")
        // A field at the bottom of a low view: no room below, so above it.
        let low = CGRect(x: 200, y: 0, width: 1000, height: 100)
        let above = AutofillPopupLayout.frame(field: CGRect(x: 10, y: 60, width: 300, height: 30), viewOnScreen: low, size: size, screen: screen)
        XCTAssertEqual(above.minY, 100 - 60 + 2)
        // Kept on screen horizontally.
        let right = AutofillPopupLayout.frame(field: CGRect(x: 1300, y: 10, width: 300, height: 30), viewOnScreen: CGRect(x: 0, y: 100, width: 1440, height: 700),
                                              size: size, screen: screen)
        XCTAssertEqual(right.maxX, 1440)
    }

    func testEarlyAcceptRetryWaitsOutChromiumsGuard() {
        let shown = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(AutofillAcceptPolicy.retryDelay(shownAt: shown, now: shown.addingTimeInterval(0.1)), 0.5, accuracy: 0.001)
        XCTAssertEqual(AutofillAcceptPolicy.retryDelay(shownAt: shown, now: shown.addingTimeInterval(2)), 0.05, accuracy: 0.001)
    }

    // MARK: Save offers, HTTP auth, leak check

    func testSaveOfferText() {
        let card = AutofillSaveOffer(id: 1, kind: .card, isUpdate: false, origin: "https://shop.test",
                                     summary: "Visa •••• 1111\n12/2031\n\nRearc Tester\nextra\nmore")
        XCTAssertEqual(card.title, "Save card?")
        XCTAssertEqual(card.acceptTitle, "Save")
        XCTAssertEqual(card.summaryLines, ["Visa •••• 1111", "12/2031", "Rearc Tester", "extra"])
        XCTAssertEqual(card.symbol, "creditcard.fill")
        XCTAssertTrue(card.footnote.contains("security code"))
        let address = AutofillSaveOffer(id: 2, kind: .address, isUpdate: true, origin: "", summary: "1 Test Way")
        XCTAssertEqual(address.title, "Update address?")
        XCTAssertEqual(address.acceptTitle, "Update")
        XCTAssertEqual(AutofillSaveAction.decline.rawValue, 1)
        XCTAssertEqual(AutofillSaveAction.ignore.rawValue, 2)
    }

    func testHTTPAuthChallengeText() {
        let plain = HTTPAuthChallenge(id: 1, challenger: "http://127.0.0.1:8080", scheme: "basic", realm: "rearc-basic", isProxy: false)
        XCTAssertEqual(plain.title, "Sign in")
        XCTAssertEqual(plain.message, "http://127.0.0.1:8080 requires a username and password.")
        XCTAssertEqual(plain.realmNote, "The site says: “rearc-basic”")
        XCTAssertTrue(plain.isInsecure)
        let proxy = HTTPAuthChallenge(id: 2, challenger: "https://proxy.test:443", scheme: "digest", realm: " ", isProxy: true)
        XCTAssertEqual(proxy.title, "Sign in to the proxy")
        XCTAssertNil(proxy.realmNote)
        XCTAssertFalse(proxy.isInsecure)
        XCTAssertTrue(HTTPAuthChallenge.isValidCredential(String(repeating: "a", count: 4096)))
        XCTAssertFalse(HTTPAuthChallenge.isValidCredential(String(repeating: "é", count: 2049)), "the limit is UTF-8 bytes")
    }

    func testLeakCheckPreferenceAppliesOnlyAnExplicitChoice() {
        let defaults = UserDefaults(suiteName: "wave27-leak-\(UUID().uuidString)")!
        var preference = PasswordLeakDetectionPreference.load(from: defaults)
        XCTAssertNil(preference.explicitChoice, "never changed: profiles keep Chromium's default (on)")
        XCTAssertNil(preference.valueToApply(current: true, managed: false))
        preference.explicitChoice = false
        preference.save(to: defaults)
        XCTAssertEqual(PasswordLeakDetectionPreference.load(from: defaults), preference)
        XCTAssertEqual(preference.valueToApply(current: true, managed: false), false)
        XCTAssertNil(preference.valueToApply(current: false, managed: false), "already off")
        XCTAssertNil(preference.valueToApply(current: true, managed: true), "policy wins")
    }
}

final class Wave27LinkOpenTests: XCTestCase {
    func testDispositionsMapOntoTheSidebar() {
        let source = UUID()
        XCTAssertEqual(LinkOpenPlacement.resolve(disposition: 2, littleArcKeysHeld: false, sourceTab: source), .backgroundTab)
        XCTAssertEqual(LinkOpenPlacement.resolve(disposition: 1, littleArcKeysHeld: false, sourceTab: source), .foregroundTab)
        XCTAssertEqual(LinkOpenPlacement.resolve(disposition: 4, littleArcKeysHeld: false, sourceTab: source), .littleArc)
        XCTAssertEqual(LinkOpenPlacement.resolve(disposition: 5, littleArcKeysHeld: false, sourceTab: source), .split(with: source))
        XCTAssertEqual(LinkOpenPlacement.resolve(disposition: 5, littleArcKeysHeld: false, sourceTab: nil), .foregroundTab,
                       "a Little ReArc or peek source has no sidebar tab to split with")
        XCTAssertEqual(LinkOpenPlacement.resolve(disposition: 3, littleArcKeysHeld: false, sourceTab: source), .decline("unsupported disposition 3"))
    }

    func testOptionCommandClickStaysLittleArc() {
        for raw: UInt32 in [1, 2, 4, 5] {
            XCTAssertEqual(LinkOpenPlacement.resolve(disposition: raw, littleArcKeysHeld: true, sourceTab: UUID()), .littleArc)
        }
        XCTAssertFalse(LinkOpenPlacement.backgroundTab.isActive)
        XCTAssertTrue(LinkOpenPlacement.split(with: UUID()).isActive)
        XCTAssertTrue(LinkOpenPlacement.littleArc.isActive)
    }
}

final class ExtensionPromptSecurityTests: XCTestCase {
    func testCancelIsDefaultForEveryPrompt() {
        for kind: ExtensionPromptKind in [.permissions, .reEnable, .install, .uninstall, .external, .remote] {
            XCTAssertTrue(ExtensionPromptRequest(id: 1, kind: kind, extensionID: "x", name: "X").cancelIsDefault)
        }
    }
}
