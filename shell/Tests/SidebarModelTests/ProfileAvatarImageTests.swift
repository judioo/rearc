import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SidebarModel

final class ProfileAvatarImageTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-avatars-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    /// Columns of colour, left to right, each `width / colors.count` wide.
    private func bitmap(width: Int, height: Int, columns colors: [(CGFloat, CGFloat, CGFloat, CGFloat)]) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let column = CGFloat(width) / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
            context.fill(CGRect(x: CGFloat(index) * column, y: 0, width: column, height: CGFloat(height)))
        }
        return context.makeImage()!
    }

    private func encode(_ images: [CGImage], as type: UTType, properties: [CFString: Any]? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)!
        for image in images { CGImageDestinationAddImage(destination, image, properties as CFDictionary?) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func decoded(_ data: Data) throws -> (image: CGImage, properties: [CFString: Any]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (image, properties)
    }

    /// The centre pixel as 0–255 RGBA.
    private func centre(_ image: CGImage) -> [Int] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return pixel.map(Int.init)
    }

    private let red = (CGFloat(1), CGFloat(0), CGFloat(0), CGFloat(1))
    private let green = (CGFloat(0), CGFloat(1), CGFloat(0), CGFloat(1))
    private let blue = (CGFloat(0), CGFloat(0), CGFloat(1), CGFloat(1))

    // MARK: Normalising

    func testLargePhotoIsCroppedToACentredSquareAndCappedAt256() throws {
        // Red | green | blue thirds: the centred square is the green third.
        let source = encode([bitmap(width: 1500, height: 500, columns: [red, green, blue])], as: .png)
        let image = try ProfileAvatarImage.normalizing(source)
        XCTAssertEqual(image.format, .jpeg, "opaque pictures are JPEG")
        XCTAssertEqual(image.side, 256)
        let (pixels, _) = try decoded(image.data)
        XCTAssertEqual([pixels.width, pixels.height], [256, 256])
        let mid = centre(pixels)
        XCTAssertGreaterThan(mid[1], 200)
        XCTAssertLessThan(mid[0], 40)
        XCTAssertLessThan(mid[2], 40)
        let hash = SHA256.hash(data: image.data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(image.name.rawValue, "\(hash).jpg", "named by its content")
        XCTAssertEqual(try ProfileAvatarImage.normalizing(source).name, image.name, "the same picture, the same file")
    }

    func testSmallPictureIsNotEnlarged() throws {
        let image = try ProfileAvatarImage.normalizing(encode([bitmap(width: 90, height: 60, columns: [green])], as: .png))
        XCTAssertEqual(image.side, 60)
        XCTAssertEqual(try decoded(image.data).image.width, 60)
    }

    func testTransparencyKeepsPNGAndAnOpaqueAlphaChannelDoesNot() throws {
        let clear = (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0))
        let transparent = try ProfileAvatarImage.normalizing(encode([bitmap(width: 300, height: 300, columns: [clear, blue, clear])], as: .png))
        XCTAssertEqual(transparent.format, .png)
        XCTAssertTrue(transparent.name.rawValue.hasSuffix(".png"))
        let (pixels, _) = try decoded(transparent.data)
        XCTAssertNotEqual(pixels.alphaInfo, .none)
        // A PNG with an alpha channel that is opaque everywhere.
        let opaque = try ProfileAvatarImage.normalizing(encode([bitmap(width: 300, height: 300, columns: [blue])], as: .png))
        XCTAssertEqual(opaque.format, .jpeg)
    }

    func testMetadataIsStripped() throws {
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SecretCam", kCGImagePropertyTIFFModel: "X1",
                                             kCGImagePropertyTIFFArtist: "Someone"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private note",
                                             kCGImagePropertyExifDateTimeOriginal: "2026:11:12 10:00:00"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "caption"],
        ]
        let source = encode([bitmap(width: 400, height: 400, columns: [red])], as: .jpeg, properties: metadata)
        XCTAssertNotNil(try decoded(source).properties[kCGImagePropertyGPSDictionary], "the fixture carries GPS")
        let image = try ProfileAvatarImage.normalizing(source)
        let properties = try decoded(image.data).properties
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFMake])
        XCTAssertNil(tiff[kCGImagePropertyTIFFModel])
        XCTAssertNil(tiff[kCGImagePropertyTIFFArtist])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifUserComment])
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
        for needle in ["SecretCam", "Someone", "private note", "caption"] {
            XCTAssertNil(image.data.range(of: Data(needle.utf8)), needle)
        }
    }

    func testRejectsFilesOver20MB() {
        let big = Data(count: ProfileAvatarImage.maxFileBytes + 1)
        XCTAssertThrowsError(try ProfileAvatarImage.normalizing(big)) { XCTAssertEqual($0 as? ProfileAvatarImageError, .tooLarge) }
    }

    func testRejectsWhatIsNotAStillImage() throws {
        let text = Data("not an image".utf8)
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><image href="file:///etc/hosts"/></svg>"#.utf8)
        for data in [Data(), text, svg] {
            XCTAssertThrowsError(try ProfileAvatarImage.normalizing(data)) { XCTAssertEqual($0 as? ProfileAvatarImageError, .notAnImage) }
        }
        // ImageIO fills in a cut-off file's missing rows; what matters is a plain result, not a crash.
        let truncated = encode([bitmap(width: 400, height: 400, columns: [red])], as: .png).prefix(200)
        if let image = try? ProfileAvatarImage.normalizing(Data(truncated)) { XCTAssertEqual(image.side, 256) }
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: pdf)!, mediaBox: &box, nil))
        context.beginPDFPage(nil); context.fill(box); context.endPDFPage(); context.closePDF()
        XCTAssertThrowsError(try ProfileAvatarImage.normalizing(pdf as Data)) { XCTAssertEqual($0 as? ProfileAvatarImageError, .notAnImage) }

        let frames = [bitmap(width: 40, height: 40, columns: [red]), bitmap(width: 40, height: 40, columns: [blue])]
        XCTAssertThrowsError(try ProfileAvatarImage.normalizing(encode(frames, as: .gif))) { XCTAssertEqual($0 as? ProfileAvatarImageError, .animated) }
        XCTAssertNoThrow(try ProfileAvatarImage.normalizing(encode([frames[0]], as: .gif)), "a still GIF is fine")
    }

    func testRejectsAbsurdDimensions() {
        let wide = encode([bitmap(width: ProfileAvatarImage.maxSourceSide + 1, height: 1, columns: [red])], as: .png)
        XCTAssertThrowsError(try ProfileAvatarImage.normalizing(wide)) { XCTAssertEqual($0 as? ProfileAvatarImageError, .badDimensions) }
        XCTAssertFalse(ProfileAvatarImageError.badDimensions.message.isEmpty)
    }

    // MARK: Reading the chosen file

    func testReadsOnlyARegularFileAndNeverThroughALink() throws {
        let file = directory.appendingPathComponent("photo.png")
        let png = encode([bitmap(width: 10, height: 10, columns: [red])], as: .png)
        try png.write(to: file)
        XCTAssertEqual(try ProfileAvatarImage.readCandidate(at: file), png)

        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ProfileAvatarImage.readCandidate(at: link)) { XCTAssertEqual($0 as? ProfileAvatarImageError, .unreadable) }
        XCTAssertThrowsError(try ProfileAvatarImage.readCandidate(at: directory)) { XCTAssertEqual($0 as? ProfileAvatarImageError, .unreadable) }
        XCTAssertThrowsError(try ProfileAvatarImage.readCandidate(at: URL(string: "https://example.com/a.png")!)) {
            XCTAssertEqual($0 as? ProfileAvatarImageError, .unreadable)
        }

        // Sparse, so the test writes no 20 MB.
        let huge = directory.appendingPathComponent("huge.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(ProfileAvatarImage.maxFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try ProfileAvatarImage.readCandidate(at: huge)) { XCTAssertEqual($0 as? ProfileAvatarImageError, .tooLarge) }
    }

    // MARK: Names and files

    func testNamesAreHashesWithOurExtensionsOnly() {
        let hash = String(repeating: "ab", count: 32)
        XCTAssertNotNil(ProfileAvatarImageName(rawValue: "\(hash).jpg"))
        XCTAssertNotNil(ProfileAvatarImageName(rawValue: "\(hash).png"))
        for bad in ["\(hash).heic", "\(hash.uppercased()).jpg", "\(hash.dropLast()).jpg", "../\(hash.dropFirst(3)).jpg",
                    "\(hash).jpg/..", "\(hash)", ".jpg", "\(hash).jpg.png", String(repeating: "０", count: 64) + ".jpg"] {
            XCTAssertNil(ProfileAvatarImageName(rawValue: bad), bad)
        }
    }

    func testStoreKeepsOwnerOnlyFilesNamedByContentAndCleansUp() throws {
        let store = ProfileAvatarImageStore(directory: directory.appendingPathComponent("ProfileAvatars"))
        let first = try ProfileAvatarImage.normalizing(encode([bitmap(width: 300, height: 300, columns: [red])], as: .png))
        let second = try ProfileAvatarImage.normalizing(encode([bitmap(width: 300, height: 300, columns: [blue])], as: .png))
        XCTAssertEqual(try store.save(first), first.name)
        XCTAssertEqual(try store.save(first), first.name, "saving the same picture again is harmless")
        try store.save(second)
        let fm = FileManager.default
        XCTAssertEqual(try fm.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try fm.attributesOfItem(atPath: store.url(for: first.name).path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try Data(contentsOf: store.url(for: first.name)), first.data)
        XCTAssertEqual(store.image(named: first.name)?.width, 256)

        let missing = try XCTUnwrap(ProfileAvatarImageName(rawValue: String(repeating: "0", count: 64) + ".jpg"))
        XCTAssertNil(store.image(named: missing))
        XCTAssertFalse(store.contains(missing))

        // Someone else's file in the folder, and a link posing as a picture.
        try Data("keep".utf8).write(to: store.directory.appendingPathComponent("notes.txt"))
        let linked = try XCTUnwrap(ProfileAvatarImageName(rawValue: String(repeating: "1", count: 64) + ".png"))
        try fm.createSymbolicLink(at: store.url(for: linked), withDestinationURL: store.url(for: second.name))
        XCTAssertNil(store.image(named: linked), "never read through a link")
        XCTAssertFalse(store.contains(linked))

        let removed = store.removeUnused(keeping: [first.name])
        XCTAssertEqual(Set(removed), [second.name, linked])
        XCTAssertTrue(store.contains(first.name))
        XCTAssertFalse(fm.fileExists(atPath: store.url(for: second.name).path))
        XCTAssertTrue(fm.fileExists(atPath: store.directory.appendingPathComponent("notes.txt").path))
        XCTAssertEqual(ProfileAvatarImageStore(directory: directory.appendingPathComponent("absent")).removeUnused(keeping: []), [])
    }

    func testStoreNamesTheUsedPictures() throws {
        let store = SidebarStore()
        XCTAssertTrue(store.profileAvatarImageNames.isEmpty)
        let name = try XCTUnwrap(ProfileAvatarImageName(rawValue: String(repeating: "c", count: 64) + ".jpg"))
        XCTAssertNil(store.setProfileAvatar(.init(kind: .emoji("🙂"), image: name), for: store.activeProfileID))
        XCTAssertEqual(store.profileAvatarImageNames, [name])
        XCTAssertEqual(ProfileAvatarImageStore(besideSidebarFile: directory.appendingPathComponent("sidebar.json")).directory,
                       directory.appendingPathComponent("ProfileAvatars", isDirectory: true))
    }
}
