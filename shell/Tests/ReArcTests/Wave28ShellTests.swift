import AppKit
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Wave 28: the Library, gradient themes, Boosts v2, region capture, rich
/// notes and browser import.
@MainActor
final class Wave28ShellTests: XCTestCase {

    private func makeModel(_ configure: (SidebarStore) -> Void = { _ in }) -> BrowserViewModel {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        configure(store)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w28-\(UUID().uuidString)")
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        model.tabUnloadDefaults = UserDefaults(suiteName: "rearc-w28-\(UUID().uuidString)")!
        model.externalLinkDefaults = UserDefaults(suiteName: "rearc-w28-links-\(UUID().uuidString)")!
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-w28-\(UUID().uuidString)"))
        return model
    }

    private func titles(_ groups: [[ShellMenuItem]]) -> [String] { groups.flatMap { $0.map(\.title) } }

    // MARK: Library

    func testLibraryOpensInTheKeyWindowAndAnySidebarClickClosesIt() {
        let model = makeModel()
        let windowA = SidebarWindowID(), windowB = SidebarWindowID()
        model.store.registerWindow(windowA)
        model.store.registerWindow(windowB)
        model.windowBecameKey(windowA)
        let tab = model.store.addTab(kind: .today, title: "A", url: URL(string: "https://a.test")!)
        model.store.selectTab(tab.id)

        XCTAssertNil(model.executeCommand(.openLibrary(.easels), commandID: nil))
        XCTAssertEqual(model.librarySection(in: windowA), .easels)
        XCTAssertNil(model.librarySection(in: windowB))

        model.selectTab(tab.id)
        XCTAssertNil(model.librarySection(in: windowA), "clicking the tab under the Library shows it")

        model.toggleLibrary(in: windowA)
        XCTAssertEqual(model.librarySection(in: windowA), .easels, "the Home button reopens the last page")
        model.toggleLibrary(in: windowA)
        XCTAssertNil(model.librarySection(in: windowA))
    }

    func testViewArchiveBoostsAndMediaAreLibraryPages() {
        let model = makeModel()
        XCTAssertNil(model.executeCommand(.viewArchive, commandID: nil))
        XCTAssertTrue(model.isArchivePresented)
        XCTAssertEqual(model.librarySection(in: nil), .archive)
        XCTAssertNil(model.executeCommand(.openCapturesGallery, commandID: nil))
        XCTAssertTrue(model.isCapturesGalleryPresented)
        XCTAssertFalse(model.isArchivePresented, "one page at a time")
        model.isBoostLibraryPresented = true
        XCTAssertEqual(model.librarySection(in: nil), .boosts)
        model.isArchivePresented = false
        XCTAssertTrue(model.isBoostLibraryPresented, "closing another page leaves this one")
        model.isBoostLibraryPresented = false
        XCTAssertNil(model.librarySection(in: nil))

        let tab = model.openInNewTab(URL(string: "https://restore.test")!)
        model.openLibrary(.archive)
        model.archiveTab()
        let record = try? XCTUnwrap(model.store.archivedTabs.first { $0.tab.id == tab.id })
        model.restoreArchivedTab(record!.id)
        XCTAssertNil(model.librarySection(in: nil), "a restored tab is shown")
    }

    func testViewMenuListsLibraryPages() {
        let model = makeModel()
        XCTAssertEqual(titles(ShellMenus.library(model)),
                       ["View Library", "View Spaces", "View Downloads", "View Media", "View Easels & Notes", "View Archive", "View Boosts"])
        ShellMenus.library(model).flatMap { $0 }.first { $0.title == "View Spaces" }!.action()
        XCTAssertEqual(model.librarySection(in: nil), .spaces)
        XCTAssertFalse(titles(ShellMenus.sidebarItems(model)).contains("View Archive"), "moved to the View menu's Library group")

        let space = model.store.addSpace(name: "Second")
        model.openLibrarySpace(space.id)
        XCTAssertEqual(model.store.activeSpaceID, space.id)
        XCTAssertNil(model.librarySection(in: nil))
    }

    // MARK: Gradient themes

