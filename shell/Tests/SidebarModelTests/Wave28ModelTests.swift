import XCTest
@testable import SidebarModel

/// Wave 28: the Library, gradient themes, Boosts v2, region capture, rich
/// notes and browser import.
final class Wave28ModelTests: XCTestCase {

    // MARK: Library

    func testLibraryPagesFollowArcsHomeButtonOrder() {
        XCTAssertEqual(LibrarySection.allCases.map(\.title),
                       ["Spaces", "Downloads", "Media", "Easels & Notes", "Archive", "Boosts"])
        XCTAssertEqual(LibrarySection.easels.menuTitle, "View Easels & Notes")
        XCTAssertEqual(LibrarySection.archive.systemImage, "archivebox")
    }

    func testLibraryIsPerWindowAndClosesWhenTheWindowShowsAnotherItem() {
        var library = LibraryPresentation()
        let a = SidebarWindowID(), b = SidebarWindowID()
        let tab = UUID(), other = UUID()
        XCTAssertNil(library.section(in: a, selection: tab))

        library.open(.media, in: a, selection: tab)
        XCTAssertEqual(library.section(in: a, selection: tab), .media)
        XCTAssertNil(library.section(in: b, selection: tab), "another window keeps its page")
        XCTAssertNil(library.section(in: a, selection: other), "a new selection shows the item")

        library.open(.archive, in: a, selection: nil)
        XCTAssertEqual(library.section(in: a, selection: nil), .archive, "an empty window can show it too")
        library.close(in: a)
        XCTAssertNil(library.section(in: a, selection: nil))
    }

    func testHomeButtonReopensTheLastPageOrCloses() {
        var library = LibraryPresentation()
        let window = SidebarWindowID()
        XCTAssertEqual(library.lastSection, .spaces)
        library.toggle(in: window, selection: nil)
        XCTAssertEqual(library.section(in: window, selection: nil), .spaces)
        library.open(.boosts, in: window, selection: nil)
        library.toggle(in: window, selection: nil)
        XCTAssertNil(library.section(in: window, selection: nil))
        library.toggle(in: window, selection: nil)
        XCTAssertEqual(library.section(in: window, selection: nil), .boosts, "the last page comes back")
        library.forgetWindow(window)
        XCTAssertNil(library.section(in: window, selection: nil))
    }

    func testAStalePageStaysClosedWhenTheItemComesBack() {
        var library = LibraryPresentation()
        let a = SidebarWindowID(), b = SidebarWindowID()
        let tab = UUID(), other = UUID()
        library.open(.media, in: a, selection: tab)
        library.open(.spaces, in: b, selection: other)
        library.closeStale { $0 == a ? other : other }
        XCTAssertNil(library.section(in: a, selection: tab), "window a showed another tab, then came back")
        XCTAssertEqual(library.section(in: b, selection: other), .spaces)
    }

    func testMediaListsCapturesNewestFirstWithTheirEasels() {
        let old = CaptureRecord(sourceURL: URL(string: "https://old.test/a"), sourceTitle: "Old page",
                                createdAt: Date(timeIntervalSince1970: 100), scope: .visible)
        let new = CaptureRecord(sourceURL: URL(string: "https://new.test/b"), sourceTitle: "New page",
                                createdAt: Date(timeIntervalSince1970: 200), scope: .fullPage)
        let frame = EaselFrame(x: 0, y: 0, width: 10, height: 10)
        let board = EaselDocument(title: "Board", updatedAt: Date(timeIntervalSince1970: 50), blocks: [
            EaselBlock(frame: frame, payload: .image(captureID: old.id)),
            EaselBlock(frame: frame, payload: .image(captureID: old.id)),
        ])
        let moodboard = EaselDocument(title: "Moodboard", updatedAt: Date(timeIntervalSince1970: 60), blocks: [
            EaselBlock(frame: frame, payload: .image(captureID: old.id)),
        ])

        let all = LibraryMedia.items(captures: [old, new], documents: [board, moodboard])
        XCTAssertEqual(all.map(\.id), [new.id, old.id])
        XCTAssertEqual(all[1].easelTitles, ["Moodboard", "Board"], "each easel once, most recently edited first")
        XCTAssertEqual(LibraryMedia.items(captures: [old, new], documents: [board], filter: .inEasels).map(\.id), [old.id])
        XCTAssertEqual(LibraryMedia.items(captures: [old, new], documents: [board], filter: .notInEasels).map(\.id), [new.id])
        XCTAssertEqual(LibraryMedia.items(captures: [old, new], documents: [board], query: "NEW.test").map(\.id), [new.id], "by site")
        XCTAssertEqual(LibraryMedia.items(captures: [old, new], documents: [board], query: "board").map(\.id), [old.id], "by easel")
    }

