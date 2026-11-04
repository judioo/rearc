import AppKit
import Foundation
import SidebarModel

/// Site icons for sidebar rows, keyed by host (`www.` stripped). Engines
/// deliver icons only for loaded tabs; the cache lets unloaded pinned tabs and
/// favorites keep theirs across launches (Arc `SidebarItemsFaviconCache/`).
/// Files hold the image bytes as the engine delivered them.
@Observable
final class FaviconStore {
    private var images: [String: NSImage] = [:]
    @ObservationIgnored private var missingOnDisk: Set<String> = []
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "net.rearc.favicons", qos: .utility)

    /// `directory` nil keeps icons in memory only.
    init(directory: URL?) {
        self.directory = directory
    }

    static func hostKey(for url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func image(for url: URL) -> NSImage? {
        guard let key = Self.hostKey(for: url) else { return nil }
        if let cached = images[key] { return cached }
        guard let directory, !missingOnDisk.contains(key) else { return nil }
        let file = directory.appendingPathComponent(Self.fileName(for: key))
        let read = ModelSignposts.measure(ModelSignposts.persistence, "FaviconDiskRead") {
            (try? Data(contentsOf: file)).flatMap(NSImage.init(data:))
        }
        guard let image = read else {
            missingOnDisk.insert(key)
            return nil
        }
        // Loaded during a view update: publish on the next turn, not mid-render.
        DispatchQueue.main.async { [weak self] in self?.images[key] = image }
        return image
    }

    /// Records an engine-delivered icon for the page's host. `persist` is false
    /// for private (ephemeral) contexts.
    @discardableResult
    func store(_ data: Data, for pageURL: URL, persist: Bool = true) -> Bool {
        guard let key = Self.hostKey(for: pageURL), let image = NSImage(data: data) else { return false }
        images[key] = image
        missingOnDisk.remove(key)
        guard persist, let directory else { return true }
        let file = directory.appendingPathComponent(Self.fileName(for: key))
        ioQueue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return true
    }

    /// Host names map to file names with anything outside [a-z0-9.-] replaced.
    static func fileName(for key: String) -> String {
        let safe = key.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "_" }
        return String(safe) + ".icon"
    }
}
