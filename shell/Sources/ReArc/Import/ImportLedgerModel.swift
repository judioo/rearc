import Foundation
import SidebarModel

/// Reads which extensions a ReArc profile already has, off the main thread.
typealias InstalledExtensionsReader = @Sendable (Profile.ID) -> Set<String>

extension BrowserViewModel {
    var importLedgerURL: URL { Self.siblingFile(ImportLedger.fileName, of: persistence.fileURL) }

    func loadImportLedger() -> ImportLedger { ImportLedger.load(from: importLedgerURL) }

    /// Notes another browser profile's history as merged, so importing it
    /// again brings only pages visited since.
    func recordImportedHistory(_ records: [VisitRecord], from sourceID: String) {
        var ledger = loadImportLedger()
        ledger.recordHistory(records, from: sourceID)
        ledger.save(to: importLedgerURL)
    }

    /// The extensions each ReArc profile has: what its Chromium folder lists
    /// when the engine has made one, else what earlier imports installed
    /// (`extension-reinstall.json`). An import never queues them again.
    func installedExtensionsReader() -> InstalledExtensionsReader {
        let pending = pendingExtensionReinstall ?? PendingExtensionReinstall.read(from: pendingExtensionReinstallURL)
        let succeeded = Set((pending?.results ?? [:]).filter { $0.value.succeeded }.keys)
        let folder = chromiumProfileFolderLocator()
        return { profileID in
            if let url = folder(profileID), FileManager.default.fileExists(atPath: url.appendingPathComponent("Preferences").path) {
                return Set(ExtensionInventoryReader.read(profile: url).map(\.id))
            }
            let prefix = "\(profileID):"
            return Set(succeeded.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })
        }
    }

    private func chromiumProfileFolderLocator() -> @Sendable (Profile.ID) -> URL? {
        #if REARC_CHROMIUM
        if let userDataDir = ChromiumRuntime.active?.userDataDir {
            return { ChromiumProfileStorageMap.folder(for: $0, in: userDataDir) }
        }
        #endif
        return { _ in nil }
    }
}

extension ChromiumProfileStorageMap {
    /// The profile's folder in `userDataDir`: an adopted directory or its named one.
    static func folder(for profileID: Profile.ID, in userDataDir: URL) -> URL {
        let map = load(from: userDataDir.appendingPathComponent(fileName))
        switch map.storage(for: profileID) {
        case .directory(let token): return userDataDir.appendingPathComponent(token, isDirectory: true)
        case .named(let key):
            return userDataDir.appendingPathComponent(ChromiumProfileStoragePlan.namedDirectoryName(forKey: key), isDirectory: true)
        }
    }
}
