import Foundation

/// PNG capture storage under Application Support (index lives in `SidebarSnapshot`).
public protocol CaptureFileStoring: AnyObject {
    func savePNG(_ data: Data, for record: CaptureRecord) throws
    func loadPNG(for record: CaptureRecord) -> Data?
    func deletePNG(for record: CaptureRecord)
    func fileURL(for record: CaptureRecord) -> URL
}

public final class CaptureFileStore: CaptureFileStoring {
    public static let defaultDirectoryURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReArc/Captures", isDirectory: true)
    }()

    private let directoryURL: URL

    public init(directoryURL: URL = CaptureFileStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    public func fileURL(for record: CaptureRecord) -> URL {
        let name = CaptureRecord.canonicalFileName(id: record.id, proposed: record.fileName)
        let base = directoryURL.standardizedFileURL
        let resolved = base.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard resolved.path.hasPrefix(base.path + "/") || resolved.path == base.path else {
            return base.appendingPathComponent("\(record.id.uuidString).png", isDirectory: false)
        }
        return resolved
    }

    public func savePNG(_ data: Data, for record: CaptureRecord) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: record), options: [.atomic])
    }

    public func loadPNG(for record: CaptureRecord) -> Data? {
        try? Data(contentsOf: fileURL(for: record))
    }

    public func deletePNG(for record: CaptureRecord) {
        try? FileManager.default.removeItem(at: fileURL(for: record))
    }
}
