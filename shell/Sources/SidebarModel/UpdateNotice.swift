import Foundation

// Arc's "New Arc Version Available" notice at the bottom of the sidebar
// (docs/FEATURE-SPECS/UPDATE-NOTICE.md). Everything here is decided from the
// signed feed item's flags and version numbers only: no text from the feed is
// shown or logged.

/// How pressing an update is. Display only: no level forces a quit, blocks
/// browsing or overrides Automatic Updates (`UpdateEnforcement`).
public enum UpdateUrgency: Int, Comparable, Sendable {
    case normal
    /// Sparkle's own `<sparkle:criticalUpdate>` (`SUAppcastItem.isCriticalUpdate`).
    case critical
    /// ReArc's `<rearc:requiredBelow>` (`UpdateFeedMarker`), for this build.
    case required

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// ReArc's own marker in a feed item, in its own XML namespace:
///
///     <rss xmlns:rearc="https://rearc.imara.ae/xml-namespaces/update" …>
///       <item> … <rearc:requiredBelow>700</rearc:requiredBelow> … </item>
///
/// "Required for builds below 700". Sparkle keeps an element outside its own
/// namespace in the item's `propertiesDictionary` under its prefixed name,
/// as its trimmed text (attributes are dropped, hence text rather than
/// Sparkle's `sparkle:version` attribute), and ignores it otherwise: a ReArc
/// that predates the marker updates as for any other item.
public enum UpdateFeedMarker {
    public static let namespaceURI = "https://rearc.imara.ae/xml-namespaces/update"
    public static let prefix = "rearc"
    public static let requiredBelowKey = "rearc:requiredBelow"

    /// The builds an item is required for.
    public enum Requirement: Equatable, Sendable {
        case none
        case below(Int)
        /// Present but not a build number: ignored, and reported to the log
        /// by its shape only.
        case unrecognized
    }

    /// Reads the marker from `SUAppcastItem.propertiesDictionary`.
    public static func requirement(in properties: [AnyHashable: Any]) -> Requirement {
        guard let value = properties[requiredBelowKey] else { return .none }
        guard let text = value as? String, let build = UpdateBuild(text) else { return .unrecognized }
        return .below(build.number)
    }
}

/// A `CFBundleVersion` / `sparkle:version` as ReArc writes them: the commit
/// count, digits only. Anything else is not a build ReArc compares.
public struct UpdateBuild: Comparable, Hashable, Sendable {
    public var number: Int

    public init(_ number: Int) { self.number = number }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 9).contains(trimmed.count), trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(trimmed), number > 0 else { return nil }
        self.number = number
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.number < rhs.number }
}

/// The flags of a feed item as Sparkle parsed them from the signed feed.
public struct UpdateFeedFlags: Equatable, Sendable {
    /// `SUAppcastItem.isCriticalUpdate`: Sparkle has already applied the
    /// element's `sparkle:version` to the running build.
    public var isCritical: Bool
    public var requirement: UpdateFeedMarker.Requirement

    public init(isCritical: Bool, requirement: UpdateFeedMarker.Requirement = .none) {
        self.isCritical = isCritical
        self.requirement = requirement
    }

    public init(isCritical: Bool, properties: [AnyHashable: Any]) {
        self.init(isCritical: isCritical, requirement: UpdateFeedMarker.requirement(in: properties))
    }

    /// The level for the running build `host`. A build ReArc cannot read
    /// is never required.
    public func urgency(forHostBuild host: UpdateBuild?) -> UpdateUrgency {
        if case let .below(threshold) = requirement, let host, host.number < threshold { return .required }
        return isCritical ? .critical : .normal
    }
}

/// An update the updater found: its build (to tell a newer one apart), the
/// version Sparkle shows in its own window (logged, never drawn here) and
/// how pressing it is.
public struct AvailableUpdate: Equatable, Sendable {
    public var version: String
    public var build: UpdateBuild?
    public var urgency: UpdateUrgency

    public init(version: String, build: UpdateBuild? = nil, urgency: UpdateUrgency = .normal) {
        self.version = version
        self.build = build
        self.urgency = urgency
    }

    /// The mini space header's menu item, which installs it.
    public static let title = "Restart and Update ReArc"

    /// Another update than `other`: a higher build, or (with either build
    /// unreadable) a different version.
    func isNewer(than other: AvailableUpdate) -> Bool {
        if let build, let otherBuild = other.build { return build > otherBuild }
        return version != other.version
    }

