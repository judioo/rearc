import Foundation

/// A browser ReArc imports from by reading its files (PROFILE-IMPORT §1).
/// Chromium's own importer covers Safari, Firefox and bookmark files on
/// macOS, not other Chromium profiles; the shell reads all of them itself,
/// so one window (and the onboarding) covers every browser on the Mac.
public enum ImportBrowser: String, CaseIterable, Identifiable, Codable, Sendable {
    case arc
    case chrome
    case chromeBeta
    case chromeDev
    case chromeCanary
    case brave
    case braveBeta
    case braveNightly
    case edge
    case edgeBeta
    case edgeDev
    case edgeCanary
    case vivaldi
    case vivaldiSnapshot
    case opera
    case operaGX
    case chromium
    case safari
    case firefox

    public var id: String { rawValue }

    /// How its data is laid out, and so which readers apply.
    public enum Family: Sendable {
        /// `Local State`, profile folders, `Bookmarks` JSON, `History` SQLite.
        case chromium
        /// `~/Library/Safari`: `Bookmarks.plist` (with the Reading List), `History.db`.
        case safari
        /// `profiles.ini`, each profile's `places.sqlite`.
        case firefox
    }

    public var family: Family {
        switch self {
        case .safari: return .safari
        case .firefox: return .firefox
        default: return .chromium
        }
    }

    public var name: String {
        switch self {
        case .arc: return "Arc"
        case .chrome: return "Google Chrome"
        case .chromeBeta: return "Google Chrome Beta"
        case .chromeDev: return "Google Chrome Dev"
        case .chromeCanary: return "Google Chrome Canary"
        case .brave: return "Brave"
        case .braveBeta: return "Brave Beta"
        case .braveNightly: return "Brave Nightly"
        case .edge: return "Microsoft Edge"
        case .edgeBeta: return "Microsoft Edge Beta"
        case .edgeDev: return "Microsoft Edge Dev"
        case .edgeCanary: return "Microsoft Edge Canary"
        case .vivaldi: return "Vivaldi"
        case .vivaldiSnapshot: return "Vivaldi Snapshot"
        case .opera: return "Opera"
        case .operaGX: return "Opera GX"
        case .chromium: return "Chromium"
        case .safari: return "Safari"
        case .firefox: return "Firefox"
        }
    }

    /// The onboarding's label beside its node ("Chrome", "Edge Beta").
    public var shortName: String {
        name.replacingOccurrences(of: "Google ", with: "").replacingOccurrences(of: "Microsoft ", with: "")
    }

    /// Its data, under `~/Library/Application Support`; Safari's is beside
    /// that folder, in `~/Library/Safari`.
    public var userDataPath: String {
        switch self {
        case .arc: return "Arc/User Data"
        case .chrome: return "Google/Chrome"
        case .chromeBeta: return "Google/Chrome Beta"
        case .chromeDev: return "Google/Chrome Dev"
        case .chromeCanary: return "Google/Chrome Canary"
        case .brave: return "BraveSoftware/Brave-Browser"
        case .braveBeta: return "BraveSoftware/Brave-Browser-Beta"
        case .braveNightly: return "BraveSoftware/Brave-Browser-Nightly"
        case .edge: return "Microsoft Edge"
        case .edgeBeta: return "Microsoft Edge Beta"
        case .edgeDev: return "Microsoft Edge Dev"
        case .edgeCanary: return "Microsoft Edge Canary"
        case .vivaldi: return "Vivaldi"
        case .vivaldiSnapshot: return "Vivaldi Snapshot"
        case .opera: return "com.operasoftware.Opera"
        case .operaGX: return "com.operasoftware.OperaGX"
        case .chromium: return "Chromium"
        case .safari: return "../Safari"
        case .firefox: return "Firefox"
        }
    }

    public func dataFolder(in applicationSupport: URL) -> URL {
        if self == .safari {
            return applicationSupport.deletingLastPathComponent().appendingPathComponent("Safari", isDirectory: true)
        }
        return applicationSupport.appendingPathComponent(userDataPath, isDirectory: true)
    }

    /// Opera keeps its main profile in the user data folder itself, not in `Default`.
    var keepsProfileAtRoot: Bool { self == .opera || self == .operaGX }

