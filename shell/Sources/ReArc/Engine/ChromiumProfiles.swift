import Foundation
import SidebarModel

/// The engine profile a Chromium tab is created in (C-ABI.md "Profiles").
///
/// A shell `Profile` owns its Spaces, and every Space uses its profile's
/// storage, so each shell profile maps onto one named persistent engine
/// profile. A private window maps onto one off-the-record engine profile
/// under the persistent profile it was opened from. Engine profile IDs are
/// session-local and never persisted; only the storage key is stable.
enum ChromiumProfileKey: Hashable, CustomStringConvertible {
    case persistent(Profile.ID)
    /// One in-memory context per private session; `parent` is the persistent profile.
    case offTheRecord(session: UUID, parent: Profile.ID)

    /// An ephemeral context maps to the off-the-record profile of
    /// `privateSession`; every engine of one private session shares it.
    init(context: EngineProfileContext, privateSession: UUID) {
        if context.isEphemeral {
            self = .offTheRecord(session: privateSession, parent: context.profileID)
        } else {
            self = .persistent(context.profileID)
        }
    }

    var parentProfileID: Profile.ID {
        switch self {
        case .persistent(let id): return id
        case .offTheRecord(_, let parent): return parent
        }
    }

    var isOffTheRecord: Bool {
        if case .offTheRecord = self { return true }
        return false
    }

    /// `ReArcProfileOpen` name for a persistent profile: the lowercased shell
    /// profile UUID (36 ASCII characters, `[a-f0-9-]`).
    var storageKey: String? {
        guard case .persistent(let id) = self else { return nil }
        return Self.storageKey(for: id)
    }

    static func storageKey(for profileID: Profile.ID) -> String {
        profileID.uuidString.lowercased()
    }

    /// The engine's key rule: case-sensitive `[A-Za-z0-9_-]{1,64}`, never a path.
    static func isValidStorageKey(_ key: String) -> Bool {
        guard (1...64).contains(key.utf8.count) else { return false }
        return key.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F
        }
    }

    var description: String {
        switch self {
        case .persistent(let id): return "profile \(Self.storageKey(for: id))"
        case .offTheRecord(let session, let parent):
            return "private session \(session.uuidString.lowercased()) of \(Self.storageKey(for: parent))"
        }
    }
}

/// Profile teardown order. The engine refuses to close a parent while any
/// off-the-record child is alive (busy), so children close first, one at a
/// time, then the parent.
enum ChromiumProfileTeardown {
    static func closeOrder(for key: ChromiumProfileKey, among open: [ChromiumProfileKey]) -> [ChromiumProfileKey] {
        switch key {
        case .offTheRecord:
            return [key]
        case .persistent(let id):
            let children = open.filter { $0.isOffTheRecord && $0.parentProfileID == id }
            return children + [key]
        }
    }
}

/// Where a persistent shell profile's Chromium data lives (C-ABI.md 1.13).
/// Engine IDs are never persisted; this is the stable reference.
enum ChromiumProfileStorage: Equatable {
    /// `ReArcProfileOpen` under the lowercased shell UUID (`ReArcProfile-<hex>`).
    case named(String)
    /// `ReArcProfileOpenDirectory`: an existing directory opened in place.
    case directory(String)
}

/// Persisted beside the engine data (`ReArcProfileStorage.json` in the
/// user-data-dir): which shell profile owns an existing directory, and the
/// one-time decision about the startup `Default` directory left by builds
/// that predate named profiles. Absent from `directories` means named.
struct ChromiumProfileStorageMap: Codable, Equatable {
    enum LegacyDefault: String, Codable {
        /// `Default` was opened in place for the owner in `directories`.
        case adopted
        /// The first profile already had named data; it keeps it, and Default is left alone.
        case keptNamed
    }

    static let fileName = "ReArcProfileStorage.json"
    static let defaultDirectory = "Default"

