import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import ReArc
@testable import SidebarModel

@MainActor
final class ProfileMenuTests: XCTestCase {
    private var directory: URL!
    private var hostingMenu: NSMenu?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-profile-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var images: ProfileAvatarImageStore { ProfileAvatarImageStore(besideSidebarFile: directory.appendingPathComponent("sidebar.json")) }

    private func png(_ color: CGColor, size: Int = 64) -> Data {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    private func savedPicture(_ color: CGColor) throws -> ProfileAvatarImageName {
        try images.save(ProfileAvatarImage.normalizing(png(color)))
    }

    /// The centre pixel of an image, as 0–255 RGBA.
    private func centre(_ image: NSImage) throws -> [Int] {
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: -CGFloat(cg.width) / 2 + 0.5, y: -CGFloat(cg.height) / 2 + 0.5, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        return pixel.map(Int.init)
    }

    private func makeModel(store: SidebarStore = SidebarStore(), persistence: SidebarFilePersistence? = nil) -> BrowserViewModel {
        BrowserViewModel(store: store,
                         persistence: persistence ?? SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
                         syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
    }

    // MARK: The menu as AppKit draws it

    /// What a SwiftUI menu turns the rows into: real `NSMenuItem`s.
    private func menuItems(_ choices: ProfileMenuChoices) throws -> [NSMenuItem] {
        guard #available(macOS 15, *) else { throw XCTSkip("NSHostingMenu needs macOS 15") }
        _ = NSApplication.shared
        let menu = NSHostingMenu(rootView: choices)
        menu.update()
        // Items keep only a weak link to their menu.
        hostingMenu = menu
        return menu.items
    }

    func testRowsDrawTheAvatarNameCountAndStandardCheckmark() throws {
        guard #available(macOS 15, *) else { throw XCTSkip("NSHostingMenu needs macOS 15") }
        let store = SidebarStore()
        let first = store.activeProfile
        let upper = store.addProfile(name: "Akilu", avatar: .init(kind: .emoji("💖")), themeColor: SpaceTheme.presets[2])
        let typo = store.addProfile(name: "akliu", createInitialSpace: false)
        for index in 0..<12 { _ = store.addSpace(name: "S\(index)", profileID: first.id) }

        let items = try menuItems(ProfileMenuChoices(store: store, active: upper.id, images: images) { _ in })
        XCTAssertEqual(items.map(\.title), [first.name, "Akilu", "akliu"])
        XCTAssertEqual(items.map(\.subtitle), ["13 spaces", "1 space", "No spaces"])
        XCTAssertEqual(items.map(\.state), [.off, .on, .off], "the menu's own checkmark, which VoiceOver reads")
        for item in items {
            let image = try XCTUnwrap(item.image, item.title)
            XCTAssertFalse(image.isTemplate, "drawn in the profile's colours")
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16))
            XCTAssertTrue(item.isEnabled)
        }
        XCTAssertNotEqual(items[0].image?.tiffRepresentation, items[1].image?.tiffRepresentation)
        _ = typo
    }

    func testChoosingARowSelectsItAndTheActiveRowStays() throws {
        let store = SidebarStore()
        let other = store.addProfile(name: "Other")
        var chosen: [Profile.ID] = []
        let items = try menuItems(ProfileMenuChoices(store: store, active: store.activeProfileID, images: images) { chosen.append($0) })
        let menu = try XCTUnwrap(hostingMenu)
        for index in items.indices { menu.performActionForItem(at: index) }
        // SwiftUI runs a menu item's action on the next turn of the run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(chosen, [other.id], "the checked profile is already active")
    }

    func testASpacesChoicesKeepTheCurrentProfileCheckedButUnavailable() throws {
        let store = SidebarStore()
        _ = store.addProfile(name: "Other")
        let items = try menuItems(ProfileMenuChoices(store: store, active: store.activeProfileID, disablesActive: true, images: images) { _ in })
        XCTAssertEqual(items.map(\.state), [.on, .off])
        XCTAssertEqual(items.map(\.isEnabled), [false, true])
    }

    // MARK: The avatar