    /// Arc's own sidebar store, beside its user data; the others have none.
    public var sidebarPath: String? {
        self == .arc ? "Arc/\(ArcSidebarReader.fileName)" : nil
    }

    /// The Keychain item that holds the key for a Chromium browser's
    /// passwords and cookies (`<name> Safe Storage`, account `<name>`). The
    /// names are in Arc's engine, which imports from the others the same way.
    /// Safari and Firefox keep theirs elsewhere.
    public var safeStorageService: String { "\(safeStorageAccount) Safe Storage" }

    public var safeStorageAccount: String {
        switch self {
        case .arc: return "Arc"
        case .chrome, .chromeBeta, .chromeDev, .chromeCanary: return "Chrome"
        case .brave, .braveBeta, .braveNightly: return "Brave"
        case .edge, .edgeBeta, .edgeDev, .edgeCanary: return "Microsoft Edge"
        case .vivaldi, .vivaldiSnapshot: return "Vivaldi"
        case .opera: return "Opera"
        case .operaGX: return "Opera GX"
        case .chromium: return "Chromium"
        case .safari, .firefox: return name
        }
    }

    /// The app's bundle identifiers, first the one whose preferences domain
    /// is the browser's (Arc's settings live there).
    public var bundleIdentifiers: [String] {
        switch self {
        case .arc: return ["company.thebrowser.Browser"]
        case .chrome: return ["com.google.Chrome"]
        case .chromeBeta: return ["com.google.Chrome.beta"]
        case .chromeDev: return ["com.google.Chrome.dev"]
        case .chromeCanary: return ["com.google.Chrome.canary"]
        case .brave: return ["com.brave.Browser"]
        case .braveBeta: return ["com.brave.Browser.beta"]
        case .braveNightly: return ["com.brave.Browser.nightly"]
        case .edge: return ["com.microsoft.edgemac"]
        case .edgeBeta: return ["com.microsoft.edgemac.Beta"]
        case .edgeDev: return ["com.microsoft.edgemac.Dev"]
        case .edgeCanary: return ["com.microsoft.edgemac.Canary"]
        case .vivaldi: return ["com.vivaldi.Vivaldi"]
        case .vivaldiSnapshot: return ["com.vivaldi.Vivaldi.snapshot"]
        case .opera: return ["com.operasoftware.Opera"]
        case .operaGX: return ["com.operasoftware.OperaGX"]
        case .chromium: return ["org.chromium.Chromium"]
        case .safari: return ["com.apple.Safari"]
        case .firefox: return ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"]
        }
    }

    /// The app's preferences domain (Arc's settings live there).
    public var defaultsDomain: String { bundleIdentifiers[0] }

    /// The app's names in `/Applications`, for `isInstalledAtStandardLocation`.
    public var appNames: [String] {
        switch self {
        case .brave: return ["Brave Browser"]
        case .braveBeta: return ["Brave Browser Beta"]
        case .braveNightly: return ["Brave Browser Nightly"]
        case .firefox: return ["Firefox", "Firefox Developer Edition", "Firefox Nightly"]
        default: return [name]
        }
    }

    /// What macOS asks for before ReArc may read the browser's data.
    public var permission: ImportPermission { self == .safari ? .fullDiskAccess : .appData }

    /// Its app is in `/Applications` or `~/Applications`. The shell asks
    /// Launch Services instead (`NSWorkspace`); this is the fallback, which
    /// needs no AppKit.
    public var isInstalledAtStandardLocation: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return appNames.contains { app in
            ["/Applications", home].contains { FileManager.default.fileExists(atPath: "\($0)/\(app).app") }
        }
    }
}

/// The macOS privacy setting that lets ReArc read another app's files.
/// Opening a protected file fails with EPERM, and macOS shows no prompt
/// for it (TCC records `kTCCServiceSystemPolicyAppDataDetailed` as denied:
/// "does not allow prompting"), so the person has to switch it on.
public enum ImportPermission: String, Codable, Sendable {
    /// Another app's data folder (macOS 15 and later protect most browsers').
    /// Privacy & Security › Files & Folders lists it under ReArc once ReArc
    /// has tried; Full Disk Access covers it too.
    case appData
    /// `~/Library/Safari`, which only Full Disk Access opens.
    case fullDiskAccess

