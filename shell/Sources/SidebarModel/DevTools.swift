import Foundation

/// Where a tab's DevTools show (Arc docks them beside the page by default).
public enum DevToolsPlacement: String, Equatable, Sendable {
    /// A pane beside the page in the tab's window.
    case docked
    /// Their own window.
    case window
}

/// Chrome's Dock side, as a dockable frontend reports it (Chromium ABI 1.54).
public enum DevToolsDockSide: UInt32, Equatable, Sendable {
    case undocked = 0, right, bottom, left
}

/// A dockable frontend's layout, as Chrome's DevToolsWindow keeps it: the
/// frontend (docked) or its device-mode toolbox (undocked) fills the content
/// area and the page sits above it at the bounds the frontend reports.
public struct DevToolsDockLayout: Equatable, Sendable {
    public var side: DevToolsDockSide
    /// The engine tab behind the page; 0 while undocked without a toolbox.
    public var inTabTabID: UInt64
    /// The page's rect in that view, in points; nil until the frontend sends one.
    public var pageBounds: CGRect?

    public init(side: DevToolsDockSide, inTabTabID: UInt64, pageBounds: CGRect? = nil) {
        self.side = side
        self.inTabTabID = inTabTabID
        self.pageBounds = pageBounds
    }

    /// Chrome's ApplyDevToolsContentsResizingStrategy: no bounds, or an empty
    /// size off the origin, fill the area; an empty rect at the origin hides
    /// the page; right and bottom docks keep DevTools' minimum size.
    public func pageFrame(in container: CGSize) -> CGRect {
        guard let bounds = pageBounds, (bounds.width > 0 && bounds.height > 0) || bounds.origin == .zero
        else { return CGRect(origin: .zero, size: container) }
        let left = min(bounds.minX, container.width), top = min(bounds.minY, container.height)
        var width = min(bounds.width, container.width), height = min(bounds.height, container.height)
        switch side {
        case .right: width = min(width, max(0, container.width - 250))
        case .bottom: height = min(height, max(0, container.height - 72))
        case .left, .undocked: break
        }
        return CGRect(x: left, y: top, width: max(0, width), height: max(0, height))
    }
}

/// One tab's DevTools frontend: the engine's frontend tab and where it shows.
public struct DevToolsSession: Equatable, Sendable {
    /// The engine's frontend tab (Chromium registry ID); it closes when the page does.
    public var frontendTabID: UInt64
    public var placement: DevToolsPlacement
    /// Set once a dockable frontend reports its layout; it then decides `placement`.
    public var layout: DevToolsDockLayout?

    public init(frontendTabID: UInt64, placement: DevToolsPlacement = .docked) {
        self.frontendTabID = frontendTabID
        self.placement = placement
    }
}

/// The DevTools open in this window session, at most one per sidebar tab
/// (the engine makes a new frontend on every request; the shell reuses its own).
public struct DevToolsSessions: Equatable, Sendable {
    public private(set) var sessions: [UUID: DevToolsSession] = [:]
    /// Width of the docked pane as a fraction of the content area.
    public private(set) var dockFraction: Double = 0.4

    public static let dockFractionRange: ClosedRange<Double> = 0.2 ... 0.75

    public init() {}

    public func session(for tabID: UUID) -> DevToolsSession? { sessions[tabID] }

    public func tab(forFrontend frontendTabID: UInt64) -> UUID? {
        sessions.first { $0.value.frontendTabID == frontendTabID }?.key
    }

    /// A new frontend for `tabID` shows docked; one already open is kept as it is.
    public mutating func opened(_ frontendTabID: UInt64, for tabID: UUID) {
        guard sessions[tabID] == nil else { return }
        sessions[tabID] = DevToolsSession(frontendTabID: frontendTabID)
    }

    public mutating func setPlacement(_ placement: DevToolsPlacement, for tabID: UUID) {
        sessions[tabID]?.placement = placement
    }

