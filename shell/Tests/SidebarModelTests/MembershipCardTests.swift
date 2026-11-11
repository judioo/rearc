import XCTest
@testable import SidebarModel

/// Settings › Account's membership card (FEATURE-SPECS/SETTINGS.md §12):
/// ReArc's title lists, the stamps by date, the card file, the read of
/// Arc's card (and only two fields of its auth file), and the Arc-to-ReArc
/// transition's timing.
final class MembershipCardTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        utc.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    // MARK: Title

    func testTheListsAreReArcsOwnFortyByForty() {
        XCTAssertEqual(MembershipCardTitle.adjectives.count, 40)
        XCTAssertEqual(MembershipCardTitle.nouns.count, 40)
        XCTAssertEqual(Set(MembershipCardTitle.adjectives).count, 40, "no repeats")
        XCTAssertEqual(Set(MembershipCardTitle.nouns).count, 40, "no repeats")
        // The words SETTINGS.md §10.3 saw in Arc's binary aren't ReArc's.
        let arcWords: Set<String> = ["RARE", "MAJESTIC", "SLEEPY", "CURIOUS", "STATUESQUE",
                                     "HUNTER", "READER", "ROBOT", "ARCHITECT", "BIG SHOT"]
        XCTAssertTrue(arcWords.isDisjoint(with: MembershipCardTitle.adjectives + MembershipCardTitle.nouns))
        for word in MembershipCardTitle.adjectives + MembershipCardTitle.nouns {
            XCTAssertEqual(word, word.uppercased())
        }
        let longest = MembershipCardTitle.adjectives.map(\.count).max()! + 1 + MembershipCardTitle.nouns.map(\.count).max()!
        XCTAssertLessThanOrEqual(longest, 32, "every title fits the card's line")
    }

    func testATitleFromASeedIsAlwaysTheSame() {
        XCTAssertEqual(MembershipCardTitle.make(seed: 42), MembershipCardTitle.make(seed: 42))
        let title = MembershipCardTitle.make(seed: 7)
        let words = title.split(separator: " ", maxSplits: 1).map(String.init)
        XCTAssertEqual(words.count, 2)
        XCTAssertTrue(MembershipCardTitle.adjectives.contains(words[0]))
        XCTAssertTrue(MembershipCardTitle.nouns.contains(words[1]))
        let titles = Set((0..<1000).map { MembershipCardTitle.make(seed: UInt64($0)) })
        XCTAssertGreaterThan(titles.count, 500, "seeds spread over the 1,600 titles")
    }

    func testImportedTitlesAreOneShortLineOfCapitals() {
        XCTAssertEqual(MembershipCardTitle.sanitized("  statuesque\nhunter "), "STATUESQUE HUNTER")
        XCTAssertNil(MembershipCardTitle.sanitized("  \n "))
        XCTAssertEqual(MembershipCardTitle.sanitized(String(repeating: "A", count: 100))?.count, 32)
    }

    func testRandomizeDrawsANewTitleShapeAndPaletteAndKeepsTheRest() {
        var rng = SplitMix64(seed: 1)
        let start = date(2026, 11, 8)
        var card = MembershipCard.fresh(now: start, using: &rng)
        XCTAssertEqual(card.palette, 0, "a new card wears the theme")
        XCTAssertEqual(card.seed.count, MembershipCard.blobCount)
        card.name = "Ada"
        card.arcMemberSince = date(2024, 6, 1)
        let before = card
        for _ in 0..<20 {
            let previous = card
            card.randomize(using: &rng)
            XCTAssertNotEqual(card.title, previous.title)
            XCTAssertNotEqual(card.palette, previous.palette)
            XCTAssertTrue((1...MembershipCard.paletteCount).contains(card.palette))
            XCTAssertTrue((1...MembershipCard.shapeCount).contains(card.shape))
        }
        XCTAssertEqual(card.titleSource, .rearc)
        XCTAssertEqual(card.name, before.name)
        XCTAssertEqual(card.arcMemberSince, before.arcMemberSince)
        XCTAssertEqual(card.rearcMemberSince, before.rearcMemberSince)
    }

    func testTheNameIsOnboardingsThenArcsThenTheProfiles() {
        var card = MembershipCard.fresh(now: Date())
        XCTAssertEqual(card.displayName(profileName: "Personal"), "Personal")
        card.arcName = "Akilu"
        XCTAssertEqual(card.displayName(profileName: "Personal"), "Akilu")
        card.name = "Ada"
        XCTAssertEqual(card.displayName(profileName: "Personal"), "Ada")
        card.name = "  "
        XCTAssertEqual(card.displayName(profileName: "Personal"), "Akilu", "a blank name doesn't count")
    }

    // MARK: Stamps

    func testStampsAreFullArcYearsThenReArcsMilestones() {
        let arc = date(2024, 6, 1)
        let rearc = date(2026, 11, 8)
        let kinds = { (now: Date) in
            MembershipCardStamps.stamps(arcSince: arc, rearcSince: rearc, now: now, calendar: self.utc).map(\.kind)
        }
        XCTAssertEqual(kinds(rearc), [.arcYear(1), .arcYear(2), .rearcDayOne])
        XCTAssertEqual(kinds(date(2026, 12, 7)), [.arcYear(1), .arcYear(2), .rearcDayOne], "29 days")
        XCTAssertEqual(kinds(date(2026, 12, 8)), [.arcYear(1), .arcYear(2), .rearcDayOne, .rearcDays(30)])
        XCTAssertEqual(kinds(date(2027, 2, 16)), [.arcYear(1), .arcYear(2), .rearcDayOne, .rearcDays(30), .rearcDays(100)])
        XCTAssertEqual(kinds(date(2027, 11, 8)).suffix(2), [.rearcDays(100), .rearcYear(1)])
        XCTAssertEqual(kinds(date(2029, 11, 9)).filter { if case .rearcYear = $0 { return true } else { return false } },
                       [.rearcYear(1), .rearcYear(2), .rearcYear(3)])
        // Arc's years stop at the move: they don't keep counting with ReArc.
        XCTAssertEqual(kinds(date(2030, 1, 1)).filter { if case .arcYear = $0 { return true } else { return false } },
                       [.arcYear(1), .arcYear(2)])
    }

    func testWithoutArcTheCardHasOnlyReArcStamps() {
        let rearc = date(2026, 11, 8)
        let stamps = MembershipCardStamps.stamps(arcSince: nil, rearcSince: rearc, now: rearc, calendar: utc)
        XCTAssertEqual(stamps.map(\.kind), [.rearcDayOne])
        XCTAssertEqual(stamps.first?.ring, "REARC · DAY ONE")
        XCTAssertEqual(stamps.first?.accessibilityLabel, "Day one with ReArc")
        XCTAssertTrue(MembershipCardStamps.arcStamps(arcSince: date(2026, 1, 1), until: rearc, calendar: utc).isEmpty, "under a year")
    }

    func testStampTexts() {
        XCTAssertEqual(MembershipCardStamp(kind: .arcYear(1)).accessibilityLabel, "One year with Arc")
        XCTAssertEqual(MembershipCardStamp(kind: .arcYear(2)).accessibilityLabel, "2 years with Arc")
        XCTAssertEqual(MembershipCardStamp(kind: .arcYear(2)).ring, "ARC · ANNIVERSARY")
        XCTAssertEqual(MembershipCardStamp(kind: .rearcDays(100)).centre, "100")
        XCTAssertTrue(MembershipCardStamp(kind: .arcYear(3)).isArc)
        XCTAssertFalse(MembershipCardStamp(kind: .rearcYear(1)).isArc)
    }

    func testDayNumbersCountFromOne() {
        let start = date(2026, 11, 8, hour: 23)
        XCTAssertEqual(MembershipCardStamps.dayNumber(since: start, now: date(2026, 11, 8, hour: 23), calendar: utc), 1)
        XCTAssertEqual(MembershipCardStamps.dayNumber(since: start, now: date(2026, 11, 9, hour: 1), calendar: utc), 2,
                       "a new calendar day is a new day")
    }

    func testDatesPrintAsTheStripDoes() {
        let utcZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(MembershipCardDates.format(Date(timeIntervalSinceReferenceDate: 738_929_101.8), timeZone: utcZone), "1 Jun 2024")
        XCTAssertEqual(MembershipCardDates.span(from: date(2024, 6, 1), to: date(2026, 11, 8), calendar: utc), "2 yrs 5 mo")
        XCTAssertEqual(MembershipCardDates.span(from: date(2025, 11, 1), to: date(2026, 11, 8), calendar: utc), "1 yr")
        XCTAssertEqual(MembershipCardDates.span(from: date(2026, 10, 1), to: date(2026, 11, 8), calendar: utc), "1 mo")
    }

    // MARK: File

    func testTheCardFileRoundTripsAndOutOfRangeValuesComeBack() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("card-\(UUID().uuidString)/\(MembershipCard.fileName)")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var card = MembershipCard.fresh(now: date(2026, 11, 8))
        card.arcMemberSince = date(2024, 6, 1)
        try MembershipCardFile.save(card, to: url)
        XCTAssertEqual(MembershipCardFile.load(from: url), card)

        try Data(#"{"version":1,"title":"x","titleSource":"rearc","shape":9,"palette":44,"seed":[1],"rearcMemberSince":"2026-11-08T12:00:00Z","transitionShown":true}"#.utf8).write(to: url)
        let loaded = try XCTUnwrap(MembershipCardFile.load(from: url))
        XCTAssertEqual(loaded.shape, 1)
        XCTAssertEqual(loaded.palette, 0)
        XCTAssertEqual(loaded.seed.count, MembershipCard.blobCount)
        XCTAssertEqual(loaded.title, "X")
        XCTAssertNil(MembershipCardFile.load(from: url.appendingPathExtension("missing")))
    }

    // MARK: Import from Arc

    /// The shape of Arc's files (SETTINGS.md §10.3), with made-up values.
    private let arcCard = Data(#"""
    {"title": "STATUESQUE HUNTER", "paletteNumber": 6, "shapeName": "Shape2",
     "backgroundBlobInfo": [10, 7, 9, 14, 7, 3, 9, 7, 4, 1, 4, 12, 14, 9, 7], "version": 1}
    """#.utf8)

    private let secretEmail = "someone@example.invalid"
    private let secretToken = "eyJ-secret-access-token"
    private let secretID = "user-7f3a-secret-id"

    private var arcAuth: Data {
        Data("""
        {"session": {"accessToken": "\(secretToken)", "refreshToken": "\(secretToken)-refresh",
          "user": {"id": "\(secretID)", "email": "\(secretEmail)", "name": "Akilu",
                   "avatarURL": "https://example.invalid/\(secretID).png", "createdAt": 738929101.8}},
         "deviceID": "\(secretID)-device"}
        """.utf8)
    }

    func testArcsCardImportsOnlyNameAndMemberSinceFromAuth() throws {
        let imported = try XCTUnwrap(ArcMembershipCardImport.read(card: arcCard, auth: arcAuth))
        XCTAssertEqual(imported.title, "STATUESQUE HUNTER")
        XCTAssertEqual(imported.palette, 6)
        XCTAssertEqual(imported.shape, 2)
        XCTAssertEqual(imported.seed, [10, 7, 9, 14, 7, 3, 9, 7, 4, 1, 4, 12, 14, 9, 7])
        XCTAssertEqual(imported.name, "Akilu")
        XCTAssertEqual(imported.memberSince, Date(timeIntervalSinceReferenceDate: 738929101.8))
    }

    func testNothingElseFromTheAuthFileIsKeptOrStored() throws {
        let imported = try XCTUnwrap(ArcMembershipCardImport.read(card: arcCard, auth: arcAuth))
        // The import holds nothing but its six fields...
        let fields = Set(Mirror(reflecting: imported).children.compactMap(\.label))
        XCTAssertEqual(fields, ["title", "palette", "shape", "seed", "memberSince", "name"])
        let described = String(describing: imported) + String(reflecting: imported)
        for secret in [secretEmail, secretToken, secretID] {
            XCTAssertFalse(described.contains(secret), "\(secret) was kept")
        }
        // ...and the saved card carries none of the secrets either.
        let card = imported.applied(to: MembershipCard.fresh(now: date(2026, 11, 8)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("card-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try MembershipCardFile.save(card, to: url)
        let saved = try String(contentsOf: url, encoding: .utf8)
        for secret in [secretEmail, secretToken, secretID, "accessToken", "email", "avatarURL"] {
            XCTAssertFalse(saved.contains(secret), "the card file holds \(secret)")
        }
        XCTAssertTrue(saved.contains("STATUESQUE HUNTER"))
    }

    func testAnAuthFileAloneIsNeverOfferedOrImported() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let arc = ArcMembershipCardImport.folder(in: support)
        try FileManager.default.createDirectory(at: arc, withIntermediateDirectories: true)
        try arcAuth.write(to: arc.appendingPathComponent(ArcMembershipCardImport.authFileName))
        XCTAssertFalse(ArcMembershipCardImport.exists(in: support))
        XCTAssertNil(ArcMembershipCardImport.load(from: support))
        try arcCard.write(to: arc.appendingPathComponent(ArcMembershipCardImport.cardFileName))
        let imported = try XCTUnwrap(ArcMembershipCardImport.load(from: support))
        XCTAssertEqual(imported.memberSince, Date(timeIntervalSinceReferenceDate: 738929101.8))
        XCTAssertEqual(imported.name, "Akilu")
        XCTAssertEqual(imported.title, "STATUESQUE HUNTER")
    }

    func testArcsNumbersOutsideReArcsSetsAreDropped() {
        let card = Data(#"{"title": "X Y", "paletteNumber": 12, "shapeName": "Shape9", "backgroundBlobInfo": [500, -3]}"#.utf8)
        let imported = ArcMembershipCardImport.read(card: card)
        XCTAssertNil(imported?.palette)
        XCTAssertNil(imported?.shape)
        XCTAssertEqual(imported?.seed, [99, 0])
        XCTAssertNil(ArcMembershipCardImport.shapeNumber("Leaf"))
    }

    func testLoadsFromArcsFolderAndSkipsAnOversizedFile() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        XCTAssertFalse(ArcMembershipCardImport.exists(in: support))
        let arc = ArcMembershipCardImport.folder(in: support)
        try FileManager.default.createDirectory(at: arc, withIntermediateDirectories: true)
        try arcCard.write(to: arc.appendingPathComponent(ArcMembershipCardImport.cardFileName))
        XCTAssertTrue(ArcMembershipCardImport.exists(in: support))
        try Data(count: ArcMembershipCardImport.maximumFileSize + 1).write(to: arc.appendingPathComponent(ArcMembershipCardImport.authFileName))
        let imported = try XCTUnwrap(ArcMembershipCardImport.load(from: support))
        XCTAssertEqual(imported.title, "STATUESQUE HUNTER")
        XCTAssertNil(imported.memberSince, "the oversized auth file isn't read")
    }

    func testApplyingTheImportSetsUpTheTransition() throws {
        let fresh = MembershipCard.fresh(now: date(2026, 11, 8))
        let imported = try XCTUnwrap(ArcMembershipCardImport.read(card: arcCard, auth: arcAuth))
        let card = imported.applied(to: fresh)
        XCTAssertEqual(card.title, "STATUESQUE HUNTER")
        XCTAssertEqual(card.titleSource, .arc)
        XCTAssertEqual(card.shape, 2)
        XCTAssertEqual(card.arcPalette, 6, "the Arc-era card's colours")
        XCTAssertEqual(card.palette, 0, "after the transition, the theme's")
        XCTAssertEqual(card.arcName, "Akilu")
        XCTAssertEqual(card.rearcMemberSince, fresh.rearcMemberSince, "ReArc's date is set once")
        XCTAssertTrue(card.hasArcHistory)
        XCTAssertFalse(card.transitionShown)
        // A card file without a member-since date has no story to tell.
        let titleOnly = ArcMembershipCardImport(title: "A B").applied(to: fresh)
        XCTAssertTrue(titleOnly.transitionShown)
    }

    func testReimportRestoresRandomizedDesignAndUpgradesHistoryWithoutDuplicates() throws {
        let imported = try XCTUnwrap(ArcMembershipCardImport.read(card: arcCard, auth: arcAuth))
        let designOnly = try XCTUnwrap(ArcMembershipCardImport.read(card: arcCard))
        let fresh = MembershipCard.fresh(now: date(2026, 11, 8))
        var card = designOnly.applied(to: fresh)
        XCTAssertFalse(imported.isApplied(to: card), "builds 544/564 can recover history")
        card = imported.applied(to: card)
        XCTAssertTrue(imported.isApplied(to: card))
        XCTAssertTrue(card.hasArcHistory)
        XCTAssertEqual(imported.applied(to: card), card, "import is idempotent")
        card.randomize()
        XCTAssertFalse(imported.isApplied(to: card))
        card = imported.applied(to: card)
        XCTAssertEqual(card, imported.applied(to: fresh))
        XCTAssertEqual(card.seed.count, MembershipCard.blobCount)
    }

    func testMissingOrMalformedAuthStillImportsDesign() throws {
        for auth in [Data? .none, Data("not JSON".utf8), Data(#"{"session":{"user":{"createdAt":"bad"}}}"#.utf8)] {
            let imported = try XCTUnwrap(ArcMembershipCardImport.read(card: arcCard, auth: auth))
            XCTAssertNil(imported.memberSince)
            XCTAssertNil(imported.name)
            XCTAssertEqual(imported.title, "STATUESQUE HUNTER")
        }
        XCTAssertNil(ArcMembershipCardImport.read(card: nil, auth: arcAuth))
        // One bad field leaves the other; a non-positive date is no date.
        let badDate = Data(#"{"session":{"user":{"createdAt":"bad","name":"  Akilu  "}}}"#.utf8)
        XCTAssertEqual(ArcMembershipCardImport.read(card: arcCard, auth: badDate)?.name, "Akilu")
        let zero = Data(#"{"session":{"user":{"createdAt":0,"name":7}}}"#.utf8)
        XCTAssertNil(ArcMembershipCardImport.read(card: arcCard, auth: zero)?.memberSince)
        XCTAssertNil(ArcMembershipCardImport.read(card: arcCard, auth: zero)?.name)
    }

    func testAnUntitledArcCardStillImportsItsDesignAndHistory() throws {
        let untitled = Data(#"{"paletteNumber": 3, "shapeName": "Shape1"}"#.utf8)
        let imported = try XCTUnwrap(ArcMembershipCardImport.read(card: untitled, auth: arcAuth))
        XCTAssertNil(imported.title)
        XCTAssertEqual(imported.palette, 3)
        XCTAssertEqual(imported.name, "Akilu")
        XCTAssertNotNil(imported.memberSince)
        XCTAssertNil(ArcMembershipCardImport.read(card: Data("{}".utf8), auth: arcAuth), "an empty card is no card")
    }

    // MARK: Palettes and blobs

    func testPalettesRunLightToDeep() {
        XCTAssertEqual(MembershipCardPalette.fixed.count, MembershipCard.paletteCount)
        let themed = MembershipCardPalette.themed(SpaceColor(red: 0.45, green: 0.35, blue: 0.9))
        for palette in MembershipCardPalette.fixed + [themed] {
            XCTAssertEqual(palette.colours.count, 5, palette.name)
            let lightness = palette.colours.map { OKLab($0).l }
            XCTAssertEqual(lightness, lightness.sorted(by: >), "\(palette.name) runs light to deep")
            for colour in palette.colours + [palette.ink] {
                for c in [colour.red, colour.green, colour.blue] { XCTAssertTrue((-0.001...1.001).contains(c), palette.name) }
            }
            XCTAssertLessThan(OKLab(palette.ink).l, 0.6, "\(palette.name)'s ink reads on cream")
        }
        XCTAssertEqual(MembershipCardPalette.palette(3, theme: SpaceColor(red: 1, green: 0, blue: 0)), MembershipCardPalette.fixed[2])
        XCTAssertEqual(MembershipCardPalette.palette(0, theme: SpaceColor(red: 1, green: 0, blue: 0)).name, "Theme")
    }

    func testBlobsFollowTheirSeed() {
        let seed = [10, 7, 9, 14, 7, 3, 9, 7, 4, 1, 4, 12, 14, 9, 7]
        let blobs = MembershipCardBlob.layout(seed: seed, colours: 5)
        XCTAssertEqual(blobs, MembershipCardBlob.layout(seed: seed, colours: 5))
        XCTAssertEqual(blobs.count, 15)
        XCTAssertNotEqual(blobs, MembershipCardBlob.layout(seed: seed.reversed(), colours: 5))
        for blob in blobs {
            XCTAssertTrue((0..<5).contains(blob.colour))
            XCTAssertTrue((20...40).contains(blob.period), "a slow drift")
            let a = blob.centre(at: 0), b = blob.centre(at: blob.period)
            XCTAssertEqual(a.x, b.x, accuracy: 1e-9, "one full cycle per period")
        }
    }

    // MARK: Transition

    func testTheTransitionsKeyframes() {
        let at = { (t: Double) in MembershipCardTransition.frame(at: t, reduceMotion: false) }
        // 0–0.6 s: the Arc card as Arc showed it.
        XCTAssertEqual(at(0).dateText, 0)
        XCTAssertEqual(at(0.5).label, 0)
        XCTAssertNil(at(0.5).stampScale)
        XCTAssertEqual(at(0.5).retint, 0)
        // 0.6–1.4 s: the date cell flips to Arc's span, then ReArc's date.
        XCTAssertEqual(at(0.6 + 0.12).flipAngle, 90, accuracy: 0.5, "edge-on halfway")
        XCTAssertEqual(at(0.9).dateText, 1)
        XCTAssertEqual(at(0.9).flipAngle, 0)
        XCTAssertEqual(at(1.3).dateText, 2)
        XCTAssertEqual(at(1.4).label, 1)
        // 1.4–2.0 s: the stamp drops from 1.4×, overshoots to 0.96× on contact, settles at 1.
        XCTAssertEqual(at(1.4).stampScale ?? 0, 1.4, accuracy: 0.001)
        XCTAssertEqual(at(MembershipCardTransition.stampContact).stampScale ?? 0, 0.96, accuracy: 0.001)
        XCTAssertEqual(at(1.99).stampScale ?? 0, 1, accuracy: 0.01)
        XCTAssertLessThan(at(1.99).stampShadow, at(1.5).stampShadow, "the shadow tightens")
        // 2.0–3.2 s: the re-tint.
        XCTAssertEqual(at(2.0).retint, 0)
        XCTAssertEqual(at(2.6).retint, 0.5, accuracy: 0.01)
        XCTAssertFalse(at(3.1).isFinished)
        XCTAssertEqual(at(3.2), MembershipCardTransition.rest)
        XCTAssertTrue(at(10).isFinished)
    }

    func testEachBlobRetintsWithItsOwnDelay() {
        let count = MembershipCard.blobCount
        let starts = (0..<count).map { index in
            stride(from: 2.0, through: 3.2, by: 0.01).first { MembershipCardTransition.blobRetint(index, at: $0) > 0 } ?? 9
        }
        XCTAssertEqual(starts.min() ?? 0, 2.0, accuracy: 0.011)
        XCTAssertLessThanOrEqual(starts.max() ?? 9, 2.0 + MembershipCardTransition.maxBlobDelay + 0.011)
        XCTAssertGreaterThan(Set(starts.map { Int($0 * 100) }).count, 3, "not all at once")
        for index in 0..<count {
            XCTAssertEqual(MembershipCardTransition.blobRetint(index, at: 1.9), 0)
            XCTAssertEqual(MembershipCardTransition.blobRetint(index, at: 3.2), 1)
        }
    }

    func testReduceMotionIsOneShortCrossFade() {
        let at = { (t: Double) in MembershipCardTransition.frame(at: t, reduceMotion: true) }
        XCTAssertEqual(at(0).crossfade, 0)
        XCTAssertEqual(at(0.15).crossfade ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(at(0.15).stampScale, "no drop: the stamp comes with the fade")
        XCTAssertEqual(at(MembershipCardTransition.reducedDuration), MembershipCardTransition.rest)
        XCTAssertEqual(MembershipCardTransition.blobRetint(3, at: 0.15, reduceMotion: true), 0.5, accuracy: 0.001)
    }
}