    /// Privacy & Security › Files & Folders, or › Full Disk Access.
    public var settingsURL: URL {
        switch self {
        case .appData: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        case .fullDiskAccess: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        }
    }

    /// The pane's name, as System Settings shows it.
    public var paneName: String {
        switch self {
        case .appData: return "Files & Folders"
        case .fullDiskAccess: return "Full Disk Access"
        }
    }

    /// macOS applies Full Disk Access to a running app only after it quits
    /// (System Settings offers "Quit & Reopen"); a Files & Folders switch
    /// usually applies at once.
    public var usuallyNeedsRelaunch: Bool { self == .fullDiskAccess }
}

/// Whether a file or folder can be opened, as `open(2)` / `opendir(3)` say.
public enum ImportAccess: Equatable, Sendable {
    case missing
    case readable
    /// EPERM (macOS privacy protection) or EACCES. `stat` still works, so
    /// the data is known to be there.
    case denied
}

/// Answers `ImportAccess` for a path; tests simulate a protected folder.
public typealias ImportAccessProbe = @Sendable (URL) -> ImportAccess

public enum ImportAccessProbes {
    /// Opens the item read-only and closes it at once; reads nothing.
    public static let system: ImportAccessProbe = { url in
        var info = stat()
        guard stat(url.path, &info) == 0 else { return .missing }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard let dir = opendir(url.path) else { return errno == ENOENT ? .missing : .denied }
            closedir(dir)
            return .readable
        }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { return errno == ENOENT ? .missing : .denied }
        close(fd)
        return .readable
    }
}

/// One profile of a source browser (Safari has one).
public struct ImportSourceProfile: Identifiable, Hashable, Sendable {
    public var browser: ImportBrowser
    /// The profile's directory name (`Default`, `Profile 1`; Firefox's
    /// `Path`, `Profiles/xxxx.default-release`).
    public var directory: String
    /// The name the browser shows (Local State `profile.info_cache.<dir>.name`, profiles.ini `Name`).
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

extension ImportSourceProfile {
    /// Its bookmarks, by its browser's reader.
    public func readBookmarks() throws -> [BookmarkNode] {
        switch browser.family {
        case .chromium: return try ChromiumBookmarksReader.read(url.appendingPathComponent(ChromiumBookmarksReader.fileName))
        case .safari: return try SafariBookmarksReader.read(url.appendingPathComponent(SafariBookmarksReader.fileName))
        case .firefox: return try FirefoxPlacesReader.bookmarks(url.appendingPathComponent(FirefoxPlacesReader.fileName))
        }
    }

    /// Its most recently visited web pages, newest first, from a copy.
    public func readHistory(limit: Int = VisitHistory.capacity) throws -> [VisitRecord] {
        switch browser.family {
        case .chromium: return try ChromiumHistoryReader.read(url.appendingPathComponent(ChromiumHistoryReader.fileName), limit: limit)
        case .safari: return try SafariHistoryReader.read(url.appendingPathComponent(SafariHistoryReader.fileName), limit: limit)
        case .firefox: return try FirefoxPlacesReader.history(url.appendingPathComponent(FirefoxPlacesReader.fileName), limit: limit)
        }
    }

    /// Pages in its history (visited since `after`); nil when it cannot be read.
    public func historyPageCount(after: Date? = nil) -> Int? {
        switch browser.family {
        case .chromium: return ChromiumHistoryReader.pageCount(url.appendingPathComponent(ChromiumHistoryReader.fileName), after: after)
        case .safari: return SafariHistoryReader.pageCount(url.appendingPathComponent(SafariHistoryReader.fileName), after: after)
        case .firefox: return FirefoxPlacesReader.pageCount(url.appendingPathComponent(FirefoxPlacesReader.fileName), after: after)
        }
    }

    /// Chromium profiles carry extensions and a `Preferences` setup.
    public var hasChromiumData: Bool { browser.family == .chromium }
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

/// A browser found on this Mac. One that is not installed and left no
/// data is not found at all.
public struct DiscoveredBrowser: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Its profiles can be read.
        case available
        /// Installed, but there is nothing to import yet (never opened, or no profile).
        case noProfiles
        /// Its data is there, but macOS refuses to open it until ReArc is
        /// allowed in System Settings.
        case blocked(ImportPermission)
    }

