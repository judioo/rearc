import Foundation

/// The browsers macOS keeps ReArc out of, while the person goes to System
/// Settings to allow them and comes back (PROFILE-IMPORT §6). The Import
/// window and the onboarding share it:
///
/// 1. `update` with each discovery: which are blocked, which just opened.
/// 2. `openedSettings` when the person presses the button.
/// 3. `becameActive` when ReArc is the active app again: true means look
///    again now (a few `open` calls, no counting).
/// 4. The next `update` either opens the browser (importable without a
///    restart) or, when it is still blocked after a visit to System Settings,
///    `offersRelaunch`: macOS applies some switches (Full Disk Access) only
///    to a freshly launched app.
public struct ImportAccessWatch: Equatable, Sendable {
    /// Blocked now, in discovery order.
    public private(set) var blocked: [ImportBrowser] = []
    public private(set) var permissions: [ImportBrowser: ImportPermission] = [:]
    /// System Settings was opened for these and ReArc has not been active since.
    public private(set) var awaitingReturn: Set<ImportPermission> = []
    /// Back from System Settings; the next `update` says whether it worked.
    private var checking: Set<ImportPermission> = []
    /// Still blocked after the person came back from System Settings.
    public private(set) var stillBlockedAfterSettings: Set<ImportBrowser> = []

    public init() {}

    public init(_ discovered: [DiscoveredBrowser]) { update(discovered) }

    public var isEmpty: Bool { blocked.isEmpty }

    public func permission(for browser: ImportBrowser) -> ImportPermission? { permissions[browser] }

    /// Takes a discovery; returns the browsers that were blocked and now are not.
    @discardableResult
    public mutating func update(_ discovered: [DiscoveredBrowser]) -> [ImportBrowser] {
        var now: [ImportBrowser] = []
        var permissions: [ImportBrowser: ImportPermission] = [:]
        for found in discovered {
            if case .blocked(let permission) = found.status {
                now.append(found.browser)
                permissions[found.browser] = permission
            }
        }
        let opened = blocked.filter { !now.contains($0) }
        let checked = checking
        checking = []
        stillBlockedAfterSettings = stillBlockedAfterSettings.intersection(now)
            .union(now.filter { permissions[$0].map(checked.contains) == true })
        blocked = now
        self.permissions = permissions
        return opened
    }

    /// The person is on their way to `permission`'s pane.
    public mutating func openedSettings(_ permission: ImportPermission) {
        awaitingReturn.insert(permission)
    }

    /// ReArc is active again. Returns whether to look again now: whenever
    /// something is blocked, since the person may have used System Settings
    /// without the button.
    public mutating func becameActive() -> Bool {
        checking.formUnion(awaitingReturn)
        awaitingReturn = []
        return !blocked.isEmpty
    }

    /// A relaunch may be what macOS is waiting for.
    public func offersRelaunch(for browser: ImportBrowser) -> Bool {
        stillBlockedAfterSettings.contains(browser)
    }

    public var offersRelaunch: Bool { !stillBlockedAfterSettings.isEmpty }

    /// The panes to send the person to, one per permission, in the order
    /// their browsers were found.
    public var neededPermissions: [ImportPermission] {
        var out: [ImportPermission] = []
        for browser in blocked {
            if let permission = permissions[browser], !out.contains(permission) { out.append(permission) }
        }
        return out
    }
}
