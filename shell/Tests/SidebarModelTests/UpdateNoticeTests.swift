import XCTest
@testable import SidebarModel

/// The sidebar's update notice (UPDATE-NOTICE.md): the state Sparkle's
/// callbacks drive, the feed flags that set its level, which surface owns a
/// session, and where each window draws it.
final class UpdateNoticeTests: XCTestCase {
    private let v700 = AvailableUpdate(version: "0.1.0", build: UpdateBuild(700))
    private let v701 = AvailableUpdate(version: "0.1.0", build: UpdateBuild(701))

    private func notice(_ events: UpdateNotice.Event...) -> UpdateNotice {
        var notice = UpdateNotice()
        events.forEach { notice.send($0) }
        return notice
    }

    // MARK: State machine

    func testNothingFoundShowsNothing() {
        let notice = UpdateNotice()
        XCTAssertFalse(notice.isVisible)
        XCTAssertEqual(notice.menuState, UpdateMenuState())
        XCTAssertEqual(UpdateNotice().menuState.title, "Check for Updates…")
    }

    func testFoundThenDownloadedAndInstalled() {
        var notice = notice(.found(v700, downloaded: false))
        XCTAssertEqual(notice.phase, .available)
        XCTAssertTrue(notice.isVisible)
        XCTAssertEqual(notice.menuState.title, "Update Available…")
        XCTAssertEqual(notice.menuState.badgeCount, 1)

        notice.send(.installRequested)
        XCTAssertEqual(notice.phase, .downloading(UpdateProgress()))
        XCTAssertTrue(notice.isBusy)
        notice.send(.downloadStarted)
        notice.send(.downloadExpected(200))
        notice.send(.downloadReceived(50))
        notice.send(.downloadReceived(50))
        XCTAssertEqual(notice.phase, .downloading(UpdateProgress(received: 100, expected: 200)))
        XCTAssertEqual(UpdateNoticeText.status(notice.phase), "Downloading… 50%")
        notice.send(.extractionStarted)
        notice.send(.extracted(0.5))
        XCTAssertEqual(notice.phase, .extracting(0.5))
        XCTAssertEqual(UpdateNoticeText.status(notice.phase), "Preparing the update…")
        notice.send(.readyToInstall)
        XCTAssertEqual(notice.phase, .installing, "the person already asked: ready goes straight to installing")
        XCTAssertEqual(UpdateNoticeText.status(notice.phase), "Restarting ReArc…")
        XCTAssertTrue(notice.holdsCardOpen, "progress keeps the card open")
    }

    func testAlreadyDownloadedGoesStraightToInstall() {
        var notice = notice(.found(v700, downloaded: true))
        XCTAssertEqual(notice.phase, .ready)
        XCTAssertNil(UpdateNoticeText.status(notice.phase))
        notice.send(.installRequested)
        XCTAssertEqual(notice.phase, .installing)
    }

    func testAutomaticDownloadFinishingMakesTheUpdateReady() {
        var notice = notice(.found(v700, downloaded: false))
        notice.send(.found(v700, downloaded: true))
        XCTAssertEqual(notice.phase, .ready)
        // Sparkle's own ready step without a request waits for the person.
        var waiting = self.notice(.found(v700, downloaded: false))
        waiting.send(.readyToInstall)
        XCTAssertEqual(waiting.phase, .ready)
    }

    func testUnknownDownloadSizeIsIndeterminate() {
        let notice = notice(.found(v700, downloaded: false), .installRequested, .downloadStarted, .downloadReceived(10))
        XCTAssertNil(UpdateProgress(received: 10).fraction)
        XCTAssertEqual(UpdateNoticeText.status(notice.phase), "Downloading…")
        XCTAssertEqual(UpdateProgress(received: 300, expected: 200).fraction, 1)
    }

    func testProgressWithoutARequestIsIgnored() {
        // Automatic Updates downloads silently: those steps never reach the notice.
        let notice = notice(.found(v700, downloaded: false), .downloadStarted, .downloadReceived(10), .extractionStarted)
        XCTAssertEqual(notice.phase, .available)
        XCTAssertFalse(notice.isBusy)
    }

