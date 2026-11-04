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
}