    func testEaselsAndNotesRowsFilterSearchAndSummarize() {
        let frame = EaselFrame(x: 0, y: 0, width: 10, height: 10)
        let easel = EaselDocument(title: "Trip", updatedAt: Date(timeIntervalSince1970: 10), blocks: [
            EaselBlock(frame: frame, payload: .shape(kind: .rectangle, color: .accent, arrowEnd: nil)),
            EaselBlock(frame: frame, payload: .image(captureID: UUID())),
        ])
        var note = EaselDocumentOps.noteDocument(title: "Groceries")
        note.updatedAt = Date(timeIntervalSince1970: 20)
        note.blocks[0].payload = .text(runs: [EaselRichTextRun(text: "Milk\nEggs")])
        let docs = [easel.id: easel, note.id: note]
        let refs = [
            (ref: SidebarEaselRef(easelDocumentID: easel.id), spaceName: "Home"),
            (ref: SidebarEaselRef(easelDocumentID: note.id), spaceName: "Work"),
            (ref: SidebarEaselRef(easelDocumentID: UUID()), spaceName: "Gone"),
        ]

        let rows = LibraryDocuments.rows(refs: refs, document: { docs[$0] })
        XCTAssertEqual(rows.map(\.title), ["Groceries", "Trip"], "newest first; a missing document is skipped")
        XCTAssertEqual(rows[0].summary, "Milk")
        XCTAssertEqual(rows[0].kind, .note)
        XCTAssertEqual(rows[1].summary, "2 objects, 1 image")
        XCTAssertEqual(rows[1].spaceName, "Home")
        XCTAssertEqual(LibraryDocuments.rows(refs: refs, document: { docs[$0] }, filter: .easels).map(\.title), ["Trip"])
        XCTAssertEqual(LibraryDocuments.rows(refs: refs, document: { docs[$0] }, filter: .notes).map(\.title), ["Groceries"])
        XCTAssertEqual(LibraryDocuments.rows(refs: refs, document: { docs[$0] }, query: "milk").map(\.title), ["Groceries"])
    }

    func testDocumentsWithoutAKindAreInferredOnDecode() throws {
        let note = EaselDocumentOps.noteDocument()
        XCTAssertEqual(note.kind, .note)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as! [String: Any]
        json["kind"] = nil
        let legacyNote = try JSONDecoder().decode(EaselDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacyNote.kind, .note, "a pre-wave-28 New Note")

        let easel = EaselDocumentOps.emptyEasel(title: "Note to self")
        json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(easel)) as! [String: Any]
        json["kind"] = nil
        XCTAssertEqual(try JSONDecoder().decode(EaselDocument.self, from: JSONSerialization.data(withJSONObject: json)).kind, .easel)

