import Foundation

/// An extension installed in a source profile (PROFILE-IMPORT §3). Read from
/// `Secure Preferences` and `Preferences` (`extensions.settings.<id>`,
/// `extensions.pinned_extensions`) and the manifest under `Extensions/`.
public struct SourceExtension: Identifiable, Equatable, Sendable {
    public enum Origin: Equatable, Codable, Sendable {
        /// From the Chrome Web Store: reinstalls by id.
        case webStore
        /// Loaded unpacked from a folder (developer mode).
        case unpacked(path: String)
        /// Installed by policy, another app or a sideloaded crx: not portable.
        case other
    }

    public var id: String
    public var name: String
    public var version: String
    public var isEnabled: Bool
    public var isPinned: Bool
    public var isTheme: Bool
    public var manifestVersion: Int? = nil
    public var isComponent = false
    public var isDefaultApp = false
    public var isActiveTheme = false
    public var isBlocklisted = false
    public var origin: Origin
    /// The source browser's installed manifest, as JSON: the engine prompts
    /// when the store's current one asks for more (engine ABI 1.61).
    public var manifestJSON: String? = nil

    public var canReinstall: Bool {
        switch origin {
        case .webStore: return true
        case .unpacked: return false
        case .other: return false
        }
    }
}

public enum ExtensionInventoryReader {
    /// Chromium `ManifestLocation`: kInternal 1, kExternalPref 2, kExternalRegistry 3,
    /// kUnpacked 4, kComponent 5, kExternalPrefDownload 6, kExternalPolicyDownload 7,
    /// kCommandLine 8, kExternalPolicy 9, kExternalComponent 10.
    static let unpackedLocations: Set<Int> = [4, 8]
    static let builtInLocations: Set<Int> = [5, 10]
    public static let webStoreUpdateURL = "https://clients2.google.com/service/update2/crx"

    /// 32 letters a–p.
    public static func isExtensionID(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { ("a" ... "p").contains($0) }
    }

    /// A new inventory can remove consented items, never add IDs or change
    /// their origin (including an unpacked path) after the discovery snapshot.
    public static func consented(_ inventory: [SourceExtension], snapshot: [String: SourceExtension.Origin]) -> [SourceExtension] {
        inventory.filter { snapshot[$0.id] == $0.origin }
    }

