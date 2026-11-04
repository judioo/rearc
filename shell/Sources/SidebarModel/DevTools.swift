import Foundation

/// Where a tab's DevTools show (Arc docks them beside the page by default).
public enum DevToolsPlacement: String, Equatable, Sendable {
    /// A pane beside the page in the tab's window.
    case docked
    /// Their own window.
    case window
}

/// One tab's DevTools frontend: the engine's frontend tab and where it shows.
public struct DevToolsSession: Equatable, Sendable {
    /// The engine's frontend tab (Chromium registry ID); it closes when the page does.
    public var frontendTabID: UInt64
    public var placement: DevToolsPlacement

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
