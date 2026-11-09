import Foundation

/// A browser ReArc imports from by reading its files (PROFILE-IMPORT §1).
/// Chromium's own importer covers Safari, Firefox and bookmark files on
/// macOS, not other Chromium profiles, so these three are the shell's.
public enum ImportBrowser: String, CaseIterable, Identifiable, Codable, Sendable {
    case arc
    case chrome
    case brave

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .arc: return "Arc"
        case .chrome: return "Google Chrome"
        case .brave: return "Brave"
        }
    }

    /// Chromium user data, under `~/Library/Application Support`.
    public var userDataPath: String {
        switch self {
        case .arc: return "Arc/User Data"
        case .chrome: return "Google/Chrome"
        case .brave: return "BraveSoftware/Brave-Browser"
        }
    }

    /// Arc's own sidebar store, beside its user data; the others have none.
    public var sidebarPath: String? {
        self == .arc ? "Arc/\(ArcSidebarReader.fileName)" : nil
    }

    /// The Keychain item that holds the key for the browser's passwords and
    /// cookies (`<name> Safe Storage`, account `<name>`). The names are in
    /// Arc's engine, which imports from the other two the same way.
    public var safeStorageService: String { "\(safeStorageAccount) Safe Storage" }

    public var safeStorageAccount: String {
        switch self {
        case .arc: return "Arc"
        case .chrome: return "Chrome"
        case .brave: return "Brave"
        }
    }

    /// The app's preferences domain (Arc's settings live there).
    public var defaultsDomain: String {
        switch self {
        case .arc: return "company.thebrowser.Browser"
        case .chrome: return "com.google.Chrome"
        case .brave: return "com.brave.Browser"
        }
    }
}

/// One Chromium profile of a source browser.
public struct ImportSourceProfile: Identifiable, Hashable, Sendable {
    public var browser: ImportBrowser
    /// The profile's directory name (`Default`, `Profile 1`).
    public var directory: String
    /// The name the browser shows (Local State `profile.info_cache.<dir>.name`).
    public var name: String
    public var url: URL

    public var id: String { "\(browser.rawValue)/\(directory)" }

    public init(browser: ImportBrowser, directory: String, name: String, url: URL) {
        self.browser = browser
        self.directory = directory
        self.name = name
        self.url = url
    }
}

/// What a profile holds, as counts. Secrets are only noted as present:
/// counting passwords or cookies would mean opening their databases.
public struct ImportSourceInventory: Equatable, Sendable {
    public var bookmarks = 0
    /// Visible web pages in History; nil when the file is missing or unreadable.
    public var historyPages: Int?
    public var extensions = 0
    public var hasPasswords = false
    public var hasCookies = false
    public var hasAutofill = false

    public init() {}
}

/// A browser found on this Mac.
public struct DiscoveredBrowser: Identifiable, Sendable {
    public enum Status: Equatable, Sendable {
        case available
        /// Its folder exists but macOS refused to list it (privacy settings).
        case notReadable
    }

    public var browser: ImportBrowser
    public var status: Status
    public var profiles: [ImportSourceProfile]
    /// Arc's `StorableSidebar.json`, when this is Arc and it exists.
    public var sidebarFile: URL?

    public var id: ImportBrowser { browser }
}

/// Finds Arc, Chrome and Brave and their profiles. It only reads: lists
/// folders, parses Local State and counts. It runs when the Import window
/// opens, never at launch, so any macOS privacy prompt follows a click.
public enum BrowserImportDiscovery {
    /// `~/Library/Application Support` (a fixture folder in tests).
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static func discover(in applicationSupport: URL = applicationSupport,
                                fileManager: FileManager = .default) -> [DiscoveredBrowser] {
        ImportBrowser.allCases.compactMap { discover($0, in: applicationSupport, fileManager: fileManager) }
    }

    public static func discover(_ browser: ImportBrowser, in applicationSupport: URL,
                                fileManager: FileManager = .default) -> DiscoveredBrowser? {
        let root = applicationSupport.appendingPathComponent(browser.userDataPath, isDirectory: true)
        let sidebar = browser.sidebarPath.map { applicationSupport.appendingPathComponent($0) }
            .flatMap { fileManager.isReadableFile(atPath: $0.path) ? $0 : nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            // Arc's sidebar alone is still worth importing.
            return sidebar.map { DiscoveredBrowser(browser: browser, status: .available, profiles: [], sidebarFile: $0) }
        }
        guard (try? fileManager.contentsOfDirectory(atPath: root.path)) != nil else {
            return DiscoveredBrowser(browser: browser, status: .notReadable, profiles: [], sidebarFile: sidebar)
        }
        return DiscoveredBrowser(browser: browser, status: .available,
                                 profiles: profiles(of: browser, root: root, fileManager: fileManager), sidebarFile: sidebar)
    }