    func isSameRelease(as other: AvailableUpdate) -> Bool {
        if let build, let otherBuild = other.build { return build == otherBuild }
        return version == other.version
    }
}

/// What went wrong, in the few kinds the card names. The technical text goes
/// to the log; the card shows `UpdateNoticeText.failure`.
public enum UpdateNoticeFailure: Equatable, Sendable {
    case offline
    case signature
    case noSpace
    /// A page asked ReArc not to quit (beforeunload); Try Again asks again.
    case quitRefused
    case other

    /// One error and its underlying chain, outermost first, as
    /// (domain, code). Sparkle's codes are SUErrors.h's.
    public static func classify(_ chain: [(domain: String, code: Int)]) -> UpdateNoticeFailure {
        let offline: Set<Int> = [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1020]
        if chain.contains(where: { ($0.domain == NSCocoaErrorDomain && $0.code == NSFileWriteOutOfSpaceError)
            || ($0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOSPC)) }) { return .noSpace }
        if chain.contains(where: { $0.domain == NSURLErrorDomain && offline.contains($0.code) }) { return .offline }
        // SUInsufficientSigningError, SUSignatureError, SUValidationError.
        if chain.contains(where: { $0.domain == sparkleErrorDomain && [2, 3001, 3002].contains($0.code) }) { return .signature }
        return .other
    }

    public static let sparkleErrorDomain = "SUSparkleErrorDomain"
    /// SUNoUpdateError: the feed has nothing newer (not a failure).
    public static let noUpdateCode = 1001
    /// SUInstallationCanceledError: the person or Sparkle stopped it.
    public static let canceledCode = 4007
}

/// The download as Sparkle reports it.
public struct UpdateProgress: Equatable, Sendable {
    public var received: UInt64 = 0
    public var expected: UInt64?

    public init(received: UInt64 = 0, expected: UInt64? = nil) {
        self.received = received
        self.expected = expected
    }

    /// 0…1, or nil while the size is unknown.
    public var fraction: Double? {
        guard let expected, expected > 0 else { return nil }
        return min(Double(received) / Double(expected), 1)
    }
}