    func testThePictureDrawsWhereTheFileIsAndTheSymbolWhereItIsNot() throws {
        let red = try savedPicture(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let blue = SpaceTheme(red: 0, green: 0, blue: 1)
        let withPicture = Profile(name: "P", avatar: .init(kind: .emoji("🙂"), image: red), themeColor: blue)
        let picture = try centre(ProfileAvatarPictures.menuImage(for: withPicture, diameter: 24, images: images))
        XCTAssertGreaterThan(picture[0], 200)
        XCTAssertLessThan(picture[2], 60)

        // Another Mac (or a deleted file): the emoji on the profile's colour.
        let missing = try XCTUnwrap(ProfileAvatarImageName(rawValue: String(repeating: "e", count: 64) + ".jpg"))
        let fallback = Profile(name: "P", avatar: .init(kind: .sfSymbol(name: "circle.fill"), image: missing), themeColor: blue)
        let elsewhere = ProfileAvatarPictures.menuImage(for: fallback, diameter: 24, images: images)
        let plain = ProfileAvatarPictures.menuImage(for: Profile(name: "P", avatar: .init(kind: .sfSymbol(name: "circle.fill")), themeColor: blue),
                                                    diameter: 24, images: images)
        XCTAssertEqual(elsewhere.tiffRepresentation, plain.tiffRepresentation)
        let symbol = try centre(elsewhere)
        XCTAssertGreaterThan(symbol[2], 150, "the white symbol, not the red picture")
    }

    // MARK: Files

    func testSavingAProfileRemovesThePictureItReplacedUnlessAnotherUsesIt() throws {
        let model = makeModel()
        let red = try savedPicture(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let green = try savedPicture(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        let personal = model.store.activeProfile
        let other = model.store.addProfile(name: "Other", avatar: .init(kind: .emoji("🙂"), image: green))
        XCTAssertEqual(model.avatarImages.directory, images.directory)

        var draft = ProfileDraft(profile: personal)
        draft.avatar.image = red
        XCTAssertNotNil(model.saveProfile(draft, id: personal.id, selecting: false))
        XCTAssertEqual(model.store.profile(withID: personal.id)?.avatar.image, red)

        draft.avatar = ProfileAvatarDescriptor(kind: .sfSymbol(name: "leaf.fill"))
        XCTAssertNotNil(model.saveProfile(draft, id: personal.id, selecting: false))
        XCTAssertFalse(images.contains(red), "replaced, and no profile uses it")

        var otherDraft = ProfileDraft(profile: other)
        otherDraft.avatar.image = nil
        _ = model.store.addProfile(name: "Twin", avatar: .init(kind: .emoji("🙂"), image: green))
        XCTAssertNotNil(model.saveProfile(otherDraft, id: other.id, selecting: false))
        XCTAssertTrue(images.contains(green), "Twin still uses it")
    }

    func testLaunchCleanupRunsOnlyAfterTheSidebarFileLoaded() throws {
        let store = SidebarStore()
        let used = try savedPicture(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let stale = try savedPicture(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        XCTAssertNil(store.setProfileAvatar(.init(kind: .emoji("🙂"), image: used), for: store.activeProfileID))

        // A first run (no file) or a damaged file: nothing is removed.
        makeModel(store: store).removeUnusedProfileAvatarImages()
        XCTAssertTrue(images.contains(stale))

        let file = directory.appendingPathComponent("sidebar.json")
        try JSONEncoder().encode(store.makeSnapshot()).write(to: file)
        let persistence = SidebarFilePersistence(fileURL: file)
        let loaded = SidebarFilePersistence.loadStore(fileURL: file, persistence: persistence)
        XCTAssertEqual(persistence.loadOutcome, .loaded)
        makeModel(store: loaded, persistence: persistence).removeUnusedProfileAvatarImages()
        XCTAssertTrue(images.contains(used))
        XCTAssertFalse(images.contains(stale))
    }

    // MARK: Choose, drop and paste

    func testIntakeStoresANormalisedCopyAndRefusesLinks() throws {
        let file = directory.appendingPathComponent("photo.png")
        try png(CGColor(red: 0, green: 1, blue: 0, alpha: 1), size: 600).write(to: file)
        let name = try ProfileAvatarImageIntake.adopt(.file(file), into: images)
        XCTAssertTrue(images.contains(name))
        XCTAssertEqual(images.image(named: name)?.width, 256)
        XCTAssertNotEqual(try Data(contentsOf: images.url(for: name)), try Data(contentsOf: file), "a copy, never the original bytes")

        let link = directory.appendingPathComponent("alias.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try ProfileAvatarImageIntake.adopt(.file(link), into: images)) {
            XCTAssertEqual($0 as? ProfileAvatarImageError, .unreadable)
        }
        XCTAssertThrowsError(try ProfileAvatarImageIntake.adopt(.data(Data("hello".utf8)), into: images)) {
            XCTAssertEqual($0 as? ProfileAvatarImageError, .notAnImage)
        }
    }

    func testPasteTakesAFileFirstThenImageData() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertNil(ProfileAvatarImageIntake.source(from: pasteboard))

        let data = png(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        guard case .data(let pasted)? = ProfileAvatarImageIntake.source(from: pasteboard) else { return XCTFail("image data") }
        XCTAssertEqual(pasted, data)

        let file = directory.appendingPathComponent("copied.png")
        try data.write(to: file)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        guard case .file(let url)? = ProfileAvatarImageIntake.source(from: pasteboard) else { return XCTFail("a file") }
        XCTAssertEqual(url.standardizedFileURL, file.standardizedFileURL)
    }
}
