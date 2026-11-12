import Foundation
import SidebarModel

/// Max › Tidy Downloads (FEATURE-SPECS/MAX.md §3), by rules on this Mac: a
/// download that finishes gets a clearer name from its page's title, its
/// host and its own name, in the same folder, never over another file. The
/// original name stays with the download; Undo and Use Original Name put it
/// back. Nothing from a private window is renamed or read.
extension BrowserViewModel {
    /// Tries a few times while the file settles (Chromium, quarantine and
    /// Spotlight touch it just after it finishes).
    static let tidyDownloadAttempts = 4
    static let tidyDownloadRetryDelay: TimeInterval = 1.5

    /// `DownloadsController.onCompleted`.
    func installTidyDownloads() {
        downloads.onCompleted = { [weak self] record, origin in self?.tidyDownload(record, origin: origin) }
    }

    /// The new name for a finished download, or nil to leave it.
    static func tidyDownloadName(for record: DownloadRecord, origin: DownloadOrigin?) -> String? {
        guard let origin, !origin.isPrivate, record.hasFileOnDisk, record.originalPath == nil else { return nil }
        return TidyDownloads.tidyName(for: record.fileName, origin: origin.page)
    }

    func tidyDownload(_ record: DownloadRecord, origin: DownloadOrigin?, attempt: Int = 1,
                      fileSystem: DownloadFileSystem = SystemDownloadFileSystem(),
                      queue: DispatchQueue = DispatchQueue.global(qos: .utility),
                      completion: ((DownloadRenamer.Outcome) -> Void)? = nil) {
        guard isMaxFeatureOn(.tidyDownloads), let name = Self.tidyDownloadName(for: record, origin: origin) else { return }
        let path = record.targetPath
        let size = record.totalBytes > 0 ? record.totalBytes : record.receivedBytes
        queue.async { [weak self] in
            let outcome = DownloadRenamer.rename(path, to: name, expectedSize: size, fileSystem: fileSystem)
            DispatchQueue.main.async {
                guard let self else { return }
                switch outcome {
                case .renamed(let newPath):
                    self.downloads.noteRenamed(record.id, to: newPath, originalPath: path)
                    let shown = (newPath as NSString).lastPathComponent
                    self.showUndoToast("Renamed download to “\(shown)”", systemImage: "arrow.down.doc") { [weak self] in
                        self?.useOriginalDownloadName(record.id, fileSystem: fileSystem, queue: queue)
                    }
                case .skipped(.open) where attempt < Self.tidyDownloadAttempts:
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.tidyDownloadRetryDelay) { [weak self] in
                        guard let self, let current = self.downloads.list.record(withID: record.id), current.targetPath == path else { return }
                        self.tidyDownload(current, origin: origin, attempt: attempt + 1, fileSystem: fileSystem, queue: queue, completion: completion)
                    }
                    return
                case .skipped:
                    break
                }
                completion?(outcome)
            }
        }
    }

    /// The toast's Undo: Use Original Name, saying so when it cannot.
    func useOriginalDownloadName(_ id: String, fileSystem: DownloadFileSystem = SystemDownloadFileSystem(),
                                 queue: DispatchQueue = DispatchQueue.global(qos: .utility),
                                 completion: ((DownloadRenamer.Outcome) -> Void)? = nil) {
        downloads.useOriginalName(id, fileSystem: fileSystem, queue: queue) { [weak self] outcome in
            switch outcome {
            case .renamed: break
            case .skipped(.missing): self?.showToast("The file is no longer where ReArc put it", systemImage: "exclamationmark.triangle")
            case .skipped: self?.showToast("Could not rename the file back", systemImage: "exclamationmark.triangle")
            }
            completion?(outcome)
        }
    }
}
