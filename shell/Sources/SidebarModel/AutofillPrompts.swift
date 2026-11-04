import CoreGraphics
import Foundation

// Autofill suggestions (engine ABI 1.34), local card/address save offers
// (1.37), HTTP authentication (1.38) and the password leak check preference
// (1.35). Chromium decides when suggestions show, fills, previews and routes
// the field's keys; the shell only draws. Pure, so row text, placement and
// prompt wording are testable without Chromium.

/// Chromium `FillingProduct` of a suggestion list.
public struct AutofillProduct: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let address = AutofillProduct(rawValue: 1)
    public static let creditCard = AutofillProduct(rawValue: 2)
    public static let iban = AutofillProduct(rawValue: 4)
    public static let autocomplete = AutofillProduct(rawValue: 5)
    public static let password = AutofillProduct(rawValue: 6)
    public static let datalist = AutofillProduct(rawValue: 12)
}

public enum AutofillRowKind: UInt32, Sendable {
    case fill = 0, manage, separator, other
}

/// One row as the engine sent it (`ReArcAutofillSuggestion`).
public struct AutofillSuggestionRow: Identifiable, Equatable, Sendable {
    /// The row's index in the engine's list (what Accept/Select take).
    public var id: Int
    public var value: String
    public var minor: String
    public var label: String
    public var icon: String
    public var kind: AutofillRowKind
    public var isAcceptable: Bool

    public init(id: Int, value: String, minor: String = "", label: String = "", icon: String = "",
                kind: AutofillRowKind = .fill, isAcceptable: Bool = true) {
        self.id = id
        self.value = value
        self.minor = minor
        self.label = label
        self.icon = icon
        self.kind = kind
        self.isAcceptable = isAcceptable
    }

    /// SF Symbol for the engine's icon name; nil draws no icon.
    public var symbolName: String? {
        if icon.hasPrefix("card") { return "creditcard" }
        switch icon {
        case "account": return "person.crop.circle"
        case "email": return "envelope"
        case "home": return "house"
        case "work": return "briefcase"
        case "location": return "mappin.and.ellipse"
        case "globe": return "globe"
        case "key", "password_manager": return "key"
        case "settings": return "gearshape"
        case "undo": return "arrow.uturn.backward"
        case "delete": return "trash"
        case "edit": return "pencil"
        case "iban": return "building.columns"
        case "other": return "text.badge.plus"
        default: return nil
        }
    }

    /// Card network for a `card_<network>` icon ("visa"), shown as a caption.
    public var cardNetwork: String? {
        guard icon.hasPrefix("card_") else { return nil }
        let network = String(icon.dropFirst("card_".count))
        switch network {
        case "amex": return "Amex"
        case "mastercard": return "Mastercard"
        case "unionpay": return "UnionPay"
        default: return network.prefix(1).uppercased() + network.dropFirst()
        }
    }
}

/// The suggestion list the shell draws for one field.
public struct AutofillPopup: Equatable, Sendable {
    public static let maskedPassword = "••••••••"

    public var requestID: UInt64
    public var tabID: UInt64
    public var product: AutofillProduct
    /// The field in the tab view's DIP coordinates, top-left origin.
    public var field: CGRect
    public var rows: [AutofillSuggestionRow]
    /// Keyboard selection (engine phase 2), nil for none.
    public var selected: Int?

    public init(requestID: UInt64, tabID: UInt64, product: AutofillProduct, field: CGRect,
                rows: [AutofillSuggestionRow], selected: Int? = nil) {
        self.requestID = requestID
        self.tabID = tabID
        self.product = product
        self.field = field
        self.rows = rows
        self.selected = selected
    }

    /// The text each row shows. Password rows never show anything that
    /// could be a password: the engine sends the username and Chromium's
    /// masked label, and the shell draws fixed bullets in place of the label.
    public func secondaryText(of row: AutofillSuggestionRow) -> String? {
        if product == .password, row.kind == .fill { return Self.maskedPassword }
        let parts = [row.minor, row.label].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.isEmpty { return row.cardNetwork }
        return parts.joined(separator: " · ")
    }

    public func primaryText(of row: AutofillSuggestionRow) -> String {
        let value = row.value.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { return value }
        return row.kind == .manage ? manageTitle : row.label
    }

    /// The footer's title when the engine left the row empty.
    public var manageTitle: String {
        switch product {
        case .address: return "Manage addresses…"
        case .creditCard, .iban: return "Manage payment methods…"
        case .password: return "Manage passwords…"
        default: return "Manage…"
        }
    }

    public var hasRows: Bool { rows.contains { $0.kind != .separator } }

    /// The index the next arrow key would select (wrapping, skipping separators and
    /// rows that cannot be accepted), for a host that routes keys itself.
    public func nextSelectable(from current: Int?, forward: Bool) -> Int? {
        let selectable = rows.filter { $0.kind != .separator && $0.isAcceptable }.map(\.id)
        guard !selectable.isEmpty else { return nil }
        guard let current, let index = selectable.firstIndex(of: current) else {
            return forward ? selectable.first : selectable.last
        }
        let next = forward ? index + 1 : index - 1
        return selectable[(next + selectable.count) % selectable.count]
    }
}

/// Size and position of the suggestion panel.
public enum AutofillPopupLayout {
    public static let rowHeight: CGFloat = 36
    public static let separatorHeight: CGFloat = 9
    public static let padding: CGFloat = 6
    public static let minimumWidth: CGFloat = 240
    public static let maximumWidth: CGFloat = 420
    /// Between the field and the panel.
    public static let gap: CGFloat = 2

    public static func size(for popup: AutofillPopup) -> CGSize {
        let height = popup.rows.reduce(padding * 2) { $0 + ($1.kind == .separator ? separatorHeight : rowHeight) }
        let width = min(max(popup.field.width, minimumWidth), maximumWidth)
        return CGSize(width: width, height: min(height, 420))
    }

