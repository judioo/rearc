import Foundation

// Pure models behind the page-level prompts both engines raise: JavaScript
// dialogs, file choosers, permission requests, page context menus and
// password-save offers. Chromium delivers them over the ABI 1.18–1.22 host
// prompt channels (engine/docs/C-ABI.md "Host prompt channels"), WebKit
// through WKUIDelegate. The shell draws them; these types decide what is
// drawn and what is answered.

/// Serialized web origins ("https://example.com:8443") as engines report them.
public enum PageOrigin {
    /// The origin's host without `www.`, with a non-default port; nil for
    /// opaque origins ("null", data:, about:) and an empty string.
    public static func displayHost(_ origin: String) -> String? {
        guard let components = URLComponents(string: origin),
              let host = components.host, !host.isEmpty else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if let port = components.port { return "\(bare):\(port)" }
        return bare
    }

    /// `displayHost` for a prompt's wording: an insecure origin keeps its
    /// `http://`, so it never reads like the https site of the same name.
    public static func promptHost(_ origin: String) -> String? {
        guard let host = displayHost(origin) else { return nil }
        return URLComponents(string: origin)?.scheme?.lowercased() == "http" ? "http://" + host : host
    }

    /// A host for one line of trusted UI: whole labels from the right, the registrable domain
    /// always kept, and "…" in front of what was cut. A long host such as
    /// `accounts.google.com.verify-session.evil.example` then shows its real domain rather than
    /// its trusted-looking start (security RC-0.1.0-544 N-06). An `http://` prefix and a port stay.
    public static func shortenedHost(_ text: String, limit: Int = 36) -> String {
        guard text.count > limit else { return text }
        let scheme = text.hasPrefix("http://") ? "http://" : ""
        var host = String(text.dropFirst(scheme.count))
        var port = ""
        if let colon = host.lastIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber) {
            port = String(host[colon...])
            host = String(host[..<colon])
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let floor = BoostScopeMatcher.registrableDomain(host).split(separator: ".").count
        var kept = Array(labels.suffix(min(floor, labels.count)))
        for label in labels.dropLast(kept.count).reversed() {
            let candidate = ([label] + kept).joined(separator: ".")
            guard scheme.count + 1 + candidate.count + port.count <= limit else { break }
            kept.insert(label, at: 0)
        }
        let shown = kept.joined(separator: ".")
        return scheme + (kept.count < labels.count ? "…" : "") + shown + port
    }

    /// The origin of a page URL (scheme://host[:port]); nil without a host.
    public static func of(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }
}

// MARK: - JavaScript dialogs

/// `ReArcJavaScriptDialogEvent.kind` (0 alert, 1 confirm, 2 prompt, 3 beforeunload).
public enum JavaScriptDialogKind: UInt32, Sendable {
    case alert = 0, confirm, prompt, beforeUnload
}

/// One dialog a page asked for. `id` is the engine's request ID (WebKit
/// requests get shell-allocated IDs).
public struct JavaScriptDialogRequest: Identifiable, Equatable, Sendable {
    public var id: UInt64
    public var kind: JavaScriptDialogKind
    public var message: String
    public var defaultText: String
    /// Serialized origin of the frame that asked.
    public var origin: String
    /// beforeunload for a reload ("Reload site?") rather than leaving.
    public var isReload: Bool

    /// Long messages are shown scrollable, and capped like Chrome's dialog.
    public static let maxMessageLength = 10_000

    public init(id: UInt64, kind: JavaScriptDialogKind, message: String, defaultText: String = "", origin: String, isReload: Bool = false) {
        self.id = id
        self.kind = kind
        self.message = message
        self.defaultText = defaultText
        self.origin = origin
        self.isReload = isReload
    }

    public var title: String {
        if kind == .beforeUnload { return isReload ? "Reload site?" : "Leave site?" }
        return PageOrigin.promptHost(origin).map { "\($0) says" } ?? "This page says"
    }

    /// Page text is untrusted: shown as plain text, capped.
    public var displayMessage: String {
        if kind == .beforeUnload { return "Changes you made may not be saved." }
        return message.count > Self.maxMessageLength ? String(message.prefix(Self.maxMessageLength)) + "…" : message
    }

