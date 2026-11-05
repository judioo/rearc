import AppKit
import Foundation
import SidebarModel

/// Site icons for sidebar rows, keyed by host (`www.` stripped). Engines
/// deliver icons only for loaded tabs; the cache lets unloaded pinned tabs and
/// favorites keep theirs across launches (Arc `SidebarItemsFaviconCache/`).
/// Files hold the image bytes as the engine delivered them.
@Observable
final class FaviconStore {
    /// Observed per host (`cells`), so one icon arriving redraws the rows showing that host only.
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private let cells = ObservationCells<String>()
    @ObservationIgnored private var missingOnDisk: Set<String> = []
    @ObservationIgnored private var loadingFromDisk: Set<String> = []
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let ioQueue: DispatchQueue

    /// `directory` nil keeps icons in memory only.
    init(directory: URL?, ioQueue: DispatchQueue = DispatchQueue(label: "net.rearc.favicons", qos: .utility)) {
        self.directory = directory
        self.ioQueue = ioQueue
    }

    static func hostKey(for url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    func image(for url: URL) -> NSImage? {
        guard let key = Self.hostKey(for: url) else { return nil }
        cells.access(key)
        if let cached = images[key] { return cached }
        guard let directory, !missingOnDisk.contains(key), loadingFromDisk.insert(key).inserted else { return nil }
        let file = directory.appendingPathComponent(Self.fileName(for: key))
        ioQueue.async { [weak self] in
            let image = ModelSignposts.measure(ModelSignposts.persistence, "FaviconDiskRead") {
                (try? Data(contentsOf: file)).flatMap(NSImage.init(data:))
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadingFromDisk.remove(key)
                // An engine icon delivered during the read is newer than disk.
                guard self.images[key] == nil else { return }
                if let image {
                    self.setImage(image, for: key)
                } else {
                    self.missingOnDisk.insert(key)
                }
            }
        }
        return nil
    }

    /// Records an engine-delivered icon for the page's host. `persist` is false
    /// for private (ephemeral) contexts.
    @discardableResult
    func store(_ data: Data, for pageURL: URL, persist: Bool = true) -> Bool {
        guard let key = Self.hostKey(for: pageURL), let image = NSImage(data: data) else { return false }
        setImage(image, for: key)
        missingOnDisk.remove(key)
        guard persist, let directory else { return true }
        let file = directory.appendingPathComponent(Self.fileName(for: key))
        ioQueue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return true
    }

    private func setImage(_ image: NSImage, for key: String) {
        images[key] = image
        cells.invalidate(key)
    }

    /// Host names map to file names with anything outside [a-z0-9.-] replaced.
    static func fileName(for key: String) -> String {
        let safe = key.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") ? $0 : "_" }
        return String(safe) + ".icon"
    }
}