    func testFailureShowsOneLineAndTryAgainRestarts() {
        var notice = notice(.found(v700, downloaded: false), .installRequested, .failed(.offline))
        XCTAssertEqual(notice.phase, .failed(.offline))
        XCTAssertFalse(notice.installRequested)
        XCTAssertFalse(notice.isBusy, "Try Again is enabled")
        XCTAssertEqual(UpdateNoticeText.status(notice.phase), "ReArc can't reach the update server. Check your connection.")
        notice.send(.installRequested)
        XCTAssertEqual(notice.phase, .downloading(UpdateProgress()))
    }

    func testRefusedQuitRetriesTheInstall() {
        var notice = notice(.found(v700, downloaded: true), .installRequested, .failed(.quitRefused))
        XCTAssertTrue(notice.installRequested)
        XCTAssertEqual(UpdateNoticeText.status(notice.phase), "A page asked ReArc to stay open.")
        notice.send(.installRequested)
        XCTAssertEqual(notice.phase, .installing)
    }

    func testFailureWithoutAnUpdateIsNotShown() {
        let notice = notice(.failed(.other), .installRequested, .readyToInstall, .installing)
        XCTAssertEqual(notice, UpdateNotice())
    }

    func testEveryFailureHasPlainWords() {
        for failure in [UpdateNoticeFailure.offline, .signature, .noSpace, .quitRefused, .other] {
            let text = UpdateNoticeText.failure(failure)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("Error"), text)
            XCTAssertFalse(text.contains("\n"), text)
        }
    }

    func testSessionEndingMidDownloadGoesBackToAvailable() {
        var notice = notice(.found(v700, downloaded: false), .installRequested, .downloadStarted)
        notice.send(.sessionEnded)
        XCTAssertEqual(notice.phase, .available)
        XCTAssertFalse(notice.installRequested)
        // Quitting to install is not undone by the session's end.
        var quitting = self.notice(.found(v700, downloaded: true), .installRequested)
        quitting.send(.sessionEnded)
        XCTAssertEqual(quitting.phase, .installing)
    }

    func testNotFoundAndSkipClearTheNotice() {
        XCTAssertEqual(notice(.found(v700, downloaded: false), .notFound), UpdateNotice())
        XCTAssertEqual(notice(.found(v700, downloaded: true), .skipped), UpdateNotice())
    }

    func testANewerUpdateReplacesTheShownOne() {
        var notice = notice(.found(v700, downloaded: true), .pointerVisited, .hidden)
        notice.send(.found(v701, downloaded: false))
        XCTAssertEqual(notice.update, v701)
        XCTAssertEqual(notice.phase, .available, "the newer build is not downloaded yet")
        XCTAssertFalse(notice.pointerVisited)
        XCTAssertFalse(notice.isHidden, "a newer update shows again")
    }

    func testAnOlderUpdateIsIgnored() {
        let notice = notice(.found(v701, downloaded: false), .found(v700, downloaded: true))
        XCTAssertEqual(notice.update, v701)
        XCTAssertEqual(notice.phase, .available)
    }

    func testANewerUpdateFoundByRestartAndUpdatesOwnCheckCarriesOn() {
        var notice = notice(.found(v700, downloaded: false), .installRequested)
        notice.send(.found(v701, downloaded: false))
        XCTAssertEqual(notice.update, v701)
        XCTAssertEqual(notice.phase, .downloading(UpdateProgress()))
        XCTAssertTrue(notice.installRequested)
        var downloaded = self.notice(.found(v700, downloaded: false), .installRequested)
        downloaded.send(.found(v701, downloaded: true))
        XCTAssertEqual(downloaded.phase, .installing)
    }

    func testANewerUpdateWhileQuittingDoesNotInterrupt() {
        let notice = notice(.found(v700, downloaded: true), .installRequested, .found(v701, downloaded: false))
        XCTAssertEqual(notice.update, v700)
        XCTAssertEqual(notice.phase, .installing)
    }

    func testUnreadableBuildsCompareByVersion() {
        let a = AvailableUpdate(version: "1.0"), b = AvailableUpdate(version: "1.1")
        let notice = notice(.found(a, downloaded: false), .found(b, downloaded: false))
        XCTAssertEqual(notice.update, b)
    }

    func testRefetchedItemCanRaiseItsLevel() {
        var critical = v700
        critical.urgency = .critical
        let notice = notice(.found(v700, downloaded: false), .hidden, .found(critical, downloaded: false))
        XCTAssertEqual(notice.urgency, .critical)
        XCTAssertFalse(notice.isHidden)
    }

    // MARK: Levels on the card

    func testNormalCanBeHiddenCriticalAndRequiredCannot() {
        var normal = notice(.found(v700, downloaded: false))
        XCTAssertTrue(normal.canHide)
        normal.send(.hidden)
        XCTAssertFalse(normal.isVisible)
        XCTAssertTrue(normal.menuState.updateAvailable, "the menu stays the route to a hidden update")

        for urgency in [UpdateUrgency.critical, .required] {
            var update = v700
            update.urgency = urgency
            var pressing = notice(.found(update, downloaded: false))
            XCTAssertFalse(pressing.canHide)
            pressing.send(.hidden)
            XCTAssertTrue(pressing.isVisible, "\(urgency)")
        }
    }

    func testCriticalCardStaysOpenUntilThePointerHasBeenOverIt() {
        var update = v700
        update.urgency = .critical
        var notice = notice(.found(update, downloaded: false))
        XCTAssertTrue(notice.holdsCardOpen)
        notice.send(.pointerVisited)
        XCTAssertFalse(notice.holdsCardOpen)
        XCTAssertFalse(self.notice(.found(v700, downloaded: false)).holdsCardOpen, "a normal update rests as the pill")
    }

    func testTitlesAndDetails() {
        XCTAssertEqual(UpdateNoticeText.title(.normal), "New ReArc Version Available")
        XCTAssertEqual(UpdateNoticeText.title(.critical), "Critical Update Available")
        XCTAssertEqual(UpdateNoticeText.title(.required), "Required Update")
        XCTAssertNil(UpdateNoticeText.detail(.normal))
        XCTAssertEqual(UpdateNoticeText.detail(.critical), "This update fixes a security problem.")
        XCTAssertEqual(UpdateNoticeText.detail(.required), "This version of ReArc is no longer supported. Restart to update.")
        XCTAssertEqual(AvailableUpdate.title, "Restart and Update ReArc")
    }

    func testEnforcementIsDisplayOnlyForNow() {
        for urgency in [UpdateUrgency.normal, .critical, .required] {
            XCTAssertFalse(UpdateEnforcement.installsAtQuit(urgency))
            XCTAssertFalse(UpdateEnforcement.blocksAtLaunch(urgency))
        }
    }

    // MARK: Feed flags

    func testCriticalComesFromSparklesFlag() {
        XCTAssertEqual(UpdateFeedFlags(isCritical: true, properties: [:]).urgency(forHostBuild: UpdateBuild(677)), .critical)
        XCTAssertEqual(UpdateFeedFlags(isCritical: false, properties: [:]).urgency(forHostBuild: UpdateBuild(677)), .normal)
    }

    func testRequiredBelowAppliesToOlderBuildsOnly() {
        let flags = UpdateFeedFlags(isCritical: false, properties: ["rearc:requiredBelow": "700"])
        XCTAssertEqual(flags.requirement, .below(700))
        XCTAssertEqual(flags.urgency(forHostBuild: UpdateBuild(608)), .required)
        XCTAssertEqual(flags.urgency(forHostBuild: UpdateBuild(699)), .required)
        XCTAssertEqual(flags.urgency(forHostBuild: UpdateBuild(700)), .normal)
        XCTAssertEqual(flags.urgency(forHostBuild: UpdateBuild(705)), .normal)
        XCTAssertEqual(flags.urgency(forHostBuild: nil), .normal, "an unreadable host build is never required")
        let both = UpdateFeedFlags(isCritical: true, properties: ["rearc:requiredBelow": "700"])
        XCTAssertEqual(both.urgency(forHostBuild: UpdateBuild(677)), .required, "required outranks critical")
        XCTAssertEqual(both.urgency(forHostBuild: UpdateBuild(700)), .critical)
    }

    func testRequiredBelowToleratesSparklesTrimmingAndPrettyPrinting() {
        XCTAssertEqual(UpdateFeedMarker.requirement(in: ["rearc:requiredBelow": " 700\n"]), .below(700))
    }

    func testAnUnknownOrMalformedMarkerIsIgnored() {
        for value in ["", "soon", "-5", "0", "7e2", "700 701", "７００", "99999999999", "1.2"] {
            let flags = UpdateFeedFlags(isCritical: false, properties: ["rearc:requiredBelow": value])
            XCTAssertEqual(flags.requirement, .unrecognized, value)
            XCTAssertEqual(flags.urgency(forHostBuild: UpdateBuild(1)), .normal, value)
        }
        XCTAssertEqual(UpdateFeedMarker.requirement(in: ["rearc:requiredBelow": 700]), .unrecognized, "Sparkle stores text")
        // Other elements in ReArc's namespace, and Sparkle's own, are not the marker.
        let other = UpdateFeedFlags(isCritical: false, properties: ["rearc:required": "700", "rearc:deadline": "2027-01-01",
                                                                    "sparkle:version": "700", "title": "Required"])
        XCTAssertEqual(other.requirement, .none)
        XCTAssertEqual(other.urgency(forHostBuild: UpdateBuild(1)), .normal)
    }

    /// A stamped item as Sparkle 2.10.1's SUAppcast reads it: XMLDocument, then
    /// each child under "sparkle:" + its local name in Sparkle's namespace and
    /// under its own prefixed name otherwise, as trimmed text. This is what
    /// `SUAppcastItem.propertiesDictionary` holds in ReArc, and what an older
    /// ReArc (677, 608) parses and then ignores.
    private static let stampedFeed = """
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:rearc="https://rearc.imara.ae/xml-namespaces/update" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <title>ReArc</title>
                <item>
                    <title>0.1.0</title>
                    <sparkle:version>700</sparkle:version>
                    <rearc:requiredBelow>690</rearc:requiredBelow>
                    <sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
                    <sparkle:criticalUpdate></sparkle:criticalUpdate>
                    <enclosure url="https://rearc.imara.ae/updates/ReArc-0.1.0-700.dmg" length="1" type="application/octet-stream" sparkle:edSignature="eA=="/>
                </item>
            </channel>
        </rss>
        """

    private static func sparkleProperties(_ data: Data) throws -> [AnyHashable: Any] {
        let sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        let document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        let item = try XCTUnwrap(try document.nodes(forXPath: "/rss/channel/item").first as? XMLElement)
        var properties: [AnyHashable: Any] = [:]
        for case let node as XMLElement in item.children ?? [] {
            let name = node.uri == sparkle ? "sparkle:" + (node.localName ?? "") : (node.name ?? "")
            properties[name] = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return properties
    }

    func testSparkleReadsTheMarkerUnderItsPrefixedName() throws {
        let properties = try Self.sparkleProperties(Data(Self.stampedFeed.utf8))
        XCTAssertEqual(properties["rearc:requiredBelow"] as? String, "690")
        XCTAssertEqual(properties["sparkle:version"] as? String, "700", "Sparkle's own elements read as before")
        XCTAssertNotNil(properties["sparkle:criticalUpdate"])
        XCTAssertEqual(UpdateFeedFlags(isCritical: true, properties: properties).urgency(forHostBuild: UpdateBuild(677)), .required)
        XCTAssertEqual(UpdateFeedFlags(isCritical: true, properties: properties).urgency(forHostBuild: UpdateBuild(695)), .critical)
    }

    func testTheMarkerSurvivesGenerateAppcastsRewrite() throws {
        // The next release's generate_appcast loads the feed and writes it pretty-printed.
        let document = try XMLDocument(data: Data(Self.stampedFeed.utf8), options: [.nodeLoadExternalEntitiesNever, .nodePreserveCDATA, .nodePreserveWhitespace])
        let rewritten = document.xmlData(options: [.nodeCompactEmptyElement, .nodePrettyPrint])
        XCTAssertTrue(String(decoding: rewritten, as: UTF8.self).contains("xmlns:rearc=\"https://rearc.imara.ae/xml-namespaces/update\""))
        XCTAssertEqual(try Self.sparkleProperties(rewritten)["rearc:requiredBelow"] as? String, "690")
    }

    func testBuildNumbers() {
        XCTAssertEqual(UpdateBuild("677")?.number, 677)
        XCTAssertNil(UpdateBuild("0.1.0"))
        XCTAssertNil(UpdateBuild("677a"))
        XCTAssertNil(UpdateBuild(""))
        XCTAssertTrue(UpdateBuild(608) < UpdateBuild(677))
    }

    // MARK: Errors

    func testFailureClassification() {
        XCTAssertEqual(UpdateNoticeFailure.classify([("SUSparkleErrorDomain", 2001), (NSURLErrorDomain, -1009)]), .offline)
        XCTAssertEqual(UpdateNoticeFailure.classify([("SUSparkleErrorDomain", 1002), (NSURLErrorDomain, -1001)]), .offline)
        XCTAssertEqual(UpdateNoticeFailure.classify([("SUSparkleErrorDomain", 3001)]), .signature)
        XCTAssertEqual(UpdateNoticeFailure.classify([("SUSparkleErrorDomain", 3002)]), .signature)
        XCTAssertEqual(UpdateNoticeFailure.classify([("SUSparkleErrorDomain", 3000), (NSPOSIXErrorDomain, Int(ENOSPC))]), .noSpace)
        XCTAssertEqual(UpdateNoticeFailure.classify([("SUSparkleErrorDomain", 2001), (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError)]), .noSpace)
        XCTAssertEqual(UpdateNoticeFailure.classify([("SUSparkleErrorDomain", 4005)]), .other)
        XCTAssertEqual(UpdateNoticeFailure.classify([]), .other)
    }

    func testLogEscaping() {
        XCTAssertEqual(UpdateNoticeLog.escaped("0.1.0 (677)"), "\"0.1.0 (677)\"")
        XCTAssertEqual(UpdateNoticeLog.escaped("a\nb\"c\\"), "\"a\\u{a}b\\\"c\\\\\"")
        XCTAssertEqual(UpdateNoticeLog.escaped("\u{202E}evil"), "\"\\u{202e}evil\"")
        XCTAssertEqual(UpdateNoticeLog.escaped(String(repeating: "x", count: 300)).count, 200 + 3)
    }

    // MARK: Who owns a session

    func testAScheduledFindIsTheNotices() {
        var routing = UpdateSessionRouting()
        XCTAssertEqual(routing.updateFound(userInitiated: false, informationOnly: false), .notice)
        XCTAssertEqual(routing.current, .notice)
        routing.sessionEnded()
        XCTAssertNil(routing.route)
    }

    func testCheckForUpdatesIsSparklesWindow() {
        var routing = UpdateSessionRouting()
        XCTAssertEqual(routing.userInitiatedCheckBegan(), .standard)
        XCTAssertEqual(routing.updateFound(userInitiated: true, informationOnly: false), .standard)
        XCTAssertEqual(routing.current, .standard, "\"You're up to date\" and errors go to Sparkle's window too")
    }

    func testRestartAndUpdatesOwnCheckIsTheNotices() {
        var routing = UpdateSessionRouting()
        routing.noticeWillCheck()
        XCTAssertEqual(routing.current, .notice)
        XCTAssertEqual(routing.userInitiatedCheckBegan(), .notice)
        XCTAssertEqual(routing.updateFound(userInitiated: true, informationOnly: false), .notice)
        routing.sessionEnded()
        XCTAssertEqual(routing.userInitiatedCheckBegan(), .standard, "the next menu check is Sparkle's again")
    }

    func testInformationOnlyItemsStayWithSparkle() {
        var routing = UpdateSessionRouting()
        XCTAssertEqual(routing.updateFound(userInitiated: false, informationOnly: true), .standard)
    }

    func testTheMenuTakesOverAHeldUpdate() {
        var routing = UpdateSessionRouting()
        _ = routing.updateFound(userInitiated: false, informationOnly: false)
        routing.handOverToStandard()
        XCTAssertEqual(routing.current, .standard)
    }

    // MARK: Per window

    func testFormPerWindowAndSidebar() {
        let shown = notice(.found(v700, downloaded: false))
        typealias P = UpdateNoticePresentation
        XCTAssertEqual(P.form(for: shown, window: .browser, sidebar: .full), .pill)
        XCTAssertEqual(P.form(for: shown, window: .browser, sidebar: .mini), .compact)
        XCTAssertEqual(P.form(for: shown, window: .browser, sidebar: .hidden), .none)
        for window in [P.WindowKind.littleArc, .privateWindow] {
            for sidebar in [P.SidebarMode.full, .mini, .hidden] {
                XCTAssertEqual(P.form(for: shown, window: window, sidebar: sidebar), .none, "\(window) \(sidebar)")
            }
        }
        XCTAssertEqual(P.form(for: UpdateNotice(), window: .browser, sidebar: .full), .none)
        XCTAssertEqual(P.form(for: notice(.found(v700, downloaded: false), .hidden), window: .browser, sidebar: .full), .none)
    }

    // MARK: Ink

    func testWarningInkIsLegibleOnEveryTheme() {
        for (name, theme) in SidebarBadgeInkTests.themes {
            for dark in [false, true] {
                let label = "\(name) \(dark ? "dark" : "light")"
                let backdrop = SidebarBackdrop(theme: theme, dark: dark)
                let lightInk = backdrop.prefersLightInk
                let ink = UpdateNoticeInk(backdrop: backdrop, lightInk: lightInk, accent: SpaceThemeRoles(theme: theme).chrome(dark: lightInk).accent)
                // Straddling gradients too: the warning pill's own wash lifts every theme to the floor.
                let pill = UpdateNoticeInk.washed(backdrop, with: ink.warningFill, alpha: ink.warningFillAlpha)
                XCTAssertGreaterThanOrEqual(pill.contrast(of: ink.warning, lightInk: lightInk), SidebarContrast.text, label)
                let card = UpdateNoticeInk.washed(backdrop, with: ink.card, alpha: ink.cardAlpha)
                XCTAssertGreaterThanOrEqual(card.contrast(of: ink.cardWarning, lightInk: lightInk), SidebarContrast.text, label)
            }
        }
    }

    func testWarningInkStaysOrange() {
        let backdrop = SidebarBackdrop(theme: .arcDefault, dark: false)
        let ink = UpdateNoticeInk(backdrop: backdrop, lightInk: backdrop.prefersLightInk, accent: SpaceColor(red: 0.15, green: 0.19, blue: 1))
        let hue = ink.warning.oklab.lch.h
        let base = UpdateNoticeInk.warningBase.light.oklab.lch.h
        XCTAssertEqual(hue, base, accuracy: 8, "moved in lightness, not hue (degrees)")
    }

    func testButtonTitleReadsOnTheAccent() {
        let backdrop = SidebarBackdrop(theme: .arcDefault, dark: false)
        let dark = UpdateNoticeInk(backdrop: backdrop, lightInk: false, accent: SpaceColor(red: 0.39, green: 0.28, blue: 0.18))
        XCTAssertEqual(dark.buttonTitle, .white, "Arc's brown accent takes white")
        let pale = UpdateNoticeInk(backdrop: backdrop, lightInk: false, accent: SpaceColor(red: 0.98, green: 0.9, blue: 0.2))
        XCTAssertEqual(pale.buttonTitle, .black)
    }
}