    var version = 1
    /// Lowercased shell profile UUID to directory token.
    var directories: [String: String] = [:]
    /// nil until an engine with `profile_directory` has decided.
    var legacyDefault: LegacyDefault?

    func storage(for profileID: Profile.ID) -> ChromiumProfileStorage {
        let key = ChromiumProfileKey.storageKey(for: profileID)
        return directories[key].map(ChromiumProfileStorage.directory) ?? .named(key)
    }

    /// Records a successful directory open (and, for Default, the decision).
    mutating func recordDirectory(_ token: String, for profileID: Profile.ID) {
        directories[ChromiumProfileKey.storageKey(for: profileID)] = token
        if token == Self.defaultDirectory { legacyDefault = .adopted }
    }

    /// The map on disk; missing or unreadable files start empty (the plan is
    /// idempotent, so re-deciding reaches the same storage).
    static func load(from url: URL) -> ChromiumProfileStorageMap {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode(ChromiumProfileStorageMap.self, from: data) else {
            return ChromiumProfileStorageMap()
        }
        return map
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// How the runtime opens one persistent profile. Only the first shell
/// profile may take over `Default`, only once, and never when it already has
/// named data: nothing is merged or silently replaced, and no directory is
/// moved, copied or deleted.
enum ChromiumProfileStoragePlan: Equatable {
    case named(String)
    case directory(String)
    /// ABI 1.10–1.12 fallback for a recorded `Default` mapping: the engine's
    /// startup profile is that directory when no other one was selected.
    case startupProfile
    /// Open `Default` in place; record the mapping only if the open succeeds.
    case adoptDefault
    /// Open named and record `keptNamed`: the profile's named directory exists.
    case keepNamed(String)
    /// A recorded directory this engine cannot open; never a fresh named profile.
    case unsupported(String)

    struct Engine: Equatable {
        /// `profile_directory` (ABI 1.13).
        var canOpenDirectory: Bool
        /// `--profile-directory` the engine started with (`Default` unless supplied).
        var startupDirectory: String
    }

    static func plan(
        for profileID: Profile.ID,
        map: ChromiumProfileStorageMap,
        legacyOwner: Profile.ID?,
        engine: Engine,
        namedDirectoryExists: (String) -> Bool
    ) -> ChromiumProfileStoragePlan {
        switch map.storage(for: profileID) {
        case .directory(let token):
            if engine.canOpenDirectory { return .directory(token) }
            return token == engine.startupDirectory ? .startupProfile : .unsupported(token)
        case .named(let key):
            guard engine.canOpenDirectory, map.legacyDefault == nil, profileID == legacyOwner,
                  engine.startupDirectory == ChromiumProfileStorageMap.defaultDirectory else { return .named(key) }
            return namedDirectoryExists(namedDirectoryName(forKey: key)) ? .keepNamed(key) : .adoptDefault
        }
    }

    /// The engine's directory for a named key: `ReArcProfile-` plus the
    /// uppercase hex of the ASCII key (C-ABI.md "Profiles").
    static func namedDirectoryName(forKey key: String) -> String {
        "ReArcProfile-" + key.utf8.map { String(format: "%02X", $0) }.joined()
    }

    /// `ReArcProfileOpenDirectory` token syntax: one ASCII basename of 1–128
    /// bytes, letters, digits, `_`, `-` and interior spaces.
    static func isValidDirectoryToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard (1...128).contains(bytes.count), bytes.first != 0x20, bytes.last != 0x20 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D || byte == 0x5F || byte == 0x20
        }
    }
}

/// Whether `ReArcEngineShutdown` must wait (C-ABI.md 1.12). An accepted
/// ProfileClose always makes shutdown busy; standalone tab closes do only on
/// engines without `shutdown_pending_closes`.
enum ChromiumShutdownGate {
    static func mustDefer(profileCloseInFlight: Bool, tabClosesInFlight: Int, engineJoinsTabCloses: Bool) -> Bool {
        profileCloseInFlight || (!engineJoinsTabCloses && tabClosesInFlight > 0)
    }
}
