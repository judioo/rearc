import Foundation

/// Settings › Account's membership card (FEATURE-SPECS/SETTINGS.md §12):
/// ReArc's own take on Arc's card. A name, a two-word title, a shape and a
/// palette for the gradient, the blobs' seed, and the dates the stamps come
/// from. Saved as `membership-card.json` next to the sidebar, never synced.
public struct MembershipCard: Codable, Equatable, Sendable {
    public static let fileName = "membership-card.json"
    public static let currentVersion = 1
    /// ReArc's shapes and palettes (`palette` 0 follows the profile's theme).
    public static let shapeCount = 4
    public static let paletteCount = 8
    public static let blobCount = 15

    public enum TitleSource: String, Codable, Sendable {
        case rearc, arc
    }

    public var version = Self.currentVersion
    /// Act 1's name, or one set with Change Name…; nil shows Arc's or the profile's.
    public var name: String?
    /// Arc's display name, from the import.
    public var arcName: String?
    public var title: String
    public var titleSource: TitleSource
    /// 1…`shapeCount`.
    public var shape: Int
    /// 0: the profile's theme colour; 1…`paletteCount`: one of ReArc's palettes.
    public var palette: Int
    /// The palette the imported Arc card mapped to; the transition starts from it.
    public var arcPalette: Int?
    /// One small number per blob: its colour, place and phase.
    public var seed: [Int]
    /// Arc's member-since date (`session.user.createdAt`), when imported.
    public var arcMemberSince: Date?
    /// The first launch, or the first after this card existed (existing
    /// installs start on the day they update). Set once.
    public var rearcMemberSince: Date
    /// The Arc-to-ReArc transition played (or Reduce Motion's cross-fade).
    public var transitionShown: Bool

    public init(name: String? = nil, arcName: String? = nil, title: String, titleSource: TitleSource = .rearc,
                shape: Int, palette: Int = 0, arcPalette: Int? = nil, seed: [Int],
                arcMemberSince: Date? = nil, rearcMemberSince: Date, transitionShown: Bool = true) {
        self.name = name
        self.arcName = arcName
        self.title = title
        self.titleSource = titleSource
        self.shape = shape
        self.palette = palette
        self.arcPalette = arcPalette
        self.seed = seed
        self.arcMemberSince = arcMemberSince
        self.rearcMemberSince = rearcMemberSince
        self.transitionShown = transitionShown
    }

    /// A new plain ReArc card: a drawn title, shape and blobs, in the theme's colours.
    public static func fresh<G: RandomNumberGenerator>(now: Date, using rng: inout G) -> MembershipCard {
        MembershipCard(title: MembershipCardTitle.random(using: &rng), shape: Int.random(in: 1...shapeCount, using: &rng),
                       seed: randomSeed(using: &rng), rearcMemberSince: wholeSeconds(now))
    }

    /// The file keeps dates to the second; so does the card in memory.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.rounded(.down))
    }

    public static func fresh(now: Date = Date()) -> MembershipCard {
        var rng = SystemRandomNumberGenerator()
        return fresh(now: now, using: &rng)
    }

    static func randomSeed<G: RandomNumberGenerator>(using rng: inout G) -> [Int] {
        (0..<blobCount).map { _ in Int.random(in: 1...14, using: &rng) }
    }

    /// Randomize: a new title, shape, palette and blobs. The name, dates and
    /// stamps stay. The palette is always one of ReArc's eight, never the one shown.
    public mutating func randomize<G: RandomNumberGenerator>(using rng: inout G) {
        var newTitle = MembershipCardTitle.random(using: &rng)
        while newTitle == title { newTitle = MembershipCardTitle.random(using: &rng) }
        title = newTitle
        titleSource = .rearc
        shape = Int.random(in: 1...Self.shapeCount, using: &rng)
        var newPalette = Int.random(in: 1...Self.paletteCount, using: &rng)
        while newPalette == palette { newPalette = Int.random(in: 1...Self.paletteCount, using: &rng) }
        palette = newPalette
        seed = Self.randomSeed(using: &rng)
    }

    public mutating func randomize() {
        var rng = SystemRandomNumberGenerator()
        randomize(using: &rng)
    }

    /// The card's name: Act 1's (or Change Name…'s), else Arc's, else the profile's.
    public func displayName(profileName: String) -> String {
        for candidate in [name, arcName] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespaces).isEmpty { return candidate }
        }
        return profileName
    }

    /// An Arc card was imported: the card tells the Arc-to-ReArc story.
    public var hasArcHistory: Bool { arcMemberSince != nil }

    /// Values from an older or hand-edited file, back in range.
    public var normalized: MembershipCard {
        var card = self
        card.shape = (1...Self.shapeCount).contains(shape) ? shape : 1
        card.palette = (0...Self.paletteCount).contains(palette) ? palette : 0
        card.arcPalette = arcPalette.flatMap { (1...Self.paletteCount).contains($0) ? $0 : nil }
        card.seed = (0..<Self.blobCount).map { seed.indices.contains($0) ? max(0, min(seed[$0], 99)) : $0 + 1 }
        card.title = MembershipCardTitle.sanitized(title) ?? "STEADY NAVIGATOR"
        return card
    }
}