    public var browser: ImportBrowser
    public var status: Status
    public var profiles: [ImportSourceProfile]
    /// Arc's `StorableSidebar.json`, when this is Arc and it exists.
    public var sidebarFile: URL?

    public var id: ImportBrowser { browser }

    public var isBlocked: Bool {
        if case .blocked = status { return true }
        return false
    }

    public init(browser: ImportBrowser, status: Status, profiles: [ImportSourceProfile] = [], sidebarFile: URL? = nil) {
        self.browser = browser
        self.status = status
        self.profiles = profiles
        self.sidebarFile = sidebarFile
    }
}

/// Finds browsers and their profiles. It only reads: checks folders, parses
/// Local State or profiles.ini, and counts. It runs when the Import window
/// opens or the onboarding asks, never at a plain launch.
public enum BrowserImportDiscovery {
    /// `~/Library/Application Support` (a fixture folder in tests).
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Every browser that is installed or left data, in `ImportBrowser` order.
    /// `installed` defaults to the standard app folders; `probe` to `open(2)`.
    public static func discover(in applicationSupport: URL = applicationSupport,
                                fileManager: FileManager = .default,
                                installed: (ImportBrowser) -> Bool = { $0.isInstalledAtStandardLocation },
                                probe: ImportAccessProbe = ImportAccessProbes.system) -> [DiscoveredBrowser] {
        ImportBrowser.allCases.compactMap {
            discover($0, in: applicationSupport, fileManager: fileManager, installed: installed($0), probe: probe)
        }
    }

    /// One of four answers: nil (not installed, no data), `.noProfiles`,
    /// `.blocked` (macOS privacy protection) or `.available`.
    public static func discover(_ browser: ImportBrowser, in applicationSupport: URL,
                                fileManager: FileManager = .default, installed: Bool = false,
                                probe: ImportAccessProbe = ImportAccessProbes.system) -> DiscoveredBrowser? {
        let root = browser.dataFolder(in: applicationSupport)
        let sidebar = browser.sidebarPath.map { applicationSupport.appendingPathComponent($0) }
            .flatMap { probe($0) == .readable ? $0 : nil }
        let empty = installed ? DiscoveredBrowser(browser: browser, status: .noProfiles) : nil
        let blocked = DiscoveredBrowser(browser: browser, status: .blocked(browser.permission), sidebarFile: sidebar)
        // `stat` works on a protected folder, so "missing" is really missing.
        switch probe(root) {
        case .missing:
            // Arc's sidebar alone is still worth importing.
            return sidebar.map { DiscoveredBrowser(browser: browser, status: .available, sidebarFile: $0) } ?? empty
        case .denied:
            // `stat` still sees inside: a protected folder with no profile is not worth a permission.
            guard exists(root.appendingPathComponent(dataMarker(of: browser))) else { return sidebar.map {
                DiscoveredBrowser(browser: browser, status: .available, sidebarFile: $0) } ?? empty }
            return blocked
        case .readable:
            // A readable folder can still hold a protected file (Safari's, without Full Disk Access).
            if probe(root.appendingPathComponent(dataMarker(of: browser))) == .denied { return blocked }
        }
        let found = profiles(of: browser, root: root, fileManager: fileManager)
        if found.isEmpty, sidebar == nil { return empty }
        return DiscoveredBrowser(browser: browser, status: .available, profiles: found, sidebarFile: sidebar)
    }