    /// A dockable frontend moved or resized the page; undocked means its own window.
    @discardableResult
    public mutating func setLayout(_ layout: DevToolsDockLayout, forFrontend frontendTabID: UInt64) -> UUID? {
        guard let tab = tab(forFrontend: frontendTabID) else { return nil }
        sessions[tab]?.layout = layout
        sessions[tab]?.placement = layout.side == .undocked ? .window : .docked
        return tab
    }

    public mutating func setDockFraction(_ fraction: Double) {
        guard fraction.isFinite else { return }
        dockFraction = min(max(fraction, Self.dockFractionRange.lowerBound), Self.dockFractionRange.upperBound)
    }

    /// The shell closed them (⌥⌘I again, the pane's close button, the window).
    @discardableResult
    public mutating func close(for tabID: UUID) -> DevToolsSession? {
        sessions.removeValue(forKey: tabID)
    }

    /// The engine closed the frontend (its page closed, or the frontend did).
    @discardableResult
    public mutating func frontendClosed(_ frontendTabID: UInt64) -> UUID? {
        guard let tab = tab(forFrontend: frontendTabID) else { return nil }
        sessions[tab] = nil
        return tab
    }
}

// MARK: - Client certificates

/// One identity the engine offers for a TLS client-certificate request.
public struct ClientCertificateIdentity: Identifiable, Equatable, Sendable {
    /// SHA-256 of the leaf certificate, 64 uppercase hex digits (what the reply carries).
    public var fingerprint: String
    public var subject: String
    public var issuer: String
    public var expires: Date

    public var id: String { fingerprint }

    public init(fingerprint: String, subject: String, issuer: String, expires: Date) {
        self.fingerprint = fingerprint
        self.subject = subject
        self.issuer = issuer
        self.expires = expires
    }

    /// From the ABI's Unix microseconds.
    public init(fingerprint: String, subject: String, issuer: String, expiryMicroseconds: Int64) {
        self.init(fingerprint: fingerprint, subject: subject, issuer: issuer,
                  expires: Date(timeIntervalSince1970: Double(expiryMicroseconds) / 1_000_000))
    }

    public func isExpired(at now: Date = Date()) -> Bool { expires <= now }

    /// "AB12 CD34 … 9F" style grouping of the fingerprint, as Keychain Access shows it.
    public var groupedFingerprint: String {
        stride(from: 0, to: fingerprint.count, by: 2).map { offset -> String in
            let start = fingerprint.index(fingerprint.startIndex, offsetBy: offset)
            return String(fingerprint[start ..< fingerprint.index(start, offsetBy: min(2, fingerprint.count - offset))])
        }.joined(separator: " ")
    }

    /// A fingerprint the engine accepts: 64 hex digits.
    public static func isValidFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

/// A site asking which certificate identifies you (Chromium `client_certificates`, ABI 1.41).
public struct ClientCertificateRequest: Identifiable, Equatable, Sendable {
    public var id: UInt64
    /// `https://host:port` of the server that asked (not the page URL).
    public var origin: String
    public var identities: [ClientCertificateIdentity]

    public init(id: UInt64, origin: String, identities: [ClientCertificateIdentity]) {
        self.id = id
        self.origin = origin
        self.identities = identities
    }

    /// The server, without the default HTTPS port.
    public var host: String {
        guard let components = URLComponents(string: origin), let host = components.host else { return origin }
        return components.port.map { $0 == 443 ? host : "\(host):\($0)" } ?? host
    }

    public var title: String { "Select a certificate" }

    public var message: String {
        identities.isEmpty
            ? "\(host) wants a certificate to identify you, and you have none it accepts."
            : "Select a certificate to identify yourself to \(host)."
    }

    /// Valid identities first, then by subject; the first one is preselected.
    public func sortedIdentities(now: Date = Date()) -> [ClientCertificateIdentity] {
        identities.sorted { a, b in
            let aExpired = a.isExpired(at: now), bExpired = b.isExpired(at: now)
            if aExpired != bExpired { return !aExpired }
            return a.subject.localizedStandardCompare(b.subject) == .orderedAscending
        }
    }
}
