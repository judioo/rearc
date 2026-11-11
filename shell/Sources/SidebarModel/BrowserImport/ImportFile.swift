import Foundation
import SQLite3

/// How the importers open another browser's files (RC-0.1.0-602 T-08). A
/// source profile is untrusted, and with Full Disk Access ReArc can read
/// what that profile's owner could not: a file is read only if it is a
/// regular file, never through a symbolic link, and only up to a size a
/// real browser writes. JSON is checked for nesting before it is parsed.
public enum ImportFile {
    /// Bookmarks, Preferences, Local State, extension manifests, Arc's sidebar.
    public static let maxDocumentBytes = 64 << 20
    /// History, places.sqlite, History.db (and their journals).
    public static let maxDatabaseBytes = 2 << 30
    /// Deeper JSON is refused before Foundation's recursive parser sees it.
    public static let maxJSONNesting = 512
    /// Bookmark folders below this are not walked: each level is a stack frame.
    public static let maxFolderWalkDepth = 64

    public enum ReadError: Error { case notARegularFile, tooLarge, tooDeep }

    /// A regular file (not a link) of at most `maxBytes`, as `lstat` sees it.
    public static func isRegularFile(_ url: URL, maxBytes: Int) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return false }
        return info.st_size <= maxBytes
    }

    /// The file's bytes, opened with `O_NOFOLLOW` (a link fails) and checked again once open.
    public static func data(_ url: URL, maxBytes: Int = maxDocumentBytes) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ReadError.notARegularFile }
        guard info.st_size <= maxBytes else { throw ReadError.tooLarge }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw ReadError.tooLarge }
        return data
    }

    /// `JSONSerialization` on the file, if it nests no deeper than `maxJSONNesting`.
    public static func json(_ url: URL, maxBytes: Int = maxDocumentBytes) throws -> Any {
        let data = try data(url, maxBytes: maxBytes)
        guard nestsWithin(data, limit: maxJSONNesting) else { throw ReadError.tooDeep }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Array and object depth, counted outside strings; a cheap scan before parsing.
    public static func nestsWithin(_ data: Data, limit: Int) -> Bool {
        var depth = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > limit { return false }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return true
    }

    /// Copies `source` to `destination` byte for byte, refusing a link or an oversized file.
    static func copy(_ source: URL, to destination: URL, maxBytes: Int) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: source.path]) }
        let reader = FileHandle(fileDescriptor: input, closeOnDealloc: true)
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ReadError.notARegularFile }
        guard info.st_size <= maxBytes else { throw ReadError.tooLarge }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path]) }
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        var copied = 0
        while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            copied += chunk.count
            guard copied <= maxBytes else { throw ReadError.tooLarge }
            try writer.write(contentsOf: chunk)
        }
    }

    /// Opens a database copy read-only, never through a link, with SQLite's
    /// schema distrust on: a crafted file's views and triggers run no functions.
    public static func openDatabase(_ url: URL) -> OpaquePointer? {
        // NOFOLLOW refuses a link anywhere in the path, and the temporary folder is under
        // /var (itself a link): the folder is resolved, the file itself never is.
        // (Foundation's resolvingSymlinksInPath maps /private/var back to /var; realpath does not.)
        guard let folder = realpath(url.deletingLastPathComponent().path, nil) else { return nil }
        let path = String(cString: folder) + "/" + url.lastPathComponent
        free(folder)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        // SQLITE_DBCONFIG_DEFENSIVE is set through a C variadic Swift cannot call; on a
        // read-only, query-only copy these pragmas cover what it would.
        for pragma in ["PRAGMA trusted_schema = OFF", "PRAGMA query_only = ON", "PRAGMA cell_size_check = ON"] {
            guard sqlite3_exec(db, pragma, nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(db)
                return nil
            }
        }
        return db
    }
}