    /// Profiles in Local State order (`profiles_order`, then the rest by
    /// directory), keeping only those whose folder exists.
    public static func profiles(of browser: ImportBrowser, root: URL,
                                fileManager: FileManager = .default) -> [ImportSourceProfile] {
        let names = LocalState.read(root.appendingPathComponent("Local State"))
        var directories = names.order
        let listed = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in listed.sorted(by: directoryOrder) where isProfileDirectory(name) && !directories.contains(name) {
            directories.append(name)
        }
        return directories.compactMap { directory in
            let url = root.appendingPathComponent(directory, isDirectory: true)
            guard isProfileDirectory(directory), !names.internal.contains(directory),
                  fileManager.fileExists(atPath: url.appendingPathComponent("Preferences").path) else { return nil }
            let name = names.names[directory].flatMap { $0.isEmpty ? nil : $0 } ?? directory
            return ImportSourceProfile(browser: browser, directory: directory, name: name, url: url)
        }
    }

    static func isProfileDirectory(_ name: String) -> Bool {
        name == "Default" || (name.hasPrefix("Profile ") && Int(name.dropFirst(8)) != nil)
    }

    /// Default first, then Profile 1, 2, … by number.
    static func directoryOrder(_ a: String, _ b: String) -> Bool {
        func key(_ name: String) -> Int { name == "Default" ? -1 : Int(name.dropFirst(8)) ?? Int.max }
        return key(a) < key(b)
    }

    /// Counts what `profile` holds. Never opens Login Data, Cookies or Web Data.
    public static func inventory(of profile: ImportSourceProfile,
                                 fileManager: FileManager = .default) -> ImportSourceInventory {
        var inventory = ImportSourceInventory()
        let url = profile.url
        if let roots = try? ChromiumBookmarksReader.read(url.appendingPathComponent(ChromiumBookmarksReader.fileName)) {
            inventory.bookmarks = roots.reduce(0) { $0 + $1.linkCount }
        }
        inventory.historyPages = ChromiumHistoryReader.pageCount(url.appendingPathComponent(ChromiumHistoryReader.fileName))
        inventory.extensions = ExtensionInventoryReader.read(profile: url).filter { !$0.isComponent }.count
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: url.appendingPathComponent(name).path) }
        inventory.hasPasswords = exists("Login Data")
        inventory.hasCookies = exists("Cookies")
        inventory.hasAutofill = exists("Web Data")
        return inventory
    }

    /// Local State's profile names and order.
    struct LocalState {
        var names: [String: String] = [:]
        var order: [String] = []
        /// Profile folders the browser keeps for itself.
        var `internal`: Set<String> = []
        static let arcInternalPrefix = "__ARC_"

        static func read(_ url: URL) -> LocalState {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let profile = root["profile"] as? [String: Any] else { return LocalState() }
            var state = LocalState()
            for (directory, value) in profile["info_cache"] as? [String: Any] ?? [:] {
                let name = (value as? [String: Any])?["name"] as? String
                // Arc's own internal profile ("__ARC_SYSTEM_PROFILE") is nobody's to import.
                if name?.hasPrefix(Self.arcInternalPrefix) == true {
                    state.internal.insert(directory)
                    continue
                }
                state.names[directory] = name
            }
            state.order = (profile["profiles_order"] as? [String] ?? []).filter { state.names[$0] != nil }
            return state
        }
    }
}

/// Copies a SQLite file (and its write-ahead log) to a private temporary
/// folder, so the source browser's file is never opened or locked. Chrome
/// holds History open while it runs.
public struct SQLiteSnapshot {
    public let url: URL
    private let folder: URL

    public init(copying source: URL, fileManager: FileManager = .default) throws {
        folder = fileManager.temporaryDirectory.appendingPathComponent("ReArcImport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try fileManager.copyItem(at: source, to: url)
            for suffix in ["-wal", "-journal"] {
                let side = URL(fileURLWithPath: source.path + suffix)
                if fileManager.fileExists(atPath: side.path) {
                    try? fileManager.copyItem(at: side, to: URL(fileURLWithPath: url.path + suffix))
                }
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}
