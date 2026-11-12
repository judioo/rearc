import Darwin
import Foundation
import SidebarModel

/// The file calls Tidy Downloads makes, so tests can use a folder of their own.
protocol DownloadFileSystem: Sendable {
    /// nil: nothing at `path`.
    func state(atPath path: String) -> (isDirectory: Bool, isPackage: Bool, size: Int64, modified: Date)?
    /// A process (Chromium finishing up, a mounter, an app) has the file open.
    func isOpen(_ path: String) -> Bool
    func exists(_ path: String) -> Bool
    /// Moves the file, refusing to replace anything (`RENAME_EXCL`): 0 or the errno.
    func renameExclusive(_ from: String, to: String) -> Int32
}

struct SystemDownloadFileSystem: DownloadFileSystem {
    func state(atPath path: String) -> (isDirectory: Bool, isPackage: Bool, size: Int64, modified: Date)? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return nil }
        return (values.isDirectory ?? false, values.isPackage ?? false, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
    }

    func isOpen(_ path: String) -> Bool {
        var pids = [Int32](repeating: 0, count: 32)
        let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return bytes > 0
    }

    func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    func renameExclusive(_ from: String, to: String) -> Int32 {
        renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
    }
}

/// Max › Tidy Downloads on disk (FEATURE-SPECS/MAX.md §3): the rename, in
/// the same folder, never over another file, and only of a file that is
/// where the download left it, unchanged, a plain file, and open in no
/// process. Runs off the main thread.
enum DownloadRenamer {
    enum Outcome: Equatable {
        case renamed(to: String)
        case skipped(Reason)
    }

    enum Reason: Equatable {
        /// Gone: the person moved, renamed or deleted it.
        case missing
        /// A folder or bundle.
        case notAFile
        /// Its size is not the download's: changed since, or not finished.
        case changed
        /// Still open in some process.
        case open
        /// No clearer name, or one never renamed (installers, disk images, scripts).
        case noBetterName
        case failed(Int32)
    }

    /// Seconds a file must sit unmodified before it is renamed.
    static let settleTime: TimeInterval = 1

    /// Renames the finished download at `path` to `name` (already tidied
    /// and safe), or the first free numbered variant of it.
    static func rename(_ path: String, to name: String, expectedSize: Int64?, now: Date = Date(),
                       fileSystem: DownloadFileSystem = SystemDownloadFileSystem()) -> Outcome {
        let current = (path as NSString).lastPathComponent
        guard name != current, !name.contains("/"), !name.hasPrefix("."),
              TidyDownloads.fileExtension(of: name) == TidyDownloads.fileExtension(of: current) else { return .skipped(.noBetterName) }
        guard let state = fileSystem.state(atPath: path) else { return .skipped(.missing) }
        guard !state.isDirectory, !state.isPackage else { return .skipped(.notAFile) }
        if let expectedSize, expectedSize > 0, state.size != expectedSize { return .skipped(.changed) }
        guard now.timeIntervalSince(state.modified) >= settleTime else { return .skipped(.open) }
        guard !fileSystem.isOpen(path) else { return .skipped(.open) }
        let directory = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent, isDirectory: true)
        var taken = Set<String>()
        for _ in 0 ..< 20 {
            let target = TidyDownloads.freeName(name, in: directory) { taken.contains($0.path) || fileSystem.exists($0.path) }.path
            let status = fileSystem.renameExclusive(path, to: target)
            if status == 0 { return .renamed(to: target) }
            // Taken between the check and the move: the next number.
            guard status == EEXIST else { return .skipped(.failed(status)) }
            taken.insert(target)
        }
        return .skipped(.failed(EEXIST))
    }

    /// Use Original Name / Undo: back to the name it had, or a free variant
    /// of it, only while the file is still at the tidied path.
    static func restore(_ tidiedPath: String, originalPath: String, fileSystem: DownloadFileSystem = SystemDownloadFileSystem()) -> Outcome {
        guard let state = fileSystem.state(atPath: tidiedPath) else { return .skipped(.missing) }
        guard !state.isDirectory, !state.isPackage else { return .skipped(.notAFile) }
        let directory = URL(fileURLWithPath: (tidiedPath as NSString).deletingLastPathComponent, isDirectory: true)
        let name = (originalPath as NSString).lastPathComponent
        var taken = Set<String>()
        for _ in 0 ..< 20 {
            let target = TidyDownloads.freeName(name, in: directory) { taken.contains($0.path) || fileSystem.exists($0.path) }.path
            let status = fileSystem.renameExclusive(tidiedPath, to: target)
            if status == 0 { return .renamed(to: target) }
            guard status == EEXIST else { return .skipped(.failed(status)) }
            taken.insert(target)
        }
        return .skipped(.failed(EEXIST))
    }
}