    public var acceptTitle: String {
        guard kind == .beforeUnload else { return "OK" }
        return isReload ? "Reload" : "Leave"
    }

    public var showsCancel: Bool { kind != .alert }
    public var showsTextField: Bool { kind == .prompt }
}

/// The answer the engine gets: `accept` (OK / Leave) and the prompt's text.
public struct JavaScriptDialogReply: Equatable, Sendable {
    public var accept: Bool
    public var text: String?

    public init(accept: Bool, text: String? = nil) {
        self.accept = accept
        self.text = text
    }

    /// Prompt text the ABI accepts (UTF-8, at most 64 KiB).
    public static let maxTextBytes = 64 * 1024

    /// A prompt reply clipped to the ABI limit on a character boundary.
    public static func prompt(_ text: String) -> JavaScriptDialogReply {
        guard text.utf8.count > maxTextBytes else { return JavaScriptDialogReply(accept: true, text: text) }
        var clipped = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > maxTextBytes { break }
            clipped.append(character)
            bytes += size
        }
        return JavaScriptDialogReply(accept: true, text: clipped)
    }
}

/// Chrome's "Don't allow this page to create more dialogs": per document,
/// from the second dialog on, the dialog offers to suppress the rest. A
/// suppressed page's dialogs are answered at once without UI. A new
/// document starts over.
public struct JavaScriptDialogGuard: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case present(offersSuppression: Bool)
        case suppress(JavaScriptDialogReply)
    }

    /// Dialogs shown on this document before the checkbox appears.
    public static let shownBeforeOffer = 1

    public private(set) var shownCount = 0
    public private(set) var isSuppressed = false
    public private(set) var suppressedCount = 0

    public init() {}

    public mutating func admit(_ kind: JavaScriptDialogKind) -> Decision {
        if isSuppressed {
            suppressedCount += 1
            return .suppress(Self.suppressedReply(for: kind))
        }
        // Leave-site prompts are never counted or suppressible from their own dialog.
        guard kind != .beforeUnload else { return .present(offersSuppression: false) }
        shownCount += 1
        return .present(offersSuppression: shownCount > Self.shownBeforeOffer)
    }

    public mutating func suppress() { isSuppressed = true }

    /// A new primary document.
    public mutating func reset() { self = JavaScriptDialogGuard() }

    /// alert is acknowledged, confirm and prompt are cancelled, and a
    /// suppressed page can always be left.
    public static func suppressedReply(for kind: JavaScriptDialogKind) -> JavaScriptDialogReply {
        switch kind {
        case .alert, .beforeUnload: return JavaScriptDialogReply(accept: true)
        case .confirm, .prompt: return JavaScriptDialogReply(accept: false)
        }
    }
}

// MARK: - File chooser

/// `ReArcFileChooserEvent.mode`.
public enum FileChooserMode: UInt32, Sendable {
    case open = 0, openMultiple, uploadFolder, openDirectory, save
}

/// A page's `accept` list split into extensions and MIME types, in the
/// page's order, lowercased and deduplicated.
public struct FileTypeFilter: Equatable, Sendable {
    /// Without the leading dot.
    public var extensions: [String] = []
    /// Full types ("application/pdf") and wildcards ("image/*").
    public var mimeTypes: [String] = []

    public init(acceptTypes: [String]) {
        for raw in acceptTypes {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if value.isEmpty { continue }
            if value.contains("/") {
                if !mimeTypes.contains(value) { mimeTypes.append(value) }
            } else {
                let ext = value.hasPrefix(".") ? String(value.dropFirst()) : value
                if !ext.isEmpty, !extensions.contains(ext) { extensions.append(ext) }
            }
        }
    }

    public var isEmpty: Bool { extensions.isEmpty && mimeTypes.isEmpty }
}

public struct FileChooserRequest: Identifiable, Equatable, Sendable {
    public var id: UInt64
    public var mode: FileChooserMode
    public var origin: String
    public var title: String
    /// A suggested file name or full path (save), or a starting directory.
    public var defaultPath: String
    public var acceptTypes: [String]