    func testSpacesMenuAppearanceKeepsTheGradientAndGrain() {
        let model = makeModel()
        let space = model.store.activeSpaceID
        model.store.setSpaceTheme(space, theme: SpaceTheme.gradientPresets[0].addingStop())
        ShellMenus.spaces(model).flatMap { $0 }.first { $0.title == "Appearance: Dark" }!.action()
        let theme = model.store.activeSpace.theme
        XCTAssertEqual(theme.appearance, .dark)
        XCTAssertEqual(theme.stops.count, 3)
        XCTAssertNil(model.executeCommand(.setSpaceAppearance(.light), commandID: nil))
        XCTAssertEqual(model.store.activeSpace.theme.appearance, .light)
    }

    // MARK: Boosts v2

    func testVisualEditorZapsOnPickAndSavesIntoTheStylesheet() throws {
        let model = makeModel()
        let tab = model.store.addTab(kind: .today, title: "Site", url: URL(string: "https://boost.test/page")!)
        model.store.selectTab(tab.id)
        model.newBoost()
        let draft = try XCTUnwrap(model.boostEditorDraft)
        model.startBoostPicker(zap: true)
        XCTAssertTrue(model.boostEditorDraft?.zapOnPick == true)
        let descriptor = ElementDescriptor(tag: "div", id: "promo", classes: [], attrs: [:], structuralPath: ["body"])
        model.handleBoostPick(PickedElementSnapshot(descriptor: descriptor, bounds: ElementBounds(x: 0, y: 0, width: 10, height: 10),
                                                    viewportWidth: 100, viewportHeight: 100))
        XCTAssertEqual(model.boostEditorDraft?.visual.zaps.count, 1, "the pick zapped the element")
        XCTAssertFalse(model.boostEditorDraft?.zapOnPick ?? true)
        model.updateBoostVisual { $0.tint = BoostTint(hue: 0.3) }
        model.boostEditorCSSChanged("h1 { color: red; }")
        model.saveBoostEditor()
        let css = try XCTUnwrap(model.store.boostLibrary().package(id: draft.packageID)?.styleBoost?.css)
        let parsed = BoostVisualStyle.parse(css)
        XCTAssertEqual(parsed.style.tint?.hue ?? 0, 0.3, accuracy: 1e-9)
        XCTAssertEqual(parsed.style.zaps.count, 1)
        XCTAssertEqual(parsed.customCSS, "h1 { color: red; }")
    }

    func testLegacyBoostAndBoostFiles() throws {
        let model = makeModel()
        XCTAssertEqual(model.newLegacyBoost(), "Open a website to boost first")
        let tab = model.store.addTab(kind: .today, title: "Site", url: URL(string: "https://legacy.test/")!)
        model.store.selectTab(tab.id)
        XCTAssertNil(model.executeCommand(.newLegacyBoost, commandID: nil))
        let id = try XCTUnwrap(model.legacyBoostEditorID)
        XCTAssertNil(model.saveLegacyBoost(id, css: "body { margin: 0 }", js: "document.body.dataset.boosted = '1'"))
        XCTAssertEqual(model.saveLegacyBoost(id, css: "@import url(https://x.test/a.css);", js: "1"), "Boosts cannot load files from the web.")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-w28-boosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("good.rearcboost"), bad = directory.appendingPathComponent("bad.rearcboost")
        try XCTUnwrap(model.boostFileData(id)).write(to: good)
        try Data("{}".utf8).write(to: bad)
        let before = model.store.boostLibrary().packages.count
        let problems = model.importBoostFiles([good, bad])
        XCTAssertEqual(problems, ["bad.rearcboost: This file could not be read as a boost."])
        XCTAssertEqual(model.store.boostLibrary().packages.count, before + 1)
        let imported = try XCTUnwrap(model.store.boostLibrary().packages.last)
        XCTAssertEqual(model.store.boostLibrary().installation(for: imported.manifest.id)?.enabled, false, "script boosts arrive off")

        model.legacyBoostEditorID = nil
        model.editBoost(imported.manifest.id)
        XCTAssertEqual(model.legacyBoostEditorID, imported.manifest.id, "Edit opens the code editor for a script boost")
    }

    // MARK: Capture

