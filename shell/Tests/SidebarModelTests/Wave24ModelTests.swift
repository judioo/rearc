import XCTest
@testable import SidebarModel

/// Wave 24: print paper and page ranges, PDF names, the print gate, the
/// page drop policy, sidebar link drops and automatic PiP on a tab switch.
final class Wave24ModelTests: XCTestCase {

    // MARK: Printing

    func testPaperFollowsThePrintInfoInPortraitInches() {
        let a4Landscape = PrintPaperSetup(paperWidthPoints: 841.89, heightPoints: 595.28, landscape: true)
        XCTAssertEqual(a4Landscape.widthInches, 595.28 / 72, accuracy: 0.001, "Chromium wants portrait sizes plus a flag")
        XCTAssertEqual(a4Landscape.heightInches, 841.89 / 72, accuracy: 0.001)
        XCTAssertTrue(a4Landscape.landscape)
        XCTAssertEqual(PrintPaperSetup(paperWidthPoints: 612, heightPoints: 792, landscape: false), .letter)
        let broken = PrintPaperSetup(paperWidthPoints: .nan, heightPoints: 0, landscape: true)
        XCTAssertEqual(broken.widthInches, 8.5)
        XCTAssertTrue(broken.landscape, "a bad size falls back to Letter, keeping the orientation")
    }

    func testPageRangesFollowChromiumSyntax() {
        for good in ["", " ", "1", "1-3,5", "2-", "-4", " 1 - 2 , 7 "] {
            XCTAssertTrue(PrintPageRanges.isWellFormed(good), good)
        }
        for bad in ["0", "a", "3-1", "1--2", "1,,2", "-", "1-2-3", "１", String(repeating: "1,", count: 2100)] {
            XCTAssertFalse(PrintPageRanges.isWellFormed(bad), bad)
        }
    }

    func testExportNamesComeFromTheTitleThenTheHost() {
        XCTAssertEqual(PDFExportNaming.suggestedFileName(title: "Q3: report / final", url: nil), "Q3- report - final.pdf")
        XCTAssertEqual(PDFExportNaming.suggestedFileName(title: "  ", url: URL(string: "https://example.com/a")), "example.com.pdf")
        XCTAssertEqual(PDFExportNaming.suggestedFileName(title: "..hidden", url: nil), "hidden.pdf")
        XCTAssertEqual(PDFExportNaming.suggestedFileName(title: "Paper.PDF", url: nil), "Paper.pdf")
        XCTAssertEqual(PDFExportNaming.suggestedFileName(title: nil, url: nil), "Page.pdf")
        XCTAssertEqual(PDFExportNaming.suggestedFileName(title: String(repeating: "x", count: 500), url: nil).count, 204)
    }

    func testPDFSignatureAndOneJobPerPage() {
        XCTAssertTrue(PDFSignature.isPDF(Data("%PDF-1.7\n".utf8)))
        XCTAssertFalse(PDFSignature.isPDF(Data("<html>".utf8)))
        XCTAssertFalse(PDFSignature.isPDF(Data()))
        var gate = PrintRequestGate<Int>()
        XCTAssertTrue(gate.begin(1))
        XCTAssertFalse(gate.begin(1), "a window.print() while the panel is open is dropped")
        XCTAssertTrue(gate.begin(2), "other pages print independently")
        gate.end(1)
        XCTAssertFalse(gate.isPrinting(1))
        XCTAssertTrue(gate.begin(1))
    }

    // MARK: Drops into pages

    func testTheShellPolicyAcceptsEverythingButSidebarDrags() {
        let policy = PageDropPolicy.shell
        XCTAssertEqual(policy.accept.rawValue, 15, "files 1 | text 2 | urls 4 | images 8")
        XCTAssertEqual(policy.blockedTypes, ["com.rearc.sidebar-item"])
        XCTAssertTrue(policy.isValid)
        XCTAssertTrue(policy.blocks(dragTypes: ["public.utf8-plain-text", SidebarDragType.identifier]))
        XCTAssertFalse(policy.blocks(dragTypes: ["public.file-url", "public.utf8-plain-text"]))
    }

    func testDropPolicyValidationMatchesTheEngine() {
        XCTAssertFalse(PageDropPolicy(accept: .init(rawValue: 16), blockedTypes: []).isValid, "unknown accept bit")
        XCTAssertFalse(PageDropPolicy(accept: .text, blockedTypes: ["has space"]).isValid)
        XCTAssertFalse(PageDropPolicy(accept: .text, blockedTypes: [""]).isValid)
        XCTAssertFalse(PageDropPolicy(accept: .text, blockedTypes: ["é"]).isValid, "ASCII only")
        XCTAssertFalse(PageDropPolicy(accept: .text, blockedTypes: [String(repeating: "a", count: 257)]).isValid)
        XCTAssertTrue(PageDropPolicy(accept: .text, blockedTypes: [String(repeating: "a", count: 256)]).isValid)
        XCTAssertFalse(PageDropPolicy(accept: .text, blockedTypes: (0 ... 32).map { "t\($0)" }).isValid, "at most 32 types")
        XCTAssertTrue(PageDropPolicy(accept: [], blockedTypes: []).isValid, "accept 0 refuses every drop")
    }

