import Foundation

/// An extension installed in a source profile (PROFILE-IMPORT §3). Read from
/// `Secure Preferences` and `Preferences` (`extensions.settings.<id>`,
/// `extensions.pinned_extensions`) and the manifest under `Extensions/`.
public struct SourceExtension: Identifiable, Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
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
    public var origin: Origin

    public var canReinstall: Bool {
        switch origin {
        case .webStore: return true
        case .unpacked(let path): return FileManager.default.fileExists(atPath: path)
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
        let merged = settings(preferences).merging(settings(securePreferences)) { _, secure in secure }
        let pinned = Set((preferences["extensions"] as? [String: Any])?["pinned_extensions"] as? [String] ?? [])
        return merged.compactMap { id, entry -> SourceExtension? in
            guard isExtensionID(id), let manifest = entry["manifest"] as? [String: Any],
                  let location = entry["location"] as? Int, !builtInLocations.contains(location) else { return nil }
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
                origin: origin
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

    /// `__MSG_name__` names come from `_locales/<default_locale>/messages.json`.
    static func localized(_ name: String, defaultLocale: String?, folder: URL) -> String? {
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__"), name.count > 8 else { return name }
        let key = String(name.dropFirst(6).dropLast(2)).lowercased()
        let locales = [defaultLocale, "en", "en_US"].compactMap { $0 }
        for locale in locales {
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

/// Extensions to reinstall into a ReArc profile, one at a time. A Web Store
/// extension cannot be copied as files (its verified contents and install
/// signature belong to the source browser), so each opens on its store page,
/// where the engine's install prompt asks for the user's consent; an
/// unpacked one is loaded from its folder through chrome://extensions.
public struct ExtensionReinstallQueue: Equatable, Sendable {
    public struct Item: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var origin: SourceExtension.Origin
        public var profileID: Profile.ID
    }

    public private(set) var items: [Item]
    public private(set) var position = 0

    public init(_ extensions: [SourceExtension], into profileID: Profile.ID) {
        items = extensions.filter(\.canReinstall).map { Item(id: $0.id, name: $0.name, origin: $0.origin, profileID: profileID) }
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