    /// The profile's extensions, without Chromium's built-in ones, by name.
    public static func read(profile: URL) -> [SourceExtension] {
        func json(_ name: String) -> [String: Any] {
            guard let data = try? Data(contentsOf: profile.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }
        return parse(preferences: json("Preferences"), securePreferences: json("Secure Preferences"),
                     extensionsFolder: profile.appendingPathComponent("Extensions", isDirectory: true))
    }

    static func parse(preferences: [String: Any], securePreferences: [String: Any], extensionsFolder: URL) -> [SourceExtension] {
        func settings(_ root: [String: Any]) -> [String: [String: Any]] {
            ((root["extensions"] as? [String: Any])?["settings"] as? [String: [String: Any]]) ?? [:]
        }
        // macOS keeps them in Secure Preferences; older profiles in Preferences.
        let merged = settings(preferences).merging(settings(securePreferences)) { regular, secure in
            regular.merging(secure) { _, value in value }
        }
        let pinned = Set((preferences["extensions"] as? [String: Any])?["pinned_extensions"] as? [String] ?? [])
        return merged.compactMap { id, entry -> SourceExtension? in
            guard isExtensionID(id), let manifest = entry["manifest"] as? [String: Any],
                  let location = entry["location"] as? Int else { return nil }
            let path = entry["path"] as? String ?? ""
            let folder = path.hasPrefix("/") ? URL(fileURLWithPath: path, isDirectory: true)
                : extensionsFolder.appendingPathComponent(path, isDirectory: true)
            let origin: SourceExtension.Origin
            if unpackedLocations.contains(location) {
                origin = .unpacked(path: folder.path)
            } else if entry["from_webstore"] as? Bool == true || manifest["update_url"] as? String == webStoreUpdateURL {
                origin = .webStore
            } else {
                origin = .other
            }
            let rawName = manifest["name"] as? String ?? id
            return SourceExtension(
                id: id,
                name: localized(rawName, defaultLocale: manifest["default_locale"] as? String, folder: folder) ?? id,
                version: manifest["version"] as? String ?? "",
                isEnabled: isEnabled(entry),
                isPinned: pinned.contains(id),
                isTheme: manifest["theme"] != nil,
                manifestVersion: manifest["manifest_version"] as? Int,
                isComponent: builtInLocations.contains(location),
                isDefaultApp: entry["was_installed_by_default"] as? Bool == true || entry["was_installed_by_oem"] as? Bool == true,
                isActiveTheme: (((preferences["extensions"] as? [String: Any])?["theme"] as? [String: Any])?["id"] as? String) == id,
                isBlocklisted: (entry["blocklist_state"] as? Int ?? entry["blacklist_state"] as? Int ?? 0) != 0,
                origin: origin,
                manifestJSON: (try? JSONSerialization.data(withJSONObject: manifest)).flatMap { String(data: $0, encoding: .utf8) }
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Chromium 120+ keeps `disable_reasons` (empty or absent: enabled);
    /// older profiles kept `state` (1 enabled, 0 disabled).
    static func isEnabled(_ entry: [String: Any]) -> Bool {
        if let reasons = entry["disable_reasons"] as? [Any] { return reasons.isEmpty }
        if let reasons = entry["disable_reasons"] as? Int { return reasons == 0 }
        if let state = entry["state"] as? Int { return state == 1 }
        return true
    }

    /// A locale directory name, such as en, en_US, es_419 or zh_Hant_TW.
    /// Separators are allowed only between ASCII alphanumeric subtags.
    static func isLocaleName(_ name: String) -> Bool {
        name.count <= 64 && name.range(of: "^[A-Za-z]{2,3}(?:[_-][A-Za-z0-9]{2,8})*$", options: .regularExpression) == (name.startIndex..<name.endIndex)
    }

    /// `__MSG_name__` names come from `_locales/<default_locale>/messages.json`.
    static func localized(_ name: String, defaultLocale: String?, folder: URL) -> String? {
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__"), name.count > 8 else { return name }
        let key = String(name.dropFirst(6).dropLast(2)).lowercased()
        let locales = [defaultLocale, "en", "en_US"].compactMap { $0 }
        for locale in locales where isLocaleName(locale) {
            let url = folder.appendingPathComponent("_locales/\(locale)/messages.json")
            guard let data = try? Data(contentsOf: url),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (messageKey, value) in messages where messageKey.lowercased() == key {
                if let message = (value as? [String: Any])?["message"] as? String, !message.isEmpty { return message }
            }
        }
        return nil
    }
}

/// A consolidated install into one ReArc profile. Legacy position is retained
/// so queues written by older shells can resume without repeating their steps.
public struct ExtensionReinstallQueue: Equatable, Codable, Sendable {
    public struct Item: Identifiable, Equatable, Codable, Sendable {
        public var id: String
        public var name: String
        public var origin: SourceExtension.Origin
        public var profileID: Profile.ID
        public var enabledByDefault: Bool? = nil
        /// `SourceExtension.manifestJSON`; absent in queues saved before it.
        public var sourceManifest: String? = nil

        public var key: String { "\(profileID):\(id)" }
    }

    public private(set) var items: [Item]
    public private(set) var position = 0

    /// The ones that can be reinstalled, each once (the same extension can
    /// come from more than one source profile), less those `installedIDs`
    /// says the ReArc profile has already.
    public init(_ extensions: [SourceExtension], into profileID: Profile.ID, installedIDs: Set<String> = []) {
        items = ExtensionConsolidation(extensions, installedIDs: installedIDs).candidates
            .map { Item(id: $0.id, name: $0.name, origin: $0.origin, profileID: profileID, enabledByDefault: $0.isEnabled,
                        sourceManifest: $0.manifestJSON) }
    }

    /// Old queues omitted source enablement. Re-read their inventory before
    /// treating onboarding's earlier consent as authorization to install.
    public mutating func reconcileLegacyInventory(_ inventory: [SourceExtension]) -> [ExtensionConsolidation.Skipped] {
        let legacyIDs = Set(items.dropFirst(position).filter { $0.enabledByDefault == nil }.map(\.id))
        let consolidation = ExtensionConsolidation(inventory.filter { legacyIDs.contains($0.id) })
        let candidates = Dictionary(uniqueKeysWithValues: consolidation.candidates.map { ($0.id, $0) })
        var skipped = consolidation.skipped
        items = Array(items.dropFirst(position)).compactMap { item in
            guard item.enabledByDefault == nil else { return item }
            guard let source = candidates[item.id] else {
                if !inventory.contains(where: { $0.id == item.id }) {
                    skipped.append(.init(id: item.id, name: item.name, reason: "source unavailable"))
                }
                return nil
            }
            guard source.origin == item.origin else {
                skipped.append(.init(id: item.id, name: item.name, reason: "source origin changed"))
                return nil
            }
            var item = item
            item.enabledByDefault = source.isEnabled
            item.sourceManifest = source.manifestJSON
            return item
        }
        position = 0
        return skipped
    }

    private enum CodingKeys: String, CodingKey { case items, position }

    /// Persisted queues are untrusted input. Keep store items only, including
    /// when resuming a queue written before unpacked imports were removed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([Item].self, forKey: .items)
        let oldPosition = max(0, min(try container.decodeIfPresent(Int.self, forKey: .position) ?? 0, decoded.count))
        var seen = Set<String>()
        let accepted = decoded.enumerated().filter { _, item in
            item.origin == .webStore && ExtensionInventoryReader.isExtensionID(item.id) && seen.insert(item.key).inserted
        }
        items = accepted.map(\.element)
        position = accepted.filter { $0.offset < oldPosition }.count
    }

    public var current: Item? { items.indices.contains(position) ? items[position] : nil }
    public var isFinished: Bool { current == nil }
    public var remaining: Int { max(0, items.count - position) }

    /// "2 of 5" while running.
    public var progressText: String? {
        current.map { _ in "\(position + 1) of \(items.count)" }
    }

    public mutating func advance() {
        if position < items.count { position += 1 }
    }

    public static func storeURL(for id: String) -> URL {
        URL(string: "https://chromewebstore.google.com/detail/\(id)")!
    }
}

/// Consolidate before any downloads. An enabled copy wins over a disabled copy;
/// a source's disabled/policy/blocklist flags never authorize an installation.
public struct ExtensionConsolidation: Sendable {
    public struct Skipped: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var reason: String
        public init(id: String, name: String, reason: String) {
            self.id = id
            self.name = name
            self.reason = reason
        }
    }
    public var candidates: [SourceExtension] = []
    public var skipped: [Skipped] = []
    public let totalFound: Int
    public let uniqueCount: Int

    public init(_ sources: [SourceExtension], installedIDs: Set<String> = []) {
        totalFound = sources.count
        let grouped = Dictionary(grouping: sources, by: \.id)
        uniqueCount = grouped.count
        var seen = Set<String>()
        for source in sources where seen.insert(source.id).inserted {
            let copies = grouped[source.id]!
            for duplicate in copies.dropFirst() {
                skipped.append(.init(id: duplicate.id, name: duplicate.name, reason: "duplicate"))
            }
            let enabled = copies.filter { $0.isEnabled && !$0.isComponent && !$0.isDefaultApp && !$0.isBlocklisted && (!$0.isTheme || $0.isActiveTheme) }
            let eligible = enabled.first { $0.manifestVersion != 2 && $0.canReinstall } ?? enabled.first
            let reason: String?
            if installedIDs.contains(source.id) { reason = "already installed" }
            else if copies.allSatisfy(\.isComponent) { reason = "component" }
            else if copies.allSatisfy(\.isDefaultApp) { reason = "default app" }
            else if copies.allSatisfy({ $0.isTheme && !$0.isActiveTheme }) { reason = "inactive theme" }
            else if copies.allSatisfy(\.isBlocklisted) { reason = "blocklisted" }
            else if eligible == nil { reason = "disabled" }
            else if eligible?.manifestVersion == 2 { reason = "retired (Manifest V2)" }
            else if case .unpacked(let path) = eligible?.origin { reason = "load manually: \(path)" }
            else if eligible?.canReinstall != true { reason = "not portable" }
            else { reason = nil }
            if let reason { skipped.append(.init(id: source.id, name: source.name, reason: reason)) }
            else if let eligible { candidates.append(eligible) }
        }
    }

    /// ABI result 2 is unavailable, rather than a broken installation. Result
    /// 4 covers unsupported manifests, blocklist and management policy checks.
    public static func unavailable(status: Int32) -> Bool { status == 2 || status == 4 }
}
