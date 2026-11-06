import Foundation

/// The per-site panel behind the URL field's site icon (Arc `ARC_SiteControlCenter`,
/// `SiteControlCenterBoostsView`; BOOSTS §5): connection, permissions, the
/// site's boosts, its zoom and its cookies and site data.
public enum SiteControlCenter {
    /// The site a page belongs to, for web pages only.
    public struct Site: Equatable, Sendable {
        public var origin: String
        public var host: String
    }

    public static func site(for url: URL?) -> Site? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let origin = PageOrigin.of(url), let host = PageOrigin.displayHost(origin) else { return nil }
        return Site(origin: origin, host: host)
    }

    /// Whether a website-data record (WebKit names them by registrable
    /// domain, "example.co.uk") belongs to `host` or one of its parents.
    public static func siteDataRecord(_ recordDomain: String, belongsTo host: String) -> Bool {
        let record = recordDomain.lowercased()
        let name = host.lowercased().split(separator: ":").first.map(String.init) ?? host.lowercased()
        guard !record.isEmpty else { return false }
        return name == record || name.hasSuffix("." + record)
    }

    /// One boost row: its switch says whether it changes this site now.
    public struct BoostRow: Equatable, Identifiable, Sendable {
        public var id: UUID
        public var name: String
        public var isEnabled: Bool
    }

    public static func boostRows(_ matches: [(BoostPackage, BoostInstallation)]) -> [BoostRow] {
        matches.map { BoostRow(id: $0.0.manifest.id, name: $0.0.manifest.name, isEnabled: $0.1.enabled) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The site data line: what WebKit holds for the site, or where Chromium's lives.
    public static func siteDataSummary(recordCount: Int?) -> String {
        switch recordCount {
        case nil: return "Cookies and storage are kept by the engine"
        case 0: return "No cookies or site data"
        case 1: return "1 kind of site data stored"
        case let count?: return "\(count) kinds of site data stored"
        }
    }
}

// MARK: - Arc's site controls panel

/// What Arc's toolbar site-controls popover lists, top to bottom: four
/// square buttons, the Extensions grid, the site's Settings rows, then a
/// footer with the connection and a ⋯ menu (docs/arc-recordings/2026-11-06-site-controls-panel.md).
extension SiteControlCenter {
    /// The top row, in Arc's order.
    public enum QuickAction: String, CaseIterable, Sendable {
        case share, boost, capture, captureFullPage

        public var title: String {
            switch self {
            case .share: return "Share"
            case .boost: return "New Boost"
            case .capture: return "Capture"
            case .captureFullPage: return "Capture Full Page"
            }
        }

        public var symbol: String {
            switch self {
            case .share: return "square.and.arrow.up"
            case .boost: return "wand.and.sparkles"
            case .capture: return "camera"
            case .captureFullPage: return "text.viewfinder"
            }
        }
    }

    public struct QuickActionItem: Equatable, Identifiable, Sendable {
        public var action: QuickAction
        public var isEnabled: Bool
        public var id: QuickAction { action }
    }

    /// Boosts can't change some web pages (the Web Store, the engine's own).
    public static func quickActions(boostsEligible: Bool) -> [QuickActionItem] {
        QuickAction.allCases.map { QuickActionItem(action: $0, isEnabled: $0 != .boost || boostsEligible) }
    }

    /// One tile of the Extensions grid: an extension, or Arc's + last.
    public enum ExtensionTile: Equatable, Identifiable, Sendable {
        case action(ExtensionActionItem, pinned: Bool)
        case add

        public var id: String {
            switch self {
            case .action(let item, _): return item.id
            case .add: return "+"
            }
        }
    }

    public static let extensionColumns = 4

    /// Pinned extensions first, in the toolbar's order, then the rest in
    /// the engine's order, then +. Arc's grid starts with the toolbar's icons.
    public static func extensionTiles(_ actions: [ExtensionActionItem], pins: ExtensionPins) -> [ExtensionTile] {
        let pinned = pins.pinned(actions)
        let rest = actions.filter { !pins.isPinned($0.id) }
        return pinned.map { .action($0, pinned: true) } + rest.map { .action($0, pinned: false) } + [.add]
    }

    /// What a Settings row's menu can do.
    public enum SettingAction: Equatable, Sendable {
        case allow, block, reset, snoozeOneHour, openSiteSettings

        public var title: String {
            switch self {
            case .allow: return "Allow"
            case .block: return "Block"
            case .reset: return "Reset"
            case .snoozeOneHour: return "Snooze for 1 Hour"
            case .openSiteSettings: return "Site Settings…"
            }
        }
    }

    /// One Settings row: a round icon, a title and the site's state.
    public struct SettingRow: Equatable, Identifiable, Sendable {
        public enum Kind: Hashable, Sendable {
            case permission(String)
            case autoPictureInPicture
        }

        public var kind: Kind
        public var title: String
        public var state: String
        public var symbol: String
        public var isBlocked: Bool
        /// One action is a click; more are a menu; none is a label.
        public var actions: [SettingAction]
        public var id: Kind { kind }
    }

    /// Location, camera, microphone and notifications lead, as in Arc; other types follow by name.
    static let leadingPermissions = ["geolocation", "camera_stream", "mic_stream", "notifications"]

    /// The site's answered permissions, then automatic Picture in Picture.
    /// `permissionsInEngine`: Chromium keeps remembered answers, so a row
    /// opens its Site Settings; on WebKit the shell's store is the answer.
    public static func settingRows(
        permissions: [(type: PermissionType, entry: SitePermissionStore.Entry)],
        permissionsInEngine: Bool,
        autoPiP: AutoPiPHostPreference,
        autoPiPEnabled: Bool,
        now: Date = Date()
    ) -> [SettingRow] {
        func rank(_ type: PermissionType) -> Int { leadingPermissions.firstIndex(of: type.key) ?? leadingPermissions.count }
        let sorted = permissions.sorted { (rank($0.type), $0.type.name) < (rank($1.type), $1.type.name) }
        var rows = sorted.map { type, entry in
            let blocked = entry.decision == .deny
            let actions: [SettingAction] = permissionsInEngine
                ? [.openSiteSettings]
                : [blocked ? .allow : .block, .reset]
            return SettingRow(kind: .permission(type.key), title: type.name, state: permissionState(entry),
                              symbol: type.symbol, isBlocked: blocked, actions: actions)
        }
        rows.append(autoPiPRow(autoPiP, enabled: autoPiPEnabled, now: now))
        return rows
    }

    public static func permissionState(_ entry: SitePermissionStore.Entry) -> String {
        let decision = entry.decision == .allow ? "Allowed" : "Blocked"
        return entry.remembered ? decision : "\(decision) this time"
    }

    /// Arc's "Automatic Picture-In-Picture" row, from ReArc's per-site
    /// allow, block and one-hour snooze. Off in Settings wins for every
    /// site, and then the row has nothing to change.
    static func autoPiPRow(_ preference: AutoPiPHostPreference, enabled: Bool, now: Date) -> SettingRow {
        var row = SettingRow(kind: .autoPictureInPicture, title: "Automatic Picture-In-Picture", state: "Allowed",
                             symbol: "pip", isBlocked: false, actions: [.block, .snoozeOneHour])
        switch preference {
        case .enabled:
            break
        case .disabled:
            row.state = "Blocked"
            row.isBlocked = true
            row.actions = [.allow]
        case .snoozedUntil(let deadline):
            let minutes = max(1, Int((deadline.timeIntervalSince(now) / 60).rounded(.up)))
            row.state = "Snoozed for \(minutes) min"
            row.isBlocked = true
            row.actions = [.allow, .block]
        }
        if !enabled {
            row.state = "Off for all sites"
            row.isBlocked = true
            row.actions = []
        }
        return row
    }

    /// The ⋯ menu: what the old panel held besides permissions.
    public enum MenuItem: Hashable, Sendable {
        case zoomLevel(percent: Int)
        case zoomIn, zoomOut, actualSize(enabled: Bool)
        case boost(id: UUID, name: String, enabled: Bool)
        case editBoosts
        /// WebKit: the shell clears the site's records itself.
        case clearSiteData
        /// Chromium: its Site Settings page lists and clears them.
        case cookiesAndSiteData
        case siteSettings

        public var title: String {
            switch self {
            case .zoomLevel(let percent): return "Zoom \(percent)%"
            case .zoomIn: return "Zoom In"
            case .zoomOut: return "Zoom Out"
            case .actualSize: return "Actual Size"
            case .boost(_, let name, _): return name
            case .editBoosts: return "Edit Boost…"
            case .clearSiteData: return "Clear Cookies and Site Data"
            case .cookiesAndSiteData: return "Cookies and Site Data…"
            case .siteSettings: return "Site Settings…"
            }
        }
    }

    /// Sections of the ⋯ menu, divided in the view.
    public static func moreMenu(zoomPercent: Int, boosts: [BoostRow], shellClearsSiteData: Bool, siteSettingsAvailable: Bool) -> [[MenuItem]] {
        var sections: [[MenuItem]] = [[.zoomLevel(percent: zoomPercent), .zoomIn, .zoomOut, .actualSize(enabled: zoomPercent != 100)]]
        if !boosts.isEmpty {
            sections.append(boosts.map { .boost(id: $0.id, name: $0.name, enabled: $0.isEnabled) } + [.editBoosts])
        }
        var site: [MenuItem] = []
        if shellClearsSiteData {
            site.append(.clearSiteData)
        } else if siteSettingsAvailable {
            site.append(.cookiesAndSiteData)
        }
        if siteSettingsAvailable { site.append(.siteSettings) }
        if !site.isEmpty { sections.append(site) }
        return sections
    }

    /// The connection as the footer shows it.
    public enum Connection: Sendable {
        case secure, insecure, dangerous, unknown
    }

    public enum FooterAction: Equatable, Sendable {
        case showCertificate, openSiteSettings
    }

    public struct Footer: Equatable, Sendable {
        public var title: String
        public var symbol: String
        public var isWarning: Bool
        /// Nil: the badge is a label.
        public var action: FooterAction?
    }

    /// "🔒 Secure" in Arc. A click shows the certificate where the engine
    /// hands one over (WebKit), otherwise the site's settings (Chromium).
    public static func footer(_ connection: Connection, certificateAvailable: Bool, siteSettingsAvailable: Bool) -> Footer {
        let action: FooterAction? = certificateAvailable ? .showCertificate : (siteSettingsAvailable ? .openSiteSettings : nil)
        switch connection {
        case .secure: return Footer(title: "Secure", symbol: "lock.fill", isWarning: false, action: action)
        case .insecure: return Footer(title: "Not Secure", symbol: "lock.open.fill", isWarning: true, action: action)
        case .dangerous: return Footer(title: "Dangerous", symbol: "exclamationmark.octagon.fill", isWarning: true, action: action)
        case .unknown: return Footer(title: "Site Info", symbol: "info.circle", isWarning: false, action: siteSettingsAvailable ? .openSiteSettings : nil)
        }
    }
}