    public init(id: UInt64, mode: FileChooserMode, origin: String = "", title: String = "", defaultPath: String = "", acceptTypes: [String] = []) {
        self.id = id
        self.mode = mode
        self.origin = origin
        self.title = title
        self.defaultPath = defaultPath
        self.acceptTypes = acceptTypes
    }

    public var isSave: Bool { mode == .save }
    public var allowsMultipleSelection: Bool { mode == .openMultiple }
    public var choosesDirectories: Bool { mode == .uploadFolder || mode == .openDirectory }
    public var filter: FileTypeFilter { FileTypeFilter(acceptTypes: acceptTypes) }

    public var prompt: String {
        switch mode {
        case .open, .openMultiple: return "Open"
        case .uploadFolder: return "Upload"
        case .openDirectory: return "Select"
        case .save: return "Save"
        }
    }

    /// The panel's message line: the page's title, else who is asking.
    public var message: String? {
        if !title.isEmpty { return title }
        guard let host = PageOrigin.promptHost(origin) else { return nil }
        switch mode {
        case .uploadFolder: return "Choose a folder to upload to \(host). Every file in it will be shared."
        case .openDirectory: return "Choose a folder for \(host)."
        case .save: return nil
        case .open, .openMultiple: return "Choose a file to upload to \(host)."
        }
    }

    /// For save: the folder and file name the panel opens with.
    public func saveDefaults(fallbackDirectory: String) -> (directory: String, fileName: String) {
        let path = defaultPath
        guard !path.isEmpty else { return (fallbackDirectory, "") }
        guard path.hasPrefix("/") else { return (fallbackDirectory, (path as NSString).lastPathComponent) }
        let name = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        return (directory.isEmpty ? fallbackDirectory : directory, name)
    }
}

/// What `ReArcFileChooserRespond` accepts: absolute UTF-8 paths without
/// parent references, at most 4096 of them and 4096 bytes each, and one
/// path unless the mode is open-multiple. The shell never sends a reply the
/// engine would reject (an invalid reply leaves the request pending).
public enum FileChooserReply {
    public static let maxPaths = 4096
    public static let maxPathBytes = 4096

    public static func validPaths(_ paths: [String], mode: FileChooserMode) -> [String]? {
        guard !paths.isEmpty, paths.count <= (mode == .openMultiple ? maxPaths : 1) else { return nil }
        for path in paths {
            guard path.hasPrefix("/"), path.utf8.count <= maxPathBytes,
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { return nil }
        }
        return paths
    }
}

// MARK: - Permissions

/// One Chromium `PermissionKeyForRequestType` name (ABI 1.20) and how the
/// prompt words it. WebKit media requests use the same keys.
public struct PermissionType: Hashable, Sendable {
    public var key: String

    public init(_ key: String) { self.key = key }

    public static let camera = PermissionType("camera_stream")
    public static let microphone = PermissionType("mic_stream")
    public static let geolocation = PermissionType("geolocation")
    public static let notifications = PermissionType("notifications")
    public static let clipboard = PermissionType("clipboard")

    /// What the site wants to do ("Use your camera").
    public var phrase: String {
        switch key {
        case "camera_stream": return "Use your camera"
        case "mic_stream": return "Use your microphone"
        case "camera_pan_tilt_zoom": return "Move your camera"
        case "geolocation": return "Know your location"
        case "notifications": return "Show notifications"
        case "clipboard": return "See text and images copied to the clipboard"
        case "midi_sysex": return "Control and reprogram your MIDI devices"
        case "sensors": return "Use your device's motion sensors"
        case "storage_access", "top_level_storage_access": return "Use cookies and site data it saved on other sites"
        case "local_fonts": return "Use the fonts on your computer"
        case "idle_detection": return "Know when you're actively using this device"
        case "multiple_downloads": return "Download multiple files"
        case "window_management": return "Manage windows on all your displays"
        case "pointer_lock": return "Hide and lock your pointer"
        case "keyboard_lock": return "Take over your keyboard"
        case "protected_media_identifier": return "Play protected content"
        case "local_network", "loopback_network": return "Find and connect to devices on your local network"
        case "file_system": return "Edit files on your computer"
        case "ar_session", "vr_session": return "Use your virtual reality devices"
        case "hand_tracking": return "Track your hands"
        case "nfc_device": return "Use NFC devices"
        case "register_protocol_handler": return "Open web links of a type"
        case "web_printing": return "Print to your printers"
        case "smart_card": return "Use your smart card readers"
        default:
            let words = key.replacingOccurrences(of: "_", with: " ")
            return "Use \(words)"
        }
    }