/// The notice's state, shared by every window. Sparkle's user driver and
/// delegate feed it events (`AppUpdater`); the sidebar draws it.
///
///     idle → available → downloading → extracting → installing (ReArc quits)
///               ↘ ready (already downloaded) ↗
///     any step → failed → Try Again → downloading / installing
public struct UpdateNotice: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        /// Found, not downloaded.
        case available
        case downloading(UpdateProgress)
        case extracting(Double)
        /// Downloaded and ready: Restart and Update installs at once.
        case ready
        /// Installing: ReArc is quitting to relaunch.
        case installing
        case failed(UpdateNoticeFailure)
    }

    public enum Event: Equatable, Sendable {
        case found(AvailableUpdate, downloaded: Bool)
        /// Restart and Update (or Try Again).
        case installRequested
        case downloadStarted
        case downloadExpected(UInt64)
        case downloadReceived(UInt64)
        case extractionStarted
        case extracted(Double)
        case readyToInstall
        case installing
        case failed(UpdateNoticeFailure)
        /// Up to date: the feed has nothing newer.
        case notFound
        /// Skip This Version in Sparkle's window.
        case skipped
        /// Sparkle ended its session without installing.
        case sessionEnded
        case pointerVisited
        case hidden
    }

    public private(set) var update: AvailableUpdate?
    public private(set) var phase: Phase = .idle
    /// The person pressed Restart and Update; every later step runs on.
    public private(set) var installRequested = false
    /// The pointer has been over the open card since this update arrived.
    public private(set) var pointerVisited = false
    /// Hidden from the sidebar (normal updates only) until another update.
    public private(set) var isHidden = false

    public init() {}

    public mutating func send(_ event: Event) {
        switch event {
        case let .found(found, downloaded):
            receive(found, downloaded: downloaded)
        case .installRequested:
            guard update != nil else { return }
            switch phase {
            case .available, .failed(.offline), .failed(.signature), .failed(.noSpace), .failed(.other):
                installRequested = true
                phase = .downloading(UpdateProgress())
            case .ready, .failed(.quitRefused):
                installRequested = true
                phase = .installing
            case .idle, .downloading, .extracting, .installing:
                break
            }
        case .downloadStarted:
            if installRequested, update != nil { phase = .downloading(UpdateProgress()) }
        case let .downloadExpected(length):
            if case var .downloading(progress) = phase {
                progress.expected = length
                phase = .downloading(progress)
            }
        case let .downloadReceived(length):
            if case var .downloading(progress) = phase {
                progress.received += length
                phase = .downloading(progress)
            }
        case .extractionStarted:
            if installRequested, update != nil { phase = .extracting(0) }
        case let .extracted(fraction):
            if case .extracting = phase { phase = .extracting(min(max(fraction, 0), 1)) }
        case .readyToInstall:
            guard update != nil else { return }
            phase = installRequested ? .installing : .ready
        case .installing:
            if update != nil { phase = .installing }
        case let .failed(failure):
            guard update != nil else { return }
            phase = .failed(failure)
            // A refused quit keeps the request: Try Again asks again.
            installRequested = failure == .quitRefused
        case .notFound, .skipped:
            self = UpdateNotice()
        case .sessionEnded:
            switch phase {
            case .downloading, .extracting:
                installRequested = false
                phase = .available
            default:
                break
            }
        case .pointerVisited:
            if update != nil { pointerVisited = true }
        case .hidden:
            if canHide { isHidden = true }
        }
    }

    private mutating func receive(_ found: AvailableUpdate, downloaded: Bool) {
        guard let current = update else {
            update = found
            phase = downloaded ? .ready : .available
            return
        }
        if found.isNewer(than: current) {
            // Already quitting to install the one before: that install wins.
            guard phase != .installing else { return }
            update = found
            pointerVisited = false
            isHidden = false
            if installRequested {
                // Restart and Update's own check found a newer build: it carries on with that one.
                phase = downloaded ? .installing : .downloading(UpdateProgress())
            } else {
                phase = downloaded ? .ready : .available
            }
        } else if found.isSameRelease(as: current) {
            if found.urgency != current.urgency {
                update = found
                if found.urgency > current.urgency { isHidden = false }
            }
            switch phase {
            case .idle, .failed:
                if !installRequested { phase = downloaded ? .ready : .available }
            case .available:
                if downloaded { phase = .ready }
            case .downloading, .extracting:
                if downloaded { phase = installRequested ? .installing : .ready }
            case .ready, .installing:
                break
            }
        }
        // An older build than the one shown is not news.
    }

    public var urgency: UpdateUrgency { update?.urgency ?? .normal }

    /// The sidebar draws the notice.
    public var isVisible: Bool { update != nil && phase != .idle && !isHidden }

    /// Downloading, preparing or quitting: the button waits.
    public var isBusy: Bool {
        switch phase {
        case .downloading, .extracting, .installing: true
        default: false
        }
    }

    /// Only a normal update can be put away; critical and required stay.
    public var canHide: Bool { update != nil && urgency == .normal }

    /// The card stays open without the pointer: while it shows progress, and
    /// for a critical or required update until the pointer has been over it.
    public var holdsCardOpen: Bool {
        isVisible && (isBusy || (urgency >= .critical && !pointerVisited))
    }

    /// The menu's "Update Available…" and its badge.
    public var menuState: UpdateMenuState { UpdateMenuState(updateAvailable: update != nil && phase != .idle) }
}

/// The ReArc menu item: "Check for Updates…", or "Update Available…" with a
/// badge while an update waits.
public struct UpdateMenuState: Equatable, Sendable {
    public var updateAvailable = false

    public init(updateAvailable: Bool = false) {
        self.updateAvailable = updateAvailable
    }

    public var title: String { updateAvailable ? "Update Available…" : "Check for Updates…" }
    public var badgeCount: Int { updateAvailable ? 1 : 0 }
}

/// Which of Sparkle's surfaces owns the update session in progress: the
/// sidebar notice (scheduled checks, and Restart and Update's own check) or
/// Sparkle's standard window (Check for Updates…, "You're up to date"). One
/// surface per update: a scheduled critical update goes to the notice, never
/// also to Sparkle's alert.
public struct UpdateSessionRouting: Equatable, Sendable {
    public enum Route: Equatable, Sendable {
        case notice
        case standard
    }

    public private(set) var route: Route?
    /// Restart and Update started the check now beginning.
    public private(set) var noticeStartedCheck = false

    public init() {}

    /// Restart and Update had no update in hand and asks Sparkle to check
    /// (or resume a downloaded update); the session that follows is the notice's.
    public mutating func noticeWillCheck() { noticeStartedCheck = true }

    /// `showUserInitiatedUpdateCheck`: the notice's own check, or the menu's.
    public mutating func userInitiatedCheckBegan() -> Route {
        let owner: Route = noticeStartedCheck ? .notice : .standard
        route = owner
        return owner
    }