// MARK: File

public enum MembershipCardFile {
    public static func load(from url: URL) -> MembershipCard? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(MembershipCard.self, from: data).normalized
    }

    public static func save(_ card: MembershipCard, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(card).write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: Title

/// Two words from ReArc's own lists (40 × 40 = 1,600 titles), upbeat, with
/// a lean to the sea and the sky to match the sunrise-and-horizon mark.
/// Written for ReArc; Arc's lists are not used.
public enum MembershipCardTitle {
    public static let adjectives = [
        "STEADY", "BRIGHT", "NIMBLE", "BOLD", "SUNLIT", "BRISK", "WINDSWEPT", "VALIANT",
        "MERRY", "GOLDEN", "DAWNLIT", "KEEN", "LIVELY", "PLUCKY", "RADIANT", "SALTY",
        "SEAWORTHY", "STARBOUND", "TIDAL", "UNHURRIED", "BUOYANT", "GALLANT", "HARDY", "JOVIAL",
        "LUCKY", "NORTHERLY", "PATIENT", "SPIRITED", "SUNNY", "TIRELESS", "WAYFARING", "ZESTY",
        "CHEERFUL", "DAUNTLESS", "GLEAMING", "HOPEFUL", "FAR-SIGHTED", "SURE-FOOTED", "BREEZY", "STALWART",
    ]

    public static let nouns = [
        "NAVIGATOR", "LOOKOUT", "CARTOGRAPHER", "SKIPPER", "PILOT", "STARGAZER", "VOYAGER", "WAYFINDER",
        "DECKHAND", "LIGHTKEEPER", "HARBOURMASTER", "SURVEYOR", "PATHFINDER", "BEACHCOMBER", "TIDEWATCHER", "SAILMAKER",
        "QUARTERMASTER", "TRAILBLAZER", "BEACON", "LANTERN", "ALBATROSS", "OTTER", "PUFFIN", "HERON",
        "DOLPHIN", "KESTREL", "ANCHOR", "KITE", "SEXTANT", "CAPTAIN", "BOSUN", "COXSWAIN",
        "MAPMAKER", "SUNCHASER", "MARINER", "COMPASS", "WATCHKEEPER", "SHIPWRIGHT", "DAYSAILER", "SEAFARER",
    ]

    /// The same seed gives the same title.
    public static func make(seed: UInt64) -> String {
        var rng = SplitMix64(seed: seed)
        return random(using: &rng)
    }

    public static func random<G: RandomNumberGenerator>(using rng: inout G) -> String {
        "\(adjectives[Int.random(in: 0..<adjectives.count, using: &rng)]) \(nouns[Int.random(in: 0..<nouns.count, using: &rng)])"
    }

    /// An imported title as the card prints it: one line, capitals, at most 32 characters.
    public static func sanitized(_ raw: String) -> String? {
        let line = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces).uppercased()
        guard !line.isEmpty else { return nil }
        return String(line.prefix(32))
    }
}

// MARK: Stamps