    /// `stat` says it is there, or cannot tell (EACCES): only ENOENT is absence.
    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return stat(url.path, &info) == 0 || (errno != ENOENT && errno != ENOTDIR)
    }

    /// The file whose presence says the browser has made its profiles.
    static func dataMarker(of browser: ImportBrowser) -> String {
        switch browser.family {
        case .chromium: return browser.keepsProfileAtRoot ? "Preferences" : "Local State"
        case .safari: return SafariBookmarksReader.fileName
        case .firefox: return FirefoxProfiles.fileName
        }
    }

    /// Chromium profiles in Local State order (`profiles_order`, then the
    /// rest by directory), keeping only those whose folder exists; Safari's
    /// one; Firefox's from profiles.ini.
    public static func profiles(of browser: ImportBrowser, root: URL,
                                fileManager: FileManager = .default) -> [ImportSourceProfile] {
        switch browser.family {
        case .safari:
            let has = [SafariBookmarksReader.fileName, SafariHistoryReader.fileName].contains {
                fileManager.fileExists(atPath: root.appendingPathComponent($0).path)
            }
            return has ? [ImportSourceProfile(browser: browser, directory: "Default", name: browser.name, url: root)] : []
        case .firefox:
            return FirefoxProfiles.read(root: root, fileManager: fileManager)
        case .chromium:
            break
        }
        let names = LocalState.read(root.appendingPathComponent("Local State"))
        var directories = names.order
        let listed = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in listed.sorted(by: directoryOrder) where isProfileDirectory(name) && !directories.contains(name) {
            directories.append(name)
        }
        let found: [ImportSourceProfile] = directories.compactMap { directory in
            let url = root.appendingPathComponent(directory, isDirectory: true)
            guard isProfileDirectory(directory), !names.internal.contains(directory),
                  fileManager.fileExists(atPath: url.appendingPathComponent("Preferences").path) else { return nil }
            let name = names.names[directory].flatMap { $0.isEmpty ? nil : $0 } ?? directory
            return ImportSourceProfile(browser: browser, directory: directory, name: name, url: url)
        }
        if found.isEmpty, browser.keepsProfileAtRoot,
           fileManager.fileExists(atPath: root.appendingPathComponent("Preferences").path) {
            return [ImportSourceProfile(browser: browser, directory: "Default", name: browser.name, url: root)]
        }
        return found
    }

    public static func isProfileDirectory(_ name: String) -> Bool {
        name == "Default" || (name.hasPrefix("Profile ") && Int(name.dropFirst(8)) != nil)
    }

    /// Default first, then Profile 1, 2, … by number.
    static func directoryOrder(_ a: String, _ b: String) -> Bool {
        func key(_ name: String) -> Int { name == "Default" ? -1 : Int(name.dropFirst(8)) ?? Int.max }
        return key(a) < key(b)
    }

    /// Counts what `profile` holds. Never opens Login Data, Cookies or Web
    /// Data (Firefox: logins.json, cookies.sqlite, formhistory.sqlite); the
    /// import reads only Web Data's keywords (`ChromiumKeywordsReader`).
    public static func inventory(of profile: ImportSourceProfile,
                                 fileManager: FileManager = .default) -> ImportSourceInventory {
        var inventory = ImportSourceInventory()
        let url = profile.url
        if let roots = try? profile.readBookmarks() {
            inventory.bookmarks = roots.reduce(0) { $0 + $1.linkCount }
        }
        inventory.historyPages = profile.historyPageCount()
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: url.appendingPathComponent(name).path) }
        switch profile.browser.family {
        case .chromium:
            inventory.extensions = ExtensionInventoryReader.read(profile: url).filter { !$0.isComponent }.count
            inventory.hasPasswords = exists("Login Data")
            inventory.hasCookies = exists("Cookies")
            inventory.hasAutofill = exists("Web Data")
        case .firefox:
            inventory.hasPasswords = exists("logins.json")
            inventory.hasCookies = exists("cookies.sqlite")
            inventory.hasAutofill = exists("formhistory.sqlite")
        case .safari:
            // Safari's passwords and cookies are in the Keychain and its own containers.
            break
        }
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
            guard let root = try? ImportFile.json(url) as? [String: Any],
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
/// holds History open while it runs. Only regular files are copied, never
/// through a link (`copyItem` would copy a link as a link, and SQLite would
/// then open whatever it names: RC-0.1.0-602 T-08).
public struct SQLiteSnapshot {
    public let url: URL
    private let folder: URL

    public init(copying source: URL, fileManager: FileManager = .default) throws {
        folder = fileManager.temporaryDirectory.appendingPathComponent("ReArcImport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        url = folder.appendingPathComponent(source.lastPathComponent)
        do {
            try ImportFile.copy(source, to: url, maxBytes: ImportFile.maxDatabaseBytes)
            for suffix in ["-wal", "-journal"] {
                let side = URL(fileURLWithPath: source.path + suffix)
                var info = stat()
                if lstat(side.path, &info) == 0 {
                    try ImportFile.copy(side, to: URL(fileURLWithPath: url.path + suffix), maxBytes: ImportFile.maxDatabaseBytes)
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