    /// Short name for the site-permissions list ("Camera").
    public var name: String {
        switch key {
        case "camera_stream": return "Camera"
        case "mic_stream": return "Microphone"
        case "camera_pan_tilt_zoom": return "Camera movement"
        case "geolocation": return "Location"
        case "notifications": return "Notifications"
        case "clipboard": return "Clipboard"
        case "midi_sysex": return "MIDI devices"
        case "multiple_downloads": return "Automatic downloads"
        default:
            let words = key.replacingOccurrences(of: "_", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// SF Symbol for the prompt and the indicator.
    public var symbol: String {
        switch key {
        case "camera_stream", "camera_pan_tilt_zoom": return "video.fill"
        case "mic_stream": return "mic.fill"
        case "geolocation": return "location.fill"
        case "notifications": return "bell.fill"
        case "clipboard": return "doc.on.clipboard"
        case "midi_sysex": return "pianokeys"
        case "multiple_downloads": return "arrow.down.circle"
        case "local_network", "loopback_network": return "network"
        case "pointer_lock": return "cursorarrow"
        case "keyboard_lock": return "keyboard"
        default: return "hand.raised.fill"
        }
    }

    /// Types macOS also authorizes per app (TCC); a site grant alone is not enough.
    public var needsSystemAuthorization: Bool {
        ["camera_stream", "mic_stream", "camera_pan_tilt_zoom", "geolocation"].contains(key)
    }
}

/// `ReArcPermissionRespond` decision (0 allow, 1 deny, 2 dismiss).
public enum PermissionDecision: UInt32, Codable, Sendable {
    case allow = 0, deny, dismiss
}

/// One permission prompt; a coalesced camera+microphone request is one prompt.
public struct PermissionPromptRequest: Identifiable, Equatable, Sendable {
    public var id: UInt64
    public var origin: String
    public var embeddingOrigin: String
    public var types: [PermissionType]

    public init(id: UInt64, origin: String, embeddingOrigin: String = "", types: [PermissionType]) {
        self.id = id
        self.origin = origin
        self.embeddingOrigin = embeddingOrigin
        self.types = types
    }

    public var host: String { PageOrigin.promptHost(origin) ?? "This page" }

    /// "Use your camera and microphone", or one line per type.
    public var phrases: [String] {
        let keys = Set(types.map(\.key))
        if keys == ["camera_stream", "mic_stream"] { return ["Use your camera and microphone"] }
        return types.map(\.phrase)
    }

    public var symbol: String {
        let keys = Set(types.map(\.key))
        if keys.contains("camera_stream") { return PermissionType.camera.symbol }
        return types.first?.symbol ?? "hand.raised.fill"
    }

    /// An iframe asking on behalf of a different top-level site.
    public var embeddedNote: String? {
        guard !embeddingOrigin.isEmpty, embeddingOrigin != origin,
              let embedder = PageOrigin.promptHost(embeddingOrigin) else { return nil }
        return "Embedded in \(embedder)"
    }

    public var needsSystemAuthorization: Bool { types.contains(where: \.needsSystemAuthorization) }
}

/// The shell's record of permission answers, per profile scope and site.
/// It drives the URL field's site-permissions indicator on both engines.
/// On WebKit it is also the permission store: remembered answers are
/// replayed without prompting. On Chromium, Chromium's own
/// HostContentSettingsMap holds remembered answers and chrome://settings
/// resets them; this record only mirrors what was answered here.
public struct SitePermissionStore: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var decision: PermissionDecision
        /// Remembered (sent with persist) rather than this time only.
        public var remembered: Bool
        public var date: Date

        public init(decision: PermissionDecision, remembered: Bool, date: Date) {
            self.decision = decision
            self.remembered = remembered
            self.date = date
        }
    }

    public var version = 1
    /// scope (profile UUID, or `private:<session>`) -> origin -> type key -> entry.
    public private(set) var scopes: [String: [String: [String: Entry]]] = [:]

    public init() {}

    public static let fileName = "SitePermissions.json"

    /// Scopes that start with this prefix are never written to disk.
    public static let ephemeralPrefix = "private:"

    public mutating func record(_ decision: PermissionDecision, remembered: Bool, types: [PermissionType], origin: String, scope: String, now: Date = Date()) {
        guard decision != .dismiss, !origin.isEmpty else { return }
        for type in types {
            scopes[scope, default: [:]][origin, default: [:]][type.key] = Entry(decision: decision, remembered: remembered, date: now)
        }
    }

    public func entries(origin: String, scope: String) -> [(type: PermissionType, entry: Entry)] {
        (scopes[scope]?[origin] ?? [:])
            .map { (PermissionType($0.key), $0.value) }
            .sorted { $0.type.name < $1.type.name }
    }

    /// A remembered answer that covers every requested type, if they agree.
    public func rememberedDecision(for types: [PermissionType], origin: String, scope: String) -> PermissionDecision? {
        let site = scopes[scope]?[origin] ?? [:]
        let decisions = types.map { site[$0.key].flatMap { $0.remembered ? $0.decision : nil } }
        guard let first = decisions.first, let decision = first, decisions.allSatisfy({ $0 == decision }) else { return nil }
        return decision
    }

    public mutating func reset(origin: String, scope: String, type: PermissionType? = nil) {
        if let type {
            scopes[scope]?[origin]?[type.key] = nil
            if scopes[scope]?[origin]?.isEmpty == true { scopes[scope]?[origin] = nil }
        } else {
            scopes[scope]?[origin] = nil
        }
        if scopes[scope]?.isEmpty == true { scopes[scope] = nil }
    }

    /// Forgets this-time-only answers (a new document may prompt again) and private scopes.
    public mutating func dropScope(_ scope: String) { scopes[scope] = nil }

    /// What is saved: remembered answers of persistent scopes only.
    public var persistable: SitePermissionStore {
        var copy = SitePermissionStore()
        for (scope, sites) in scopes where !scope.hasPrefix(Self.ephemeralPrefix) {
            for (origin, types) in sites {
                for (key, entry) in types where entry.remembered {
                    copy.scopes[scope, default: [:]][origin, default: [:]][key] = entry
                }
            }
        }
        return copy
    }

    public static func load(from url: URL) -> SitePermissionStore {
        guard let data = try? Data(contentsOf: url) else { return SitePermissionStore() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SitePermissionStore.self, from: data)) ?? SitePermissionStore()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(persistable)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Page context menu

/// What was right-clicked, from `ReArcContextMenuEvent` (Chromium) or the
/// page's `contextmenu` event (WebKit).
public struct PageContextMenuParams: Equatable, Sendable {
    /// Blink `ContextMenuDataMediaType`.
    public enum MediaType: UInt32, Sendable {
        case none = 0, image, video, audio, canvas, file, plugin
    }

    /// Blink `ContextMenuDataEditFlags`.
    public struct EditFlags: OptionSet, Equatable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let canUndo = EditFlags(rawValue: 0x1)
        public static let canRedo = EditFlags(rawValue: 0x2)
        public static let canCut = EditFlags(rawValue: 0x4)
        public static let canCopy = EditFlags(rawValue: 0x8)
        public static let canPaste = EditFlags(rawValue: 0x10)
        public static let canDelete = EditFlags(rawValue: 0x20)
        public static let canSelectAll = EditFlags(rawValue: 0x40)
    }

    public var linkURL: String
    public var srcURL: String
    public var selectionText: String
    public var pageURL: String
    public var frameURL: String
    public var mediaType: MediaType
    public var editFlags: EditFlags
    public var isEditable: Bool
    public var hasImageContents: Bool

    public init(
        linkURL: String = "", srcURL: String = "", selectionText: String = "", pageURL: String = "", frameURL: String = "",
        mediaType: MediaType = .none, editFlags: EditFlags = [], isEditable: Bool = false, hasImageContents: Bool = false
    ) {
        self.linkURL = linkURL
        self.srcURL = srcURL
        self.selectionText = selectionText
        self.pageURL = pageURL
        self.frameURL = frameURL
        self.mediaType = mediaType
        self.editFlags = editFlags
        self.isEditable = isEditable
        self.hasImageContents = hasImageContents
    }

    /// Page-sourced opens are limited to web URLs.
    public var openableLink: URL? { Self.openable(linkURL) }
    public var openableImage: URL? { mediaType == .image ? Self.openable(srcURL) : nil }
    public var trimmedSelection: String { selectionText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func openable(_ string: String) -> URL? {
        guard !string.isEmpty, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil, NavigationURLPolicy.allows(url) else { return nil }
        return url
    }
}

/// Items of the page context menu. Chromium runs the engine ones through
/// `ReArcContextMenuCommand`; the Arc ones are the shell's.
public enum PageContextMenuItem: Equatable, Sendable {
    case openLinkInNewTab
    case openLinkInNewWindow
    case openLinkInNewSplit
    case openLinkInLittleArc
    case openLinkInPrivateWindow
    case saveLinkAs
    case copyLink
    case openImageInNewTab
    case saveImage
    case copyImage
    case copyImageAddress
    /// "Search <engine> for Image": the engine's name.
    case searchImage(String)
    case searchFor(String)
    case cut
    case copy
    case paste
    case selectAll
    case back
    case forward
    case reload
    case viewSource
    case inspect

    public var title: String {
        switch self {
        case .openLinkInNewTab: return "Open Link in New Tab"
        case .openLinkInNewWindow: return "Open Link in New Window"
        case .openLinkInNewSplit: return "Open Link in Split View"
        case .openLinkInLittleArc: return "Open Link in Little ReArc"
        case .openLinkInPrivateWindow: return "Open Link in Private Window"
        case .saveLinkAs: return "Save Link As…"
        case .copyLink: return "Copy Link Address"
        case .openImageInNewTab: return "Open Image in New Tab"
        case .saveImage: return "Save Image As…"
        case .copyImage: return "Copy Image"
        case .copyImageAddress: return "Copy Image Address"
        case .searchImage(let engine): return "Search \(engine) for Image"
        case .searchFor(let text): return "Search for “\(PageContextMenuPlan.truncated(text))”"
        case .cut: return "Cut"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .selectAll: return "Select All"
        case .back: return "Back"
        case .forward: return "Forward"
        case .reload: return "Reload"
        case .viewSource: return "View Page Source"
        case .inspect: return "Inspect"
        }
    }
}

public struct PageContextMenuPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var item: PageContextMenuItem
        public var isEnabled: Bool
    }

