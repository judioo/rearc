import AppKit
import SidebarModel
import UniformTypeIdentifiers

/// A picture for a profile from Choose Image…, a drop or a paste: read,
/// normalised (`ProfileAvatarImage`) and stored. Only the normalised copy
/// is kept, and nothing but ImageIO sees the original bytes.
enum ProfileAvatarImageIntake {
    enum Source: Sendable {
        case file(URL)
        case data(Data)
    }

    /// Pasteboard image flavours, in the order they are tried after a file URL.
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.png, .tiff] + [UTType.jpeg, .heic].map { NSPasteboard.PasteboardType($0.identifier) }

    static func adopt(_ source: Source, into images: ProfileAvatarImageStore) throws -> ProfileAvatarImageName {
        let bytes: Data
        switch source {
        case .file(let url): bytes = try ProfileAvatarImage.readCandidate(at: url)
        case .data(let data): bytes = data
        }
        return try images.save(ProfileAvatarImage.normalizing(bytes))
    }

    /// Decoding a large photo takes a moment: done off the main thread.
    static func adopt(_ source: Source, into images: ProfileAvatarImageStore,
                      completion: @escaping @MainActor (Result<ProfileAvatarImageName, ProfileAvatarImageError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try adopt(source, into: images) }
                .mapError { $0 as? ProfileAvatarImageError ?? .unreadable }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// A copied file first (Finder), then image data (a screenshot, a browser's Copy Image).
    static func source(from pasteboard: NSPasteboard) -> Source? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first {
            return .file(url)
        }
        for type in pasteboardTypes {
            if let data = pasteboard.data(forType: type) { return .data(data) }
        }
        return nil
    }

    static let dropTypes: [UTType] = [.fileURL, .image]

    /// The first dropped or pasted item; `completion` runs on the main thread.
    static func loadSource(from providers: [NSItemProvider], completion: @escaping @MainActor (Source?) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        @Sendable func finish(_ source: Source?) { DispatchQueue.main.async { MainActor.assumeIsolated { completion(source) } } }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                finish(data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }.map(Source.file))
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in finish(data.map(Source.data)) }
            return true
        }
        return false
    }
}