/// One rubber stamp on the card: a number in a ring of text.
public struct MembershipCardStamp: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// A full year with Arc, counted up to the move to ReArc.
        case arcYear(Int)
        case rearcDayOne
        /// 30 and 100 days with ReArc.
        case rearcDays(Int)
        case rearcYear(Int)
    }

    public var kind: Kind

    public var isArc: Bool {
        if case .arcYear = kind { return true }
        return false
    }

    /// The number in the middle.
    public var centre: String {
        switch kind {
        case .arcYear(let n), .rearcYear(let n), .rearcDays(let n): return "\(n)"
        case .rearcDayOne: return "1"
        }
    }

    /// The text round the ring.
    public var ring: String {
        switch kind {
        case .arcYear: return "ARC · ANNIVERSARY"
        case .rearcDayOne: return "REARC · DAY ONE"
        case .rearcDays: return "REARC · DAYS"
        case .rearcYear: return "REARC · ANNIVERSARY"
        }
    }

    public var accessibilityLabel: String {
        switch kind {
        case .arcYear(1): return "One year with Arc"
        case .arcYear(let n): return "\(n) years with Arc"
        case .rearcDayOne: return "Day one with ReArc"
        case .rearcDays(let n): return "\(n) days with ReArc"
        case .rearcYear(1): return "One year with ReArc"
        case .rearcYear(let n): return "\(n) years with ReArc"
        }
    }
}

public enum MembershipCardStamps {
    /// ReArc's milestones in days (years are counted on their own).
    public static let dayMilestones = [30, 100]

    /// Oldest first: a stamp per full year with Arc (from Arc's date to the
    /// first day with ReArc), then ReArc's day one, 30 days, 100 days and
    /// each full year since.
    public static func stamps(arcSince: Date?, rearcSince: Date?, now: Date,
                              calendar: Calendar = .current) -> [MembershipCardStamp] {
        var stamps = arcStamps(arcSince: arcSince, until: rearcSince ?? now, calendar: calendar)
        guard let rearcSince else { return stamps }
        stamps.append(MembershipCardStamp(kind: .rearcDayOne))
        let days = daysBetween(rearcSince, now, calendar: calendar)
        for milestone in dayMilestones where days >= milestone {
            stamps.append(MembershipCardStamp(kind: .rearcDays(milestone)))
        }
        let years = calendar.dateComponents([.year], from: rearcSince, to: now).year ?? 0
        if years >= 1 { stamps += (1...years).map { MembershipCardStamp(kind: .rearcYear($0)) } }
        return stamps
    }

    /// The Arc-era card's stamps: one per full year with Arc.
    public static func arcStamps(arcSince: Date?, until end: Date, calendar: Calendar = .current) -> [MembershipCardStamp] {
        guard let arcSince else { return [] }
        let years = calendar.dateComponents([.year], from: arcSince, to: end).year ?? 0
        return years >= 1 ? (1...years).map { MembershipCardStamp(kind: .arcYear($0)) } : []
    }

    /// Day 1 is the first day with ReArc.
    public static func dayNumber(since start: Date, now: Date, calendar: Calendar = .current) -> Int {
        daysBetween(start, now, calendar: calendar) + 1
    }

    static func daysBetween(_ start: Date, _ end: Date, calendar: Calendar) -> Int {
        max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0)
    }
}

// MARK: Dates

public enum MembershipCardDates {
    /// "1 Jun 2024", as the card's date strip prints it, whatever the locale.
    public static func format(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// "2 yrs 5 mo": the time with Arc, shown as the strip rolls over.
    public static func span(from start: Date, to end: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: start, to: end)
        let years = max(0, parts.year ?? 0), months = max(0, parts.month ?? 0)
        var out: [String] = []
        if years > 0 { out.append(years == 1 ? "1 yr" : "\(years) yrs") }
        if months > 0 || years == 0 { out.append("\(months) mo") }
        return out.joined(separator: " ")
    }
}

// MARK: Blobs

/// Where each blob of the gradient sits and drifts: a slow orbit round a
/// home point, one cycle in 20–40 s. Positions are unit coordinates in the
/// shape's box.
public struct MembershipCardBlob: Equatable, Sendable {
    /// Index into the palette's colours.
    public var colour: Int
    public var home: (x: Double, y: Double)
    /// Diameter as a fraction of the box's width.
    public var size: Double
    public var period: Double
    public var phase: Double
    public var reach: Double