    /// `showUpdateFound`. A scheduled find is the notice's, except an
    /// information-only item (nothing to install), which is Sparkle's.
    public mutating func updateFound(userInitiated: Bool, informationOnly: Bool) -> Route {
        if let route { return route }
        let owner: Route = (userInitiated && !noticeStartedCheck) || informationOnly ? .standard : .notice
        route = owner
        return owner
    }

    /// The menu asked for Sparkle's window while the notice held the update.
    public mutating func handOverToStandard() { route = .standard }

    /// Any other callback before the session has an owner (a resumed
    /// install, an error) belongs to whoever started it.
    public var current: Route { route ?? (noticeStartedCheck ? .notice : .standard) }

    public mutating func sessionEnded() { self = UpdateSessionRouting() }
}

/// What "required" may enforce later. Today every level is display only;
/// the owner decides (docs/FEATURE-SPECS/UPDATE-NOTICE.md §5). Enforcement
/// goes here and only here: `AppUpdater` asks before each step it could take.
public enum UpdateEnforcement {
    /// Install at the next quit even with Automatic Updates off.
    public static func installsAtQuit(_ urgency: UpdateUrgency) -> Bool { false }
    /// Ask at launch, before browsing, once a deadline has passed.
    public static func blocksAtLaunch(_ urgency: UpdateUrgency) -> Bool { false }
}

/// The sidebars a notice can appear in.
public enum UpdateNoticeForm: Equatable, Sendable {
    case none
    /// Arc's pill above the space strip, growing into the card on hover.
    case pill
    /// The mini sidebar's glyph in the same place; the card is a popover.
    case compact
}

public enum UpdateNoticePresentation {
    public enum WindowKind: Equatable, Sendable {
        case browser
        case littleArc
        case privateWindow
    }

    public enum SidebarMode: Equatable, Sendable {
        case full
        case mini
        /// ⌘S: nothing extra; the ReArc menu's item is the route there.
        case hidden
    }

    /// Browser windows only: a Little ReArc window and a private window have
    /// no sidebar and no notice.
    public static func form(for notice: UpdateNotice, window: WindowKind, sidebar: SidebarMode) -> UpdateNoticeForm {
        guard notice.isVisible, window == .browser else { return .none }
        switch sidebar {
        case .full: return .pill
        case .mini: return .compact
        case .hidden: return .none
        }
    }
}

/// Every word the notice shows. None comes from the feed.
public enum UpdateNoticeText {
    public static func title(_ urgency: UpdateUrgency) -> String {
        switch urgency {
        case .normal: "New ReArc Version Available"
        case .critical: "Critical Update Available"
        case .required: "Required Update"
        }
    }

    public static func detail(_ urgency: UpdateUrgency) -> String? {
        switch urgency {
        case .normal: nil
        case .critical: "This update fixes a security problem."
        case .required: "This version of ReArc is no longer supported. Restart to update."
        }
    }

    public static let automaticUpdates = "Automatic Updates"
    public static let install = "Restart and Update"
    public static let retry = "Try Again"
    public static let hide = "Hide Until the Next Update"

    /// The line under the checkbox while the button waits, or after a failure.
    public static func status(_ phase: UpdateNotice.Phase) -> String? {
        switch phase {
        case let .downloading(progress):
            guard let fraction = progress.fraction else { return "Downloading…" }
            return "Downloading… \(Int((fraction * 100).rounded(.down)))%"
        case .extracting: return "Preparing the update…"
        case .installing: return "Restarting ReArc…"
        case let .failed(failure): return self.failure(failure)
        case .idle, .available, .ready: return nil
        }
    }

    public static func failure(_ failure: UpdateNoticeFailure) -> String {
        switch failure {
        case .offline: "ReArc can't reach the update server. Check your connection."
        case .signature: "The update couldn't be verified, so it wasn't installed."
        case .noSpace: "There isn't enough disk space for the update."
        case .quitRefused: "A page asked ReArc to stay open."
        case .other: "The update couldn't be installed."
        }
    }
}

/// The notice's colours on one theme: the pill's wash, a warning ink that
/// clears the text floor (critical and required), and the card's surface.
/// Arc's light theme measured: black at ≈ 5 % for the pill, white at ≈ 80 %
/// for the card.
public struct UpdateNoticeInk: Hashable, Sendable {
    public var pillFill: SpaceColor
    public var pillFillAlpha: Double
    /// The critical and required pill stands out on a stronger wash away
    /// from its ink (white under dark ink, black under light): on a mid-tone
    /// theme Arc's faint wash leaves no orange, not even black or white,
    /// that reaches the text floor.
    public var warningFill: SpaceColor
    public var warningFillAlpha: Double
    /// The critical and required pill's title and glyph, on `warningFill`.
    public var warning: SpaceColor
    public var card: SpaceColor
    public var cardAlpha: Double
    /// The card's text uses the light roles (white card) or the dark ones.
    public var cardIsDark: Bool
    /// The critical and required line on the card.
    public var cardWarning: SpaceColor
    /// Restart and Update's title on the space's accent.
    public var buttonTitle: SpaceColor