    /// The panel's screen frame (bottom-left origin): below the field, or
    /// above it when the screen has no room below, kept on screen.
    /// `viewOnScreen` is the tab view's frame in screen coordinates.
    public static func frame(field: CGRect, viewOnScreen: CGRect, size: CGSize, screen: CGRect) -> CGRect {
        let fieldBottom = viewOnScreen.maxY - field.maxY
        let fieldTop = viewOnScreen.maxY - field.minY
        var y = fieldBottom - gap - size.height
        if y < screen.minY, fieldTop + gap + size.height <= screen.maxY {
            y = fieldTop + gap
        }
        y = min(max(y, screen.minY), screen.maxY - size.height)
        var x = viewOnScreen.minX + field.minX
        x = min(max(x, screen.minX), screen.maxX - size.width)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Chromium drops an accept within 500 ms of showing (`busy` from the
/// engine); the shell retries once the guard has passed.
public enum AutofillAcceptPolicy {
    public static let earlyAcceptGuard: TimeInterval = 0.55

    public static func retryDelay(shownAt: Date, now: Date = Date()) -> TimeInterval {
        max(0.05, earlyAcceptGuard - now.timeIntervalSince(shownAt) + 0.05)
    }
}

// MARK: - Local card and address save offers (ABI 1.37)

public enum AutofillSaveKind: UInt32, Sendable {
    case card = 0, address
}

/// `ReArcAutofillSaveRespond` action.
public enum AutofillSaveAction: UInt32, Sendable {
    case accept = 0, decline, ignore
}

/// Chromium's offer to keep a card or an address on this Mac. The summary
/// is display data (card network, last four, expiry, name; or the address);
/// no card number or CVC crosses the ABI.
public struct AutofillSaveOffer: Identifiable, Equatable, Sendable {
    public var id: UInt64
    public var kind: AutofillSaveKind
    public var isUpdate: Bool
    public var origin: String
    public var summary: String

    public init(id: UInt64, kind: AutofillSaveKind, isUpdate: Bool, origin: String, summary: String) {
        self.id = id
        self.kind = kind
        self.isUpdate = isUpdate
        self.origin = origin
        self.summary = summary
    }

    public var title: String {
        switch (kind, isUpdate) {
        case (.card, false): return "Save card?"
        case (.card, true): return "Update card?"
        case (.address, false): return "Save address?"
        case (.address, true): return "Update address?"
        }
    }

    public var acceptTitle: String { isUpdate ? "Update" : "Save" }
    public var symbol: String { kind == .card ? "creditcard.fill" : "house.fill" }

    /// The summary's lines, at most four.
    public var summaryLines: [String] {
        Array(summary.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.prefix(4))
    }

    public var footnote: String {
        kind == .card ? "Saved in ReArc on this Mac only. Never the security code." : "Saved in ReArc on this Mac only."
    }
}

// MARK: - HTTP authentication (ABI 1.38)

/// A Basic/Digest challenge for one tab. Credentials go back once and are
/// never stored by the shell; Chromium keeps its auth cache.
public struct HTTPAuthChallenge: Identifiable, Equatable, Sendable {
    /// The ABI's per-string limit.
    public static let maximumCredentialBytes = 4096

    public var id: UInt64
    /// scheme://host:port of the challenger.
    public var challenger: String
    public var scheme: String
    public var realm: String
    public var isProxy: Bool

    public init(id: UInt64, challenger: String, scheme: String, realm: String, isProxy: Bool) {
        self.id = id
        self.challenger = challenger
        self.scheme = scheme
        self.realm = realm
        self.isProxy = isProxy
    }

    public var title: String { isProxy ? "Sign in to the proxy" : "Sign in" }

    public var message: String {
        let who = isProxy ? "The proxy \(challenger)" : challenger
        return "\(who) requires a username and password."
    }

    /// The realm is the server's text; Chrome quotes it as such.
    public var realmNote: String? {
        let realm = realm.trimmingCharacters(in: .whitespacesAndNewlines)
        return realm.isEmpty ? nil : "The site says: “\(String(realm.prefix(120)))”"
    }

    /// Credentials sent over plain HTTP are readable on the network.
    public var isInsecure: Bool { challenger.lowercased().hasPrefix("http://") }

    public static func isValidCredential(_ value: String) -> Bool {
        value.utf8.count <= maximumCredentialBytes
    }
}

// MARK: - Password leak check (ABI 1.35)

/// ReArc > Check Passwords for Leaks. Chromium keeps the setting per
/// profile (on by default, as in Chrome); the shell remembers an explicit
/// choice and applies it to each profile as it opens.
public struct PasswordLeakDetectionPreference: Equatable, Sendable {
    public static let defaultsKey = "ReArcPasswordLeakDetection"

    /// nil: never changed in ReArc; profiles keep their own value.
    public var explicitChoice: Bool?

    public init(explicitChoice: Bool? = nil) {
        self.explicitChoice = explicitChoice
    }

    public static func load(from defaults: UserDefaults) -> PasswordLeakDetectionPreference {
        PasswordLeakDetectionPreference(explicitChoice: defaults.object(forKey: defaultsKey) as? Bool)
    }

    public func save(to defaults: UserDefaults) {
        if let explicitChoice { defaults.set(explicitChoice, forKey: Self.defaultsKey) } else { defaults.removeObject(forKey: Self.defaultsKey) }
    }

    /// The value a newly opened profile should get, if any.
    public func valueToApply(current: Bool, managed: Bool) -> Bool? {
        guard let explicitChoice, !managed, explicitChoice != current else { return nil }
        return explicitChoice
    }
}