    /// Sections, separated in the menu.
    public var sections: [[Entry]]

    public var items: [PageContextMenuItem] { sections.flatMap { $0.map(\.item) } }

    public func entry(_ item: PageContextMenuItem) -> Entry? {
        sections.joined().first { $0.item == item }
    }

    /// What the host can do besides the engine's commands.
    public struct Options: Equatable, Sendable {
        public var canGoBack = false
        public var canGoForward = false
        public var canOpenLittleArc = true
        public var canOpenSplit = true
        /// A new browser window, and a private window: not from a private window's page.
        public var canOpenWindow = true
        public var canOpenPrivateWindow = true
        /// Engine Save Link As (Chromium ABI 1.64 `context_menu_save_link`).
        public var canSaveLink = false
        /// The default search engine's name when it can search by image.
        public var imageSearchName: String?
        public var canViewSource = false
        /// Engine inspection (ABI 1.21 `inspect` is unsupported until a DevTools frontend lands).
        public var canInspect = false
        /// Show Inspect (disabled) at all when it cannot run.
        public var showsDisabledInspect = true

        public init(
            canGoBack: Bool = false, canGoForward: Bool = false, canOpenLittleArc: Bool = true, canOpenSplit: Bool = true,
            canOpenWindow: Bool = true, canOpenPrivateWindow: Bool = true, canSaveLink: Bool = false, imageSearchName: String? = nil,
            canViewSource: Bool = false, canInspect: Bool = false, showsDisabledInspect: Bool = true
        ) {
            self.canGoBack = canGoBack
            self.canGoForward = canGoForward
            self.canOpenLittleArc = canOpenLittleArc
            self.canOpenSplit = canOpenSplit
            self.canOpenWindow = canOpenWindow
            self.canOpenPrivateWindow = canOpenPrivateWindow
            self.canSaveLink = canSaveLink
            self.imageSearchName = imageSearchName
            self.canViewSource = canViewSource
            self.canInspect = canInspect
            self.showsDisabledInspect = showsDisabledInspect
        }
    }