        let roundTrip = try JSONDecoder().decode(EaselDocument.self, from: JSONEncoder().encode(note))
        XCTAssertEqual(roundTrip, note)
    }

    func testSpacesPageGroupsByProfileWithCounts() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        store.addTab(kind: .pinned, title: "P", url: URL(string: "https://p.test")!)
        store.addTab(kind: .today, title: "T1", url: URL(string: "https://t1.test")!)
        store.addTab(kind: .today, title: "T2", url: URL(string: "https://t2.test")!)
        let groups = LibrarySpaces.groups(in: store)
        XCTAssertEqual(groups.count, store.profiles.count)
        let row = try? XCTUnwrap(groups.flatMap(\.rows).first { $0.space.name == "Main" })
        XCTAssertEqual(row?.pinnedCount, 1)
        XCTAssertEqual(row?.todayCount, 2)
    }

    func testLibraryCommandsAreInTheCommandBar() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: ClosedTabStack())
        let commands = AppCommandRegistry.all(in: context)
        XCTAssertTrue(commands.contains { $0.title == "View Library" && $0.action == .openLibrary(nil) })
        XCTAssertTrue(commands.contains { $0.title == "View Easels & Notes" && $0.action == .openLibrary(.easels) })
        XCTAssertTrue(commands.contains { $0.title == "View Media" && $0.action == .openCapturesGallery })
    }

    // MARK: Gradient themes

    func testPlainThemesEncodeExactlyAsBeforeAndLegacyThemesDecode() throws {
        let plain = SpaceTheme.presets[2]
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["red", "green", "blue"])
        let legacy = try JSONDecoder().decode(SpaceTheme.self, from: Data(#"{"red":0.1,"green":0.2,"blue":0.3}"#.utf8))
        XCTAssertEqual(legacy, SpaceTheme(red: 0.1, green: 0.2, blue: 0.3))
        XCTAssertEqual(legacy.appearance, .automatic)
        let unknownAppearance = try JSONDecoder().decode(SpaceTheme.self, from: Data(#"{"red":0,"green":0,"blue":0,"appearance":"sepia"}"#.utf8))
        XCTAssertEqual(unknownAppearance.appearance, .automatic, "a future appearance falls back")

        var styled = plain
        styled.gradientColors = [SpaceColor(red: 1, green: 0, blue: 0)]
        styled.noise = 0.25
        styled.appearance = .dark
        XCTAssertEqual(try JSONDecoder().decode(SpaceTheme.self, from: JSONEncoder().encode(styled)), styled)
    }

    func testThemeKeepsAtMostThreeStopsAndClampsGrain() {
        var theme = SpaceTheme(red: 1, green: 0, blue: 0, gradientColors: Array(repeating: SpaceColor(red: 0, green: 0, blue: 1), count: 5), noise: 3)
        XCTAssertEqual(theme.stops.count, SpaceTheme.maxGradientColors)
        XCTAssertEqual(theme.noise, 1)
        theme.noise = -.infinity
        XCTAssertEqual(theme.noise, 0)
        theme.gradientColors.append(SpaceColor(red: 0, green: 1, blue: 0))
        XCTAssertEqual(theme.gradientColors.count, 2)
    }

    func testEditorAddsSetsAndRemovesStops() {
        let red = SpaceTheme(red: 1, green: 0, blue: 0)
        let two = red.addingStop()
        XCTAssertEqual(two.stops.count, 2)
        XCTAssertEqual(two.stops[1].red, 1, accuracy: 1e-9, "60° from red is yellow")
        XCTAssertEqual(two.stops[1].green, 1, accuracy: 1e-9)
        let three = two.addingStop()
        XCTAssertEqual(three.addingStop(), three, "three stops at most")
        let blue = SpaceTheme(red: 0, green: 0, blue: 1)
        XCTAssertEqual(three.settingStop(2, to: blue).stops[2], blue)
        XCTAssertEqual(three.settingStop(0, to: blue).baseColor, blue)
        XCTAssertEqual(three.settingStop(7, to: blue), three)
        let promoted = three.removingStop(0)
        XCTAssertEqual(promoted.stops, Array(three.stops.dropFirst()), "the next stop becomes the base")
        XCTAssertEqual(red.removingStop(0), red, "the last colour stays")

        var dark = three
        dark.appearance = .dark
        dark.noise = 0.5
        XCTAssertEqual(dark.withBaseColor(blue).appearance, .dark, "a swatch keeps the style")
        XCTAssertEqual(dark.withBaseColor(blue).noise, 0.5)
    }

    func testAppearanceResolvesAgainstTheMac() {
        XCTAssertTrue(SpaceAppearance.automatic.isDark(systemDark: true))
        XCTAssertFalse(SpaceAppearance.automatic.isDark(systemDark: false))
        XCTAssertFalse(SpaceAppearance.light.isDark(systemDark: true))
        XCTAssertTrue(SpaceAppearance.dark.isDark(systemDark: false))
    }

    func testGradientPaletteRunsThroughEveryStopAndMixesAcrossStopCounts() {
        let theme = SpaceTheme(red: 1, green: 0, blue: 0, gradientColors: [SpaceColor(red: 0, green: 0, blue: 1)], noise: 0.3)
        let palette = SpaceThemePalette(theme: theme, darkAppearance: false)
        XCTAssertTrue(palette.isDiagonal)
        XCTAssertEqual(palette.colors.count, 2)
        XCTAssertGreaterThan(palette.top.red, palette.top.blue)
        XCTAssertGreaterThan(palette.bottom.blue, palette.bottom.red)
        XCTAssertEqual(palette.noise, 0.3)
        XCTAssertEqual(palette.accent, theme.baseColor)

        let plain = SpaceThemePalette(theme: .default, darkAppearance: false)
        XCTAssertFalse(plain.isDiagonal)
        let three = SpaceThemePalette(theme: SpaceTheme.gradientPresets[4], darkAppearance: true)
        XCTAssertEqual(three.colors.count, 3)
        let half = plain.mixed(with: three, fraction: 0.5)
        XCTAssertEqual(half.colors.count, 3, "sampled at the larger stop count")
        XCTAssertEqual(plain.mixed(with: three, fraction: 1).colors, three.colors)
        XCTAssertEqual(palette.color(at: 0.5), palette.top.mixed(with: palette.bottom, fraction: 0.5))
    }

    func testSpacesMenuCommandsSetTheActiveSpaceAppearance() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: ClosedTabStack())
        let commands = AppCommandRegistry.all(in: context).filter {
            if case .setSpaceAppearance = $0.action { return true }
            return false
        }
        XCTAssertEqual(commands.map(\.title), ["Appearance: Light", "Appearance: Dark"], "the current one is hidden")
        var theme = store.activeSpace.theme
        theme.appearance = .dark
        store.setSpaceTheme(store.activeSpaceID, theme: theme)
        XCTAssertTrue(AppCommandRegistry.all(in: context).contains { $0.action == .setSpaceAppearance(.automatic) })
    }

    // MARK: Boosts v2

    func testVisualBoostCompilesToSafeCSSAndParsesBack() {
        var style = BoostVisualStyle(tint: BoostTint(hue: 0.6, intensity: 0.4, harmony: .complementary),
                                     darkMode: true, font: .family("Avenir Next"), textScale: 1.25)
        style.appendZap(".cookie-banner")
        style.appendZap("#promo > div:nth-of-type(2)")
        style.appendZap(".cookie-banner")
        style.appendZap("a { color: red }")
        XCTAssertEqual(style.zaps, [".cookie-banner", "#promo > div:nth-of-type(2)"], "a selector zaps once; braces are refused")

        let custom = "h1 { letter-spacing: 2px; }\n  /* mine */ "
        let css = BoostVisualStyle.compose(style, customCSS: custom)
        XCTAssertTrue(BoostSecurity.validateCSS(css, allowInStyle: true).isEmpty)
        XCTAssertNotNil(BoostStyleCompiler.compileStylesheet(css), "every block parses")
        XCTAssertTrue(css.contains("hsl(216, 85%, 50%)"), "hue 0.6 is 216°")
        XCTAssertTrue(css.contains("hsl(36, 85%, 50%)"), "complementary adds 216 + 180")
        XCTAssertTrue(css.contains("invert(1) hue-rotate(180deg)"))
        XCTAssertTrue(css.contains("\"Avenir Next\", sans-serif"))
        XCTAssertTrue(css.contains("font-size: 125% !important"))
        XCTAssertTrue(css.contains(".cookie-banner {\n  display: none !important;\n}"))
        let comment = css.split(separator: "\n")[0]
        XCTAssertFalse(comment.contains("{") || comment.contains("}"), "the settings line holds no braces")

        let parsed = BoostVisualStyle.parse(css)
        XCTAssertEqual(parsed.style, style)
        XCTAssertEqual(parsed.customCSS, custom, "hand-written CSS comes back exactly as typed")
        XCTAssertEqual(BoostVisualStyle.compose(parsed.style, customCSS: parsed.customCSS), css)
    }

    func testStylesheetsWithoutTheBlockAreAllHandWritten() {
        let legacy = "/* ReArc boost */\n.ad { display: none !important; }\n"
        let parsed = BoostVisualStyle.parse(legacy)
        XCTAssertTrue(parsed.style.isEmpty)
        XCTAssertEqual(parsed.customCSS, legacy)
        XCTAssertEqual(BoostVisualStyle.compose(BoostVisualStyle(), customCSS: legacy), legacy, "no settings, no block")
        XCTAssertEqual(BoostVisualStyle().compiled(), "")
    }

    func testDraftEditsVisualAndCustomCSSIndependently() {
        var draft = BoostEditorDraft(packageID: UUID(), baselineCSS: "p { color: blue; }\n")
        draft.updateVisual { $0.darkMode = true }
        XCTAssertTrue(draft.visual.darkMode)
        XCTAssertEqual(draft.customCSS, "p { color: blue; }\n")
        draft.setCustomCSS("p { color: green; }")
        XCTAssertTrue(draft.visual.darkMode, "typing CSS keeps the settings")
        XCTAssertTrue(draft.isDirty)
        draft.updateVisual { $0.darkMode = false }
        XCTAssertEqual(draft.draftCSS, "p { color: green; }")
    }

    func testTintHarmoniesFontNamesAndRanges() {
        XCTAssertEqual(BoostTint(hue: 0.5).degrees, [180])
        XCTAssertEqual(BoostTint(hue: 0.95, harmony: .analogous).degrees, [342, 22])
        XCTAssertEqual(BoostTint(hue: -0.25).hue, 0.75, accuracy: 1e-9)
        XCTAssertEqual(BoostTint(hue: 0, intensity: 7).intensity, 1)
        XCTAssertEqual(BoostTint.namedHues.count, 8, "Arc's eight Boost colours")
        XCTAssertEqual(BoostFontChoice.safeFamilyName(" Helvetica Neue "), "Helvetica Neue")
        XCTAssertNil(BoostFontChoice.safeFamilyName("Evil\"; } body { x"))
        XCTAssertNil(BoostFontChoice.safeFamilyName(""))
        XCTAssertEqual(BoostVisualStyle(textScale: 9).textScale, 2)
        let parsed = BoostVisualStyle.parse("/* rearc-visual-boost v1 font=family:Bad\"Name zaps=0 */\n/* /rearc-visual-boost */\n")
        XCTAssertNil(parsed.style.font, "an unsafe family in the comment is dropped")
    }

    func testLegacyBoostsStartWithTheirScriptNotAllowedAndValidateEdits() throws {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        XCTAssertNil(store.createLegacyBoost(name: "X", pageURL: URL(string: "about:blank")!))
        let boost = try XCTUnwrap(store.createLegacyBoost(name: "Legacy", pageURL: URL(string: "https://news.test/a")!))
        let library = store.boostLibrary()
        XCTAssertEqual(library.installation(for: boost.manifest.id)?.enabled, true)
        XCTAssertEqual(library.package(id: boost.manifest.id)?.scriptBoost?.userScriptEnabled, false)
        XCTAssertNil(library.package(id: boost.manifest.id)?.styleBoost)

        XCTAssertEqual(store.updateBoostScript(packageID: boost.manifest.id, css: "", js: "s.src='https://evil.test/x.js'"),
                       [.remoteScriptSourceInJS])
        XCTAssertEqual(store.updateBoostScript(packageID: boost.manifest.id, css: "body { color: red }", js: "document.title = 'x'"), [])
        let saved = try XCTUnwrap(store.boostLibrary().package(id: boost.manifest.id))
        XCTAssertEqual(saved.scriptBoost?.js, "document.title = 'x'")
        XCTAssertEqual(saved.manifest.version, 2)
        XCTAssertEqual(store.updateBoostScript(packageID: UUID(), css: "", js: ""), [.emptyScriptPayload])
    }

    func testBoostFilesRoundTripAndNeverGrantScriptPermission() throws {
        var package = BoostPackage.newScript(name: "Shared: a/b", hostScope: [BoostHostRule(host: "news.test")], js: "1")
        package.scriptBoost?.userScriptEnabled = true
        let data = try BoostInterchange.exportJSON(package)
        guard case .success(let imported) = BoostInterchange.importJSON(data) else { return XCTFail("import failed") }
        XCTAssertNotEqual(imported.manifest.id, package.manifest.id, "an import forks")
        XCTAssertEqual(imported.scriptBoost?.userScriptEnabled, false, "the user allows the script, not the file")
        XCTAssertFalse(BoostInterchange.defaultEnabledOnImport(imported))
        XCTAssertEqual(BoostInterchange.suggestedFileName(for: package), "Shared- a-b.rearcboost")
        XCTAssertEqual(BoostInterchange.describe(.unsupportedVersion), "This boost was made by a newer ReArc.")
        guard case .failure(.decodeFailed) = BoostInterchange.importJSON(Data("nope".utf8)) else { return XCTFail() }
    }

    // MARK: Capture

    func testCaptureDetailIsOptionalSoOlderIndexesStillRead() throws {
        let record = CaptureRecord(sourceURL: nil, sourceTitle: "T", scope: .visible, detail: .region)
        XCTAssertEqual(try JSONDecoder().decode(CaptureRecord.self, from: JSONEncoder().encode(record)), record)
        let plain = CaptureRecord(sourceURL: nil, sourceTitle: "T", scope: .fullPage)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
        XCTAssertNil(json["detail"], "a plain capture writes what wave 27 wrote")
        var future = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        future["detail"] = "hologram"
        let decoded = try JSONDecoder().decode(CaptureRecord.self, from: JSONSerialization.data(withJSONObject: future))
        XCTAssertNil(decoded.detail, "an unknown detail is dropped, not the record")
    }

    func testDragAndElementRectsBecomeFractionsAndPixels() throws {
        XCTAssertNil(CaptureCropping.dragFraction(from: (10, 10), to: (14, 40), viewWidth: 200, viewHeight: 100), "a click, not a drag")
        let drag = try XCTUnwrap(CaptureCropping.dragFraction(from: (150, 80), to: (50, -20), viewWidth: 200, viewHeight: 100))
        XCTAssertEqual(drag, CaptureRect(x: 0.25, y: 0, width: 0.5, height: 0.8), "any direction, clipped to the view")

        let element = try XCTUnwrap(CaptureCropping.elementFraction(ElementBounds(x: -20, y: 50, width: 120, height: 100),
                                                                     viewportWidth: 400, viewportHeight: 100))
        XCTAssertEqual(element, CaptureRect(x: 0, y: 0.5, width: 0.25, height: 0.5), "only the part on screen")
        XCTAssertNil(CaptureCropping.elementFraction(ElementBounds(x: 0, y: 200, width: 10, height: 10), viewportWidth: 100, viewportHeight: 100))

        XCTAssertEqual(CaptureCropping.pixelRect(CaptureRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5), imageWidth: 801, imageHeight: 400),
                       CaptureRect(x: 200, y: 200, width: 401, height: 200), "rounded outward to whole pixels")
        XCTAssertEqual(CaptureCropping.pixelRect(CaptureRect(x: 1, y: 1, width: 0, height: 0), imageWidth: 10, imageHeight: 10),
                       CaptureRect(x: 9, y: 9, width: 1, height: 1), "never empty, never outside")
    }

    func testPortraitLayoutFramesTheCaptureWithAMarginAndWatermark() throws {
        let layout = PortraitCaptureLayout(imageWidth: 1000, imageHeight: 600, watermark: true)
        XCTAssertEqual(layout.image, CaptureRect(x: 48, y: 48, width: 1000, height: 600))
        XCTAssertEqual(layout.canvasWidth, 1096)
        XCTAssertEqual(layout.canvasHeight, 696)
        XCTAssertEqual(layout.cornerRadius, 15)
        let mark = try XCTUnwrap(layout.watermark)
        XCTAssertEqual(mark.x, 1048, "right-aligned inside the margin")
        XCTAssertGreaterThan(mark.y, 648, "in the bottom margin")
        XCTAssertNil(PortraitCaptureLayout(imageWidth: 1000, imageHeight: 600, watermark: false).watermark)
    }

    func testCaptureCommands() {
        let store = SidebarStore(spaces: [Space(name: "Main", sortRank: "a")])
        let tab = store.addTab(kind: .today, title: "T", url: URL(string: "https://t.test")!)
        store.selectTab(tab.id)
        let context = CommandBarContext(store: store, isSidebarVisible: true, closedTabStack: ClosedTabStack())
        let titles = AppCommandRegistry.all(in: context).map(\.title)
        XCTAssertTrue(titles.contains("Capture"))
        XCTAssertTrue(titles.contains("Capture in Portrait Mode"))
    }

    // MARK: Notes

    private var sampleNote: NoteContent {
        NoteContent(blocks: [
            NoteBlock(.heading(1), text: "Trip"),
            NoteBlock(runs: [NoteRun("Pack "), NoteRun("light", bold: true), NoteRun(" and "), NoteRun("early", italic: true)]),
            NoteBlock(.numbered, text: "Passport"),
            NoteBlock(.numbered, text: "Tickets"),
            NoteBlock(.checklist(checked: true), text: "Book hotel"),
            NoteBlock(.checklist(checked: false), text: "Pack"),
            NoteBlock(.bullet, runs: [NoteRun("Map", link: URL(string: "https://maps.test/x"))]),
            NoteBlock(.numbered, text: "Again"),
            NoteBlock(.quote, runs: [NoteRun("Go", code: true), NoteRun(" gone", strikethrough: true)]),
        ])
    }

    func testMarkersNumberEachListAndMarkdownExports() {
        XCTAssertEqual(sampleNote.markers(), [nil, nil, "1.", "2.", "☑", "☐", "•", "1.", nil], "numbering restarts after another kind")
        XCTAssertEqual(sampleNote.markdown(), """
        # Trip
        Pack **light** and *early*
        1. Passport
        2. Tickets
        - [x] Book hotel
        - [ ] Pack
        - [Map](https://maps.test/x)
        1. Again
        > `Go`~~ gone~~
        """)
        XCTAssertEqual(sampleNote.plainText.split(separator: "\n").first, "Trip")
    }

    func testNotesRoundTripAndMirrorTheirTextForOlderBuilds() throws {
        var document = EaselDocumentOps.noteDocument()
        document.setNoteContent(sampleNote, now: Date(timeIntervalSince1970: 5))
        let decoded = try JSONDecoder().decode(EaselDocument.self, from: JSONEncoder().encode(document))
        XCTAssertEqual(decoded.noteContent, sampleNote)
        guard case .text(let runs) = decoded.blocks[0].payload else { return XCTFail("no mirror") }
        XCTAssertEqual(runs.map(\.text).joined(), sampleNote.plainText, "a wave 27 build shows the text")
        XCTAssertEqual(decoded.updatedAt, Date(timeIntervalSince1970: 5))

        let json = String(decoding: try JSONEncoder().encode(NoteRun("plain")), as: UTF8.self)
        XCTAssertEqual(json, #"{"text":"plain"}"#, "unset styles are not written")
        let rows = LibraryDocuments.rows(refs: [(ref: SidebarEaselRef(easelDocumentID: document.id), spaceName: "S")],
                                         document: { _ in decoded })
        XCTAssertEqual(rows.first?.summary, "Trip")
    }

    func testLegacyNoteTextBecomesBlocks() {
        let content = NoteContent(legacyRuns: [
            EaselRichTextRun(text: "Title", isBold: true, headingLevel: 2),
            EaselRichTextRun(text: "\nbody "),
            EaselRichTextRun(text: "bold\nnext", isBold: true),
        ])
        XCTAssertEqual(content.blocks.map(\.style), [.heading(2), .paragraph, .paragraph])
        XCTAssertEqual(content.blocks.map(\.text), ["Title", "body bold", "next"])
        XCTAssertEqual(content.blocks[1].runs, [NoteRun("body "), NoteRun("bold", bold: true)])
        var document = EaselDocumentOps.noteDocument()
        document.blocks[0].payload = .text(runs: [EaselRichTextRun(text: "old note")])
        XCTAssertEqual(document.noteContent.plainText, "old note", "an unsaved legacy note reads its text block")
        XCTAssertEqual(NoteContent(blocks: []).blocks.count, 1, "a note always has a line to type in")
    }

    func testTypingRules() {
        XCTAssertEqual(NoteEditing.styleAfterReturn(in: .bullet, blockIsEmpty: false).next, .bullet)
        XCTAssertEqual(NoteEditing.styleAfterReturn(in: .checklist(checked: true), blockIsEmpty: false).next, .checklist(checked: false))
        XCTAssertEqual(NoteEditing.styleAfterReturn(in: .heading(1), blockIsEmpty: false).next, .paragraph)
        XCTAssertEqual(NoteEditing.styleAfterReturn(in: .numbered, blockIsEmpty: true).current, .paragraph, "an empty item ends the list")
        XCTAssertEqual(NoteEditing.styleAfterDeleteAtStart(.quote), .paragraph)
        XCTAssertNil(NoteEditing.styleAfterDeleteAtStart(.paragraph))
        XCTAssertEqual(NoteEditing.shortcutStyle(forPrefix: "##"), .heading(2))
        XCTAssertEqual(NoteEditing.shortcutStyle(forPrefix: "[x]"), .checklist(checked: true))
        XCTAssertNil(NoteEditing.shortcutStyle(forPrefix: "####"))
        XCTAssertEqual(NoteEditing.linkURL(from: "arc.net/x"), URL(string: "https://arc.net/x"))
        XCTAssertEqual(NoteEditing.linkURL(from: "mailto:a@b.test"), URL(string: "mailto:a@b.test"))
        XCTAssertNil(NoteEditing.linkURL(from: "javascript:alert(1)"))
        XCTAssertNil(NoteEditing.linkURL(from: "file:///etc/passwd"))

        var note = sampleNote
        note.setStyle(.bullet, blocks: [2, 3])
        XCTAssertEqual(note.blocks[2].style, .bullet)
        note.setStyle(.bullet, blocks: [2, 3])
        XCTAssertEqual(note.blocks[3].style, .paragraph, "applying the style they all have turns it off")
        note.toggleChecklist(at: 5)
        XCTAssertEqual(note.blocks[5].style, .checklist(checked: true))
        note.toggleChecklist(at: 0)
        XCTAssertEqual(note.blocks[0].style, .heading(1), "only checklist rows check")
    }
}