    func testSidebarLinkDropsKeepNavigableURLsOnce() {
        let urls = [
            URL(string: "https://a.test/x")!, URL(string: "javascript:alert(1)")!, URL(string: "https://a.test/x")!,
            URL(fileURLWithPath: "/tmp/report.pdf"), URL(string: "chrome://settings")!, URL(string: "http://b.test")!,
        ]
        XCTAssertEqual(SidebarURLDrop.tabURLs(from: urls, engine: []).map(\.absoluteString),
                       ["https://a.test/x", "file:///tmp/report.pdf", "http://b.test"])
        let many = (0 ..< 40).map { URL(string: "https://site\($0).test")! }
        XCTAssertEqual(SidebarURLDrop.tabURLs(from: many, engine: []).count, SidebarURLDrop.maxTabs)
        XCTAssertEqual(SidebarURLDrop.placeholderTitle(for: URL(fileURLWithPath: "/tmp/report.pdf")), "report.pdf")
        XCTAssertEqual(SidebarURLDrop.placeholderTitle(for: URL(string: "https://a.test/x")!), "a.test")
    }

    // MARK: Automatic Picture in Picture

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let playing = WebMediaState(isPlaying: true, isAudible: true, canPictureInPicture: true)

    private func plan(
        from previous: Set<UUID>, to visible: Set<UUID>, media: [UUID: WebMediaState],
        autoEntered: Set<UUID> = [], enabled: Bool = true, settings: AutoPiPPolicyState = AutoPiPPolicyState()
    ) -> AutoPiPTabSwitchPlan {
        AutoPiPPolicy.tabSwitchPlan(
            previouslyVisible: previous, nowVisible: visible, media: media,
            hosts: [a: "video.test", b: "news.test", c: "music.test"],
            autoEntered: autoEntered, isEnabled: enabled, settings: settings, now: now
        )
    }

    func testSwitchingAwayFromAPlayingVideoEntersPiP() {
        XCTAssertEqual(plan(from: [a], to: [b], media: [a: playing]), AutoPiPTabSwitchPlan(enter: a))
        XCTAssertNil(plan(from: [a], to: [b], media: [a: playing], enabled: false).enter, "the setting is off")
        XCTAssertNil(plan(from: [a], to: [a, b], media: [a: playing]).enter, "still on screen (a split)")
        XCTAssertNil(plan(from: [a], to: [b], media: [a: WebMediaState(isPlaying: true, isAudible: true)]).enter, "audio only")
        XCTAssertNil(plan(from: [a], to: [b], media: [a: WebMediaState(isPlaying: false, canPictureInPicture: true)]).enter, "paused")
        let snoozed = AutoPiPPolicy.snooze(host: "video.test", from: AutoPiPPolicyState(), now: now, duration: 60)
        XCTAssertNil(plan(from: [a], to: [b], media: [a: playing], settings: snoozed).enter, "snoozed site")
    }

    func testOnePiPWindowAtATime() {
        var muted = playing
        muted.isAudible = false
        XCTAssertEqual(plan(from: [a, c], to: [b], media: [a: muted, c: playing]).enter, c, "the tab you can hear wins")
        var inPiP = playing
        inPiP.isPictureInPicture = true
        XCTAssertNil(plan(from: [a], to: [b], media: [a: playing, c: inPiP]).enter, "a video already in PiP keeps the window")
    }

    func testReturningToAnAutoPiPTabBringsItsVideoBack() {
        var inPiP = playing
        inPiP.isPictureInPicture = true
        XCTAssertEqual(plan(from: [b], to: [a], media: [a: inPiP], autoEntered: [a]).exit, [a])
        XCTAssertEqual(plan(from: [b], to: [a], media: [a: inPiP], autoEntered: []).exit, [], "a PiP you chose stays")
        // Back from the PiP tab to another playing one: the window moves over.
        XCTAssertEqual(plan(from: [c], to: [a], media: [a: inPiP, c: playing], autoEntered: [a]),
                       AutoPiPTabSwitchPlan(enter: c, exit: [a]))
    }

    func testMediaSnapshotsFromBeforeWave24Decode() throws {
        let old = Data(#"{"isPlaying":true,"isAudible":false,"title":"T","canPictureInPicture":true}"#.utf8)
        let state = try JSONDecoder().decode(WebMediaState.self, from: old)
        XCTAssertTrue(state.isPlaying && state.canPictureInPicture && !state.isPictureInPicture)
        let round = try JSONDecoder().decode(WebMediaState.self, from: JSONEncoder().encode(inPiPState))
        XCTAssertEqual(round, inPiPState)
    }

    private var inPiPState: WebMediaState { WebMediaState(isPlaying: true, canPictureInPicture: true, isPictureInPicture: true) }

    func testThePiPCommandNeedsAVideo() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let tab = store.addTab(kind: .today, title: "V", url: URL(string: "https://video.test")!)
        store.selectTab(tab.id)
        func enabled(_ media: WebMediaState?) -> Bool {
            let context = CommandBarContext(
                store: store, isSidebarVisible: true, closedTabStack: ClosedTabStack(),
                mediaByTab: media.map { [tab.id: $0] } ?? [:]
            )
            return AppCommand(id: "pip", title: "PiP", action: .togglePictureInPicture).isEnabled(in: context)
        }
        XCTAssertFalse(enabled(nil))
        XCTAssertFalse(enabled(WebMediaState(isPlaying: true, isAudible: true)))
        XCTAssertTrue(enabled(playing))
        XCTAssertTrue(enabled(inPiPState))
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: ClosedTabStack())
        XCTAssertTrue(AppCommand(id: "p", title: "P", action: .printPage).isEnabled(in: context))
        XCTAssertTrue(AppCommand(id: "e", title: "E", action: .exportPageAsPDF).isEnabled(in: context))
        let withVideo = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: ClosedTabStack(), mediaByTab: [tab.id: playing])
        let titles = AppCommandRegistry.all(in: withVideo).filter { $0.isEnabled(in: withVideo) }.map(\.title)
        XCTAssertTrue(titles.contains("Print…") && titles.contains("Export as PDF…") && titles.contains("Picture in Picture"))
    }
}