    private func testPNG(width: Int, height: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0 ..< width { for y in 0 ..< height { rep.setColor(x < width / 2 ? NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1) : NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1), atX: x, y: y) } }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testCropAndPortraitProduceImagesOfTheLaidOutSize() throws {
        let png = try testPNG(width: 40, height: 20)
        let cropped = try XCTUnwrap(CaptureImaging.crop(png, to: CaptureRect(x: 0.5, y: 0, width: 0.5, height: 0.5)))
        let image = try XCTUnwrap(CaptureImaging.cgImage(cropped))
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 10)
        let rep = NSBitmapImageRep(cgImage: image)
        XCTAssertGreaterThan(rep.colorAt(x: 5, y: 5)?.blueComponent ?? 0, 0.9, "the right half is blue")

        let palette = SpaceThemePalette(theme: SpaceTheme.gradientPresets[0], darkAppearance: false)
        let framed = try XCTUnwrap(CaptureImaging.portrait(png, palette: palette, watermark: true))
        let framedImage = try XCTUnwrap(CaptureImaging.cgImage(framed))
        let layout = PortraitCaptureLayout(imageWidth: 40, imageHeight: 20, watermark: true)
        XCTAssertEqual(framedImage.width, Int(layout.canvasWidth))
        XCTAssertEqual(framedImage.height, Int(layout.canvasHeight))
    }

    func testCaptureOverlayNeedsAPageAndCancels() {
        let model = makeModel()
        XCTAssertEqual(model.beginPageCapture(), "No page to capture")
        let tab = model.store.addTab(kind: .today, title: "Site", url: URL(string: "https://capture.test/")!)
        model.store.selectTab(tab.id)
        XCTAssertNil(model.executeCommand(.captureAreaOrElement, commandID: nil))
        XCTAssertEqual(model.pageCaptureSession?.tabID, tab.id)
        model.cancelPageCapture()
        XCTAssertNil(model.pageCaptureSession)
        XCTAssertEqual(PageElementRect(["x": 1, "y": 2, "width": 3, "height": 4, "vw": 100, "vh": 50])?.fraction,
                       CaptureRect(x: 0.01, y: 0.04, width: 0.03, height: 0.08))
        XCTAssertNil(PageElementRect(["x": "nope"]))
        XCTAssertTrue(titles(ShellMenus.capture(model)).contains("Capture in Portrait Mode"))
    }

    // MARK: Notes

    private func noteEditor(_ content: NoteContent) -> (NoteTextEditor.Coordinator, NoteTextView, () -> NoteContent?) {
        var latest: NoteContent?
        let coordinator = NoteTextEditor.Coordinator(onChange: { latest = $0 }, onOpenLink: { _ in })
        let view = NoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.isRichText = true
        view.delegate = coordinator
        view.coordinator = coordinator
        coordinator.textView = view
        coordinator.load(content)
        return (coordinator, view, { latest })
    }

    func testNoteTextRoundTripsThroughTheAttributedString() {
        let content = NoteContent(blocks: [
            NoteBlock(.heading(2), text: "Plan"),
            NoteBlock(runs: [NoteRun("a "), NoteRun("b", bold: true, italic: true), NoteRun(" c", underline: true)]),
            NoteBlock(.numbered, text: "one"),
            NoteBlock(.checklist(checked: true), runs: [NoteRun("done", code: true)]),
            NoteBlock(.bullet, runs: [NoteRun("link", link: URL(string: "https://x.test"))]),
            NoteBlock(.quote, runs: [NoteRun("cut", strikethrough: true)]),
            NoteBlock(),
        ])
        let text = NoteTextFormatting.attributedString(content)
        XCTAssertEqual(NoteTextFormatting.content(text, emptyLastStyle: .paragraph), content)
        XCTAssertEqual(NoteTextFormatting.content(text).blocks.last?.style, .quote, "without it, an empty last line continues the one before")
        XCTAssertTrue(text.string.hasPrefix("Plan\na b c\n1.\tone\n☑\tdone\n•\tlink\ncut\n"))
        let position = NoteTextFormatting.blockPosition(of: (text.string as NSString).range(of: "one").location + 2, in: content)
        XCTAssertEqual(position.block, 2)
        XCTAssertEqual(position.offset, 2)
        XCTAssertEqual(NoteTextFormatting.location(of: position, in: content), (text.string as NSString).range(of: "one").location + 2)
    }

    func testNoteEditorContinuesListsAndFormatsMarkdownShortcuts() throws {
        let (coordinator, view, latest) = noteEditor(NoteContent(blocks: [NoteBlock(.bullet, text: "milk")]))
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(latest()?.blocks.map(\.style), [.bullet, .bullet], "Return continues the list")
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(latest()?.blocks.map(\.style), [.bullet, .paragraph], "Return on an empty item ends it")

        view.insertText("[] ", replacementRange: view.selectedRange())
        XCTAssertEqual(latest()?.blocks.last?.style, .checklist(checked: false), "a typed shortcut formats the line")
        XCTAssertEqual(latest()?.blocks.last?.text, "")
        view.insertText("eggs", replacementRange: view.selectedRange())
        XCTAssertEqual(latest()?.blocks.last?.text, "eggs")

        let markerIndex = (view.string as NSString).range(of: "☐").location
        XCTAssertTrue(coordinator.clicked(atCharacter: markerIndex))
        XCTAssertEqual(latest()?.blocks.last?.style, .checklist(checked: true), "a click on the box checks it")

        let eggs = (view.string as NSString).range(of: "eggs")
        view.setSelectedRange(eggs)
        coordinator.toggleInline(.noteBold)
        XCTAssertEqual(latest()?.blocks.last?.runs, [NoteRun("eggs", bold: true)])
        coordinator.setLink(URL(string: "https://eggs.test"))
        XCTAssertEqual(latest()?.blocks.last?.runs.first?.link, URL(string: "https://eggs.test"))

        view.setSelectedRange(NSRange(location: eggs.location, length: 0))
        XCTAssertTrue(coordinator.textView(view, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(latest()?.blocks.last?.style, .paragraph, "delete at the start clears the list style first")
    }

    // MARK: Browser import

    func testImportMenuOffersChromiumsImporterOnlyWithTheEngine() {
        let model = makeModel()
        XCTAssertEqual(titles(ShellMenus.importing(model, chromiumImporter: false)), ["Import Bookmarks from HTML File…"])
        XCTAssertEqual(titles(ShellMenus.importing(model, chromiumImporter: true)),
                       ["Import from Another Browser…", "Import Bookmarks from HTML File…"])
        XCTAssertEqual(BrowserInternalPage.importData.url.absoluteString, "chrome://settings/importData")
        XCTAssertFalse(BrowserInternalPage.importData.isAvailable(engine: model.engineHost.navigationSchemes), "WebKit has no Chromium WebUI")
        XCTAssertTrue(BrowserInternalPage.importData.isAvailable(engine: .chromium))
        XCTAssertNotNil(model.executeCommand(.openBrowserPage(.importData), commandID: nil), "explains it needs the Chromium engine")

        XCTAssertEqual(model.importBookmarks(fromHTML: "plain text", spaceName: "X"), "That file is not a bookmarks export")
        let html = "<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><A HREF=\"https://one.test/\">One</A></DL>"
        XCTAssertNil(model.importBookmarks(fromHTML: html, spaceName: "Chrome"))
        XCTAssertEqual(model.store.activeSpace.name, "Chrome", "the imported space is shown")
        XCTAssertEqual(model.toast?.message, "Imported 1 bookmark into Chrome")
    }

    // MARK: DevTools and client certificates (engine wave 18h)

    private final class FakeDevToolsOpener: DevToolsOpening {
        var opened: [Tab.ID] = []
        func openDevTools(for tab: Tab, engine: any WebEngine) -> String? {
            opened.append(tab.id)
            return nil
        }
    }

    func testCapabilitiesGateDevToolsAndClientCertificatesOnTheirMinors() {
        let all: (String) -> Bool = { _ in true }
        let old = ChromiumCapabilities(abiMinorVersion: 39, hasFeature: all)
        XCTAssertFalse(old.devTools)
        XCTAssertFalse(old.canInspect, "Inspect stays disabled before ABI 1.40")
        XCTAssertFalse(old.clientCertificates)
        let forty = ChromiumCapabilities(abiMinorVersion: 40, hasFeature: all)
        XCTAssertTrue(forty.devTools && forty.canInspect)
        XCTAssertFalse(forty.clientCertificates)
        let current = ChromiumCapabilities(abiMinorVersion: 41, hasFeature: all)
        XCTAssertTrue(current.clientCertificates)
        XCTAssertTrue(current.summary.contains("devtools=1 client_certificates=1"))
        XCTAssertFalse(ChromiumCapabilities(abiMinorVersion: 41, hasFeature: { $0 != "devtools" }).canInspect)
    }

    func testDevToolsOpenDockPopOutAndCloseThroughTheModel() throws {
        let model = makeModel()
        XCTAssertEqual(model.toggleDevTools(), "No page to inspect")
        let tab = model.openInNewTab(URL(string: "https://inspect.test/")!)
        XCTAssertEqual(model.toggleDevTools(), "Developer Tools need the Chromium engine", "WebKit has none")
        let opener = FakeDevToolsOpener()
        model.devToolsOpener = opener
        XCTAssertNil(model.toggleDevTools())
        XCTAssertNil(model.toggleDevTools(), "a second ⌥⌘I while it opens asks nothing more")
        XCTAssertEqual(opener.opened, [tab.id])

        let frontend = model.engineHost.engine(for: model.store.addTab(kind: .today, title: "F", url: URL(string: "about:blank")!),
                                               profileID: model.store.activeProfileID)
        model.store.selectTab(tab.id)
        model.attachDevTools(frontend, frontendTabID: 77, for: tab.id)
        XCTAssertTrue(model.dockedDevTools(for: tab.id) === frontend, "docked by default")
        model.setDevToolsPlacement(.window)
        XCTAssertNil(model.dockedDevTools(for: tab.id))
        XCTAssertEqual(model.devTools.session(for: tab.id)?.placement, .window)
        model.devToolsWindowClosed(for: tab.id)
        XCTAssertNil(model.devTools.session(for: tab.id), "closing the window closes them")

        model.attachDevTools(frontend, frontendTabID: 78, for: tab.id)
        model.devToolsFrontendClosed(78)
        XCTAssertNil(model.devToolsEngine(for: tab.id), "the engine closed the frontend with its page")
        model.attachDevTools(frontend, frontendTabID: 79, for: tab.id)
        model.releaseEngine(for: tab.id)
        XCTAssertNil(model.devTools.session(for: tab.id), "closing the page closes its DevTools")
        XCTAssertEqual(titles(ShellMenus.developer(model)).first, "Developer Tools")
        XCTAssertEqual(ShellMenus.developer(model).first?.first?.menuKeyEquivalent, "i")
    }

    func testCertificateSheetQueuesAndRepliesOnce() {
        let prompts = PagePromptCenter()
        let a = ClientCertificateIdentity(fingerprint: String(repeating: "A", count: 64), subject: "Client Cert A", issuer: "B CA",
                                          expires: Date().addingTimeInterval(86_400))
        let d = ClientCertificateIdentity(fingerprint: String(repeating: "D", count: 64), subject: "Client Cert D", issuer: "E CA",
                                          expires: Date().addingTimeInterval(86_400))
        var replies: [(UInt64, String?)] = []
        prompts.presentClientCertificate(ClientCertificateRequest(id: 1, origin: "https://m.test", identities: [d, a])) { replies.append((1, $0)) }
        prompts.presentClientCertificate(ClientCertificateRequest(id: 2, origin: "https://m.test", identities: [a])) { replies.append((2, $0)) }
        XCTAssertEqual(prompts.clientCertificate?.id, 1)
        XCTAssertEqual(prompts.selectedCertificate, a.fingerprint, "the first sorted identity is preselected")
        XCTAssertTrue(prompts.hasPendingPrompt)
        prompts.answerClientCertificate(String(repeating: "F", count: 64))
        XCTAssertTrue(replies.isEmpty, "an unlisted fingerprint is not sent")
        prompts.answerClientCertificate(d.fingerprint)
        XCTAssertEqual(replies.map(\.1), [d.fingerprint])
        XCTAssertEqual(prompts.clientCertificate?.id, 2, "the next request shows")
        prompts.cancelClientCertificate(id: 2)
        XCTAssertNil(prompts.clientCertificate, "withdrawn by the engine: no reply")
        XCTAssertEqual(replies.count, 1)
        prompts.presentClientCertificate(ClientCertificateRequest(id: 3, origin: "https://m.test", identities: [a])) { replies.append((3, $0)) }
        prompts.answerAllConservatively()
        XCTAssertEqual(replies.last?.0, 3)
        XCTAssertNil(replies.last?.1, "closing the page cancels it")
    }
}