    public static func == (a: Self, b: Self) -> Bool {
        a.colour == b.colour && a.home == b.home && a.size == b.size && a.period == b.period
            && a.phase == b.phase && a.reach == b.reach
    }

    /// The blob's centre at `time` seconds.
    public func centre(at time: Double) -> (x: Double, y: Double) {
        let angle = phase + 2 * .pi * time / period
        return (home.x + reach * cos(angle), home.y + reach * 0.8 * sin(angle * 1.3))
    }

    /// One blob per seed number, the same for the same seed.
    public static func layout(seed: [Int], colours: Int) -> [MembershipCardBlob] {
        seed.enumerated().map { index, value in
            var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: value &* 7919 &+ index &* 104_729))
            return MembershipCardBlob(
                colour: (value + index) % max(colours, 1),
                home: (Double.random(in: 0.05...0.95, using: &rng), Double.random(in: 0.05...0.95, using: &rng)),
                size: Double.random(in: 0.45...0.9, using: &rng),
                period: Double.random(in: 20...40, using: &rng),
                phase: Double.random(in: 0..<(2 * .pi), using: &rng),
                reach: Double.random(in: 0.06...0.18, using: &rng)
            )
        }
    }
}

// MARK: Transition

/// The one-time Arc-to-ReArc transition (SETTINGS.md §12.2), as frames of
/// a timeline: the Arc card (0–0.6 s), the date strip rolls (0.6–1.4 s),
/// a ReArc stamp is pressed on (1.4–2.0 s), the gradient re-tints to the
/// profile's theme (2.0–3.2 s), then the card rests. Under Reduce Motion a
/// 0.3 s cross-fade from the Arc card to the ReArc card instead.
public enum MembershipCardTransition {
    public static let duration: Double = 3.2
    public static let reducedDuration: Double = 0.3

    /// Each flip of the date cell: half to edge-on, the text changes, half back.
    public static let flipDuration: Double = 0.24
    /// The cell's texts: Arc's date, the time with Arc, ReArc's date.
    public static let flipStarts: [Double] = [0.6, 0.98]
    public static let labelFade: ClosedRange<Double> = 1.0...1.4
    public static let stampDrop: ClosedRange<Double> = 1.4...2.0
    /// The stamp meets the card: the haptic's moment.
    public static let stampContact: Double = 1.7
    public static let retint: ClosedRange<Double> = 2.0...3.2
    /// Each blob starts its re-tint up to this much later than the first.
    public static let maxBlobDelay: Double = 0.3

    public struct Frame: Equatable, Sendable {
        /// 0 Arc's date, 1 the time with Arc, 2 ReArc's date.
        public var dateText = 0
        /// The date cell's turn about its X axis, 0 (flat) to 90 (edge-on).
        public var flipAngle: Double = 0
        /// The strip's label, "ARC" (0) to "REARC" (1); "ARC SINCE" comes in with it.
        public var label: Double = 0
        /// The new stamp: nil before it drops.
        public var stampScale: Double?
        public var stampOpacity: Double = 0
        /// Its shadow, tightening on contact.
        public var stampShadow: Double = 4
        /// The gradient's move from the Arc palette (0) to the theme's (1).
        public var retint: Double = 0
        /// Reduce Motion: the ReArc card's opacity over the Arc card's.
        public var crossfade: Double?
        public var isFinished = false
    }

    public static func frame(at t: Double, reduceMotion: Bool) -> Frame {
        var frame = Frame()
        if reduceMotion {
            let p = clamp(t / reducedDuration)
            frame.crossfade = p
            frame.isFinished = t >= reducedDuration
            if frame.isFinished { frame = rest }
            return frame
        }
        guard t < duration else { return rest }
        for (index, start) in flipStarts.enumerated() where t >= start {
            let p = clamp((t - start) / flipDuration)
            frame.dateText = p < 0.5 ? index : index + 1
            frame.flipAngle = p < 1 ? 90 * (p < 0.5 ? p * 2 : (1 - p) * 2) : 0
        }
        frame.label = easeInOut(progress(t, in: labelFade))
        if t >= stampDrop.lowerBound {
            let fall = stampContact - stampDrop.lowerBound
            if t < stampContact {
                let p = easeIn((t - stampDrop.lowerBound) / fall)
                frame.stampScale = 1.4 - (1.4 - 0.96) * p
                frame.stampOpacity = clamp((t - stampDrop.lowerBound) / 0.1)
                frame.stampShadow = 4
            } else {
                let p = easeOut(progress(t, in: stampContact...stampDrop.upperBound))
                frame.stampScale = 0.96 + 0.04 * p
                frame.stampOpacity = 1
                frame.stampShadow = 4 - 3 * p
            }
        }
        frame.retint = easeInOut(progress(t, in: retint))
        return frame
    }