    /// Arc's variants, in its order: link, image, selection / editable,
    /// else the page itself; Inspect last.
    public static func plan(for params: PageContextMenuParams, options: Options) -> PageContextMenuPlan {
        var sections: [[Entry]] = []
        func on(_ item: PageContextMenuItem, _ enabled: Bool = true) -> Entry { Entry(item: item, isEnabled: enabled) }

        let link = params.openableLink
        if link != nil {
            var section = [on(.openLinkInNewTab)]
            if options.canOpenWindow { section.append(on(.openLinkInNewWindow)) }
            if options.canOpenSplit { section.append(on(.openLinkInNewSplit)) }
            if options.canOpenLittleArc { section.append(on(.openLinkInLittleArc)) }
            if options.canOpenPrivateWindow { section.append(on(.openLinkInPrivateWindow)) }
            sections.append(section)
            sections.append(options.canSaveLink ? [on(.saveLinkAs), on(.copyLink)] : [on(.copyLink)])
        }
        let isImage = params.mediaType == .image || params.mediaType == .canvas
        if isImage {
            var section: [Entry] = []
            if params.openableImage != nil { section.append(on(.openImageInNewTab)) }
            section.append(on(.saveImage, params.hasImageContents))
            section.append(on(.copyImage, params.hasImageContents))
            if params.openableImage != nil {
                section.append(on(.copyImageAddress))
                if let engine = options.imageSearchName { section.append(on(.searchImage(engine))) }
            }
            sections.append(section)
        }
        let selection = params.trimmedSelection
        if params.isEditable {
            sections.append([
                on(.cut, params.editFlags.contains(.canCut)),
                on(.copy, params.editFlags.contains(.canCopy)),
                on(.paste, params.editFlags.contains(.canPaste)),
            ])
            if !selection.isEmpty { sections.append([on(.searchFor(selection))]) }
            sections.append([on(.selectAll, params.editFlags.contains(.canSelectAll))])
        } else if !selection.isEmpty {
            sections.append([on(.copy, params.editFlags.contains(.canCopy)), on(.searchFor(selection))])
        }
        if link == nil, !isImage, selection.isEmpty, !params.isEditable {
            sections.append([on(.back, options.canGoBack), on(.forward, options.canGoForward), on(.reload)])
            var page: [Entry] = [on(.selectAll, params.editFlags.contains(.canSelectAll))]
            if options.canViewSource { page.append(on(.viewSource)) }
            sections.append(page)
        }
        if options.canInspect || options.showsDisabledInspect {
            sections.append([on(.inspect, options.canInspect)])
        }
        return PageContextMenuPlan(sections: sections.filter { !$0.isEmpty })
    }

    /// Selection shown in "Search for …": one line, at most 30 characters.
    public static func truncated(_ text: String, limit: Int = 30) -> String {
        let line = text.split(whereSeparator: \.isNewline).map(String.init).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}

// MARK: - Password save offers

/// `ReArcPasswordPromptRespond` action (0 save or update, 1 never, 2 dismiss).
public enum PasswordPromptAction: UInt32, Sendable {
    case save = 0, never, notNow
}

/// A save/update offer. No password crosses the ABI: the shell only ever
/// sees the origin and username, and Chromium owns the store.
public struct PasswordSavePrompt: Identifiable, Equatable, Sendable {
    public var id: UInt64
    public var origin: String
    public var username: String
    public var isUpdate: Bool

    public init(id: UInt64, origin: String, username: String, isUpdate: Bool) {
        self.id = id
        self.origin = origin
        self.username = username
        self.isUpdate = isUpdate
    }

    public var title: String {
        let host = PageOrigin.promptHost(origin) ?? "this site"
        return isUpdate ? "Update password for \(host)?" : "Save password for \(host)?"
    }

    public var saveTitle: String { isUpdate ? "Update" : "Save" }
    public var displayUsername: String { username.isEmpty ? "No username" : username }
}