    /// Apple's orange (light and dark), moved as little as each surface needs.
    static let warningBase = (light: SpaceColor(red: 1, green: 0.584, blue: 0), dark: SpaceColor(red: 1, green: 0.624, blue: 0.039))

    /// `lightInk`: the sidebar's text is light (`SidebarBackdrop.prefersLightInk`).
    public init(backdrop: SidebarBackdrop, lightInk: Bool, accent: SpaceColor) {
        pillFill = lightInk ? .white : .black
        pillFillAlpha = lightInk ? 0.10 : 0.05
        let base = lightInk ? Self.warningBase.dark : Self.warningBase.light
        warningFill = lightInk ? .black : .white
        warningFillAlpha = 0.6
        warning = Self.washed(backdrop, with: warningFill, alpha: warningFillAlpha)
            .legible(base, floor: SidebarContrast.text, lightInk: lightInk)
        cardIsDark = lightInk
        card = lightInk ? SpaceColor(red: 0.14, green: 0.14, blue: 0.15) : .white
        cardAlpha = lightInk ? 0.9 : 0.8
        cardWarning = Self.washed(backdrop, with: card, alpha: cardAlpha)
            .legible(base, floor: SidebarContrast.text, lightInk: lightInk)
        buttonTitle = accent.contrast(with: .white) >= accent.contrast(with: .black) ? .white : .black
    }

    /// `backdrop` under a wash of `color` at `alpha`.
    static func washed(_ backdrop: SidebarBackdrop, with color: SpaceColor, alpha: Double) -> SidebarBackdrop {
        SidebarBackdrop(darkest: backdrop.darkest.mixed(with: color, fraction: alpha),
                        lightest: backdrop.lightest.mixed(with: color, fraction: alpha))
    }
}

/// Arc's notice as measured from the owner's recording (UPDATE-NOTICE.md §2),
/// in points and seconds. The views apply them.
public enum UpdateNoticeMetrics {
    /// The pill: 24 pt tall, 8 pt in from each sidebar edge, 9 pt above the
    /// space strip; the card shares its corner radius.
    public static let pillHeight = 24.0
    public static let cornerRadius = 10.0
    public static let gapAboveStrip = 9.0
    /// The card: the title row (the pill's height), a hairline, the checkbox
    /// row, the 24 pt button 8 pt in from the card's edges and bottom.
    public static let checkboxRowHeight = 31.0
    public static let buttonHeight = 24.0
    public static let buttonRadius = 6.0
    public static let cardInset = 8.0
    public static let titleSize = 12.0
    public static let labelSize = 12.0
    public static let buttonTitleSize = 11.0
    /// The card's height in Arc (no detail or status line): 24 + 1 + 31 + 24 + 8.
    public static let cardHeight = 88.0
    /// The pointer rests ≈ 0.4 s on the pill before the card opens; it
    /// grows in ≈ 0.15 s with a 3 pt overshoot that settles by ≈ 0.33 s, and
    /// closes ≈ 0.05 s after the pointer leaves, in ≈ 0.07 s.
    public static let openDelay: TimeInterval = 0.4
    public static let openResponse: TimeInterval = 0.2
    public static let openDamping = 0.8
    public static let closeDelay: TimeInterval = 0.05
    public static let closeDuration: TimeInterval = 0.07
}

/// Text from the feed or from Sparkle's errors, made safe for a log line:
/// printable ASCII stays (backslash and quote escaped), anything else
/// (newlines, controls, bidirectional marks, any non-ASCII) becomes
/// `\u{…}`, and it is cut at `limit` characters.
public enum UpdateNoticeLog {
    public static func escaped(_ text: String, limit: Int = 200) -> String {
        var out = ""
        for scalar in text.unicodeScalars.prefix(limit) {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case " " ... "~": out.unicodeScalars.append(scalar)
            default: out += "\\u{\(String(scalar.value, radix: 16))}"
            }
        }
        if text.unicodeScalars.count > limit { out += "…" }
        return "\"\(out)\""
    }
}