    /// The resting card.
    public static let rest = Frame(dateText: 2, flipAngle: 0, label: 1, stampScale: 1, stampOpacity: 1,
                                   stampShadow: 1, retint: 1, crossfade: nil, isFinished: true)

    /// Blob `index`'s own re-tint: it starts up to `maxBlobDelay` late and
    /// finishes by the end of the re-tint, eased in and out.
    public static func blobRetint(_ index: Int, at t: Double, reduceMotion: Bool = false) -> Double {
        if reduceMotion { return frame(at: t, reduceMotion: true).crossfade ?? 1 }
        let delay = maxBlobDelay * Double((index * 37) % 11) / 10
        let start = retint.lowerBound + delay
        return easeInOut(progress(t, in: start...retint.upperBound))
    }

    static func progress(_ t: Double, in range: ClosedRange<Double>) -> Double {
        clamp((t - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func easeIn(_ x: Double) -> Double { let x = clamp(x); return x * x }
    static func easeOut(_ x: Double) -> Double { let x = clamp(x); return 1 - (1 - x) * (1 - x) }
    static func easeInOut(_ x: Double) -> Double { let x = clamp(x); return x * x * (3 - 2 * x) }
}

// MARK: Palettes

/// ReArc's eight card palettes, drawn from the brand's sunrise and horizon
/// and the theme presets, plus palette 0, built from the profile's theme
/// colour. Each runs light to deep; `ink` is the name and title colour.
public struct MembershipCardPalette: Equatable, Sendable {
    public var name: String
    public var colours: [SpaceColor]
    public var ink: SpaceColor

    private static func hex(_ value: UInt32) -> SpaceColor {
        SpaceColor(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                   blue: Double(value & 0xFF) / 255)
    }

    private init(_ name: String, _ colours: [UInt32], ink: UInt32) {
        self.name = name
        self.colours = colours.map(Self.hex)
        self.ink = Self.hex(ink)
    }

    public init(name: String, colours: [SpaceColor], ink: SpaceColor) {
        self.name = name
        self.colours = colours
        self.ink = ink
    }

    /// Palettes 1…8.
    public static let fixed: [MembershipCardPalette] = [
        MembershipCardPalette("Sunrise", [0xFFD9A8, 0xFFA66B, 0xFF7A4D, 0xF25C3B, 0xD9415A], ink: 0xC2331F),
        MembershipCardPalette("Horizon", [0xC9D4FF, 0x8FA3FF, 0x5A6EFF, 0x2F43E0, 0x1B1F9C], ink: 0x2233C8),
        MembershipCardPalette("Lagoon", [0xC8F2EC, 0x7FDCCF, 0x3BB8B0, 0x1C8C99, 0x146A80], ink: 0x0F6170),
        MembershipCardPalette("Dusk", [0xF6C8E4, 0xD79BE8, 0xA675E0, 0x7652C9, 0x4B3699], ink: 0x5B2DA8),
        MembershipCardPalette("Meadow", [0xE6F5B8, 0xB9E27E, 0x86C95A, 0x4FA24A, 0x2E7A45], ink: 0x2D6B33),
        MembershipCardPalette("Ember", [0xFFE2B0, 0xFFC061, 0xF7943A, 0xE0662A, 0xA8401F], ink: 0xA8361A),
        MembershipCardPalette("Glacier", [0xEAF4FF, 0xBFDDF7, 0x92C2EE, 0x9CA6E8, 0x6E7FCF], ink: 0x3A5AA8),
        MembershipCardPalette("Coral Reef", [0xFFD6CC, 0xFF9E94, 0x48C1C4, 0xF2708A, 0x2B8FA6], ink: 0xB7334F),
    ]

    /// Palette `number` (0 the theme's).
    public static func palette(_ number: Int, theme: SpaceColor) -> MembershipCardPalette {
        (1...fixed.count).contains(number) ? fixed[number - 1] : themed(theme)
    }

    /// Five stops at the theme's hue, light to deep, chroma fitted to sRGB,
    /// and an ink deep enough to read on cream.
    public static func themed(_ theme: SpaceColor) -> MembershipCardPalette {
        let base = OKLab(theme).lch
        // A grey theme still makes a lively card.
        let hue = base.h, chroma = max(base.c, 0.11)
        func stop(_ l: Double, _ c: Double, _ dh: Double = 0) -> SpaceColor {
            OKLCH(l: l, c: c, h: (hue + dh + 360).truncatingRemainder(dividingBy: 360)).gamutMapped(to: .sRGB).lab.linear.encoded
        }
        return MembershipCardPalette(
            name: "Theme",
            colours: [stop(0.92, chroma * 0.35, -12), stop(0.82, chroma * 0.7, -6), stop(0.7, chroma),
                      stop(0.58, chroma * 1.05, 6), stop(0.46, chroma * 0.9, 12)],
            ink: stop(0.45, chroma * 0.95)
        )
    }

    /// A colour between two palettes' stops, mixed in OKLab (the re-tint).
    public static func mix(_ a: SpaceColor, _ b: SpaceColor, _ t: Double) -> SpaceColor {
        OKLab(a).mixed(with: OKLab(b), fraction: min(max(t, 0), 1)).linear.encoded
    }
}

// MARK: Import from Arc

/// Imports Arc's card design and only `session.user.createdAt` (Apple reference
/// date seconds) and `session.user.name` from StorableAuthState.json, to retain
/// the member's history and card name. Current Arc stores no tokens there;
/// the decoder stays field-limited in case that changes (F-21). Both files
/// are capped at 1 MB; no other auth fields are retained, logged or written.
/// Arc's files are never written.
public struct ArcMembershipCardImport: Equatable, Sendable {
    public static let cardFileName = "StorableMembershipCard.json"
    public static let authFileName = "StorableAuthState.json"
    /// The card is small; a bigger file is not read.
    static let maximumFileSize = 1 << 20

    public var title: String?
    /// Arc's 1…8, mapped to ReArc's palette of the same number.
    public var palette: Int?
    /// Arc's `Shape1`…`Shape4`, mapped to ReArc's shape of the same number.
    public var shape: Int?
    /// Arc's blob numbers, kept only as the blobs' seed.
    public var seed: [Int] = []
    public var memberSince: Date?
    public var name: String?

    public init(title: String? = nil, palette: Int? = nil, shape: Int? = nil, seed: [Int] = [],
                memberSince: Date? = nil, name: String? = nil) {
        self.title = title
        self.palette = palette
        self.shape = shape
        self.seed = seed
        self.memberSince = memberSince
        self.name = name
    }

    public var isEmpty: Bool { !hasDesign && memberSince == nil && name == nil }

    /// Whether Arc's card file gave anything: an auth file alone is no card.
    var hasDesign: Bool { title != nil || palette != nil || shape != nil || !seed.isEmpty }

    /// Arc's folder in Application Support.
    public static func folder(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Arc", isDirectory: true)
    }

    /// Whether there is an Arc card to import (the files exist; nothing is read).
    public static func exists(in applicationSupport: URL, fileManager: FileManager = .default) -> Bool {
        let folder = folder(in: applicationSupport)
        return fileManager.isReadableFile(atPath: folder.appendingPathComponent(cardFileName).path)
    }

    public static func load(from applicationSupport: URL) -> ArcMembershipCardImport? {
        let folder = folder(in: applicationSupport)
        guard let card = smallFile(folder.appendingPathComponent(cardFileName)), read(card: card) != nil else { return nil }
        return read(card: card, auth: smallFile(folder.appendingPathComponent(authFileName)))
    }

    /// Never through a link, and only up to `maximumFileSize` (RC-0.1.0-602 T-08).
    static func smallFile(_ url: URL) -> Data? {
        try? ImportFile.data(url, maxBytes: maximumFileSize)
    }

    /// Nil when the card gives nothing.
    public static func read(card: Data?, auth: Data? = nil) -> ArcMembershipCardImport? {
        var result = ArcMembershipCardImport()
        if let card, let state = try? JSONDecoder().decode(CardState.self, from: card) {
            result.title = state.title.flatMap(MembershipCardTitle.sanitized)
            result.palette = state.paletteNumber.flatMap { (1...MembershipCard.paletteCount).contains($0) ? $0 : nil }
            result.shape = state.shapeName.flatMap(shapeNumber)
            result.seed = Array((state.backgroundBlobInfo ?? []).prefix(MembershipCard.blobCount)).map { max(0, min($0, 99)) }
        }
        guard result.hasDesign else { return nil }
        if let auth, auth.count <= maximumFileSize,
           let user = (try? JSONDecoder().decode(AuthState.self, from: auth))?.session?.user {
            result.memberSince = user.createdAt.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSinceReferenceDate: $0) : nil }
            result.name = user.name.flatMap { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : String(trimmed.prefix(40))
            }
        }
        return result
    }

    /// "Shape2" → 2.
    static func shapeNumber(_ name: String) -> Int? {
        guard name.hasPrefix("Shape"), let number = Int(name.dropFirst(5)),
              (1...MembershipCard.shapeCount).contains(number) else { return nil }
        return number
    }

    /// The card with Arc's in it: its title (until Randomize), palette and
    /// shape as ReArc's of the same number, blobs seeded from Arc's, the
    /// member-since date and name. The transition is due again.
    public func applied(to card: MembershipCard) -> MembershipCard {
        var card = card
        if let title {
            card.title = title
            card.titleSource = .arc
        }
        if let shape { card.shape = shape }
        if let palette { card.arcPalette = palette }
        if !seed.isEmpty {
            card.seed = (0..<MembershipCard.blobCount).map { seed[$0 % seed.count] }
        }
        if let memberSince { card.arcMemberSince = MembershipCard.wholeSeconds(memberSince) }
        if let name { card.arcName = name }
        // After the transition the gradient follows the profile's theme.
        card.palette = 0
        card.transitionShown = !card.hasArcHistory
        return card
    }

    /// Compare only imported design/history, ignoring local name and transition progress.
    public func isApplied(to card: MembershipCard) -> Bool {
        let restored = applied(to: card)
        return card.title == restored.title && card.titleSource == restored.titleSource
            && card.shape == restored.shape && card.arcPalette == restored.arcPalette
            && card.seed == restored.seed && card.palette == restored.palette
            && card.arcMemberSince == restored.arcMemberSince && card.arcName == restored.arcName
    }

    /// Only the path to the two fields; every other key is skipped unread,
    /// and a field of the wrong type is dropped on its own.
    private struct AuthState: Decodable {
        var session: Session?

        init(from decoder: Decoder) throws {
            session = try? decoder.container(keyedBy: CodingKeys.self).decode(Session.self, forKey: .session)
        }

        enum CodingKeys: String, CodingKey { case session }

        struct Session: Decodable {
            var user: User?

            init(from decoder: Decoder) throws {
                user = try? decoder.container(keyedBy: CodingKeys.self).decode(User.self, forKey: .user)
            }

            enum CodingKeys: String, CodingKey { case user }
        }

        struct User: Decodable {
            var createdAt: Double?
            var name: String?

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                createdAt = try? c.decode(Double.self, forKey: .createdAt)
                name = try? c.decode(String.self, forKey: .name)
            }

            enum CodingKeys: String, CodingKey { case createdAt, name }
        }
    }

    private struct CardState: Decodable {
        var title: String?
        var paletteNumber: Int?
        var shapeName: String?
        var backgroundBlobInfo: [Int]?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try? c.decode(String.self, forKey: .title)
            paletteNumber = try? c.decode(Int.self, forKey: .paletteNumber)
            shapeName = try? c.decode(String.self, forKey: .shapeName)
            backgroundBlobInfo = try? c.decode([Int].self, forKey: .backgroundBlobInfo)
        }

        enum CodingKeys: String, CodingKey { case title, paletteNumber, shapeName, backgroundBlobInfo }
    }

}
